# frozen_string_literal: true

# @api private
# @since [1.13.0]
module RedisQueuedLocks::Config::DSL
  # @api private
  # @since [1.13.0]
  module ClassMethods
    # NOTE:
    #   1. Style/DefWithParentheses rubocop's cop incorrectly drops `()` from method definition
    #   and breaks ruby code syntax. So this cop is disabled here;
    #   2. attr_reader is not used cuz `steep` can't understand it form inside the class where
    #   the current module is mixed;
    #
    # @return [Hash<String,Block>]
    #
    # @api private
    # @since [1.13.0]
    def config_setters()= @config_setters # rubocop:disable Style/DefWithParentheses

    # NOTE:
    #   1. Style/DefWithParentheses rubocop's cop incorrectly drops `()` from method definition
    #   and breaks ruby code syntax. So this cop is disabled here;
    #   2. attr_reader is not used cuz `steep` can't understand it form inside the class where
    #   the current module is mixed;
    #
    # @return [Hash<String,Block>]
    #
    # @api private
    # @since [1.13.0]
    def config_validators()= @config_validators # rubocop:disable Style/DefWithParentheses

    # @param config_key [String]
    # @param validator [Block]
    # @return [Bool]
    #
    # @api private
    # @since [1.13.0]
    def validate(config_key, &validator)
      config_validators[config_key] = validator
    end

    # @param config_key [String]
    # @param config_value [Any]
    # @return [void]
    #
    # @api private
    # @since [1.13.0]
    def setting(config_key, config_value)
      config_setters[config_key] = proc do |config|
        config[config_key] = config_value
      end
    end
  end

  module InstanceMethods
    # @return [Hash<String,Blcok>]
    #
    # @api private
    # @since [1.13.0]
    def config_setters
      self.class.config_setters # steep:ignore
    end

    # @return [Hash<String,Blcok>]
    #
    # @api private
    # @since [1.13.0]
    def config_validators
      self.class.config_validators # steep:ignore
    end
  end

  class << self
    # @param child_klass [Class]
    # @return [void]
    #
    # @api private
    # @since [1.13.0]
    def included(child_klass)
      child_klass.instance_variable_set(
        :@config_setters,
        {} #: RedisQueuedLocks::Config::DSL::configSetters
      )
      child_klass.instance_variable_set(
        :@config_validators,
        {} #: RedisQueuedLocks::Config::DSL::configValidators
      )
      child_klass.extend(ClassMethods)
      child_klass.include(InstanceMethods)
      super
    end
  end
end
