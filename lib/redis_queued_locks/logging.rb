# frozen_string_literal: true

# @api public
# @since 0.1.0
module RedisQueuedLocks::Logging
  require_relative 'logging/void_logger'

  class << self
    # @param logger [::Logger,#debug]
    # @return [Boolean]
    #
    # @api public
    # @since 0.1.0
    def valid_interface?(logger)
      return true if logger.is_a?(::Logger)

      # NOTE: should provide `#debug` method.
      return false unless logger.respond_to?(:debug)

      # NOTE:
      #   `#debug` method should have appropriated signature `(progname, &block)`
      #   Required method signature (progname, &block):
      #     => [[:opt, :progname], [:block, :block]]
      #     => [[:req, :progname], [:block, :block]]
      #     => [[:opt, :progname]]
      #     => [[:req, :progname]]
      #     => [[:rest], [:block, :block]]
      #     => [[:rest]]

      m_obj = logger.method(:debug)
      m_sig = m_obj.parameters

      if m_sig.size == 2
        # => [[:opt, :progname], [:block, :block]]
        # => [[:req, :progname], [:block, :block]]
        # => [[:rest], [:block, :block]]
        f_prm = m_sig[0][0]
        s_prm = m_sig[1][0]

        # rubocop:disable Layout/MultilineOperationIndentation
        f_prm == :opt && s_prm == :block ||
        f_prm == :req && s_prm == :block ||
        f_prm == :rest && s_prm == :block
        # rubocop:enable Layout/MultilineOperationIndentation
      elsif m_sig.size == 1
        # => [[:opt, :progname]]
        # => [[:req, :progname]]
        # => [[:rest]]
        prm = m_sig[0][0]

        prm == :opt || prm == :req || prm == :rest
      else
        false
      end
    end
  end
end
