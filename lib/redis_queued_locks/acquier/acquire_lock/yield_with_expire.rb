# frozen_string_literal: true

# @api private
# @since 1.0.0
module RedisQueuedLocks::Acquier::AcquireLock::YieldWithExpire
  # @since 1.0.0
  extend RedisQueuedLocks::Utilities

  # @param redis [RedisClient] Redis connection manager.
  # @param logger [::Logger,#debug] Logger object.
  # @param lock_key [String] Lock key to be expired.
  # @param acquier_id [String] Acquier identifier.
  # @param timed [Boolean] Should the lock be wrapped by Tiemlout with with lock's ttl
  # @param ttl_shift [Float] Lock's TTL shifting. Should affect block's ttl. In millisecodns.
  # @param ttl [Integer,NilClass] Lock's time to live (in ms). Nil means "without timeout".
  # @param queue_ttl [Integer] Lock request lifetime.
  # @param block [Block] Custom logic that should be invoked unter the obtained lock.
  # @return [Any,NilClass] nil is returned no block parametr is provided.
  #
  # @api private
  # @since 1.0.0
  def yield_with_expire(
    redis,
    logger,
    lock_key,
    acquier_id,
    timed,
    ttl_shift,
    ttl,
    queue_ttl,
    &block
  )
    if block_given?
      if timed && ttl != nil
        timeout = ((ttl - ttl_shift) / 1000.0).yield_self { |time| (time < 0) ? 0.0 : time }
        yield_with_timeout(timeout, lock_key, ttl, &block)
      else
        yield
      end
    end
  ensure
    run_non_critical do
      logger.debug do
        "[redis_queued_locks.expire_lock] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquier_id}'"
      end
    end
    redis.call('EXPIRE', lock_key, '0')
  end

  private

  # @param timeout [Float]
  # @parma lock_key [String]
  # @param lock_ttl [Integer,NilClass]
  # @param block [Blcok]
  # @return [Any]
  #
  # @api private
  # @since 1.0.0
  def yield_with_timeout(timeout, lock_key, lock_ttl, &block)
    ::Timeout.timeout(timeout, &block)
  rescue ::Timeout::Error
    raise(
      RedisQueuedLocks::TimedLockTimeoutError,
      "Passed <timed> block of code exceeded " \
      "the lock TTL (lock: \"#{lock_key}\", ttl: #{lock_ttl})"
    )
  end
end
