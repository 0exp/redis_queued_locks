# frozen_string_literal: true

# @api private
# @since 1.9.0
module RedisQueuedLocks::Swarm::Acquirers
  class << self
    # Returns the list of swarm acquirers stored as HASH.
    # Format:
    #   {
    #     <acquirer id #1> => {
    #       zombie: <Boolean>,
    #       last_probe_time: <Time>,
    #       last_probe_score: <Numeric>
    #      },
    #     <acquirer id #2> => {
    #       zombie: <Boolean>,
    #       last_probe_time: <Time>,
    #       last_probe_score: <Numeric>
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
    def acquirers(redis_client, zombie_ttl)
      redis_client.with do |rconn|
        rconn.call('HGETALL', RedisQueuedLocks::Resource::SWARM_KEY).tap do |swarm_acqs|
          # @type var swarm_acqs: ::Hash[::String,untyped]
          swarm_acqs.transform_values! do |last_probe|
            # @type var last_probe: ::String
            last_probe_score = last_probe.to_f
            last_probe_time = Time.at(last_probe_score)
            zombie_score = RedisQueuedLocks::Resource.calc_zombie_score(zombie_ttl / 1_000.0)
            is_zombie = last_probe_score < zombie_score
            { zombie: is_zombie, last_probe_time:, last_probe_score: }
          end
        end
      end
    end
  end
end
