# frozen_string_literal: true

# @api private
# @since 1.23.0
# rubocop:disable Metrics/ModuleLength
module RedisQueuedLocks::Acquirer::LockSeries::LogVisitor
  # rubocop:disable Metrics/ClassLength
  class << self
    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_keys [Array<String>]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol] The mode of the lock series (`:read` or `:write`).
    # @param priority [Integer] The lock request priority of the series.
    # @return [void]
    #
    # @api private
    # @since 1.23.0
    def start_lock_series_obtaining(
      logger,
      log_sampled,
      lock_keys,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode,
      priority
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.start_lock_series_obtaining] " \
        "lock_keys => '#{lock_keys.inspect}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "priority => #{priority}"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_keys [Array<String>]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol] The mode of the lock series (`:read` or `:write`).
    # @param priority [Integer] The lock request priority of the series.
    # @return [void]
    #
    # @api private
    # @since 1.23.0
    def start_try_to_lock_series_cycle(
      logger,
      log_sampled,
      lock_keys,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode,
      priority
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.start_try_to_lock_series_cycle] " \
        "lock_keys => '#{lock_keys.inspect}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "priority => #{priority}"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_keys [Array<String>]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol] The mode of the lock series (`:read` or `:write`).
    # @param priority [Integer] The lock request priority of the series.
    # @return [void]
    #
    # @api private
    # @since 1.23.0
    def dead_score_reached__reset_series_position(
      logger,
      log_sampled,
      lock_keys,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode,
      priority
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.dead_score_reached__reset_series_position] " \
        "lock_keys => '#{lock_keys.inspect}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "priority => #{priority}"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String] The lock of the series.
    # @param lock_keys [Array<String>] All locks of the series.
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param acq_time [Numeric]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol] The mode of the lock series (`:read` or `:write`).
    # @param priority [Integer] The lock request priority of the series.
    # @return [void]
    #
    # @api private
    # @since 1.23.0
    def lock_series_intermediate_lock_obtained(
      logger,
      log_sampled,
      lock_key,
      lock_keys,
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
        "[redis_queued_locks.lock_series_intermediate_lock_obtained] " \
        "lock_key => '#{lock_key}' " \
        "lock_keys => '#{lock_keys.inspect}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "priority => #{priority} " \
        "acq_time => #{acq_time} (ms)"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String] The lock of the series.
    # @param lock_keys [Array<String>] All locks of the series.
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param acq_time [Numeric]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol] The mode of the lock series (`:read` or `:write`).
    # @param priority [Integer] The lock request priority of the series.
    # @return [void]
    #
    # @api private
    # @since 1.23.0
    def lock_series_lock_obtained(
      logger,
      log_sampled,
      lock_key,
      lock_keys,
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
        "[redis_queued_locks.lock_series_lock_obtained] " \
        "lock_key => '#{lock_key}' " \
        "lock_keys => '#{lock_keys.inspect}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "priority => #{priority} " \
        "acq_time => #{acq_time} (ms)"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_keys [Array<String>]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param acq_time [Numeric]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol] The mode of the lock series (`:read` or `:write`).
    # @param priority [Integer] The lock request priority of the series.
    # @param reentrant_lock_keys [Array<String>]
    #   The locks of the series that are obtained by the outer logic of the current acquirer.
    # @return [void]
    #
    # @api private
    # @since 1.23.0
    def lock_series_obtained(
      logger,
      log_sampled,
      lock_keys,
      queue_ttl,
      acquirer_id,
      host_id,
      acq_time,
      access_strategy,
      rw_mode,
      priority,
      reentrant_lock_keys
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.lock_series_obtained] " \
        "lock_keys => '#{lock_keys.inspect}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "priority => #{priority} " \
        "acq_time => #{acq_time} (ms) " \
        "reentrant_lock_keys => '#{reentrant_lock_keys.inspect}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String] The lock that blocks the series.
    # @param lock_keys [Array<String>] All locks of the series.
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param acq_time [Numeric]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol] The mode of the lock series (`:read` or `:write`).
    # @param priority [Integer] The lock request priority of the series.
    # @param result [Symbol] The failure result (`:timeout_reached`, `:retry_limit_reached`, ...).
    # @return [void]
    #
    # @api private
    # @since 1.23.0
    def lock_series_lock_obtaining_failed(
      logger,
      log_sampled,
      lock_key,
      lock_keys,
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
        "[redis_queued_locks.lock_series_lock_obtaining_failed] " \
        "lock_key => '#{lock_key}' " \
        "lock_keys => '#{lock_keys.inspect}' " \
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

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_keys [Array<String>]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param acq_time [Numeric]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol] The mode of the lock series (`:read` or `:write`).
    # @param priority [Integer] The lock request priority of the series.
    # @param result [Symbol] The failure result (`:timeout_reached`, `:retry_limit_reached`, ...).
    # @param failed_lock_key [String,NilClass]
    #   The lock of the series that blocks the series (`nil`: unknown, an attempt was not finished
    #   or some lock state was changed during the attempt).
    # @return [void]
    #
    # @api private
    # @since 1.23.0
    def lock_series_obtaining_failed(
      logger,
      log_sampled,
      lock_keys,
      queue_ttl,
      acquirer_id,
      host_id,
      acq_time,
      access_strategy,
      rw_mode,
      priority,
      result,
      failed_lock_key
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.lock_series_obtaining_failed] " \
        "lock_keys => '#{lock_keys.inspect}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "priority => #{priority} " \
        "acq_time => #{acq_time} (ms) " \
        "result => '#{result}' " \
        "failed_lock_key => '#{failed_lock_key}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_keys [Array<String>]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol] The mode of the lock series (`:read` or `:write`).
    # @param priority [Integer] The lock request priority of the series.
    # @return [void]
    #
    # @api private
    # @since 1.23.0
    def dequeue_from_lock_series_queues(
      logger,
      log_sampled,
      lock_keys,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode,
      priority
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.dequeue_from_lock_series_queues] " \
        "lock_keys => '#{lock_keys.inspect}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "priority => #{priority}"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_keys [Array<String>]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol] The mode of the lock series (`:read` or `:write`).
    # @param priority [Integer] The lock request priority of the series.
    # @return [void]
    #
    # @api private
    # @since 1.23.0
    def expire_lock_series(
      logger,
      log_sampled,
      lock_keys,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode,
      priority
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.expire_lock_series] " \
        "lock_keys => '#{lock_keys.inspect}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "priority => #{priority}"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_keys [Array<String>]
    #   The extended reentrant locks of the series (`:extendable_work_through`).
    # @param decreased_ttl [Integer] In milliseconds.
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol] The mode of the lock series (`:read` or `:write`).
    # @param priority [Integer] The lock request priority of the series.
    # @return [void]
    #
    # @api private
    # @since 1.23.0
    def decrease_lock_series(
      logger,
      log_sampled,
      lock_keys,
      decreased_ttl,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode,
      priority
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.decrease_lock_series] " \
        "lock_keys => '#{lock_keys.inspect}' " \
        "decreased_ttl => #{decreased_ttl} " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "priority => #{priority}"
      end rescue nil
    end
  end
  # rubocop:enable Metrics/ClassLength
end
# rubocop:enable Metrics/ModuleLength
