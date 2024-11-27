# frozen_string_literal: true

# @api private
# @since 1.7.0
module RedisQueuedLocks::Acquirer::AcquireLock::YieldExpire::LogVisitor
  class << self
    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquier_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def expire_lock(
      logger,
      log_sampled,
      lock_key,
      queue_ttl,
      acquier_id,
      host_id,
      access_strategy
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.expire_lock] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquier_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param lock_key [String]
    # @param decreased_ttl [Integer]
    # @param queue_ttl [Integer]
    # @param acquier_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def decrease_lock(
      logger,
      log_sampled,
      lock_key,
      decreased_ttl,
      queue_ttl,
      acquier_id,
      host_id,
      access_strategy
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.decrease_lock] " \
        "lock_key => '#{lock_key}' " \
        "decreased_ttl => #{decreased_ttl} " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquier_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}'"
      end rescue nil
    end
  end
end
