# frozen_string_literal: true

# @api private
# @sicne 1.13.0
module RedisQueuedLocks::Acquirer::RemoveFromQueues
  # @since 1.13.0
  extend RedisQueuedLocks::Utilities

  class << self
    # Remove acquirer's requests for all lock request queues.
    #
    # @param redis [RedisClient]
    # @param acquirer_id [String]
    # @param scan_size [Integer]
    # @param logger [::Logger,#debug]
    # @param instrumenter [#notify]
    # @param instrument [NilClass,Any]
    # @param log_sampling_enabled [Boolean]
    # @param log_sampling_percent [Integer]
    # @param log_sampler [#sampling_happened?,Module<RedisQueuedLocks::Logging::Sampler>]
    # @param log_sample_this [Boolean]
    # @param instr_sampling_enabled [Boolean]
    # @param instr_sampling_percent [Integer]
    # @param instr_sampler [#sampling_happened?,Module<RedisQueuedLocks::Instrument::Sampler>]
    # @param instr_sample_this [Boolean]
    # @return [Hash<Symbol,Bool|Hash<Symbol,String|Float|Integer>>]
    #   Format: { ok: true, result: { acq_id: String, rel_time: Float, rel_reqs: Integer } }
    #
    # @api private
    # @since 1.13.0
    def remove_from_queues(
      redis,
      acquirer_id,
      scan_size,
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
      rel_start_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond)
      rel_reqs = drop_from_queues(redis, acquirer_id, scan_size)

      time_at = Time.now.to_f
      rel_end_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond)
      rel_time = ((rel_end_time - rel_start_time) / 1_000.0).ceil(2) #: Float

      instr_sampled = RedisQueuedLocks::Instrument.should_instrument?(
        instr_sampling_enabled,
        instr_sample_this,
        instr_sampling_percent,
        instr_sampler
      )

      run_non_critical do
        instrumenter.notify('redis_queued_locks.remove_acquirer_requests_from_queues', {
          at: time_at,
          acq_id: acquirer_id,
          rel_time:,
          rel_reqs:
        })
      end if instr_sampled

      { ok: true, result: { acq_id: acquirer_id, rel_time:, rel_reqs: } }
    end

    private

    # @param redis [RedisClient]
    # @param acquirer_id [String]
    # @param scan_size [Integer]
    # @return [Integer]
    #
    # @api private
    # @since 1.13.0
    def drop_from_queues(redis, acquirer_id, scan_size)
      released_requests = 0

      redis.with do |rconn|
        rconn.scan(
          "MATCH", RedisQueuedLocks::Resource::LOCK_QUEUE_PATTERN, count: scan_size
        ) do |lock_queue|
          released_requests += rconn.call("ZREM", lock_queue, acquirer_id)
        end
      end

      released_requests
    end
  end
end
