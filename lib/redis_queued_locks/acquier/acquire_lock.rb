# frozen_string_literal: true

# @api private
# @since 0.1.0
# rubocop:disable Metrics/ModuleLength
# rubocop:disable Metrics/MethodLength
# rubocop:disable Metrics/ClassLength
# rubocop:disable Metrics/BlockNesting
module RedisQueuedLocks::Acquier::AcquireLock
  require_relative 'acquire_lock/delay_execution'
  require_relative 'acquire_lock/with_acq_timeout'
  require_relative 'acquire_lock/yield_with_expire'
  require_relative 'acquire_lock/try_to_lock'

  # @since 0.1.0
  extend TryToLock
  # @since 0.1.0
  extend DelayExecution
  # @since 0.1.0
  extend YieldWithExpire
  # @since 0.1.0
  extend WithAcqTimeout
  # @since 0.1.0
  extend RedisQueuedLocks::Utilities

  # @return [Integer] Redis expiration error (in milliseconds).
  #
  # @api private
  # @since 0.1.0
  REDIS_EXPIRE_ERROR = 1

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
    # @option timed [Boolean]
    #   Limit the invocation time period of the passed block of code by the lock's TTL.
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
    # @option fail_fast [Boolean]
    #   Should the required lock to be checked before the try and exit immidetly if lock is
    #   already obtained.
    # @option metadata [NilClass,Any]
    #   - A custom metadata wich will be passed to the instrumenter's payload with :meta key;
    # @option logger [::Logger,#debug]
    #   - Logger object used from the configuration layer (see config[:logger]);
    #   - See RedisQueuedLocks::Logging::VoidLogger for example;
    # @option log_lock_try [Boolean]
    #   - should be logged the each try of lock acquiring (a lot of logs can be generated depending
    #     on your retry configurations);
    #   - see `config[:log_lock_try]`;
    # @param [Block]
    #   A block of code that should be executed after the successfully acquired lock.
    # @return [RedisQueuedLocks::Data,Hash<Symbol,Any>,yield]
    #  - Format: { ok: true/false, result: Any }
    #  - If block is given the result of block's yeld will be returned.
    #
    # @api private
    # @since 0.1.0
    def acquire_lock(
      redis,
      lock_name,
      process_id:,
      thread_id:,
      fiber_id:,
      ractor_id:,
      ttl:,
      queue_ttl:,
      timeout:,
      timed:,
      retry_count:,
      retry_delay:,
      retry_jitter:,
      raise_errors:,
      instrumenter:,
      identity:,
      fail_fast:,
      metadata:,
      logger:,
      log_lock_try:,
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

      run_non_critical do
        logger.debug(
          "[redis_queued_locks.start_lock_obtaining] " \
          "lock_key => '#{lock_key}'"
        )
      end

      # Step 2: try to lock with timeout
      with_acq_timeout(timeout, lock_key, raise_errors, on_timeout: acq_dequeue) do
        acq_start_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

        # Step 2.1: caclically try to obtain the lock
        while acq_process[:should_try]
          try_to_lock(
            redis,
            logger,
            log_lock_try,
            lock_key,
            lock_key_queue,
            acquier_id,
            acquier_position,
            lock_ttl,
            queue_ttl,
            fail_fast
          ) => { ok:, result: }

          acq_end_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
          acq_time = ((acq_end_time - acq_start_time) * 1_000).ceil(2)

          # Step X: save the intermediate results to the result observer
          acq_process[:result] = result
          acq_process[:acq_end_time] = acq_end_time

          # Step 2.1: analyze an acquirement attempt
          if ok
            run_non_critical do
              logger.debug(
                "[redis_queued_locks.lock_obtained] " \
                "lock_key => '#{result[:lock_key]}'" \
                "acq_time => #{acq_time} (ms)"
              )
            end

            # Step X (instrumentation): lock obtained
            run_non_critical do
              instrumenter.notify('redis_queued_locks.lock_obtained', {
                lock_key: result[:lock_key],
                ttl: result[:ttl],
                acq_id: result[:acq_id],
                ts: result[:ts],
                acq_time: acq_time,
                meta: metadata
              })
            end

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
          elsif fail_fast && acq_process[:result] == :fail_fast_no_try
            acq_process[:should_try] = false
            if raise_errors
              raise(RedisQueuedLocks::LockAlreadyObtainedError, <<~ERROR_MESSAGE.strip)
                Lock "#{lock_key}" is already obtained.
              ERROR_MESSAGE
            end
          else
            # Step 2.1.b: failed acquirement => retry
            acq_process[:tries] += 1

            if (retry_count != nil && acq_process[:tries] >= retry_count) || fail_fast
              # NOTE:
              #   - reached the retry limit => quit from the loop
              #   - should fail fast => quit from the loop
              acq_process[:should_try] = false
              acq_process[:result] = fail_fast ? :fail_fast_after_try : :retry_limit_reached

              # NOTE:
              #   - reached the retry limit => dequeue from the lock queue
              #   - should fail fast => dequeue from the lock queue
              acq_dequeue.call

              # NOTE: check and raise an error
              if fail_fast && raise_errors
                raise(RedisQueuedLocks::LockAlreadyObtainedError, <<~ERROR_MESSAGE.strip)
                  Lock "#{lock_key}" is already obtained.
                ERROR_MESSAGE
              elsif raise_errors
                raise(RedisQueuedLocks::LockAcquiermentRetryLimitError, <<~ERROR_MESSAGE.strip)
                  Failed to acquire the lock "#{lock_key}"
                  for the given retry_count limit (#{retry_count} times).
                ERROR_MESSAGE
              end
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
            yield_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
            ttl_shift = ((yield_time - acq_process[:acq_end_time]) * 1000).ceil(2)
            yield_with_expire(redis, logger, lock_key, timed, ttl_shift, ttl, &block)
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
                acq_time: acq_process[:acq_time],
                meta: metadata
              })
            end
          end
        else
          RedisQueuedLocks::Data[ok: true, result: acq_process[:lock_info]]
        end
      else
        if acq_process[:result] != :retry_limit_reached &&
           acq_process[:result] != :fail_fast_no_try &&
           acq_process[:result] != :fail_fast_after_try
          # NOTE: we have only two situations if lock is not acquired withou fast-fail flag:
          #   - time limit is reached
          #   - retry count limit is reached
          #   In other cases the lock obtaining time and tries count are infinite.
          acq_process[:result] = :timeout_reached
        end
        # Step 3.b: lock is not acquired (acquier is dequeued by timeout callback)
        RedisQueuedLocks::Data[ok: false, result: acq_process[:result]]
      end
    end
  end
end
# rubocop:enable Metrics/ModuleLength
# rubocop:enable Metrics/MethodLength
# rubocop:enable Metrics/ClassLength
# rubocop:enable Metrics/BlockNesting
