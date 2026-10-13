# frozen_string_literal: true

# @api private
# @since 1.0.0
# @version 1.21.0
module RedisQueuedLocks::Acquirer::Keys
  # The number of replies of one lock name in the key state pipeline of a batch of lock names
  # (`collect_lock_keys`): EXISTS (write lock), EXISTS (write lock queue), EXISTS (read lock
  # queue), ZRANGE (readers registry).
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.20.0
  KEY_STATE_REPLIES = 4

  class << self
    # RQL keys of the locks:
    #   - the disabled lock index: all the RQL keys (`RedisQueuedLocks::Resource::KEY_PATTERN`,
    #     `rql:lock*`) found in one SCAN pass over the keyspace;
    #   - the enabled lock index: all the existing keys of the locks of the lock index (write locks,
    #     lock queues, readers registries, read lock queues, read lock data): one ZSCAN pass over
    #     the lock names (`RedisQueuedLocks::Resource::LOCK_INDEX_KEY`, the keyspace is never
    #     scanned), lock keys are derived from the lock names;
    #
    # @param redis_client [RedisClient]
    # @option scan_size [Integer]
    #   SCAN count (the disabled lock index) or ZSCAN count and the number of lock names in one
    #   batch (the enabled lock index).
    # @option lock_index_enabled [Boolean]
    # @return [Set<String>]
    #
    # @api private
    # @since 1.0.0
    # @version 1.21.0
    def keys(redis_client, scan_size:, lock_index_enabled:)
      # NOTE: (arguments) the same range as the config key: zero/negative sizes fail SCAN/ZSCAN
      #   (`COUNT 0`) and the batching (`each_slice(0)`);
      if !scan_size.is_a?(::Integer) || scan_size <= 0
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:scan_size` argument should be a positive Integer, got #{scan_size.inspect}."
        )
      end

      Set.new.tap do |keyset|
        # @type var keyset: Set[String]
        if lock_index_enabled
          redis_client.with do |rconn|
            each_lock_name_batch(rconn, scan_size) do |lock_names|
              collect_lock_keys(rconn, lock_names, keyset)
            end
          end
        else
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

    private

    # (lock index) Adds the existing keys of the given batch of lock names to the key set
    # (one round trip for the lock keys, one more for the read lock data when read locks exist).
    #
    # @param redis_client [RedisClient]
    # @param lock_names [Array<String>]
    # @param keyset [Set<String>]
    # @return [void]
    #
    # @api private
    # @since 1.20.0
    # rubocop:disable Metrics/MethodLength
    def collect_lock_keys(redis_client, lock_names, keyset)
      # Step 1: the state of the lock keys of the batch
      # NOTE: (pipeline layout) `KEY_STATE_REPLIES` replies per lock name in the batch order
      #   (the replies of the lock name with the index N start at `N * KEY_STATE_REPLIES`):
      #   EXISTS (write lock), EXISTS (write lock queue), EXISTS (read lock queue),
      #   ZRANGE (readers registry: redis deletes empty sorted sets, so an empty result means
      #   the registry does not exist);
      # @type var key_state: Array[untyped]
      key_state = redis_client.pipelined do |pipeline|
        lock_names.each do |lock_name|
          pipeline.call('EXISTS', RedisQueuedLocks::Resource.prepare_lock_key(lock_name))
          pipeline.call('EXISTS', RedisQueuedLocks::Resource.prepare_lock_queue(lock_name))
          pipeline.call('EXISTS', RedisQueuedLocks::Resource.prepare_read_lock_queue(lock_name))
          pipeline.call(
            'ZRANGE', RedisQueuedLocks::Resource.prepare_lock_readers(lock_name), '0', '-1'
          )
        end
      end

      # @type var read_lock_keys: Array[String]
      read_lock_keys = []
      lock_names.each_with_index do |lock_name, index|
        replies_at = index * KEY_STATE_REPLIES
        if key_state[replies_at] == 1
          keyset.add(RedisQueuedLocks::Resource.prepare_lock_key(lock_name))
        end
        if key_state[replies_at + 1] == 1
          keyset.add(RedisQueuedLocks::Resource.prepare_lock_queue(lock_name))
        end
        if key_state[replies_at + 2] == 1
          keyset.add(RedisQueuedLocks::Resource.prepare_read_lock_queue(lock_name))
        end
        # @type var read_lock_acquirers: Array[String]
        read_lock_acquirers = key_state[replies_at + 3]
        next if read_lock_acquirers.empty?

        keyset.add(RedisQueuedLocks::Resource.prepare_lock_readers(lock_name))
        read_lock_acquirers.each do |acquirer_id|
          read_lock_keys << RedisQueuedLocks::Resource.prepare_read_lock_key(lock_name, acquirer_id)
        end
      end
      return if read_lock_keys.empty?

      # Step 2: (RW) read lock data of the readers registries (it can be absent: the data of an
      #   expired read lock is expired before the registry cleanup)
      # NOTE: (pipeline layout) one EXISTS reply per read lock data key
      # @type var read_lock_keys_existence: Array[Integer]
      read_lock_keys_existence = redis_client.pipelined do |pipeline|
        read_lock_keys.each { |read_lock_key| pipeline.call('EXISTS', read_lock_key) }
      end
      read_lock_keys.each_with_index do |read_lock_key, index|
        keyset.add(read_lock_key) if read_lock_keys_existence[index] == 1
      end
    end
    # rubocop:enable Metrics/MethodLength

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
  end
end
