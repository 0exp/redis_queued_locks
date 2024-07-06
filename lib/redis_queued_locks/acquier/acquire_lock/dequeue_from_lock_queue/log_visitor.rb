# frozen_string_literal: true

# @api private
# @since 1.7.0
module RedisQueuedLocks::Acquier::AcquireLock::DequeueFromLockQueue::LogVisitor
  extend self

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
  def dequeue_from_lock_queue(
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
      "[redis_queued_locks.fail_fast_or_limits_reached_or_deadlock__dequeue] " \
      "lock_key => '#{lock_key}' " \
      "queue_ttl => #{queue_ttl} " \
      "acq_id => '#{acquier_id}' " \
      "hst_id => '#{host_id}' " \
      "acs_strat => '#{access_strategy}"
    end rescue nil
  end
end
