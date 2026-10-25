# frozen_string_literal: true

# NOTE: Lock Series PoC
# rubocop:disable Metrics/ModuleLength, Metrics/ClassLength, Metrics/MethodLength
# @api private
# @since 1.16.0
# @version 1.22.0
module RedisQueuedLocks::Acquirer::LockSeriesPoC # steep:ignore
  require_relative 'lock_series_poc/log_visitor'
  require_relative 'lock_series_poc/instr_visitor'

  # @since 1.16.0
  extend RedisQueuedLocks::Acquirer::AcquireLock::YieldExpire

  class << self
    # @api private
    # @since 1.16.0
    # @version 1.22.0
    def lock_series_poc( # steep:ignore
      redis,
      lock_names,
      detailed_result:,
      process_id:,
      thread_id:,
      fiber_id:,
      ractor_id:,
      ttl:,
      queue_ttl:,
      lock_index_enabled:,
      lock_index_grace_period:,
      timeout:,
      timed:,
      retry_count:,
      retry_delay:,
      retry_jitter:,
      raise_errors:,
      instrumenter:,
      identity:,
      fail_fast:,
      meta:,
      detailed_acq_timeout_error:,
      instrument:,
      logger:,
      log_lock_try:,
      conflict_strategy:,
      read_write_mode:,
      access_strategy:,
      priority:,
      lock_priorities:,
      log_sampling_enabled:,
      log_sampling_percent:,
      log_sampler:,
      log_sample_this:,
      instr_sampling_enabled:,
      instr_sampling_percent:,
      instr_sampler:,
      instr_sample_this:,
      &block
    )
      # NOTE: (RW) the lock mode is the same for all locks of the series
      #   (see RedisQueuedLocks::Acquirer::AcquireLock for read_write_mode validations);
      # NOTE: the lock request priority is the same for all locks of the series too (validated
      #   below: the series logs and instrumentation report it);

      case meta
      when Hash, NilClass then nil
      else
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:meta` argument should be a type of NilClass or Hash, got #{meta.class}."
        )
      end

      # NOTE: Symbol keys are written to the lock data as Strings (the same check as in
      #   RedisQueuedLocks::Acquirer::AcquireLock);
      if meta.is_a?(::Hash) && (meta.any? do |key, _value|
        meta_key = key.is_a?(::Symbol) ? key.name : key
        meta_key == 'acq_id' ||
        meta_key == 'hst_id' ||
        meta_key == 'ts' ||
        meta_key == 'ini_ttl' ||
        meta_key == 'lock_key' ||
        meta_key == 'rem_ttl' ||
        meta_key == 'spc_ext_ttl' ||
        meta_key == 'spc_cnt' ||
        meta_key == 'l_spc_ext_ini_ttl' ||
        meta_key == 'l_spc_ext_ts' ||
        meta_key == 'l_spc_ts' ||
        meta_key == 'rw_mode'
      end)
        raise(
          RedisQueuedLocks::ArgumentError,
          '`:meta` keys can not overlap reserved lock data keys ' \
          '"acq_id", "hst_id", "ts", "ini_ttl", "lock_key", "rem_ttl", "spc_cnt", ' \
          '"spc_ext_ttl", "l_spc_ext_ini_ttl", "l_spc_ext_ts", "l_spc_ts", "rw_mode"'
        )
      end

      # NOTE: the series ttl is validated before the lock ttl calculation: each lock ttl of
      #   the series includes the retry delay and jitter (a non-positive series ttl can produce
      #   a positive lock ttl), the series ttl limits the `timed` block (the same check as in
      #   RedisQueuedLocks::Acquirer::AcquireLock);
      if !ttl.is_a?(::Integer) || ttl <= 0
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:ttl` argument should be a positive Integer, got #{ttl.inspect}."
        )
      end

      # NOTE: the retry delay and jitter are parts of the lock ttls of the series (validated before
      #   the lock ttl calculation; other options are validated by
      #   RedisQueuedLocks::Acquirer::AcquireLock on the first lock of the series, before any lock
      #   is obtained);
      if !retry_delay.is_a?(::Integer) || retry_delay < 0
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:retry_delay` argument should be a non-negative Integer, got #{retry_delay.inspect}."
        )
      end
      if !retry_jitter.is_a?(::Integer) || retry_jitter < 0
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:retry_jitter` argument should be a non-negative Integer, got #{retry_jitter.inspect}."
        )
      end

      # NOTE: the priority of the series is validated before the series logs and instrumentation:
      #   a priority name is resolved to its Integer priority (the series events report the Integer
      #   priority; the same check as in RedisQueuedLocks::Acquirer::AcquireLock);
      priority = lock_priorities.fetch(priority, priority) if priority.is_a?(::Symbol)
      if !priority.is_a?(::Integer) ||
         priority < RedisQueuedLocks::Resource::MIN_LOCK_PRIORITY ||
         priority > RedisQueuedLocks::Resource::MAX_LOCK_PRIORITY
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:priority` argument should be an Integer from " \
          "#{RedisQueuedLocks::Resource::MIN_LOCK_PRIORITY} to " \
          "#{RedisQueuedLocks::Resource::MAX_LOCK_PRIORITY} or a priority name of " \
          "`config['lock_priorities']` (#{lock_priorities.keys.map(&:inspect).join(', ')}), " \
          "got #{priority.inspect}."
        )
      end

      locks_count = lock_names.size

      lock_acquirement_operations = lock_names.each_with_index.map do |lock_name, position|
        lock_ttl =
          ttl * (locks_count - position) +
          retry_delay * (locks_count - position) +
          retry_jitter * (locks_count - position)

        { lock_name: lock_name, ttl: lock_ttl }
      end

      log_sampled = RedisQueuedLocks::Logging.should_log?(
        log_sampling_enabled,
        log_sample_this,
        log_sampling_percent,
        log_sampler
      )

      instr_sampled = RedisQueuedLocks::Instrument.should_instrument?(
        instr_sampling_enabled,
        instr_sample_this,
        instr_sampling_percent,
        instr_sampler
      )

      lock_keys_for_instrumentation = lock_names.map do |lock_name|
        RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
      end

      acquirer_id_for_instrumentation = RedisQueuedLocks::Resource.acquirer_identifier(
        process_id,
        thread_id,
        fiber_id,
        ractor_id,
        identity
      )

      host_id_for_instrumentation = RedisQueuedLocks::Resource.host_identifier(
        process_id,
        thread_id,
        ractor_id,
        identity
      )

      LogVisitor.start_lock_series_obtaining( # steep:ignore
        logger, log_sampled, lock_keys_for_instrumentation,
        queue_ttl, acquirer_id_for_instrumentation, host_id_for_instrumentation,
        access_strategy, read_write_mode, priority
      )

      acq_start_time = RedisQueuedLocks::Utilities.clock_gettime
      successfully_acquired_locks = [] # steep:ignore
      failed_locks_and_errors = {} # steep:ignore
      failed_on_lock = nil
      # NOTE: locks of the failed series are released once (exceptional or not)
      is_failed_series_released = false

      lock_acquirement_operations.map do |lock_operation_options|
        result =
          begin
            RedisQueuedLocks::Acquirer::AcquireLock.acquire_lock(
              redis,
              lock_operation_options[:lock_name],
              process_id:,
              thread_id:,
              fiber_id:,
              ractor_id:,
              ttl: lock_operation_options[:ttl],
              queue_ttl:,
              lock_index_enabled:,
              lock_index_grace_period:,
              timeout:,
              timed:,
              retry_count:,
              retry_delay:,
              retry_jitter:,
              raise_errors:,
              instrumenter:,
              identity:,
              fail_fast:,
              meta:,
              detailed_acq_timeout_error:,
              instrument:,
              logger:,
              log_lock_try:,
              conflict_strategy:,
              read_write_mode:,
              access_strategy:,
              priority:,
              lock_priorities:,
              log_sampling_enabled:,
              log_sampling_percent:,
              log_sampler:,
              log_sample_this:,
              instr_sampling_enabled:,
              instr_sampling_percent:,
              instr_sampler:,
              instr_sample_this:
            )
          rescue RedisQueuedLocks::LockAlreadyObtainedError,
                 RedisQueuedLocks::LockAcquirementIntermediateTimeoutError,
                 RedisQueuedLocks::LockAcquirementTimeoutError,
                 RedisQueuedLocks::LockAcquirementRetryLimitError,
                 RedisQueuedLocks::ConflictLockObtainError => error
            # NOTE: release all previously acquired locks if any next lock is already locked
            release_lock_series( # steep:ignore
              redis, read_write_mode, successfully_acquired_locks, acquirer_id_for_instrumentation
            )
            is_failed_series_released = true

            raise(error) if raise_errors
          end

        if result[:ok]
          successfully_acquired_locks << {
            lock_name: lock_operation_options[:lock_name],
            ok: result[:ok],
            result: result[:result]
          }
        else
          failed_on_lock = lock_operation_options[:lock_name]
          failed_locks_and_errors[lock_operation_options[:lock_name]] = result
          # NOTE: release all previously acquired locks
          #   (non-exceptional failure: raise_errors: false)
          unless is_failed_series_released
            release_lock_series( # steep:ignore
              redis, read_write_mode, successfully_acquired_locks, acquirer_id_for_instrumentation
            )
            is_failed_series_released = true
          end
          break
        end
      end

      if successfully_acquired_locks.size == lock_names.size &&
         successfully_acquired_locks.all? { |res| res[:ok] }
        acq_end_time = RedisQueuedLocks::Utilities.clock_gettime
        acq_time = ((acq_end_time - acq_start_time) / 1_000.0).ceil(2)
        ts = Time.now.to_f

        LogVisitor.lock_series_obtained( # steep:ignore
          logger, log_sampled, lock_keys_for_instrumentation,
          queue_ttl, acquirer_id_for_instrumentation, host_id_for_instrumentation,
          acq_time, access_strategy, read_write_mode, priority
        )

        InstrVisitor.lock_series_obtained( # steep:ignore
          instrumenter, instr_sampled, lock_keys_for_instrumentation, read_write_mode, priority,
          ttl, acquirer_id_for_instrumentation, host_id_for_instrumentation, ts, acq_time,
          instrument
        )

        yield_time = RedisQueuedLocks::Utilities.clock_gettime
        ttl_shift = (
          (yield_time - acq_end_time) / 1_000.0 -
          RedisQueuedLocks::Resource::REDIS_TIMESHIFT_ERROR
        ).ceil(2)

        yield_result = nil
        # @type var is_lock_manually_released: bool
        # @type var hold_time: Float | Integer

        begin
          yield_result = yield_expire( # steep:ignore
            redis,
            logger,
            lock_keys_for_instrumentation.last,
            RedisQueuedLocks::Resource.prepare_lock_readers(lock_names.last),
            RedisQueuedLocks::Resource.prepare_read_lock_key(
              lock_names.last, acquirer_id_for_instrumentation
            ),
            read_write_mode,
            acquirer_id_for_instrumentation,
            host_id_for_instrumentation,
            access_strategy,
            timed,
            ttl_shift,
            ttl,
            queue_ttl,
            meta,
            log_sampled,
            instr_sampled,
            false, # should_expire (expire manually)
            false, # should_decrease (expire manually)
            &block
          )
        ensure
          is_lock_manually_released = false

          # expire locks manually
          if block_given?
            release_lock_series( # steep:ignore
              redis, read_write_mode, successfully_acquired_locks, acquirer_id_for_instrumentation
            )
            is_lock_manually_released = true
          end

          rel_time = RedisQueuedLocks::Utilities.clock_gettime
          hold_time = ((rel_time - acq_end_time) / 1_000.0).ceil(2)
          ts = Time.now.to_f

          LogVisitor.expire_lock_series( # steep:ignore
            logger, log_sampled, lock_keys_for_instrumentation,
            queue_ttl, acquirer_id_for_instrumentation, host_id_for_instrumentation,
            access_strategy, read_write_mode, priority
          ) if is_lock_manually_released

          InstrVisitor.lock_series_hold_and_release( # steep:ignore
            instrumenter,
            instr_sampled,
            lock_keys_for_instrumentation,
            read_write_mode,
            priority,
            ttl,
            acquirer_id_for_instrumentation,
            host_id_for_instrumentation,
            ts,
            acq_time,
            hold_time,
            instrument
          ) if is_lock_manually_released
        end

        if detailed_result
          {
            yield_result: yield_result,
            locks_release_strategy: block_given? ? :immediate_release_after_yield : :redis_key_ttl,
            locks_released_at: block_given? ? ts : nil,
            locks_acq_time: acq_time,
            locks_hold_time: is_lock_manually_released ? hold_time : nil,
            lock_series: lock_names,
            rql_lock_series: lock_keys_for_instrumentation
          }
        else
          yield_result
        end
      else
        acquired_locks = successfully_acquired_locks.map { |state| state[:lock_name] }
        missing_locks = lock_names - acquired_locks

        {
          ok: false,
          result: {
            error: :failed_to_acquire_lock_series,
            detailed_errors: failed_locks_and_errors,
            lock_series: lock_names,
            acquired_locks:,
            missing_locks:,
            failed_on_lock:
          }
        }
      end
    end

    private

    # Releases locks of the series that are obtained by the series itself:
    #   - reentrant locks (already obtained by the outer logic of the current acquirer) are kept;
    #   - only locks of the current acquirer are released (owner check);
    #
    # @param redis [RedisClient]
    # @param read_write_mode [Symbol]
    # @param successfully_acquired_locks [Array<Hash<Symbol,Any>>]
    # @param acquirer_id [String]
    # @return [void]
    #
    # @api private
    # @since 1.18.0
    def release_lock_series( # steep:ignore
      redis, read_write_mode, successfully_acquired_locks, acquirer_id
    )
      lock_names = obtained_lock_names(successfully_acquired_locks) # steep:ignore

      if read_write_mode == :read
        release_read_lock_series(redis, lock_names, acquirer_id) # steep:ignore
      else
        release_write_lock_series(redis, lock_names, acquirer_id) # steep:ignore
      end
    end

    # Releases write locks of the given acquirer (compare-and-delete: the lock can be expired
    # and obtained by another acquirer when the series logic exceeds the lock ttl) in one
    # transaction for the whole series (three round trips: WATCH, lock owners, MULTI/EXEC):
    #   - an aborted transaction (one of the watched locks is changed) is retried with the locks
    #     that were still owned by the acquirer at the last check: the locks of other acquirers
    #     are neither deleted nor watched, so the retries converge;
    #
    # @param redis [RedisClient]
    # @param lock_names [Array<String>]
    # @param acquirer_id [String]
    # @return [void]
    #
    # @api private
    # @since 1.18.0
    # @version 1.21.0
    def release_write_lock_series(redis, lock_names, acquirer_id) # steep:ignore
      return if lock_names.empty?

      own_lock_keys = lock_names.map do |lock_name|
        RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
      end

      redis.with do |conn|
        until own_lock_keys.empty?
          released = conn.multi(watch: own_lock_keys) do |transaction|
            # NOTE: (pipeline layout) one reply (lock owner) per lock in the series order
            lock_owners = conn.pipelined do |pipeline|
              own_lock_keys.each { |lock_key| pipeline.call('HGET', lock_key, 'acq_id') }
            end
            own_lock_keys = own_lock_keys.select.with_index do |_lock_key, index|
              lock_owners[index] == acquirer_id
            end
            own_lock_keys.each { |lock_key| transaction.call('DEL', lock_key) }
          end
          # NOTE: `nil` => the transaction is aborted (a watched lock is changed) => retry
          break unless released == nil
        end
      rescue RedisQueuedLocks::LockAcquirementIntermediateTimeoutError,
             RedisQueuedLocks::TimedLockIntermediateTimeoutError,
             ::Timeout::ExitException
        # NOTE: (timeouts) an interrupted WATCH block (the internal timeouts and the user's
        #   `Timeout.timeout` without an exception class): the closed connection drops the WATCH
        #   state (redis-client sends `UNWATCH` only on `StandardError`);
        conn.close
        raise
      end
    end

    # Locks of the series that are obtained by the series itself (reentrant locks are obtained
    # by the outer logic of the current acquirer and should be released by it).
    #
    # @param successfully_acquired_locks [Array<Hash<Symbol,Any>>]
    # @return [Array<String>]
    #
    # @api private
    # @since 1.18.0
    def obtained_lock_names(successfully_acquired_locks) # steep:ignore
      successfully_acquired_locks.filter_map do |operation_result|
        operation_result[:lock_name] if operation_result[:result][:process] == :lock_obtaining
      end
    end

    # Releases read locks of the given acquirer (other readers are not affected).
    #
    # @param redis [RedisClient]
    # @param lock_names [Array<String>]
    # @param acquirer_id [String]
    # @return [void]
    #
    # @api private
    # @since 1.18.0
    def release_read_lock_series(redis, lock_names, acquirer_id) # steep:ignore
      return if lock_names.empty?

      redis.with do |conn|
        conn.multi do |transaction|
          lock_names.each do |lock_name|
            transaction.call(
              'ZREM', RedisQueuedLocks::Resource.prepare_lock_readers(lock_name), acquirer_id
            )
            transaction.call(
              'DEL', RedisQueuedLocks::Resource.prepare_read_lock_key(lock_name, acquirer_id)
            )
          end
        end
      end
    end
  end
end
# rubocop:enable Metrics/ModuleLength, Metrics/ClassLength, Metrics/MethodLength
