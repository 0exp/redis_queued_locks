# frozen_string_literal: true

# @api private
# @since 1.0.0
# @version 1.7.0
# rubocop:disable Metrics/ModuleLength
module RedisQueuedLocks::Acquier::AcquireLock::TryToLock
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
  # @param lock_key_queue [String]
  # @param acquier_id [String]
  # @param host_id [String]
  # @param acquier_position [Numeric]
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
  # @version 1.9.0
  # rubocop:disable Metrics/MethodLength
  def try_to_lock(
    redis,
    logger,
    log_lock_try,
    lock_key,
    lock_key_queue,
    acquier_id,
    host_id,
    acquier_position,
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
    inter_result = nil
    timestamp = nil
    spc_processed_timestamp = nil

    LogVisitor.start(
      logger, log_sampled, log_lock_try, lock_key,
      queue_ttl, acquier_id, host_id, access_strategy
    )

    # Step X: start to work with lock acquiring
    result = redis.with do |rconn|
      LogVisitor.rconn_fetched(
        logger, log_sampled, log_lock_try, lock_key,
        queue_ttl, acquier_id, host_id, access_strategy
      )

      # Step 0:
      #   watch the lock key changes (and discard acquirement if lock is already
      #   obtained by another acquier during the current lock acquiremntt)
      rconn.multi(watch: [lock_key]) do |transact|
        # SP-Conflict status PREPARING: get the current lock obtainer
        current_lock_obtainer = rconn.call('HGET', lock_key, 'acq_id')
        # SP-Conflict status PREPARING: status flag variable
        sp_conflict_status = nil

        # SP-Conflict Step X1: calculate the current deadlock status
        if current_lock_obtainer != nil && acquier_id == current_lock_obtainer
          LogVisitor.same_process_conflict_detected(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquier_id, host_id, access_strategy
          )

          # SP-Conflict Step X2: self-process dead lock moment started.
          # SP-Conflict CHECK (Step CHECK): check chosen strategy and flag the current status
          case conflict_strategy
          when :work_through
            # <SP-Conflict Moment>: work through => exit
            sp_conflict_status = :conflict_work_through
          when :extendable_work_through
            # <SP-Conflict Moment>: extendable_work_through => extend the lock pttl and exit
            sp_conflict_status = :extendable_conflict_work_through
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
            queue_ttl, acquier_id, host_id, access_strategy, sp_conflict_status
          )
        end

        # SP-Conflict-Step X2: switch to conflict-based logic or not
        if sp_conflict_status == :extendable_conflict_work_through
          # SP-Conflict-Step FINAL (SPCF): extend the lock and work through
          #   - extend the lock ttl;
          #   - store extensions in lock metadata;
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
            'l_spc_ext_ts', (spc_processed_timestamp = Time.now.to_f),
            'l_spc_ext_ini_ttl', ttl
          )
          inter_result = :extendable_conflict_work_through

          LogVisitor.reentrant_lock__extend_and_work_through(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquier_id, host_id, access_strategy,
            sp_conflict_status, ttl, spc_processed_timestamp
          )
        # SP-Conflict-Step X2: switch to dead lock logic or not
        elsif sp_conflict_status == :conflict_work_through
          inter_result = :conflict_work_through

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
            'l_spc_ts', (spc_processed_timestamp = Time.now.to_f)
          )

          LogVisitor.reentrant_lock__work_through(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquier_id, host_id, access_strategy,
            sp_conflict_status, spc_processed_timestamp
          )
        # SP-Conflict-Step X2: switch to dead lock logic or not
        elsif sp_conflict_status == :conflict_dead_lock
          inter_result = :conflict_dead_lock
          spc_processed_timestamp = Time.now.to_f

          LogVisitor.single_process_lock_conflict__dead_lock(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquier_id, host_id, access_strategy,
            sp_conflict_status, spc_processed_timestamp
          )
        # Reached the SP-Non-Conflict Mode (NOTE):
        #   - in other sp-conflict cases we are in <wait_for_lock> (non-conflict) status and should
        #     continue to work in classic way (next lines of code):
        elsif fail_fast && current_lock_obtainer != nil # Fast-Step X0: fail-fast check
          # Fast-Step X1: lock is already obtained. fail fast leads to "no try".
          inter_result = :fail_fast_no_try
        else
          # Step 1: add an acquier to the lock acquirement queue
          rconn.call('ZADD', lock_key_queue, 'NX', acquier_position, acquier_id)

          LogVisitor.acq_added_to_queue(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquier_id, host_id, access_strategy
          )

          # Step 2.1: drop expired acquiers from the lock queue
          rconn.call(
            'ZREMRANGEBYSCORE',
            lock_key_queue,
            '-inf',
            RedisQueuedLocks::Resource.acquier_dead_score(queue_ttl)
          )

          LogVisitor.remove_expired_acqs(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquier_id, host_id, access_strategy
          )

          # Step 3: get the actual acquier waiting in the queue
          waiting_acquier = Array(rconn.call('ZRANGE', lock_key_queue, '0', '0')).first

          LogVisitor.get_first_from_queue(
            logger, log_sampled, log_lock_try, lock_key,
            queue_ttl, acquier_id, host_id, access_strategy, waiting_acquier
          )

          # Step PRE-4.x: check if the request time limit is reached
          #   (when the current try self-removes itself from queue (queue ttl has come))
          if waiting_acquier == nil
            LogVisitor.exit__queue_ttl_reached(
              logger, log_sampled, log_lock_try, lock_key,
              queue_ttl, acquier_id, host_id, access_strategy
            )

            inter_result = :dead_score_reached
            # Step STRATEGY: check the stragegy and corresponding preventing factor
            # Step STRATEGY (queued): check the actual acquier: is it ours? are we aready to lock?
          elsif access_strategy == :queued && waiting_acquier != acquier_id
            # Step ROLLBACK 1.1: our time hasn't come yet. retry!
            LogVisitor.exit__no_first(
              logger, log_sampled, log_lock_try, lock_key,
              queue_ttl, acquier_id, host_id, access_strategy, waiting_acquier,
              rconn.call('HGETALL', lock_key).to_h
            )
            inter_result = :acquier_is_not_first_in_queue
            # Step STRAGEY: successfull (:queued OR :random)
          elsif (access_strategy == :queued && waiting_acquier == acquier_id) ||
                (access_strategy == :random)
            # NOTE: our time has come! let's try to acquire the lock!

            # Step 5: find the lock -> check if the our lock is already acquired
            locked_by_acquier = rconn.call('HGET', lock_key, 'acq_id')

            if locked_by_acquier
              # Step ROLLBACK 2: required lock is stil acquired. retry!

              LogVisitor.exit__lock_still_obtained(
                logger, log_sampled, log_lock_try, lock_key,
                queue_ttl, acquier_id, host_id, access_strategy,
                waiting_acquier, locked_by_acquier,
                rconn.call('HGETALL', lock_key).to_h
              )
              inter_result = :lock_is_still_acquired
            else
              # NOTE: required lock is free and ready to be acquired! acquire!

              # Step 6.1: remove our acquier from waiting queue
              transact.call('ZREM', lock_key_queue, acquier_id)

              # Step 6.2: acquire a lock and store an info about the acquier and host
              transact.call(
                'HSET',
                lock_key,
                'acq_id', acquier_id,
                'hst_id', host_id,
                'ts', (timestamp = Time.now.to_f),
                'ini_ttl', ttl,
                *(meta.to_a if meta != nil)
              )

              # Step 6.3: set the lock expiration time in order to prevent "infinite locks"
              transact.call('PEXPIRE', lock_key, ttl) # NOTE: in milliseconds

              LogVisitor.obtain__free_to_acquire(
                logger, log_sampled, log_lock_try, lock_key,
                queue_ttl, acquier_id, host_id, access_strategy
              )
            end
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
      if result.is_a?(::Array) && result.size == 4 # NOTE: four commands should be processed
        # TODO:
        #   => (!) analyze the command result and do actions with the depending on it
        #   1. EVAL (extend lock pttl) (OK for != nil)
        #   2. HINCRBY (ttl extension) (OK for != nil)
        #   3. HINCRBY (increased spc count) (OK for != nil)
        #   4. HSET (store the last spc time and ttl data) (OK for == 2 or != nil)
        if result[0] != nil && result[1] != nil && result[2] != nil && result[3] != nil
          RedisQueuedLocks::Data[ok: true, result: {
            process: :extendable_conflict_work_through,
            lock_key: lock_key,
            acq_id: acquier_id,
            hst_id: host_id,
            ts: spc_processed_timestamp,
            ttl: ttl
          }]
        elsif result[0] != nil
          # NOTE: that is enough to the fact that the lock is extended but <TODO>
          # TODO: add detalized overview (log? some in-line code clarifications?) of the result
          RedisQueuedLocks::Data[ok: true, result: {
            process: :extendable_conflict_work_through,
            lock_key: lock_key,
            acq_id: acquier_id,
            hst_id: host_id,
            ts: spc_processed_timestamp,
            ttl: ttl
          }]
        else
          # NOTE: unknown behaviour :thinking:
          RedisQueuedLocks::Data[ok: false, result: :unknown]
        end
      elsif result == nil || (result.is_a?(::Array) && result.empty?)
        # NOTE: the lock key was changed durign an SPC logic execution
        RedisQueuedLocks::Data[ok: false, result: :lock_is_acquired_during_acquire_race]
      else
        # NOTE: unknown behaviour :thinking:. this part is not reachable at the moment.
        RedisQueuedLocks::Data[ok: false, result: :unknown]
      end
    when inter_result == :conflict_work_through
      # Step 7.same_process_conflict.B:
      #   - conflict_work_through case => yield <block> without lock realesing/extending
      RedisQueuedLocks::Data[ok: true, result: {
        process: :conflict_work_through,
        lock_key: lock_key,
        acq_id: acquier_id,
        hst_id: host_id,
        ts: spc_processed_timestamp,
        ttl: ttl
      }]
    when inter_result == :conflict_dead_lock
      # Step 7.same_process_conflict.C:
      #  - deadlock. should fail in acquirement logic;
      RedisQueuedLocks::Data[ok: false, result: inter_result]
    when fail_fast && inter_result == :fail_fast_no_try
      # Step 7.a: lock is still acquired and we should exit from the logic as soon as possible
      RedisQueuedLocks::Data[ok: false, result: inter_result]
    when inter_result == :dead_score_reached
      RedisQueuedLocks::Data[ok: false, result: inter_result]
    when inter_result == :lock_is_still_acquired || inter_result == :acquier_is_not_first_in_queue
      # Step 7.b: lock is still acquired by another process => failed to acquire
      RedisQueuedLocks::Data[ok: false, result: inter_result]
    when result == nil || (result.is_a?(::Array) && result.empty?)
      # Step 7.c: lock is already acquired durign the acquire race => failed to acquire
      RedisQueuedLocks::Data[ok: false, result: :lock_is_acquired_during_acquire_race]
    when result.is_a?(::Array) && result.size == 3 # NOTE: 3 is a count of redis lock commands
      # TODO:
      #   => (!) analyze the command result and do actions with the depending on it;
      #   => (*) at this moment we accept that all comamnds are completed successfully;
      #   => (!) need to analyze:
      #   1. zrem shoud return ? (?)
      #   2. hset should return 3 as minimum
      #      (lock key is added to the redis as a hashmap with 3 fields as minimum)
      #   3. pexpire should return 1 (expiration time is successfully applied)

      # Step 7.d: locked! :) let's go! => successfully acquired
      RedisQueuedLocks::Data[ok: true, result: {
        process: :lock_obtaining,
        lock_key: lock_key,
        acq_id: acquier_id,
        hst_id: host_id,
        ts: timestamp,
        ttl: ttl
      }]
    else
      # Ste 7.3: unknown behaviour :thinking:
      RedisQueuedLocks::Data[ok: false, result: :unknown]
    end
    # rubocop:enable Lint/DuplicateBranch
  end
  # rubocop:enable Metrics/MethodLength, Metrics/PerceivedComplexity
end
# rubocop:enable Metrics/ModuleLength
