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

    { ok: true, result: }
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
    rel_queue_cnt = 0
    rel_lock_cnt = 0

    # Step A: release all queus and their related locks
    redis.scan(
      'MATCH',
      RedisQueuedLocks::Resource::LOCK_QUEUE_PATTERN,
      count: batch_size
    ) do |lock_queue|
      rel_queue_cnt += 1
      rel_lock_cnt += 1

      redis.pipelined do |pipeline|
        pipeline.call('ZREMRANGEBYSCORE', lock_queue, '-inf', '+inf')
        pipeline.call('EXPIRE', RedisQueuedLocks::Resource.lock_key_from_queue(lock_queue), '0')
      end
    end

    # Step B: release all locks
    redis.pipelined do |pipeline|
      redis.scan(
        'MATCH',
        RedisQueuedLocks::Resource::LOCK_PATTERN,
        count: batch_size
      ) do |lock_key|
        rel_lock_cnt += 1
        pipeline.call('EXPIRE', lock_key, '0')
      end
    end

    { ok: true, result: { rel_queue_cnt:, rel_lock_cnt: } }
  end
end
