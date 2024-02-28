# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Acquier::Try
  # @param redis [RedisClient]
  # @param lock_key [String]
  # @param lock_key_queue [String]
  # @param acquier_id [String]
  # @param acquier_position [Numeric]
  # @param ttl [Integer]
  # @param queue_ttl [Integer]
  # @param fail_fast [Boolean]
  # @return [Hash<Symbol,Any>] Format: { ok: true/false, result: Symbol|Hash<Symbol,Any> }
  #
  # @api private
  # @since 0.1.0
  # rubocop:disable Metrics/MethodLength
  def try_to_lock(
    redis,
    lock_key,
    lock_key_queue,
    acquier_id,
    acquier_position,
    ttl,
    queue_ttl,
    fail_fast
  )
    # Step X: intermediate invocation results
    inter_result = nil
    timestamp = nil

    # Step 0: watch the lock key changes (and discard acquirement if lock is already acquired)
    result = redis.multi(watch: [lock_key]) do |transact|
      # Fast-Step X0: fail-fast check
      if fail_fast && redis.call('HGET', lock_key, 'acq_id')
        # Fast-Step X1: is lock already obtained. fail fast - no try.
        inter_result = :fail_fast_no_try
      else
        # Step 1: add an acquier to the lock acquirement queue
        res = redis.call('ZADD', lock_key_queue, 'NX', acquier_position, acquier_id)

        RedisQueuedLocks.debug(
          "Step №1: добавление в очередь (#{acquier_id}). [ZADD to the queue: #{res}]"
        )

        # Step 2.1: drop expired acquiers from the lock queue
        res = redis.call(
          'ZREMRANGEBYSCORE',
          lock_key_queue,
          '-inf',
          RedisQueuedLocks::Resource.acquier_dead_score(queue_ttl)
        )

        RedisQueuedLocks.debug(
          "Step №2: дропаем из очереди просроченных ожидающих. [ZREMRANGE: #{res}]"
        )

        # Step 3: get the actual acquier waiting in the queue
        waiting_acquier = Array(redis.call('ZRANGE', lock_key_queue, '0', '0')).first

        RedisQueuedLocks.debug(
          "Step №3: какой процесс в очереди сейчас ждет. " \
          "[ZRANGE <следующий процесс>: #{waiting_acquier} :: <текущий процесс>: #{acquier_id}]"
        )

        # Step 4: check the actual acquier: is it ours? are we aready to lock?
        unless waiting_acquier == acquier_id
          # Step ROLLBACK 1.1: our time hasn't come yet. retry!

          RedisQueuedLocks.debug(
            "Step ROLLBACK №1: не одинаковые ключи. выходим. " \
            "[Ждет: #{waiting_acquier}. А нужен: #{acquier_id}]"
          )

          inter_result = :acquier_is_not_first_in_queue
        else
          # NOTE: our time has come! let's try to acquire the lock!

          # Step 5: check if the our lock is already acquired
          locked_by_acquier = redis.call('HGET', lock_key, 'acq_id')

          RedisQueuedLocks.debug(
            "Ste №5: Ищем требуемый лок. " \
            "[HGET<#{lock_key}>: " \
            "#{(locked_by_acquier == nil) ? 'не занят' : "занят процессом <#{locked_by_acquier}>"}"
          )

          if locked_by_acquier
            # Step ROLLBACK 2: required lock is stil acquired. retry!

            RedisQueuedLocks.debug(
              "Step ROLLBACK №2: Ключ уже занят. Ничего не делаем. " \
              "[Занят процессом: #{locked_by_acquier}]"
            )

            inter_result = :lock_is_still_acquired
          else
            # NOTE: required lock is free and ready to be acquired! acquire!

            # Step 6.1: remove our acquier from waiting queue
            transact.call('ZPOPMIN', lock_key_queue, '1')

            RedisQueuedLocks.debug(
              'Step №4: Забираем наш текущий процесс из очереди. [ZPOPMIN]'
            )

            RedisQueuedLocks.debug(
              "===> <FINAL> Step №6: закрепляем лок за процессом [HSET<#{lock_key}>: #{acquier_id}]"
            )

            # Step 6.2: acquire a lock and store an info about the acquier
            transact.call(
              'HSET',
              lock_key,
              'acq_id', acquier_id,
              'ts', (timestamp = Time.now.to_i),
              'ini_ttl', ttl
            )

            # Step 6.3: set the lock expiration time in order to prevent "infinite locks"
            transact.call('PEXPIRE', lock_key, ttl) # NOTE: in milliseconds
          end
        end
      end
    end

    # Step 7: Analyze the aquirement attempt:
    # rubocop:disable Lint/DuplicateBranch
    case
    when fail_fast && inter_result == :fail_fast_no_try
      # Step 7.a: lock is still acquired and we should exit from the logic as soon as possible
      { ok: false, result: inter_result }
    when inter_result == :lock_is_still_acquired || inter_result == :acquier_is_not_first_in_queue
      # Step 7.b: lock is still acquired by another process => failed to acquire
      { ok: false, result: inter_result }
    when result == nil || (result.is_a?(::Array) && result.empty?)
      # Step 7.c: lock is already acquired durign the acquire race => failed to acquire
      { ok: false, result: :lock_is_acquired_during_acquire_race }
    when result.is_a?(::Array) && result.size == 3 # NOTE: 3 is a count of redis lock commands
      # TODO:
      #   => (!) analyze the command result and do actions with the depending on it;
      #   => (*) at this moment we accept that all comamnds are completed successfully;
      #   => (!) need to analyze:
      #   1. zpopmin should return our process (array with <acq_id> and <score>)
      #   2. hset should return 2 (lock key is added to the redis as a hashmap with 2 fields)
      #   3. pexpire should return 1 (expiration time is successfully applied)

      # Step 7.d: locked! :) let's go! => successfully acquired
      { ok: true, result: { lock_key: lock_key, acq_id: acquier_id, ts: timestamp, ttl: ttl } }
    else
      # Ste 7.3: unknown behaviour :thinking:
      { ok: false, result: :unknown }
    end
    # rubocop:enable Lint/DuplicateBranch
  end
  # rubocop:enable Metrics/MethodLength, Metrics/PerceivedComplexity

  # @param redis [RedisClient]
  # @param lock_key_queue [String]
  # @param acquier_id [String]
  # @return [Hash<Symbol,Any>] Format: { ok: true/false, result: Any }
  #
  # @api private
  # @since 0.1.0
  def dequeue_from_lock_queue(redis, lock_key_queue, acquier_id)
    result = redis.call('ZREM', lock_key_queue, acquier_id)

    RedisQueuedLocks.debug(
      "Step ~ [СМЕРТЬ ПРОЦЕССА]: [#{acquier_id} :: #{lock_key_queue}] РЕЗУЛЬТАТ: #{result}"
    )

    { ok: true, result: result }
  end
end
