# frozen_string_literal: true

# @api private
# @since 1.0.0
# @version 1.5.0
module RedisQueuedLocks::Utilities
  module_function

  # @param block [Block]
  # @return [Any]
  #
  # @api private
  # @since 1.0.0
  def run_non_critical(&block)
    yield rescue nil
  end
end
