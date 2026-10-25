# frozen_string_literal: true

# @api private
# @since 1.7.0
# @version 1.22.0
# rubocop:disable Metrics/ModuleLength
module RedisQueuedLocks::Acquirer::AcquireLock::LogVisitor
  # rubocop:disable Metrics/ClassLength
  class << self
    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def start_lock_obtaining(
      logger,
      log_sampled,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.start_lock_obtaining] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def start_try_to_lock_cycle(
      logger,
      log_sampled,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.start_try_to_lock_cycle] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def dead_score_reached__reset_acquirer_position(
      logger,
      log_sampled,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.dead_score_reached__reset_acquirer_position] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param acq_time [Numeric]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def extendable_reentrant_lock_obtained(
      logger,
      log_sampled,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      acq_time,
      access_strategy,
      rw_mode
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.extendable_reentrant_lock_obtained] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "acq_time => #{acq_time} (ms)"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param acq_time [Numeric]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def reentrant_lock_obtained(
      logger,
      log_sampled,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      acq_time,
      access_strategy,
      rw_mode
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.reentrant_lock_obtained] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "acq_time => #{acq_time} (ms)"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param acq_time [Numeric]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @param priority [Integer] The lock request priority.
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.22.0
    def lock_obtained(
      logger,
      log_sampled,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      acq_time,
      access_strategy,
      rw_mode,
      priority
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.lock_obtained] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "priority => #{priority} " \
        "acq_time => #{acq_time} (ms)"
      end rescue nil
    end

    # The lock is not obtained (the failure result of `#lock`/`#lock!`: the timeout, the retry
    # limit, `fail_fast`, the dead lock or the lock upgrade conflict).
    #
    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param acq_time [Numeric]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @param priority [Integer] The lock request priority.
    # @param result [Symbol] The failure result (`:timeout_reached`, `:retry_limit_reached`, ...).
    # @return [void]
    #
    # @api private
    # @since 1.21.0
    # @version 1.22.0
    def lock_obtaining_failed(
      logger,
      log_sampled,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      acq_time,
      access_strategy,
      rw_mode,
      priority,
      result
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.lock_obtaining_failed] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "priority => #{priority} " \
        "acq_time => #{acq_time} (ms) " \
        "result => '#{result}'"
      end rescue nil
    end
  end
  # rubocop:enable Metrics/ClassLength
end
# rubocop:enable Metrics/ModuleLength
