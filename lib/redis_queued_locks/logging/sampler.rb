# frozen_string_literal: true

# @api private
# @since 1.5.0
module RedisQueuedLocks::Logging::Sampler
  class << self
    # Super simple probalistic function based on the `weight` of <true>/<false> values.
    # Requires the <percent> parameter as the required percent of <true> values sampled.
    #
    # @param sampling_percent [Integer]
    #   - percent of <true> values in range of 0..100;
    # @return [Boolean]
    #   - <true> for <sampling_percent>% of invocations (and <false> for the rest invocations)
    #
    # @api private
    # @since 1.5.0
    def sampling_happened?(sampling_percent)
      sampling_percent >= SecureRandom.rand(0..100)
    end
  end
end
