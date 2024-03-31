# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Acquier::ClearDeadRequests
  class << self
    # @param redis_client [RedisClient]
    # @param scan_size [Integer]
    # @param dead_ttl [Integer] In milliseconds
    # @param logger [::Logger,#debug]
    # @param instrumenter [#notify]
    # @param instrument [NilClass,Any]
    # @return [Hash<Symbol,Boolean|Hash<Symbol,Set<String>>>]
    #
    # @api private
    # @since 0.1.0
    def clear_dead_requests(redis_client, scan_size, dead_ttl, logger, instrumenter, instrument)
      dead_score = Time.now.to_f - dead_ttl

      result = Set.new do |processed_queues|
        redis_client.with do |rconn|
          each_lock_queue(rconn, scan_size) do |lock_queue|
            rconn.call('ZREMRANGEBYSCORE', lock_queue, '-inf', dead_score)
            processed_queues << lock_queue
          end
        end
      end

      RedisQueuedLocks::Data[ok: true, result: { processed_queues: result }]
    end

    private

    # @param redis_client [RedisClient]
    # @param scan_size [Integer]
    # @yield [lock_queue]
    # @yieldparam lock_queue [String]
    # @yieldreturn [void]
    # @return [Enumerator]
    #
    # @api private
    # @since 0.1.0
    def each_lock_queue(redis_client, scan_size, &block)
      redis_client.scan(
        'MATCH',
        RedisQueuedLocks::Resource::LOCK_QUEUE_PATTERN,
        count: scan_size,
        &block
      )
    end
  end
end
