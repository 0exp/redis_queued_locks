# frozen_string_literal: true

# @api private
# @since 1.9.0
# @version 1.20.0
module RedisQueuedLocks::Swarm::ZombieInfo
  class << self
    # @param redis_client [RedisClient]
    # @param zombie_ttl [Integer]
    # @param lock_scan_size [Integer]
    # @return [Hash<Symbol,Set<String>>]
    #   Format: {
    #     zombie_hosts: <Set<String>>,
    #     zombie_acquirers: <Set<String>>,
    #     zombie_locks: <Set<String>>
    #   }
    #
    # @api private
    # @since 1.9.0
    def zombies_info(redis_client, zombie_ttl, lock_scan_size)
      redis_client.with do |rconn|
        extract_all(rconn, zombie_ttl, lock_scan_size)
      end
    end

    # @param redis_client [RedisClient]
    # @param zombie_ttl [Integer]
    # @param lock_scan_size [Integer]
    # @return [Set<String>]
    #
    # @api private
    # @since 1.9.0
    def zombie_locks(redis_client, zombie_ttl, lock_scan_size)
      redis_client.with do |rconn|
        extract_zombie_locks(rconn, zombie_ttl, lock_scan_size)
      end
    end

    # @param redis_client [RedisClient]
    # @param zombie_ttl [Integer]
    # @return [Set<String>]
    #
    # @api private
    # @since 1.9.0
    def zombie_hosts(redis_client, zombie_ttl)
      redis_client.with do |rconn|
        extract_zombie_hosts(rconn, zombie_ttl)
      end
    end

    # @param redis_client [RedisClient]
    # @param zombie_ttl [Integer]
    # @param lock_scan_size [Integer]
    # @return [Set<String>]
    #
    # @api private
    # @since 1.9.0
    def zombie_acquirers(redis_client, zombie_ttl, lock_scan_size)
      redis_client.with do |rconn|
        extract_zombie_acquirers(rconn, zombie_ttl, lock_scan_size)
      end
    end

    private

    # @param rconn [RedisClient] redis connection obtained via `#with` from RedisClient instance;
    # @param zombie_ttl [Integer]
    # @return [Set<String>]
    #
    # @api private
    # @since 1.9.0
    def extract_zombie_hosts(rconn, zombie_ttl)
      zombie_score = RedisQueuedLocks::Resource.calc_zombie_score(zombie_ttl / 1_000.0)
      swarmed_hosts = rconn.call('HGETALL', RedisQueuedLocks::Resource::SWARM_KEY)
      swarmed_hosts.each_with_object(Set.new) do |(hst_id, ts), zombies|
        (zombies << hst_id) if (zombie_score > ts.to_f)
      end
    end

    # @param rconn [RedisClient] redis connection obtained via `#with` from RedisClient instance;
    # @param zombie_ttl [Integer]
    # @param lock_scan_size [Integer]
    # @return [Set<String>]
    #
    # @api private
    # @since 1.9.0
    # @version 1.20.0
    def extract_zombie_locks(rconn, zombie_ttl, lock_scan_size)
      zombie_hosts = extract_zombie_hosts(rconn, zombie_ttl)
      zombie_locks = Set.new #: Set[String]
      # NOTE: (RW) readers registries with zombie read locks are zombie locks too
      each_zombie_lock(rconn, zombie_hosts, lock_scan_size) do |lock_key, _acquirer_id|
        zombie_locks << lock_key
      end
      zombie_locks
    end

    # @param rconn [RedisClient] redis connection obtained via `#with` from RedisClient instance;
    # @param zombie_ttl [Integer]
    # @param lock_scan_size [Integer]
    # @return [Set<String>]
    #
    # @api private
    # @since 1.9.0
    # @version 1.20.0
    def extract_zombie_acquirers(rconn, zombie_ttl, lock_scan_size)
      zombie_hosts = extract_zombie_hosts(rconn, zombie_ttl)
      zombie_acquirers = Set.new #: Set[String]
      # NOTE: (RW) zombie read lock acquirers are zombie acquirers too
      each_zombie_lock(rconn, zombie_hosts, lock_scan_size) do |_lock_key, acquirer_id|
        zombie_acquirers << acquirer_id
      end
      zombie_acquirers
    end

    # @param rconn [RedisClient] redis connection obtained via `#with` from RedisClient instance;
    # @param zombie_ttl [Integer]
    # @param lock_scan_size [Integer]
    # @return [Hash<Symbol,<Set<String>>]
    #   Format: {
    #     zombie_hosts: <Set<String>>,
    #     zombie_acquirers: <Set<String>>,
    #     zombie_locks: <Set<String>>
    #   }
    #
    # @api private
    # @since 1.9.0
    # @version 1.20.0
    def extract_all(rconn, zombie_ttl, lock_scan_size)
      zombie_hosts = extract_zombie_hosts(rconn, zombie_ttl)
      zombie_locks = Set.new #: Set[String]
      zombie_acquirers = Set.new #: Set[String]
      # NOTE: (RW) zombie read locks are reported by their readers registries
      each_zombie_lock(rconn, zombie_hosts, lock_scan_size) do |lock_key, acquirer_id|
        zombie_acquirers << acquirer_id
        zombie_locks << lock_key
      end
      { zombie_hosts:, zombie_acquirers:, zombie_locks: }
    end

    # Iterates over the locks of zombie hosts in one ZSCAN pass over the lock index
    # (`LOCK_INDEX_KEY`: lock names; lock keys are derived from the lock names, the full keyspace
    # is never scanned): write locks and readers registries are processed in batches of
    # `lock_scan_size` locks with one round trip per batch and per key family (batches are
    # collected across ZSCAN pages). Expired lock names of the index are skipped (all their keys
    # are expired). Nothing is scanned when there are no zombie hosts.
    #
    # @param rconn [RedisClient] redis connection obtained via `#with` from RedisClient instance;
    # @param zombie_hosts [Set<String>]
    # @param lock_scan_size [Integer]
    # @yield [lock_key, acquirer_id]
    # @yieldparam lock_key [String] Zombie write lock or readers registry with a zombie read lock.
    # @yieldparam acquirer_id [String] Zombie lock acquirer.
    # @return [void]
    #
    # @api private
    # @since 1.20.0
    def each_zombie_lock(rconn, zombie_hosts, lock_scan_size, &block)
      return if zombie_hosts.empty?

      # @type var lock_keys: Array[String]
      lock_keys = []
      # @type var lock_readers_keys: Array[String]
      lock_readers_keys = []
      lock_index_time = RedisQueuedLocks::Resource.lock_index_time

      rconn.zscan(
        RedisQueuedLocks::Resource::LOCK_INDEX_KEY, count: lock_scan_size
      ) do |lock_name, lock_index_score|
        # NOTE: the expired lock name (not dropped from the index yet): its keys are expired
        next if lock_index_score.to_f < lock_index_time

        lock_keys << RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
        lock_readers_keys << RedisQueuedLocks::Resource.prepare_lock_readers(lock_name)
        next if lock_keys.size < lock_scan_size

        each_zombie_write_lock(rconn, lock_keys, zombie_hosts, &block)
        each_zombie_read_lock(rconn, lock_readers_keys, zombie_hosts, &block)
        lock_keys.clear
        lock_readers_keys.clear
      end

      return if lock_keys.empty?

      each_zombie_write_lock(rconn, lock_keys, zombie_hosts, &block)
      each_zombie_read_lock(rconn, lock_readers_keys, zombie_hosts, &block)
    end

    # Iterates over the write locks of zombie hosts in the given batch of write locks
    # (one round trip).
    #
    # @param rconn [RedisClient] redis connection obtained via `#with` from RedisClient instance;
    # @param lock_keys [Array<String>]
    # @param zombie_hosts [Set<String>]
    # @yield [lock_key, acquirer_id]
    # @yieldparam lock_key [String] Zombie write lock.
    # @yieldparam acquirer_id [String] Zombie write lock acquirer.
    # @return [void]
    #
    # @api private
    # @since 1.20.0
    def each_zombie_write_lock(rconn, lock_keys, zombie_hosts)
      # NOTE: (pipeline layout) one reply (acquirer and host) per lock in the batch order
      # @type var lock_owners: Array[[String?, String?]]
      lock_owners = rconn.pipelined do |pipeline|
        lock_keys.each { |lock_key| pipeline.call('HMGET', lock_key, 'acq_id', 'hst_id') }
      end

      lock_keys.each_with_index do |lock_key, index|
        acquirer_id, host_id = lock_owners[index]
        next unless acquirer_id && host_id && zombie_hosts.include?(host_id)

        yield(lock_key, acquirer_id)
      end
    end

    # Iterates over read locks of zombie hosts in the given batch of readers registries
    # (one round trip; read locks store acquirer ids only: the host is a part of the acquirer id).
    #
    # @param rconn [RedisClient] redis connection obtained via `#with` from RedisClient instance;
    # @param lock_readers_keys [Array<String>]
    # @param zombie_hosts [Set<String>]
    # @yield [lock_readers_key, acquirer_id]
    # @yieldparam lock_readers_key [String] Readers registry with a zombie read lock.
    # @yieldparam acquirer_id [String] Zombie read lock acquirer.
    # @return [void]
    #
    # @api private
    # @since 1.18.0
    # @version 1.20.0
    def each_zombie_read_lock(rconn, lock_readers_keys, zombie_hosts)
      # NOTE: (pipeline layout) one reply (read lock acquirers) per registry in the batch order
      # @type var read_lock_acquirers: Array[Array[String]]
      read_lock_acquirers = rconn.pipelined do |pipeline|
        lock_readers_keys.each do |lock_readers_key|
          pipeline.call('ZRANGE', lock_readers_key, '0', '-1')
        end
      end

      lock_readers_keys.each_with_index do |lock_readers_key, index|
        read_lock_acquirers[index].each do |acquirer_id|
          host_id = RedisQueuedLocks::Resource.host_identifier_from_acquirer(acquirer_id)
          yield(lock_readers_key, acquirer_id) if zombie_hosts.include?(host_id)
        end
      end
    end
  end
end
