# frozen_string_literal: true

module RedisQueuedLocks
  # @api public
  # @since 0.1.0
  Error = Class.new(::StandardError)

  # @api public
  # @since 0.1.0
  ArgumentError = Class.new(::ArgumentError)

  # @api public
  # @since 0.1.0
  LockAcquiermentTimeoutError = Class.new(Error)

  # @api public
  # @since 0.1.0
  LockAcquiermentLimitError = Class.new(Error)
end
