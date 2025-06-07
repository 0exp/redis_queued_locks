# frozen_string_literal: true

# NOTE:
#   the one-line definition style (like "Error = Class.new(::StandardError)")
#   is not used cuz that style can not be correctly defined via RBS types: we can not
#   identify the superclass of our class for a constant;
module RedisQueuedLocks
  # @api public
  # @since 1.0.0
  class Error < ::StandardError; end

  # @api public
  # @since 1.0.0
  class ArgumentError < ::ArgumentError; end

  # @api public
  # @since 1.0.0
  class LockAlreadyObtainedError < Error; end

  # @api private
  # @since 1.11.0
  class LockAcquirementIntermediateTimeoutError < ::Timeout::Error; end

  # @api public
  # @since 1.0.0
  class LockAcquirementTimeoutError < Error; end

  # @api public
  # @since 1.0.0
  class LockAcquirementRetryLimitError < Error; end

  # @api private
  # @since 1.12.0
  class TimedLockIntermediateTimeoutError < ::Timeout::Error; end

  # @api pulic
  # @since 1.0.0
  class TimedLockTimeoutError < Error; end

  # @api public
  # @since 1.3.0
  class ConflictLockObtainError < Error; end

  # @api public
  # @since 1.9.0
  class SwarmError < Error; end

  # @api public
  # @since 1.9.0
  class SwarmArgumentError < ArgumentError; end

  # @api public
  # @since ?.?.?
  class ConfigError < Error; end

  # @api public
  # @since ?.?.?
  class ConfigNotFoundError < ConfigError; end

  # @api pub;ic
  # @since ?.?.?
  class ConfigValidationError < ConfigError; end
end
