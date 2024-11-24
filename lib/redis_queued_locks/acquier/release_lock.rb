# frozen_string_literal: true

# @api private
# @since 1.0.0
module RedisQueuedLocks::Acquier::ReleaseLock
  # @since 1.0.0
  extend RedisQueuedLocks::Utilities

  class << self
    # Release the concrete lock:
    # - 1. clear lock queue: al; related processes released
    #      from the lock aquierment and should retry;
    # - 2. delete the lock: drop lock key from Redis;
    # It is safe because the lock obtain logic is transactional and
    # watches the original lock for changes.
    #
    # @param redis [RedisClient]
    #   Redis connection client.
    # @param lock_name [String]
    #   The lock name that should be released.
    # @param isntrumenter [#notify]
    #   See RedisQueuedLocks::Instrument::ActiveSupport for example.
    # @param logger [::Logger,#debug]
    #   - Logger object used from `configuration` layer (see config[:logger]);
    #   - See RedisQueuedLocks::Logging::VoidLogger for example;
    # @param log_sampling_enabled [Boolean]
    #   - enables <log sampling>: only the configured percent of RQL cases will be logged;
    #   - disabled by default;
    #   - works in tandem with <config.log_sampling_percent and <log.sampler>;
    # @param log_sampling_percent [Integer]
    #   - the percent of cases that should be logged;
    #   - take an effect when <config.log_sampling_enalbed> is true;
    #   - works in tandem with <config.log_sampling_enabled> and <config.log_sampler> configs;
    # @param log_sampler [#sampling_happened?,Module<RedisQueuedLocks::Logging::Sampler>]
    #   - percent-based log sampler that decides should be RQL case logged or not;
    #   - works in tandem with <config.log_sampling_enabled> and
    #     <config.log_sampling_percent> configs;
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
    #   - works in tandem with <config.instr_sampling_percent and <log.instr_sampler>;
    # @param instr_sampling_percent [Integer]
    #   - the percent of cases that should be instrumented;
    #   - take an effect when <config.instr_sampling_enalbed> is true;
    #   - works in tandem with <config.instr_sampling_enabled> and <config.instr_sampler> configs;
    # @param instr_sampler [#sampling_happened?,Module<RedisQueuedLocks::Instrument::Sampler>]
    #   - percent-based log sampler that decides should be RQL case instrumented or not;
    #   - works in tandem with <config.instr_sampling_enabled> and
    #     <config.instr_sampling_percent> configs;
    #   - based on the ultra simple percent-based (weight-based) algorithm that uses
    #     SecureRandom.rand method so the algorithm error is ~(0%..13%);
    #   - you can provide your own log sampler with bettter algorithm that should realize
    #     `sampling_happened?(percent) => boolean` interface
    #     (see `RedisQueuedLocks::Instrument::Sampler` for example);
    # @param instr_sample_this [Boolean]
    #   - marks the method that everything should be instrumneted
    #     despite the enabled instrumentation sampling;
    #   - makes sense when instrumentation sampling is enabled;
    # @return [RedisQueuedLocks::Data,Hash<Symbol,Boolean<Hash<Symbol,Numeric|String|Symbol>>]
    #   Format: { ok: true/false, result: Hash<Symbol,Numeric|String|Symbol> }
    #
    # @api private
    # @since 1.0.0
    # @version 1.6.0
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

      rel_start_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond)
      fully_release_lock(redis, lock_key, lock_key_queue) => { ok:, result: } # steep:ignore

      # @type var ok: bool
      # @type var result: ::RedisQueuedLocks::Data

      time_at = Time.now.to_f
      rel_end_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond)
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

      # steep:ignore:start
      RedisQueuedLocks::Data[
        ok: true,
        result: {
          rel_time: rel_time,
          rel_key: lock_key,
          rel_queue: lock_key_queue,
          queue_res: result[:queue],
          lock_res: result[:lock]
        }
      ]
      # steep:ignore:end
    end
    # rubocop:enable Metrics/MethodLength

    private

    # Realease the lock: clear the lock queue and expire the lock.
    #
    # @param redis [RedisClient]
    # @param lock_key [String]
    # @param lock_key_queue [String]
    # @return [RedisQueuedLocks::Data,Hash<Symbol,Boolean|Hash<Symbol,Symbol>>]
    #   Format: {
    #     ok: true/false,
    #     result: {
    #       queue: :released/:nothing_to_release,
    #       lock: :released/:nothing_to_release
    #     }
    #   }
    #
    # @api private
    # @since 1.0.0
    def fully_release_lock(redis, lock_key, lock_key_queue)
      result = redis.with do |rconn|
        rconn.multi do |transact|
          transact.call('ZREMRANGEBYSCORE', lock_key_queue, '-inf', '+inf')
          transact.call('EXPIRE', lock_key, '0')
        end
      end

      # @type var result: [::Integer,::Integer]

      # steep:ignore:start
      RedisQueuedLocks::Data[
        ok: true,
        result: {
          queue: (result[0] != 0) ? :released : :nothing_to_release,
          lock: (result[1] != 0) ? :released : :nothing_to_release
        }
      ]
      # steep:ignore:end
    end
  end
end
