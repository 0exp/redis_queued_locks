# frozen_string_literal: true

# @api private
# @since 1.24.0
module RedisQueuedLocks::LockKeeper::InstrVisitor
  class << self
    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String]
    # @param rw_mode [Symbol]
    # @param ext_ttl [Integer]
    # @param rem_ttl [Integer]
    # @param acq_id [String]
    # @param hst_id [String]
    # @param instrument [NilClass,Any]
    # @return [void]
    #
    # @api private
    # @since 1.24.0
    def lock_auto_extended(
      instrumenter,
      instr_sampled,
      lock_key,
      rw_mode,
      ext_ttl,
      rem_ttl,
      acq_id,
      hst_id,
      instrument
    )
      return unless instr_sampled

      instrumenter.notify('redis_queued_locks.lock_auto_extended', {
        lock_key:, rw_mode:, ext_ttl:, rem_ttl:, acq_id:, hst_id:, at: Time.now.to_f, instrument:
      }) rescue nil
    end

    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String]
    # @param rw_mode [Symbol]
    # @param ext_ttl [Integer]
    # @param acq_id [String]
    # @param hst_id [String]
    # @param error [String] The class name of the error.
    # @param instrument [NilClass,Any]
    # @return [void]
    #
    # @api private
    # @since 1.24.0
    def lock_auto_extension_failed(
      instrumenter,
      instr_sampled,
      lock_key,
      rw_mode,
      ext_ttl,
      acq_id,
      hst_id,
      error,
      instrument
    )
      return unless instr_sampled

      instrumenter.notify('redis_queued_locks.lock_auto_extension_failed', {
        lock_key:, rw_mode:, ext_ttl:, acq_id:, hst_id:, error:, at: Time.now.to_f, instrument:
      }) rescue nil
    end

    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String]
    # @param rw_mode [Symbol]
    # @param acq_id [String]
    # @param hst_id [String]
    # @param hold_time [Integer]
    # @param instrument [NilClass,Any]
    # @return [void]
    #
    # @api private
    # @since 1.24.0
    def auto_extended_lock_lost(
      instrumenter,
      instr_sampled,
      lock_key,
      rw_mode,
      acq_id,
      hst_id,
      hold_time,
      instrument
    )
      return unless instr_sampled

      instrumenter.notify('redis_queued_locks.auto_extended_lock_lost', {
        lock_key:, rw_mode:, acq_id:, hst_id:, hold_time:, at: Time.now.to_f, instrument:
      }) rescue nil
    end

    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String]
    # @param rw_mode [Symbol]
    # @param max_hold_time [Integer]
    # @param acq_id [String]
    # @param hst_id [String]
    # @param instrument [NilClass,Any]
    # @return [void]
    #
    # @api private
    # @since 1.24.0
    def lock_hold_limit_reached(
      instrumenter,
      instr_sampled,
      lock_key,
      rw_mode,
      max_hold_time,
      acq_id,
      hst_id,
      instrument
    )
      return unless instr_sampled

      instrumenter.notify('redis_queued_locks.lock_hold_limit_reached', {
        lock_key:, rw_mode:, max_hold_time:, acq_id:, hst_id:, at: Time.now.to_f, instrument:
      }) rescue nil
    end

    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String]
    # @param rw_mode [Symbol]
    # @param hold_time [Integer]
    #   The requested time (`RedisQueuedLocks::LockKeeper::LockLease#hold_for`).
    # @param rem_hold_time [Integer,NilClass] The time left till the hold limit, `nil`: no limit.
    # @param ext_ttl [Integer]
    # @param rem_ttl [Integer]
    # @param acq_id [String]
    # @param hst_id [String]
    # @param instrument [NilClass,Any]
    # @return [void]
    #
    # @api private
    # @since 1.24.0
    def lock_hold_limit_extended(
      instrumenter,
      instr_sampled,
      lock_key,
      rw_mode,
      hold_time,
      rem_hold_time,
      ext_ttl,
      rem_ttl,
      acq_id,
      hst_id,
      instrument
    )
      return unless instr_sampled

      instrumenter.notify('redis_queued_locks.lock_hold_limit_extended', {
        lock_key:,
        rw_mode:,
        hold_time:,
        rem_hold_time:,
        ext_ttl:,
        rem_ttl:,
        acq_id:,
        hst_id:,
        at: Time.now.to_f,
        instrument:
      }) rescue nil
    end
  end
end
