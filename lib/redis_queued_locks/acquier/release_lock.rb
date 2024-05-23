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
    #   - The percent of cases that should be logged;
    #   - Sampling algorithm is super simple and works via SecureRandom.rand method
    #     on the base of "weight" algorithm;
    #   - You can provide your own sampler via config[:log_sampler] config and :sampler option
    #     (see `RedisQueuedLocks::Logging::Sampler` for examples);
    #   - The spread of guaranteed percent is approximately +13% (rand method spread);
    #   - Take an effect when <log_sampling_enabled> parameter has <true> value
    #     (when log sampling is enabled);
    # @param log_sampling_percent [Integer]
    #   - The percent of cases that should be logged;
    #   - Take an effect when <log_sampling_enabled> parameter has <true> value
    #     (when log sampling is enabled);
    # @param log_sampler [#sampling_happened?,Module<RedisQueuedLocks::Logging::Sampler>]
    # @return [RedisQueuedLocks::Data,Hash<Symbol,Boolean<Hash<Symbol,Numeric|String|Symbol>>]
    #   Format: { ok: true/false, result: Hash<Symbol,Numeric|String|Symbol> }
    #
    # @api private
    # @since 1.0.0
    # @version 1.5.0
    def release_lock(
      redis,
      lock_name,
      instrumenter,
      logger,
      log_sampling_enabled,
      log_sampling_percent,
      log_sampler
    )
      lock_key = RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
      lock_key_queue = RedisQueuedLocks::Resource.prepare_lock_queue(lock_name)

      rel_start_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond)
      fully_release_lock(redis, lock_key, lock_key_queue) => { ok:, result: }
      time_at = Time.now.to_f
      rel_end_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond)
      rel_time = ((rel_end_time - rel_start_time) / 1_000).ceil(2)

      run_non_critical do
        instrumenter.notify('redis_queued_locks.explicit_lock_release', {
          lock_key: lock_key,
          lock_key_queue: lock_key_queue,
          rel_time: rel_time,
          at: time_at
        })
      end

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
    end

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

      RedisQueuedLocks::Data[
        ok: true,
        result: {
          queue: (result[0] != 0) ? :released : :nothing_to_release,
          lock: (result[1] != 0) ? :released : :nothing_to_release
        }
      ]
    end
  end
end
