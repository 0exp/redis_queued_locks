# frozen_string_literal: true

# @api public
# @since 1.6.0
module RedisQueuedLocks::Instrument::Sampler
  # @return [Range]
  #
  # @api private
  # @since 1.6.0
  SAMPLING_PERCENT_RANGE = (0..100)

  class << self
    # Super simple probalistic function based on the `weight` of <true>/<false> values.
    # Requires the <percent> parameter as the required percent of <true> values sampled.
    #
    # @param sampling_percent [Integer]
    #   - percent of <true> values in range of 0..100;
    # @return [Boolean]
    #   - <true> for <sampling_percent>% of invocations (and <false> for the rest invocations)
    #
    # @api public
    # @since 1.6.0
    def sampling_happened?(sampling_percent)
      sampling_percent >= SecureRandom.rand(SAMPLING_PERCENT_RANGE)
    end
  end
end
