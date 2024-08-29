# frozen_string_literal: true

# @api private
# @since 1.9.0
class RedisQueuedLocks::Utilities::Lock
  # @return [void]
  #
  # @api private
  # @since 1.9.0
  # @version 1.13.0
  def initialize
    @lock = ::Monitor.new
  end

  # @param block [Block]
  # @return [Any]
  #
  # @api private
  # @since 1.9.0
  # @version 1.13.0
  def synchronize(&block)
    @lock.synchronize(&block)
  end
end
