# frozen_string_literal: true

# @api public
# @since 1.0.0
# @version 1.5.0
module RedisQueuedLocks::Logging
  require_relative 'logging/void_logger'
  require_relative 'logging/sampler'

  class << self
    # @param log_sampling_enabled [Boolean]
    # @param log_sample_this [Boolean]
    # @param log_sampling_percent [Integer]
    # @param log_sampler [#sampling_happened?,Module<RedisQueuedLocks::Logging::Sampler>]
    # @return [Boolean]
    #
    # @api private
    # @since 1.5.0
    def should_log?(
      log_sampling_enabled,
      log_sample_this,
      log_sampling_percent,
      log_sampler
    )
      return true unless log_sampling_enabled
      return true if log_sample_this
      log_sampler.sampling_happened?(log_sampling_percent)
    end

    # @param sampler [#sampling_happened?,Module<RedisQueuedLocks::Logging::Sampler>]
    # @return [Boolean]
    #
    # @api private
    # @since 1.5.0
    def valid_sampler?(sampler)
      return false unless sampler.respond_to?(:sampling_happened?)

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

    # @param logger [::Logger,#debug,::SemanticLogger::Logger]
    # @return [Boolean]
    #
    # @api public
    # @since 1.0.0
    # @version 1.2.0
    def valid_interface?(logger)
      return true if logger.is_a?(::Logger)

      # NOTE:
      #   - convinient/conventional way to support the popular `semantic_logger` library
      #     - see https://logger.rocketjob.io/
      #     - see https://github.com/reidmorrison/semantic_logger
      #   - convinient/conventional way to support the popular `broadcast` RoR's logger;
      #     - see https://api.rubyonrails.org/classes/ActiveSupport/BroadcastLogger.html
      # rubocop:disable Layout/LineLength
      return true if defined?(::SemanticLogger::Logger) && logger.is_a?(::SemanticLogger::Logger)
      return true if defined?(::ActiveSupport::BroadcastLogger) && logger.is_a?(::ActiveSupport::BroadcastLogger)
      # rubocop:enable Layout/LineLength

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

      # @type var m_obj: Method
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
