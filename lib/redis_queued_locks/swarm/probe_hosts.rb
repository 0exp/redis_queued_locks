# frozen_string_literal: true

# @api private
# @since 1.9.0
class RedisQueuedLocks::Swarm::ProbeHosts < RedisQueuedLocks::Swarm::SwarmElement::Threaded
  class << self
    # Returns a list of living hosts as a element command result. Result example:
    # {
    #   ok: <Boolean>,
    #   result: {
    #     host_id1 <String> => score1 <String>,
    #     host_id2 <String> => score2 <String>,
    #     etc...
    #   }
    # }
    #
    # @param redis_client [RedisClient]
    # @param uniq_identity [String]
    # @return [::Hash]
    #
    # @api private
    # @since 1.9.0
    def probe_hosts(redis_client, uniq_identity)
      possible_hosts = RedisQueuedLocks::Resource.possible_host_identifiers(uniq_identity)
      probed_hosts = {} #: Hash[String,Float]

      redis_client.with do |rconn|
        possible_hosts.each do |host_id|
          rconn.call(
            'HSET',
            RedisQueuedLocks::Resource::SWARM_KEY,
            host_id,
            probe_score = Time.now.to_f
          )
          probed_hosts[host_id] = probe_score
        end
      end

      { ok: true, result: probed_hosts }
    end
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def enabled?
    rql_client.config[:swarm][:probe_hosts][:enabled_for_swarm]
  end

  # @return [Thread]
  #
  # @api private
  # @since 1.9.0
  def spawn_main_loop!
    Thread.new do
      redis_client = RedisQueuedLocks::Swarm::RedisClientBuilder.build(
        pooled: rql_client.config[:swarm][:probe_hosts][:redis_config][:pooled],
        sentinel: rql_client.config[:swarm][:probe_hosts][:redis_config][:sentinel],
        config: rql_client.config[:swarm][:probe_hosts][:redis_config][:config],
        pool_config: rql_client.config[:swarm][:probe_hosts][:redis_config][:pool_config]
      )

      loop do
        RedisQueuedLocks::Swarm::ProbeHosts.probe_hosts(redis_client, rql_client.uniq_identity)
        sleep(rql_client.config[:swarm][:probe_hosts][:probe_period])
      end
    end
  end
end
