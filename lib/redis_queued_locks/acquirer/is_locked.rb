# frozen_string_literal: true

# @api private
# @since 1.0.0
module RedisQueuedLocks::Acquirer::IsLocked
  class << self
    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @return [Boolean]
    #
    # @api private
    # @since 1.0.0
    def locked?(redis_client, lock_name)
      lock_key = RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
      redis_client.call('EXISTS', lock_key) == 1
    end
  end
end
