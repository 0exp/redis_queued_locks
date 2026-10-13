# frozen_string_literal: true

# NOTE:
#   the one-line definition style (like "Error = Class.new(::StandardError)")
#   is not used cuz that style can not be correctly defined via RBS types: we can not
#   identify the superclass of our class for a constant;
# NOTE: (error hierarchy) each error inherits from the global base error of its branch:
#   - `Error` (`::StandardError`) - the main hierarchy;
#   - `ArgumentError` (`::ArgumentError`) - invalid arguments (the Ruby core branch that can not be
#     a part of the main hierarchy);
#   - `Exception` (`::Exception`) - super exceptional cases only: each error of this branch
#     describes why it is not a `StandardError`;
module RedisQueuedLocks
  # @api public
  # @since 1.0.0
  class Error < ::StandardError; end

  # @api public
  # @since 1.0.0
  class ArgumentError < ::ArgumentError; end

  # The base of the errors that should not be rescued by the code they interrupt
  # (`rescue => e`, `rescue StandardError`, `rescue nil`): like `Timeout::ExitException`,
  # they are rescued only by `rescue Exception` (and by the library itself).
  # NOTE: inside `module RedisQueuedLocks` a bare `Exception` refers to this class;
  #
  # @api private
  # @since 1.21.0
  class Exception < ::Exception; end # rubocop:disable Lint/InheritException

  # @api public
  # @since 1.0.0
  class LockAlreadyObtainedError < Error; end

  # Interrupts the lock acquirement after the `timeout` (`Timeout.timeout`); rescued by
  # `WithAcqTimeout` (=> `LockAcquirementTimeoutError` / `:timeout_reached`).
  # NOTE: (why `Exception`) the acquirement calls the logger and the instrumenter: a `StandardError`
  #   that interrupts them is swallowed by `rescue nil` of the log/instrumentation events, and the
  #   acquirement continues without the timeout (with `retry_count: nil` - without any limit);
  #
  # @api private
  # @since 1.11.0
  # @version 1.21.0
  class LockAcquirementIntermediateTimeoutError < Exception; end

  # @api public
  # @since 1.0.0
  class LockAcquirementTimeoutError < Error; end

  # @api public
  # @since 1.0.0
  class LockAcquirementRetryLimitError < Error; end

  # Interrupts the `timed: true` block after the lock ttl (`Timeout.timeout`); rescued by
  # `YieldExpire` (=> `TimedLockTimeoutError`).
  # NOTE: (why `Exception`) a `StandardError` is swallowed by `rescue => e` / `rescue nil` of
  #   the user block: the block continues after the lock ttl (without the mutual exclusion:
  #   another acquirer can obtain the expired lock, and the write lock release after the block
  #   deletes its lock);
  #
  # @api private
  # @since 1.12.0
  # @version 1.21.0
  class TimedLockIntermediateTimeoutError < Exception; end

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
  # @since 1.13.0
  class ConfigError < Error; end

  # @api public
  # @since 1.13.0
  class ConfigNotFoundError < ConfigError; end

  # @api pub;ic
  # @since 1.13.0
  class ConfigValidationError < ConfigError; end
end
