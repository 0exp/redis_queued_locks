# frozen_string_literal: true

# @api private
# @since 1.7.0
module RedisQueuedLocks::Acquirer::AcquireLock::InstrVisitor
  class << self
    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String]
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
    # @version 1.9.0
    def extendable_reentrant_lock_obtained(
      instrumenter,
      instr_sampled,
      lock_key,
      ttl,
      acq_id,
      hst_id,
      ts,
      acq_time,
      instrument
    )
      return unless instr_sampled
      instrumenter.notify('redis_queued_locks.extendable_reentrant_lock_obtained', {
        lock_key:, ttl:, acq_id:, hst_id:, ts:, acq_time:, instrument:
      }) rescue nil
    end

    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String]
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
    # @version 1.9.0
    def reentrant_lock_obtained(
      instrumenter,
      instr_sampled,
      lock_key,
      ttl,
      acq_id,
      hst_id,
      ts,
      acq_time,
      instrument
    )
      return unless instr_sampled
      instrumenter.notify('redis_queued_locks.reentrant_lock_obtained', {
        lock_key:, ttl:, acq_id:, hst_id:, ts:, acq_time:, instrument:
      }) rescue nil
    end

    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String]
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
    # @version 1.9.0
    def lock_obtained(
      instrumenter,
      instr_sampled,
      lock_key,
      ttl,
      acq_id,
      hst_id,
      ts,
      acq_time,
      instrument
    )
      return unless instr_sampled
      instrumenter.notify('redis_queued_locks.lock_obtained', {
        lock_key:, ttl:, acq_id:, hst_id:, ts:, acq_time:, instrument:
      }) rescue nil
    end

    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String]
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
    # @version 1.9.0
    def reentrant_lock_hold_completes(
      instrumenter,
      instr_sampled,
      lock_key,
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
        hold_time:, ttl:, acq_id:, hst_id:, ts:, lock_key:, acq_time:, instrument:
      }) rescue nil
    end

    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String]
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
    # @version 1.9.0
    def lock_hold_and_release(
      instrumenter,
      instr_sampled,
      lock_key,
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
        hold_time:, ttl:, acq_id:, hst_id:, ts:, lock_key:, acq_time:, instrument:
      }) rescue nil
    end
  end
end
