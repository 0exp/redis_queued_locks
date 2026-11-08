# frozen_string_literal: true

# @api private
# @since 1.7.0
# @version 1.24.0
module RedisQueuedLocks::Acquirer::AcquireLock::DequeueFromLockQueue
  require_relative 'dequeue_from_lock_queue/log_visitor'

  # @param redis [RedisClient]
  # @param logger [::Logger,#debug]
  # @param lock_key [String]
  # @param rw_mode [Symbol]
  # @param lock_key_queue [String] Queue of write lock requests.
  # @param read_lock_key_queue [String] Queue of read lock requests.
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
  # @version 1.18.0
  def dequeue_from_lock_queue(
    redis,
    logger,
    lock_key,
    rw_mode,
    lock_key_queue,
    read_lock_key_queue,
    queue_ttl,
    acquirer_id,
    host_id,
    access_strategy,
    log_sampled,
    instr_sampled
  )
    # NOTE: the request lives in the queue of the requested mode
    request_queue = (rw_mode == :read) ? read_lock_key_queue : lock_key_queue

    # @type var result: Integer
    result = redis.call('ZREM', request_queue, acquirer_id)

    LogVisitor.dequeue_from_lock_queue(
      logger, log_sampled,
      lock_key, queue_ttl, acquirer_id, host_id, access_strategy, rw_mode
    )

    { ok: true, result: result }
  end

  # Releases the lock of an interrupted acquirement whose obtaining transaction can be applied by
  # Redis without the reply (the acquirement timeout comes while the reply is read or right after
  # it, before the lock is reported as obtained):
  #   - only the lock of the current acquirer is released (the transaction can be aborted: the lock
  #     can be held by another acquirer): write lock: the owner-checked release script, read lock:
  #     `ZREM` of the own reader + `DEL` of the own read lock data;
  #   - the lock index entry is kept (releases never touch the lock index);
  #   - logged as `expire_lock` (the requested mode is the held one: the obtaining transaction
  #     obtains the requested mode);
  #
  # @param redis [RedisClient]
  # @param logger [::Logger,#debug]
  # @param lock_key [String]
  # @param rw_mode [Symbol]
  # @param lock_readers_key [String] Registry of read lock holders.
  # @param read_lock_key [String,NilClass] Read lock data of the current acquirer (read locks).
  # @param queue_ttl [Integer]
  # @param acquirer_id [String]
  # @param host_id [String]
  # @param access_strategy [Symbol]
  # @param log_sampled [Boolean]
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def release_unconfirmed_lock(
    redis,
    logger,
    lock_key,
    rw_mode,
    lock_readers_key,
    read_lock_key,
    queue_ttl,
    acquirer_id,
    host_id,
    access_strategy,
    log_sampled
  )
    if rw_mode == :read
      redis.multi do |transact|
        transact.call('ZREM', lock_readers_key, acquirer_id)
        transact.call('DEL', read_lock_key)
      end
    else
      # NOTE: EVAL signature -> <lua script>, (number of keys), *(keys), *(arguments)
      redis.call(
        'EVAL',
        RedisQueuedLocks::Acquirer::AcquireLock::YieldExpire::RELEASE_OWN_LOCK,
        1,
        lock_key,
        acquirer_id
      )
    end

    RedisQueuedLocks::Acquirer::AcquireLock::YieldExpire::LogVisitor.expire_lock(
      logger, log_sampled, lock_key, queue_ttl, acquirer_id, host_id, access_strategy, rw_mode
    )
  end
end
