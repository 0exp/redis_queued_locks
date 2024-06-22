# frozen_string_literal: true

# @api private
# @since 1.9.0
class RedisQueuedLocks::Swarm::ProbeItself < RedisQueuedLocks::Swarm::SwarmElement
  class << self
    # @param redis_client [RedisClient]
    # @param acquirer_id [String]
    # @return [
    #   RedisQueuedLocks::Data[
    #     ok: <Boolean>,
    #     acq_id: <String>,
    #     probe_score: <Float>
    #   ]
    # ]
    #
    # @api private
    # @since 1.9.0
    def probe_itself(redis_client, acquirer_id)
      redis_client.with do |rconn|
        rconn.call(
          'HSET',
          RedisQueuedLocks::Resource::SWARM_KEY,
          acquirer_id,
          probe_score = Time.now.to_f
        )

        RedisQueuedLocks::Data[ok: true, acq_id: acquirer_id, probe_score:]
      end
    end

    # @param redis_config [Hash]
    # @param acquirer_id [String]
    # @param probe_period [Integer]
    # @return [Thread]
    #
    # @api private
    # @since 1.9.0
    def spawn_main_loop(redis_config, acquirer_id, probe_period)
      Thread.new do
        redis_client = RedisQueuedLocks::Swarm::RedisClientBuilder.build(
          pooled: redis_config['pooled'],
          sentinel: redis_config['sentinel'],
          config: redis_config['config'],
          pool_config: redis_config['pool_config']
        )

        loop do
          RedisQueuedLocks::Swarm::ProbeItself.probe_itself(redis_client, acquirer_id)
          sleep(probe_period)
        end
      end
    end
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def enabled?
    rql_client.config[:swarm][:probe_itself][:enabled_for_swarm]
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def swarm!
    @swarm_element = Ractor.new(
      rql_client.config.slice_value('swarm.probe_itself.redis_config'),
      rql_client.current_acquier_id,
      rql_client.config[:swarm][:probe_itself][:probe_period]
    ) do |rc, acq_id, prb_prd|
      RedisQueuedLocks::Swarm::ProbeItself.swarm_loop do
        RedisQueuedLocks::Swarm::ProbeItself.spawn_main_loop(rc, acq_id, prb_prd)
      end
    end
  end
end
