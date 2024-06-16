# frozen_string_literal: true

# @api private
# @since 1.0.0
module RedisQueuedLocks::Utilities
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
  RACTOR_LIVENESS_PATTERN = /\A.*?(created|running|blocking).*?\z/

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
end
