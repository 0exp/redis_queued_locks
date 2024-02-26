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

  # @return [Integer]
  #   Redis expiration deviation in milliseconds:
  #   -> 1 millisecond: for Redis's deviation;
  #   -> 1 millisecond: for RubyVM's processing deviation;
  #
  # @api private
  # @since 0.1.0
  REDIS_EXPIRATION_DEVIATION = 2 # NOTE: milliseconds

  # rubocop:disable Metrics/ClassLength
  class << self
    # @param redis [RedisClient]
    #   Redis connection client.
    # @param lock_name [String]
    #   Lock name to be acquier.
    # @option process_id [Integer,String]
    #   The process that want to acquire the lock.
    # @option thread_id [Integer,String]
    #   The process's thread that want to acquire the lock.
    # @option ttl [Integer]
    #   Lock's time to live (in milliseconds).
    # @option queue_ttl [Integer]
    #   ?
    # @option timeout [Integer]
    #   Time period whe should try to acquire the lock (in seconds).
    # @option retry_count [Integer]
    #   How many times we should try to acquire a lock.
    # @option retry_delay [Integer]
    #   A time-interval between the each retry (in milliseconds).
    # @option retry_jitter [Integer]
    #   Time-shift range for retry-delay (in milliseconds).
    # @option raise_errors [Boolean]
    #   Raise errors on exceptional cases.
    # @option instrumenter [#notify]
    #   See RedisQueuedLocks::Instrument::ActiveSupport for example.
    # @param [Block]
    #   A block of code that should be executed after the successfully acquired lock.
    # @return [Hash<Symbol,Any>]
    #   Format: { ok: true/false, result: Any }
    #
    # @api private
    # @since 0.1.0
    # rubocop:disable Metrics/MethodLength
    def acquire_lock!(
      redis,
      lock_name,
      process_id:,
      thread_id:,
      ttl:,
      queue_ttl:,
      timeout:,
      retry_count:,
      retry_delay:,
      retry_jitter:,
      raise_errors:,
      instrumenter:,
      &block
    )
      # Step 1: prepare lock requirements (generate lock name, calc lock ttl, etc).
      acquier_id = RedisQueuedLocks::Resource.acquier_identifier(process_id, thread_id)
      lock_ttl = ttl + REDIS_EXPIRATION_DEVIATION
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
        acq_time: nil # NOTE: in milliseconds
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
          acq_time = ((acq_end_time - acq_start_time) * 1_000).ceil

          # Step X: save the intermediate results to the result observer
          acq_process[:result] = result

          # Step 2.1: analyze an acquirement attempt
          if ok
            # INSTRUMENT: lock obtained
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
          else
            # Step 2.1.b: failed acquirement => retry
            acq_process[:tries] += 1

            if acq_process[:tries] >= retry_count
              # NOTE: reached the retry limit => quit from the loop
              acq_process[:should_try] = false
              # NOTE: reached the retry limit => dequeue from the lock queue
              acq_dequeue.call
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
          yield_with_expire(redis, lock_key, &block) # INSTRUMENT: lock release
        else
          { ok: true, result: acq_process[:lock_info] }
        end
      else
        # Step 3.b: lock is not acquired:
        #   => drop itslef from the queue and return the reason of the failed acquirement
        { ok: false, result: acq_process[:result] }
      end
    end
    # rubocop:enable Metrics/MethodLength

    # Release the concrete lock:
    # - 1. clear lock queue: al; related processes released
    #      from the lock aquierment and should retry;
    # - 2. delete the lock: drop lock key from Redis;
    # It is safe because the lock obtain logic is transactional and
    # watches the original lock for changes.
    #
    # @param redis [RedisClient] Redis connection client.
    # @param lock_name [String] The lock name that should be released.
    # @return [Hash<Symbol,Any>] Format: { ok: true/false, result: Any }
    #
    # @api private
    # @since 0.1.0
    def release_lock!(redis, lock_name)
      lock_key = RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
      lock_key_queue = RedisQueuedLocks::Resource.prepare_lock_queue(lock_name)

      # INSTRUMENT: lock release
      result = fully_release_lock(redis, lock_key, lock_key_queue)
      { ok: true, result: result }
    end

    # Release all locks:
    # - 1. clear all lock queus: drop them all from Redis database by the lock queue pattern;
    # - 2. delete all locks: drop lock keys from Redis by the lock key pattern;
    #
    # @param redis [RedisClient] Redis connection client.
    # @param batch_size [Integer] The number of lock keys that should be released in a time.
    # @return [Hash<Symbol,Any>] Format: { ok: true/false, result: Any }
    #
    # @api private
    # @since 0.1.0
    def release_all_locks!(redis, batch_size)
      # INSTRUMENT: all locks released
      result = fully_release_all_locks(redis, batch_size)
      { ok: true, result: result }
    end

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
  end
  # rubocop:enable Metrics/ClassLength
end
# rubocop:enable Metrics/ModuleLength
