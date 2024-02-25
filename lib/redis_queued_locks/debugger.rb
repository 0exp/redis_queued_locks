# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Debugger
  require_relative 'debugger/interface'

  # @return [String]
  #
  # @api private
  # @since 0.1.0
  DEBUG_ENABLED_METHOD = <<~METHOD_DECLARATION.strip.freeze
    def debug(message) = STDOUT.write_nonblock("#\{message}\n")
  METHOD_DECLARATION

  # @return [String]
  #
  # @api private
  # @since 0.1.0
  DEBUG_DISABLED_MEHTOD = <<~METHOD_DECLARATION.strip.freeze
    def debug(message); end
  METHOD_DECLARATION

  class << self
    # @api private
    # @since 0.1.0
    instance_variable_set(:@enabled, false)

    # @return [void]
    #
    # @api private
    # @since 0.1.0
    def enable!
      @enabled = true
      eval(DEBUG_ENABLED_METHOD)
    end

    # @return [void]
    #
    # @api private
    # @since 0.1.0
    def disable!
      @enabled = false
      eval(DEBUG_DISABLED_MEHTOD)
    end

    # @return [Boolean]
    #
    # @api private
    # @since 0.1.0
    def enabled?
      @enabled
    end

    # @param message [String]
    # @return [void]
    #
    # @api private
    # @since 0.1.0
    def debug(message); end
  end
end
