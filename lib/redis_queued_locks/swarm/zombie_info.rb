# frozen_string_literal: true

# @api private
# @since 1.9.0
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
    # @version 1.18.0
    def extract_zombie_locks(rconn, zombie_ttl, lock_scan_size)
      zombie_hosts = extract_zombie_hosts(rconn, zombie_ttl)
      zombie_locks = Set.new
      rconn.scan(
        'MATCH', RedisQueuedLocks::Resource::LOCK_PATTERN, count: lock_scan_size
      ) do |lock_key|
        _acquirer_id, host_id = rconn.call('HMGET', lock_key, 'acq_id', 'hst_id')
        zombie_locks << lock_key if zombie_hosts.include?(host_id)
      end
      # NOTE: (RW) readers registries with zombie read locks
      each_zombie_read_lock(rconn, zombie_hosts, lock_scan_size) do |lock_readers_key, _acquirer_id|
        zombie_locks << lock_readers_key
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
    # @version 1.18.0
    def extract_zombie_acquirers(rconn, zombie_ttl, lock_scan_size)
      zombie_hosts = extract_zombie_hosts(rconn, zombie_ttl)
      zombie_acquirers = Set.new
      rconn.scan(
        'MATCH', RedisQueuedLocks::Resource::LOCK_PATTERN, count: lock_scan_size
      ) do |lock_key|
        acquirer_id, host_id = rconn.call('HMGET', lock_key, 'acq_id', 'hst_id')
        zombie_acquirers << acquirer_id if zombie_hosts.include?(host_id)
      end
      # NOTE: (RW) zombie read lock acquirers
      each_zombie_read_lock(rconn, zombie_hosts, lock_scan_size) do |_lock_readers_key, acquirer_id|
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
    # @version 1.18.0
    def extract_all(rconn, zombie_ttl, lock_scan_size)
      zombie_hosts = extract_zombie_hosts(rconn, zombie_ttl)
      zombie_locks = Set.new
      zombie_acquirers = Set.new
      rconn.scan(
        'MATCH', RedisQueuedLocks::Resource::LOCK_PATTERN, count: lock_scan_size
      ) do |lock_key|
        acquirer_id, host_id = rconn.call('HMGET', lock_key, 'acq_id', 'hst_id')
        if zombie_hosts.include?(host_id)
          zombie_acquirers << acquirer_id
          zombie_locks << lock_key
        end
      end
      # NOTE: (RW) zombie read locks
      each_zombie_read_lock(rconn, zombie_hosts, lock_scan_size) do |lock_readers_key, acquirer_id|
        zombie_acquirers << acquirer_id
        zombie_locks << lock_readers_key
      end
      { zombie_hosts:, zombie_acquirers:, zombie_locks: }
    end

    # Iterates over read locks of zombie hosts
    # (read locks store acquirer ids only: the host is a part of the acquirer id).
    #
    # @param rconn [RedisClient] redis connection obtained via `#with` from RedisClient instance;
    # @param zombie_hosts [Set<String>]
    # @param lock_scan_size [Integer]
    # @yield [lock_readers_key, acquirer_id]
    # @yieldparam lock_readers_key [String] Readers registry with a zombie read lock.
    # @yieldparam acquirer_id [String] Zombie read lock acquirer.
    # @return [void]
    #
    # @api private
    # @since 1.18.0
    def each_zombie_read_lock(rconn, zombie_hosts, lock_scan_size)
      rconn.scan(
        'MATCH', RedisQueuedLocks::Resource::LOCK_READERS_PATTERN, count: lock_scan_size
      ) do |lock_readers_key|
        # @type var read_lock_acquirers: Array[String]
        read_lock_acquirers = rconn.call('ZRANGE', lock_readers_key, '0', '-1')
        read_lock_acquirers.each do |acquirer_id|
          host_id = RedisQueuedLocks::Resource.host_identifier_from_acquirer(acquirer_id)
          yield(lock_readers_key, acquirer_id) if zombie_hosts.include?(host_id)
        end
      end
    end
  end
end
