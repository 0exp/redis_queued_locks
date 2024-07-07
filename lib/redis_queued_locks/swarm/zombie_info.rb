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
    def zombie_acquiers(redis_client, zombie_ttl, lock_scan_size)
      redis_client.with do |rconn|
        extract_zombie_acquiers(rconn, zombie_ttl, lock_scan_size)
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
      zombie_score = RedisQueuedLocks::Resource.calc_zombie_score(zombie_ttl / 1_000)
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
    def extract_zombie_locks(rconn, zombie_ttl, lock_scan_size)
      zombie_hosts = extract_zombie_hosts(rconn, zombie_ttl)
      zombie_locks = Set.new
      rconn.scan(
        'MATCH', RedisQueuedLocks::Resource::LOCK_PATTERN, count: lock_scan_size
      ) do |lock_key|
        _acquier_id, host_id = rconn.call('HMGET', lock_key, 'acq_id', 'hst_id')
        zombie_locks << lock_key if zombie_hosts.include?(host_id)
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
    def extract_zombie_acquiers(rconn, zombie_ttl, lock_scan_size)
      zombie_hosts = extract_zombie_hosts(rconn, zombie_ttl)
      zombie_acquirers = Set.new
      rconn.scan(
        'MATCH', RedisQueuedLocks::Resource::LOCK_PATTERN, count: lock_scan_size
      ) do |lock_key|
        acquier_id, host_id = rconn.call('HMGET', lock_key, 'acq_id', 'hst_id')
        zombie_acquirers << acquier_id if zombie_hosts.include?(host_id)
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
    def extract_all(rconn, zombie_ttl, lock_scan_size)
      zombie_hosts = extract_zombie_hosts(rconn, zombie_ttl)
      zombie_locks = Set.new
      zombie_acquirers = Set.new
      rconn.scan(
        'MATCH', RedisQueuedLocks::Resource::LOCK_PATTERN, count: lock_scan_size
      ) do |lock_key|
        acquier_id, host_id = rconn.call('HMGET', lock_key, 'acq_id', 'hst_id')
        if zombie_hosts.include?(host_id)
          zombie_acquirers << acquier_id
          zombie_locks << lock_key
        end
      end
      { zombie_hosts:, zombie_acquirers:, zombie_locks: }
    end
  end
end
