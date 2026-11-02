# frozen_string_literal: true

# The locks of one block of code that are kept alive by the lock keeper
# (`RedisQueuedLocks::LockKeeper`): one lock (`#lock`) or all locks of a series (`#lock_series`):
#   - one lease per block of code, not per lock: the block is interrupted once and the hold limit
#     is the limit of the whole block;
#   - the locks are parallel arrays in the order of the lock names;
#   - the time values are the milliseconds of the monotonic clock;
#   - the extension schedule is changed by the keeper thread only; the block of code reads `#lost?`
#     and moves the hold limit (`RedisQueuedLocks::LockLease#hold_for`) under the lock of the
#     keeper;
#
# @api private
# @since 1.24.0
# rubocop:disable Metrics/ClassLength
class RedisQueuedLocks::LockKeeper::Lease
  # @return [Array<String>]
  #
  # @api private
  # @since 1.24.0
  attr_reader :lock_keys

  # @return [Array<String>]
  #
  # @api private
  # @since 1.24.0
  attr_reader :lock_readers_keys

  # @return [Array<String,NilClass>]
  #
  # @api private
  # @since 1.24.0
  attr_reader :read_lock_keys

  # The modes of the really held locks (a read lock request under the own write lock holds the
  # write lock).
  #
  # @return [Array<Symbol>]
  #
  # @api private
  # @since 1.24.0
  attr_reader :rw_modes

  # @return [Array<String>]
  #
  # @api private
  # @since 1.24.0
  attr_reader :lock_names

  # @return [String]
  #
  # @api private
  # @since 1.24.0
  attr_reader :acquirer_id

  # @return [String]
  #
  # @api private
  # @since 1.24.0
  attr_reader :host_id

  # How long the lock lives after an extension (in milliseconds).
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.24.0
  attr_reader :extension_ttl

  # The time between the extensions (in milliseconds).
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.24.0
  attr_reader :extension_interval

  # @return [Integer,NilClass]
  #
  # @api private
  # @since 1.24.0
  attr_reader :max_hold_time

  # The start of the attempt that obtained the locks.
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.24.0
  attr_reader :started_at

  # @return [Integer]
  #
  # @api private
  # @since 1.24.0
  attr_reader :next_extension_at

  # @return [Boolean]
  #
  # @api private
  # @since 1.24.0
  attr_reader :lock_index_enabled

  # @return [Integer]
  #
  # @api private
  # @since 1.24.0
  attr_reader :lock_index_grace_period

  # The thread of the block of code that is interrupted when a lock is lost or the hold limit is
  # reached (`nil`: nothing to interrupt: the block is not `timed`, it is not started yet or it can
  # not be reached by `Thread#raise`). See `RedisQueuedLocks::LockKeeper#interrupt_timed_block`.
  #
  # @return [Thread,NilClass]
  #
  # @api private
  # @since 1.24.0
  attr_accessor :interrupted_thread

  # @return [::Logger,#debug]
  #
  # @api private
  # @since 1.24.0
  attr_reader :logger

  # @return [Boolean]
  #
  # @api private
  # @since 1.24.0
  attr_reader :log_sampled

  # @return [#notify]
  #
  # @api private
  # @since 1.24.0
  attr_reader :instrumenter

  # @return [Boolean]
  #
  # @api private
  # @since 1.24.0
  attr_reader :instr_sampled

  # @return [NilClass,Any]
  #
  # @api private
  # @since 1.24.0
  attr_reader :instrument

  # @param lock_keys [Array<String>]
  # @param lock_readers_keys [Array<String>]
  # @param read_lock_keys [Array<String,NilClass>]
  # @param rw_modes [Array<Symbol>]
  # @param lock_names [Array<String>]
  # @param acquirer_id [String]
  # @param host_id [String]
  # @param started_at [Integer] The start of the attempt that obtained the locks.
  # @param ttl [Integer] The ttl of the obtained locks (in milliseconds).
  # @param extension_ttl [Integer] How long the lock lives after an extension (in milliseconds).
  # @param max_hold_time [Integer,NilClass] The hold limit (in milliseconds), `nil`: no limit.
  # @param lock_index_enabled [Boolean]
  # @param lock_index_grace_period [Integer]
  # @param logger [::Logger,#debug]
  # @param log_sampled [Boolean]
  # @param instrumenter [#notify]
  # @param instr_sampled [Boolean]
  # @param instrument [NilClass,Any]
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  # rubocop:disable Metrics/MethodLength
  def initialize(
    lock_keys,
    lock_readers_keys,
    read_lock_keys,
    rw_modes,
    lock_names,
    acquirer_id,
    host_id,
    started_at,
    ttl,
    extension_ttl,
    max_hold_time,
    lock_index_enabled,
    lock_index_grace_period,
    logger,
    log_sampled,
    instrumenter,
    instr_sampled,
    instrument
  )
    @lock_keys = lock_keys
    @lock_readers_keys = lock_readers_keys
    @read_lock_keys = read_lock_keys
    @rw_modes = rw_modes
    @lock_names = lock_names
    @acquirer_id = acquirer_id
    @host_id = host_id
    @extension_ttl = extension_ttl
    @extension_interval = [extension_ttl / 3, 1].max
    @max_hold_time = max_hold_time
    @started_at = started_at
    @hold_deadline = max_hold_time ? (started_at + max_hold_time) : nil
    @lock_index_enabled = lock_index_enabled
    @lock_index_grace_period = lock_index_grace_period
    @interrupted_thread = nil
    @logger = logger
    @log_sampled = log_sampled
    @instrumenter = instrumenter
    @instr_sampled = instr_sampled
    @instrument = instrument
    @lost_locks = Array.new(lock_keys.size, false)
    @lost = false
    @hold_stopped = false
    @hold_moved = false
    # NOTE: the first extension:
    #   - `ttl / 3`: the lock has to be extended while it is alive (the ttl can be shorter than the
    #     extension ttl);
    #   - `ttl - extension_ttl * 2 / 3`: an earlier extension of a long ttl changes nothing (it
    #     never shortens the lock): the same remaining time as before all other extensions;
    @next_extension_at = 0
    schedule_extension(started_at + [ttl / 3, ttl - (extension_ttl * 2 / 3)].max)
  end
  # rubocop:enable Metrics/MethodLength

  # @return [Boolean] At least one lock of the lease is lost.
  #
  # @api private
  # @since 1.24.0
  def lost?
    @lost
  end

  # @param lock_index [Integer]
  # @return [Boolean]
  #
  # @api private
  # @since 1.24.0
  def lock_lost?(lock_index)
    @lost_locks[lock_index]
  end

  # @param lock_index [Integer]
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def lose_lock(lock_index)
    @lost_locks[lock_index] = true
    @lost = true
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.24.0
  def all_locks_lost?
    @lost_locks.all?
  end

  # @param time [Integer]
  # @return [Boolean]
  #
  # @api private
  # @since 1.24.0
  def hold_limit_reached?(time)
    hold_deadline = @hold_deadline
    hold_deadline ? time >= hold_deadline : false
  end

  # Moves the hold limit to the given moment, never back (no limit stays no limit). Under the lock
  # of the keeper: see `RedisQueuedLocks::LockKeeper#hold_for`.
  #
  # @param hold_deadline [Integer]
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def hold_until(hold_deadline)
    current_hold_deadline = @hold_deadline
    return unless current_hold_deadline && hold_deadline > current_hold_deadline

    @hold_deadline = hold_deadline
    @hold_moved = true
  end

  # @return [Boolean] The hold limit is moved by the block of code (it is not `max_hold_time`).
  #
  # @api private
  # @since 1.24.0
  def hold_moved?
    @hold_moved
  end

  # @param time [Integer]
  # @return [Integer,NilClass] The time left till the hold limit (in milliseconds), `nil`: no limit.
  #
  # @api private
  # @since 1.24.0
  def hold_time_left(time)
    hold_deadline = @hold_deadline
    hold_deadline ? [hold_deadline - time, 0].max : nil
  end

  # The hold limit is reached and the locks are not extended anymore (under the lock of the keeper).
  #
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def stop_hold
    @hold_stopped = true
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.24.0
  def hold_stopped?
    @hold_stopped
  end

  # How long the lock lives after an extension at the given time: the extension ttl without
  # exceeding the hold limit.
  #
  # @param time [Integer]
  # @return [Integer] In milliseconds.
  #
  # @api private
  # @since 1.24.0
  def extension_ttl_at(time)
    hold_deadline = @hold_deadline
    return extension_ttl unless hold_deadline

    [hold_deadline - time, extension_ttl].min #: Integer
  end

  # @param time [Integer]
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def schedule_extension(time)
    hold_deadline = @hold_deadline
    @next_extension_at = (hold_deadline && hold_deadline < time) ? hold_deadline : time
  end
end
# rubocop:enable Metrics/ClassLength
