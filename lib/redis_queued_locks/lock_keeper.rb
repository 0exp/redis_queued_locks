# frozen_string_literal: true

# Keeps the locks of the running blocks of code alive (the `auto_extend: true` option of `#lock`
# and `#lock_series`): one background thread per client extends the locks of all blocks while they
# are running, so the lock ttl is a lease: the crash of the process releases the lock by the ttl,
# whatever the duration of the block of code is:
#   - the thread and its Redis connection are created on demand and stop after the idle timeout
#     without new leases (`config['lock_keeper.idle_timeout']`);
#   - the thread has its own connection (from the config of the client): the client can be a plain
#     `RedisClient` (one connection), it can not be shared with the threads of the application;
#   - an extension checks the owner of the lock, never revives a lost lock and never shortens the
#     lock: the lock lives the extension ttl from the moment of the extension, it is not a sum (the
#     lifetime after a crash does not depend on the number of extensions);
#   - an extension is a Lua script: the owner check and all commands of a lock are one atomic step
#     in one round trip of the whole tick (mutual exclusion stays with `WATCH`/`MULTI` of the
#     acquirement: an extension changes the ttl of an already held lock only);
#   - the lock of a stuck block is not kept forever: see `max_hold_time_during_auto_extend` (the
#     extension just stops, nothing depends on the client: the lock expires by itself);
#   - the block of code can move its hold limit while it makes progress
#     (`RedisQueuedLocks::LockKeeper::LockLease#hold_for`, see `#hold_for`); this thread interrupts
#     a `timed` block of code at the hold limit (a `Timeout` can not be moved): `Thread#raise` in
#     a blocking fiber, the fiber scheduler in a non-blocking one (see `#interrupt_timed_block`);
#   - the leases are planned in a timer wheel (`config['lock_keeper.schedule_slot']`): a wake-up
#     takes the due slots only and `#keep`/`#forget` change one slot, so the work under the lock
#     does not grow with the number of running blocks of code;
#   - `fork`: the thread does not survive and the locks of the parent process are not the locks of
#     the child: the first lease of the child process starts with an empty state;
#   - the settings of the keeper are `config['lock_keeper.*']` of the client (read when the
#     thread starts, see `#load_settings`);
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
  require_relative 'lock_keeper/lock_lease'

  # @since 1.24.0
  include RedisQueuedLocks::Utilities

  # Extends the write lock of the acquirer (`EXTEND_LOCK_LUA_LOST_LOCK_REPLY` if the lock is lost,
  # the remaining ttl otherwise):
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

  # Extends the read lock of the acquirer (`EXTEND_LOCK_LUA_LOST_LOCK_REPLY` if the lock is lost,
  # the remaining ttl otherwise):
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

  # The reply of the Lua scripts of the lock extension (`EXTEND_WRITE_LOCK`, `EXTEND_READ_LOCK`)
  # for a lost lock: the lock is not owned anymore (not a `PTTL` reply: they return `-3` literally).
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.24.0
  EXTEND_LOCK_LUA_LOST_LOCK_REPLY = -3

  # @return [RedisQueuedLocks::Client]
  #
  # @api private
  # @since 1.24.0
  attr_reader :rql_client

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

  # NOTE: (settings) `config['lock_keeper.*']` of the client, read when the keeper thread starts
  #   (`#load_settings`): a changed setting takes effect at the next start of the thread (after
  #   its idle timeout or in a new process); the schedule is rebuilt with the new slot length;

  # @return [Integer]
  #   The keeper thread stops after this time without new leases (in milliseconds,
  #   `config['lock_keeper.idle_timeout']`).
  #
  # @api private
  # @since 1.24.0
  attr_reader :idle_timeout

  # An idle keeper follows the rhythm of the extensions, but it does not wake up more often than
  # this (in milliseconds, `config['lock_keeper.min_idle_wake_up_interval']`): a lease with a
  # shorter interval just wakes it up by itself.
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.24.0
  attr_reader :min_idle_wake_up_interval

  # A failed extension is retried sooner: `extension_interval / extension_retry_ratio`
  # (`config['lock_keeper.extension_retry_ratio']`).
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.24.0
  attr_reader :extension_retry_ratio

  # The leases that are due in `extension_interval / extension_batching_ratio` are extended with the
  # due ones (`config['lock_keeper.extension_batching_ratio']`): one pipeline instead of a wake-up
  # per lease.
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.24.0
  attr_reader :extension_batching_ratio

  # The schedule of the leases is a set of slots of this length (in milliseconds,
  # `config['lock_keeper.schedule_slot']`) by the time of their next extension: a wake-up looks at
  # the leases of the due slots only, not at all leases (the work under the lock does not grow with
  # the number of the running blocks of code).
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.24.0
  attr_reader :schedule_slot

  # How long the fiber of a `timed` block of code waits for the interruption that is sent through
  # its fiber scheduler when the block ends before it comes (in milliseconds,
  # `config['lock_keeper.fiber_interruption_timeout']`, see `#forget`): the scheduler raises it at
  # the next suspension point of the fiber, and a scheduler that does not raise it in this time is
  # not waited for anymore.
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.24.0
  attr_reader :fiber_interruption_timeout

  # The step of this wait (in seconds, `Kernel#sleep`,
  # `config['lock_keeper.fiber_interruption_wait_step']`): each step suspends the fiber, so its
  # scheduler gets the control and raises the interruption.
  #
  # @return [Float,Integer]
  #
  # @api private
  # @since 1.24.0
  attr_reader :fiber_interruption_wait_step

  # @param rql_client [RedisQueuedLocks::Client]
  #   The client of the keeper (its connection and its config).
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def initialize(rql_client)
    @rql_client = rql_client
    @sync = RedisQueuedLocks::Utilities::Lock.new
    @leases = {} #: Hash[Lease,bool]
    # NOTE: the schedule (under the lock): the leases by the slot of their next extension and the
    #   sorted slots (the first one is the nearest);
    @buckets = {} #: Hash[Integer,Hash[Lease,bool]]
    @slot_keys = [] #: Array[Integer]
    @wakeups = ::Thread::Queue.new
    @wake_at = nil
    @last_lease_at = 0
    @thread = nil
    @process_id = ::Process.pid
    load_settings
    @idle_wake_up_interval = idle_timeout
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
  # @param max_hold_time_during_auto_extend [Integer,NilClass]
  #   The hold limit (in milliseconds), `nil`: no limit.
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
    max_hold_time_during_auto_extend,
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
      max_hold_time_during_auto_extend,
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
      schedule(lease)
      @last_lease_at = monotonic_time
      @idle_wake_up_interval = [lease.extension_interval, min_idle_wake_up_interval].max
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
  #   - a blocking fiber is interrupted with `Thread#raise`;
  #   - a non-blocking fiber (a fiber scheduler task, for example) can be suspended, and
  #     `Thread#raise` reaches the current fiber of the thread only (it would interrupt another
  #     task), `Fiber#raise` can not be called by another thread: such a block is interrupted
  #     through its scheduler (`Fiber::Scheduler#fiber_interrupt`, Ruby 4.0: it may be called by
  #     another thread); a scheduler without this hook (or no scheduler) can not interrupt it: its
  #     hold limit is a `Timeout`, a lost lock interrupts it only when the block finds it by itself
  #     (`#hold_for`);
  #
  # @param lease [RedisQueuedLocks::LockKeeper::Lease]
  # @return [void]
  #
  # @raise [RedisQueuedLocks::TimedLockIntermediateTimeoutError]
  #
  # @api private
  # @since 1.24.0
  def interrupt_timed_block(lease)
    fiber = ::Fiber.current
    fiber_scheduler = fiber.blocking? ? nil : ::Fiber.scheduler

    sync.synchronize do
      if lease.lost?
        raise(RedisQueuedLocks::TimedLockIntermediateTimeoutError, 'A lock is already lost')
      end
      if lease.hold_stopped?
        raise(RedisQueuedLocks::TimedLockIntermediateTimeoutError, 'The hold limit is reached')
      end

      lease.timed_fiber = fiber
      if fiber.blocking?
        lease.interrupted_thread = ::Thread.current
      elsif fiber_scheduler.respond_to?(:fiber_interrupt)
        lease.fiber_scheduler = fiber_scheduler
      end
    end
  end

  # Stops to keep the locks of the block of code (it is safe to call it several times). A running
  # tick can still send its extension: the extension checks the owner of the lock.
  #
  # An interruption sent through the fiber scheduler can not be cancelled, and it comes at the next
  # suspension point of the fiber: when the block of code ends before it comes, the fiber waits for
  # it here (inside the `rescue` scope of the interruption, see `#fiber_interruption_timeout`), so
  # it never reaches the code of the application after the block.
  #
  # @param lease [RedisQueuedLocks::LockKeeper::Lease]
  # @param raised_error [Exception,NilClass]
  #   The error that has stopped the `timed` block of code (an interruption that has already come).
  # @return [void]
  #
  # @raise [RedisQueuedLocks::TimedLockIntermediateTimeoutError]
  #
  # @api private
  # @since 1.24.0
  def forget(lease, raised_error = nil)
    pending_interruption = sync.synchronize do
      unschedule(lease) if @leases.delete(lease)
      # NOTE: the end of the interruption period: a kept lease never interrupts the code after the
      #   block (`#hold_for` of a lost lock returns `:lock_lost` then);
      lease.timed_fiber = nil
      lease.take_pending_interruption(raised_error)
    end

    wait_for_interruption if pending_interruption
  end

  # Moves the hold limit of the block of code (`RedisQueuedLocks::LockKeeper::LockLease#hold_for`):
  # its locks are kept at least `hold_time` from now (the limit never moves back) and they are
  # extended at once, in the thread of the caller:
  #   - at once: the last extensions before the limit are shortened to the limit, so a limit that is
  #     moved right before it could miss the next tick (a delayed keeper thread); `ok: true` means
  #     that all locks are still owned and extended;
  #   - with the connection of the client: the connection of the keeper belongs to its thread;
  #   - under the lock of the keeper: a stopped lease is never extended again, and a tick that has
  #     found the old limit reached does not stop the moved one (`#stop_hold` checks it again);
  #   - a lost lock is reported once (`auto_extended_lock_lost`) and interrupts a `timed` block of
  #     code (the error is raised here when the block of code itself calls it, in any fiber; a
  #     block that the keeper can not interrupt is interrupted here by an earlier loss too);
  #   - a dead keeper thread is revived (the next extensions are its work);
  #
  # @param redis [RedisClient] The connection of the client.
  # @param lease [RedisQueuedLocks::LockKeeper::Lease]
  # @param hold_time [Integer] In milliseconds.
  # @return [Hash<Symbol,Boolean|Symbol>] See `RedisQueuedLocks::LockKeeper::LockLease#hold_for`.
  #
  # @raise [RedisQueuedLocks::TimedLockIntermediateTimeoutError]
  #
  # @api private
  # @since 1.24.0
  # rubocop:disable Metrics/MethodLength
  def hold_for(redis, lease, hold_time)
    # NOTE: the time before the commands: the new limit is counted from an earlier moment;
    time = monotonic_time
    interrupts_caller = false
    status = sync.synchronize do
      if lease.lost?
        # NOTE: a `timed` block of code that the keeper can not interrupt (a non-blocking fiber
        #   without an interrupting fiber scheduler) is interrupted when it finds the lost lock;
        interrupts_caller = !lease.interruptible? && lease.timed_fiber.equal?(::Fiber.current)
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
    if interrupts_caller
      raise(RedisQueuedLocks::TimedLockIntermediateTimeoutError, 'A lock is already lost')
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

      if reply == EXTEND_LOCK_LUA_LOST_LOCK_REPLY
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
      @buckets = {}
      @slot_keys = []
      @wake_at = nil
      @thread = nil
    end

    return if @thread&.alive?

    # NOTE: the client is built here (not in the thread): a client without the connection config
    #   fails in the lock logic, not silently in the background;
    redis = rql_client.redis_client.config.new_client
    # NOTE: a new thread takes the leases of a dead one over: a killed thread can leave the due
    #   leases of its tick out of the schedule (the registry keeps all leases); the slots are
    #   rebuilt with the new settings;
    load_settings
    rebuild_schedule
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
  def wait_for_due_leases
    loop do
      wait_time = sync.synchronize do
        now = monotonic_time
        @wakeups.clear
        next_extension_at = planned_extension_at

        if next_extension_at == nil
          # NOTE: (idle) counted from the last lease, not from the last lease seen here: a short
          #   block of code ends before this thread gets the GVL, and the leases are in use;
          idle_time = now - @last_lease_at

          if idle_time >= idle_timeout
            # NOTE: under the lock: a new lease sees the stopped thread and starts a new one;
            @thread = nil
            return nil
          end

          # NOTE: (idle) the rhythm of the extensions: the next lease with the same ttl is due later
          #   than this wake-up, so a stream of short blocks does not wake the thread per block;
          idle_wait = [idle_timeout - idle_time, @idle_wake_up_interval].min #: Integer
          @wake_at = now + idle_wait
          idle_wait
        elsif next_extension_at > now
          @wake_at = next_extension_at
          next_extension_at - now
        else
          return take_due_leases(now)
        end
      end

      @wakeups.pop(timeout: wait_time / 1_000.0)
    end
  end

  # NOTE: (the schedule) all methods of the schedule are called under the lock (`sync`);
  #
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def rebuild_schedule
    @buckets = {}
    @slot_keys = []
    @leases.each_key { |lease| schedule(lease) }
  end

  # The empty slots in front of the schedule are dropped here (see `#unschedule`).
  #
  # @return [Integer,NilClass] The nearest planned extension, `nil`: no leases.
  #
  # @api private
  # @since 1.24.0
  def planned_extension_at
    while (slot = @slot_keys.first)
      bucket = @buckets.fetch(slot)
      return bucket.each_key.map(&:next_extension_at).min unless bucket.empty?

      @slot_keys.shift
      @buckets.delete(slot)
    end
  end

  # Takes the due leases and the leases that are due in their batching interval out of the
  # schedule (the slots till the batching interval of the nearest lease are looked at): one
  # pipeline instead of a wake-up per lease. The tick puts them back (`#reschedule`).
  #
  # @param now [Integer]
  # @return [Array<RedisQueuedLocks::LockKeeper::Lease>]
  #
  # @api private
  # @since 1.24.0
  def take_due_leases(now)
    first_slot = @slot_keys.first #: Integer
    nearest_lease = @buckets.fetch(first_slot).each_key.min_by(&:next_extension_at) #: Lease
    horizon = now + (nearest_lease.extension_interval / extension_batching_ratio)
    due_leases = [] #: Array[Lease]
    later_leases = [] #: Array[Lease]

    while (slot = @slot_keys.first) && slot * schedule_slot <= horizon
      @slot_keys.shift
      @buckets.delete(slot)&.each_key do |lease|
        if lease.next_extension_at <= now + (lease.extension_interval / extension_batching_ratio)
          due_leases << lease
        else
          later_leases << lease
        end
      end
    end

    later_leases.each { |lease| schedule(lease) }
    due_leases
  end

  # Puts the leases of a tick back into the schedule (the leases of the completed blocks of code
  # and the dropped ones are not in the registry anymore): one section for the whole tick.
  #
  # @param leases [Array<RedisQueuedLocks::LockKeeper::Lease>]
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def reschedule(leases)
    sync.synchronize do
      leases.each { |lease| schedule(lease) if @leases.key?(lease) }
    end
  end

  # @param lease [RedisQueuedLocks::LockKeeper::Lease]
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def schedule(lease)
    slot = lease.next_extension_at / schedule_slot
    bucket = @buckets[slot]

    if bucket
      bucket[lease] = true
    else
      @buckets[slot] = { lease => true }
      slot_index = @slot_keys.bsearch_index { |slot_key| slot_key >= slot } || @slot_keys.size
      @slot_keys.insert(slot_index, slot)
    end
  end

  # NOTE: the slot is found by the planned extension: it changes only while the lease is out of
  #   the schedule (a due lease of a tick); a lease out of the schedule is not found (a no-op);
  #   an empty slot stays till its time (`#planned_extension_at` drops it): a stream of short
  #   blocks of code reuses it (no new slot per block under the lock);
  #
  # @param lease [RedisQueuedLocks::LockKeeper::Lease]
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def unschedule(lease)
    @buckets[lease.next_extension_at / schedule_slot]&.delete(lease)
  end

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
    # NOTE: a limit that is moved after this check (`#hold_for`) keeps the lease: it is extended
    #   with the others (the due leases are out of the schedule till the end of the tick);
    stopped_leases.each { |lease| leases << lease if stop_hold(lease, time) == :moved }
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
      reschedule(leases)
      return
    end

    process_extension_replies(leases, lock_indexes, replies, time)
    reschedule(leases)
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
    # NOTE: one section for the whole tick (not one per lease);
    kept_leases = sync.synchronize { leases.map { |lease| @leases.key?(lease) } }

    leases.each_with_index do |lease, lease_position|
      lease.schedule_extension(time + lease.extension_interval)
      lease_kept = kept_leases[lease_position]

      lock_indexes[lease_position].each do |lock_index|
        reply = replies[reply_position]
        reply_position += 1
        # NOTE: the block of code is completed and its lock is released during the tick, or the
        #   lock is found lost by the thread of the block meanwhile (`#hold_for`);
        next if !lease_kept || lease.lock_lost?(lock_index)

        if reply == EXTEND_LOCK_LUA_LOST_LOCK_REPLY
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
  # @return [Symbol]
  #   - `:stopped` - the hold limit is reached;
  #   - `:moved` - the limit is moved after the tick has found it reached (`#hold_for`);
  #   - `:released` - the block of code is completed during the tick;
  #
  # @api private
  # @since 1.24.0
  def stop_hold(lease, time)
    # @type var status: Symbol
    status = sync.synchronize do
      next :released unless @leases.key?(lease)
      next :moved unless lease.hold_limit_reached?(time)

      @leases.delete(lease)
      lease.stop_hold
      # NOTE: under the lock: see `#report_lost_lock`;
      lease.interrupt(
        "The hold limit (#{lease.max_hold_time_during_auto_extend}) of the locks is reached"
      )
      :stopped
    end
    return status unless status == :stopped

    lease.lock_keys.each_with_index do |lock_key, lock_index|
      next if lease.lock_lost?(lock_index)

      LogVisitor.lock_hold_limit_reached(
        lease.logger, lease.log_sampled, lock_key, lease.rw_modes[lock_index],
        lease.max_hold_time_during_auto_extend, lease.acquirer_id, lease.host_id
      )
      InstrVisitor.lock_hold_limit_reached(
        lease.instrumenter, lease.instr_sampled, lock_key, lease.rw_modes[lock_index],
        lease.max_hold_time_during_auto_extend, lease.acquirer_id, lease.host_id, lease.instrument
      )
    end
    status
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
      time + [lease.extension_interval / extension_retry_ratio, 1].max
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
    interrupts_caller = false
    # NOTE: under the lock: `#forget` returns only when the block can not be interrupted anymore
    #   (an interruption after the block of code would reach the code of the application);
    is_lost = sync.synchronize do
      # NOTE: a lock is lost once: the keeper thread and the thread of the block (`#hold_for`) can
      #   find it lost at the same time;
      next false if !@leases.key?(lease) || lease.lock_lost?(lock_index)

      lease.lose_lock(lock_index)

      # NOTE: a dropped lease is unscheduled too: `#hold_for` can find a lock lost while the lease
      #   waits in the schedule (a due lease of a tick is not in it: a no-op);
      if lease.timed_fiber.equal?(::Fiber.current) || lease.interrupted_thread == ::Thread.current
        # NOTE: `#hold_for` of the `timed` block of code itself (in any fiber, a fiber without an
        #   interrupting scheduler too): the error is raised after the report (the block is
        #   running: no race with `#forget`);
        unschedule(lease) if @leases.delete(lease)
        interrupts_caller = true
      elsif lease.interruptible?
        unschedule(lease) if @leases.delete(lease)
        lease.interrupt("The lock \"#{lease.lock_keys[lock_index]}\" is lost")
      elsif lease.all_locks_lost?
        unschedule(lease) if @leases.delete(lease)
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
    return unless interrupts_caller

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

  # Waits in the fiber of the `timed` block of code for the interruption that is sent through its
  # fiber scheduler (see `#forget`): the interruption is raised out of `sleep` (each step suspends
  # the fiber and gives the control to the scheduler).
  #
  # NOTE: an error of another source that comes during this wait stops it: the interruption can
  #   still come after the block of code then (like two asynchronous errors at once in a thread);
  #
  # @return [void]
  #
  # @raise [RedisQueuedLocks::TimedLockIntermediateTimeoutError]
  #
  # @api private
  # @since 1.24.0
  def wait_for_interruption
    deadline = monotonic_time + fiber_interruption_timeout
    sleep(fiber_interruption_wait_step) while monotonic_time < deadline
  end

  # Reads the settings of the keeper from the config of the client (`config['lock_keeper.*']`).
  #
  # @return [void]
  #
  # @api private
  # @since 1.24.0
  def load_settings
    config = rql_client.config
    @idle_timeout = config['lock_keeper.idle_timeout']
    @min_idle_wake_up_interval = config['lock_keeper.min_idle_wake_up_interval']
    @extension_retry_ratio = config['lock_keeper.extension_retry_ratio']
    @extension_batching_ratio = config['lock_keeper.extension_batching_ratio']
    @schedule_slot = config['lock_keeper.schedule_slot']
    @fiber_interruption_timeout = config['lock_keeper.fiber_interruption_timeout']
    @fiber_interruption_wait_step = config['lock_keeper.fiber_interruption_wait_step']
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
