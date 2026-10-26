# frozen_string_literal: true

# Read/Write locks (`read_write_mode`):
#   - `:write` lock is exclusive: it is obtained when there is no write lock and no live read lock;
#   - `:read` lock is shared: it is obtained when there is no write lock;
#   - read locks are stored in the readers registry: a sorted set where the member is an acquirer
#     id and the score is the read lock expiration time (redis server time, in milliseconds);
#   - each read lock has its own data hash (the same structure as the write lock: timestamp, ttl,
#     meta, reentrant lock data; acquirer and host are derived from the acquirer id and are not
#     stored) with the read lock ttl; the readers registry is the only source of truth for
#     the read lock existence (the data hash is a data carrier only);
#   - mutual exclusion relies on the optimistic transactions only (WATCH/MULTI):
#     - readers WATCH the write lock key: a new write lock invalidates the reader's transaction;
#     - writers WATCH the write lock key and the readers registry: a new read lock invalidates
#       the writer's transaction;
#     - readers do not WATCH the readers registry so they never invalidate each other;
#   - lock queues are responsible for the order only (`:queued` access strategy,
#     FIFO between modes):
#     - write lock request should be the first in the write lock queue (the classic lock queue)
#       and should wait for all earlier read lock requests;
#     - read lock request should wait for all earlier write lock requests;
#   - `:random` access strategy ignores the order of both queues (no ordering between modes, so
#     a continuous flow of readers can starve writers); its own lock request is queued like any
#     lock request (`:queued` lock requests wait for it);
#
# Lock index (`RedisQueuedLocks::Resource::LOCK_INDEX_KEY`): only with the enabled lock index
# (`lock_index_enabled`, `config['lock_index_enabled']`); with the disabled lock index (default)
# no lock index commands are sent and lock request queues have no TTL:
#   - every command that creates a lock key is followed by the lock index update in the same
#     pipeline/transaction: the lock name score is the upper bound of the key lifetime (`ZADD GT
#     <client time + ttl + grace period>`): the request queue in the queueing pipeline, the lock
#     (write lock / readers registry) in the obtaining transaction (atomically: the lock index
#     entry can be dropped by `#unlock`/`#clear_locks` between the queueing and the obtaining);
#   - lock extensions (reentrant `:extendable_work_through`) increase the score by the extension
#     in the same transaction (`ZADD XX INCR`);
#   - lock request queues live as long as the latest lock request (`PEXPIRE NX` + `GT` with
#     the queue ttl on each queueing) so the lifetime of every lock key is bounded;
#   - each queueing drops the expired lock names from the index (`ZREMRANGEBYSCORE`): the index
#     is maintained by the lock acquirement itself (no background jobs);
#
# Lock request priorities (`priority`, see `RedisQueuedLocks::Resource::LOCK_PRIORITY_BAND`):
#   - the position of the lock request (the score) is the enqueue time shifted by the priority
#     band: requests of a higher priority are ahead of the requests of a lower priority in both
#     queues (FIFO inside the same priority), so the queue heads and the order between modes
#     (`find_opposite_request_ahead`) work with the positions as is;
#   - dead lock requests are dropped per priority band (each band has its own time barrier):
#     the band of the current request before the request is queued and the queue heads are read
#     (both queues); a dead request of another band is dropped when it blocks the current request
#     (the queue head or the earlier request of the opposite mode): its band and its enqueue time
#     are decoded from its position, so the cost of an attempt does not depend on the number of
#     priorities (see `drop_dead_requests_ahead`);
#
# @api private
# @since 1.0.0
# @version 1.22.0
# rubocop:disable Metrics/ModuleLength
module RedisQueuedLocks::Acquirer::AcquireLock::TryToLock
  require_relative 'try_to_lock/log_visitor'

  # @return [String]
  #
  # @api private
  # @since 1.3.0
  EXTEND_LOCK_PTTL = <<~LUA_SCRIPT.strip.tr("\n", '').freeze
    local new_lock_pttl = redis.call("PTTL", KEYS[1]) + ARGV[1];
    return redis.call("PEXPIRE", KEYS[1], new_lock_pttl);
  LUA_SCRIPT

  # Lock data for the try-lock log events when the lock data is not extracted
  # (logs are disabled): shared frozen object instead of a new hash for each failed attempt.
  #
  # NOTE: (steep) an empty hash literal with a method call can't be annotated inline
  #   (the constant type is declared in RBS);
  #
  # @return [Hash]
  #
  # @api private
  # @since 1.20.0
  NO_LOCK_DATA = {}.freeze # steep:ignore

  # Position of the write lock obtainer (`HGET acq_id`) in the lock state pipeline
  # (see "pipeline layout" in `pipeline_lock_state`).
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.20.0
  LOCK_STATE_OBTAINER_REPLY = 0

  # Position of the redis server time (`TIME`) in the lock state pipeline
  # (see "pipeline layout" in `pipeline_lock_state`).
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.20.0
  LOCK_STATE_REDIS_TIME_REPLY = 1

  # Position of the read lock expiration of the current acquirer (`ZSCORE`) in the lock state
  # pipeline (see "pipeline layout" in `pipeline_lock_state`).
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.20.0
  LOCK_STATE_OWN_READ_LOCK_REPLY = 2

  # Position of the first reply of the lock request queueing commands (`queue_lock_request`)
  # in the lock state pipeline (see "pipeline layout" in `pipeline_lock_state`).
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.20.0
  LOCK_STATE_QUEUE_REPLIES_AT = 3

  # Position of the first request of the request queue (`ZRANGE WITHSCORES`) in the replies of
  # the lock request queueing commands (`queue_lock_request`), relative to their first reply.
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.20.0
  QUEUE_HEAD_REPLY = 3

  # Position of the first request of the opposite request queue (`ZRANGE WITHSCORES`) in the
  # replies of the lock request queueing commands (`queue_lock_request`), relative to their
  # first reply.
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.20.0
  OPPOSITE_QUEUE_HEAD_REPLY = 4

  # The maximum number of the round trips of one call of `drop_dead_requests_ahead` (the attempt or
  # its pre-check; each round trip drops the dead blocking requests, the head of the write lock
  # queue and the earlier request of the opposite mode, with the dead requests of their priority
  # bands): the attempt fails when more dead lock requests block it (the next attempts drop them).
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.22.0
  MAX_DEAD_REQUEST_REMOVALS = 5

  # @param redis [RedisClient]
  # @param logger [::Logger,#debug]
  # @param log_lock_try [Boolean]
  # @param lock_key [String]
  # @param read_write_mode [Symbol] `:read` or `:write`
  # @param lock_key_queue [String] Queue of write lock requests.
  # @param read_lock_key_queue [String] Queue of read lock requests.
  # @param lock_readers_key [String] Registry of read lock holders.
  # @param read_lock_key [String,NilClass]
  #   Read lock data of the current acquirer (`nil` for write lock requests: they never obtain
  #   read locks).
  # @param lock_name [String] The lock name (the member of the lock index).
  # @param acquirer_id [String]
  # @param host_id [String]
  # @param acquirer_position [Numeric]
  #   The position of the lock request (the score: the enqueue time shifted by the priority band).
  # @param priority [Integer]
  #   The lock request priority (the band of `acquirer_position`).
  # @param ttl [Integer]
  # @param queue_ttl [Integer]
  # @param lock_index_enabled [Boolean]
  #   Maintain the lock index (the lock index commands and the lock request queue TTL).
  # @param lock_index_grace_period [Integer]
  #   The lock index score margin (in milliseconds) over the key lifetime (client clock skew and
  #   network latency tolerance).
  # @param fail_fast [Boolean]
  # @param conflict_strategy [Symbol]
  # @param access_strategy [Symbol]
  # @param meta [NilClass,Hash<String|Symbol,Any>]
  # @param retry_attempt [Boolean]
  #   The attempt is a retry (the previous attempt of the acquirement did not obtain the lock).
  # @param log_sampled [Boolean]
  # @param instr_sampled [Boolean]
  # @return [Hash<Symbol,Any>] Format: { ok: true/false, result: Symbol|Hash<Symbol,Any> }
  #
  # @api private
  # @since 1.0.0
  # @version 1.22.0
  # rubocop:disable Metrics/MethodLength
  def try_to_lock(
    redis,
    logger,
    log_lock_try,
    lock_key,
    read_write_mode,
    lock_key_queue,
    read_lock_key_queue,
    lock_readers_key,
    read_lock_key,
    lock_name,
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
    log_sampled,
    instr_sampled
  )
    # Step X: intermediate invocation results
    # @type var inter_result: Symbol?
    inter_result = nil
    # @type var timestamp: Float?
    timestamp = nil
    # @type var spc_processed_timestamp: Float?
    spc_processed_timestamp = nil
    # Step RW: the mode of the lock that is really held by the acquirer after the attempt
    #   (the requested mode or the mode of the already obtained lock for same-process conflicts);
    # @type var held_rw_mode: Symbol
    held_rw_mode = read_write_mode
    # Step RW: read lock request flag
    read_mode = (read_write_mode == :read)
    # Step RW: request queue of the current mode and the queue of the opposite mode
    request_queue = read_mode ? read_lock_key_queue : lock_key_queue
    opposite_request_queue = read_mode ? lock_key_queue : read_lock_key_queue
    # Step 2.1 (prepare): requests queued before this score are expired (in both queues)
    acquirer_dead_score = RedisQueuedLocks::Resource.acquirer_dead_score(queue_ttl)
    # Step X: eager queueing - the lock request is queued in the lock state round trip (Step 0.1)
    #   instead of a separate round trip in the classic logic (Steps 1-3). Only when the attempt
    #   always reaches the classic logic or dequeues the request after the failure:
    #   - `:wait_for_lock`: same-process conflicts are processed in the classic way;
    #   - `:dead_locking`: same-process conflicts fail the acquirement (the request is dequeued);
    #   - not for `fail_fast` (the failed "no try" attempt does not dequeue the request) and not for
    #     `:work_through`/`:extendable_work_through` (same-process conflicts exit without queueing);
    eager_queueing =
      !fail_fast && (conflict_strategy == :wait_for_lock || conflict_strategy == :dead_locking)
    # Step X: pre-check - the lock state is checked without WATCH first (see Step PRE): `fail_fast`
    #   attempts (they fail on the obtained lock) and retries (the lock was not obtained yet);
    precheck = fail_fast || retry_attempt

    LogVisitor.start(
      logger, log_sampled, log_lock_try, lock_key,
      queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode
    )

    # Step X: start to work with lock acquiring
    result = redis.with do |rconn|
      LogVisitor.rconn_fetched(
        logger, log_sampled, log_lock_try, lock_key,
        queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode
      )

      # Step PRE: (pre-check) the lock state without WATCH: the attempt that can not obtain
      #   the lock fails in one round trip (no WATCH, lock state and MULTI/EXEC round trips);
      #   - the pre-check never obtains the lock: the attempt that can obtain the lock continues
      #     with the WATCH/MULTI logic below (the lock state is read again after WATCH);
      #   - see `precheck_lock` for details;
      if precheck
        inter_result = precheck_lock(
          rconn, logger, log_sampled, log_lock_try, lock_key, read_write_mode, lock_readers_key,
          request_queue, opposite_request_queue, lock_name, acquirer_id, host_id,
          acquirer_position, priority, acquirer_dead_score, queue_ttl, lock_index_enabled,
          lock_index_grace_period, fail_fast, access_strategy
        )
        next if inter_result
      end

      # Step 0:
      #   watch the lock key changes (and discard acquirement if lock is already
      #   obtained by another acquirer during the current lock acquiremntt)
      # Step 0 (RW):
      #   - write lock request watches the readers registry too (and discards acquirement if
      #     a read lock is obtained during the current lock acquirement);
      #   - read lock request does not watch the readers registry (readers should not invalidate
      #     transactions of each other);
      rconn.multi(watch: (read_mode ? [lock_key] : [lock_key, lock_readers_key])) do |transact|
        # Step 0.1: fetch the current lock state in one round trip:
        #   - current write lock obtainer;
        #   - redis server time (read lock expiration is calculated in redis time);
        #   - read lock expiration of the current acquirer;
        #   - the longest read lock (the last one in the readers registry): write lock requests
        #     only (read lock requests do not wait for other readers);
        #   - (eager queueing) the lock request queueing: Steps 2.1, 1, 3 (`queue_lock_request`);
        # NOTE: replies are read by their positions: see "pipeline layout" in `pipeline_lock_state`
        # @type var lock_state: Array[untyped]
        lock_state = rconn.pipelined do |pipeline|
          pipeline_lock_state(
            pipeline, lock_key, lock_readers_key, acquirer_id, read_mode, eager_queueing,
            request_queue, opposite_request_queue, acquirer_position, priority,
            acquirer_dead_score, lock_name, queue_ttl, lock_index_enabled, lock_index_grace_period
          )
        end
        # @type var current_lock_obtainer: String?
        current_lock_obtainer = lock_state[LOCK_STATE_OBTAINER_REPLY]
        redis_time = RedisQueuedLocks::Resource.redis_time_ms(lock_state[LOCK_STATE_REDIS_TIME_REPLY])
        # @type var own_read_lock_expiration: Float?
        own_read_lock_expiration = lock_state[LOCK_STATE_OWN_READ_LOCK_REPLY]
        # NOTE: the write-only tail is the last reply of write lock requests only (read lock
        #   requests have no such reply: never read it without the condition of the pipeline)
        # @type var longest_read_lock: [String, Float]?
        longest_read_lock = read_mode ? nil : lock_state.last.first
        # NOTE:
        #   - expired read locks are ignored (they can live in the registry till the cleanup);
        #   - nil expiration (no read lock) is converted to 0.0 (always expired);
        #   - `read_locked` is used by write lock requests only (always false for read requests);
        read_locked_by_acquirer = own_read_lock_expiration.to_f > redis_time
        read_locked = longest_read_lock ? longest_read_lock[1] > redis_time : false

        # SP-Conflict status PREPARING: the mode of the lock (already obtained by the current
        #   acquirer) that the current lock request conflicts with;
        sp_conflict_rw_mode =
          if current_lock_obtainer != nil && acquirer_id == current_lock_obtainer
            :write
          elsif read_locked_by_acquirer
            :read
          end
        # SP-Conflict status PREPARING: status flag variable
        sp_conflict_status = nil

        # SP-Conflict Step X1: calculate the current deadlock status
        if sp_conflict_rw_mode != nil
          LogVisitor.same_process_conflict_detected(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode
          )

          # NOTE:
          #   read-to-write lock upgrade can not "work through": the read lock is not exclusive
          #   so the "work through" logic will work without an exclusive lock;
          lock_upgrade = !read_mode && sp_conflict_rw_mode == :read

          # SP-Conflict Step X2: self-process dead lock moment started.
          # SP-Conflict CHECK (Step CHECK): check chosen strategy and flag the current status
          case conflict_strategy
          when :work_through
            # <SP-Conflict Moment>: work through => exit
            sp_conflict_status = lock_upgrade ? :conflict_lock_upgrade : :conflict_work_through
          when :extendable_work_through
            # <SP-Conflict Moment>: extendable_work_through => extend the lock pttl and exit
            sp_conflict_status =
              lock_upgrade ? :conflict_lock_upgrade : :extendable_conflict_work_through
          when :wait_for_lock
            # <SP-Conflict Moment>: wait_for_lock => obtain a lock in classic way
            sp_conflict_status = :conflict_wait_for_lock
          when :dead_locking
            # <SP-Conflict Moment>: dead_locking => exit and fail
            sp_conflict_status = :conflict_dead_lock
          else
            # <SP-Conflict Moment>:
            #   - unknown status => work in classic way <wait_for_lock>
            #   - it is a case when the new status is added to the code base in the past
            #     but is forgotten to be added here;
            sp_conflict_status = :conflict_wait_for_lock
          end
          LogVisitor.same_process_conflict_analyzed(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, sp_conflict_status
          )
        end

        # SP-Conflict-Step X2: switch to conflict-based logic or not
        if sp_conflict_status == :extendable_conflict_work_through
          # SP-Conflict-Step FINAL (SPCF): extend the lock and work through
          #   - extend the lock ttl;
          #   - store extensions in lock metadata;
          if sp_conflict_rw_mode == :write
            held_rw_mode = :write

            # SPCF Step 1: extend the lock pttl
            #   - [REDIS RESULT]: in normal cases should return the last script command value
            #     - for the current script should return:
            #       <1> => timeout was set;
            #       <0> => timeount was not set;
            transact.call('EVAL', EXTEND_LOCK_PTTL, 1, lock_key, ttl)
            # SPCF Step <Meta>: store conflict-state additionals in lock metadata:
            # SPCF Step 2: (lock meta-data)
            #   - add the added ttl to reflect the real lock TTL in info;
            #   - [REDIS RESULT]: in normal cases should return the value of <ttl> key
            #     - for non-existent key value starts from <0> (zero)
            transact.call('HINCRBY', lock_key, 'spc_ext_ttl', ttl)
            # SPCF Step 3: (lock meta-data)
            #   - increment the conflcit counter in order to remember
            #     how many times dead lock happened;
            #   - [REDIS RESULT]: in normal cases should return the value of <spc_cnt> key
            #     - for non-existent key starts from 0
            transact.call('HINCRBY', lock_key, 'spc_cnt', 1)
            # SPCF Step 4: (lock meta-data)
            #   - remember the last ext-timestamp and the last ext-initial ttl;
            #   - [REDIS RESULT]: for normal cases should return the number of fields
            #     were added/changed;
            transact.call(
              'HSET',
              lock_key,
              'l_spc_ext_ts', spc_processed_timestamp = Time.now.to_f,
              'l_spc_ext_ini_ttl', ttl
            )
          else
            held_rw_mode = :read
            # SPCF Step 1 (read lock): extend the read lock of the current acquirer
            #   - [REDIS RESULT]: the new read lock expiration time
            #     (or nil if the read lock has been removed from the registry);
            transact.call('ZADD', lock_readers_key, 'XX', 'INCR', ttl, acquirer_id)
            # SPCF Step 2 (read lock): the registry should live as long as the longest read lock
            #   - NX + GT => sets the registry TTL to max(current TTL, extended read lock TTL);
            extended_read_lock_ttl = (own_read_lock_expiration.to_f + ttl.to_i - redis_time).ceil
            transact.call('PEXPIRE', lock_readers_key, extended_read_lock_ttl, 'NX')
            transact.call('PEXPIRE', lock_readers_key, extended_read_lock_ttl, 'GT')
            # SPCF Step 3 (read lock data): the same reentrant lock data as for the write lock
            transact.call('HINCRBY', read_lock_key, 'spc_ext_ttl', ttl)
            transact.call('HINCRBY', read_lock_key, 'spc_cnt', 1)
            transact.call(
              'HSET',
              read_lock_key,
              'l_spc_ext_ts', spc_processed_timestamp = Time.now.to_f,
              'l_spc_ext_ini_ttl', ttl
            )
            # SPCF Step 4 (read lock data): the read lock data lives as long as the read lock
            transact.call('PEXPIRE', read_lock_key, extended_read_lock_ttl, 'NX')
            transact.call('PEXPIRE', read_lock_key, extended_read_lock_ttl, 'GT')
          end
          # SPCF Step 5: (lock index) the lock (write or read) lives longer by the extension:
          #   - the lock index score is increased by the extension (the upper bound of the lock
          #     lifetime stays the upper bound);
          #   - XX => locks without the index entry (of older RQL versions) are not indexed with
          #     a wrong score (see `reindex_locks`);
          #   - [REDIS RESULT]: the new lock index score (nil for the lock without the index entry);
          #   - only with the enabled lock index (the last command of the transaction);
          if lock_index_enabled
            transact.call(
              'ZADD', RedisQueuedLocks::Resource::LOCK_INDEX_KEY, 'XX', 'INCR', ttl, lock_name
            )
          end
          inter_result = :extendable_conflict_work_through

          # @type var spc_processed_timestamp: Float
          LogVisitor.reentrant_lock__extend_and_work_through(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode,
            sp_conflict_status, ttl, spc_processed_timestamp
          )
        # SP-Conflict-Step X2: switch to dead lock logic or not
        elsif sp_conflict_status == :conflict_work_through
          inter_result = :conflict_work_through

          if sp_conflict_rw_mode == :write
            held_rw_mode = :write

            # SPCF Step X: (lock meta-data)
            #   - increment the conflcit counter in order to remember
            #     how many times dead lock happened;
            #   - [REDIS RESULT]: in normal cases should return the value of <spc_cnt> key
            #     - for non-existent key starts from 0
            transact.call('HINCRBY', lock_key, 'spc_cnt', 1)
            # SPCF Step 4: (lock meta-data)
            #   - remember the last ext-timestamp and the last ext-initial ttl;
            #   - [REDIS RESULT]: for normal cases should return the number of fields
            #     were added/changed;
            transact.call(
              'HSET',
              lock_key,
              'l_spc_ts', spc_processed_timestamp = Time.now.to_f
            )
          else
            held_rw_mode = :read

            # SPCF Step X (read lock data): the same reentrant lock data as for the write lock
            transact.call('HINCRBY', read_lock_key, 'spc_cnt', 1)
            transact.call(
              'HSET', read_lock_key, 'l_spc_ts', spc_processed_timestamp = Time.now.to_f
            )
            # SPCF Step X (read lock data): (NX) the read lock data should not outlive the read lock
            #   (it is the case when the read lock data is dropped during the read lock life);
            transact.call(
              'PEXPIRE',
              read_lock_key,
              (own_read_lock_expiration.to_f - redis_time).ceil,
              'NX'
            )
          end

          # @type var spc_processed_timestamp: Float
          LogVisitor.reentrant_lock__work_through(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode,
            sp_conflict_status, spc_processed_timestamp
          )
        # SP-Conflict-Step X2: switch to dead lock logic or not
        elsif sp_conflict_status == :conflict_dead_lock
          inter_result = :conflict_dead_lock
          spc_processed_timestamp = Time.now.to_f

          # @type var spc_processed_timestamp: Float
          LogVisitor.single_process_lock_conflict__dead_lock(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode,
            sp_conflict_status, spc_processed_timestamp
          )
        # SP-Conflict-Step X2 (RW): read-to-write lock upgrade is not supported => exit and fail
        elsif sp_conflict_status == :conflict_lock_upgrade
          inter_result = :conflict_lock_upgrade
          spc_processed_timestamp = Time.now.to_f

          # @type var spc_processed_timestamp: Float
          LogVisitor.single_process_lock_conflict__lock_upgrade(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode,
            sp_conflict_status, spc_processed_timestamp
          )
        # Reached the SP-Non-Conflict Mode (NOTE):
        #   - in other sp-conflict cases we are in <wait_for_lock> (non-conflict) status and should
        #     continue to work in classic way (next lines of code):
        # Fast-Step X0: fail-fast check
        #   - write lock request: the lock is obtained by a writer or by readers;
        #   - read lock request: the lock is obtained by a writer (or by the current acquirer);
        elsif fail_fast && (
          current_lock_obtainer != nil || (read_mode ? read_locked_by_acquirer : read_locked)
        )
          # Fast-Step X1: lock is already obtained. fail fast leads to "no try".
          inter_result = :fail_fast_no_try
        else
          # Step 2.1: drop expired acquirers from the lock queues
          # Step 1: add an acquirer to the lock acquirement queue
          # Step 3: get the actual acquirer waiting in the queue
          #   - one round trip for all of them (see `queue_lock_request`);
          #   - eager queueing: already done in the lock state round trip (Step 0.1);
          #   - Step 2.2 (priorities) runs after them (see below);
          # @type var queue_replies: Array[untyped]
          queue_replies =
            if eager_queueing
              lock_state
            else
              rconn.pipelined do |pipeline|
                queue_lock_request(
                  pipeline, request_queue, opposite_request_queue,
                  acquirer_position, priority, acquirer_id, acquirer_dead_score,
                  lock_name, queue_ttl, lock_index_enabled, lock_index_grace_period
                )
              end
            end
          # NOTE: the position of the first queueing reply (see "pipeline layout" in Step 0.1)
          queue_replies_at = eager_queueing ? LOCK_STATE_QUEUE_REPLIES_AT : 0
          # @type var waiting_request: [String, Float]?
          waiting_request = queue_replies[queue_replies_at + QUEUE_HEAD_REPLY].first
          # @type var opposite_waiting_request: [String, Float]?
          opposite_waiting_request =
            queue_replies[queue_replies_at + OPPOSITE_QUEUE_HEAD_REPLY].first

          LogVisitor.acq_added_to_queue(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, priority
          )
          LogVisitor.remove_expired_acqs(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode
          )

          # Step 2.2: (priorities) drop the dead lock requests of other priority bands that block
          #   the current one (the queue head or the earlier request of the opposite mode) and get
          #   the actual queue heads (no round trips while no dead request blocks the current one);
          actual_queue_heads = drop_dead_requests_ahead(
            rconn, read_write_mode, request_queue, opposite_request_queue, acquirer_id,
            acquirer_position, acquirer_dead_score, access_strategy, waiting_request,
            opposite_waiting_request
          )
          if actual_queue_heads
            waiting_request, opposite_waiting_request, dropped_requests = actual_queue_heads
            log_dropped_requests(
              logger, log_sampled, log_lock_try, lock_key, queue_ttl, acquirer_id, host_id,
              access_strategy, read_write_mode, dropped_requests
            )
          end
          waiting_acquirer = waiting_request ? waiting_request[0] : nil
          # NOTE: the priority of the first request is decoded for logs only
          waiting_priority =
            if log_sampled && log_lock_try && waiting_request
              RedisQueuedLocks::Resource.lock_request_priority(waiting_request[1])
            end

          LogVisitor.get_first_from_queue(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, waiting_acquirer,
            waiting_priority
          )

          # Step 3.1 (RW) + Steps PRE-4.x, ROLLBACK 1.1, 1.2, 2, 3: the obstacle to the lock
          #   obtaining (the same decision and logs as in the pre-check: `lock_obstacle`,
          #   `log_lock_obstacle`);
          # @type var opposite_request_ahead: String?
          opposite_request_ahead = find_opposite_request_ahead(
            access_strategy, opposite_waiting_request, acquirer_position, acquirer_id
          )
          obstacle = lock_obstacle(
            read_mode, access_strategy, acquirer_id, waiting_acquirer, opposite_request_ahead,
            current_lock_obtainer, (read_mode ? read_locked_by_acquirer : read_locked)
          )

          if obstacle
            # Step ROLLBACK: the lock can not be obtained now. retry!
            log_lock_obstacle(
              rconn, obstacle, logger, log_sampled, log_lock_try, lock_key, queue_ttl,
              acquirer_id, host_id, access_strategy, read_write_mode,
              waiting_acquirer, waiting_priority, opposite_waiting_request, current_lock_obtainer
            )
            inter_result = obstacle
          elsif read_mode
            # NOTE: required lock is free and ready to be acquired! acquire! (read lock)

            # Step 6.1: remove our acquirer from waiting queue
            transact.call('ZREM', request_queue, acquirer_id)

            # Step 6.2 (RW): drop expired read locks from the readers registry
            transact.call('ZREMRANGEBYSCORE', lock_readers_key, '-inf', "(#{redis_time}")

            # Step 6.3 (RW): register the read lock (expiration time in redis time)
            transact.call('ZADD', lock_readers_key, redis_time + ttl.to_i, acquirer_id)

            # Step 6.4 (RW): the registry should live as long as the longest read lock
            #   - NX + GT => sets the registry TTL to max(current TTL, read lock TTL);
            #   - in order to prevent "infinite registries" after process crashes;
            transact.call('PEXPIRE', lock_readers_key, ttl, 'NX')
            transact.call('PEXPIRE', lock_readers_key, ttl, 'GT')

            # Step 6.5 (RW): store the read lock data (the same structure as the write lock data
            #   without `acq_id`/`hst_id`: both are derived from the read lock acquirer id that is
            #   a part of the data key and the registry member, so the info adds them on formatting)
            #   - drop the data of the expired read lock of the current acquirer (if any);
            #   - the read lock data lives as long as the read lock;
            transact.call('DEL', read_lock_key)
            transact.call(
              'HSET',
              read_lock_key,
              'ts', timestamp = Time.now.to_f,
              'ini_ttl', ttl,
              *(meta.to_a if meta != nil) # steep:ignore
            )
            transact.call('PEXPIRE', read_lock_key, ttl)

            # Step 6.6 (lock index): the lock name lives in the lock index as long as the read lock
            #   (the upper bound of the read lock lifetime: client time + ttl + grace period);
            #   - in the same transaction: an index entry dropped between the queueing and this
            #     transaction (`#unlock`, `#clear_locks`) is restored with the read lock;
            #   - GT => the score is never decreased (other keys of the lock can live longer);
            #   - only with the enabled lock index (the last command of the transaction);
            if lock_index_enabled
              transact.call(
                'ZADD', RedisQueuedLocks::Resource::LOCK_INDEX_KEY, 'GT',
                RedisQueuedLocks::Resource.lock_index_time + ttl.to_i + lock_index_grace_period,
                lock_name
              )
            end

            inter_result = :lock_obtaining

            LogVisitor.obtain__free_to_acquire(
              logger, log_sampled, log_lock_try, lock_key,
              queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode
            )
          else
            # NOTE: required lock is free and ready to be acquired! acquire! (write lock)

            # Step 6.1: remove our acquirer from waiting queue
            transact.call('ZREM', request_queue, acquirer_id)

            # Step 6.2: acquire a lock and store an info about the acquirer and host
            transact.call(
              'HSET',
              lock_key,
              'acq_id', acquirer_id,
              'hst_id', host_id,
              'ts', timestamp = Time.now.to_f,
              'ini_ttl', ttl,
              *(meta.to_a if meta != nil) # steep:ignore
            )

            # Step 6.3: set the lock expiration time in order to prevent "infinite locks"
            transact.call('PEXPIRE', lock_key, ttl) # NOTE: in milliseconds

            # Step 6.4 (lock index): the lock name lives in the lock index as long as the lock
            #   (the upper bound of the lock lifetime: client time + ttl + grace period);
            #   - in the same transaction: an index entry dropped between the queueing and this
            #     transaction (`#unlock`, `#clear_locks`) is restored with the lock;
            #   - GT => the score is never decreased (other keys of the lock can live longer);
            #   - only with the enabled lock index (the last command of the transaction);
            if lock_index_enabled
              transact.call(
                'ZADD', RedisQueuedLocks::Resource::LOCK_INDEX_KEY, 'GT',
                RedisQueuedLocks::Resource.lock_index_time + ttl.to_i + lock_index_grace_period,
                lock_name
              )
            end

            inter_result = :lock_obtaining

            LogVisitor.obtain__free_to_acquire(
              logger, log_sampled, log_lock_try, lock_key,
              queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode
            )
          end
        end
      end
    rescue RedisQueuedLocks::LockAcquirementIntermediateTimeoutError,
           RedisQueuedLocks::TimedLockIntermediateTimeoutError,
           ::Timeout::ExitException
      # NOTE: (timeouts) the timeout can interrupt the attempt inside the WATCH block:
      #   redis-client sends `UNWATCH` only on `StandardError` (the internal timeouts and the
      #   `Timeout.timeout` of the user without an exception class are `::Exception`s), and the
      #   connection would return to the pool with the active WATCH (an EXEC of the next
      #   transaction on it is aborted when a watched key is changed);
      #   - the closed connection drops the WATCH state and is reconnected on the next use;
      rconn.close
      raise
    end

    # Step 7: Analyze the aquirement attempt:
    # rubocop:disable Lint/DuplicateBranch
    case
    when inter_result == :extendable_conflict_work_through
      # Step 7.same_process_conflict.A:
      #   - extendable_conflict_work_through case => yield <block> without lock realesing/extending;
      #   - lock is extended in logic above;
      #   - if <result == nil> => the lock was changed during an extention:
      #     it is the fail case => go retry.
      #   - else: let's go! :))
      if result.is_a?(::Array) && !result.empty? && held_rw_mode == :read
        # NOTE: read lock extension commands:
        #   1. ZADD XX INCR (new read lock expiration) (OK for != nil)
        #   2. PEXPIRE NX/GT (registry TTL)
        #   3. HINCRBY/HSET/PEXPIRE (read lock data)
        #   4. ZADD XX INCR (the lock index score; the enabled lock index only)
        if result[0] != nil
          {
            ok: true,
            result: {
              process: :extendable_conflict_work_through,
              lock_key: lock_key,
              acq_id: acquirer_id,
              hst_id: host_id,
              ts: spc_processed_timestamp,
              ttl: ttl,
              rw_mode: held_rw_mode
            }
          }
        else
          # NOTE: the read lock is expired and removed from the registry during the extension
          { ok: false, result: :read_lock_is_expired_during_extension }
        end
      elsif result.is_a?(::Array) && result.size == (lock_index_enabled ? 5 : 4)
        # NOTE: four commands should be processed (five with the enabled lock index)
        # TODO:
        #   => (!) analyze the command result and do actions with the depending on it
        #   1. EVAL (extend lock pttl) (OK for != nil)
        #   2. HINCRBY (ttl extension) (OK for != nil)
        #   3. HINCRBY (increased spc count) (OK for != nil)
        #   4. HSET (store the last spc time and ttl data) (OK for == 2 or != nil)
        #   5. ZADD XX INCR (the lock index score; the enabled lock index only) (nil for the lock
        #      without the index entry: it does not affect the extension)
        if result[0] != nil && result[1] != nil && result[2] != nil && result[3] != nil
          {
            ok: true,
            result: {
              process: :extendable_conflict_work_through,
              lock_key: lock_key,
              acq_id: acquirer_id,
              hst_id: host_id,
              ts: spc_processed_timestamp,
              ttl: ttl,
              rw_mode: held_rw_mode
            }
          }
        elsif result[0] != nil
          # NOTE: that is enough to the fact that the lock is extended but <TODO>
          # TODO: add detalized overview (log? some in-line code clarifications?) of the result
          {
            ok: true,
            result: {
              process: :extendable_conflict_work_through,
              lock_key: lock_key,
              acq_id: acquirer_id,
              hst_id: host_id,
              ts: spc_processed_timestamp,
              ttl: ttl,
              rw_mode: held_rw_mode
            }
          }
        else
          # NOTE: unknown behaviour :thinking:
          { ok: false, result: :unknown }
        end
      elsif result == nil || (result.is_a?(::Array) && result.empty?)
        # NOTE: the lock key was changed durign an SPC logic execution
        { ok: false, result: :lock_is_acquired_during_acquire_race }
      else
        # NOTE: unknown behaviour :thinking:. this part is not reachable at the moment.
        { ok: false, result: :unknown }
      end
    when inter_result == :conflict_work_through
      # Step 7.same_process_conflict.B:
      #   - conflict_work_through case => yield <block> without lock realesing/extending
      {
        ok: true,
        result: {
          process: :conflict_work_through,
          lock_key: lock_key,
          acq_id: acquirer_id,
          hst_id: host_id,
          ts: spc_processed_timestamp,
          ttl: ttl,
          rw_mode: held_rw_mode
        }
      }
    when inter_result == :conflict_dead_lock
      # Step 7.same_process_conflict.C:
      #  - deadlock. should fail in acquirement logic;
      { ok: false, result: :conflict_dead_lock }
    when inter_result == :conflict_lock_upgrade
      # Step 7.same_process_conflict.D (RW):
      #  - read-to-write lock upgrade. should fail in acquirement logic;
      { ok: false, result: :conflict_lock_upgrade }
    when fail_fast && inter_result == :fail_fast_no_try
      # Step 7.a: lock is still acquired and we should exit from the logic as soon as possible
      { ok: false, result: :fail_fast_no_try }
    when inter_result == :dead_score_reached
      { ok: false, result: :dead_score_reached }
    when inter_result == :lock_is_still_acquired
      # Step 7.b: lock is still acquired by another process => failed to acquire
      { ok: false, result: :lock_is_still_acquired }
    when inter_result == :read_lock_is_still_acquired
      # Step 7.b (RW): lock is still acquired by readers => failed to acquire
      { ok: false, result: :read_lock_is_still_acquired }
    when inter_result == :acquirer_is_not_first_in_queue
      # Step 7.c: lock is still acquired by another process => failed to acquire
      { ok: false, result: :acquirer_is_not_first_in_queue }
    when inter_result == :write_request_is_ahead
      # Step 7.c (RW): an earlier write lock request should obtain the lock first
      { ok: false, result: :write_request_is_ahead }
    when inter_result == :read_request_is_ahead
      # Step 7.c (RW): an earlier read lock request should obtain the lock first
      { ok: false, result: :read_request_is_ahead }
    when result == nil || (result.is_a?(::Array) && result.empty?)
      # Step 7.d: lock is already acquired durign the acquire race => failed to acquire
      { ok: false, result: :lock_is_acquired_during_acquire_race }
    when inter_result == :lock_obtaining && result.is_a?(::Array)
      # TODO:
      #   => (!) analyze the command result and do actions with the depending on it;
      #   => (*) at this moment we accept that all comamnds are completed successfully;
      #   => (!) need to analyze:
      #   - (write lock):
      #     1. zrem shoud return ? (?)
      #     2. hset should return 3 as minimum
      #        (lock key is added to the redis as a hashmap with 3 fields as minimum)
      #     3. pexpire should return 1 (expiration time is successfully applied)
      #   - (read lock):
      #     1. zrem shoud return ? (?)
      #     2. zremrangebyscore should return the number of dropped expired read locks
      #     3. zadd should return 1 (new read lock) or 0 (expired read lock is re-obtained)
      #     4. pexpire (NX + GT) should return 1 for one of them as minimum
      #     5. del/hset/pexpire (read lock data)

      # Step 7.e: locked! :) let's go! => successfully acquired
      {
        ok: true,
        result: {
          process: :lock_obtaining,
          lock_key: lock_key,
          acq_id: acquirer_id,
          hst_id: host_id,
          ts: timestamp,
          ttl: ttl,
          rw_mode: held_rw_mode
        }
      }
    else
      # Ste 7.3: unknown behaviour :thinking:
      { ok: false, result: :unknown }
    end
    # rubocop:enable Lint/DuplicateBranch
  end
  # rubocop:enable Metrics/MethodLength

  private

  # Queues the lock request and reads the lock queue state (Steps 2.1, 1, 3 and 3.2-3.4 of
  # the attempt): the commands are added to the given pipeline (one round trip with other
  # pipelined commands).
  # Replies (positions relative to the first one): [0] ZREMRANGEBYSCORE (request queue, the
  # priority band of the request), [1] ZREMRANGEBYSCORE (opposite request queue, the priority band
  # of the request), [2] ZADD NX, [QUEUE_HEAD_REPLY] ZRANGE WITHSCORES (the first request of
  # the request queue), [OPPOSITE_QUEUE_HEAD_REPLY] ZRANGE WITHSCORES (the first request of
  # the opposite request queue); the enabled lock index only: [5] PEXPIRE NX, [6] PEXPIRE GT (the
  # request queue TTL), [7] ZADD GT (the lock index), [8] ZREMRANGEBYSCORE (expired lock names of
  # the lock index). Update these constants when the commands change (new commands go to the end:
  # the replies are not read after `OPPOSITE_QUEUE_HEAD_REPLY`, so the conditional lock index
  # commands do not shift the read replies).
  #
  # @param pipeline [RedisClient::Pipeline]
  # @param request_queue [String] Queue of the requests of the requested lock mode.
  # @param opposite_request_queue [String] Queue of the requests of the opposite lock mode.
  # @param acquirer_position [Numeric] The enqueue time shifted by the priority band.
  # @param priority [Integer] The priority band of `acquirer_position`.
  # @param acquirer_id [String]
  # @param acquirer_dead_score [Float]
  #   Requests queued before this time are expired (the barrier of the default priority band).
  # @param lock_name [String] The lock name (the member of the lock index).
  # @param queue_ttl [Integer] Lifetime of the lock request (in seconds).
  # @param lock_index_enabled [Boolean] Send the lock index commands (Steps 3.2-3.4).
  # @param lock_index_grace_period [Integer] In milliseconds.
  # @return [void]
  #
  # @api private
  # @since 1.20.0
  # @version 1.22.0
  def queue_lock_request(
    pipeline,
    request_queue,
    opposite_request_queue,
    acquirer_position,
    priority,
    acquirer_id,
    acquirer_dead_score,
    lock_name,
    queue_ttl,
    lock_index_enabled,
    lock_index_grace_period
  )
    # Step 2.1: drop expired acquirers from the lock queues
    #   - (RW) both queues are cleared: an expired request of the opposite mode should not
    #     block the current request forever;
    #   - (priorities) the requests of the priority band of the current request (the band has its
    #     own time barrier, see `RedisQueuedLocks::Resource::LOCK_PRIORITY_BAND`); a dead request of
    #     another band is dropped when it blocks the current request (`drop_dead_requests_ahead`),
    #     requests of lower priorities are never ahead of the current request;
    #   - before the queueing (Step 1): the old (dead) position of the requeued request (its
    #     position is reset after `queue_ttl`, see `dead_score_reached?`) is dropped first, so
    #     `ZADD NX` adds its new position in the same round trip (after `ZADD NX` the old position
    #     would be kept by `NX` and dropped by the removal: the request would be missing in the
    #     queue in this attempt);
    pipeline_dead_requests_removal(
      pipeline, request_queue, opposite_request_queue, acquirer_dead_score, priority
    )

    # Step 1: add an acquirer to the lock acquirement queue
    # NOTE:
    #   'NX' means "Only add new elements. Don't update already existing elements."
    #   that works as:
    #     1. (enqueue) <<if you are already in the queue - do nothing and wait your time>>
    #     2. (requeue) or <<add to the right pre-calculated position if you are
    #       not in the queue now>>;
    pipeline.call('ZADD', request_queue, 'NX', acquirer_position, acquirer_id)

    # Step 3: get the actual acquirer waiting in the queue (with its position: the band and
    #   the liveness of the queue head are decoded from it, see `drop_dead_requests_ahead`)
    #   - (RW) and the first request of the opposite mode;
    pipeline.call('ZRANGE', request_queue, '0', '0', 'WITHSCORES')
    pipeline.call('ZRANGE', opposite_request_queue, '0', '0', 'WITHSCORES')

    # NOTE: the disabled lock index: no lock index commands, lock request queues have no TTL
    #   (lock-iterating operations scan the keyspace);
    return unless lock_index_enabled

    # Step 3.2: (lock index) the request queue lives as long as the latest lock request
    #   - NX + GT => sets the queue TTL to max(current TTL, queue ttl): waiting acquirers refresh
    #     it on each attempt, the queue of dead acquirers expires (no "infinite queues");
    #   - queues order the lock requests only: a live acquirer whose request is dropped with
    #     the expired queue re-queues it on its next attempt (`ZADD NX` with its position);
    # NOTE: `ceil` - queue ttl can be passed as a Float (in seconds), PEXPIRE requires Integer
    queue_pttl = (queue_ttl * 1_000).ceil
    pipeline.call('PEXPIRE', request_queue, queue_pttl, 'NX')
    pipeline.call('PEXPIRE', request_queue, queue_pttl, 'GT')

    # Step 3.3: (lock index) the lock name lives in the lock index as long as the request queue
    #   - the score is the upper bound of the queue lifetime: client time + queue ttl + grace;
    #     (the lock obtained by the attempt is indexed by its own transaction: Step 6.4/6.6);
    #   - GT => the score is never decreased (other keys of the lock can live longer);
    #   - after the queue command: an index entry dropping between the queue command and
    #     the index command (pruning, `#unlock`, `#clear_locks`) can not leave the queue without
    #     the index entry;
    lock_index_time = RedisQueuedLocks::Resource.lock_index_time
    pipeline.call(
      'ZADD', RedisQueuedLocks::Resource::LOCK_INDEX_KEY, 'GT',
      lock_index_time + queue_pttl + lock_index_grace_period, lock_name
    )

    # Step 3.4: (lock index) drop the expired lock names from the lock index: all the keys of
    #   these locks are expired (amortized cleanup: no background jobs are required);
    pipeline.call(
      'ZREMRANGEBYSCORE', RedisQueuedLocks::Resource::LOCK_INDEX_KEY, '-inf', lock_index_time - 1
    )
  end

  # Adds the removal of the dead lock requests of the given priority band (both lock queues) to
  # the given pipeline (see `queue_lock_request` and `drop_dead_requests_ahead`).
  #
  # @param pipeline [RedisClient::Pipeline]
  # @param request_queue [String]
  # @param opposite_request_queue [String]
  # @param acquirer_dead_score [Float]
  #   Requests queued before this time are expired (the barrier of the default priority band).
  # @param priority [Integer]
  #   The priority band (see `RedisQueuedLocks::Resource::LOCK_PRIORITY_BAND`).
  # @return [void]
  #
  # @api private
  # @since 1.22.0
  def pipeline_dead_requests_removal(
    pipeline,
    request_queue,
    opposite_request_queue,
    acquirer_dead_score,
    priority
  )
    band_floor = RedisQueuedLocks::Resource.lock_priority_band_floor(priority)
    band_dead_score =
      RedisQueuedLocks::Resource.lock_priority_band_dead_score(acquirer_dead_score, priority)
    pipeline.call('ZREMRANGEBYSCORE', request_queue, band_floor, band_dead_score)
    pipeline.call('ZREMRANGEBYSCORE', opposite_request_queue, band_floor, band_dead_score)
  end

  # Adds the lock state commands to the given pipeline (the lock state of the attempt and of
  # the pre-check: one round trip).
  #
  # NOTE: (pipeline layout) replies are read by their positions in the pipeline:
  #   - [LOCK_STATE_OBTAINER_REPLY] HGET, [LOCK_STATE_REDIS_TIME_REPLY] TIME,
  #     [LOCK_STATE_OWN_READ_LOCK_REPLY] ZSCORE - all requests (the head of the pipeline);
  #   - [LOCK_STATE_QUEUE_REPLIES_AT, +5] lock request queueing (`queue_lock_request`: the request
  #     queue commands; +9 with the lock index commands of the enabled lock index) - only with
  #     `queueing` (eager queueing, pre-check of retries);
  #   - the last reply: ZRANGE (the longest read lock) - write lock requests only (the "write-only
  #     tail" of the pipeline: it is read by `lock_state.last` under the same condition);
  #   - conditional commands go after the head (the queueing commands, then the write-only
  #     tail); the write-only tail must stay the last one: read lock requests do not send it,
  #     so a command added after it would get another position for read lock requests
  #     (and its reply would be read as the reply of another command);
  #   - new unconditional commands go into the head: update the position constants, the reply
  #     reading (`try_to_lock` Step 0.1 and `precheck_lock`) and the spec "lock state pipeline
  #     layout" (it checks the layout of both modes, with and without the queueing);
  #
  # @param pipeline [RedisClient::Pipeline]
  # @param lock_key [String]
  # @param lock_readers_key [String]
  # @param acquirer_id [String]
  # @param read_mode [Boolean]
  # @param queueing [Boolean] Queue the lock request in the same round trip.
  # @param request_queue [String]
  # @param opposite_request_queue [String]
  # @param acquirer_position [Numeric]
  # @param priority [Integer]
  # @param acquirer_dead_score [Float]
  # @param lock_name [String] The lock name (the member of the lock index).
  # @param queue_ttl [Integer] In seconds.
  # @param lock_index_enabled [Boolean]
  # @param lock_index_grace_period [Integer] In milliseconds.
  # @return [void]
  #
  # @api private
  # @since 1.20.0
  # @version 1.22.0
  def pipeline_lock_state(
    pipeline,
    lock_key,
    lock_readers_key,
    acquirer_id,
    read_mode,
    queueing,
    request_queue,
    opposite_request_queue,
    acquirer_position,
    priority,
    acquirer_dead_score,
    lock_name,
    queue_ttl,
    lock_index_enabled,
    lock_index_grace_period
  )
    pipeline.call('HGET', lock_key, 'acq_id')
    pipeline.call('TIME')
    pipeline.call('ZSCORE', lock_readers_key, acquirer_id)
    # NOTE: the queueing commands (see "pipeline layout" above)
    if queueing
      queue_lock_request(
        pipeline, request_queue, opposite_request_queue,
        acquirer_position, priority, acquirer_id, acquirer_dead_score,
        lock_name, queue_ttl, lock_index_enabled, lock_index_grace_period
      )
    end
    # NOTE: the write-only tail (keep it the last: see "pipeline layout" above)
    pipeline.call('ZRANGE', lock_readers_key, '-1', '-1', 'WITHSCORES') unless read_mode
  end

  # (RW) The request of the opposite mode that should obtain the lock earlier
  #   - FIFO between modes (`:queued` access strategy only);
  #   - (priorities) positions are shifted by the priority bands: a request of a higher priority
  #     is ahead of any request of a lower priority, requests of the same priority are FIFO;
  #   - equal positions are ordered by acquirer ids;
  #
  # @param access_strategy [Symbol]
  # @param opposite_waiting_request [Array<String,Float>,NilClass]
  #   The first request of the opposite request queue (acquirer id, position).
  # @param acquirer_position [Numeric]
  # @param acquirer_id [String]
  # @return [String,NilClass] The acquirer of the earlier request of the opposite mode.
  #
  # @api private
  # @since 1.20.0
  def find_opposite_request_ahead(
    access_strategy,
    opposite_waiting_request,
    acquirer_position,
    acquirer_id
  )
    return unless access_strategy == :queued && opposite_waiting_request

    if opposite_waiting_request[1] < acquirer_position ||
       (opposite_waiting_request[1] == acquirer_position &&
        opposite_waiting_request[0] < acquirer_id)
      opposite_waiting_request[0]
    end
  end

  # The obstacle to the lock obtaining for the classic (queued) logic of the attempt
  # (the same decision for the attempt and for its pre-check).
  #
  # @param read_mode [Boolean]
  # @param access_strategy [Symbol]
  # @param acquirer_id [String]
  # @param waiting_acquirer [String,NilClass] The first request of the request queue.
  # @param opposite_request_ahead [String,NilClass] See `find_opposite_request_ahead`.
  # @param current_lock_obtainer [String,NilClass] The write lock obtainer.
  # @param read_locked [Boolean]
  #   Write lock requests: live read locks exist; read lock requests: the own read lock is live.
  # @return [Symbol,NilClass] The obstacle (the failure result of the attempt) or `nil`.
  #
  # @api private
  # @since 1.20.0
  def lock_obstacle(
    read_mode,
    access_strategy,
    acquirer_id,
    waiting_acquirer,
    opposite_request_ahead,
    current_lock_obtainer,
    read_locked
  )
    # Step PRE-4.x: check if the request time limit is reached
    #   (when the current try self-removes itself from queue (queue ttl has come))
    if waiting_acquirer == nil
      :dead_score_reached
    # Step STRATEGY (queued): check the actual acquirer: is it ours? are we aready to lock?
    #   - (RW) write lock requests are processed one by one;
    #   - (RW) read lock requests are processed in parallel;
    elsif !read_mode && access_strategy == :queued && waiting_acquirer != acquirer_id
      # Step ROLLBACK 1.1: our time hasn't come yet. retry!
      :acquirer_is_not_first_in_queue
    elsif opposite_request_ahead
      # Step ROLLBACK 1.2 (RW): an earlier request of the opposite mode goes first. retry!
      read_mode ? :write_request_is_ahead : :read_request_is_ahead
    # Step 5: find the lock -> check if the our lock is already acquired
    #   - NOTE: the attempt fetches the lock state after WATCH (step 0.1) so any lock state change
    #     invalidates its transaction;
    elsif current_lock_obtainer
      # Step ROLLBACK 2: required lock is stil acquired. retry!
      :lock_is_still_acquired
    elsif read_locked
      # Step ROLLBACK 3 (RW): the lock is still obtained by readers. retry!
      #   - write lock request waits for all readers;
      #   - read lock request waits for its own read lock (`:wait_for_lock` conflict strategy);
      :read_lock_is_still_acquired
    end
  end

  # Logs the obstacle to the lock obtaining (see `lock_obstacle`): the exit event of the attempt.
  #
  # @param rconn [RedisClient]
  # @param obstacle [Symbol]
  # @param logger [::Logger,#debug]
  # @param log_sampled [Boolean]
  # @param log_lock_try [Boolean]
  # @param lock_key [String]
  # @param queue_ttl [Integer]
  # @param acquirer_id [String]
  # @param host_id [String]
  # @param access_strategy [Symbol]
  # @param read_write_mode [Symbol]
  # @param waiting_acquirer [String,NilClass]
  # @param waiting_priority [Integer,NilClass]
  #   The priority of the first request (decoded for logs only: `nil` without logs).
  # @param opposite_waiting_request [Array<String,Float>,NilClass]
  #   The first request of the opposite queue (the request ahead of the `*_request_is_ahead`
  #   obstacles, see `find_opposite_request_ahead`).
  # @param current_lock_obtainer [String,NilClass]
  # @return [void]
  #
  # @api private
  # @since 1.20.0
  # @version 1.22.0
  # rubocop:disable Metrics/MethodLength
  def log_lock_obstacle(
    rconn,
    obstacle,
    logger,
    log_sampled,
    log_lock_try,
    lock_key,
    queue_ttl,
    acquirer_id,
    host_id,
    access_strategy,
    read_write_mode,
    waiting_acquirer,
    waiting_priority,
    opposite_waiting_request,
    current_lock_obtainer
  )
    case obstacle
    when :dead_score_reached
      LogVisitor.exit__queue_ttl_reached(
        logger, log_sampled, log_lock_try, lock_key,
        queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode
      )
    when :acquirer_is_not_first_in_queue
      LogVisitor.exit__no_first(
        logger, log_sampled, log_lock_try, lock_key,
        queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, waiting_acquirer,
        waiting_priority,
        # NOTE: lock data is extracted for logs only
        ((log_sampled && log_lock_try) ? rconn.call('HGETALL', lock_key).to_h : NO_LOCK_DATA)
      )
    when :write_request_is_ahead
      ahead_request = opposite_waiting_request #: [String, Float]
      # NOTE: the priority of the request ahead is decoded for logs only
      ahead_priority =
        if log_sampled && log_lock_try
          RedisQueuedLocks::Resource.lock_request_priority(ahead_request[1])
        end
      LogVisitor.exit__write_request_ahead(
        logger, log_sampled, log_lock_try, lock_key,
        queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode,
        ahead_request[0], ahead_priority
      )
    when :read_request_is_ahead
      ahead_request = opposite_waiting_request #: [String, Float]
      # NOTE: the priority of the request ahead is decoded for logs only
      ahead_priority =
        if log_sampled && log_lock_try
          RedisQueuedLocks::Resource.lock_request_priority(ahead_request[1])
        end
      LogVisitor.exit__read_request_ahead(
        logger, log_sampled, log_lock_try, lock_key,
        queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode,
        ahead_request[0], ahead_priority
      )
    when :lock_is_still_acquired
      LogVisitor.exit__lock_still_obtained(
        logger, log_sampled, log_lock_try, lock_key,
        queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode,
        waiting_acquirer, waiting_priority,
        current_lock_obtainer, #: String
        # NOTE: lock data is extracted for logs only
        ((log_sampled && log_lock_try) ? rconn.call('HGETALL', lock_key).to_h : NO_LOCK_DATA)
      )
    when :read_lock_is_still_acquired
      LogVisitor.exit__read_lock_still_obtained(
        logger, log_sampled, log_lock_try, lock_key,
        queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, waiting_acquirer,
        waiting_priority
      )
    end
  end
  # rubocop:enable Metrics/MethodLength

  # (priorities) Drops the dead lock requests of other priority bands that block the current lock
  # request (`:queued` access strategy: the head of the write lock queue for write lock requests,
  # the earlier lock request of the opposite mode for both modes) and reads the actual queue heads
  # (Step 2.2 of the attempt and of its pre-check):
  #   - the dead lock requests of the band of the current request are dropped by the queueing
  #     (Step 2.1, before the queue heads are read) and requests of lower priorities are never
  #     ahead of it: only a request of a higher priority can be a dead blocking request;
  #   - the band and the enqueue time of the blocking request are decoded from its position (see
  #     `RedisQueuedLocks::Resource::LOCK_PRIORITY_BAND`): no Redis commands to check the liveness,
  #     any band is recognized (the priority range of the current RQL version is not used), the
  #     time barrier is the barrier of the current request (`acquirer_dead_score`: its `queue_ttl`);
  #   - the dead blocking requests (the head of the write lock queue and the earlier request of the
  #     opposite mode) are dropped with all dead requests of their bands (both queues) in one round
  #     trip with the reading of the actual queue heads; no round trips while no dead request
  #     blocks the current one (the lock state does not matter: the attempt drops the dead blocking
  #     requests even when the lock is obtained by another acquirer);
  #   - up to `MAX_DEAD_REQUEST_REMOVALS` round trips (one or two bands each) per call;
  #   - (infinite positions) RQL never writes them (manual writes of the queues, see
  #     `RedisQueuedLocks::Resource.lock_request_priority`): a blocking request at `-inf` is always
  #     dead (the highest band, no enqueue time) and is dropped with all requests at `-inf` of both
  #     queues in the same round trip; a request at `+inf` is never ahead of the current request;
  #   - the dropped blocking requests are returned, not logged: the attempt and its pre-check log
  #     them at the same step (after the queueing log events, see `log_dropped_requests`);
  #
  # @param rconn [RedisClient]
  # @param read_write_mode [Symbol]
  # @param request_queue [String]
  # @param opposite_request_queue [String]
  # @param acquirer_id [String]
  # @param acquirer_position [Numeric]
  # @param acquirer_dead_score [Float]
  #   Requests queued before this time are expired (the barrier of the default priority band).
  # @param access_strategy [Symbol]
  # @param waiting_request [Array<String,Float>,NilClass] The head of the request queue.
  # @param opposite_waiting_request [Array<String,Float>,NilClass]
  #   The head of the opposite request queue.
  # @return [Array<Array<String,Float>,NilClass,Array<Array<String,Integer>>>,NilClass]
  #   - the actual queue heads and the dropped blocking requests (the acquirer and the priority of
  #     each one, in the order of the removal): `[waiting_request, opposite_waiting_request,
  #     dropped_requests]` when at least one dead lock request is dropped;
  #   - `nil` otherwise;
  #
  # @api private
  # @since 1.22.0
  # rubocop:disable Metrics/MethodLength
  def drop_dead_requests_ahead(
    rconn,
    read_write_mode,
    request_queue,
    opposite_request_queue,
    acquirer_id,
    acquirer_position,
    acquirer_dead_score,
    access_strategy,
    waiting_request,
    opposite_waiting_request
  )
    return unless access_strategy == :queued

    read_mode = (read_write_mode == :read)
    round_trips = 0
    # NOTE: allocated by the first removal only (no allocations while nothing dead blocks)
    # @type var dropped_requests: Array[[String, Integer]]?
    dropped_requests = nil

    while round_trips < MAX_DEAD_REQUEST_REMOVALS
      # NOTE: the lock requests that block the current one (the same order as in `lock_obstacle`):
      #   the head of the write lock queue (write lock requests only) and the earlier lock request
      #   of the opposite mode; a live head of the write lock queue stops the removal (the attempt
      #   waits for it), the dead blocking requests are dropped in one round trip (both bands);
      # @type var dead_head: [String, Float]?
      dead_head = nil
      # @type var dead_head_priority: Integer?
      dead_head_priority = nil
      if !read_mode && waiting_request && waiting_request[0] != acquirer_id
        dead_head_priority = dead_request_priority(waiting_request, acquirer_dead_score)
        break unless dead_head_priority

        dead_head = waiting_request
      end
      # @type var dead_ahead: [String, Float]?
      dead_ahead = nil
      # @type var dead_ahead_priority: Integer?
      dead_ahead_priority = nil
      if find_opposite_request_ahead(
        access_strategy, opposite_waiting_request, acquirer_position, acquirer_id
      )
        ahead_request = opposite_waiting_request #: [String, Float]
        dead_ahead_priority = dead_request_priority(ahead_request, acquirer_dead_score)
        dead_ahead = ahead_request if dead_ahead_priority
      end
      break unless dead_head_priority || dead_ahead_priority

      # NOTE: (pipeline layout) ZREMRANGEBYSCORE of both queues for each dropped band (one or two
      #   bands) and for the requests at `-inf` (a dead blocking request at `-inf` only), then [-2]
      #   ZRANGE WITHSCORES (the head of the request queue) and [-1] ZRANGE WITHSCORES (the head of
      #   the opposite request queue);
      # @type var queue_state: Array[untyped]
      queue_state = rconn.pipelined do |pipeline|
        if dead_head_priority
          pipeline_dead_requests_removal(
            pipeline, request_queue, opposite_request_queue, acquirer_dead_score, dead_head_priority
          )
        end
        if dead_ahead_priority && dead_ahead_priority != dead_head_priority
          pipeline_dead_requests_removal(
            pipeline, request_queue, opposite_request_queue, acquirer_dead_score,
            dead_ahead_priority
          )
        end
        # NOTE: (infinite positions) a dead blocking request at `-inf` (a manual write: out of all
        #   bands, see `RedisQueuedLocks::Resource.lock_request_priority`) is not covered by
        #   the band removal of its decoded priority (it drops the dead requests of that band
        #   only): the requests at `-inf` are dropped from both queues by their position;
        if (dead_head && dead_head[1] == -Float::INFINITY) ||
           (dead_ahead && dead_ahead[1] == -Float::INFINITY)
          pipeline.call('ZREMRANGEBYSCORE', request_queue, '-inf', '-inf')
          pipeline.call('ZREMRANGEBYSCORE', opposite_request_queue, '-inf', '-inf')
        end
        pipeline.call('ZRANGE', request_queue, '0', '0', 'WITHSCORES')
        pipeline.call('ZRANGE', opposite_request_queue, '0', '0', 'WITHSCORES')
      end
      # @type var removed_requests: Array[[String, Integer]]
      removed_requests = dropped_requests || []
      removed_requests << [dead_head[0], dead_head_priority] if dead_head && dead_head_priority
      removed_requests << [dead_ahead[0], dead_ahead_priority] if dead_ahead && dead_ahead_priority
      dropped_requests = removed_requests
      waiting_request = queue_state[-2].first
      opposite_waiting_request = queue_state[-1].first
      round_trips += 1
    end

    [waiting_request, opposite_waiting_request, dropped_requests] if dropped_requests
  end
  # rubocop:enable Metrics/MethodLength

  # (priorities) Logs the dead lock requests dropped by `drop_dead_requests_ahead` (the attempt
  # and its pre-check log them at the same step: after the queueing log events).
  #
  # @param logger [::Logger,#debug]
  # @param log_sampled [Boolean]
  # @param log_lock_try [Boolean]
  # @param lock_key [String]
  # @param queue_ttl [Integer]
  # @param acquirer_id [String]
  # @param host_id [String]
  # @param access_strategy [Symbol]
  # @param read_write_mode [Symbol]
  # @param dropped_requests [Array<Array<String,Integer>>]
  #   The acquirer and the priority of each dropped lock request.
  # @return [void]
  #
  # @api private
  # @since 1.22.0
  def log_dropped_requests(
    logger,
    log_sampled,
    log_lock_try,
    lock_key,
    queue_ttl,
    acquirer_id,
    host_id,
    access_strategy,
    read_write_mode,
    dropped_requests
  )
    return unless log_sampled && log_lock_try

    dropped_requests.each do |dead_acquirer_id, dead_priority|
      LogVisitor.dead_request_removed(
        logger, log_sampled, log_lock_try, lock_key, queue_ttl, acquirer_id, host_id,
        access_strategy, read_write_mode, dead_acquirer_id, dead_priority
      )
    end
  end

  # (priorities) The priority band of the dead lock request (see `drop_dead_requests_ahead`): the
  # band and the enqueue time are decoded from the position of the request (infinite positions:
  # `-inf` is decoded to the highest band and is always dead, `+inf` to the lowest band and is never
  # dead, see `RedisQueuedLocks::Resource.lock_request_priority`).
  #
  # @param lock_request [Array<String,Float>] The acquirer and the position of the lock request.
  # @param acquirer_dead_score [Float]
  #   Requests queued before this time are expired (the barrier of the default priority band).
  # @return [Integer,NilClass]
  #   The priority of the dead lock request, `nil` for a live one (its position is after the time
  #   barrier of its band: the same barrier as the dropping of the dead requests of the band).
  #
  # @api private
  # @since 1.22.0
  def dead_request_priority(lock_request, acquirer_dead_score)
    priority = RedisQueuedLocks::Resource.lock_request_priority(lock_request[1])
    band_dead_score =
      RedisQueuedLocks::Resource.lock_priority_band_dead_score(acquirer_dead_score, priority)
    priority if lock_request[1] <= band_dead_score
  end

  # Pre-check of the attempt (Step PRE): the lock state without WATCH (one round trip).
  #   - `fail_fast` attempts: the lock state only (the request is not queued: the failed "no try"
  #     attempt does not dequeue the request); fails with `:fail_fast_no_try` on the obtained lock;
  #   - retries: the lock state and the lock request queueing (the request is already queued by
  #     the previous attempts); fails with the obstacle of the classic logic (`lock_obstacle`)
  #     and logs the same events as the failed attempt in the same order;
  #   - (priorities) retries drop the dead lock requests of other priority bands that block the
  #     request before the decision (Step 2.2 of the attempt: one more round trip per dropped
  #     band, see `drop_dead_requests_ahead`);
  #   - same-process conflicts (the lock is obtained by the current acquirer) and locks that can be
  #     obtained are not decided: the attempt continues with the WATCH/MULTI logic (`nil`);
  #   - the pre-check never obtains the lock (mutual exclusion relies on WATCH/MULTI only);
  #
  # @param rconn [RedisClient]
  # @param logger [::Logger,#debug]
  # @param log_sampled [Boolean]
  # @param log_lock_try [Boolean]
  # @param lock_key [String]
  # @param read_write_mode [Symbol]
  # @param lock_readers_key [String]
  # @param request_queue [String]
  # @param opposite_request_queue [String]
  # @param lock_name [String] The lock name (the member of the lock index).
  # @param acquirer_id [String]
  # @param host_id [String]
  # @param acquirer_position [Numeric]
  # @param priority [Integer]
  # @param acquirer_dead_score [Float]
  # @param queue_ttl [Integer]
  # @param lock_index_enabled [Boolean]
  # @param lock_index_grace_period [Integer] In milliseconds.
  # @param fail_fast [Boolean]
  # @param access_strategy [Symbol]
  # @return [Symbol,NilClass] The failure result of the attempt or `nil` (continue the attempt).
  #
  # @api private
  # @since 1.20.0
  # @version 1.22.0
  # rubocop:disable Metrics/MethodLength
  def precheck_lock(
    rconn,
    logger,
    log_sampled,
    log_lock_try,
    lock_key,
    read_write_mode,
    lock_readers_key,
    request_queue,
    opposite_request_queue,
    lock_name,
    acquirer_id,
    host_id,
    acquirer_position,
    priority,
    acquirer_dead_score,
    queue_ttl,
    lock_index_enabled,
    lock_index_grace_period,
    fail_fast,
    access_strategy
  )
    read_mode = (read_write_mode == :read)
    # NOTE: the same pipeline layout and the same reply reading as in Step 0.1 of the attempt
    # @type var lock_state: Array[untyped]
    lock_state = rconn.pipelined do |pipeline|
      pipeline_lock_state(
        pipeline, lock_key, lock_readers_key, acquirer_id, read_mode, !fail_fast,
        request_queue, opposite_request_queue, acquirer_position, priority, acquirer_dead_score,
        lock_name, queue_ttl, lock_index_enabled, lock_index_grace_period
      )
    end
    # @type var current_lock_obtainer: String?
    current_lock_obtainer = lock_state[LOCK_STATE_OBTAINER_REPLY]
    redis_time = RedisQueuedLocks::Resource.redis_time_ms(lock_state[LOCK_STATE_REDIS_TIME_REPLY])
    # @type var own_read_lock_expiration: Float?
    own_read_lock_expiration = lock_state[LOCK_STATE_OWN_READ_LOCK_REPLY]
    # @type var longest_read_lock: [String, Float]?
    longest_read_lock = read_mode ? nil : lock_state.last.first
    read_locked_by_acquirer = own_read_lock_expiration.to_f > redis_time
    read_locked = longest_read_lock ? longest_read_lock[1] > redis_time : false

    # NOTE: same-process conflicts are processed by the attempt (conflict strategies)
    return if acquirer_id == current_lock_obtainer || read_locked_by_acquirer

    # NOTE: the fail-fast check of the attempt (Fast-Step X0) without same-process conflicts
    return ((current_lock_obtainer || read_locked) ? :fail_fast_no_try : nil) if fail_fast

    # @type var waiting_request: [String, Float]?
    waiting_request = lock_state[LOCK_STATE_QUEUE_REPLIES_AT + QUEUE_HEAD_REPLY].first
    # @type var opposite_waiting_request: [String, Float]?
    opposite_waiting_request =
      lock_state[LOCK_STATE_QUEUE_REPLIES_AT + OPPOSITE_QUEUE_HEAD_REPLY].first
    # NOTE: (priorities) Step 2.2 of the attempt: the dead lock requests of other priority bands
    #   that block the current one are dropped before the obstacle decision; they are logged at
    #   the step of the attempt (after the queueing log events of the failed pre-check, they
    #   follow the decision) or before the attempt that continues (it logs its own queueing);
    actual_queue_heads = drop_dead_requests_ahead(
      rconn, read_write_mode, request_queue, opposite_request_queue, acquirer_id,
      acquirer_position, acquirer_dead_score, access_strategy, waiting_request,
      opposite_waiting_request
    )
    # @type var dropped_requests: Array[[String, Integer]]?
    dropped_requests = nil
    if actual_queue_heads
      waiting_request, opposite_waiting_request, dropped_requests = actual_queue_heads
    end
    waiting_acquirer = waiting_request ? waiting_request[0] : nil
    # @type var opposite_request_ahead: String?
    opposite_request_ahead = find_opposite_request_ahead(
      access_strategy, opposite_waiting_request, acquirer_position, acquirer_id
    )
    obstacle = lock_obstacle(
      read_mode, access_strategy, acquirer_id, waiting_acquirer, opposite_request_ahead,
      current_lock_obtainer, read_locked
    )
    unless obstacle
      if dropped_requests
        log_dropped_requests(
          logger, log_sampled, log_lock_try, lock_key, queue_ttl, acquirer_id, host_id,
          access_strategy, read_write_mode, dropped_requests
        )
      end
      return
    end

    # NOTE: the priority of the first request is decoded for logs only
    waiting_priority =
      if log_sampled && log_lock_try && waiting_request
        RedisQueuedLocks::Resource.lock_request_priority(waiting_request[1])
      end

    # NOTE: the same log events as the failed attempt in the same order (queueing steps, the dropped
    #   dead requests, the first request, the exit event)
    LogVisitor.acq_added_to_queue(
      logger, log_sampled, log_lock_try, lock_key,
      queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, priority
    )
    LogVisitor.remove_expired_acqs(
      logger, log_sampled, log_lock_try, lock_key,
      queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode
    )
    if dropped_requests
      log_dropped_requests(
        logger, log_sampled, log_lock_try, lock_key, queue_ttl, acquirer_id, host_id,
        access_strategy, read_write_mode, dropped_requests
      )
    end
    LogVisitor.get_first_from_queue(
      logger, log_sampled, log_lock_try, lock_key,
      queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, waiting_acquirer,
      waiting_priority
    )
    log_lock_obstacle(
      rconn, obstacle, logger, log_sampled, log_lock_try, lock_key, queue_ttl,
      acquirer_id, host_id, access_strategy, read_write_mode,
      waiting_acquirer, waiting_priority, opposite_waiting_request, current_lock_obtainer
    )
    obstacle
  end
  # rubocop:enable Metrics/MethodLength
end
# rubocop:enable Metrics/ModuleLength
