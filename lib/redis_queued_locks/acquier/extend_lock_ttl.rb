# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Acquier::ExtendLockTTL
  class << self
    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @param milliseconds [Integer]
    # @param logger [#debug]
    # @return [?]
    #
    # @api private
    # @since 0.1.0
    def extend_lock_ttl(redis_client, lock_name, milliseconds, logger)
      # TODO: realize
    end
  end
end
