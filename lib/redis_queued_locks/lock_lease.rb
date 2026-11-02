# frozen_string_literal: true

# The lease of an auto extended block of code (`auto_extend: true` of `#lock`, `#lock!`,
# `#lock_series`, `#lock_series!`): the block of code gets it as its argument when it takes one.
#
#   rql.lock('report', ttl: 10_000, auto_extend: true, max_hold_time: 600_000) do |lease|
#     batches.each do |batch|
#       process(batch)
#       lease.hold_for(120_000) # the progress is made: keep the lock two more minutes from now
#     end
#     save_report unless lease.lost?
#   end
#
#   - the hold limit (`max_hold_time`) is the limit of a stuck block of code: a block that makes
#     progress moves it (`#hold_for`), a stuck one stops moving it and its lock expires at the
#     last limit (a dead man's switch);
#   - one lease per block of code: a lock series has one lease for all its locks, a nested block
#     with `auto_extend: true` has its own one;
#   - a block of code without arguments (a lambda without parameters too) gets no lease: nothing is
#     allocated for it;
#   - the lease belongs to its block of code: it is useless after the block (`:released`);
#
# @api public
# @since 1.24.0
class RedisQueuedLocks::LockLease
  # @param lock_keeper [RedisQueuedLocks::LockKeeper]
  # @param lease [RedisQueuedLocks::LockKeeper::Lease]
  # @param redis [RedisClient] The connection of the client.
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def initialize(lock_keeper, lease, redis)
    @lock_keeper = lock_keeper
    @lease = lease
    @redis = redis
  end

  # Moves the hold limit of the block of code: the locks are kept at least `hold_time`
  # milliseconds from now, and they are extended at once (one round trip with the connection of
  # the client).
  #
  #   - the time is counted from now, it is not a sum: the calls in a loop do not accumulate it,
  #     and the limit never moves back (the latest limit wins);
  #   - it can move the limit beyond `max_hold_time`: the block that makes progress decides; with
  #     `max_hold_time: nil` (no limit) it only extends the locks and checks their owner;
  #   - each extension of the keeper is still `auto_extend_ttl` at most: the crash of the process
  #     releases the lock in `auto_extend_ttl`, whatever the limit is;
  #   - `timed: true`: the limit of the block of code is moved too (the block is interrupted at the
  #     moved limit; a non-blocking fiber whose fiber scheduler has no
  #     `Fiber::Scheduler#fiber_interrupt` keeps the `Timeout` of `max_hold_time`); a lost lock
  #     interrupts such block right here (`RedisQueuedLocks::TimedBlockLostLockError`), in any
  #     fiber;
  #   - call it per a unit of progress (a batch), not per item: each call is a round trip;
  #   - from another thread: only with a connection pool (the connection of the client is used,
  #     like by any method of the client);
  #
  # @param hold_time [Integer] In milliseconds, a positive Integer.
  # @return [Hash<Symbol,Boolean|Symbol>]
  #   Format: { ok: true, result: :extended } or { ok: false, result: Symbol }:
  #     - `:extended` - the hold limit is moved, all locks are owned and extended;
  #     - `:lock_lost` - a lock of the block of code is lost (`auto_extended_lock_lost` is
  #       reported); the next calls do not move the limit;
  #     - `:hold_limit_reached` - the hold limit is already reached: the locks are not extended
  #       anymore (`lock_hold_limit_reached` is reported), the limit can not be moved back;
  #     - `:released` - the block of code is completed and its locks are released;
  #
  # @raise [RedisQueuedLocks::ArgumentError]
  #
  # @api public
  # @since 1.24.0
  def hold_for(hold_time)
    unless hold_time.is_a?(::Integer) && hold_time > 0
      raise(
        RedisQueuedLocks::ArgumentError,
        "`hold_time` argument should be a positive Integer, got #{hold_time.inspect}."
      )
    end

    @lock_keeper.hold_for(@redis, @lease, hold_time)
  end

  # A local check without Redis: a lost lock is found by an extension (each `auto_extend_ttl / 3`)
  # or by `#hold_for`, so `false` does not prove that the lock is still owned right now.
  #
  # @return [Boolean] A lock of the block of code is lost.
  #
  # @api public
  # @since 1.24.0
  def lost?
    @lease.lost?
  end

  # @return [Integer,NilClass]
  #   The time left till the hold limit (in milliseconds, `0` when it is reached), `nil`: no limit.
  #
  # @api public
  # @since 1.24.0
  def hold_time_left
    @lock_keeper.hold_time_left(@lease)
  end
end
