# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Acquier::Delay
  # Sleep with random time-shifting (it is necessary for empty-time-slot lock acquirement).
  #
  # @param retry_delay [Integer] In milliseconds
  # @param retry_jitter [Integer] In milliseconds
  # @return [void]
  #
  # @api private
  # @since 0.1.0
  def delay_execution(retry_delay, retry_jitter)
    delay = (retry_delay + rand(retry_jitter)).to_f / 1_000
    sleep(delay)
  end
end
