# frozen_string_literal: true

# @api private
# @since 1.3.0
# @version 1.7.0
module RedisQueuedLocks::Acquirer::AcquireLock::YieldExpire
  require_relative 'yield_expire/log_visitor'

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
  # @param acquirer_id [String] Acquirer identifier.
  # @param host_id [String] Host identifier.
  # @param access_strategy [Symbol] Lock obtaining strategy.
  # @param timed [Boolean] Should the lock be wrapped by Timeout with with lock's ttl
  # @param ttl_shift [Numeric] Lock's TTL shifting. Should affect block's ttl. In millisecodns.
  # @param ttl [Integer,NilClass] Lock's time to live (in ms). Nil means "without timeout".
  # @param queue_ttl [Integer] Lock request lifetime.
  # @param meta [NilClass,Hash<String|Symbol,Any>] Custom metadata wich is passed to the lock data;
  # @param log_sampled [Boolean] Should the logic be logged or not.
  # @param instr_sampled [Boolean] Should the logic be instrumented or not.
  # @param should_expire [Boolean] Should the lock be expired after the block invocation.
  # @param should_decrease [Boolean]
  #   - Should decrease the lock TTL after the lock invocation;
  #   - It is suitable for extendable reentrant locks;
  # @param block [Block] Custom logic that should be invoked under the obtained lock.
  # @return [Any,NilClass] nil is returned when no block parametr is provided.
  #
  # @api private
  # @since 1.3.0
  # @version 1.9.0
  # rubocop:disable Metrics/MethodLength
  def yield_expire(
    redis,
    logger,
    lock_key,
    acquirer_id,
    host_id,
    access_strategy,
    timed,
    ttl_shift,
    ttl,
    queue_ttl,
    meta,
    log_sampled,
    instr_sampled,
    should_expire,
    should_decrease,
    &block
  )
    initial_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :millisecond)

    if block_given?
      if timed && ttl != nil
        # NOTE:
        #   - steep is ignored cuz steep can not recognize `::Integer - ::Integer|::Float`
        #     operation here for some mystical reason (it tryes to find overloadd `-` method for
        #     integer and fails on it);
        #   - so we need to ignore steep here at all and manually set the type of each
        #     variable for the correct following variable type recognitions;

        # steep:ignore:start
        # @type var ttl: Integer
        # @type var ttl_shift: Float|Integer
        # @type var timeout: Float
        timeout = ((ttl - ttl_shift) / 1_000.0).yield_self do |time|
          # @type var time: Float
          # NOTE: time in <seconds> cuz Ruby's Timeout requires <seconds>
          (time < 0) ? 0.0 : time
        end
        # steep:ignore:end

        yield_with_timeout(
          timeout,
          lock_key,
          ttl,
          acquirer_id,
          host_id,
          meta,
          &block # steep:ignore
        )
      else
        yield
      end
    end
  ensure
    if should_expire # TODO: comment all cases/examples when should_expire is true
      LogVisitor.expire_lock(
        logger, log_sampled, lock_key,
        queue_ttl, acquirer_id, host_id, access_strategy
      )
      redis.call('EXPIRE', lock_key, '0')
    elsif should_decrease # TODO: comment all cases/examples when should_expire is true
      finish_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :millisecond)
      # @type var initial_time: Integer
      spent_time = (finish_time - initial_time)
      # @type var ttl: Integer
      decreased_ttl = ttl - spent_time - RedisQueuedLocks::Resource::REDIS_TIMESHIFT_ERROR

      if decreased_ttl > 0
        LogVisitor.decrease_lock(
          logger, log_sampled, lock_key,
          decreased_ttl, queue_ttl, acquirer_id, host_id, access_strategy
        )
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
  # @param acquirer_id [String]
  # @param host_id [String]
  # @param meta [NilClass,Hash<Symbol|String,Any>]
  # @param block [Blcok]
  # @return [Any]
  #
  # @raise [RedisQueuedLocks::TimedLockTimeoutError]
  #
  # @api private
  # @since 1.3.0
  # @version 1.12.0
  def yield_with_timeout(timeout, lock_key, lock_ttl, acquirer_id, host_id, meta, &block)
    ::Timeout.timeout(timeout, RedisQueuedLocks::TimedLockIntermediateTimeoutError, &block)
  rescue RedisQueuedLocks::TimedLockIntermediateTimeoutError
    raise(
      RedisQueuedLocks::TimedLockTimeoutError,
      "Passed <timed> block of code exceeded the lock TTL " \
      "(lock: \"#{lock_key}\", " \
      "ttl: #{lock_ttl}, " \
      "meta: #{meta ? meta.inspect : '<no-meta>'}, " \
      "acq_id: \"#{acquirer_id}\", " \
      "hst_id: \"#{host_id}\")"
    )
  end
end
