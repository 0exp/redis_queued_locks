# frozen_string_literal: true

# @api private
# @since 1.18.0
module RedisQueuedLocks::Acquirer::ReleaseReadLock
  # @since 1.18.0
  extend RedisQueuedLocks::Utilities

  class << self
    # Release the read lock of the concrete acquirer (other read locks, the write lock and
    # lock requests are not affected): drop the acquirer from the readers registry and drop
    # its read lock data.
    #
    # @param redis [RedisClient]
    #   Redis connection client.
    # @param lock_name [String]
    #   The lock name whose read lock should be released.
    # @param acquirer_id [String]
    #   The read lock acquirer.
    # @param instrumenter [#notify]
    #   See RedisQueuedLocks::Instrument::ActiveSupport for example.
    # @param logger [::Logger,#debug]
    #   - Logger object used from `configuration` layer (see config['logger']);
    #   - See RedisQueuedLocks::Logging::VoidLogger for example;
    # @param instrument [NilClass,Any]
    #   - Custom instrumentation data wich will be passed to the instrumenter's payload
    #     with :instrument key;
    # @param log_sampling_enabled [Boolean]
    # @param log_sampling_percent [Integer]
    # @param log_sampler [#sampling_happened?,Module<RedisQueuedLocks::Logging::Sampler>]
    # @param log_sample_this [Boolean]
    # @param instr_sampling_enabled [Boolean]
    #   - enables <instrumentaion sampling>: only the configured percent
    #     of RQL cases will be instrumented;
    # @param instr_sampling_percent [Integer]
    #   - the percent of cases that should be instrumented;
    # @param instr_sampler [#sampling_happened?,Module<RedisQueuedLocks::Instrument::Sampler>]
    #   - percent-based sampler that decides should be RQL case instrumented or not;
    # @param instr_sample_this [Boolean]
    #   - marks the method that everything should be instrumneted
    #     despite the enabled instrumentation sampling;
    # @return [Hash<Symbol,Boolean<Hash<Symbol,Numeric|String|Symbol>>]
    #   Format: {
    #     ok: true,
    #     result: {
    #       rel_time: Numeric, # <milliseconds>
    #       rel_key: String, # lock key
    #       rel_acq_id: String, # read lock acquirer
    #       lock_res: Symbol # :released or :nothing_to_release
    #     }
    #   }
    #
    # @api private
    # @since 1.18.0
    # rubocop:disable Metrics/MethodLength
    def release_read_lock(
      redis,
      lock_name,
      acquirer_id,
      instrumenter,
      logger,
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
      lock_key = RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
      lock_readers_key = RedisQueuedLocks::Resource.prepare_lock_readers(lock_name)
      read_lock_key = RedisQueuedLocks::Resource.prepare_read_lock_key(lock_name, acquirer_id)

      rel_start_time = clock_gettime
      # steep:ignore:start
      fully_release_read_lock(
        redis, lock_readers_key, read_lock_key, acquirer_id
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
        instrumenter.notify('redis_queued_locks.explicit_read_lock_release', {
          lock_key: lock_key,
          acq_id: acquirer_id,
          lock_res: result[:lock],
          rel_time: rel_time,
          at: time_at,
          instrument: instrument
        })
      end if instr_sampled

      {
        ok: true,
        result: {
          rel_time: rel_time,
          rel_key: lock_key,
          rel_acq_id: acquirer_id,
          lock_res: result[:lock]
        }
      }
    end
    # rubocop:enable Metrics/MethodLength

    private

    # @param redis [RedisClient]
    # @param lock_readers_key [String]
    # @param read_lock_key [String]
    # @param acquirer_id [String]
    # @return [Hash<Symbol,Boolean|Hash<Symbol,Symbol>>]
    #   Format: { ok: true, result: { lock: :released/:nothing_to_release } }
    #
    # @api private
    # @since 1.18.0
    def fully_release_read_lock(redis, lock_readers_key, read_lock_key, acquirer_id)
      # @type var result: [Integer,Integer]
      result = redis.with do |rconn|
        rconn.multi do |transact|
          transact.call('ZREM', lock_readers_key, acquirer_id)
          transact.call('DEL', read_lock_key)
        end
      end

      { ok: true, result: { lock: (result[0] != 0) ? :released : :nothing_to_release } }
    end
  end
end
