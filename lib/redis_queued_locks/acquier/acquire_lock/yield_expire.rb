# frozen_string_literal: true

# @api private
# @since 1.3.0
module RedisQueuedLocks::Acquier::AcquireLock::YieldExpire
  # @since 1.3.0
  extend RedisQueuedLocks::Utilities

  # @return [String]
  #
  # @api private
  # @since 1.3.0
  DECREASE_LOCK_PTTL = <<~LUA_SCRIPT.strip.tr("\n", '').freeze
    local new_lock_pttl = redis.call("PTTL", KEYS[1]) - ARGV[1];
    return redis.call("PEXPIRE", KEYS[1], new_lock_pttl);
  LUA_SCRIPT

  # @param redis [RedisClient] Redis connection.
  # @param logger [::Logger,#debug] Logger object.
  # @param lock_key [String] Obtained lock key that should be expired.
  # @param acquier_id [String] Acquier identifier.
  # @param timed [Boolean] Should the lock be wrapped by Timeout with with lock's ttl
  # @param ttl_shift [Float] Lock's TTL shifting. Should affect block's ttl. In millisecodns.
  # @param ttl [Integer,NilClass] Lock's time to live (in ms). Nil means "without timeout".
  # @param queue_ttl [Integer] Lock request lifetime.
  # @param block [Block] Custom logic that should be invoked unter the obtained lock.
  # @param log_sampled [Boolean] Should the logic be logged or not (is log sample happened?).
  # @param should_expire [Boolean] Should the lock be expired after the block invocation.
  # @param should_decrease [Boolean]
  #   - Should decrease the lock TTL after the lock invocation;
  #   - It is suitable for extendable reentrant locks;
  # @return [Any,NilClass] nil is returned no block parametr is provided.
  #
  # @api private
  # @since 1.3.0
  # @version 1.5.0
  # rubocop:disable Metrics/MethodLength
  def yield_expire(
    redis,
    logger,
    lock_key,
    acquier_id,
    timed,
    ttl_shift,
    ttl,
    queue_ttl,
    log_sampled,
    should_expire,
    should_decrease,
    &block
  )
    initial_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :millisecond)

    if block_given?
      timeout = ((ttl - ttl_shift) / 1_000.0).yield_self do |time|
        # NOTE: time in <seconds> cuz Ruby's Timeout requires <seconds>
        (time < 0) ? 0.0 : time
      end

      if timed && ttl != nil
        yield_with_timeout(timeout, lock_key, ttl, &block)
      else
        yield
      end
    end
  ensure
    if should_expire
      run_non_critical do
        logger.debug do
          "[redis_queued_locks.expire_lock] " \
          "lock_key => '#{lock_key}' " \
          "queue_ttl => #{queue_ttl} " \
          "acq_id => '#{acquier_id}'"
        end
      end if log_sampled
      redis.call('EXPIRE', lock_key, '0')
    elsif should_decrease
      finish_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :millisecond)
      spent_time = (finish_time - initial_time)
      decreased_ttl = ttl - spent_time - RedisQueuedLocks::Resource::REDIS_TIMESHIFT_ERROR
      if decreased_ttl > 0
        run_non_critical do
          logger.debug do
            "[redis_queued_locks.decrease_lock] " \
            "lock_key => '#{lock_key}' " \
            "decreased_ttl => '#{decreased_ttl} " \
            "queue_ttl => #{queue_ttl} " \
            "acq_id => '#{acquier_id}' " \
          end
        end if log_sampled
        # NOTE:# NOTE: EVAL signature -> <lua script>, (number of keys), *(keys), *(arguments)
        redis.call('EVAL', DECREASE_LOCK_PTTL, 1, lock_key, decreased_ttl)
        # TODO: upload scripts to the redis
      end
    end
  end
  # rubocop:enable Metrics/MethodLength

  private

  # @param timeout [Float]
  # @parma lock_key [String]
  # @param lock_ttl [Integer,NilClass]
  # @param block [Blcok]
  # @return [Any]
  #
  # @api private
  # @since 1.3.0
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
