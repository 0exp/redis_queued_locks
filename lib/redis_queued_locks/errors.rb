# frozen_string_literal: true

module RedisQueuedLocks
  # @api public
  # @since 1.0.0
  Error = Class.new(::StandardError)

  # @api public
  # @since 1.0.0
  ArgumentError = Class.new(::ArgumentError)

  # @api public
  # @since 1.0.0
  LockAlreadyObtainedError = Class.new(Error)

  # @api public
  # @since 1.0.0
  LockAcquiermentTimeoutError = Class.new(Error)

  # @api public
  # @since 1.0.0
  LockAcquiermentRetryLimitError = Class.new(Error)

  # @api pulic
  # @since 1.0.0
  TimedLockTimeoutError = Class.new(Error)

  # @api public
  # @since 1.3.0
  ConflictLockObtainError = Class.new(Error)

  # @api public
  # @since 1.9.0
  SwarmError = Class.new(Error)

  # @api public
  # @since 1.9.0
  SwarmArgumentError = Class.new(ArgumentError)
end
