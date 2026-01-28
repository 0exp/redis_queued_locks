# frozen_string_literal: true

# NOTE: Lock Series PoC
# steep:ignore
# @api private
# @since 1.16.1
module RedisQueuedLocks::Acquirer::LockSeriesPoC::InstrVisitor # steep:ignore
  class << self
    # NOTE: Lock Series PoC
    # @api private
    # @since 1.16.1
    def lock_series_obtained( # steep:ignore
      instrumenter,
      instr_sampled,
      lock_keys,
      ttl,
      acq_id,
      hst_id,
      ts,
      acq_time,
      instrument
    )
      return unless instr_sampled
      instrumenter.notify('redis_queued_locks.lock_series_obtained', {
        lock_keys:, ttl:, acq_id:, hst_id:, ts:, acq_time:, instrument:
      }) rescue nil
    end

    # NOTE: Lock Series PoC
    # @api private
    # @since 1.16.1
    def lock_series_hold_and_release( # steep:ignore
      instrumenter,
      instr_sampled,
      lock_keys,
      ttl,
      acq_id,
      hst_id,
      ts,
      acq_time,
      hold_time,
      instrument
    )
      return unless instr_sampled
      instrumenter.notify('redis_queued_locks.lock_series_hold_and_release', {
        lock_keys:, hold_time:, ttl:, acq_id:, hst_id:, ts:, acq_time:, instrument:
      }) # rescue nil
    end
  end
end
# steep:ignore
