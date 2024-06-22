# frozen_string_literal: true

# @api private
# @since 1.0.0
module RedisQueuedLocks::Utilities
  require_relative 'utilities/lock'

  module_function

  # Ractor class has no methods for Ractor object status identification.
  # The only one approach (without C/FFI extending) to give the status is to check
  # the status from the `#inspect/#to_s` methods. String representation has the following format:
  #   Format: "#<Ractor:##{id}#{name ? ' '+name : ''}#{loc ? " " + loc : ''} #{status}>"
  #   Example: #<Ractor:#2 (irb):2 terminated>
  # So we need to parse the `status` part of the inspect method and use it for our logic.
  # Current regexp object provides the pattern for this.
  #
  # @return [Regexp]
  #
  # @api private
  # @since 1.9.0
  RACTOR_LIVENESS_PATTERN = /\A.*?(created|running|blocking).*?\z/i

  # Ractor status as a string extracted from the object string representation.
  # This way is used cuz the ractor class has no any detailed status extraction API.
  #
  # @return [Regexp]
  #
  # @api private
  # @since 1.9.0
  RACTOR_STATUS_PATTERN = /\A.*?\s(?<status>\w+)>\z/i

  # @param block [Block]
  # @return [Any]
  #
  # @api private
  # @since 1.0.0
  def run_non_critical(&block)
    yield rescue nil
  end

  # @param ractor [Ractor]
  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def ractor_alive?(ractor)
    ractor.to_s.match?(RACTOR_LIVENESS_PATTERN)
  end

  # @param ractor [Ractor]
  # @return [String]
  #
  # @api private
  # @since 1.9.0
  def ractor_status(ractor)
    ractor.to_s.match(RACTOR_STATUS_PATTERN)[:status]
  end

  # Returns the status of the passed thread object.
  # Possible thread statuses:
  #   - "run" (thread is executing);
  #   - "sleep" (thread is sleeping or waiting on I/O);
  #   - "aborting" (thread is aborting)
  #   - "dead" (thread is terminated normally);
  #   - "failed" (thread is terminated with an exception);
  # See Thread#status official documentation.
  #
  # @param [Thread]
  # @return [String]
  #
  # @api private
  # @since 1.9.0
  def thread_state(thread)
    status = thread.status

    case
    when status == false
      'dead'
    when status == nil
      'failed'
    else
      status
    end
  end
end
