# frozen_string_literal: true

# @api private
# @since 1.0.0
# @version 1.20.0
module RedisQueuedLocks::Acquirer::Queues
  class << self
    # @param redis_client [RedisClient]
    # @option scan_size [Integer]
    # @option with_info [Boolean]
    # @return [Set<String>,Set<Hash<Symbol,Any>>]
    #
    # @api private
    # @since 1.0.0
    # @version 1.20.0
    def queues(redis_client, scan_size:, with_info:)
      redis_client.with do |rconn|
        lock_queues = scan_queues(rconn, scan_size)
        with_info ? extract_queues_info(rconn, lock_queues, scan_size) : lock_queues
      end
    end

    private

    # Write and read lock queues in one SCAN pass.
    #
    # @param redis_client [RedisClient]
    # @param scan_size [Integer]
    # @return [Set<String>]
    #   - (RW) queues of read lock requests are included;
    #
    # @api private
    # @since 1.0.0
    # @version 1.20.0
    def scan_queues(redis_client, scan_size)
      Set.new.tap do |lock_queues|
        # @type var lock_queues: Set[String]
        redis_client.scan(
          'MATCH',
          RedisQueuedLocks::Resource::ALL_LOCK_QUEUES_PATTERN,
          count: scan_size
        ) do |key|
          # NOTE: the pattern matches other keys too (lock names with `queue:`): lock queues only
          family = RedisQueuedLocks::Resource.lock_key_family(key)
          lock_queues.add(key) if family == :lock_queue || family == :read_lock_queue
        end
      end
    end

    # @param redis_client [RedisClient]
    # @param lock_queues [Set<String>]
    # @param scan_size [Integer] The number of queues whose requests are read in one round trip.
    # @return [Set<Hash<Symbol,Any>>]
    #   - each request: `{ 'acq_id' => String, 'score' => Float, 'rw_mode' => 'read'/'write' }`;
    #
    # @api private
    # @since 1.0.0
    # @version 1.20.0
    def extract_queues_info(redis_client, lock_queues, scan_size)
      # NOTE: the same approach as in `QueueInfo` (duplicated on purpose: public operation modules
      #   do not reuse each other, they share logic via `Resource`, `Utilities`);
      Set.new.tap do |seeded_queues|
        # @type var seeded_queues: Set[Hash[Symbol,untyped]]
        lock_queues.each_slice(scan_size) do |lock_queues_batch|
          # Step 1: extract the requests of the batch of lock queues in one round trip
          #   - redis deletes empty sorted sets, so a queue that does not exist anymore gives
          #     an empty ZRANGE result (no need for EXISTS checks);
          #   - (pipeline layout) one reply per queue in the batch order;
          # @type var queues_requests: Array[Array[[String,Float]]]
          queues_requests = redis_client.pipelined do |pipeline|
            lock_queues_batch.each do |lock_queue|
              pipeline.call('ZRANGE', lock_queue, '0', '-1', 'WITHSCORES')
            end
          end

          lock_queues_batch.each_with_index do |lock_queue, index|
            # NOTE:
            #   - (RW) the mode of the requests of the queue (`'read'` or `'write'`);
            #   - lock queues are scanned by the lock queue patterns, so the mode is never `nil`;
            rw_mode = RedisQueuedLocks::Resource.lock_queue_rw_mode(lock_queue) #: String

            # Step 2: format the result and push it to the result store
            seeded_queues << {
              queue: lock_queue,
              requests: queues_requests[index].map do |val|
                { 'acq_id' => val[0], 'score' => val[1], 'rw_mode' => rw_mode }
              end
            }
          end
        end
      end
    end
  end
end
