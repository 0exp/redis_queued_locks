# frozen_string_literal: true

# @api private
# @since 0.1.0
# rubocop:disable Metrics/ModuleLength
module RedisQueuedLocks::Acquier
  require_relative 'acquier/try'
  require_relative 'acquier/delay'
  require_relative 'acquier/expire'
  require_relative 'acquier/release'

  # @since 0.1.0
  extend Try
  # @since 0.1.0
  extend Delay
  # @since 0.1.0
  extend Expire
  # @since 0.1.0
  extend Release

  # @return [Integer] Redis expiration error in milliseconds.
  #
  # @api private
  # @since 0.1.0
  REDIS_EXPIRE_ERROR = 1

  # rubocop:disable Metrics/ClassLength
  class << self
    # @param redis [RedisClient]
    #   Redis connection client.
    # @param lock_name [String]
    #   Lock name to be acquier.
    # @option process_id [Integer,String]
    #   The process that want to acquire a lock.
    # @option thread_id [Integer,String]
    #   The process's thread that want to acquire a lock.
    # @option fiber_id [Integer,String]
    #   A current fiber that want to acquire a lock.
    # @option ractor_id [Integer,String]
    #   The current ractor that want to acquire a lock.
    # @option ttl [Integer,NilClass]
    #   Lock's time to live (in milliseconds). Nil means "without timeout".
    # @option queue_ttl [Integer]
    #   Lifetime of the acuier's lock request. In seconds.
    # @option timeout [Integer]
    #   Time period whe should try to acquire the lock (in seconds).
    # @option retry_count [Integer,NilClass]
    #   How many times we should try to acquire a lock. Nil means "infinite retries".
    # @option retry_delay [Integer]
    #   A time-interval between the each retry (in milliseconds).
    # @option retry_jitter [Integer]
    #   Time-shift range for retry-delay (in milliseconds).
    # @option raise_errors [Boolean]
    #   Raise errors on exceptional cases.
    # @option instrumenter [#notify]
    #   See RedisQueuedLocks::Instrument::ActiveSupport for example.
    # @option identity [String]
    #   Unique acquire identifier that is also should be unique between processes and pods
    #   on different machines. By default the uniq identity string is
    #   represented as 10 bytes hexstr.
    # @param [Block]
    #   A block of code that should be executed after the successfully acquired lock.
    # @return [Hash<Symbol,Any>]
    #   Format: { ok: true/false, result: Any }
    #
    # @api private
    # @since 0.1.0
    # rubocop:disable Metrics/MethodLength, Metrics/BlockNesting
    def acquire_lock!(
      redis,
      lock_name,
      process_id:,
      thread_id:,
      fiber_id:,
      ractor_id:,
      ttl:,
      queue_ttl:,
      timeout:,
      retry_count:,
      retry_delay:,
      retry_jitter:,
      raise_errors:,
      instrumenter:,
      identity:,
      &block
    )
      # Step 1: prepare lock requirements (generate lock name, calc lock ttl, etc).
      acquier_id = RedisQueuedLocks::Resource.acquier_identifier(
        process_id,
        thread_id,
        fiber_id,
        ractor_id,
        identity
      )
      # NOTE:
      #   - think aobut the redis expiration error
      #   - (ttl - REDIS_EXPIRE_ERROR).yield_self { |val| (val == 0) ? ttl : val }
      lock_ttl = ttl
      lock_key = RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
      lock_key_queue = RedisQueuedLocks::Resource.prepare_lock_queue(lock_name)
      acquier_position = RedisQueuedLocks::Resource.calc_initial_acquier_position

      # Step X: intermediate result observer
      acq_process = {
        lock_info: {},
        should_try: true,
        tries: 0,
        acquired: false,
        result: nil,
        acq_time: nil, # NOTE: in milliseconds
        hold_time: nil, # NOTE: in milliseconds
        rel_time: nil # NOTE: in milliseconds
      }
      acq_dequeue = -> { dequeue_from_lock_queue(redis, lock_key_queue, acquier_id) }

      # Step 2: try to lock with timeout
      with_timeout(timeout, lock_key, raise_errors, on_timeout: acq_dequeue) do
        acq_start_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

        # Step 2.1: caclically try to obtain the lock
        while acq_process[:should_try]
          try_to_lock(
            redis,
            lock_key,
            lock_key_queue,
            acquier_id,
            acquier_position,
            lock_ttl,
            queue_ttl
          ) => { ok:, result: }

          acq_end_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
          acq_time = ((acq_end_time - acq_start_time) * 1_000).ceil(2)

          # Step X: save the intermediate results to the result observer
          acq_process[:result] = result

          # Step 2.1: analyze an acquirement attempt
          if ok
            # Step X (instrumentation): lock obtained
            instrumenter.notify('redis_queued_locks.lock_obtained', {
              lock_key: result[:lock_key],
              ttl: result[:ttl],
              acq_id: result[:acq_id],
              ts: result[:ts],
              acq_time: acq_time
            })

            # Step 2.1.a: successfully acquired => build the result
            acq_process[:lock_info] = {
              lock_key: result[:lock_key],
              acq_id: result[:acq_id],
              ts: result[:ts],
              ttl: result[:ttl]
            }
            acq_process[:acquired] = true
            acq_process[:should_try] = false
            acq_process[:acq_time] = acq_time
            acq_process[:acq_end_time] = acq_end_time
          else
            # Step 2.1.b: failed acquirement => retry
            acq_process[:tries] += 1

            if retry_count != nil && acq_process[:tries] >= retry_count
              # NOTE: reached the retry limit => quit from the loop
              acq_process[:should_try] = false
              acq_process[:result] = :retry_limit_reached
              # NOTE: reached the retry limit => dequeue from the lock queue
              acq_dequeue.call
              # NOTE: check and raise an error
              raise(LockAcquiermentRetryLimitError, <<~ERROR_MESSAGE.strip) if raise_errors
                Failed to acquire the lock "#{lock_key}"
                for the given retry_count limit (#{retry_count} times).
              ERROR_MESSAGE
            else
              # NOTE:
              #   delay the exceution in order to prevent chaotic attempts
              #   and to allow other processes and threads to obtain the lock too.
              delay_execution(retry_delay, retry_jitter)
            end
          end
        end
      end

      # Step 3: analyze acquirement result
      if acq_process[:acquired]
        # Step 3.a: acquired successfully => run logic or return the result of acquirement
        if block_given?
          begin
            yield_with_expire(redis, lock_key, &block)
          ensure
            acq_process[:rel_time] = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
            acq_process[:hold_time] = (
              (acq_process[:rel_time] - acq_process[:acq_end_time]) * 1000
            ).ceil(2)

            # Step X (instrumentation): lock_hold_and_release
            run_non_critical do
              instrumenter.notify('redis_queued_locks.lock_hold_and_release', {
                hold_time: acq_process[:hold_time],
                ttl: acq_process[:lock_info][:ttl],
                acq_id: acq_process[:lock_info][:acq_id],
                ts: acq_process[:lock_info][:ts],
                lock_key: acq_process[:lock_info][:lock_key],
                acq_time: acq_process[:acq_time]
              })
            end
          end
        else
          { ok: true, result: acq_process[:lock_info] }
        end
      else
        unless acq_process[:result] == :retry_limit_reached
          # NOTE: we have only two situations if lock is not acquired:
          #   - time limit is reached
          #   - retry count limit is reached
          #   In other cases the lock obtaining time and tries count are infinite.
          acq_process[:result] = :timeout_reached
        end
        # Step 3.b: lock is not acquired (acquier is dequeued by timeout callback)
        { ok: false, result: acq_process[:result] }
      end
    end
    # rubocop:enable Metrics/MethodLength, Metrics/BlockNesting

    # Release the concrete lock:
    # - 1. clear lock queue: al; related processes released
    #      from the lock aquierment and should retry;
    # - 2. delete the lock: drop lock key from Redis;
    # It is safe because the lock obtain logic is transactional and
    # watches the original lock for changes.
    #
    # @param redis [RedisClient] Redis connection client.
    # @param lock_name [String] The lock name that should be released.
    # @param isntrumenter [#notify] See RedisQueuedLocks::Instrument::ActiveSupport for example.
    # @return [Hash<Symbol,Any>] Format: { ok: true/false, result: Hash<Symbil,Numeric|String> }
    #
    # @api private
    # @since 0.1.0
    def release_lock!(redis, lock_name, instrumenter)
      lock_key = RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
      lock_key_queue = RedisQueuedLocks::Resource.prepare_lock_queue(lock_name)

      rel_start_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      fully_release_lock(redis, lock_key, lock_key_queue) => { ok:, result: }
      time_at = Time.now.to_i
      rel_end_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      rel_time = ((rel_end_time - rel_start_time) * 1_000).ceil(2)

      run_non_critical do
        instrumenter.notify('redis_queued_locks.explicit_lock_release', {
          lock_key: lock_key,
          lock_key_queue: lock_key_queue,
          rel_time: rel_time,
          at: time_at
        })
      end

      { ok: true, result: { rel_time: rel_time, rel_key: lock_key, rel_queue: lock_key_queue } }
    end

    # Release all locks:
    # - 1. clear all lock queus: drop them all from Redis database by the lock queue pattern;
    # - 2. delete all locks: drop lock keys from Redis by the lock key pattern;
    #
    # @param redis [RedisClient] Redis connection client.
    # @param batch_size [Integer] The number of lock keys that should be released in a time.
    # @param isntrumenter [#notify] See RedisQueuedLocks::Instrument::ActiveSupport for example.
    # @return [Hash<Symbol,Any>] Format: { ok: true/false, result: Hash<Symbol,Numeric> }
    #
    # @api private
    # @since 0.1.0
    def release_all_locks!(redis, batch_size, instrumenter)
      rel_start_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      fully_release_all_locks(redis, batch_size) => { ok:, result: }
      time_at = Time.now.to_i
      rel_end_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      rel_time = ((rel_end_time - rel_start_time) * 1_000).ceil(2)

      run_non_critical do
        instrumenter.notify('redis_queued_locks.explicit_all_locks_release', {
          at: time_at,
          rel_time: rel_time,
          rel_keys: result[:rel_keys]
        })
      end

      { ok: true, result: { rel_key_cnt: result[:rel_keys], rel_time: rel_time } }
    end

    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @return [Boolean]
    #
    # @api private
    # @since 0.1.0
    def locked?(redis_client, lock_name)
      lock_key = RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
      redis_client.call('EXISTS', lock_key) == 1
    end

    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @return [Boolean]
    #
    # @api private
    # @since 0.1.0
    def queued?(redis_client, lock_name)
      lock_key_queue = RedisQueuedLocks::Resource.prepare_lock_queue(lock_name)
      redis_client.call('EXISTS', lock_key_queue) == 1
    end

    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @return [Hash<Symbol,String|Numeric>,NilClass]
    #   - `nil` is returned when lock key does not exist or expired;
    #   - result format: {
    #     lock_key: "rql:lock:your_lockname", # acquired lock key
    #     acq_id: "rql:acq:process_id/thread_id", # lock acquier identifier
    #     ts: 123456789, # <locked at> time stamp (epoch)
    #     ini_ttl: 123456789, # initial lock key ttl (milliseconds),
    #     rem_ttl: 123456789, # remaining lock key ttl (milliseconds)
    #   }
    #
    # @api private
    # @since 0.1.0
    def lock_info(redis_client, lock_name)
      lock_key = RedisQueuedLocks::Resource.prepare_lock_key(lock_name)

      result = redis_client.multi(watch: [lock_key]) do |transact|
        transact.call('HGETALL', lock_key)
        transact.call('PTTL', lock_key)
      end

      if result == nil
        # NOTE:
        #   - nil result means that during transaction invocation the lock is changed (CAS):
        #     - lock is expired;
        #     - lock is released;
        #     - lock is expired + re-obtained;
        nil
      else
        hget_cmd_res = result[0]
        pttl_cmd_res = result[1]

        if hget_cmd_res == {} || pttl_cmd_res == -2 # NOTE: key does not exist
          nil
        else
          # NOTE: the result of MULTI-command is an array of results of each internal command
          #   - result[0] (HGETALL) (Hash<String,String>)
          #   - result[1] (PTTL) (Integer)
          {
            lock_key: lock_key,
            acq_id: hget_cmd_res['acq_id'],
            ts: Integer(hget_cmd_res['ts']),
            ini_ttl: Integer(hget_cmd_res['ini_ttl']),
            rem_ttl: ((pttl_cmd_res == -1) ? Infinity : pttl_cmd_res)
          }
        end
      end
    end

    # Returns an information about the required lock queue by the lock name. The result
    # represnts the ordered lock request queue that is ordered by score (Redis sets) and shows
    # lock acquirers and their position in queue. Async nature with redis communcation can lead
    # the sitaution when the queue becomes empty during the queue data extraction. So sometimes
    # you can receive the lock queue info with empty queue.
    #
    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @return [Hash<Symbol,String|Array<Hash<Symbol,String|Float>>,NilClass]
    #   - `nil` is returned when lock queue does not exist;
    #   - result format: {
    #     lock_queue: "rql:lock_queue:your_lock_name", # lock queue key in redis,
    #     queue: [
    #       { acq_id: "rql:acq:process_id/thread_id", score: 123 },
    #       { acq_id: "rql:acq:process_id/thread_id", score: 456 },
    #     ] # ordered set (by score) with information about an acquier and their position in queue
    #   }
    #
    # @api private
    # @since 0.1.0
    def queue_info(redis_client, lock_name)
      lock_key_queue = RedisQueuedLocks::Resource.prepare_lock_queue(lock_name)

      result = redis_client.pipelined do |pipeline|
        pipeline.call('EXISTS', lock_key_queue)
        pipeline.call('ZRANGE', lock_key_queue, '0', '-1', 'WITHSCORES')
      end

      exists_cmd_res = result[0]
      zrange_cmd_res = result[1]

      if exists_cmd_res == 1
        # NOTE: queue existed during the piepline invocation
        {
          lock_queue: lock_key_queue,
          queue: zrange_cmd_res.map { |val| { acq_id: val[0], score: val[1] } }
        }
      else
        # NOTE: queue did not exist during the pipeline invocation
        nil
      end
    end

    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @param milliseconds [Integer]
    # @return [?]
    #
    # @api private
    # @since 0.1.0
    def extend_lock_ttl(redis_client, lock_name, milliseconds); end

    private

    # @param timeout [NilClass,Integer]
    #   Time period after which the logic will fail with timeout error.
    # @param lock_key [String]
    #   Lock name.
    # @param raise_errors [Boolean]
    #   Raise erros on exceptional cases.
    # @option on_timeout [Proc,NilClass]
    #   Callback invoked on Timeout::Error.
    # @return [Any]
    #
    # @api private
    # @since 0.1.0
    def with_timeout(timeout, lock_key, raise_errors, on_timeout: nil, &block)
      ::Timeout.timeout(timeout, &block)
    rescue ::Timeout::Error
      on_timeout.call unless on_timeout == nil

      if raise_errors
        raise(RedisQueuedLocks::LockAcquiermentTimeoutError, <<~ERROR_MESSAGE.strip)
          Failed to acquire the lock "#{lock_key}" for the given timeout (#{timeout} seconds).
        ERROR_MESSAGE
      end
    end

    # @param block [Block]
    # @return [Any]
    #
    # @api private
    # @since 0.1.0
    def run_non_critical(&block)
      yield rescue nil
    end
  end
  # rubocop:enable Metrics/ClassLength
end
# rubocop:enable Metrics/ModuleLength
