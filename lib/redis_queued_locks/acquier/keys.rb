# frozen_string_literal: true

# @api private
# @since 1.0.0
module RedisQueuedLocks::Acquier::Keys
  class << self
    # @param redis_client [RedisClient]
    # @option scan_size [Integer]
    # @return [Array<String>]
    #
    # @api private
    # @since 1.0.0
    def keys(redis_client, scan_size:)
      Set.new.tap do |keys|
        redis_client.scan(
          'MATCH',
          RedisQueuedLocks::Resource::KEY_PATTERN,
          count: scan_size
        ) do |key|
          # TODO: reduce unnecessary iterations
          keys.add(key)
        end
      end
    end
  end
end
