# frozen_string_literal: true

# @api private
# @since 1.9.0
# @version 1.21.0
module RedisQueuedLocks::Swarm::RedisClientBuilder
  class << self
    # @option pooled [Boolean]
    # @option sentinel [Boolean]
    # @option config [Hash]
    # @option pool_config [Hash]
    # @return [RedisClient|RedisClient::Pooled]
    #
    # @api private
    # @since 1.9.0
    # @version 1.21.0
    # rubocop:disable Style/RedundantAssignment
    def build(pooled: false, sentinel: false, config: {}, pool_config: {})
      # NOTE: the passed hashes are not mutated: they are the values of the client config (they
      #   can be frozen and are shared with the zombie flusher Ractor when they are shareable);
      redis_options = config.transform_keys(&:to_sym)
      pool_options = pool_config.transform_keys(&:to_sym)

      redis_config =
        sentinel ? sentinel_config(redis_options) : non_sentinel_config(redis_options)
      redis_client =
        pooled ? pooled_client(redis_config, pool_options) : non_pooled_client(redis_config)

      redis_client
    end
    # rubocop:enable Style/RedundantAssignment

    private

    # @param config [Hash]
    # @return [RedisClient::SentinelConfig]
    #
    # @api private
    # @since 1.9.0
    def sentinel_config(config)
      RedisClient.sentinel(**config)
    end

    # @param config [Hash]
    # @return [RedisClient::Config]
    #
    # @api private
    # @since 1.9.0
    def non_sentinel_config(config)
      RedisClient.config(**config)
    end

    # @param redis_config [ReidsClient::Config]
    # @param pool_config [Hash]
    # @return [RedisClient::Pooled]
    #
    # @api private
    # @since 1.9.0
    def pooled_client(redis_config, pool_config)
      redis_config.new_pool(**pool_config)
    end

    # @param redis_config [ReidsClient::Config]
    # @return [RedisClient]
    #
    # @api private
    # @since 1.9.0
    def non_pooled_client(redis_config)
      redis_config.new_client
    end
  end
end
