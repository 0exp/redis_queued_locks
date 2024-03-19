# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Utilities
  module_function

  # @param block [Block]
  # @return [Any]
  #
  # @api private
  # @since 0.1.0
  def run_non_critical(&block)
    yield rescue nil
  end
end
