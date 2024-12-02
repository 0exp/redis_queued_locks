# frozen_string_literal: true

# @api private
# @since 1.7.0
module RedisQueuedLocks::Acquirer::AcquireLock::DequeueFromLockQueue
  require_relative 'dequeue_from_lock_queue/log_visitor'

  # @param redis [RedisClient]
  # @param logger [::Logger,#debug]
  # @param lock_key [String]
  # @param lock_key_queue [String]
  # @param queue_ttl [Integer]
  # @param acquirer_id [String]
  # @param host_id [String]
  # @param access_strategy [Symbol]
  # @param log_sampled [Boolean]
  # @param instr_sampled [Boolean]
  # @return [Hash<Symbol,Any>] Format: { ok: true/false, result: Integer }
  #
  # @api private
  # @since 1.7.0
  # @version 1.9.0
  def dequeue_from_lock_queue(
    redis,
    logger,
    lock_key,
    lock_key_queue,
    queue_ttl,
    acquirer_id,
    host_id,
    access_strategy,
    log_sampled,
    instr_sampled
  )
    # @type var result: Integer
    result = redis.call('ZREM', lock_key_queue, acquirer_id)

    LogVisitor.dequeue_from_lock_queue(
      logger, log_sampled,
      lock_key, queue_ttl, acquirer_id, host_id, access_strategy
    )

    { ok: true, result: result }
  end
end
