# frozen_string_literal: true

# @api private
# @since 1.0.0
module RedisQueuedLocks::Acquirer::ReleaseLock
  # @since 1.0.0
  extend RedisQueuedLocks::Utilities

  class << self
    # Release the concrete lock:
    # - 1. clear lock queue: al; related processes released
    #      from the lock aquierment and should retry;
    # - 2. delete the lock: drop lock key from Redis;
    # - 3. (RW) clear the read lock queue and drop all read locks (the readers registry);
    # - 4. (lock index) drop the lock name from the lock index;
    # It is safe because the lock obtain logic is transactional and
    # watches the original lock for changes.
    #
    # @param redis [RedisClient]
    #   Redis connection client.
    # @param lock_name [String]
    #   The lock name that should be released.
    # @param instrumenter [#notify]
    #   See RedisQueuedLocks::Instrument::ActiveSupport for example.
    # @param logger [::Logger,#debug]
    #   - Logger object used from `configuration` layer (see config['logger']);
    #   - See RedisQueuedLocks::Logging::VoidLogger for example;
    # @param log_sampling_enabled [Boolean]
    #   - enables <log sampling>: only the configured percent of RQL cases will be logged;
    #   - disabled by default;
    #   - works in tandem with <config['log_sampling_percent']> and <config['log_sampler']>;
    # @param log_sampling_percent [Integer]
    #   - the percent of cases that should be logged;
    #   - take an effect when <config['log_sampling_enalbed']> is true;
    #   - works in tandem with <config['log_sampling_enabled']> and <config['log_sampler']> configs;
    # @param log_sampler [#sampling_happened?,Module<RedisQueuedLocks::Logging::Sampler>]
    #   - percent-based log sampler that decides should be RQL case logged or not;
    #   - works in tandem with <config['log_sampling_enabled']> and
    #     <config['log_sampling_percent']> configs;
    #   - based on the ultra simple percent-based (weight-based) algorithm that uses
    #     SecureRandom.rand method so the algorithm error is ~(0%..13%);
    #   - you can provide your own log sampler with bettter algorithm that should realize
    #     `sampling_happened?(percent) => boolean` interface
    #     (see `RedisQueuedLocks::Logging::Sampler` for example);
    # @param log_sample_this [Boolean]
    #   - marks the method that everything should be logged despite the enabled log sampling;
    #   - makes sense when log sampling is enabled;
    # @param instr_sampling_enabled [Boolean]
    #   - enables <instrumentaion sampling>: only the configured percent
    #     of RQL cases will be instrumented;
    #   - disabled by default;
    #   - works in tandem with <config['instr_sampling_percent']> and <config['instr_sampler']>;
    # @param instr_sampling_percent [Integer]
    #   - the percent of cases that should be instrumented;
    #   - take an effect when <config['instr_sampling_enalbed']> is true;
    #   - works in tandem with <config['instr_sampling_enabled']>
    #     and <config['instr_sampler']> configs;
    # @param instr_sampler [#sampling_happened?,Module<RedisQueuedLocks::Instrument::Sampler>]
    #   - percent-based log sampler that decides should be RQL case instrumented or not;
    #   - works in tandem with <config['instr_sampling_enabled']> and
    #     <config['instr_sampling_percent']> configs;
    #   - based on the ultra simple percent-based (weight-based) algorithm that uses
    #     SecureRandom.rand method so the algorithm error is ~(0%..13%);
    #   - you can provide your own log sampler with bettter algorithm that should realize
    #     `sampling_happened?(percent) => boolean` interface
    #     (see `RedisQueuedLocks::Instrument::Sampler` for example);
    # @param instr_sample_this [Boolean]
    #   - marks the method that everything should be instrumneted
    #     despite the enabled instrumentation sampling;
    #   - makes sense when instrumentation sampling is enabled;
    # @return [Hash<Symbol,Boolean<Hash<Symbol,Numeric|String|Symbol>>]
    #   Format: { ok: true/false, result: Hash<Symbol,Numeric|String|Symbol> }
    #
    # @api private
    # @since 1.0.0
    # @version 1.20.0
    # rubocop:disable Metrics/MethodLength
    def release_lock(
      redis,
      lock_name,
      instrumenter,
      logger,
      log_sampling_enabled,
      log_sampling_percent,
      log_sampler,
      log_sample_this,
      instr_sampling_enabled,
      instr_sampling_percent,
      instr_sampler,
      instr_sample_this
    )
      lock_key = RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
      lock_key_queue = RedisQueuedLocks::Resource.prepare_lock_queue(lock_name)
      read_lock_key_queue = RedisQueuedLocks::Resource.prepare_read_lock_queue(lock_name)
      lock_readers_key = RedisQueuedLocks::Resource.prepare_lock_readers(lock_name)

      rel_start_time = clock_gettime
      # steep:ignore:start
      fully_release_lock(
        redis, lock_name, lock_key, lock_key_queue, read_lock_key_queue, lock_readers_key
      ) => { ok:, result: }
      # steep:ignore:end

      # @type var ok: bool
      # @type var result: Hash[Symbol,Symbol]

      time_at = Time.now.to_f
      rel_end_time = clock_gettime
      rel_time = ((rel_end_time - rel_start_time) / 1_000.0).ceil(2)

      instr_sampled = RedisQueuedLocks::Instrument.should_instrument?(
        instr_sampling_enabled,
        instr_sample_this,
        instr_sampling_percent,
        instr_sampler
      )

      run_non_critical do
        instrumenter.notify('redis_queued_locks.explicit_lock_release', {
          lock_key: lock_key,
          lock_key_queue: lock_key_queue,
          rel_time: rel_time,
          at: time_at
        })
      end if instr_sampled

      {
        ok: true,
        result: {
          rel_time: rel_time,
          rel_key: lock_key,
          rel_queue: lock_key_queue,
          queue_res: result[:queue],
          lock_res: result[:lock]
        }
      }
    end
    # rubocop:enable Metrics/MethodLength

    private

    # Realease the lock: clear the lock queues and expire the lock (write lock and read locks),
    # drop the lock name from the lock index.
    #
    # @param redis [RedisClient]
    # @param lock_name [String]
    # @param lock_key [String]
    # @param lock_key_queue [String]
    # @param read_lock_key_queue [String]
    # @param lock_readers_key [String]
    # @return [Hash<Symbol,Boolean|Hash<Symbol,Symbol>>]
    #   Format: {
    #     ok: true/false,
    #     result: {
    #       queue: :released/:nothing_to_release, # (any of the lock queues)
    #       lock: :released/:nothing_to_release # (write lock or read locks)
    #     }
    #   }
    #
    # @api private
    # @since 1.0.0
    # @version 1.20.0
    # rubocop:disable Metrics/MethodLength
    def fully_release_lock(
      redis,
      lock_name,
      lock_key,
      lock_key_queue,
      read_lock_key_queue,
      lock_readers_key
    )
      # @type var result: [Array[String],Integer,Integer,Integer,Integer,Integer]
      result = redis.with do |rconn|
        # Step 1: release the lock in one transaction (one round trip):
        #   - (RW) the readers registry is read in the same transaction: the snapshot of all
        #     released read locks (their data is dropped in Step 2);
        #   - (lock index) all the indexed keys of the lock are dropped: the lock name is dropped
        #     from the lock index in the same transaction (a lock request queued or a lock obtained
        #     after this transaction indexes the lock name again);
        # NOTE: (transaction layout) replies are read by their positions:
        #   [0] ZRANGE (released read locks), [1] write lock queue, [2] write lock,
        #   [3] read lock queue, [4] readers registry, [5] lock index (not read);
        released = rconn.multi do |transact|
          transact.call('ZRANGE', lock_readers_key, '0', '-1')
          transact.call('ZREMRANGEBYSCORE', lock_key_queue, '-inf', '+inf')
          transact.call('EXPIRE', lock_key, '0')
          transact.call('ZREMRANGEBYSCORE', read_lock_key_queue, '-inf', '+inf')
          transact.call('EXPIRE', lock_readers_key, '0')
          transact.call('ZREM', RedisQueuedLocks::Resource::LOCK_INDEX_KEY, lock_name)
        end

        # Step 2: (RW) drop the data of the released read locks (only when read locks existed)
        # NOTE:
        #   - the read lock data is a data carrier only: read locks are released via the readers
        #     registry (Step 1);
        #   - (trade-off) a reader of the snapshot that obtains a new read lock between Step 1 and
        #     Step 2 loses the data of the new read lock (meta, timestamps); the read lock itself is
        #     not affected (the readers registry is the source of truth);
        # @type var read_lock_acquirers: Array[String]
        read_lock_acquirers = released[0]
        unless read_lock_acquirers.empty?
          rconn.call(
            'DEL',
            *read_lock_acquirers.map do |acquirer_id|
              RedisQueuedLocks::Resource.prepare_read_lock_key(lock_name, acquirer_id)
            end
          )
        end

        released
      end

      {
        ok: true,
        result: {
          queue: (result[1] != 0 || result[3] != 0) ? :released : :nothing_to_release,
          lock: (result[2] != 0 || result[4] != 0) ? :released : :nothing_to_release
        }
      }
    end
    # rubocop:enable Metrics/MethodLength
  end
end
