# frozen_string_literal: true

# One attempt to obtain all locks of the lock series (all or nothing, see
# `RedisQueuedLocks::Acquirer::LockSeries`):
#   - mutual exclusion relies on the optimistic transaction only (WATCH/MULTI): the attempt watches
#     the lock state of all locks of the series (write lock requests: the write lock keys and the
#     readers registries, read lock requests: the write lock keys), reads the state of all locks
#     in one round trip and obtains all locks with one transaction;
#   - nothing is held while the series waits: the attempt that can not obtain some lock of
#     the series obtains nothing, so hold-and-wait is impossible;
#   - the lock request of the series has one position in all lock request queues of the series
#     (and in both modes): the requests are ordered by `(score, acq_id)` in all queues in the same
#     way, so a request waits for earlier requests only and the requests can not wait for each
#     other in a cycle (lock series are deadlock-free: for any order of the lock names);
#   - the state and the queueing commands of each lock are the commands of the single lock attempt
#     (`pipeline_lock_state`, `queue_lock_request`), the replies are read by the same position
#     constants per lock; the decisions (`same_process_conflict_status`, `lock_obstacle`,
#     `find_opposite_request_ahead`, `find_dead_requests_ahead`) and the transaction commands
#     (`transact_*`) are shared with the single lock attempt too;
#   - the try-lock logs are the logs of the single lock attempt: one event per lock of the series
#     (`RedisQueuedLocks::Acquirer::AcquireLock::TryToLock::LogVisitor`, it is the `LogVisitor`
#     constant here: `TryToLock` is included);
#
# @api private
# @since 1.23.0
# rubocop:disable Metrics/ModuleLength
module RedisQueuedLocks::Acquirer::LockSeries::TryToLockSeries
  # @since 1.23.0
  include RedisQueuedLocks::Acquirer::AcquireLock::TryToLock
  # @since 1.23.0
  include RedisQueuedLocks::Acquirer::LockSeries::ReleaseLockSeries

  # @param redis [RedisClient]
  # @param logger [::Logger,#debug]
  # @param log_lock_try [Boolean]
  # @param lock_keys [Array<String>]
  # @param read_write_mode [Symbol] `:read` or `:write` (one mode for the whole series).
  # @param lock_key_queues [Array<String>] Queues of write lock requests.
  # @param read_lock_key_queues [Array<String>] Queues of read lock requests.
  # @param lock_readers_keys [Array<String>] Registries of read lock holders.
  # @param read_lock_keys [Array<String,NilClass>]
  #   Read lock data of the current acquirer (`nil` for write lock requests).
  # @param lock_names [Array<String>] The lock names (the members of the lock index).
  # @param watched_keys [Array<String>]
  #   The lock state keys (write lock requests: `lock_keys` and `lock_readers_keys`, read lock
  #   requests: `lock_keys`).
  # @param acquirer_id [String]
  # @param host_id [String]
  # @param acquirer_position [Numeric]
  #   The position of the lock request of the series in all its lock request queues.
  # @param priority [Integer] The lock request priority (the band of `acquirer_position`).
  # @param ttl [Integer]
  # @param queue_ttl [Integer]
  # @param lock_index_enabled [Boolean]
  # @param lock_index_grace_period [Integer]
  # @param fail_fast [Boolean]
  # @param conflict_strategy [Symbol]
  # @param access_strategy [Symbol]
  # @param meta [NilClass,Hash<String|Symbol,Any>]
  # @param retry_attempt [Boolean]
  #   The attempt is a retry (the previous attempt of the acquirement did not obtain the series).
  # @param acq_process [Hash<Symbol,Any>]
  #   - The observer of the acquirement: the attempt puts `:ts`, `:lock_processes` and
  #     `:held_rw_modes` here before the obtaining transaction is sent: an interrupted acquirement
  #     (the transaction can be applied by Redis without the reply) releases these locks;
  #   - `:lock_processes` and `:held_rw_modes` are dropped when the locks are not obtained;
  # @param log_sampled [Boolean]
  # @return [Hash<Symbol,Any>]
  #   - Format: { ok: true/false, result: Symbol, lock_name: String/nil, ready_locks: Array };
  #   - `lock_name`: the first lock of the series that blocks the attempt (`nil` without it);
  #   - `ready_locks`: the indexes of the locks that passed all checks of the attempt before
  #     the lock that blocks it (the order of the lock names, reentrant locks are not checked);
  #
  # @api private
  # @since 1.23.0
  # rubocop:disable Metrics/MethodLength
  def try_to_lock_series(
    redis,
    logger,
    log_lock_try,
    lock_keys,
    read_write_mode,
    lock_key_queues,
    read_lock_key_queues,
    lock_readers_keys,
    read_lock_keys,
    lock_names,
    watched_keys,
    acquirer_id,
    host_id,
    acquirer_position,
    priority,
    ttl,
    queue_ttl,
    lock_index_enabled,
    lock_index_grace_period,
    fail_fast,
    conflict_strategy,
    access_strategy,
    meta,
    retry_attempt,
    acq_process,
    log_sampled
  )
    # Step X: the failure of the attempt and the lock of the series that causes it
    # @type var inter_result: Symbol?
    inter_result = nil
    # @type var failed_lock_index: Integer?
    failed_lock_index = nil
    # Step X: the read locks extended by the attempt (their replies are checked, see Step 6)
    # @type var extended_read_locks: Array[Integer]
    extended_read_locks = []
    # Step X: the locks that passed all checks of the attempt (see `find_series_lock_obstacle`)
    # @type var ready_locks: Array[Integer]
    ready_locks = []
    # @type var lock_processes: Array[Symbol?]
    lock_processes = Array.new(lock_names.size)
    # Step RW: the mode of the lock that is really held by the acquirer after the attempt (see
    #   `TryToLock#try_to_lock`): the requested mode or the mode of the already obtained lock;
    # @type var held_rw_modes: Array[RedisQueuedLocks::readWriteMode]
    held_rw_modes = Array.new(lock_names.size, read_write_mode)
    # Step RW: read lock request flag
    read_mode = (read_write_mode == :read)
    # Step RW: request queues of the current mode and the queues of the opposite mode
    request_queues = read_mode ? read_lock_key_queues : lock_key_queues
    opposite_request_queues = read_mode ? lock_key_queues : read_lock_key_queues
    # Step 2.1 (prepare): requests queued before this score are expired (in both queues)
    acquirer_dead_score = RedisQueuedLocks::Resource.acquirer_dead_score(queue_ttl)
    # Step X: eager queueing (see `TryToLock#try_to_lock`)
    eager_queueing =
      !fail_fast && (conflict_strategy == :wait_for_lock || conflict_strategy == :dead_locking)
    # Step X: pre-check (see `TryToLock#try_to_lock`)
    precheck = fail_fast || retry_attempt

    if log_sampled && log_lock_try
      lock_keys.each do |lock_key|
        LogVisitor.start(
          logger, log_sampled, log_lock_try, lock_key,
          queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode
        )
      end
    end

    # Step X: start to work with lock acquiring
    result = redis.with do |rconn|
      if log_sampled && log_lock_try
        lock_keys.each do |lock_key|
          LogVisitor.rconn_fetched(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode
          )
        end
      end

      # Step PRE: (pre-check) the lock state of the series without WATCH: the attempt that can not
      #   obtain the series fails in one round trip (see `precheck_lock_series`);
      if precheck
        precheck_failure = precheck_lock_series(
          rconn, logger, log_sampled, log_lock_try, lock_keys, read_write_mode, lock_readers_keys,
          request_queues, opposite_request_queues, lock_names, acquirer_id, host_id,
          acquirer_position, priority, acquirer_dead_score, queue_ttl, lock_index_enabled,
          lock_index_grace_period, fail_fast, access_strategy, ready_locks
        )
        if precheck_failure
          inter_result, failed_lock_index = precheck_failure
          next
        end
      end

      # Step 0: watch the lock state of all locks of the series (and discard the acquirement if
      #   any lock state is changed during the attempt): see `watched_keys`;
      rconn.multi(watch: watched_keys) do |transact|
        # Step 0.1: fetch the current state of all locks in one round trip (and the lock request
        #   queueing: eager queueing);
        # @type var state_replies: Array[untyped]
        state_replies = rconn.pipelined do |pipeline|
          pipeline_series_lock_state(
            pipeline, lock_keys, lock_readers_keys, acquirer_id, read_mode, eager_queueing,
            request_queues, opposite_request_queues, acquirer_position, priority,
            acquirer_dead_score, lock_names, queue_ttl, lock_index_enabled, lock_index_grace_period
          )
        end
        lock_states = series_lock_states(
          state_replies, lock_names.size, acquirer_id, read_mode, eager_queueing, lock_index_enabled
        )

        # SP-Conflict Step X1: same-process conflicts (the same logic as in the single lock attempt)
        #   - `:conflict_dead_lock`/`:conflict_lock_upgrade` fail the whole series;
        #   - "work through" locks are held by the current acquirer already (they are not queued
        #     and not obtained by the series: only their reentrant lock data is changed);
        lock_states.each_with_index do |lock_state, index|
          sp_conflict_rw_mode = lock_state[:conflict_rw_mode]
          next unless sp_conflict_rw_mode

          lock_key = lock_keys[index]
          LogVisitor.same_process_conflict_detected(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode
          )
          sp_conflict_status = same_process_conflict_status(
            conflict_strategy, !read_mode && sp_conflict_rw_mode == :read
          )
          LogVisitor.same_process_conflict_analyzed(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, sp_conflict_status
          )

          case sp_conflict_status
          when :conflict_work_through, :extendable_conflict_work_through
            lock_processes[index] = sp_conflict_status
            held_rw_modes[index] = sp_conflict_rw_mode
          when :conflict_dead_lock
            LogVisitor.single_process_lock_conflict__dead_lock(
              logger, log_sampled, log_lock_try, lock_key,
              queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode,
              sp_conflict_status, Time.now.to_f
            )
            inter_result = sp_conflict_status
            failed_lock_index = index
            break
          when :conflict_lock_upgrade
            LogVisitor.single_process_lock_conflict__lock_upgrade(
              logger, log_sampled, log_lock_try, lock_key,
              queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode,
              sp_conflict_status, Time.now.to_f
            )
            inter_result = sp_conflict_status
            failed_lock_index = index
            break
          end
        end
        next if inter_result

        # Fast-Step X0: fail-fast check (all locks that are not reentrant ones)
        #   - write lock request: the lock is obtained by a writer or by readers;
        #   - read lock request: the lock is obtained by a writer (or by the current acquirer);
        if fail_fast
          failed_lock_index = lock_states.each_index.find do |index|
            lock_state = lock_states[index]
            lock_processes[index] == nil &&
              (lock_state[:obtainer] != nil || lock_state[:read_locked])
          end
          if failed_lock_index
            inter_result = :fail_fast_no_try
            next
          end
        end

        # Steps 2.1, 1, 3: the lock request queueing in one round trip (the same commands as in
        #   the single lock attempt, see `queue_lock_request`), reentrant locks are not queued;
        #   - eager queueing: already done in the lock state round trip (Step 0.1);
        unless eager_queueing
          queue_series_lock_requests(
            rconn, lock_states, lock_processes, request_queues, opposite_request_queues,
            acquirer_position, priority, acquirer_id, acquirer_dead_score, lock_names, queue_ttl,
            lock_index_enabled, lock_index_grace_period
          )
        end

        # Step 2.2: (priorities) drop the dead lock requests of other priority bands that block
        #   the series and get the actual queue heads (see `drop_series_dead_requests_ahead`);
        drop_series_dead_requests_ahead(
          rconn, read_mode, request_queues, opposite_request_queues, lock_states, acquirer_id,
          acquirer_position, acquirer_dead_score, access_strategy
        )
        log_series_queueing(
          logger, log_sampled, log_lock_try, lock_keys, lock_states, queue_ttl, acquirer_id,
          host_id, access_strategy, read_write_mode, priority
        )

        # Step 3.1 (RW) + Steps PRE-4.x, ROLLBACK 1.1, 1.2, 2, 3: the first lock of the series that
        #   can not be obtained now: nothing is obtained, retry!
        series_obstacle = find_series_lock_obstacle(
          lock_states, read_mode, access_strategy, acquirer_id, acquirer_position, ready_locks
        )
        if series_obstacle
          log_series_lock_obstacle(
            rconn, series_obstacle[0], series_obstacle[1], lock_states, logger, log_sampled,
            log_lock_try, lock_keys, queue_ttl, acquirer_id, host_id, access_strategy,
            read_write_mode
          )
          inter_result, failed_lock_index = series_obstacle
          next
        end

        # NOTE: all locks are free and ready to be acquired! acquire!
        timestamp = Time.now.to_f

        # Step 6: (transaction layout) the extensions of the read locks are the first commands of
        #   the transaction: their replies are read by the positions (see Step 7), the replies of
        #   other commands are not read;
        lock_states.each_with_index do |lock_state, index|
          next unless lock_processes[index] == :extendable_conflict_work_through
          next unless held_rw_modes[index] == :read

          transact_read_lock_extension(
            transact, lock_readers_keys[index], read_lock_keys[index], lock_names[index],
            acquirer_id, ttl, lock_index_enabled, lock_state[:own_read_lock_expiration],
            lock_state[:redis_time], timestamp
          )
          extended_read_locks << index
        end

        # Step 6.X: other commands of the transaction: all locks of the series at once;
        #   - a reentrant lock has no lock request except the request queued by the pre-check of
        #     a retry (the lock state is not known before the queueing): it is dropped here;
        lock_states.each_with_index do |lock_state, index|
          lock_key = lock_keys[index]

          case lock_processes[index]
          when :extendable_conflict_work_through
            if held_rw_modes[index] == :write
              transact_write_lock_extension(
                transact, lock_key, lock_names[index], ttl, lock_index_enabled, timestamp
              )
            end
            transact.call('ZREM', request_queues[index], acquirer_id)
            LogVisitor.reentrant_lock__extend_and_work_through(
              logger, log_sampled, log_lock_try, lock_key,
              queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode,
              :extendable_conflict_work_through, ttl, timestamp
            )
          when :conflict_work_through
            if held_rw_modes[index] == :write
              transact_write_lock_work_through(transact, lock_key, timestamp)
            else
              transact_read_lock_work_through(
                transact, read_lock_keys[index], lock_state[:own_read_lock_expiration],
                lock_state[:redis_time], timestamp
              )
            end
            transact.call('ZREM', request_queues[index], acquirer_id)
            LogVisitor.reentrant_lock__work_through(
              logger, log_sampled, log_lock_try, lock_key,
              queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode,
              :conflict_work_through, timestamp
            )
          else
            lock_processes[index] = :lock_obtaining

            if read_mode
              transact_read_lock_obtaining(
                transact, request_queues[index], lock_readers_keys[index], read_lock_keys[index],
                lock_names[index], acquirer_id, ttl, lock_index_enabled, lock_index_grace_period,
                meta, lock_state[:redis_time], timestamp
              )
            else
              transact_write_lock_obtaining(
                transact, lock_key, request_queues[index], lock_names[index], acquirer_id, host_id,
                ttl, lock_index_enabled, lock_index_grace_period, meta, timestamp
              )
            end
            LogVisitor.obtain__free_to_acquire(
              logger, log_sampled, log_lock_try, lock_key,
              queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode
            )
          end
        end

        # NOTE: an interruption after this point can leave the applied transaction without its
        #   reply: the acquirement releases these locks (see `@param acq_process`);
        acq_process[:ts] = timestamp
        acq_process[:lock_processes] = lock_processes
        acq_process[:held_rw_modes] = held_rw_modes
      end
    rescue RedisQueuedLocks::LockAcquirementIntermediateTimeoutError,
           RedisQueuedLocks::TimedLockIntermediateTimeoutError,
           ::Timeout::ExitException
      # NOTE: (timeouts) the same as in the single lock attempt: the closed connection drops
      #   the WATCH state and is reconnected on the next use (see `TryToLock#try_to_lock`);
      rconn.close
      raise
    end

    # Step 7: Analyze the aquirement attempt:
    if inter_result
      # Step 7.a: nothing is obtained (the transaction has no commands)
      {
        ok: false,
        result: inter_result,
        lock_name: failed_lock_index ? lock_names[failed_lock_index] : nil,
        ready_locks:
      }
    elsif result == nil || (result.is_a?(::Array) && result.empty?)
      # Step 7.b: some lock state is changed during the acquire race => nothing is obtained
      acq_process[:lock_processes] = nil
      acq_process[:held_rw_modes] = nil
      { ok: false, result: :lock_is_acquired_during_acquire_race, lock_name: nil, ready_locks: }
    else
      # Step 7.c (RW): the read lock can expire during the extension (the registry is not watched):
      #   a transaction can not be rolled back, so the series releases its locks and retries;
      #   - (transaction layout) see Step 6: each extended read lock takes the same number of
      #     commands, ZADD XX INCR is the first one (`nil`: the read lock is expired);
      extension_commands =
        READ_LOCK_EXTENSION_COMMANDS + (lock_index_enabled ? 1 : 0)
      expired_read_lock = extended_read_locks.each_with_index.find do |_index, extension_position|
        result[extension_position * extension_commands] == nil
      end

      if expired_read_lock
        release_lock_series(
          redis, lock_names, lock_processes, held_rw_modes, acquirer_id,
          ttl - RedisQueuedLocks::Resource::REDIS_TIMESHIFT_ERROR
        )
        RedisQueuedLocks::Acquirer::LockSeries::LogVisitor.expire_lock_series(
          logger, log_sampled, lock_keys,
          queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, priority
        )
        acq_process[:lock_processes] = nil
        acq_process[:held_rw_modes] = nil
        {
          ok: false,
          result: :read_lock_is_expired_during_extension,
          lock_name: lock_names[expired_read_lock[0]],
          ready_locks:
        }
      else
        # Step 7.d: locked! :) let's go! => all locks of the series are successfully acquired
        { ok: true, result: :lock_series_obtaining, lock_name: nil, ready_locks: }
      end
    end
  end
  # rubocop:enable Metrics/MethodLength

  private

  # Adds the lock state commands of all locks of the series to the given pipeline.
  #
  # NOTE: (pipeline layout) the commands of each lock are the commands of the single lock attempt
  #   (`pipeline_lock_state`), so each lock has the same number of replies (see
  #   `series_lock_state_replies`) and its replies are read by the position constants of
  #   `pipeline_lock_state` (see `series_lock_states`);
  #
  # @param pipeline [RedisClient::Pipeline]
  # @param lock_keys [Array<String>]
  # @param lock_readers_keys [Array<String>]
  # @param acquirer_id [String]
  # @param read_mode [Boolean]
  # @param queueing [Boolean] Queue the lock requests in the same round trip.
  # @param request_queues [Array<String>]
  # @param opposite_request_queues [Array<String>]
  # @param acquirer_position [Numeric]
  # @param priority [Integer]
  # @param acquirer_dead_score [Float]
  # @param lock_names [Array<String>]
  # @param queue_ttl [Integer] In seconds.
  # @param lock_index_enabled [Boolean]
  # @param lock_index_grace_period [Integer] In milliseconds.
  # @return [void]
  #
  # @api private
  # @since 1.23.0
  def pipeline_series_lock_state(
    pipeline,
    lock_keys,
    lock_readers_keys,
    acquirer_id,
    read_mode,
    queueing,
    request_queues,
    opposite_request_queues,
    acquirer_position,
    priority,
    acquirer_dead_score,
    lock_names,
    queue_ttl,
    lock_index_enabled,
    lock_index_grace_period
  )
    lock_keys.each_with_index do |lock_key, index|
      pipeline_lock_state(
        pipeline, lock_key, lock_readers_keys[index], acquirer_id, read_mode, queueing,
        request_queues[index], opposite_request_queues[index], acquirer_position, priority,
        acquirer_dead_score, lock_names[index], queue_ttl, lock_index_enabled,
        lock_index_grace_period
      )
    end
  end

  # The number of the replies of one lock in the lock state pipeline of the series
  # (see `pipeline_series_lock_state`).
  #
  # @param read_mode [Boolean]
  # @param queueing [Boolean] The lock requests are queued in the same round trip.
  # @param lock_index_enabled [Boolean]
  # @return [Integer]
  #
  # @api private
  # @since 1.23.0
  def series_lock_state_replies(read_mode, queueing, lock_index_enabled)
    LOCK_STATE_QUEUE_REPLIES_AT +
      (queueing ? series_queue_replies(lock_index_enabled) : 0) +
      (read_mode ? 0 : 1) # NOTE: the write-only tail of the lock state pipeline
  end

  # The number of the replies of one lock request queueing (see `queue_lock_request`).
  #
  # @param lock_index_enabled [Boolean]
  # @return [Integer]
  #
  # @api private
  # @since 1.23.0
  def series_queue_replies(lock_index_enabled)
    QUEUE_REPLIES + (lock_index_enabled ? QUEUE_LOCK_INDEX_REPLIES : 0)
  end

  # The state of each lock of the series: the replies of the lock state pipeline of the series
  # (the same reply reading as in the single lock attempt, per lock).
  #
  # @param state_replies [Array<Any>] See `pipeline_series_lock_state`.
  # @param locks_count [Integer]
  # @param acquirer_id [String]
  # @param read_mode [Boolean]
  # @param queueing [Boolean] The lock requests are queued in the same round trip.
  # @param lock_index_enabled [Boolean]
  # @return [Array<Hash<Symbol,Any>>]
  #   - `:obtainer` - the write lock obtainer;
  #   - `:redis_time` - redis server time (in milliseconds);
  #   - `:own_read_lock_expiration` - the read lock expiration of the current acquirer;
  #   - `:read_locked` - write lock requests: live read locks exist; read lock requests: the own
  #     read lock is live;
  #   - `:conflict_rw_mode` - the mode of the lock (already obtained by the current acquirer) that
  #     the lock request conflicts with;
  #   - `:queued`, `:waiting_request`, `:opposite_waiting_request` - the lock request is queued and
  #     the queue heads;
  #   - `:dropped_requests` - the dead lock requests dropped by the attempt (for logs);
  #
  # @api private
  # @since 1.23.0
  # rubocop:disable Metrics/MethodLength
  def series_lock_states(
    state_replies,
    locks_count,
    acquirer_id,
    read_mode,
    queueing,
    lock_index_enabled
  )
    lock_replies = series_lock_state_replies(read_mode, queueing, lock_index_enabled)

    Array.new(locks_count) do |index|
      replies_at = index * lock_replies
      # @type var current_lock_obtainer: String?
      current_lock_obtainer = state_replies[replies_at + LOCK_STATE_OBTAINER_REPLY]
      redis_time = RedisQueuedLocks::Resource.redis_time_ms(
        state_replies[replies_at + LOCK_STATE_REDIS_TIME_REPLY]
      )
      # @type var own_read_lock_expiration: Float?
      own_read_lock_expiration = state_replies[replies_at + LOCK_STATE_OWN_READ_LOCK_REPLY]
      # NOTE: the write-only tail is the last reply of the lock (write lock requests only)
      # @type var longest_read_lock: [String, Float]?
      longest_read_lock = read_mode ? nil : state_replies[replies_at + lock_replies - 1].first
      read_locked_by_acquirer = own_read_lock_expiration.to_f > redis_time
      read_locked = longest_read_lock ? longest_read_lock[1] > redis_time : false
      queue_replies_at = replies_at + LOCK_STATE_QUEUE_REPLIES_AT

      {
        obtainer: current_lock_obtainer,
        redis_time:,
        own_read_lock_expiration:,
        read_locked: read_mode ? read_locked_by_acquirer : read_locked,
        conflict_rw_mode:
          if current_lock_obtainer != nil && acquirer_id == current_lock_obtainer
            :write
          elsif read_locked_by_acquirer
            :read
          end,
        queued: queueing,
        waiting_request:
          queueing ? state_replies[queue_replies_at + QUEUE_HEAD_REPLY].first : nil,
        opposite_waiting_request:
          queueing ? state_replies[queue_replies_at + OPPOSITE_QUEUE_HEAD_REPLY].first : nil,
        dropped_requests: nil
      }
    end
  end
  # rubocop:enable Metrics/MethodLength

  # Queues the lock requests of the locks that are not reentrant ones in one round trip (the same
  # commands as in the single lock attempt) and puts the queue heads to the lock states.
  #
  # @param rconn [RedisClient]
  # @param lock_states [Array<Hash<Symbol,Any>>] See `series_lock_states`.
  # @param lock_processes [Array<Symbol,NilClass>] Reentrant locks have their process here.
  # @param request_queues [Array<String>]
  # @param opposite_request_queues [Array<String>]
  # @param acquirer_position [Numeric]
  # @param priority [Integer]
  # @param acquirer_id [String]
  # @param acquirer_dead_score [Float]
  # @param lock_names [Array<String>]
  # @param queue_ttl [Integer]
  # @param lock_index_enabled [Boolean]
  # @param lock_index_grace_period [Integer]
  # @return [void]
  #
  # @api private
  # @since 1.23.0
  def queue_series_lock_requests(
    rconn,
    lock_states,
    lock_processes,
    request_queues,
    opposite_request_queues,
    acquirer_position,
    priority,
    acquirer_id,
    acquirer_dead_score,
    lock_names,
    queue_ttl,
    lock_index_enabled,
    lock_index_grace_period
  )
    queued_locks = lock_states.each_index.select { |index| lock_processes[index] == nil }
    return if queued_locks.empty?

    # NOTE: (pipeline layout) the replies of each lock are the replies of `queue_lock_request`
    # @type var queue_replies: Array[untyped]
    queue_replies = rconn.pipelined do |pipeline|
      queued_locks.each do |index|
        queue_lock_request(
          pipeline, request_queues[index], opposite_request_queues[index], acquirer_position,
          priority, acquirer_id, acquirer_dead_score, lock_names[index], queue_ttl,
          lock_index_enabled, lock_index_grace_period
        )
      end
    end
    lock_replies = series_queue_replies(lock_index_enabled)

    queued_locks.each_with_index do |index, queue_position|
      lock_state = lock_states[index]
      replies_at = queue_position * lock_replies
      lock_state[:queued] = true
      lock_state[:waiting_request] = queue_replies[replies_at + QUEUE_HEAD_REPLY].first
      lock_state[:opposite_waiting_request] =
        queue_replies[replies_at + OPPOSITE_QUEUE_HEAD_REPLY].first
    end
  end

  # (priorities) Drops the dead lock requests of other priority bands that block the series and
  # puts the actual queue heads to the lock states: Step 2.2 of the attempt and of its pre-check
  # for all queued locks of the series (see `TryToLock#drop_dead_requests_ahead`):
  #   - one round trip drops the dead blocking requests of all locks and reads the actual queue
  #     heads of these locks, up to `MAX_DEAD_REQUEST_REMOVALS` round trips per call: the cost does
  #     not depend on the number of locks of the series;
  #   - no round trips while no dead request blocks the series;
  #
  # @param rconn [RedisClient]
  # @param read_mode [Boolean]
  # @param request_queues [Array<String>]
  # @param opposite_request_queues [Array<String>]
  # @param lock_states [Array<Hash<Symbol,Any>>] See `series_lock_states`.
  # @param acquirer_id [String]
  # @param acquirer_position [Numeric]
  # @param acquirer_dead_score [Float]
  # @param access_strategy [Symbol]
  # @return [void]
  #
  # @api private
  # @since 1.23.0
  # rubocop:disable Metrics/MethodLength
  def drop_series_dead_requests_ahead(
    rconn,
    read_mode,
    request_queues,
    opposite_request_queues,
    lock_states,
    acquirer_id,
    acquirer_position,
    acquirer_dead_score,
    access_strategy
  )
    return unless access_strategy == :queued

    round_trips = 0

    while round_trips < MAX_DEAD_REQUEST_REMOVALS
      # @type var dead_requests: Array[deadRequests]
      dead_requests = []
      lock_states.each_with_index do |lock_state, index|
        next unless lock_state[:queued]

        dead_lock_requests = find_dead_requests_ahead(
          read_mode, access_strategy, acquirer_id, acquirer_position, acquirer_dead_score,
          lock_state[:waiting_request], lock_state[:opposite_waiting_request]
        )
        dead_requests << [index, dead_lock_requests] if dead_lock_requests
      end
      break if dead_requests.empty?

      # NOTE: (pipeline layout) the removal commands of all locks (see
      #   `pipeline_dead_requests_ahead_removal`), then two ZRANGE WITHSCORES per lock (the heads
      #   of the request queue and of the opposite request queue, the tail of the pipeline);
      # @type var queue_state: Array[untyped]
      queue_state = rconn.pipelined do |pipeline|
        dead_requests.each do |index, lock_requests|
          dead_head, dead_head_priority, dead_ahead, dead_ahead_priority = lock_requests
          pipeline_dead_requests_ahead_removal(
            pipeline, request_queues[index], opposite_request_queues[index], acquirer_dead_score,
            dead_head, dead_head_priority, dead_ahead, dead_ahead_priority
          )
        end
        dead_requests.each do |lock_dead_requests|
          index = lock_dead_requests[0]
          pipeline.call('ZRANGE', request_queues[index], '0', '0', 'WITHSCORES')
          pipeline.call('ZRANGE', opposite_request_queues[index], '0', '0', 'WITHSCORES')
        end
      end
      heads_at = queue_state.size - (dead_requests.size * 2)

      dead_requests.each_with_index do |(index, lock_requests), position|
        lock_state = lock_states[index]
        dead_head, dead_head_priority, dead_ahead, dead_ahead_priority = lock_requests
        # @type var removed_requests: Array[[String, Integer]]
        removed_requests = lock_state[:dropped_requests] || []
        removed_requests << [dead_head[0], dead_head_priority] if dead_head && dead_head_priority
        if dead_ahead && dead_ahead_priority
          removed_requests << [dead_ahead[0], dead_ahead_priority]
        end
        lock_state[:dropped_requests] = removed_requests
        lock_state[:waiting_request] = queue_state[heads_at + (position * 2)].first
        lock_state[:opposite_waiting_request] = queue_state[heads_at + (position * 2) + 1].first
      end
      round_trips += 1
    end
  end
  # rubocop:enable Metrics/MethodLength

  # The first lock of the series that can not be obtained now (the same decision as in the single
  # lock attempt, per lock: `find_opposite_request_ahead`, `lock_obstacle`).
  #
  # @param lock_states [Array<Hash<Symbol,Any>>] See `series_lock_states`.
  # @param read_mode [Boolean]
  # @param access_strategy [Symbol]
  # @param acquirer_id [String]
  # @param acquirer_position [Numeric]
  # @param ready_locks [Array<Integer>]
  #   The indexes of the checked locks without an obstacle are added here (in the order of the lock
  #   names: the locks after the obstacle are not checked).
  # @return [Array<Symbol,Integer>,NilClass]
  #   The obstacle and the index of the lock, `nil` when all locks can be obtained.
  #
  # @api private
  # @since 1.23.0
  def find_series_lock_obstacle(
    lock_states,
    read_mode,
    access_strategy,
    acquirer_id,
    acquirer_position,
    ready_locks
  )
    lock_states.each_with_index do |lock_state, index|
      next unless lock_state[:queued]

      # @type var waiting_request: [String, Float]?
      waiting_request = lock_state[:waiting_request]
      opposite_request_ahead = find_opposite_request_ahead(
        access_strategy, lock_state[:opposite_waiting_request], acquirer_position, acquirer_id
      )
      obstacle = lock_obstacle(
        read_mode, access_strategy, acquirer_id, waiting_request ? waiting_request[0] : nil,
        opposite_request_ahead, lock_state[:obtainer], lock_state[:read_locked]
      )
      return [obstacle, index] if obstacle

      ready_locks << index
    end

    nil
  end

  # Logs the queueing steps of the queued locks of the series (the same events as in the single
  # lock attempt, per lock).
  #
  # @param logger [::Logger,#debug]
  # @param log_sampled [Boolean]
  # @param log_lock_try [Boolean]
  # @param lock_keys [Array<String>]
  # @param lock_states [Array<Hash<Symbol,Any>>] See `series_lock_states`.
  # @param queue_ttl [Integer]
  # @param acquirer_id [String]
  # @param host_id [String]
  # @param access_strategy [Symbol]
  # @param read_write_mode [Symbol]
  # @param priority [Integer]
  # @return [void]
  #
  # @api private
  # @since 1.23.0
  # rubocop:disable Metrics/MethodLength
  def log_series_queueing(
    logger,
    log_sampled,
    log_lock_try,
    lock_keys,
    lock_states,
    queue_ttl,
    acquirer_id,
    host_id,
    access_strategy,
    read_write_mode,
    priority
  )
    return unless log_sampled && log_lock_try

    lock_states.each_with_index do |lock_state, index|
      next unless lock_state[:queued]

      lock_key = lock_keys[index]
      # @type var waiting_request: [String, Float]?
      waiting_request = lock_state[:waiting_request]

      LogVisitor.acq_added_to_queue(
        logger, log_sampled, log_lock_try, lock_key,
        queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, priority
      )
      LogVisitor.remove_expired_acqs(
        logger, log_sampled, log_lock_try, lock_key,
        queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode
      )
      # @type var dropped_requests: Array[[String, Integer]]?
      dropped_requests = lock_state[:dropped_requests]
      if dropped_requests
        log_dropped_requests(
          logger, log_sampled, log_lock_try, lock_key, queue_ttl, acquirer_id, host_id,
          access_strategy, read_write_mode, dropped_requests
        )
      end
      LogVisitor.get_first_from_queue(
        logger, log_sampled, log_lock_try, lock_key,
        queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode,
        waiting_request ? waiting_request[0] : nil,
        logged_request_priority(log_sampled, log_lock_try, waiting_request)
      )
    end
  end
  # rubocop:enable Metrics/MethodLength

  # (priorities) Logs the dead lock requests dropped by a pre-check that does not fail
  # (see `TryToLock#log_dropped_requests`).
  #
  # @param logger [::Logger,#debug]
  # @param log_sampled [Boolean]
  # @param log_lock_try [Boolean]
  # @param lock_keys [Array<String>]
  # @param lock_states [Array<Hash<Symbol,Any>>] See `series_lock_states`.
  # @param queue_ttl [Integer]
  # @param acquirer_id [String]
  # @param host_id [String]
  # @param access_strategy [Symbol]
  # @param read_write_mode [Symbol]
  # @return [void]
  #
  # @api private
  # @since 1.23.0
  def log_series_dropped_requests(
    logger,
    log_sampled,
    log_lock_try,
    lock_keys,
    lock_states,
    queue_ttl,
    acquirer_id,
    host_id,
    access_strategy,
    read_write_mode
  )
    return unless log_sampled && log_lock_try

    lock_states.each_with_index do |lock_state, index|
      # @type var dropped_requests: Array[[String, Integer]]?
      dropped_requests = lock_state[:dropped_requests]
      next unless dropped_requests

      log_dropped_requests(
        logger, log_sampled, log_lock_try, lock_keys[index], queue_ttl, acquirer_id, host_id,
        access_strategy, read_write_mode, dropped_requests
      )
    end
  end

  # Logs the obstacle to the series obtaining: the exit event of the single lock attempt for
  # the lock that blocks the series (see `log_lock_obstacle`).
  #
  # @param rconn [RedisClient]
  # @param obstacle [Symbol]
  # @param lock_index [Integer] The index of the lock that blocks the series.
  # @param lock_states [Array<Hash<Symbol,Any>>] See `series_lock_states`.
  # @param logger [::Logger,#debug]
  # @param log_sampled [Boolean]
  # @param log_lock_try [Boolean]
  # @param lock_keys [Array<String>]
  # @param queue_ttl [Integer]
  # @param acquirer_id [String]
  # @param host_id [String]
  # @param access_strategy [Symbol]
  # @param read_write_mode [Symbol]
  # @return [void]
  #
  # @api private
  # @since 1.23.0
  def log_series_lock_obstacle(
    rconn,
    obstacle,
    lock_index,
    lock_states,
    logger,
    log_sampled,
    log_lock_try,
    lock_keys,
    queue_ttl,
    acquirer_id,
    host_id,
    access_strategy,
    read_write_mode
  )
    return unless log_sampled && log_lock_try

    lock_state = lock_states[lock_index]
    # @type var waiting_request: [String, Float]?
    waiting_request = lock_state[:waiting_request]

    log_lock_obstacle(
      rconn, obstacle, logger, log_sampled, log_lock_try, lock_keys[lock_index], queue_ttl,
      acquirer_id, host_id, access_strategy, read_write_mode,
      waiting_request ? waiting_request[0] : nil,
      logged_request_priority(log_sampled, log_lock_try, waiting_request),
      lock_state[:opposite_waiting_request], lock_state[:obtainer]
    )
  end

  # Pre-check of the attempt (Step PRE): the lock state of the series without WATCH (one round
  # trip, see `TryToLock#precheck_lock`):
  #   - `fail_fast` attempts: the lock state only (the lock requests are not queued); fails with
  #     `:fail_fast_no_try` on the first obtained lock;
  #   - retries: the lock state and the lock request queueing; fails on the first obstacle (the same
  #     decision and logs as in the attempt);
  #   - a same-process conflict of any lock is not decided: the attempt continues with
  #     the WATCH/MULTI logic (a retry of the series with reentrant locks has no one round trip
  #     failures);
  #   - the pre-check never obtains locks (mutual exclusion relies on WATCH/MULTI only);
  #
  # @param rconn [RedisClient]
  # @param logger [::Logger,#debug]
  # @param log_sampled [Boolean]
  # @param log_lock_try [Boolean]
  # @param lock_keys [Array<String>]
  # @param read_write_mode [Symbol]
  # @param lock_readers_keys [Array<String>]
  # @param request_queues [Array<String>]
  # @param opposite_request_queues [Array<String>]
  # @param lock_names [Array<String>]
  # @param acquirer_id [String]
  # @param host_id [String]
  # @param acquirer_position [Numeric]
  # @param priority [Integer]
  # @param acquirer_dead_score [Float]
  # @param queue_ttl [Integer]
  # @param lock_index_enabled [Boolean]
  # @param lock_index_grace_period [Integer]
  # @param fail_fast [Boolean]
  # @param access_strategy [Symbol]
  # @param ready_locks [Array<Integer>] See `find_series_lock_obstacle`.
  # @return [Array<Symbol,Integer>,NilClass]
  #   The failure result of the attempt and the index of the lock or `nil` (continue the attempt).
  #
  # @api private
  # @since 1.23.0
  # rubocop:disable Metrics/MethodLength
  def precheck_lock_series(
    rconn,
    logger,
    log_sampled,
    log_lock_try,
    lock_keys,
    read_write_mode,
    lock_readers_keys,
    request_queues,
    opposite_request_queues,
    lock_names,
    acquirer_id,
    host_id,
    acquirer_position,
    priority,
    acquirer_dead_score,
    queue_ttl,
    lock_index_enabled,
    lock_index_grace_period,
    fail_fast,
    access_strategy,
    ready_locks
  )
    read_mode = (read_write_mode == :read)
    # NOTE: the same pipeline layout and the same reply reading as in Step 0.1 of the attempt
    # @type var state_replies: Array[untyped]
    state_replies = rconn.pipelined do |pipeline|
      pipeline_series_lock_state(
        pipeline, lock_keys, lock_readers_keys, acquirer_id, read_mode, !fail_fast,
        request_queues, opposite_request_queues, acquirer_position, priority, acquirer_dead_score,
        lock_names, queue_ttl, lock_index_enabled, lock_index_grace_period
      )
    end
    lock_states = series_lock_states(
      state_replies, lock_names.size, acquirer_id, read_mode, !fail_fast, lock_index_enabled
    )

    # NOTE: same-process conflicts are processed by the attempt (conflict strategies)
    return if lock_states.any? { |lock_state| lock_state[:conflict_rw_mode] != nil }

    if fail_fast
      # NOTE: the fail-fast check of the attempt (Fast-Step X0) without same-process conflicts
      failed_lock_index = lock_states.find_index do |lock_state|
        lock_state[:obtainer] != nil || lock_state[:read_locked]
      end
      return failed_lock_index ? [:fail_fast_no_try, failed_lock_index] : nil
    end

    # NOTE: (priorities) Step 2.2 of the attempt: before the obstacle decision
    drop_series_dead_requests_ahead(
      rconn, read_mode, request_queues, opposite_request_queues, lock_states, acquirer_id,
      acquirer_position, acquirer_dead_score, access_strategy
    )
    series_obstacle = find_series_lock_obstacle(
      lock_states, read_mode, access_strategy, acquirer_id, acquirer_position, ready_locks
    )

    if series_obstacle
      # NOTE: the same log events as the failed attempt in the same order
      log_series_queueing(
        logger, log_sampled, log_lock_try, lock_keys, lock_states, queue_ttl, acquirer_id,
        host_id, access_strategy, read_write_mode, priority
      )
      log_series_lock_obstacle(
        rconn, series_obstacle[0], series_obstacle[1], lock_states, logger, log_sampled,
        log_lock_try, lock_keys, queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode
      )
    else
      # NOTE: the attempt continues: it logs its own queueing, the dropped dead lock requests are
      #   logged here (the attempt does not see them, see `TryToLock#precheck_lock`);
      log_series_dropped_requests(
        logger, log_sampled, log_lock_try, lock_keys, lock_states, queue_ttl, acquirer_id,
        host_id, access_strategy, read_write_mode
      )
    end

    series_obstacle
  end
  # rubocop:enable Metrics/MethodLength
end
# rubocop:enable Metrics/ModuleLength
