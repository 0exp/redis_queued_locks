# frozen_string_literal: true

# @api public
# @since 0.1.0
module RedisQueuedLocks::Instrument
  require_relative 'instrument/void_notifier'
  require_relative 'instrument/active_support'

  class << self
    # @param instrumenter [Class,Module,Object]
    # @return [Boolean]
    #
    # @api public
    # @since 0.1.0
    def valid_interface?(instrumenter)
      if instrumenter == RedisQueuedLocks::Instrument::ActiveSupport
        # NOTE: active_support should be required in your app
        defined?(::ActiveSupport::Notifications)
      elsif instrumenter.respond_to?(:notify)
        # NOTE: the method signature should be (event, payload). Supported variants:
        #   => [[:req, :event], [:req, :payload]]
        #   => [[:req, :event], [:opt, :payload]]
        #   => [[:opt, :event], [:opt, :payload]]

        m_obj = instrumenter.method(:notify)
        m_sig = m_obj.parameters

        f_prm = m_sig[0][0]
        s_prm = m_sig[1][0]

        if m_sig.size == 2
          # rubocop:disable Layout/MultilineOperationIndentation
          # NOTE: check the signature vairants
          f_prm == :req && s_prm == :req ||
          f_prm == :req && s_prm == :opt ||
          f_prm == :opt && s_prm == :opt
          # rubocop:enable Layout/MultilineOperationIndentation
        else
          # NOTE: incompatible signature
          false
        end
      else
        # NOTE: no required method :notify
        false
      end
    end
  end
end
