# frozen_string_literal: true

# @api private
# @since 1.7.0
module RedisQueuedLocks::Acquier::AcquireLock::DequeueFromLockQueue
  require_relative 'dequeue_from_lock_queue/log_visitor'

  # @param redis [RedisClient]
  # @param logger [::Logger,#debug]
  # @param lock_key [String]
  # @param lock_key_queue [String]
  # @param queue_ttl [Integer]
  # @param acquier_id [String]
  # @param log_sampled [Boolean]
  # @param instr_sampled [Boolean]
  # @return [Hash<Symbol,Any>] Format: { ok: true/false, result: Any }
  #
  # @api private
  # @since 1.7.0
  def dequeue_from_lock_queue(
    redis,
    logger,
    lock_key,
    lock_key_queue,
    queue_ttl,
    acquier_id,
    log_sampled,
    instr_sampled
  )
    result = redis.call('ZREM', lock_key_queue, acquier_id)
    LogVisitor.dequeue_from_lock_queue(logger, log_sampled, lock_key, queue_ttl, acquier_id)
    RedisQueuedLocks::Data[ok: true, result: result]
  end
end
