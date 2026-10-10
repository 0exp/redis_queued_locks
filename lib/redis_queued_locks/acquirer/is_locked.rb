# frozen_string_literal: true

# @api private
# @since 1.0.0
# @version 1.18.0
module RedisQueuedLocks::Acquirer::IsLocked
  class << self
    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @return [Boolean] Is the lock obtained by a writer or by any reader (live read lock).
    #
    # @api private
    # @since 1.0.0
    # @version 1.18.0
    def locked?(redis_client, lock_name)
      lock_key = RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
      lock_readers_key = RedisQueuedLocks::Resource.prepare_lock_readers(lock_name)

      # @type var result: [Integer, Array[String], Array[[String, Float]]]
      result = redis_client.pipelined do |pipeline|
        pipeline.call('EXISTS', lock_key)
        pipeline.call('TIME')
        pipeline.call('ZRANGE', lock_readers_key, '-1', '-1', 'WITHSCORES')
      end

      # NOTE: write lock
      return true if result[0] == 1

      # NOTE: (RW) read lock (expired read locks can live in the readers registry till the cleanup)
      longest_read_lock = result[2].first
      longest_read_lock != nil &&
        longest_read_lock[1] > RedisQueuedLocks::Resource.redis_time_ms(result[1])
    end
  end
end
