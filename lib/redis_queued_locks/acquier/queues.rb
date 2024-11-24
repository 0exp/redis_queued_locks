# frozen_string_literal: true

# @api private
# @since 1.0.0
module RedisQueuedLocks::Acquier::Queues
  class << self
    # @param redis_client [RedisClient]
    # @option scan_size [Integer]
    # @option with_info [Boolean]
    # @return [Set<String>,Set<Hash<Symbol,Any>>]
    #
    # @api private
    # @since 1.0.0
    def queues(redis_client, scan_size:, with_info:)
      redis_client.with do |rconn|
        lock_queues = scan_queues(rconn, scan_size)
        with_info ? extract_queues_info(rconn, lock_queues) : lock_queues
      end
    end

    private

    # @param redis_client [RedisClient]
    # @param scan_size [Integer]
    # @return [Set<String>]
    #
    # @api private
    # @since 1.0.0
    def scan_queues(redis_client, scan_size)
      Set.new.tap do |lock_queues|
        # @type var lock_queues: ::Set[::String]
        redis_client.scan(
          'MATCH',
          RedisQueuedLocks::Resource::LOCK_QUEUE_PATTERN,
          count: scan_size
        ) do |lock_queue|
          # TODO: reduce unnecessary iterations
          # @type var lock_queue: ::String
          lock_queues.add(lock_queue)
        end
      end
    end

    # @param redis_client [RedisClient]
    # @param lock_queus [Set<String>]
    # @return [Set<Hash<Symbol,Any>>]
    #
    # @api private
    # @since 1.0.0
    def extract_queues_info(redis_client, lock_queues)
      # TODO: refactor with RedisQueuedLocks::Acquier::QueueInfo
      Set.new.tap do |seeded_queues|
        # Step X: iterate over each lock queue and extract their info
        # @type var seeded_queues: ::Set[::Hash[::Symbol,untyped]]
        lock_queues.each do |lock_queue|
          # Step 1: extract lock queue info from reids
          queue_info = redis_client.pipelined do |pipeline|
            pipeline.call('EXISTS', lock_queue)
            pipeline.call('ZRANGE', lock_queue, '0', '-1', 'WITHSCORES')
          end.yield_self do |result| # Step 2: format the result
            # @type var result: [::Integer, ::Array[[::String,::Float]]]

            exists_cmd_res = result[0]
            zrange_cmd_res = result[1]

            if exists_cmd_res == 1 # Step 2.X: lock queue existed during the piepline invocation
              zrange_cmd_res.map { |val| { 'acq_id' => val[0], 'score' => val[1] } }
            else
              # Step 2.Y: lock queue did not exist during the pipeline invocation
              [] #: ::Array[::Hash[::String,::String|::Float]]
            end
          end

          # @type var queue_info: ::Array[::Hash[::String,::String|::Float]]

          # Step 3: push the lock queue info to the result store
          seeded_queues << {
            queue: lock_queue,
            requests: queue_info
          }
        end
      end
    end
  end
end
