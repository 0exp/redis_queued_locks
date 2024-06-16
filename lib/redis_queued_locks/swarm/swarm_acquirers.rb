# frozen_string_literal: true

# @api private
# @since 1.9.0
module RedisQueuedLocks::Swarm::SwarmAcquirers
  class << self
    # Returns the list of swarm acquirers are stored as a hash represented in following format:
    #   {
    #     <acquirer id #1> => {
    #       zombie: <Boolean>, last_probe_time: <Time>, last_probe_epoch: <Numeric>
    #      },
    #     <acquirer id #2> => {
    #       zombie: <Boolean>, last_probe_time: <Time>, last_probe_epoch: <Numeric>
    #      },
    #     ...
    #   }
    # Liveness probe time is represented as a float value (Time.now.to_f initially).
    #
    # @param redis_client [RedisClient]
    # @param zombie_ttl [Integer]
    # @return [Hash<String,Hash<Symbol,Float|Time>>]
    #
    # @api private
    # @since 1.9.0
    def swarm_acquirers(redis_client, zombie_ttl)
      redis_client.with do |rconn|
        rconn.call('HGETALL', RedisQueuedLocks::Resource::SWARM_KEY).tap do |acquirers|
          acquirers.transform_values! do |last_probe|
            last_probe_epoch = last_probe.to_f
            last_probe_time = Time.at(last_probe_epoch)
            zombie_epoch = RedisQueuedLocks::Resource.calc_zombie_score(zombie_ttl / 1_000)
            is_zombie = last_probe_epoch < zombie_epoch
            { zombie: is_zombie, last_probe_time:, last_probe_epoch: }
          end
        end
      end
    end
  end
end
