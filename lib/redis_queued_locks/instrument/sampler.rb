# frozen_string_literal: true

# @api public
# @since 1.6.0
# @version 1.21.0
module RedisQueuedLocks::Instrument::Sampler
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
    # @version 1.21.0
    def sampling_happened?(sampling_percent)
      # NOTE: one of 100 equally probable values (0..99): `sampling_percent` of them are lower
      #   (0% => never, 100% => always);
      SecureRandom.rand(100) < sampling_percent
    end
  end
end
