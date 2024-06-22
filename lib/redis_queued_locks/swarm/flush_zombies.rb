# frozen_string_literal: true

# @api private
# @since 1.9.0
class RedisQueuedLocks::Swarm::FlushZombies < RedisQueuedLocks::Swarm::SwarmElement
  class << self
    # @param redis_client [RedisClient]
    # @parma zombie_ttl [Numeric]
    # @param lock_scan_size [Integer]
    # @param queue_scan_size [Integer]
    # @return [
    #   RedisQueuedLocks::Data[
    #     ok: <Boolean>,
    #     deleted_zombies: <Array<String>>,
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
      # Step 1:
      #   calculate zombie score (the time marker that shows acquirers that
      #   have not announced live probes for a long time)
      zombie_score = RedisQueuedLocks::Resource.calc_zombie_score(zombie_ttl / 1_000)

      # Step 2: extract zombie acquirers from the swarm list
      zombie_acquirers = redis_client.call('HGETALL', RedisQueuedLocks::Resource::SWARM_KEY)
      zombie_acquirers = zombie_acquirers.each_with_object([]) do |(acq_id, ts), zombies|
        (zombies << acq_id) if (zombie_score > ts.to_f)
      end

      # Step X: exit if we have no any zombie acquirer
      return RedisQueuedLocks::Data[
        ok: true,
        deleted_zombies: [],
        deleted_zombie_locks: [],
      ] if zombie_acquirers.empty?

      # Step 3: find zombie locks held by zombies and delete them
      # TODO: indexing (in order to prevent full database scan);
      # NOTE: original redis does not support indexing so we need to use
      #   internal data structers to simulate data indexing (such as sorted sets or lists);
      zombie_locks = Set.new
      redis_client.scan(
        'MATCH', RedisQueuedLocks::Resource::LOCK_PATTERN, count: lock_scan_size
      ) do |lock_key|
        acquirer = redis_client.call('HGET', lock_key, 'acq_id')
        zobmie_locks << lock_key if zombie_acquirers.include?(acquirer)
      end
      redis_client.call('DEL', *zombie_locks) if zombie_locks.any?

      # Step 4: find zombie requests => and drop them
      # TODO: indexing (in order to prevent full database scan);
      # NOTE: original redis does not support indexing so we need to use
      #   internal data structers to simulate data indexing (such as sorted sets or lists);
      redis_client.scan(
        'MATCH', RedisQueuedLocks::Resource::LOCK_QUEUE_PATTERN, count: queue_scan_size
      ) do |lock_queue|
        zombie_acquirers.each do |zombie_acquirer|
          redis_client.call('ZREM', lock_queue, zombie_acquirer)
        end
      end

      # Step 5: drop zombies from the swarm
      redis_client.call('HDEL', RedisQueuedLocks::Resource::SWARM_KEY, *zombie_acquirers)

      # Step 6: inform about deleted zombies
      RedisQueuedLocks::Data[
        ok: true,
        deleted_zombies: zombie_acquirers,
        deleted_zombie_locks: zombie_locks
      ]
    end
    # rubocop:enable Metrics/MethodLength

    # @param redis_config [Hash]
    # @param zombie_ttl [Integer]
    # @param zombie_lock_scan_size [Integer]
    # @param zombie_queue_scan_size [Integer]
    # @param zombie_flush_period [Numeric]
    # @return [Thread]
    #
    # @api private
    # @since 1.9.0
    def spawn_main_loop(
      redis_config,
      zombie_ttl,
      zombie_lock_scan_size,
      zombie_queue_scan_size,
      zombie_flush_period
    )
      Thread.new do
        redis_client = RedisQueuedLocks::Swarm::RedisClientBuilder.build(
          pooled: redis_config['pooled'],
          sentinel: redis_config['sentinel'],
          config: redis_config['config'],
          pool_config: redis_config['pool_config']
        )

        loop do
          RedisQueuedLocks::Swarm::FlushZombies.flush_zombies(
            redis_client,
            zombie_ttl,
            zombie_lock_scan_size,
            zombie_queue_scan_size
          )
          sleep(zombie_flush_period)
        end
      end
    end
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def enabled?
    rql_client.config[:swarm][:flush_zombies][:enabled_for_swarm]
  end

  # Swarm element lifecycle:
  # => 1) init (swarm!): create a ractor, main loop is not started;
  # => 2) start (start!): run main lopp inside the ractor;
  # => 3) stop (stop!): stop the main loop inside a ractor;
  # => 4) kill (kill!): kill the main loop inside teh ractor and kill a ractor;
  #
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
        RedisQueuedLocks::Swarm::FlushZombies.spawn_main_loop(
          rc, z_ttl, z_lss, z_qss, z_fl_prd
        )
      end
    end
  end
end
