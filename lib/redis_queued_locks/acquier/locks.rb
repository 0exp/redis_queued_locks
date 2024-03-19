# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Acquier::Locks
  class << self
    # @param redis_client [RedisClient]
    # @option scan_size [Integer]
    # @return [Set<String>]
    #
    # @api private
    # @since 0.1.0
    def locks(redis_client, scan_size:)
      Set.new.tap do |lock_keys|
        redis_client.scan(
          'MATCH',
          RedisQueuedLocks::Resource::LOCK_PATTERN,
          count: scan_size
        ) do |lock_key|
          # TODO: reduce unnecessary iterations
          lock_keys.add(lock_key)
        end
      end
    end
  end
end
