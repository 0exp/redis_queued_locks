# frozen_string_literal: true

# @api private
# @since 1.9.0
# @version 1.20.0
# rubocop:disable Metrics/ClassLength
class RedisQueuedLocks::Swarm::FlushZombies < RedisQueuedLocks::Swarm::SwarmElement::Isolated
  class << self
    # @param redis_client [RedisClient]
    # @param zombie_ttl [Integer]
    # @param lock_scan_size [Integer]
    # @param queue_scan_size [Integer]
    # @param lock_index_enabled [Boolean]
    #   Find zombie locks and requests via the lock index instead of the keyspace SCAN.
    # @return [Hash<Symbol,Boolean|Set<String>]] Format:
    #   {
    #     ok: <Boolean>,
    #     deleted_zombie_hosts: <Set<String>>,
    #     deleted_zombie_acquirers: <Set<String>>,
    #     deleted_zombie_locks: <Set<String>>
    #   }
    #
    # @api private
    # @since 1.9.0
    # @version 1.20.0
    # rubocop:disable Metrics/MethodLength
    def flush_zombies(
      redis_client,
      zombie_ttl,
      lock_scan_size,
      queue_scan_size,
      lock_index_enabled
    )
      redis_client.with do |rconn|
        # Step 1:
        #   calculate zombie score (the time marker that shows acquirers that
        #   have not announced live probes for a long time)
        zombie_score = RedisQueuedLocks::Resource.calc_zombie_score(zombie_ttl / 1_000.0)

        # Step 2: extract zombie acquirers from the swarm list
        zombie_hosts = rconn.call('HGETALL', RedisQueuedLocks::Resource::SWARM_KEY)
        zombie_hosts = zombie_hosts.each_with_object(Set.new) do |(hst_id, ts), zombies|
          (zombies << hst_id) if (zombie_score > ts.to_f)
        end

        # Step X: exit if we have no any zombie acquirer
        next {
          ok: true,
          deleted_zombie_hosts: Set.new,
          deleted_zombie_acquirers: Set.new,
          deleted_zombie_locks: Set.new
        } if zombie_hosts.empty?

        # Step 3: find zombie locks and zombie requests held by zombies and delete them in one pass
        #   (the keyspace SCAN or the lock index ZSCAN): write locks and readers registries are
        #   processed in batches of `lock_scan_size` locks, lock queues - in batches of
        #   `queue_scan_size` queues (two round trips per batch);
        zombie_locks = Set.new #: Set[String]
        zombie_acquirers = Set.new #: Set[String]

        if lock_index_enabled
          flush_lock_index_zombies(
            rconn, zombie_hosts, lock_scan_size, queue_scan_size, zombie_locks, zombie_acquirers
          )
        else
          flush_keyspace_zombies(
            rconn, zombie_hosts, lock_scan_size, queue_scan_size, zombie_locks, zombie_acquirers
          )
        end

        # Step 4: drop zombies from the swarm
        rconn.call('HDEL', RedisQueuedLocks::Resource::SWARM_KEY, *zombie_hosts)

        # Step 5: inform about deleted zombies
        {
          ok: true,
          deleted_zombie_hosts: zombie_hosts,
          deleted_zombie_acquirers: zombie_acquirers,
          deleted_zombie_locks: zombie_locks
        }
      end
    end
    # rubocop:enable Metrics/MethodLength

    private

    # (keyspace) Finds zombie locks (write and read) and zombie requests in one SCAN pass over
    # the RQL keys (`KEY_PATTERN`) and deletes them (the disabled lock index):
    #   - write locks and readers registries are processed in batches of `lock_scan_size` keys
    #     (two round trips per batch, batches are collected across SCAN pages);
    #   - lock queues are collected during the pass and processed after it in batches of
    #     `queue_scan_size` queues (two round trips per batch);
    #
    # @param rconn [RedisClient] redis connection obtained via `#with` from RedisClient instance;
    # @param zombie_hosts [Set<String>]
    # @param lock_scan_size [Integer] SCAN count and the batch size of locks.
    # @param queue_scan_size [Integer] The batch size of lock queues.
    # @param zombie_locks [Set<String>] Collects dropped zombie locks.
    # @param zombie_acquirers [Set<String>] Collects acquirers of the dropped zombie locks/requests.
    # @return [void]
    #
    # @api private
    # @since 1.20.0
    # rubocop:disable Metrics/MethodLength
    def flush_keyspace_zombies(
      rconn,
      zombie_hosts,
      lock_scan_size,
      queue_scan_size,
      zombie_locks,
      zombie_acquirers
    )
      # @type var lock_keys: Array[String]
      lock_keys = []
      # @type var lock_readers_keys: Array[String]
      lock_readers_keys = []
      # @type var lock_queues: Array[String]
      lock_queues = []

      rconn.scan(
        'MATCH', RedisQueuedLocks::Resource::KEY_PATTERN, count: lock_scan_size
      ) do |key|
        case RedisQueuedLocks::Resource.lock_key_family(key)
        when :lock
          lock_keys << key
          next if lock_keys.size < lock_scan_size

          flush_zombie_locks(rconn, lock_keys, zombie_hosts, zombie_locks, zombie_acquirers)
          lock_keys.clear
        when :lock_readers
          # NOTE: (RW) zombie read locks (read locks of zombie hosts)
          lock_readers_keys << key
          next if lock_readers_keys.size < lock_scan_size

          flush_zombie_read_locks(
            rconn, lock_readers_keys, zombie_hosts, zombie_locks, zombie_acquirers
          )
          lock_readers_keys.clear
        when :lock_queue, :read_lock_queue
          lock_queues << key
        end
      end

      unless lock_keys.empty?
        flush_zombie_locks(rconn, lock_keys, zombie_hosts, zombie_locks, zombie_acquirers)
      end
      unless lock_readers_keys.empty?
        flush_zombie_read_locks(
          rconn, lock_readers_keys, zombie_hosts, zombie_locks, zombie_acquirers
        )
      end

      # NOTE: drop zombie requests from the lock queues (write and read)
      #   - requests of zombie hosts: the host is derived from the acquirer id of the request,
      #     so the requests of zombie acquirers that hold no locks are dropped too (and their
      #     acquirers are reported as zombie acquirers);
      #   - two round trips per batch of `queue_scan_size` queues (requests, then ZREM);
      lock_queues.each_slice(queue_scan_size) do |lock_queues_batch|
        flush_zombie_requests(rconn, lock_queues_batch, zombie_hosts, zombie_acquirers)
      end
    end
    # rubocop:enable Metrics/MethodLength

    # (lock index) Finds zombie locks (write and read) and zombie requests in one ZSCAN pass over
    # the lock index (`LOCK_INDEX_KEY`: lock names) and deletes them (the enabled lock index):
    #   - expired lock names are dropped from the lock index first: all the keys of these locks are
    #     expired (they are not visited by the index pass);
    #   - lock keys are derived from the lock names instead of the full keyspace SCAN (keys of other
    #     applications are never visited);
    #   - write locks and readers registries are processed in batches of `lock_scan_size` locks
    #     (two round trips per batch, batches are collected across ZSCAN pages);
    #   - lock queues (write and read) are processed in batches of `queue_scan_size` queues during
    #     the same pass (two round trips per batch): zombie requests are found by the host of
    #     the request, so they do not depend on the zombie locks;
    #
    # @param rconn [RedisClient] redis connection obtained via `#with` from RedisClient instance;
    # @param zombie_hosts [Set<String>]
    # @param lock_scan_size [Integer] ZSCAN count and the batch size of locks (lock names).
    # @param queue_scan_size [Integer] The batch size of lock queues.
    # @param zombie_locks [Set<String>] Collects dropped zombie locks.
    # @param zombie_acquirers [Set<String>] Collects acquirers of the dropped zombie locks/requests.
    # @return [void]
    #
    # @api private
    # @since 1.20.0
    # rubocop:disable Metrics/MethodLength
    def flush_lock_index_zombies(
      rconn,
      zombie_hosts,
      lock_scan_size,
      queue_scan_size,
      zombie_locks,
      zombie_acquirers
    )
      # NOTE: drop the expired lock names from the lock index
      rconn.call(
        'ZREMRANGEBYSCORE', RedisQueuedLocks::Resource::LOCK_INDEX_KEY,
        '-inf', RedisQueuedLocks::Resource.lock_index_time - 1
      )

      # @type var lock_keys: Array[String]
      lock_keys = []
      # @type var lock_readers_keys: Array[String]
      lock_readers_keys = []
      # @type var lock_queues: Array[String]
      lock_queues = []

      rconn.zscan(
        RedisQueuedLocks::Resource::LOCK_INDEX_KEY, count: lock_scan_size
      ) do |lock_name|
        lock_keys << RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
        # NOTE: (RW) zombie read locks (read locks of zombie hosts)
        lock_readers_keys << RedisQueuedLocks::Resource.prepare_lock_readers(lock_name)
        if lock_keys.size >= lock_scan_size
          flush_zombie_locks(rconn, lock_keys, zombie_hosts, zombie_locks, zombie_acquirers)
          flush_zombie_read_locks(
            rconn, lock_readers_keys, zombie_hosts, zombie_locks, zombie_acquirers
          )
          lock_keys.clear
          lock_readers_keys.clear
        end

        # NOTE: drop zombie requests from the lock queues (write and read)
        #   - requests of zombie hosts: the host is derived from the acquirer id of the request,
        #     so the requests of zombie acquirers that hold no locks are dropped too (and their
        #     acquirers are reported as zombie acquirers);
        batch_zombie_requests(
          rconn, lock_queues, RedisQueuedLocks::Resource.prepare_lock_queue(lock_name),
          queue_scan_size, zombie_hosts, zombie_acquirers
        )
        batch_zombie_requests(
          rconn, lock_queues, RedisQueuedLocks::Resource.prepare_read_lock_queue(lock_name),
          queue_scan_size, zombie_hosts, zombie_acquirers
        )
      end

      unless lock_keys.empty?
        flush_zombie_locks(rconn, lock_keys, zombie_hosts, zombie_locks, zombie_acquirers)
        flush_zombie_read_locks(
          rconn, lock_readers_keys, zombie_hosts, zombie_locks, zombie_acquirers
        )
      end
      return if lock_queues.empty?

      flush_zombie_requests(rconn, lock_queues, zombie_hosts, zombie_acquirers)
    end
    # rubocop:enable Metrics/MethodLength

    # (lock index) Adds the lock queue to the batch of lock queues and drops the zombie requests of
    # the batch when it is full (`queue_scan_size` queues; see `flush_zombie_requests`).
    #
    # @param redis_client [RedisClient]
    # @param lock_queues [Array<String>] The batch of lock queues (cleared after the flush).
    # @param lock_queue [String]
    # @param queue_scan_size [Integer]
    # @param zombie_hosts [Set<String>]
    # @param zombie_acquirers [Set<String>] Collects acquirers of the dropped zombie requests.
    # @return [void]
    #
    # @api private
    # @since 1.20.0
    def batch_zombie_requests(
      redis_client,
      lock_queues,
      lock_queue,
      queue_scan_size,
      zombie_hosts,
      zombie_acquirers
    )
      lock_queues << lock_queue
      return if lock_queues.size < queue_scan_size

      flush_zombie_requests(redis_client, lock_queues, zombie_hosts, zombie_acquirers)
      lock_queues.clear
    end

    # Drops zombie locks (write locks of zombie hosts) of the given batch of write locks
    # (two round trips: lock owners, then one `DEL` of the zombie locks).
    #
    # @param redis_client [RedisClient]
    # @param lock_keys [Array<String>]
    # @param zombie_hosts [Set<String>]
    # @param zombie_locks [Set<String>] Collects dropped zombie locks.
    # @param zombie_acquirers [Set<String>] Collects acquirers of the dropped zombie locks.
    # @return [void]
    #
    # @api private
    # @since 1.20.0
    def flush_zombie_locks(redis_client, lock_keys, zombie_hosts, zombie_locks, zombie_acquirers)
      # NOTE: (pipeline layout) one reply (acquirer and host) per lock in the batch order
      # @type var lock_owners: Array[[String?, String?]]
      lock_owners = redis_client.pipelined do |pipeline|
        lock_keys.each { |lock_key| pipeline.call('HMGET', lock_key, 'acq_id', 'hst_id') }
      end

      # @type var batch_zombie_locks: Array[String]
      batch_zombie_locks = []
      lock_keys.each_with_index do |lock_key, index|
        acquirer_id, host_id = lock_owners[index]
        next unless acquirer_id && host_id && zombie_hosts.include?(host_id)

        batch_zombie_locks << lock_key
        zombie_acquirers << acquirer_id
      end
      return if batch_zombie_locks.empty?

      redis_client.call('DEL', *batch_zombie_locks)
      zombie_locks.merge(batch_zombie_locks)
    end

    # (RW) Drops zombie read locks (read locks of zombie hosts) of the given batch of readers
    # registries (two round trips: registry members, then `ZREM` of zombie readers + `DEL` of
    # their read lock data for each registry with zombie readers).
    #   - read locks store acquirer ids only (the host is a part of the acquirer id);
    #   - readers registry is reported as a zombie lock if any of its read locks is dropped;
    #
    # @param redis_client [RedisClient]
    # @param lock_readers_keys [Array<String>]
    # @param zombie_hosts [Set<String>]
    # @param zombie_locks [Set<String>] Collects registries with dropped zombie read locks.
    # @param zombie_acquirers [Set<String>] Collects acquirers of the dropped zombie read locks.
    # @return [void]
    #
    # @api private
    # @since 1.20.0
    def flush_zombie_read_locks(
      redis_client,
      lock_readers_keys,
      zombie_hosts,
      zombie_locks,
      zombie_acquirers
    )
      # NOTE: (pipeline layout) one reply (read lock acquirers) per registry in the batch order
      # @type var read_lock_acquirers: Array[Array[String]]
      read_lock_acquirers = redis_client.pipelined do |pipeline|
        lock_readers_keys.each do |lock_readers_key|
          pipeline.call('ZRANGE', lock_readers_key, '0', '-1')
        end
      end

      redis_client.pipelined do |pipeline|
        lock_readers_keys.each_with_index do |lock_readers_key, index|
          zombie_readers = read_lock_acquirers[index].select do |acquirer_id|
            zombie_hosts.include?(
              RedisQueuedLocks::Resource.host_identifier_from_acquirer(acquirer_id)
            )
          end
          next if zombie_readers.empty?

          pipeline.call('ZREM', lock_readers_key, *zombie_readers)
          # NOTE: drop the zombie read lock data
          lock_name = RedisQueuedLocks::Resource.lock_name_from_readers(lock_readers_key)
          pipeline.call(
            'DEL',
            *zombie_readers.map do |acquirer_id|
              RedisQueuedLocks::Resource.prepare_read_lock_key(lock_name, acquirer_id)
            end
          )
          zombie_locks << lock_readers_key
          zombie_acquirers.merge(zombie_readers)
        end
      end
    end

    # Drops the requests of zombie hosts from the given batch of lock queues (write and read)
    # in two round trips: queued acquirers, then one `ZREM` of the zombie requests per queue
    # (the host of a request is derived from its acquirer id).
    #
    # @param redis_client [RedisClient]
    # @param lock_queues [Array<String>]
    # @param zombie_hosts [Set<String>]
    # @param zombie_acquirers [Set<String>] Collects acquirers of the dropped zombie requests.
    # @return [void]
    #
    # @api private
    # @since 1.20.0
    def flush_zombie_requests(redis_client, lock_queues, zombie_hosts, zombie_acquirers)
      # NOTE: (pipeline layout) one reply (queued acquirers) per queue in the batch order
      # @type var queued_acquirers: Array[Array[String]]
      queued_acquirers = redis_client.pipelined do |pipeline|
        lock_queues.each { |lock_queue| pipeline.call('ZRANGE', lock_queue, '0', '-1') }
      end

      redis_client.pipelined do |pipeline|
        lock_queues.each_with_index do |lock_queue, index|
          zombie_requests = queued_acquirers[index].select do |acquirer_id|
            zombie_hosts.include?(
              RedisQueuedLocks::Resource.host_identifier_from_acquirer(acquirer_id)
            )
          end
          next if zombie_requests.empty?

          pipeline.call('ZREM', lock_queue, *zombie_requests)
          zombie_acquirers.merge(zombie_requests)
        end
      end
    end
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def enabled?
    rql_client.config['swarm.flush_zombies.enabled_for_swarm']
  end

  # @param swarm_element_results_port [Ractor::Port] Results port of the main Ractor.
  # @return [Ractor]
  #
  # @api private
  # @since 1.17.0
  # @version 1.20.0
  # rubocop:disable Metrics/MethodLength
  def spawn_swarm_element!(swarm_element_results_port)
    Ractor.new(
      swarm_element_results_port,
      rql_client.config.slice('swarm.flush_zombies.redis_config'),
      rql_client.config['swarm.flush_zombies.zombie_ttl'],
      rql_client.config['swarm.flush_zombies.zombie_lock_scan_size'],
      rql_client.config['swarm.flush_zombies.zombie_queue_scan_size'],
      rql_client.config['swarm.flush_zombies.zombie_flush_period'],
      rql_client.config['lock_index_enabled']
    ) do |r_res_p, rc, z_ttl, z_lss, z_qss, z_fl_prd, l_idx_en|
      RedisQueuedLocks::Swarm::FlushZombies.swarm_loop(r_res_p) do
        Thread.new do
          redis_client = RedisQueuedLocks::Swarm::RedisClientBuilder.build(
            pooled: rc['pooled'],
            sentinel: rc['sentinel'],
            config: rc['config'],
            pool_config: rc['pool_config']
          )

          loop do
            RedisQueuedLocks::Swarm::FlushZombies.flush_zombies(
              redis_client, z_ttl, z_lss, z_qss, l_idx_en
            )
            sleep(z_fl_prd)
          end
        end
      end
    end
  end
  # rubocop:enable Metrics/MethodLength
end
# rubocop:enable Metrics/ClassLength
