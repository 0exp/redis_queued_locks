# frozen_string_literal: true

# @api private
# @since 1.0.0
module RedisQueuedLocks::Acquirer::ReleaseAllLocks
  # @since 1.0.0
  extend RedisQueuedLocks::Utilities

  class << self
    # Release all locks: delete the keys of all lock families (write locks, lock queues,
    # readers registries, read lock queues and read lock data) found in one SCAN pass,
    # with one `DEL` per batch of keys.
    #
    # @param redis [RedisClient]
    #   Redis connection client.
    # @param batch_size [Integer]
    #   The number of lock keys that should be released in a time.
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

    # Release all locks: one SCAN pass over the RQL keys (`KEY_PATTERN`); the keys of all lock
    # families are deleted with one `DEL` per batch of `batch_size` keys (the keys are deleted
    # during the scan: no list of all keys is kept in memory).
    #
    # @param redis [RedisClient]
    # @param batch_size [Integer] SCAN count and the number of keys in one `DEL`.
    # @return [Hash<Symbol,Boolean|Hash<Symbol,Integer>>]
    #   - Exmaple: { ok: true, result: { rel_key_cnt: 12345 } }
    #
    # @api private
    # @since 1.0.0
    # @version 1.20.0
    def fully_release_all_locks(redis, batch_size)
      rel_key_cnt = 0

      redis.with do |rconn|
        # @type var lock_keys: Array[String]
        lock_keys = []

        rconn.scan('MATCH', RedisQueuedLocks::Resource::KEY_PATTERN, count: batch_size) do |key|
          # NOTE: lock families only (KEY_PATTERN matches any `rql:lock*` key)
          next if RedisQueuedLocks::Resource.lock_key_family(key) == nil

          lock_keys << key
          next if lock_keys.size < batch_size

          rel_key_cnt += rconn.call('DEL', *lock_keys)
          lock_keys.clear
        end

        rel_key_cnt += rconn.call('DEL', *lock_keys) unless lock_keys.empty?
      end

      { ok: true, result: { rel_key_cnt: } }
    end
  end
end
