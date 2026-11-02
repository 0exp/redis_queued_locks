# frozen_string_literal: true

# @api private
# @since 1.24.0
# rubocop:disable Metrics/ModuleLength
module RedisQueuedLocks::LockKeeper::LogVisitor
  # rubocop:disable Metrics/ClassLength
  class << self
    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String]
    # @param rw_mode [Symbol]
    # @param ext_ttl [Integer]
    # @param rem_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @return [void]
    #
    # @api private
    # @since 1.24.0
    def lock_auto_extended(
      logger,
      log_sampled,
      lock_key,
      rw_mode,
      ext_ttl,
      rem_ttl,
      acquirer_id,
      host_id
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.lock_auto_extended] " \
        "lock_key => '#{lock_key}' " \
        "rw_mode => '#{rw_mode}' " \
        "ext_ttl => #{ext_ttl} " \
        "rem_ttl => #{rem_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String]
    # @param rw_mode [Symbol]
    # @param ext_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param error [String] The class name of the error.
    # @return [void]
    #
    # @api private
    # @since 1.24.0
    def lock_auto_extension_failed(
      logger,
      log_sampled,
      lock_key,
      rw_mode,
      ext_ttl,
      acquirer_id,
      host_id,
      error
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.lock_auto_extension_failed] " \
        "lock_key => '#{lock_key}' " \
        "rw_mode => '#{rw_mode}' " \
        "ext_ttl => #{ext_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "error => '#{error}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String]
    # @param rw_mode [Symbol]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param hold_time [Integer]
    # @return [void]
    #
    # @api private
    # @since 1.24.0
    def auto_extended_lock_lost(
      logger,
      log_sampled,
      lock_key,
      rw_mode,
      acquirer_id,
      host_id,
      hold_time
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.auto_extended_lock_lost] " \
        "lock_key => '#{lock_key}' " \
        "rw_mode => '#{rw_mode}' " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "hold_time => #{hold_time}"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String]
    # @param rw_mode [Symbol]
    # @param max_hold_time [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @return [void]
    #
    # @api private
    # @since 1.24.0
    def lock_hold_limit_reached(
      logger,
      log_sampled,
      lock_key,
      rw_mode,
      max_hold_time,
      acquirer_id,
      host_id
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.lock_hold_limit_reached] " \
        "lock_key => '#{lock_key}' " \
        "rw_mode => '#{rw_mode}' " \
        "max_hold_time => #{max_hold_time} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String]
    # @param rw_mode [Symbol]
    # @param hold_time [Integer] The requested time (`RedisQueuedLocks::LockLease#hold_for`).
    # @param rem_hold_time [Integer,NilClass] The time left till the hold limit, `nil`: no limit.
    # @param ext_ttl [Integer]
    # @param rem_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @return [void]
    #
    # @api private
    # @since 1.24.0
    def lock_hold_limit_extended(
      logger,
      log_sampled,
      lock_key,
      rw_mode,
      hold_time,
      rem_hold_time,
      ext_ttl,
      rem_ttl,
      acquirer_id,
      host_id
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.lock_hold_limit_extended] " \
        "lock_key => '#{lock_key}' " \
        "rw_mode => '#{rw_mode}' " \
        "hold_time => #{hold_time} " \
        "rem_hold_time => #{rem_hold_time.inspect} " \
        "ext_ttl => #{ext_ttl} " \
        "rem_ttl => #{rem_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}'"
      end rescue nil
    end
  end
  # rubocop:enable Metrics/ClassLength
end
# rubocop:enable Metrics/ModuleLength
