# frozen_string_literal: true

# NOTE: Lock Series PoC
# rubocop:disable all
# @api private
# @since 1.16.0
module RedisQueuedLocks::Acquirer::LockSeriesPoC # steep:ignore
  require_relative 'lock_series_poc/log_visitor'
  require_relative 'lock_series_poc/instr_visitor'

  # @sine 1.16.0
  extend RedisQueuedLocks::Acquirer::AcquireLock::YieldExpire

  class << self
    # @api private
    # @since 1.16.0
    # @version 1.18.0
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

      case meta
      when Hash, NilClass then nil
      else
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:meta` argument should be a type of NilClass or Hash, got #{meta.class}."
        )
      end

      if meta.is_a?(::Hash) && (meta.any? do |key, _value|
        key == 'acq_id' ||
        key == 'hst_id' ||
        key == 'ts' ||
        key == 'ini_ttl' ||
        key == 'lock_key' ||
        key == 'rem_ttl' ||
        key == 'spc_ext_ttl' ||
        key == 'spc_cnt' ||
        key == 'l_spc_ext_ini_ttl' ||
        key == 'l_spc_ext_ts' ||
        key == 'l_spc_ts' ||
        key == 'rw_mode'
      end)
        raise(
          RedisQueuedLocks::ArgumentError,
          '`:meta` keys can not overlap reserved lock data keys ' \
          '"acq_id", "hst_id", "ts", "ini_ttl", "lock_key", "rem_ttl", "spc_cnt", ' \
          '"spc_ext_ttl", "l_spc_ext_ini_ttl", "l_spc_ext_ts", "l_spc_ts", "rw_mode"'
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

      RedisQueuedLocks::Acquirer::LockSeriesPoC::LogVisitor.start_lock_series_obtaining( # steep:ignore
        logger, log_sampled, lock_keys_for_instrumentation,
        queue_ttl, acquirer_id_for_instrumentation, host_id_for_instrumentation, access_strategy
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
          # NOTE: release all previously acquired locks (non-exceptional failure: raise_errors: false)
          unless is_failed_series_released
            release_lock_series( # steep:ignore
              redis, read_write_mode, successfully_acquired_locks, acquirer_id_for_instrumentation
            )
            is_failed_series_released = true
          end
          break
        end
      end

      if (successfully_acquired_locks.size == lock_names.size && (successfully_acquired_locks.all? { |res| res[:ok] }))
        acq_end_time = RedisQueuedLocks::Utilities.clock_gettime
        acq_time = ((acq_end_time - acq_start_time) / 1_000.0).ceil(2)
        ts = Time.now.to_s

        RedisQueuedLocks::Acquirer::LockSeriesPoC::LogVisitor.lock_series_obtained( # steep:ignore
          logger, log_sampled, lock_keys_for_instrumentation,
          queue_ttl, acquirer_id_for_instrumentation, host_id_for_instrumentation,
          acq_time, access_strategy
        )

        RedisQueuedLocks::Acquirer::LockSeriesPoC::InstrVisitor.lock_series_obtained( # steep:ignore
          instrumenter, instr_sampled, lock_keys_for_instrumentation,
          ttl, acquirer_id_for_instrumentation, host_id_for_instrumentation, ts, acq_time, instrument
        )

        yield_time = RedisQueuedLocks::Utilities.clock_gettime
        ttl_shift = (
          (yield_time - acq_end_time) / 1_000.0 -
          RedisQueuedLocks::Resource::REDIS_TIMESHIFT_ERROR
        ).ceil(2)

        yield_result = nil
        is_lock_manually_released = nil
        hold_time = nil

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

          RedisQueuedLocks::Acquirer::LockSeriesPoC::LogVisitor.expire_lock_series( # steep:ignore
            logger, log_sampled, lock_keys_for_instrumentation,
            queue_ttl, acquirer_id_for_instrumentation, host_id_for_instrumentation, access_strategy
          ) if is_lock_manually_released

          RedisQueuedLocks::Acquirer::LockSeriesPoC::InstrVisitor.lock_series_hold_and_release( # steep:ignore
            instrumenter,
            instr_sampled,
            lock_keys_for_instrumentation,
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
            failed_on_lock:,
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
    def release_lock_series(redis, read_write_mode, successfully_acquired_locks, acquirer_id) # steep:ignore
      lock_names = obtained_lock_names(successfully_acquired_locks) # steep:ignore

      if read_write_mode == :read
        release_read_lock_series(redis, lock_names, acquirer_id) # steep:ignore
      else
        release_write_lock_series(redis, lock_names, acquirer_id) # steep:ignore
      end
    end

    # Releases write locks of the given acquirer (compare-and-delete: the lock can be expired
    # and obtained by another acquirer when the series logic exceeds the lock ttl).
    #
    # @param redis [RedisClient]
    # @param lock_names [Array<String>]
    # @param acquirer_id [String]
    # @return [void]
    #
    # @api private
    # @since 1.18.0
    def release_write_lock_series(redis, lock_names, acquirer_id) # steep:ignore
      return if lock_names.empty?

      redis.with do |conn|
        lock_names.each do |lock_name|
          lock_key = RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
          conn.multi(watch: [lock_key]) do |transaction|
            if conn.call('HGET', lock_key, 'acq_id') == acquirer_id
              transaction.call('DEL', lock_key)
            end
          end
        end
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
# rubocop:enable all
