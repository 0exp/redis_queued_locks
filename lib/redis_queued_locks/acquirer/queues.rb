# frozen_string_literal: true

# @api private
# @since 1.0.0
# @version 1.20.0
module RedisQueuedLocks::Acquirer::Queues
  class << self
    # @param redis_client [RedisClient]
    # @option scan_size [Integer]
    # @option with_info [Boolean]
    # @option lock_index_enabled [Boolean]
    #   Find lock queues via the lock index (`index_queues`) instead of the keyspace SCAN
    #   (`scan_queues`).
    # @return [Set<String>,Set<Hash<Symbol,Any>>]
    #
    # @api private
    # @since 1.0.0
    # @version 1.20.0
    def queues(redis_client, scan_size:, with_info:, lock_index_enabled:)
      redis_client.with do |rconn|
        lock_queues =
          lock_index_enabled ? index_queues(rconn, scan_size) : scan_queues(rconn, scan_size)
        with_info ? extract_queues_info(rconn, lock_queues, scan_size) : lock_queues
      end
    end

    private

    # Write and read lock queues in one SCAN pass (the disabled lock index).
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

    # Write and read lock queues of the lock index (the enabled lock index): one ZSCAN pass over
    # the lock names (`RedisQueuedLocks::Resource::LOCK_INDEX_KEY`, the keyspace is never scanned)
    # with one round trip per batch of `scan_size` lock names (`EXISTS` of both lock queues of
    # each lock name).
    #
    # @param redis_client [RedisClient]
    # @param scan_size [Integer] ZSCAN count and the number of lock names in one batch.
    # @return [Set<String>]
    #   - (RW) queues of read lock requests are included;
    #
    # @api private
    # @since 1.20.0
    def index_queues(redis_client, scan_size)
      Set.new.tap do |lock_queues|
        # @type var lock_queues: Set[String]
        each_lock_name_batch(redis_client, scan_size) do |lock_names|
          # NOTE: (pipeline layout) two replies per lock name in the batch order:
          #   EXISTS (write lock queue), EXISTS (read lock queue);
          # @type var queues_existence: Array[Integer]
          queues_existence = redis_client.pipelined do |pipeline|
            lock_names.each do |lock_name|
              pipeline.call('EXISTS', RedisQueuedLocks::Resource.prepare_lock_queue(lock_name))
              pipeline.call(
                'EXISTS', RedisQueuedLocks::Resource.prepare_read_lock_queue(lock_name)
              )
            end
          end

          lock_names.each_with_index do |lock_name, index|
            if queues_existence[index * 2] == 1
              lock_queues.add(RedisQueuedLocks::Resource.prepare_lock_queue(lock_name))
            end
            if queues_existence[(index * 2) + 1] == 1
              lock_queues.add(RedisQueuedLocks::Resource.prepare_read_lock_queue(lock_name))
            end
          end
        end
      end
    end

    # Iterates over the lock names of the lock index (one ZSCAN pass) in batches of `scan_size`
    # lock names (batches are collected across ZSCAN pages). Expired lock names (not dropped from
    # the index yet) are skipped: all their keys are expired.
    #
    # NOTE: each operation module iterates over the lock index by itself (duplicated on purpose:
    #   operation modules are independent of each other, see `Locks.each_lock_name_batch`);
    #
    # @param redis_client [RedisClient]
    # @param scan_size [Integer] ZSCAN count and the number of lock names in one batch.
    # @yield [lock_names]
    # @yieldparam lock_names [Array<String>] The batch of lock names (reused between batches).
    # @return [void]
    #
    # @api private
    # @since 1.20.0
    def each_lock_name_batch(redis_client, scan_size)
      lock_index_time = RedisQueuedLocks::Resource.lock_index_time
      # @type var lock_names: Array[String]
      lock_names = []

      redis_client.zscan(
        RedisQueuedLocks::Resource::LOCK_INDEX_KEY, count: scan_size
      ) do |lock_name, lock_index_score|
        next if lock_index_score.to_f < lock_index_time

        lock_names << lock_name
        next if lock_names.size < scan_size

        yield(lock_names)
        lock_names.clear
      end

      yield(lock_names) unless lock_names.empty?
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
