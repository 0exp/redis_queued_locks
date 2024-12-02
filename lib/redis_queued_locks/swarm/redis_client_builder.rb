# frozen_string_literal: true

# @api private
# @since 1.9.0
module RedisQueuedLocks::Swarm::RedisClientBuilder
  class << self
    # @option pooled [Boolean]
    # @option sentinel [Boolean]
    # @option config [Hash]
    # @return [RedisClient|RedisClient::Pooled]
    #
    # @api private
    # @since 1.9.0
    # rubocop:disable Style/RedundantAssignment
    def build(pooled: false, sentinel: false, config: {}, pool_config: {})
      config.transform_keys!(&:to_sym)
      pool_config.transform_keys!(&:to_sym)

      redis_config =
        sentinel ? sentinel_config(config) : non_sentinel_config(config)
      redis_client =
        pooled ? pooled_client(redis_config, pool_config) : non_pooled_client(redis_config)

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
