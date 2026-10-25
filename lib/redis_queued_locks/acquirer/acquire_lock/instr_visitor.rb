# frozen_string_literal: true

# @api private
# @since 1.7.0
# @version 1.22.0
# rubocop:disable Metrics/ModuleLength
module RedisQueuedLocks::Acquirer::AcquireLock::InstrVisitor
  # rubocop:disable Metrics/ClassLength
  class << self
    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String]
    # @param rw_mode [Symbol]
    # @param ttl [Integer, NilClass]
    # @param acq_id [String]
    # @param hst_id [String]
    # @param ts [Numeric]
    # @param acq_time [Numeric]
    # @param instrument [NilClass,Any]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def extendable_reentrant_lock_obtained(
      instrumenter,
      instr_sampled,
      lock_key,
      rw_mode,
      ttl,
      acq_id,
      hst_id,
      ts,
      acq_time,
      instrument
    )
      return unless instr_sampled
      instrumenter.notify('redis_queued_locks.extendable_reentrant_lock_obtained', {
        lock_key:, rw_mode:, ttl:, acq_id:, hst_id:, ts:, acq_time:, instrument:
      }) rescue nil
    end

    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String]
    # @param rw_mode [Symbol]
    # @param ttl [Integer, NilClass]
    # @param acq_id [String]
    # @param hst_id [String]
    # @param ts [Numeric]
    # @param acq_time [Numeric]
    # @param instrument [NilClass,Any]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def reentrant_lock_obtained(
      instrumenter,
      instr_sampled,
      lock_key,
      rw_mode,
      ttl,
      acq_id,
      hst_id,
      ts,
      acq_time,
      instrument
    )
      return unless instr_sampled
      instrumenter.notify('redis_queued_locks.reentrant_lock_obtained', {
        lock_key:, rw_mode:, ttl:, acq_id:, hst_id:, ts:, acq_time:, instrument:
      }) rescue nil
    end

    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String]
    # @param rw_mode [Symbol]
    # @param priority [Integer] The lock request priority.
    # @param ttl [Integer, NilClass]
    # @param acq_id [String]
    # @param hst_id [String]
    # @param ts [Numeric]
    # @param acq_time [Numeric]
    # @param instrument [NilClass,Any]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.22.0
    def lock_obtained(
      instrumenter,
      instr_sampled,
      lock_key,
      rw_mode,
      priority,
      ttl,
      acq_id,
      hst_id,
      ts,
      acq_time,
      instrument
    )
      return unless instr_sampled
      instrumenter.notify('redis_queued_locks.lock_obtained', {
        lock_key:, rw_mode:, priority:, ttl:, acq_id:, hst_id:, ts:, acq_time:, instrument:
      }) rescue nil
    end

    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String]
    # @param rw_mode [Symbol]
    # @param ttl [Integer, NilClass]
    # @param acq_id [String]
    # @param hst_id [String]
    # @param ts [Numeric]
    # @param acq_time [Numeric]
    # @param hold_time [Numeric]
    # @param instrument [NilClass,Any]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def reentrant_lock_hold_completes(
      instrumenter,
      instr_sampled,
      lock_key,
      rw_mode,
      ttl,
      acq_id,
      hst_id,
      ts,
      acq_time,
      hold_time,
      instrument
    )
      return unless instr_sampled
      instrumenter.notify('redis_queued_locks.reentrant_lock_hold_completes', {
        hold_time:, ttl:, acq_id:, hst_id:, ts:, lock_key:, rw_mode:, acq_time:, instrument:
      }) rescue nil
    end

    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String]
    # @param rw_mode [Symbol]
    # @param priority [Integer] The lock request priority.
    # @param ttl [Integer, NilClass]
    # @param acq_id [String]
    # @param hst_id [String]
    # @param ts [Numeric]
    # @param acq_time [Numeric]
    # @param hold_time [Numeric]
    # @param instrument [NilClass,Any]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.22.0
    def lock_hold_and_release(
      instrumenter,
      instr_sampled,
      lock_key,
      rw_mode,
      priority,
      ttl,
      acq_id,
      hst_id,
      ts,
      acq_time,
      hold_time,
      instrument
    )
      return unless instr_sampled
      instrumenter.notify('redis_queued_locks.lock_hold_and_release', {
        hold_time:, ttl:, acq_id:, hst_id:, ts:, lock_key:, rw_mode:, priority:, acq_time:,
        instrument:
      }) rescue nil
    end

    # The lock is not obtained (the failure result of `#lock`/`#lock!`: the timeout, the retry
    # limit, `fail_fast`, the dead lock or the lock upgrade conflict).
    #
    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String]
    # @param rw_mode [Symbol]
    # @param priority [Integer] The lock request priority.
    # @param ttl [Integer]
    # @param acq_id [String]
    # @param hst_id [String]
    # @param ts [Numeric]
    # @param acq_time [Numeric]
    # @param result [Symbol] The failure result (`:timeout_reached`, `:retry_limit_reached`, ...).
    # @param instrument [NilClass,Any]
    # @return [void]
    #
    # @api private
    # @since 1.21.0
    # @version 1.22.0
    def lock_obtaining_failed(
      instrumenter,
      instr_sampled,
      lock_key,
      rw_mode,
      priority,
      ttl,
      acq_id,
      hst_id,
      ts,
      acq_time,
      result,
      instrument
    )
      return unless instr_sampled
      instrumenter.notify('redis_queued_locks.lock_obtaining_failed', {
        lock_key:, rw_mode:, priority:, ttl:, acq_id:, hst_id:, ts:, acq_time:, result:,
        instrument:
      }) rescue nil
    end
  end
  # rubocop:enable Metrics/ClassLength
end
# rubocop:enable Metrics/ModuleLength
