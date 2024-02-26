# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Acquier::Expire
  # @param redis [RedisClient] Redis connection manager.
  # @param lock_key [String] Lock key to be expired.
  # @param block [Block] Custom logic that should be invoked unter the obtained lock.
  # @return [Any,NilClass] nil is returned no block parametr is provided.
  #
  # @api private
  # @since 0.1.0
  def yield_with_expire(redis, lock_key, &block)
    yield if block_given?
  ensure
    redis.call('EXPIRE', lock_key, '0')
  end
end
