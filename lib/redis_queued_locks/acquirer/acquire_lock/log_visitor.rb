# frozen_string_literal: true

# @api private
# @since 1.7.0
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
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def start_lock_obtaining(
      logger,
      log_sampled,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.start_lock_obtaining] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def start_try_to_lock_cycle(
      logger,
      log_sampled,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.start_try_to_lock_cycle] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def dead_score_reached__reset_acquirer_position(
      logger,
      log_sampled,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.dead_score_reached__reset_acquirer_position] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}'"
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
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def extendable_reentrant_lock_obtained(
      logger,
      log_sampled,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      acq_time,
      access_strategy
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.extendable_reentrant_lock_obtained] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "host_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
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
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def reentrant_lock_obtained(
      logger,
      log_sampled,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      acq_time,
      access_strategy
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.reentrant_lock_obtained] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
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
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def lock_obtained(
      logger,
      log_sampled,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      acq_time,
      access_strategy
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.lock_obtained] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "acq_time => #{acq_time} (ms)"
      end rescue nil
    end
  end
  # rubocop:enable Metrics/ClassLength
end
# rubocop:enable Metrics/ModuleLength
