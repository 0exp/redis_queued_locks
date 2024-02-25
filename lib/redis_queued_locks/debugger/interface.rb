# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Debugger::Interface
  # @param message [String]
  # @return [void]
  #
  # @api private
  # @since 0.1.0
  def debug(message)
    RedisQueuedLocks::Debugger.debug(message)
  end

  # @return [void]
  #
  # @api private
  # @since 0.1.0
  def enable_debugger!
    RedisQueuedLocks::Debugger.enable!
  end

  # @return [void]
  #
  # @api private
  # @since 0.1.0
  def disable_debugger!
    RedisQueuedLocks::Debugger.disable!
  end
end
