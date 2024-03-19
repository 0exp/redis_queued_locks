# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Acquier::Queues
  class << self
    # @param redis_client [RedisClient]
    # @param scan_size [Integer]
    # @return [Set<String>]
    #
    # @api private
    # @since 0.1.0
    def queues(redis_client, scan_size:)
      Set.new.tap do |lock_queues|
        redis_client.scan(
          'MATCH',
          RedisQueuedLocks::Resource::LOCK_QUEUE_PATTERN,
          count: scan_size
        ) do |lock_queue|
          # TODO: reduce unnecessary iterations
          lock_queues.add(lock_queue)
        end
      end
    end
  end
end
