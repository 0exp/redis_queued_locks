# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Acquier::Release
  # Realease the lock: clear the lock queue and expire the lock.
  #
  # @param redis [RedisClient]
  # @param lock_key [String]
  # @param lock_key_queue [String]
  # @return [void]
  #
  # @api private
  # @since 0.1.0
  def fully_release_lock(redis, lock_key, lock_key_queue)
    redis.multi do |transact|
      transact.call('ZREMRANGEBYSCORE', lock_key_queue, '-inf', '+inf')
      transact.call('EXPIRE', lock_key, '0')
    end
  end

  # Release all locks: clear all lock queus and expire all locks.
  #
  # @param redis [RedisClient]
  # @param batch_size [Integer]
  # @return [void]
  #
  # @api private
  # @since 0.1.0
  def fully_release_all_locks(redis, batch_size)
    # Step A: release all queus and their related locks
    redis.scan(
      'MATCH',
      RedisQueuedLocks::Resource::LOCK_QUEUE_PATTERN,
      count: batch_size
    ) do |lock_queue|
      redis.pipelined do |pipeline|
        pipeline.call('ZREMRANGEBYSCORE', lock_queue, '-inf', '+inf')
        pipeline.call('EXPIRE', RedisQueuedLocks::Resource.lock_key_from_queue(lock_queue))
      end
    end

    # Step B: release all locks
    redis.pipelined do |pipeline|
      redis.scan(
        'MATCH',
        RedisQueuedLocks::Resource::LOCK_PATTERN,
        count: batch_size
      ) do |lock_key|
        pipeline.call('EXPIRE', lock_key, '0')
      end
    end
  end
end
