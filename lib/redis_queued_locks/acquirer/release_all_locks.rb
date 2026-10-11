# frozen_string_literal: true

# @api private
# @since 1.0.0
# @version 1.20.0
module RedisQueuedLocks::Acquirer::ReleaseAllLocks
  # @since 1.0.0
  extend RedisQueuedLocks::Utilities

  class << self
    # Release all locks: delete the keys of all lock families (write locks, lock queues,
    # readers registries, read lock queues and read lock data) of the locks of the lock index
    # (one ZSCAN pass) and drop their lock names from the lock index, with one transaction
    # (`DEL` + `ZREM`) per batch of lock names.
    #
    # @param redis [RedisClient]
    #   Redis connection client.
    # @param batch_size [Integer]
    #   The number of locks (lock names) that should be released in a time.
    # @param logger [::Logger,#debug]
    #   - Logger object used from `configuration` layer (see config['logger']);
    #   - See RedisQueuedLocks::Logging::VoidLogger for example;
    # @param instrumenter [#notify]
    #   See RedisQueuedLocks::Instrument::ActiveSupport for example.
    # @param instrument [NilClass,Any]
    #    - Custom instrumentation data wich will be passed to the instrumenter's payload
    #      with :instrument key;
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
    # @return [Hash<Symbol,Any>]
    #   Format: { ok: true, result: Hash<Symbol,Numeric> }
    #
    # @api private
    # @since 1.0.0
    # @version 1.20.0
    def release_all_locks(
      redis,
      batch_size,
      logger,
      instrumenter,
      instrument,
      log_sampling_enabled,
      log_sampling_percent,
      log_sampler,
      log_sample_this,
      instr_sampling_enabled,
      instr_sampling_percent,
      instr_sampler,
      instr_sample_this
    )
      rel_start_time = clock_gettime
      fully_release_all_locks(redis, batch_size) => { ok:, result: } # steep:ignore

      # @type var ok: bool
      # @type var result: Hash[Symbol,Integer]

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
        instrumenter.notify('redis_queued_locks.explicit_all_locks_release', {
          at: time_at,
          rel_time: rel_time,
          rel_key_cnt: result[:rel_key_cnt]
        })
      end if instr_sampled

      {
        ok: true,
        result: { rel_key_cnt: result[:rel_key_cnt], rel_time: rel_time }
      }
    end

    private

    # Release all locks: one ZSCAN pass over the lock index (`LOCK_INDEX_KEY`: lock names, the
    # keyspace is never scanned); the keys of all lock families of each batch of `batch_size` lock
    # names are deleted with one `DEL` in one transaction with the `ZREM` of the lock names from
    # the lock index (two round trips per batch: the read lock acquirers, then the transaction).
    #   - expired lock names are dropped from the lock index first (all their keys are expired);
    #   - lock names of the lock requests queued (or the locks obtained) after the transaction of
    #     their batch are indexed again by the lock acquirement;
    #
    # @param redis [RedisClient]
    # @param batch_size [Integer] ZSCAN count and the number of lock names in one transaction.
    # @return [Hash<Symbol,Boolean|Hash<Symbol,Integer>>]
    #   - Exmaple: { ok: true, result: { rel_key_cnt: 12345 } }
    #
    # @api private
    # @since 1.0.0
    # @version 1.20.0
    def fully_release_all_locks(redis, batch_size)
      rel_key_cnt = 0

      redis.with do |rconn|
        # Step 1: drop the expired lock names from the lock index (all their keys are expired)
        rconn.call(
          'ZREMRANGEBYSCORE', RedisQueuedLocks::Resource::LOCK_INDEX_KEY,
          '-inf', RedisQueuedLocks::Resource.lock_index_time - 1
        )

        # Step 2: release the locks of the lock index in batches of lock names
        each_lock_name_batch(rconn, batch_size) do |lock_names|
          rel_key_cnt += release_locks(rconn, lock_names)
        end
      end

      { ok: true, result: { rel_key_cnt: } }
    end

    # Releases the locks of the given batch of lock names: deletes all their keys and drops
    # the lock names from the lock index in one transaction.
    #   - (RW) read lock data keys are found via the readers registries (one more round trip
    #     before the transaction); the data of a read lock obtained between the registry read and
    #     the transaction stays till its ttl (the read lock itself is released with the registry);
    #
    # @param redis_client [RedisClient]
    # @param lock_names [Array<String>]
    # @return [Integer] The number of the deleted keys.
    #
    # @api private
    # @since 1.20.0
    def release_locks(redis_client, lock_names)
      # Step A: (RW) read lock acquirers of the readers registries (their read lock data keys)
      # NOTE: (pipeline layout) one reply per lock name in the batch order
      # @type var read_lock_acquirers: Array[Array[String]]
      read_lock_acquirers = redis_client.pipelined do |pipeline|
        lock_names.each do |lock_name|
          pipeline.call(
            'ZRANGE', RedisQueuedLocks::Resource.prepare_lock_readers(lock_name), '0', '-1'
          )
        end
      end

      # @type var lock_keys: Array[String]
      lock_keys = []
      lock_names.each_with_index do |lock_name, index|
        lock_keys << RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
        lock_keys << RedisQueuedLocks::Resource.prepare_lock_queue(lock_name)
        lock_keys << RedisQueuedLocks::Resource.prepare_lock_readers(lock_name)
        lock_keys << RedisQueuedLocks::Resource.prepare_read_lock_queue(lock_name)
        read_lock_acquirers[index].each do |acquirer_id|
          lock_keys << RedisQueuedLocks::Resource.prepare_read_lock_key(lock_name, acquirer_id)
        end
      end

      # Step B: delete the keys and drop the lock names from the lock index in one transaction
      #   (a lock obtained after the transaction indexes its lock name again);
      # NOTE: (transaction layout) [0] DEL (the number of the deleted keys), [1] ZREM (not read)
      # @type var released: [Integer, Integer]
      released = redis_client.multi do |transact|
        transact.call('DEL', *lock_keys)
        transact.call('ZREM', RedisQueuedLocks::Resource::LOCK_INDEX_KEY, *lock_names)
      end
      released[0]
    end

    # Iterates over the lock names of the lock index (one ZSCAN pass) in batches of `scan_size`
    # lock names (batches are collected across ZSCAN pages). Expired lock names (not dropped from
    # the index yet) are skipped: all their keys are expired.
    #
    # NOTE: each operation module iterates over the lock index by itself (duplicated on purpose:
    #   operation modules are independent of each other, see `Locks.each_lock_name_batch`);
    #
    # @param redis_client [RedisClient]
    # @param scan_size [Integer] ZSCAN count and the number of lock names in one batch.
    # @yield [lock_names]
    # @yieldparam lock_names [Array<String>] The batch of lock names (reused between batches).
    # @return [void]
    #
    # @api private
    # @since 1.20.0
    def each_lock_name_batch(redis_client, scan_size)
      lock_index_time = RedisQueuedLocks::Resource.lock_index_time
      # @type var lock_names: Array[String]
      lock_names = []

      redis_client.zscan(
        RedisQueuedLocks::Resource::LOCK_INDEX_KEY, count: scan_size
      ) do |lock_name, lock_index_score|
        next if lock_index_score.to_f < lock_index_time

        lock_names << lock_name
        next if lock_names.size < scan_size

        yield(lock_names)
        lock_names.clear
      end

      yield(lock_names) unless lock_names.empty?
    end
  end
end
