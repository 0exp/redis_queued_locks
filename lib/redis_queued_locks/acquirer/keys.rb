# frozen_string_literal: true

# @api private
# @since 1.0.0
module RedisQueuedLocks::Acquirer::Keys
  class << self
    # @param redis_client [RedisClient]
    # @option scan_size [Integer]
    # @return [Set<String>]
    #
    # @api private
    # @since 1.0.0
    def keys(redis_client, scan_size:)
      Set.new.tap do |keyset|
        # @type var keyset: Set[String]
        redis_client.scan(
          'MATCH',
          RedisQueuedLocks::Resource::KEY_PATTERN,
          count: scan_size
        ) do |key|
          keyset.add(key)
        end
      end
    end
  end
end
