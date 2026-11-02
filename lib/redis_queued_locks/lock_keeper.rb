# frozen_string_literal: true

# Keeps the locks of the running blocks of code alive (the `auto_extend: true` option of `#lock`
# and `#lock_series`): one background thread per client extends the locks of all blocks while they
# are running, so the lock ttl is a lease: the crash of the process releases the lock by the ttl,
# whatever the duration of the block of code is:
#   - the thread and its Redis connection are created on demand and stop after `IDLE_TIMEOUT`
#     without new leases;
#   - the thread has its own connection (from the config of the client): the client can be a plain
#     `RedisClient` (one connection), it can not be shared with the threads of the application;
#   - an extension checks the owner of the lock, never revives a lost lock and never shortens the
#     lock: the lock lives the extension ttl from the moment of the extension, it is not a sum (the
#     lifetime after a crash does not depend on the number of extensions);
#   - an extension is a Lua script: the owner check and all commands of a lock are one atomic step
#     in one round trip of the whole tick (mutual exclusion stays with `WATCH`/`MULTI` of the
#     acquirement: an extension changes the ttl of an already held lock only);
#   - the lock of a stuck block is not kept forever: see `max_hold_time` (the extension just stops,
#     nothing depends on the client: the lock expires by itself);
#   - the block of code can move its hold limit while it makes progress
#     (`RedisQueuedLocks::LockLease#hold_for`, see `#hold_for`); this thread interrupts a `timed`
#     block of code at the hold limit (a `Timeout` can not be moved);
#   - `fork`: the thread does not survive and the locks of the parent process are not the locks of
#     the child: the first lease of the child process starts with an empty state;
#   - a thread of the same process has the same limits as the block of code: see README "Lock auto
#     extension" (the Global VM Lock, the garbage collector);
#
# @api private
# @since 1.24.0
# rubocop:disable Metrics/ClassLength
class RedisQueuedLocks::LockKeeper
  require_relative 'lock_keeper/log_visitor'
  require_relative 'lock_keeper/instr_visitor'
  require_relative 'lock_keeper/lease'

  # @since 1.24.0
  include RedisQueuedLocks::Utilities

  # Extends the write lock of the acquirer (`LOST_LOCK_REPLY` if the lock is lost, the remaining ttl
  # otherwise):
  #   - `GT`: the extension never shortens the lock (the ttl of a reentrant lock extension);
  #   - (lock index) the score is the absolute upper bound of the lock lifetime (`XX`: a lock
  #     without an index entry is not indexed, `GT`: the score never decreases); `KEYS[2]` is sent
  #     with the enabled lock index only;
  #
  # @return [String]
  #
  # @api private
  # @since 1.24.0
  EXTEND_WRITE_LOCK = <<~LUA_SCRIPT.strip.tr("\n", '').freeze
    if redis.call("HGET", KEYS[1], "acq_id") ~= ARGV[1] then return -3 end;
    redis.call("PEXPIRE", KEYS[1], ARGV[2], "GT");
    if KEYS[2] then redis.call("ZADD", KEYS[2], "XX", "GT", ARGV[3], ARGV[4]) end;
    return redis.call("PTTL", KEYS[1]);
  LUA_SCRIPT

  # Extends the read lock of the acquirer (`LOST_LOCK_REPLY` if the lock is lost, the remaining ttl
  # otherwise):
  #   - an expired read lock is never "revived": a writer could obtain the expired lock;
  #   - the registry and the read lock data keep the longest ttl (`PEXPIRE NX` + `GT`);
  #   - (lock index) see `EXTEND_WRITE_LOCK`, `KEYS[4]`;
  #
  # @return [String]
  #
  # @api private
  # @since 1.24.0
  EXTEND_READ_LOCK = <<~LUA_SCRIPT.strip.tr("\n", '').freeze
    if redis.call("EXISTS", KEYS[1]) == 1 then return -3 end;
    local redis_time = redis.call("TIME");
    local now = redis_time[1] * 1000 + math.floor(redis_time[2] / 1000);
    local expiration = redis.call("ZSCORE", KEYS[2], ARGV[1]);
    if (not expiration) or tonumber(expiration) <= now then return -3 end;
    redis.call("ZADD", KEYS[2], "XX", "GT", now + ARGV[2], ARGV[1]);
    redis.call("PEXPIRE", KEYS[2], ARGV[2], "NX");
    redis.call("PEXPIRE", KEYS[2], ARGV[2], "GT");
    redis.call("PEXPIRE", KEYS[3], ARGV[2], "NX");
    redis.call("PEXPIRE", KEYS[3], ARGV[2], "GT");
    if KEYS[4] then redis.call("ZADD", KEYS[4], "XX", "GT", ARGV[3], ARGV[4]) end;
    return redis.call("ZSCORE", KEYS[2], ARGV[1]) - now;
  LUA_SCRIPT

  # @return [Integer] The reply of the extension scripts for a lost lock (not a `PTTL` reply).
  #
  # @api private
  # @since 1.24.0
  LOST_LOCK_REPLY = -3

  # @return [Integer] The keeper thread stops after this time without new leases (in milliseconds).
  #
  # @api private
  # @since 1.24.0
  IDLE_TIMEOUT = 60_000

  # An idle keeper follows the rhythm of the extensions, but it does not wake up more often than
  # this (in milliseconds): a lease with a shorter interval just wakes it up by itself.
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.24.0
  MIN_IDLE_WAKE_UP_INTERVAL = 100

  # A failed extension is retried sooner: `extension_interval / EXTENSION_RETRY_RATIO`.
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.24.0
  EXTENSION_RETRY_RATIO = 3

  # The leases that are due in `extension_interval / EXTENSION_BATCHING_RATIO` are extended with the
  # due ones: one pipeline instead of a wake-up per lease.
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.24.0
  EXTENSION_BATCHING_RATIO = 10

  # @return [RedisClient]
  #
  # @api private
  # @since 1.24.0
  attr_reader :redis_client

  # @return [RedisQueuedLocks::Utilities::Lock]
  #
  # @api private
  # @since 1.24.0
  attr_reader :sync

  # @return [Thread,NilClass]
  #
  # @api private
  # @since 1.24.0
  attr_reader :thread

  # @param redis_client [RedisClient]
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def initialize(redis_client)
    @redis_client = redis_client
    @sync = RedisQueuedLocks::Utilities::Lock.new
    @leases = {} #: Hash[Lease,bool]
    @wakeups = ::Thread::Queue.new
    @wake_at = nil
    @last_lease_at = 0
    @idle_wake_up_interval = IDLE_TIMEOUT
    @thread = nil
    @process_id = ::Process.pid
  end

  # Prepares the keeper before the lock is obtained: the thread and its connection have time to
  # start before the first extension (a connection takes several round trips, a slow start under
  # the load of the process eats the lifetime of the first lock).
  #
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def start
    sync.synchronize { run_keeper_thread }
  end

  # Starts to keep the locks of the block of code alive.
  #
  # @param lock_keys [Array<String>]
  # @param lock_readers_keys [Array<String>]
  # @param read_lock_keys [Array<String,NilClass>]
  # @param rw_modes [Array<Symbol>] The modes of the really held locks.
  # @param lock_names [Array<String>]
  # @param acquirer_id [String]
  # @param host_id [String]
  # @param try_start_time [Integer]
  #   The start of the attempt that obtained the locks (`Utilities#clock_gettime`, microseconds):
  #   the lock ttl and the hold limit start inside the attempt (the moment is unknown on the
  #   client), so all deadlines are counted from an earlier moment.
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
  # @return [RedisQueuedLocks::LockKeeper::Lease]
  #
  # @api private
  # @since 1.24.0
  # rubocop:disable Metrics/MethodLength
  def keep(
    lock_keys,
    lock_readers_keys,
    read_lock_keys,
    rw_modes,
    lock_names,
    acquirer_id,
    host_id,
    try_start_time,
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
    lease = Lease.new(
      lock_keys,
      lock_readers_keys,
      read_lock_keys,
      rw_modes,
      lock_names,
      acquirer_id,
      host_id,
      try_start_time / 1_000,
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

    sync.synchronize do
      run_keeper_thread
      @leases[lease] = true
      @last_lease_at = monotonic_time
      @idle_wake_up_interval = [lease.extension_interval, MIN_IDLE_WAKE_UP_INTERVAL].max
      # NOTE: the thread sleeps till the nearest extension (or till its idle wake-up): a later one
      #   needs no wake-up (no context switch per block of code);
      wake_at = @wake_at
      @wakeups << true if !wake_at || lease.next_extension_at < wake_at
    end

    lease
  end
  # rubocop:enable Metrics/MethodLength

  # Allows the keeper to interrupt the `timed` block of code when a lock is lost or the hold limit
  # is reached. It is called inside the `rescue` scope of the interruption
  # (`YieldExpire#yield_with_timeout`) and `#forget` is the end of the interruption period: an
  # internal error can not reach the application:
  #   - a lock that is already lost (or the reached hold limit) interrupts the block here (the
  #     block is not invoked);
  #   - `Thread#raise` reaches the current fiber of the thread only: a non-blocking fiber (a fiber
  #     scheduler task, for example) can be suspended, and the error would interrupt another fiber:
  #     such a block is not interrupted (`interrupted_thread` stays `nil`: its hold limit is a
  #     `Timeout`);
  #
  # @param lease [RedisQueuedLocks::LockKeeper::Lease]
  # @return [void]
  #
  # @raise [RedisQueuedLocks::TimedLockIntermediateTimeoutError]
  #
  # @api private
  # @since 1.24.0
  def interrupt_timed_block(lease)
    sync.synchronize do
      if lease.lost?
        raise(RedisQueuedLocks::TimedLockIntermediateTimeoutError, 'A lock is already lost')
      end
      if lease.hold_stopped?
        raise(RedisQueuedLocks::TimedLockIntermediateTimeoutError, 'The hold limit is reached')
      end

      lease.interrupted_thread = ::Thread.current if ::Fiber.current.blocking?
    end
  end

  # Stops to keep the locks of the block of code (it is safe to call it several times). A running
  # tick can still send its extension: the extension checks the owner of the lock.
  #
  # @param lease [RedisQueuedLocks::LockKeeper::Lease]
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def forget(lease)
    sync.synchronize { @leases.delete(lease) }
  end

  # Moves the hold limit of the block of code (`RedisQueuedLocks::LockLease#hold_for`): its locks
  # are kept at least `hold_time` from now (the limit never moves back) and they are extended at
  # once, in the thread of the caller:
  #   - at once: the last extensions before the limit are shortened to the limit, so a limit that is
  #     moved right before it could miss the next tick (a delayed keeper thread); `ok: true` means
  #     that all locks are still owned and extended;
  #   - with the connection of the client: the connection of the keeper belongs to its thread;
  #   - under the lock of the keeper: a stopped lease is never extended again, and a tick that has
  #     found the old limit reached does not stop the moved one (`#stop_hold` checks it again);
  #   - a lost lock is reported once (`auto_extended_lock_lost`) and interrupts a `timed` block of
  #     code (the error is raised here when the block of code itself calls it);
  #   - a dead keeper thread is revived (the next extensions are its work);
  #
  # @param redis [RedisClient] The connection of the client.
  # @param lease [RedisQueuedLocks::LockKeeper::Lease]
  # @param hold_time [Integer] In milliseconds.
  # @return [Hash<Symbol,Boolean|Symbol>] See `RedisQueuedLocks::LockLease#hold_for`.
  #
  # @raise [RedisQueuedLocks::TimedLockIntermediateTimeoutError]
  #
  # @api private
  # @since 1.24.0
  # rubocop:disable Metrics/MethodLength
  def hold_for(redis, lease, hold_time)
    # NOTE: the time before the commands: the new limit is counted from an earlier moment;
    time = monotonic_time
    status = sync.synchronize do
      if lease.lost?
        :lock_lost
      elsif lease.hold_stopped?
        :hold_limit_reached
      elsif @process_id != ::Process.pid || !@leases.key?(lease)
        # NOTE: the block of code is completed (or it is a lease of the parent process: `fork`);
        :released
      else
        run_keeper_thread
        lease.hold_until(time + hold_time)
        nil
      end
    end
    return { ok: false, result: status } if status

    lock_indexes = extended_lock_indexes(lease)
    # NOTE: (pipeline layout) one reply per lock of `lock_indexes`, in their order;
    # @type var replies: Array[Integer]
    replies = redis.pipelined do |pipeline|
      pipeline_lease_extension(pipeline, lease, lock_indexes, time)
    end
    lock_lost = false

    lock_indexes.each_with_index do |lock_index, reply_position|
      reply = replies[reply_position]

      if reply == LOST_LOCK_REPLY
        lock_lost = true
        report_lost_lock(lease, lock_index, time)
      else
        report_held_lock(lease, lock_index, time, hold_time, reply)
      end
    end

    lock_lost ? { ok: false, result: :lock_lost } : { ok: true, result: :extended }
  end
  # rubocop:enable Metrics/MethodLength

  # @param lease [RedisQueuedLocks::LockKeeper::Lease]
  # @return [Integer,NilClass] The time left till the hold limit (in milliseconds), `nil`: no limit.
  #
  # @api private
  # @since 1.24.0
  def hold_time_left(lease)
    lease.hold_time_left(monotonic_time)
  end

  private

  # NOTE: (fork) only the thread that called `fork` survives: the leases of the parent process are
  #   dropped, the parent process extends its locks by itself (an extension from the child process
  #   would keep alive the locks of a dead parent process);
  #
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def run_keeper_thread
    if @process_id != ::Process.pid
      @process_id = ::Process.pid
      @leases = {}
      @wake_at = nil
      @thread = nil
    end

    return if @thread&.alive?

    # NOTE: the client is built here (not in the thread): a client without the connection config
    #   fails in the lock logic, not silently in the background;
    redis = redis_client.config.new_client
    @last_lease_at = monotonic_time
    thread = ::Thread.new do
      # NOTE: a new thread inherits the interrupt mask of the current one (ruby/timeout#41);
      # NOTE: (steep) `Thread.handle_interrupt` has no block in the RBS of the Ruby core;
      ::Thread.handle_interrupt(Object => :immediate) { keep_locks(redis) } # steep:ignore
    end
    thread.name = 'rql.lock_keeper'
    @thread = thread
  end

  # @param redis [RedisClient]
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def keep_locks(redis)
    # NOTE: connect before the first extension (see `#start`); an unavailable Redis is reported by
    #   the extensions;
    run_non_critical { redis.call('PING') }

    while (leases = wait_for_due_leases)
      extend_locks(redis, leases)
    end
  ensure
    redis.close
  end

  # @return [Array<RedisQueuedLocks::LockKeeper::Lease>,NilClass]
  #   The leases that should be extended now, `nil` when the thread should stop (no leases).
  #
  # @api private
  # @since 1.24.0
  # rubocop:disable Metrics/MethodLength
  def wait_for_due_leases
    loop do
      wait_time = sync.synchronize do
        now = monotonic_time
        @wakeups.clear
        leases = @leases.keys
        next_extension_at = leases.map(&:next_extension_at).min

        if next_extension_at == nil
          # NOTE: (idle) counted from the last lease, not from the last lease seen here: a short
          #   block of code ends before this thread gets the GVL, and the leases are in use;
          idle_time = now - @last_lease_at

          if idle_time >= IDLE_TIMEOUT
            # NOTE: under the lock: a new lease sees the stopped thread and starts a new one;
            @thread = nil
            return nil
          end

          # NOTE: (idle) the rhythm of the extensions: the next lease with the same ttl is due later
          #   than this wake-up, so a stream of short blocks does not wake the thread per block;
          idle_wait = [IDLE_TIMEOUT - idle_time, @idle_wake_up_interval].min #: Integer
          @wake_at = now + idle_wait
          idle_wait
        elsif next_extension_at > now
          @wake_at = next_extension_at
          next_extension_at - now
        else
          return leases.select do |lease|
            lease.next_extension_at <= now + (lease.extension_interval / EXTENSION_BATCHING_RATIO)
          end
        end
      end

      @wakeups.pop(timeout: wait_time / 1_000.0)
    end
  end
  # rubocop:enable Metrics/MethodLength

  # @param redis [RedisClient]
  # @param due_leases [Array<RedisQueuedLocks::LockKeeper::Lease>]
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def extend_locks(redis, due_leases)
    # NOTE: the time before the commands: all deadlines are counted from an earlier moment;
    time = monotonic_time
    stopped_leases, leases = due_leases.partition { |lease| lease.hold_limit_reached?(time) }
    stopped_leases.each { |lease| stop_hold(lease, time) }
    return if leases.empty?

    # NOTE: the locks that are not lost yet: the thread of a block of code can lose a lock during
    #   the tick (`#hold_for`), so the replies are read by these indexes;
    lock_indexes = leases.map { |lease| extended_lock_indexes(lease) }

    begin
      # NOTE: (pipeline layout) one reply per lock of `lock_indexes`, in the order of the leases;
      # @type var replies: Array[Integer]
      replies = redis.pipelined do |pipeline|
        leases.each_with_index do |lease, lease_position|
          pipeline_lease_extension(pipeline, lease, lock_indexes[lease_position], time)
        end
      end
    rescue ::StandardError => error
      # NOTE: the lock can still live: the next try comes sooner, a lost lock is found by it; the
      #   blocks of code that are completed during the tick have nothing to report;
      kept_leases = sync.synchronize { leases.select { |lease| @leases.key?(lease) } }
      kept_leases.each { |lease| report_failed_extension(lease, time, error) }
      return
    end

    process_extension_replies(leases, lock_indexes, replies, time)
  end

  # @param leases [Array<RedisQueuedLocks::LockKeeper::Lease>]
  # @param lock_indexes [Array<Array<Integer>>] The extended locks of each lease.
  # @param replies [Array<Integer>] See the pipeline layout of `#extend_locks`.
  # @param time [Integer]
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def process_extension_replies(leases, lock_indexes, replies, time)
    reply_position = 0

    leases.each_with_index do |lease, lease_position|
      lease.schedule_extension(time + lease.extension_interval)
      lease_kept = sync.synchronize { @leases.key?(lease) }

      lock_indexes[lease_position].each do |lock_index|
        reply = replies[reply_position]
        reply_position += 1
        # NOTE: the block of code is completed and its lock is released during the tick, or the
        #   lock is found lost by the thread of the block meanwhile (`#hold_for`);
        next if !lease_kept || lease.lock_lost?(lock_index)

        if reply == LOST_LOCK_REPLY
          report_lost_lock(lease, lock_index, time)
        else
          report_extended_lock(lease, lock_index, time, reply)
        end
      end
    end
  end

  # @param lease [RedisQueuedLocks::LockKeeper::Lease]
  # @return [Array<Integer>] The indexes of the locks that are not lost.
  #
  # @api private
  # @since 1.24.0
  def extended_lock_indexes(lease)
    lease.lock_keys.each_index.reject { |lock_index| lease.lock_lost?(lock_index) }
  end

  # @param pipeline [RedisClient::Pipeline]
  # @param lease [RedisQueuedLocks::LockKeeper::Lease]
  # @param lock_indexes [Array<Integer>] The locks to extend (one reply per lock, in this order).
  # @param time [Integer]
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  # rubocop:disable Metrics/MethodLength
  def pipeline_lease_extension(pipeline, lease, lock_indexes, time)
    extension_ttl = lease.extension_ttl_at(time)
    index_score =
      if lease.lock_index_enabled
        RedisQueuedLocks::Resource.lock_index_time + extension_ttl + lease.lock_index_grace_period
      end

    lock_indexes.each do |lock_index|
      lock_key = lease.lock_keys[lock_index]
      read_lock = lease.rw_modes[lock_index] == :read

      if lease.lock_index_enabled && read_lock
        pipeline.call(
          'EVAL', EXTEND_READ_LOCK, 4,
          lock_key, lease.lock_readers_keys[lock_index], lease.read_lock_keys[lock_index],
          RedisQueuedLocks::Resource::LOCK_INDEX_KEY,
          lease.acquirer_id, extension_ttl, index_score, lease.lock_names[lock_index]
        )
      elsif lease.lock_index_enabled
        pipeline.call(
          'EVAL', EXTEND_WRITE_LOCK, 2,
          lock_key, RedisQueuedLocks::Resource::LOCK_INDEX_KEY,
          lease.acquirer_id, extension_ttl, index_score, lease.lock_names[lock_index]
        )
      elsif read_lock
        pipeline.call(
          'EVAL', EXTEND_READ_LOCK, 3,
          lock_key, lease.lock_readers_keys[lock_index], lease.read_lock_keys[lock_index],
          lease.acquirer_id, extension_ttl
        )
      else
        pipeline.call('EVAL', EXTEND_WRITE_LOCK, 1, lock_key, lease.acquirer_id, extension_ttl)
      end
    end
  end
  # rubocop:enable Metrics/MethodLength

  # The hold limit is reached: the lock is not extended anymore (it expires by itself), a `timed`
  # block of code is interrupted.
  #
  # @param lease [RedisQueuedLocks::LockKeeper::Lease]
  # @param time [Integer] The time of the tick.
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def stop_hold(lease, time)
    is_stopped = sync.synchronize do
      # NOTE: the block of code is completed during the tick, or the limit is moved after the tick
      #   has found it reached (`#hold_for`: the lease is due, the next tick extends it);
      next false unless @leases.key?(lease) && lease.hold_limit_reached?(time)

      @leases.delete(lease)
      lease.stop_hold
      # NOTE: under the lock: see `#report_lost_lock`;
      lease.interrupted_thread&.raise(
        RedisQueuedLocks::TimedLockIntermediateTimeoutError,
        "The hold limit (#{lease.max_hold_time}) of the locks is reached"
      )
      true
    end
    return unless is_stopped

    lease.lock_keys.each_with_index do |lock_key, lock_index|
      next if lease.lock_lost?(lock_index)

      LogVisitor.lock_hold_limit_reached(
        lease.logger, lease.log_sampled, lock_key, lease.rw_modes[lock_index],
        lease.max_hold_time, lease.acquirer_id, lease.host_id
      )
      InstrVisitor.lock_hold_limit_reached(
        lease.instrumenter, lease.instr_sampled, lock_key, lease.rw_modes[lock_index],
        lease.max_hold_time, lease.acquirer_id, lease.host_id, lease.instrument
      )
    end
  end

  # @param lease [RedisQueuedLocks::LockKeeper::Lease]
  # @param lock_index [Integer]
  # @param time [Integer]
  # @param rem_ttl [Integer]
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def report_extended_lock(lease, lock_index, time, rem_ttl)
    LogVisitor.lock_auto_extended(
      lease.logger, lease.log_sampled, lease.lock_keys[lock_index], lease.rw_modes[lock_index],
      lease.extension_ttl_at(time), rem_ttl, lease.acquirer_id, lease.host_id
    )
    InstrVisitor.lock_auto_extended(
      lease.instrumenter, lease.instr_sampled, lease.lock_keys[lock_index],
      lease.rw_modes[lock_index], lease.extension_ttl_at(time), rem_ttl, lease.acquirer_id,
      lease.host_id, lease.instrument
    )
  end

  # @param lease [RedisQueuedLocks::LockKeeper::Lease]
  # @param time [Integer]
  # @param error [StandardError]
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def report_failed_extension(lease, time, error)
    lease.schedule_extension(
      time + [lease.extension_interval / EXTENSION_RETRY_RATIO, 1].max
    )

    lease.lock_keys.each_with_index do |lock_key, lock_index|
      next if lease.lock_lost?(lock_index)

      LogVisitor.lock_auto_extension_failed(
        lease.logger, lease.log_sampled, lock_key, lease.rw_modes[lock_index],
        lease.extension_ttl_at(time), lease.acquirer_id, lease.host_id, error.class.name.to_s
      )
      InstrVisitor.lock_auto_extension_failed(
        lease.instrumenter, lease.instr_sampled, lock_key, lease.rw_modes[lock_index],
        lease.extension_ttl_at(time), lease.acquirer_id, lease.host_id, error.class.name.to_s,
        lease.instrument
      )
    end
  end

  # @param lease [RedisQueuedLocks::LockKeeper::Lease]
  # @param lock_index [Integer]
  # @param time [Integer]
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  # rubocop:disable Metrics/MethodLength
  def report_lost_lock(lease, lock_index, time)
    interrupts_current_thread = false
    # NOTE: under the lock: `#forget` returns only when the block can not be interrupted anymore
    #   (an interruption after the block of code would reach the code of the application);
    is_lost = sync.synchronize do
      # NOTE: a lock is lost once: the keeper thread and the thread of the block (`#hold_for`) can
      #   find it lost at the same time;
      next false if !@leases.key?(lease) || lease.lock_lost?(lock_index)

      lease.lose_lock(lock_index)
      interrupted_thread = lease.interrupted_thread

      if interrupted_thread == ::Thread.current
        # NOTE: `#hold_for` of the `timed` block of code itself: the error is raised after the
        #   report (the block is running: no race with `#forget`);
        @leases.delete(lease)
        interrupts_current_thread = true
      elsif interrupted_thread
        @leases.delete(lease)
        interrupted_thread.raise(
          RedisQueuedLocks::TimedLockIntermediateTimeoutError,
          "The lock \"#{lease.lock_keys[lock_index]}\" is lost"
        )
      elsif lease.all_locks_lost?
        @leases.delete(lease)
      end

      true
    end
    return unless is_lost

    LogVisitor.auto_extended_lock_lost(
      lease.logger, lease.log_sampled, lease.lock_keys[lock_index], lease.rw_modes[lock_index],
      lease.acquirer_id, lease.host_id, time - lease.started_at
    )
    InstrVisitor.auto_extended_lock_lost(
      lease.instrumenter, lease.instr_sampled, lease.lock_keys[lock_index],
      lease.rw_modes[lock_index], lease.acquirer_id, lease.host_id, time - lease.started_at,
      lease.instrument
    )
    return unless interrupts_current_thread

    raise(
      RedisQueuedLocks::TimedLockIntermediateTimeoutError,
      "The lock \"#{lease.lock_keys[lock_index]}\" is lost"
    )
  end
  # rubocop:enable Metrics/MethodLength

  # @param lease [RedisQueuedLocks::LockKeeper::Lease]
  # @param lock_index [Integer]
  # @param time [Integer]
  # @param hold_time [Integer] The requested time (in milliseconds).
  # @param rem_ttl [Integer]
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def report_held_lock(lease, lock_index, time, hold_time, rem_ttl)
    LogVisitor.lock_hold_limit_extended(
      lease.logger, lease.log_sampled, lease.lock_keys[lock_index], lease.rw_modes[lock_index],
      hold_time, lease.hold_time_left(time), lease.extension_ttl_at(time), rem_ttl,
      lease.acquirer_id, lease.host_id
    )
    InstrVisitor.lock_hold_limit_extended(
      lease.instrumenter, lease.instr_sampled, lease.lock_keys[lock_index],
      lease.rw_modes[lock_index], hold_time, lease.hold_time_left(time),
      lease.extension_ttl_at(time), rem_ttl, lease.acquirer_id, lease.host_id, lease.instrument
    )
  end

  # @return [Integer] In milliseconds.
  #
  # @api private
  # @since 1.24.0
  def monotonic_time
    clock_gettime / 1_000
  end
end
# rubocop:enable Metrics/ClassLength
