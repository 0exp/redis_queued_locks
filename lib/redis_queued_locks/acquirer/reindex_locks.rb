# frozen_string_literal: true

# @api private
# @since 1.20.0
module RedisQueuedLocks::Acquirer::ReindexLocks
  class << self
    # Adds the lock keys without the lock index entry (keys of older RQL versions created before
    # the lock index) to the lock index (`RedisQueuedLocks::Resource::LOCK_INDEX_KEY`):
    #   - one SCAN pass over the RQL keys (`KEY_PATTERN`) with pipelined batches of `scan_size`
    #     keys collected across SCAN pages (two round trips per batch: key TTLs, then the index);
    #   - write locks and readers registries are indexed with their remaining TTL (`PTTL`):
    #     the score is the client time + the remaining TTL + the grace period;
    #   - lock queues without TTL (older RQL versions) get the queue TTL first (`PEXPIRE NX`):
    #     the lifetime of every indexed key is bounded;
    #   - read lock data is not indexed: it is found via its readers registry;
    #   - keys without TTL (unreachable for RQL keys) are indexed forever (`+inf` score);
    #   - the index score is never decreased (`ZADD GT`): the operation is idempotent and can be
    #     invoked at any time (keys of the current RQL version are indexed already);
    #
    # @param redis_client [RedisClient]
    # @param scan_size [Integer]
    # @param queue_ttl [Integer] TTL of the lock queues without TTL (in seconds).
    # @param lock_index_grace_period [Integer]
    #   The lock index score margin over the key lifetime (in milliseconds).
    # @return [Hash<Symbol,Boolean|Hash<Symbol,Integer>>]
    #   Format: { ok: true, result: { idx_key_cnt: Integer } } (the number of indexed keys)
    #
    # @api private
    # @since 1.20.0
    def reindex_locks(redis_client, scan_size, queue_ttl, lock_index_grace_period)
      # NOTE: `ceil` - queue ttl can be passed as a Float (in seconds), PEXPIRE requires Integer
      queue_pttl = (queue_ttl * 1_000).ceil
      idx_key_cnt = 0

      redis_client.with do |rconn|
        # NOTE: write locks and readers registries of the batch
        # @type var lock_keys: Array[String]
        lock_keys = []
        # @type var lock_queues: Array[String]
        lock_queues = []

        rconn.scan('MATCH', RedisQueuedLocks::Resource::KEY_PATTERN, count: scan_size) do |key|
          case RedisQueuedLocks::Resource.lock_key_family(key)
          when :lock, :lock_readers then lock_keys << key
          when :lock_queue, :read_lock_queue then lock_queues << key
          else next # NOTE: read lock data and keys out of the lock key families
          end
          next if (lock_keys.size + lock_queues.size) < scan_size

          idx_key_cnt += index_lock_keys(
            rconn, lock_keys, lock_queues, queue_pttl, lock_index_grace_period
          )
          lock_keys.clear
          lock_queues.clear
        end

        unless lock_keys.empty? && lock_queues.empty?
          idx_key_cnt += index_lock_keys(
            rconn, lock_keys, lock_queues, queue_pttl, lock_index_grace_period
          )
        end
      end

      { ok: true, result: { idx_key_cnt: } }
    end

    private

    # Adds the given batch of lock keys to the lock index (two round trips: key TTLs, then
    # the index entries).
    #
    # @param redis_client [RedisClient]
    # @param lock_keys [Array<String>] Write locks and readers registries.
    # @param lock_queues [Array<String>] Lock queues (write and read).
    # @param queue_pttl [Integer] TTL of the lock queues without TTL (in milliseconds).
    # @param lock_index_grace_period [Integer] In milliseconds.
    # @return [Integer] The number of indexed keys (keys deleted after the SCAN are not indexed).
    #
    # @api private
    # @since 1.20.0
    def index_lock_keys(redis_client, lock_keys, lock_queues, queue_pttl, lock_index_grace_period)
      # NOTE: (pipeline layout) `PEXPIRE NX` + `PTTL` for each lock queue (two replies per queue),
      #   then `PTTL` for each lock key, in the batch order;
      # @type var key_ttls: Array[Integer]
      key_ttls = redis_client.pipelined do |pipeline|
        lock_queues.each do |lock_queue|
          pipeline.call('PEXPIRE', lock_queue, queue_pttl, 'NX')
          pipeline.call('PTTL', lock_queue)
        end
        lock_keys.each { |lock_key| pipeline.call('PTTL', lock_key) }
      end
      # NOTE: the client time after the TTLs are received: the score is not less than the key
      #   expiration time (+ the grace period for the client clock skew);
      lock_index_time = RedisQueuedLocks::Resource.lock_index_time
      indexed_keys_count = 0

      redis_client.pipelined do |pipeline|
        lock_queues.each_with_index do |lock_queue, index|
          indexed_keys_count += index_lock_key(
            pipeline, lock_queue, key_ttls[(index * 2) + 1], lock_index_time,
            lock_index_grace_period
          )
        end
        lock_keys.each_with_index do |lock_key, index|
          indexed_keys_count += index_lock_key(
            pipeline, lock_key, key_ttls[(lock_queues.size * 2) + index], lock_index_time,
            lock_index_grace_period
          )
        end
      end

      indexed_keys_count
    end

    # Adds the lock name of the given key to the lock index (`ZADD GT`).
    #
    # @param pipeline [RedisClient::Pipeline]
    # @param key [String] Write lock, readers registry or lock queue.
    # @param key_ttl [Integer] The remaining key TTL (`PTTL`: `-2` - no key, `-1` - no TTL).
    # @param lock_index_time [Integer] Epoch, in milliseconds.
    # @param lock_index_grace_period [Integer] In milliseconds.
    # @return [Integer] `1` - the key is indexed, `0` - the key does not exist anymore.
    #
    # @api private
    # @since 1.20.0
    def index_lock_key(pipeline, key, key_ttl, lock_index_time, lock_index_grace_period)
      return 0 if key_ttl == -2

      lock_name = RedisQueuedLocks::Resource.lock_name_from_key(
        key, RedisQueuedLocks::Resource.lock_key_family(key)
      )
      lock_index_score =
        (key_ttl == -1) ? '+inf' : (lock_index_time + key_ttl + lock_index_grace_period)
      pipeline.call(
        'ZADD', RedisQueuedLocks::Resource::LOCK_INDEX_KEY, 'GT', lock_index_score, lock_name
      )
      1
    end
  end
end
