# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Acquier::Release
  # Realease the lock: clear the lock queue and expire the lock.
  #
  # @param redis [RedisClient]
  # @param lock_key [String]
  # @param lock_key_queue [String]
  # @return [Hash<Symbol,Any>] Format: { ok: true/false, result: Any }
  #
  # @api private
  # @since 0.1.0
  def fully_release_lock(redis, lock_key, lock_key_queue)
    result = redis.multi do |transact|
      transact.call('ZREMRANGEBYSCORE', lock_key_queue, '-inf', '+inf')
      transact.call('EXPIRE', lock_key, '0')
    end

    RedisQueuedLocks::Data[ok: true, result:]
  end

  # Release all locks: clear all lock queus and expire all locks.
  #
  # @param redis [RedisClient]
  # @param batch_size [Integer]
  # @return [Hash<Symbol,Any>] Format: { ok: true/false, result: Any }
  #
  # @api private
  # @since 0.1.0
  def fully_release_all_locks(redis, batch_size)
    result = redis.pipelined do |pipeline|
      # Step A: release all queus and their related locks
      redis.scan(
        'MATCH',
        RedisQueuedLocks::Resource::LOCK_QUEUE_PATTERN,
        count: batch_size
      ) do |lock_queue|
        # TODO: reduce unnecessary iterations
        pipeline.call('ZREMRANGEBYSCORE', lock_queue, '-inf', '+inf')
        pipeline.call('EXPIRE', RedisQueuedLocks::Resource.lock_key_from_queue(lock_queue), '0')
      end

      # Step B: release all locks
      redis.scan(
        'MATCH',
        RedisQueuedLocks::Resource::LOCK_PATTERN,
        count: batch_size
      ) do |lock_key|
        # TODO: reduce unnecessary iterations
        pipeline.call('EXPIRE', lock_key, '0')
      end
    end

    rel_keys = result.count { |red_res| red_res == 0 }

    RedisQueuedLocks::Data[ok: true, result: { rel_keys: rel_keys }]
  end
end
