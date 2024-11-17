# frozen_string_literal: true

# @api public
# @since 1.0.0
# @version 1.6.0
module RedisQueuedLocks::Instrument
  require_relative 'instrument/void_notifier'
  require_relative 'instrument/active_support'
  require_relative 'instrument/sampler'

  class << self
    # @param instr_sampling_enabled [Boolean]
    # @param instr_sample_this [Boolean]
    # @param instr_sampling_percent [Integer]
    # @param instr_sampler [#sampling_happened?,Module<RedisQueuedLocks::Instrument::Sampler>]
    # @return [Boolean]
    #
    # @api private
    # @since 1.6.0
    def should_instrument?(
      instr_sampling_enabled,
      instr_sample_this,
      instr_sampling_percent,
      instr_sampler
    )
      return true unless instr_sampling_enabled
      return true if instr_sample_this
      instr_sampler.sampling_happened?(instr_sampling_percent)
    end

    # @param sampler [#sampling_happened?,Module<RedisQueuedLocks::Instrument::Sampler>]
    # @return [Boolean]
    #
    # @api private
    # @since 1.6.0
    def valid_sampler?(sampler)
      return false unless sampler.respond_to?(:sampling_happened?)

      # @type var m_obj: Method
      m_obj = sampler.method(:sampling_happened?)
      m_sig = m_obj.parameters

      # NOTE:
      #   Required method signature (sampling_percent)
      #     => [[:req, :sampling_percent]]
      #     => [[:opt, :sampling_percent]]
      #     => [[:req, :sampling_percent], [:block, :block]]
      #     => [[:opt, :sampling_percent], [:block, :block]]
      if m_sig.size == 1
        prm = m_sig[0][0]
        prm == :req || prm == :opt
      elsif m_sig.size == 2
        f_prm = m_sig[0][0]
        s_prm = m_sig[1][0]

        # rubocop:disable Layout/MultilineOperationIndentation
        f_prm == :req && s_prm == :block ||
        f_prm == :opt && s_prm == :block
        # rubocop:enable Layout/MultilineOperationIndentation
      else
        false
      end
    end

    # @param instrumenter [Class,Module,Object]
    # @return [Boolean]
    #
    # @api public
    # @since 1.0.0
    def valid_interface?(instrumenter)
      if instrumenter == RedisQueuedLocks::Instrument::ActiveSupport
        # NOTE: active_support should be required in your app
        !!defined?(::ActiveSupport::Notifications)
      elsif instrumenter.respond_to?(:notify)
        # NOTE: the method signature should be (event, payload). Supported variants:
        #   => [[:req, :event], [:req, :payload]]
        #   => [[:req, :event], [:opt, :payload]]
        #   => [[:opt, :event], [:opt, :payload]]

        # @type var m_obj: Method
        m_obj = instrumenter.method(:notify)
        m_sig = m_obj.parameters

        if m_sig.size == 2
          f_prm = m_sig[0][0]
          s_prm = m_sig[1][0]

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
