# frozen_string_literal: true

# Read/Write locks (`read_write_mode`):
#   - `:write` lock is exclusive: it is obtained when there is no write lock and no live read lock;
#   - `:read` lock is shared: it is obtained when there is no write lock;
#   - read locks are stored in the readers registry: a sorted set where the member is an acquirer
#     id and the score is the read lock expiration time (redis server time, in milliseconds);
#   - each read lock has its own data hash (the same structure as the write lock: acquirer, host,
#     timestamp, ttl, meta, reentrant lock data) with the read lock ttl; the readers registry is
#     the only source of truth for the read lock existence (the data hash is a data carrier only);
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
#   - `:random` access strategy ignores both queues (no ordering between modes, so
#     a continuous flow of readers can starve writers);
#
# @api private
# @since 1.0.0
# @version 1.18.0
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

  # @param redis [RedisClient]
  # @param logger [::Logger,#debug]
  # @param log_lock_try [Boolean]
  # @param lock_key [String]
  # @param read_write_mode [Symbol] `:read` or `:write`
  # @param lock_key_queue [String] Queue of write lock requests.
  # @param read_lock_key_queue [String] Queue of read lock requests.
  # @param lock_readers_key [String] Registry of read lock holders.
  # @param read_lock_key [String] Read lock data of the current acquirer.
  # @param acquirer_id [String]
  # @param host_id [String]
  # @param acquirer_position [Numeric]
  # @param ttl [Integer]
  # @param queue_ttl [Integer]
  # @param fail_fast [Boolean]
  # @param conflict_strategy [Symbol]
  # @param access_strategy [Symbol]
  # @param meta [NilClass,Hash<String|Symbol,Any>]
  # @param log_sampled [Boolean]
  # @param instr_sampled [Boolean]
  # @return [Hash<Symbol,Any>] Format: { ok: true/false, result: Symbol|Hash<Symbol,Any> }
  #
  # @api private
  # @since 1.0.0
  # @version 1.18.0
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
    acquirer_id,
    host_id,
    acquirer_position,
    ttl,
    queue_ttl,
    fail_fast,
    conflict_strategy,
    access_strategy,
    meta,
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
        #   - the longest read lock (the last one in the readers registry);
        # @type var lock_state: [String?, Array[String], Float?, Array[[String, Float]]]
        lock_state = rconn.pipelined do |pipeline|
          pipeline.call('HGET', lock_key, 'acq_id')
          pipeline.call('TIME')
          pipeline.call('ZSCORE', lock_readers_key, acquirer_id)
          pipeline.call('ZRANGE', lock_readers_key, '-1', '-1', 'WITHSCORES')
        end
        current_lock_obtainer = lock_state[0]
        redis_time = RedisQueuedLocks::Resource.redis_time_ms(lock_state[1])
        own_read_lock_expiration = lock_state[2]
        longest_read_lock = lock_state[3].first
        # NOTE:
        #   - expired read locks are ignored (they can live in the registry till the cleanup);
        #   - nil expiration (no read lock) is converted to 0.0 (always expired);
        read_locked_by_acquirer = own_read_lock_expiration.to_f > redis_time
        read_locked = longest_read_lock != nil && longest_read_lock[1] > redis_time

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
          # Step RW: request queue of the current mode and the queue of the opposite mode
          request_queue = read_mode ? read_lock_key_queue : lock_key_queue
          opposite_request_queue = read_mode ? lock_key_queue : read_lock_key_queue

          # Step 1: add an acquirer to the lock acquirement queue
          # NOTE:
          #   'NX' means "Only add new elements. Don't update already existing elements."
          #   that works as:
          #     1. (enqueue) <<if you are already in the queue - do nothing and wait your time>>
          #     2. (requeue) or <<add to the right pre-calculated position if you are
          #       not in the queue now>>;
          rconn.call('ZADD', request_queue, 'NX', acquirer_position, acquirer_id)

          LogVisitor.acq_added_to_queue(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode
          )

          # Step 2.1: drop expired acquirers from the lock queues
          #   - (RW) both queues are cleared: an expired request of the opposite mode should not
          #     block the current request forever;
          acquirer_dead_score = RedisQueuedLocks::Resource.acquirer_dead_score(queue_ttl)
          rconn.pipelined do |pipeline|
            pipeline.call('ZREMRANGEBYSCORE', request_queue, '-inf', acquirer_dead_score)
            pipeline.call('ZREMRANGEBYSCORE', opposite_request_queue, '-inf', acquirer_dead_score)
          end

          LogVisitor.remove_expired_acqs(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode
          )

          # Step 3: get the actual acquirer waiting in the queue
          #   - (RW) and the first request of the opposite mode;
          # @type var queue_heads: [Array[String], Array[[String, Float]]]
          queue_heads = rconn.pipelined do |pipeline|
            pipeline.call('ZRANGE', request_queue, '0', '0')
            pipeline.call('ZRANGE', opposite_request_queue, '0', '0', 'WITHSCORES')
          end
          waiting_acquirer = queue_heads[0].first
          opposite_waiting_request = queue_heads[1].first

          LogVisitor.get_first_from_queue(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, waiting_acquirer
          )

          # Step 3.1 (RW): the opposite mode request that should obtain the lock earlier
          #   - FIFO between modes (`:queued` access strategy only);
          #   - equal positions are ordered by acquirer ids;
          # @type var opposite_request_ahead: String?
          opposite_request_ahead =
            if access_strategy == :queued && opposite_waiting_request != nil &&
               (opposite_waiting_request[1] < acquirer_position ||
                (opposite_waiting_request[1] == acquirer_position &&
                 opposite_waiting_request[0] < acquirer_id))
              opposite_waiting_request[0]
            end

          # Step PRE-4.x: check if the request time limit is reached
          #   (when the current try self-removes itself from queue (queue ttl has come))
          if waiting_acquirer == nil
            LogVisitor.exit__queue_ttl_reached(
              logger, log_sampled, log_lock_try, lock_key,
              queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode
            )

            inter_result = :dead_score_reached
            # Step STRATEGY: check the stragegy and corresponding preventing factor
            # Step STRATEGY (queued): check the actual acquirer: is it ours? are we aready to lock?
            #   - (RW) write lock requests are processed one by one;
            #   - (RW) read lock requests are processed in parallel;
          elsif !read_mode && access_strategy == :queued && waiting_acquirer != acquirer_id
            # Step ROLLBACK 1.1: our time hasn't come yet. retry!

            LogVisitor.exit__no_first(
              logger, log_sampled, log_lock_try, lock_key,
              queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, waiting_acquirer,
              # NOTE: lock data is extracted for logs only
              ((log_sampled && log_lock_try) ? rconn.call('HGETALL', lock_key).to_h : {})
            )
            inter_result = :acquirer_is_not_first_in_queue
          elsif opposite_request_ahead
            # Step ROLLBACK 1.2 (RW): an earlier request of the opposite mode goes first. retry!
            if read_mode
              LogVisitor.exit__write_request_ahead(
                logger, log_sampled, log_lock_try, lock_key,
                queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode,
                opposite_request_ahead
              )
              inter_result = :write_request_is_ahead
            else
              LogVisitor.exit__read_request_ahead(
                logger, log_sampled, log_lock_try, lock_key,
                queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode,
                opposite_request_ahead
              )
              inter_result = :read_request_is_ahead
            end
          # NOTE: our time has come! let's try to acquire the lock!
          # Step 5: find the lock -> check if the our lock is already acquired
          #   - NOTE: the lock state is fetched after WATCH (step 0.1) so any lock state change
          #     invalidates the transaction;
          elsif current_lock_obtainer
            # Step ROLLBACK 2: required lock is stil acquired. retry!

            LogVisitor.exit__lock_still_obtained(
              logger, log_sampled, log_lock_try, lock_key,
              queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode,
              waiting_acquirer, current_lock_obtainer,
              # NOTE: lock data is extracted for logs only
              ((log_sampled && log_lock_try) ? rconn.call('HGETALL', lock_key).to_h : {})
            )
            inter_result = :lock_is_still_acquired
          elsif read_mode ? read_locked_by_acquirer : read_locked
            # Step ROLLBACK 3 (RW): the lock is still obtained by readers. retry!
            #   - write lock request waits for all readers;
            #   - read lock request waits for its own read lock
            #     (`:wait_for_lock` conflict strategy);

            LogVisitor.exit__read_lock_still_obtained(
              logger, log_sampled, log_lock_try, lock_key,
              queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, waiting_acquirer
            )
            inter_result = :read_lock_is_still_acquired
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

            # Step 6.5 (RW): store the read lock data (the same structure as the write lock data)
            #   - drop the data of the expired read lock of the current acquirer (if any);
            #   - the read lock data lives as long as the read lock;
            transact.call('DEL', read_lock_key)
            transact.call(
              'HSET',
              read_lock_key,
              'acq_id', acquirer_id,
              'hst_id', host_id,
              'ts', timestamp = Time.now.to_f,
              'ini_ttl', ttl,
              *(meta.to_a if meta != nil) # steep:ignore
            )
            transact.call('PEXPIRE', read_lock_key, ttl)

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

            inter_result = :lock_obtaining

            LogVisitor.obtain__free_to_acquire(
              logger, log_sampled, log_lock_try, lock_key,
              queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode
            )
          end
        end
      end
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
      elsif result.is_a?(::Array) && result.size == 4 # NOTE: four commands should be processed
        # TODO:
        #   => (!) analyze the command result and do actions with the depending on it
        #   1. EVAL (extend lock pttl) (OK for != nil)
        #   2. HINCRBY (ttl extension) (OK for != nil)
        #   3. HINCRBY (increased spc count) (OK for != nil)
        #   4. HSET (store the last spc time and ttl data) (OK for == 2 or != nil)
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
end
# rubocop:enable Metrics/ModuleLength
