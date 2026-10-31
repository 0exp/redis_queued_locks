# frozen_string_literal: true

# @api private
# @since 1.23.0
# rubocop:disable Metrics/ModuleLength
module RedisQueuedLocks::Acquirer::LockSeries::InstrVisitor
  # rubocop:disable Metrics/ClassLength
  class << self
    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String] The lock of the series.
    # @param lock_keys [Array<String>] All locks of the series.
    # @param rw_mode [Symbol] The mode of the lock series (`:read` or `:write`).
    # @param priority [Integer] The lock request priority of the series.
    # @param ttl [Integer]
    # @param acq_id [String]
    # @param hst_id [String]
    # @param ts [Numeric]
    # @param acq_time [Numeric]
    # @param instrument [NilClass,Any]
    # @return [void]
    #
    # @api private
    # @since 1.23.0
    def lock_series_intermediate_lock_obtained(
      instrumenter,
      instr_sampled,
      lock_key,
      lock_keys,
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
      instrumenter.notify('redis_queued_locks.lock_series_intermediate_lock_obtained', {
        lock_key:, lock_keys:, rw_mode:, priority:, ttl:, acq_id:, hst_id:, ts:, acq_time:,
        instrument:
      }) rescue nil
    end

    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String] The lock of the series.
    # @param lock_keys [Array<String>] All locks of the series.
    # @param rw_mode [Symbol] The mode of the lock series (`:read` or `:write`).
    # @param priority [Integer] The lock request priority of the series.
    # @param ttl [Integer]
    # @param acq_id [String]
    # @param hst_id [String]
    # @param ts [Numeric]
    # @param acq_time [Numeric]
    # @param instrument [NilClass,Any]
    # @return [void]
    #
    # @api private
    # @since 1.23.0
    def lock_series_lock_obtained(
      instrumenter,
      instr_sampled,
      lock_key,
      lock_keys,
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
      instrumenter.notify('redis_queued_locks.lock_series_lock_obtained', {
        lock_key:, lock_keys:, rw_mode:, priority:, ttl:, acq_id:, hst_id:, ts:, acq_time:,
        instrument:
      }) rescue nil
    end

    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_key [String] The lock that blocks the series.
    # @param lock_keys [Array<String>] All locks of the series.
    # @param rw_mode [Symbol] The mode of the lock series (`:read` or `:write`).
    # @param priority [Integer] The lock request priority of the series.
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
    # @since 1.23.0
    def lock_series_lock_obtaining_failed(
      instrumenter,
      instr_sampled,
      lock_key,
      lock_keys,
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
      instrumenter.notify('redis_queued_locks.lock_series_lock_obtaining_failed', {
        lock_key:, lock_keys:, rw_mode:, priority:, ttl:, acq_id:, hst_id:, ts:, acq_time:, result:,
        instrument:
      }) rescue nil
    end

    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_keys [Array<String>]
    # @param rw_mode [Symbol] The mode of the lock series (`:read` or `:write`).
    # @param priority [Integer] The lock request priority of the series.
    # @param ttl [Integer]
    # @param acq_id [String]
    # @param hst_id [String]
    # @param ts [Numeric]
    # @param acq_time [Numeric]
    # @param reentrant_lock_keys [Array<String>]
    #   The locks of the series that are obtained by the outer logic of the current acquirer.
    # @param instrument [NilClass,Any]
    # @return [void]
    #
    # @api private
    # @since 1.23.0
    def lock_series_obtained(
      instrumenter,
      instr_sampled,
      lock_keys,
      rw_mode,
      priority,
      ttl,
      acq_id,
      hst_id,
      ts,
      acq_time,
      reentrant_lock_keys,
      instrument
    )
      return unless instr_sampled
      instrumenter.notify('redis_queued_locks.lock_series_obtained', {
        lock_keys:, rw_mode:, priority:, ttl:, acq_id:, hst_id:, ts:, acq_time:,
        reentrant_lock_keys:, instrument:
      }) rescue nil
    end

    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_keys [Array<String>]
    # @param rw_mode [Symbol] The mode of the lock series (`:read` or `:write`).
    # @param priority [Integer] The lock request priority of the series.
    # @param ttl [Integer]
    # @param acq_id [String]
    # @param hst_id [String]
    # @param ts [Numeric]
    # @param acq_time [Numeric]
    # @param hold_time [Numeric]
    # @param reentrant_lock_keys [Array<String>]
    #   The locks of the series that are obtained by the outer logic of the current acquirer.
    # @param instrument [NilClass,Any]
    # @return [void]
    #
    # @api private
    # @since 1.23.0
    def lock_series_hold_and_release(
      instrumenter,
      instr_sampled,
      lock_keys,
      rw_mode,
      priority,
      ttl,
      acq_id,
      hst_id,
      ts,
      acq_time,
      hold_time,
      reentrant_lock_keys,
      instrument
    )
      return unless instr_sampled
      instrumenter.notify('redis_queued_locks.lock_series_hold_and_release', {
        lock_keys:, rw_mode:, priority:, hold_time:, ttl:, acq_id:, hst_id:, ts:, acq_time:,
        reentrant_lock_keys:, instrument:
      }) rescue nil
    end

    # @param instrumenter [#notify]
    # @param instr_sampled [Boolean]
    # @param lock_keys [Array<String>]
    # @param rw_mode [Symbol] The mode of the lock series (`:read` or `:write`).
    # @param priority [Integer] The lock request priority of the series.
    # @param ttl [Integer]
    # @param acq_id [String]
    # @param hst_id [String]
    # @param ts [Numeric]
    # @param acq_time [Numeric]
    # @param result [Symbol] The failure result (`:timeout_reached`, `:retry_limit_reached`, ...).
    # @param failed_lock_key [String,NilClass]
    #   The lock of the series that blocks the series (`nil`: unknown, an attempt was not finished
    #   or some lock state was changed during the attempt).
    # @param instrument [NilClass,Any]
    # @return [void]
    #
    # @api private
    # @since 1.23.0
    def lock_series_obtaining_failed(
      instrumenter,
      instr_sampled,
      lock_keys,
      rw_mode,
      priority,
      ttl,
      acq_id,
      hst_id,
      ts,
      acq_time,
      result,
      failed_lock_key,
      instrument
    )
      return unless instr_sampled
      instrumenter.notify('redis_queued_locks.lock_series_obtaining_failed', {
        lock_keys:, rw_mode:, priority:, ttl:, acq_id:, hst_id:, ts:, acq_time:, result:,
        failed_lock_key:, instrument:
      }) rescue nil
    end
  end
  # rubocop:enable Metrics/ClassLength
end
# rubocop:enable Metrics/ModuleLength
