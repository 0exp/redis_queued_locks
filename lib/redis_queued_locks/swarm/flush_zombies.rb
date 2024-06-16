# frozen_string_literal: true

# @api private
# @since 1.9.0
class RedisQueuedLocks::Swarm::FlushZombies < RedisQueuedLocks::Swarm::SwarmElement
  class << self
    # @param redis_client [RedisClient]
    # @parma zombie_ttl [Numeric]
    # @param lock_scan_size [Integer]
    # @param queue_scan_size [Integer]
    # @param lock_flushing [Boolean]
    # @return [
    #   RedisQueuedLocks::Data[
    #     ok: <Boolean>,
    #     del_zombie_acqs: <Array<String>>,
    #     del_zombie_locks: <Array<String>>
    #   ]
    # ]
    #
    # @api private
    # @since 1.9.0
    # rubocop:disable Metrics/MethodLength
    def flush_zombies(redis_client, zombie_ttl, lock_scan_size, queue_scan_size, lock_flushing)
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
        del_zombie_acqs: [],
        del_zombie_locks: [],
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
      return RedisQueuedLocks::Data[
        ok: true,
        del_zombie_acqs: zombie_acquirers,
        del_zombie_locks: zombie_locks
      ]
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
      rql_client.config[:swarm][:flush_zombies][:redis_config],
      rql_client.config[:swarm][:flush_zombies][:zombie_ttl],
      rql_client.config[:swarm][:flush_zombies][:zombie_lock_scan_size],
      rql_client.config[:swarm][:flush_zombies][:zombie_queue_scan_size],
      rql_client.config[:swarm][:flush_zombies][:zombie_flush_period],
      rql_client.config[:swarm][:flush_zombies][:lock_flushing]
    ) do |rc, z_ttl, lss, qss, fl_prd, l_fl|
      # TODO: pooled connection for parallel processing of zombie acquirers and zombie locks
      rcl = RedisClient.config(**rc).new_client
      loop do
        RedisQueuedLocks::Swarm::FlushZombies.flush_zombies(rcl, z_ttl, lss, qss, l_fl)
        sleep(fl_prd)
      end
    end
  end
end
