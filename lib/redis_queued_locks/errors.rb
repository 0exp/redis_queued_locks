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
  LockAlreadyObtainedError = Class.new(Error)

  # @api public
  # @since 0.1.0
  LockAcquiermentTimeoutError = Class.new(Error)

  # @api public
  # @since 0.1.0
  LockAcquiermentRetryLimitError = Class.new(Error)

  # @api pulic
  # @since 0.1.0
  TimedLockTimeoutError = Class.new(Error)
end
