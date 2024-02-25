# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Acquier::Expire
  # @param redis [RedisClient]
  # @param lock_key [String]
  # @param block [Block]
  # @return [void]
  #
  # @api private
  # @since 0.1.0
  def yield_with_expire(redis, lock_key, &block)
    yield if block_given?
  ensure
    redis.call('EXPIRE', lock_key, '0')
  end
end
