# frozen_string_literal: true

# @api private
# @since 1.13.0
module RedisQueuedLocks::Acquirer::ReleaseLocksOf
  class << self
    # @api private
    # @since 1.13.0
    def release(
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
      # NOTE: release by acquirer_id
      if acquirer_id != nil && host_id == nil
        # @type var acquirer_id: String
        # @type var host_id: nil
        result = OfAcquirer.release(
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
        { ok: true, result: }
      # NOTE: release by host_id
      elsif acquirer_id == nil && host_id != nil
        # @type var host_id: String
        # @type var acquirer_id: nil
        result = OfHost.release(
          redis,
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
        { ok: true, result: }
      # NOTE: release by combination of host_id and acquirer_id
      elsif acquirer_id != nil && host_id != nil
        # @type var host_id: String
        # @type var acquirer_id: String
        result = OfCombination.release(
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
        { ok: true, result: }
      else
        # @type var host_id: nil
        # @type var acquirer_id: nil
        raise(
          RedisQueuedLocks::NoLockObtainerForReleaseArgumentError,
          "You must specify at least one lock obtainer: " \
          "eaither acquirer_id or host_id (or both of them)."
        )
      end
    end
  end
end
