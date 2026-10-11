# frozen_string_literal: true

# @api private
# @since 1.0.0
# @version 1.18.0
module RedisQueuedLocks::Acquirer::IsQueued
  class << self
    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @return [Boolean] Are there any write or read lock requests.
    #
    # @api private
    # @since 1.0.0
    # @version 1.18.0
    def queued?(redis_client, lock_name)
      lock_key_queue = RedisQueuedLocks::Resource.prepare_lock_queue(lock_name)
      read_lock_key_queue = RedisQueuedLocks::Resource.prepare_read_lock_queue(lock_name)
      # NOTE: EXISTS returns the number of existing keys
      redis_client.call('EXISTS', lock_key_queue, read_lock_key_queue) > 0
    end
  end
end
