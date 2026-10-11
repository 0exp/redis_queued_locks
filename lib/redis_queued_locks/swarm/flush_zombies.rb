# frozen_string_literal: true

# @api private
# @since 1.9.0
# rubocop:disable Metrics/ClassLength
class RedisQueuedLocks::Swarm::FlushZombies < RedisQueuedLocks::Swarm::SwarmElement::Isolated
  class << self
    # @param redis_client [RedisClient]
    # @param zombie_ttl [Integer]
    # @param lock_scan_size [Integer]
    # @param queue_scan_size [Integer]
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
    # @version 1.18.0
    # rubocop:disable Metrics/MethodLength
    def flush_zombies(
      redis_client,
      zombie_ttl,
      lock_scan_size,
      queue_scan_size
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

        # Step 3: find zombie locks held by zombies and delete them
        # TODO: indexing (in order to prevent full database scan);
        # NOTE: original redis does not support indexing so we need to use
        #   internal data structers to simulate data indexing (such as sorted sets or lists);
        zombie_locks = Set.new #: Set[String]
        zombie_acquirers = Set.new #: Set[String]

        rconn.scan(
          'MATCH', RedisQueuedLocks::Resource::LOCK_PATTERN, count: lock_scan_size
        ) do |lock_key|
          acquirer_id, host_id = rconn.call('HMGET', lock_key, 'acq_id', 'hst_id')
          if zombie_hosts.include?(host_id)
            zombie_locks << lock_key
            zombie_acquirers << acquirer_id
          end
        end

        # NOTE: (steep) steep can't use <Set>s for splats
        rconn.call('DEL', *zombie_locks) if zombie_locks.any? # steep:ignore

        # Step 3 (RW): find zombie read locks (read locks of zombie hosts) and drop them
        #   - read locks store acquirer ids only (the host is a part of the acquirer id);
        #   - readers registry is reported as a zombie lock if any of its read locks is dropped;
        rconn.scan(
          'MATCH', RedisQueuedLocks::Resource::LOCK_READERS_PATTERN, count: lock_scan_size
        ) do |lock_readers_key|
          # @type var read_lock_acquirers: Array[String]
          read_lock_acquirers = rconn.call('ZRANGE', lock_readers_key, '0', '-1')
          zombie_readers = read_lock_acquirers.select do |acquirer_id|
            zombie_hosts.include?(RedisQueuedLocks::Resource.host_identifier_from_acquirer(acquirer_id))
          end
          next if zombie_readers.empty?

          rconn.call('ZREM', lock_readers_key, *zombie_readers)
          # NOTE: drop the zombie read lock data
          lock_name = RedisQueuedLocks::Resource.lock_name_from_readers(lock_readers_key)
          rconn.call(
            'DEL',
            *zombie_readers.map do |acquirer_id|
              RedisQueuedLocks::Resource.prepare_read_lock_key(lock_name, acquirer_id)
            end
          )
          zombie_locks << lock_readers_key
          zombie_acquirers.merge(zombie_readers)
        end

        # Step 4: find zombie requests => and drop them
        # TODO: indexing (in order to prevent full database scan);
        # NOTE: original redis does not support indexing so we need to use
        #   internal data structers to simulate data indexing (such as sorted sets or lists);
        rconn.scan(
          'MATCH', RedisQueuedLocks::Resource::LOCK_QUEUE_PATTERN, count: queue_scan_size
        ) do |lock_queue|
          zombie_acquirers.each do |zombie_acquirer|
            rconn.call('ZREM', lock_queue, zombie_acquirer)
          end
        end

        # Step 4 (RW): drop zombie requests from the queues of read lock requests
        rconn.scan(
          'MATCH', RedisQueuedLocks::Resource::READ_LOCK_QUEUE_PATTERN, count: queue_scan_size
        ) do |read_lock_queue|
          zombie_acquirers.each do |zombie_acquirer|
            rconn.call('ZREM', read_lock_queue, zombie_acquirer)
          end
        end

        # Step 5: drop zombies from the swarm
        rconn.call('HDEL', RedisQueuedLocks::Resource::SWARM_KEY, *zombie_hosts)

        # Step 6: inform about deleted zombies
        {
          ok: true,
          deleted_zombie_hosts: zombie_hosts,
          deleted_zombie_acquirers: zombie_acquirers,
          deleted_zombie_locks: zombie_locks
        }
      end
    end
    # rubocop:enable Metrics/MethodLength
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
  def spawn_swarm_element!(swarm_element_results_port)
    Ractor.new(
      swarm_element_results_port,
      rql_client.config.slice('swarm.flush_zombies.redis_config'),
      rql_client.config['swarm.flush_zombies.zombie_ttl'],
      rql_client.config['swarm.flush_zombies.zombie_lock_scan_size'],
      rql_client.config['swarm.flush_zombies.zombie_queue_scan_size'],
      rql_client.config['swarm.flush_zombies.zombie_flush_period']
    ) do |r_res_p, rc, z_ttl, z_lss, z_qss, z_fl_prd|
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
              redis_client, z_ttl, z_lss, z_qss
            )
            sleep(z_fl_prd)
          end
        end
      end
    end
  end
end
# rubocop:enable Metrics/ClassLength
