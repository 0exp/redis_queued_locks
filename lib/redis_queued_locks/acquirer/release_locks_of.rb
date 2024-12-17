# frozen_string_literal: true

module RedisQueuedLocks::Acquirer::ReleaseLocksOf
  class << self
    def release_locks_of(
      redis,
      acquirer_id,
      host_id,
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

      if acquirer_id != nil && host_id != nil
        remove_locks_of_combination(redis, acquirer_id, host_id, scan_size)
      elsif acuquirer_id != nil && host_id == nil
        remove_locks_of_acquirer(redis, acquirer_id, scan_size)
      elsif acquirer_id == nil && host_id != nil
        remove_locks_of_host(redis, host_id, scan_size)
      else
        raise
      end
    end

    private

    def remove_locks_of_acquirer(redis, acquirer_id, scan_size)
    end

    def remove_locks_of_host(redis, host_id, scan_size)
    end

    def remove_locks_of_combination(redis, acquirer_id, host_id, scan_size)
    end
  end
end
