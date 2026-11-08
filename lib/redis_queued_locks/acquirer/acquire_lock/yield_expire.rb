# frozen_string_literal: true

# @api private
# @since 1.3.0
# @version 1.24.0
# rubocop:disable Metrics/ModuleLength
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

  # Releases the write lock of the given acquirer only: an auto extended lock can be lost during
  # the block of code (the hold limit, a stuck keeper, an explicit release), and the next owner
  # of the lock should not lose it.
  #
  # @return [String]
  #
  # @api private
  # @since 1.24.0
  RELEASE_OWN_LOCK = <<~LUA_SCRIPT.strip.tr("\n", '').freeze
    if redis.call("HGET", KEYS[1], "acq_id") ~= ARGV[1] then return 0 end;
    return redis.call("EXPIRE", KEYS[1], 0);
  LUA_SCRIPT

  # Decreases the ttl of the write lock of the given acquirer only (see `RELEASE_OWN_LOCK`).
  #
  # @return [String]
  #
  # @api private
  # @since 1.24.0
  DECREASE_OWN_LOCK_PTTL = <<~LUA_SCRIPT.strip.tr("\n", '').freeze
    if redis.call("HGET", KEYS[1], "acq_id") ~= ARGV[1] then return 0 end;
    local new_lock_pttl = redis.call("PTTL", KEYS[1]) - ARGV[2];
    return redis.call("PEXPIRE", KEYS[1], new_lock_pttl);
  LUA_SCRIPT

  # @param redis [RedisClient] Redis connection.
  # @param logger [::Logger,#debug] Logger object.
  # @param lock_key [String] Obtained lock key that should be expired.
  # @param lock_readers_key [String] Registry of read lock holders.
  # @param read_lock_key [String,NilClass]
  #   Read lock data of the current acquirer (`nil` for write lock requests: they never obtain
  #   read locks).
  # @param rw_mode [Symbol]
  #   - The mode of the obtained lock (`:read` or `:write`);
  #   - `:read` => only the read lock of the current acquirer is released/decreased;
  # @param lock_name [String] Lock name (the member of the lock index).
  # @param acquirer_id [String] Acquirer identifier.
  # @param host_id [String] Host identifier.
  # @param access_strategy [Symbol] Lock obtaining strategy.
  # @param timed [Boolean] Should the lock be wrapped by Timeout with with lock's ttl
  # @param ttl_shift [Numeric] Lock's TTL shifting. Should affect block's ttl. In millisecodns.
  # @param ttl [Integer] Lock's time to live (in ms). A positive Integer.
  # @param queue_ttl [Integer] Lock request lifetime.
  # @param lock_index_enabled [Boolean] Maintain the lock index.
  # @param lock_index_grace_period [Integer] The lock index score margin (in milliseconds).
  # @param meta [NilClass,Hash<String|Symbol,Any>] Custom metadata wich is passed to the lock data;
  # @param log_sampled [Boolean] Should the logic be logged or not.
  # @param instr_sampled [Boolean] Should the logic be instrumented or not.
  # @param should_expire [Boolean] Should the lock be expired after the block invocation.
  # @param should_decrease [Boolean]
  #   - Should decrease the lock TTL after the lock invocation;
  #   - It is suitable for extendable reentrant locks;
  # @param lock_keeper [RedisQueuedLocks::LockKeeper] The lock keeper of the client.
  # @param auto_extend [Boolean] Keep the lock alive while the block of code is running.
  # @param auto_extend_ttl [Integer,NilClass]
  #   How long the lock lives after an auto extension (in ms), `nil`: the lock ttl.
  # @param max_hold_time [Integer,NilClass] The auto extension limit (in ms), `nil`: no limit.
  # @param try_start_time [Integer] The start of the successful attempt (`clock_gettime`).
  # @param instrumenter [#notify] See `RedisQueuedLocks::LockKeeper`.
  # @param instrument [NilClass,Any] See `RedisQueuedLocks::LockKeeper`.
  # @yield Custom logic that should be invoked under the obtained lock.
  # @yieldparam lease [RedisQueuedLocks::LockKeeper::LockLease]
  #   The lease of an auto extended block of code (only for a block with arguments).
  # @yieldreturn [Any]
  # @return [Any,NilClass] nil is returned when no block parametr is provided.
  #
  # @api private
  # @since 1.3.0
  # @version 1.24.0
  # rubocop:disable Metrics/MethodLength
  def yield_expire(
    redis,
    logger,
    lock_key,
    lock_readers_key,
    read_lock_key,
    rw_mode,
    lock_name,
    acquirer_id,
    host_id,
    access_strategy,
    timed,
    ttl_shift,
    ttl,
    queue_ttl,
    lock_index_enabled,
    lock_index_grace_period,
    meta,
    log_sampled,
    instr_sampled,
    should_expire,
    should_decrease,
    lock_keeper,
    auto_extend,
    auto_extend_ttl,
    max_hold_time,
    try_start_time,
    instrumenter,
    instrument,
    &block
  )
    initial_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :millisecond)
    # @type var lock_lease: RedisQueuedLocks::LockKeeper::Lease?
    lock_lease = nil
    # @type var lease_handle: RedisQueuedLocks::LockKeeper::LockLease?
    lease_handle = nil

    if block
      # NOTE: (auto extension) inside the `ensure` scope of the lock release: the lease of an
      #   interrupted method is dropped by the keeper (the released lock is not found);
      if auto_extend
        lock_lease = lock_keeper.keep(
          [lock_key],
          [lock_readers_key],
          [read_lock_key],
          [rw_mode],
          [lock_name],
          acquirer_id,
          host_id,
          try_start_time,
          ttl,
          auto_extend_ttl || ttl,
          max_hold_time,
          lock_index_enabled,
          lock_index_grace_period,
          logger,
          log_sampled,
          instrumenter,
          instr_sampled,
          instrument
        )
        # NOTE: (auto extension) the block of code gets its lease when it takes an argument (no
        #   object for a block without arguments, a lambda without parameters gets no argument);
        if block.arity != 0
          lease_handle = RedisQueuedLocks::LockKeeper::LockLease.new(lock_keeper, lock_lease, redis)
        end
      end

      if timed
        yield_with_timeout(
          timed_block_budget(lock_lease ? max_hold_time : ttl, ttl_shift),
          lock_key,
          ttl,
          max_hold_time,
          lock_keeper,
          lock_lease,
          lease_handle,
          acquirer_id,
          host_id,
          meta,
          &block
        )
      elsif lease_handle
        yield(lease_handle)
      else
        yield
      end
    end
  ensure
    # NOTE: (auto extension) the lock keeper should not report the released lock as a lost one;
    lock_keeper.forget(lock_lease) if lock_lease

    if should_expire # TODO: comment all cases/examples when should_expire is true
      LogVisitor.expire_lock(
        logger, log_sampled, lock_key,
        queue_ttl, acquirer_id, host_id, access_strategy, rw_mode
      )
      if rw_mode == :read
        # NOTE: release only the read lock of the current acquirer (other readers keep working)
        redis.multi do |transact|
          transact.call('ZREM', lock_readers_key, acquirer_id)
          transact.call('DEL', read_lock_key)
        end
      elsif lock_lease
        # NOTE: EVAL signature -> <lua script>, (number of keys), *(keys), *(arguments)
        redis.call('EVAL', RELEASE_OWN_LOCK, 1, lock_key, acquirer_id)
      else
        redis.call('EXPIRE', lock_key, '0')
      end
    elsif should_decrease # TODO: comment all cases/examples when should_expire is true
      finish_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :millisecond)
      # @type var initial_time: Integer
      spent_time = (finish_time - initial_time)
      # @type var ttl: Integer
      decreased_ttl = ttl - spent_time - RedisQueuedLocks::Resource::REDIS_TIMESHIFT_ERROR

      if decreased_ttl > 0
        LogVisitor.decrease_lock(
          logger, log_sampled, lock_key,
          decreased_ttl, queue_ttl, acquirer_id, host_id, access_strategy, rw_mode
        )
        if rw_mode == :read
          # NOTE:
          #   - decrease the read lock expiration of the current acquirer;
          #   - XX => do nothing if the read lock is already expired and removed from the registry;
          #   - the read lock data TTL is not decreased (it is not used without the read lock);
          redis.call('ZADD', lock_readers_key, 'XX', 'INCR', -decreased_ttl, acquirer_id)
        elsif lock_lease
          redis.call('EVAL', DECREASE_OWN_LOCK_PTTL, 1, lock_key, acquirer_id, decreased_ttl)
        else
          # NOTE:# NOTE: EVAL signature -> <lua script>, (number of keys), *(keys), *(arguments)
          redis.call('EVAL', DECREASE_LOCK_PTTL, 1, lock_key, decreased_ttl)
          # TODO: upload scripts to the redis
        end
      end
    end
  end
  # rubocop:enable Metrics/MethodLength

  private

  # The time budget of a `timed` block of code.
  #
  # @param time_limit [Integer,NilClass]
  #   The limit of the block of code (in milliseconds), `nil`: no limit: the lock ttl or, for an
  #   auto extended lock, its hold limit.
  # @param ttl_shift [Numeric] The time that is already spent from the limit (in milliseconds).
  # @return [Float,NilClass] In seconds (Ruby's Timeout requires seconds), `nil`: no limit.
  #
  # @api private
  # @since 1.24.0
  def timed_block_budget(time_limit, ttl_shift)
    return unless time_limit

    # NOTE: steep is ignored cuz steep can not recognize `::Integer - ::Integer|::Float` operation
    #   here for some mystical reason (it tryes to find overloadd `-` method for integer and fails
    #   on it);

    # steep:ignore:start
    ((time_limit - ttl_shift) / 1_000.0).yield_self do |time|
      (time < 0) ? 0.0 : time
    end
    # steep:ignore:end
  end

  # @param timeout [Float,NilClass] `nil`: no time limit (an auto extended lock without a limit).
  # @param lock_key [String]
  # @param lock_ttl [Integer]
  # @param max_hold_time [Integer,NilClass]
  # @param lock_keeper [RedisQueuedLocks::LockKeeper]
  # @param lock_lease [RedisQueuedLocks::LockKeeper::Lease,NilClass]
  # @param lease_handle [RedisQueuedLocks::LockKeeper::LockLease,NilClass]
  #   The argument of the block of code.
  # @param acquirer_id [String]
  # @param host_id [String]
  # @param meta [NilClass,Hash<Symbol|String,Any>]
  # @param block [Blcok]
  # @return [Any]
  #
  # @raise [RedisQueuedLocks::TimedLockTimeoutError]
  # @raise [RedisQueuedLocks::LockTtlTimeBudgetIsSpentError]
  # @raise [RedisQueuedLocks::TimedBlockExceedsLockTtlError]
  # @raise [RedisQueuedLocks::TimedBlockExceedsMaxHoldTimeError]
  # @raise [RedisQueuedLocks::TimedBlockLostLockError]
  #
  # @api private
  # @since 1.3.0
  # @version 1.24.0
  # rubocop:disable Metrics/MethodLength
  def yield_with_timeout(
    timeout,
    lock_key,
    lock_ttl,
    max_hold_time,
    lock_keeper,
    lock_lease,
    lease_handle,
    acquirer_id,
    host_id,
    meta,
    &block
  )
    # NOTE: no budget left => the block is not invoked (`Timeout.timeout(0)` means "no timeout")
    if timeout == 0.0
      raise(
        RedisQueuedLocks::LockTtlTimeBudgetIsSpentError,
        "Passed <timed> block of code was not invoked: the time budget of the lock TTL is spent " \
        "(lock: \"#{lock_key}\", ttl: #{lock_ttl}, " \
        "meta: #{meta ? meta.inspect : '<no-meta>'}, " \
        "acq_id: \"#{acquirer_id}\", " \
        "hst_id: \"#{host_id}\")"
      )
    end

    # @type var raised_error: Exception?
    raised_error = nil

    begin
      begin
        # NOTE: (auto extension) the lock keeper interrupts the block of code from another thread
        #   (or through the fiber scheduler): the interruption period is limited by
        #   `#interrupt_timed_block` and `#forget`, both are inside the `rescue` scope: an internal
        #   error never reaches the application (an interruption that comes at the very end of the
        #   block is delivered in `#forget`);
        lock_keeper.interrupt_timed_block(lock_lease) if lock_lease

        if lock_lease&.interruptible?
          # NOTE: (auto extension) the keeper interrupts the block at the hold limit too: the block
          #   can move the limit (`RedisQueuedLocks::LockKeeper::LockLease#hold_for`), a `Timeout`
          #   can not;
          lease_handle ? yield(lease_handle) : yield
        elsif lock_lease
          # NOTE: (auto extension) a non-blocking fiber without a fiber scheduler that can
          #   interrupt it: its hold limit is a `Timeout` (a fiber scheduler implements it);
          ::Timeout.timeout(timeout, RedisQueuedLocks::TimedLockIntermediateTimeoutError) do
            lease_handle ? yield(lease_handle) : yield
          end
        else
          ::Timeout.timeout(timeout, RedisQueuedLocks::TimedLockIntermediateTimeoutError, &block)
        end
      rescue RedisQueuedLocks::TimedLockIntermediateTimeoutError => error
        # NOTE: (auto extension) an interruption of the fiber scheduler that has already come:
        #   `#forget` does not wait for it;
        raised_error = error
        raise
      ensure
        lock_keeper.forget(lock_lease, raised_error) if lock_lease
      end
    rescue RedisQueuedLocks::TimedLockIntermediateTimeoutError => error
      # NOTE: (auto extension) the interruption can come while `#forget` waits for the lock of the
      #   keeper: it is taken here, so the next `#forget` calls do not wait for it;
      lock_keeper.forget(lock_lease, error) if lock_lease
      raise_timed_block_error(
        lock_key, lock_ttl, max_hold_time, lock_lease, acquirer_id, host_id, meta
      )
    end
  end
  # rubocop:enable Metrics/MethodLength

  # @param lock_key [String]
  # @param lock_ttl [Integer]
  # @param max_hold_time [Integer,NilClass]
  # @param lock_lease [RedisQueuedLocks::LockKeeper::Lease,NilClass]
  # @param acquirer_id [String]
  # @param host_id [String]
  # @param meta [NilClass,Hash<Symbol|String,Any>]
  # @return [void]
  #
  # @raise [RedisQueuedLocks::TimedBlockExceedsLockTtlError]
  # @raise [RedisQueuedLocks::TimedBlockExceedsMaxHoldTimeError]
  # @raise [RedisQueuedLocks::TimedBlockLostLockError]
  #
  # @api private
  # @since 1.24.0
  def raise_timed_block_error(
    lock_key,
    lock_ttl,
    max_hold_time,
    lock_lease,
    acquirer_id,
    host_id,
    meta
  )
    lock_details =
      "(lock: \"#{lock_key}\", ttl: #{lock_ttl}, " \
      "meta: #{meta ? meta.inspect : '<no-meta>'}, " \
      "acq_id: \"#{acquirer_id}\", " \
      "hst_id: \"#{host_id}\")"

    if lock_lease&.lost?
      raise(
        RedisQueuedLocks::TimedBlockLostLockError,
        "The lock of the passed <timed> block of code is lost #{lock_details}"
      )
    elsif lock_lease
      raise(
        RedisQueuedLocks::TimedBlockExceedsMaxHoldTimeError,
        "Passed <timed> block of code exceeded the max hold time of the lock " \
        "(#{max_hold_time}#{', moved by the block of code' if lock_lease.hold_moved?}) " \
        "#{lock_details}"
      )
    else
      raise(
        RedisQueuedLocks::TimedBlockExceedsLockTtlError,
        "Passed <timed> block of code exceeded the lock TTL #{lock_details}"
      )
    end
  end
end
# rubocop:enable Metrics/ModuleLength
