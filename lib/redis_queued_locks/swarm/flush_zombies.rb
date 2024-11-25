# frozen_string_literal: true

# @api private
# @since 1.9.0
class RedisQueuedLocks::Swarm::FlushZombies < RedisQueuedLocks::Swarm::SwarmElement::Isolated
  class << self
    # @param redis_client [RedisClient]
    # @parma zombie_ttl [Integer]
    # @param lock_scan_size [Integer]
    # @param queue_scan_size [Integer]
    # @return [
    #   RedisQueuedLocks::Data[
    #     ok: <Boolean>,
    #     deleted_zombie_hosts: <Set<String>>,
    #     deleted_zombie_acquiers: <Set<String>>,
    #     deleted_zombie_locks: <Set<String>>
    #   ]
    # ]
    #
    # @api private
    # @since 1.9.0
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
        # steep:ignore:start
        next RedisQueuedLocks::Data[
          ok: true,
          deleted_zombie_hosts: Set.new,
          deleted_zombie_acquirers: Set.new,
          deleted_zombie_locks: Set.new,
        ] if zombie_hosts.empty?
        # steep:ignore:end

        # Step 3: find zombie locks held by zombies and delete them
        # TODO: indexing (in order to prevent full database scan);
        # NOTE: original redis does not support indexing so we need to use
        #   internal data structers to simulate data indexing (such as sorted sets or lists);
        zombie_locks = Set.new #: ::Set[::String]
        zombie_acquiers = Set.new #: ::Set[::String]

        rconn.scan(
          'MATCH', RedisQueuedLocks::Resource::LOCK_PATTERN, count: lock_scan_size
        ) do |lock_key|
          acquier_id, host_id = rconn.call('HMGET', lock_key, 'acq_id', 'hst_id')
          if zombie_hosts.include?(host_id)
            zombie_locks << lock_key
            zombie_acquiers << acquier_id
          end
        end

        # NOTE: (steep ignorance) steep can't use Sets for splats
        rconn.call('DEL', *zombie_locks) if zombie_locks.any? # steep:ignore

        # Step 4: find zombie requests => and drop them
        # TODO: indexing (in order to prevent full database scan);
        # NOTE: original redis does not support indexing so we need to use
        #   internal data structers to simulate data indexing (such as sorted sets or lists);
        rconn.scan(
          'MATCH', RedisQueuedLocks::Resource::LOCK_QUEUE_PATTERN, count: queue_scan_size
        ) do |lock_queue|
          zombie_acquiers.each do |zombie_acquier|
            rconn.call('ZREM', lock_queue, zombie_acquier)
          end
        end

        # Step 5: drop zombies from the swarm
        rconn.call('HDEL', RedisQueuedLocks::Resource::SWARM_KEY, *zombie_hosts)

        # Step 6: inform about deleted zombies
        # steep:ignore:start
        RedisQueuedLocks::Data[
          ok: true,
          deleted_zombie_hosts: zombie_hosts,
          deleted_zombie_acquiers: zombie_acquiers,
          deleted_zombie_locks: zombie_locks
        ]
        # steep:ignore:end
      end
    end
    # rubocop:enable Metrics/MethodLength
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def enabled?
    rql_client.config[:swarm][:flush_zombies][:enabled_for_swarm]
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def swarm!
    @swarm_element = Ractor.new(
      rql_client.config.slice_value('swarm.flush_zombies.redis_config'),
      rql_client.config[:swarm][:flush_zombies][:zombie_ttl],
      rql_client.config[:swarm][:flush_zombies][:zombie_lock_scan_size],
      rql_client.config[:swarm][:flush_zombies][:zombie_queue_scan_size],
      rql_client.config[:swarm][:flush_zombies][:zombie_flush_period]
    ) do |rc, z_ttl, z_lss, z_qss, z_fl_prd|
      RedisQueuedLocks::Swarm::FlushZombies.swarm_loop do
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
