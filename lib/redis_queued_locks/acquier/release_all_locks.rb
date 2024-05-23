# frozen_string_literal: true

# @api private
# @since 1.0.0
module RedisQueuedLocks::Acquier::ReleaseAllLocks
  # @since 1.0.0
  extend RedisQueuedLocks::Utilities

  class << self
    # Release all locks:
    # - 1. clear all lock queus: drop them all from Redis database by the lock queue pattern;
    # - 2. delete all locks: drop lock keys from Redis by the lock key pattern;
    #
    # @param redis [RedisClient]
    #   Redis connection client.
    # @param batch_size [Integer]
    #   The number of lock keys that should be released in a time.
    # @param logger [::Logger,#debug]
    #   - Logger object used from `configuration` layer (see config[:logger]);
    #   - See RedisQueuedLocks::Logging::VoidLogger for example;
    # @param isntrumenter [#notify]
    #   See RedisQueuedLocks::Instrument::ActiveSupport for example.
    # @param instrument [NilClass,Any]
    #    - Custom instrumentation data wich will be passed to the instrumenter's payload
    #      with :instrument key;
    # @param log_sampling_enabled [Boolean]
    #   - Enables <log sampling>: only the configured percent of cases will be logged;
    #   - Works in tandem with <log_samplng_percent> option;
    # @param log_sampling_percent [Integer]
    #   - The percent of cases that should be logged;
    #   - Take an effect when <log_sampling_enabled> parameter has <true> value
    #     (when log sampling is enabled);
    # @param log_sampler [#sampling_happened?,Module<RedisQueuedLocks::Logging::Sampler>]
    # @return [RedisQueuedLocks::Data,Hash<Symbol,Any>]
    #   Format: { ok: true, result: Hash<Symbol,Numeric> }
    #
    # @api private
    # @since 1.0.0
    # @version 1.5.0
    def release_all_locks(
      redis,
      batch_size,
      logger,
      instrumenter,
      instrument,
      log_sampling_enabled,
      log_sampling_percent,
      log_sampler
    )
      rel_start_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond)
      fully_release_all_locks(redis, batch_size) => { ok:, result: }
      time_at = Time.now.to_f
      rel_end_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond)
      rel_time = ((rel_end_time - rel_start_time) / 1_000).ceil(2)

      run_non_critical do
        instrumenter.notify('redis_queued_locks.explicit_all_locks_release', {
          at: time_at,
          rel_time: rel_time,
          rel_key_cnt: result[:rel_key_cnt]
        })
      end

      RedisQueuedLocks::Data[
        ok: true,
        result: { rel_key_cnt: result[:rel_key_cnt], rel_time: rel_time }
      ]
    end

    private

    # Release all locks: clear all lock queus and expire all locks.
    #
    # @param redis [RedisClient]
    # @param batch_size [Integer]
    # @return [RedisQueuedLocks::Data,Hash<Symbol,Boolean|Hash<Symbol,Integer>>]
    #   - Exmaple: { ok: true, result: { rel_key_cnt: 12345 } }
    #
    # @api private
    # @since 1.0.0
    def fully_release_all_locks(redis, batch_size)
      result = redis.with do |rconn|
        rconn.pipelined do |pipeline|
          # Step A: release all queus and their related locks
          rconn.scan(
            'MATCH',
            RedisQueuedLocks::Resource::LOCK_QUEUE_PATTERN,
            count: batch_size
          ) do |lock_queue|
            # TODO: reduce unnecessary iterations
            pipeline.call('EXPIRE', lock_queue, '0')
          end

          # Step B: release all locks
          rconn.scan(
            'MATCH',
            RedisQueuedLocks::Resource::LOCK_PATTERN,
            count: batch_size
          ) do |lock_key|
            # TODO: reduce unnecessary iterations
            pipeline.call('EXPIRE', lock_key, '0')
          end
        end
      end

      RedisQueuedLocks::Data[ok: true, result: { rel_key_cnt: result.sum }]
    end
  end
end
