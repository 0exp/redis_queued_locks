# frozen_string_literal: true

# @api private
# @since 1.13.0
module RedisQueuedLocks::Acquirer::ReleaseLocksOf::OfAcquirer
  # @since 1.13.0
  extend RedisQueuedLocks::Utilities

  class << self
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
    # @return [Hash<Symbol,Float|Integer>]
    #   Format: { rel_time: Float, rel_key_cnt: Integer }
    #
    # @api private
    # @since 1.13.0
    def release(
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

      rel_key_cnt = remove_locks(redis, acquirer_id, scan_size)

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
        instrumenter.notify('redis_queued_locks.release_all_locks_of_acquirer', {
          at: time_at,
          acq_id: acquirer_id,
          rel_time:,
          rel_key_cnt:,
        })
      end if instr_sampled

      { rel_time:, rel_key_cnt: }
    end

    private

    # @param redis [RedisClient]
    # @param acquirer_id [String]
    # @param scan_size [Integer]
    # @return [Integer]
    #
    # @api private
    # @since 1.13.0
    def remove_locks(redis, acquirer_id, scan_size)
      released_keys_count = 0

      redis.with do |rconn|
        locks_to_release = Set.new #: Set[String]

        # TODO: reduce unnecessary iterations (with indexing)
        rconn.scan(
          "MATCH", RedisQueuedLocks::Resource::LOCK_PATTERN, count: scan_size
        ) do |lock_key|
          lock_acquirer_id = rconn.call("HMGET", lock_key, "acq_id")

          if acquirer_id == lock_acquirer_id
            locks_to_release << lock_key
          end

          if locks_to_release.size >= scan_size
            rconn.call("DEL", *locks_to_release) # steep:ignore
            released_keys_count += locks_to_release.size
            locks_to_release.clear
          end
        end

        released_keys_count += locks_to_release.size
        rconn.call("DEL", *locks_to_release) if locks_to_release.any? # steep:ignore
      end

      released_keys_count
    end
  end
end
