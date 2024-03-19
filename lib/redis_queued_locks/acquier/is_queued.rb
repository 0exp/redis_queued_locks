# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Acquier::IsQueued
  class << self
    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @return [Boolean]
    #
    # @api private
    # @since 0.1.0
    def queued?(redis_client, lock_name)
      lock_key_queue = RedisQueuedLocks::Resource.prepare_lock_queue(lock_name)
      redis_client.call('EXISTS', lock_key_queue) == 1
    end
  end
end
