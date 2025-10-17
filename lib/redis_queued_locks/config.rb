# frozen_string_literal: true

# @api private
# @since 1.13.0
# @version 1.14.0
# rubocop:disable Metrics/ClassLength
class RedisQueuedLocks::Config
  require_relative 'config/dsl'

  # @api private
  # @since 1.13.0
  include DSL

  setting('retry_count', 3)
  setting('retry_delay', 200) # NOTE: in milliseconds)
  setting('retry_jitter', 25) # NOTE: in milliseconds)
  setting('try_to_lock_timeout', 10) # NOTE: in seconds)
  setting('default_lock_ttl', 5_000) # NOTE: in milliseconds)
  setting('default_queue_ttl', 15) # NOTE: in seconds)
  setting('detailed_acq_timeout_error', false)
  setting('lock_release_batch_size', 100)
  setting('clear_locks_of__lock_scan_size', 300)
  setting('clear_locks_of__queue_scan_size', 300)
  setting('key_extraction_batch_size', 500)
  setting('instrumenter', RedisQueuedLocks::Instrument::VoidNotifier)
  setting('uniq_identifier', -> { RedisQueuedLocks::Resource.calc_uniq_identity })
  setting('logger', RedisQueuedLocks::Logging::VoidLogger)
  setting('log_lock_try', false)
  setting('dead_request_ttl', 1 * 24 * 60 * 60 * 1000) # NOTE: 1 day in milliseconds)
  setting('is_timed_by_default', false)
  setting('default_conflict_strategy', :wait_for_lock)
  setting('default_access_strategy', :queued)
  setting('log_sampling_enabled', false)
  setting('log_sampling_percent', 15)
  setting('log_sampler', RedisQueuedLocks::Logging::Sampler)
  setting('instr_sampling_enabled', false)
  setting('instr_sampling_percent', 15)
  setting('instr_sampler', RedisQueuedLocks::Instrument::Sampler)
  setting('swarm.auto_swarm', false)
  setting('swarm.supervisor.liveness_probing_period', 2) # NOTE: in seconds)
  setting('swarm.probe_hosts.enabled_for_swarm', true)
  setting('swarm.probe_hosts.probe_period', 2) # NOTE: in seconds)
  setting('swarm.probe_hosts.redis_config.sentinel', false)
  setting('swarm.probe_hosts.redis_config.pooled', false)
  setting('swarm.probe_hosts.redis_config.config', {})
  setting('swarm.probe_hosts.redis_config.pool_config', {})
  setting('swarm.flush_zombies.enabled_for_swarm', true)
  setting('swarm.flush_zombies.zombie_ttl', 15_000) # NOTE: in milliseconds)
  setting('swarm.flush_zombies.zombie_lock_scan_size', 500)
  setting('swarm.flush_zombies.zombie_queue_scan_size', 500)
  setting('swarm.flush_zombies.zombie_flush_period', 10)
  setting('swarm.flush_zombies.redis_config.sentinel', false)
  setting('swarm.flush_zombies.redis_config.pooled', false)
  setting('swarm.flush_zombies.redis_config.config', {})
  setting('swarm.flush_zombies.redis_config.pool_config', {})

  validate('swarm.auto_swarm') { |val| val == true || val == false }
  validate('swarm.supervisor.liveness_probing_period') { |val| val.is_a?(Integer) }

  validate('swarm.probe_hosts.enabled_for_swarm') { |val| val == true || val == false }
  validate('swarm.probe_hosts.redis_config.sentinel') { |val| val == true || val == false }
  validate('swarm.probe_hosts.redis_config.pooled') { |val| val == true || val == false }
  validate('swarm.probe_hosts.redis_config.config') { |val| val.is_a?(Hash) }
  validate('swarm.probe_hosts.redis_config.pool_config') { |val| val.is_a?(Hash) }
  validate('swarm.probe_hosts.probe_period') { |val| val.is_a?(Integer) }

  validate('swarm.flush_zombies.enabled_for_swarm') { |val| val == true || val == false }
  validate('swarm.flush_zombies.redis_config.sentinel') { |val| val == true || val == false }
  validate('swarm.flush_zombies.redis_config.pooled') { |val| val == true || val == false }
  validate('swarm.flush_zombies.redis_config.config') { |val| val.is_a?(Hash) }
  validate('swarm.flush_zombies.redis_config.pool_config') { |val| val.is_a?(Hash) }
  validate('swarm.flush_zombies.zombie_ttl') { |val| val.is_a?(Integer) }
  validate('swarm.flush_zombies.zombie_lock_scan_size') { |val| val.is_a?(Integer) }
  validate('swarm.flush_zombies.zombie_queue_scan_size') { |val| val.is_a?(Integer) }
  validate('swarm.flush_zombies.zombie_flush_period') { |val| val.is_a?(Integer) }

  validate('retry_count') { |val| val == nil || (val.is_a?(Integer) && val >= 0) }
  validate('retry_delay') { |val| val.is_a?(Integer) && val >= 0 }
  validate('retry_jitter') { |val| val.is_a?(Integer) && val >= 0 }
  validate('try_to_lock_timeout') { |val| val == nil || (val.is_a?(Integer) && val >= 0) }
  validate('default_lock_tt') { |val| val.is_a?(Integer) }
  validate('default_queue_ttl') { |val| val.is_a?(Integer) }
  validate('detailed_acq_timeout_error') { |val| val == true || val == false }
  validate('lock_release_batch_size') { |val| val.is_a?(Integer) }
  validate('clear_locks_of__lock_scan_size') { |val| val.is_a?(Integer) }
  validate('clear_locks_of__queue_scan_size') { |val| val.is_a?(Integer) }
  validate('instrumenter') { |val| RedisQueuedLocks::Instrument.valid_interface?(val) }
  validate('uniq_identifier') { |val| val.is_a?(Proc) }
  validate('logger') { |val| RedisQueuedLocks::Logging.valid_interface?(val) }
  validate('log_lock_try') { |val| val == true || val == false }
  validate('dead_request_ttl') { |val| val.is_a?(Integer) && val > 0 }
  validate('is_timed_by_default') { |val| val == true || val == false }
  validate('log_sampler') { |val| RedisQueuedLocks::Logging.valid_sampler?(val) }
  validate('log_sampling_enabled') { |val| val == true || val == false }
  validate('log_sampling_percent') { |val| val.is_a?(Integer) && val >= 0 && val <= 100 }
  validate('instr_sampling_enabled') { |val| val == true || val == false }
  validate('instr_sampling_percent') { |val| val.is_a?(Integer) && val >= 0 && val <= 100 }
  validate('instr_sampler') { |val| RedisQueuedLocks::Instrument.valid_sampler?(val) }
  validate('default_conflict_strategy') do |val|
    # rubocop:disable Layout/MultilineOperationIndentation
    val == :work_through ||
    val == :extendable_work_through ||
    val == :wait_for_lock ||
    val == :dead_locking
    # rubocop:enable Layout/MultilineOperationIndentation
  end
  validate('default_access_strategy') do |val|
    # rubocop:disable Layout/MultilineOperationIndentation
    val == :queued ||
    val == :random
    # rubocop:enable Layout/MultilineOperationIndentation
  end

  # @return [Hash<Symbol,Any>]
  #
  # @api private
  # @since 1.13.0
  attr_reader :config_state

  # @return [void]
  #
  # @api private
  # @since 1.13.0
  def initialize(&configuration)
    @config_state = {}
    config_setters.each_value { |setter| setter.call(@config_state) }
    configure(&configuration)
  end

  # @param configuration [Block]
  # @yield [?]
  # @yieldparam [?]
  # @return [void]
  #
  # @api private
  # @since 1.13.0
  def configure(&configuration)
    yield(self) if block_given?
  end

  # @param config_key [String]
  # @return [Any]
  #
  # @raise [RedisQueuedLocks::ConfigNotFoundError]
  #
  # @api public
  # @since 1.13.0
  def [](config_key)
    prevent_key__non_existent(config_key)
    config_state[config_key]
  end

  # @param config_key [String]
  # @param config_value [Any]
  # @return [void]
  #
  # @raise [RedisQueuedLocks::ConfigNotFoundError]
  # @raise [RedisQueuedLocks::ConfigValidationError]
  #
  # @api public
  # @since 1.13.0
  def []=(config_key, config_value)
    prevent_key__non_existent(config_key)
    prevent_key__invalid_type(config_key, config_value)
    config_state[config_key] = config_value
  end

  # Returns the slice of the config values as a `hash` match the received pattern.
  # Matched configs will be sliced as a nested config (as a hash object). And config valuess
  # will be duplicated via `Object#dup`. How it works:
  #   initial config sate: => {
  #     'swarm.flush_zombies.redis_config.pooled' => true,
  #     'swarm.flush_zombies.redis_config.sentinel' => true,
  #     'swarm.aut_swarm' => false,
  #     'logger' => Logger.new
  #   }
  #   slice with "swarm.flush_zombies.redis_config" pattern: => {
  #     'pooled' => true,
  #     'sentinel' => true
  #   }
  #
  # @param config_key_pattern [String]
  # @return [Hash<String,Any>]
  #
  # @api public
  # @since 1.13.0
  def slice(config_key_pattern)
    key_selector = "#{config_key_pattern}."
    key_splitter = key_selector.size
    sliced_config = {} #: Hash[String,untyped]

    config_state.each_pair do |config_key, config_value|
      next unless config_key.start_with?(key_selector)
      sliced_config_key = config_key[key_splitter..] #: String
      sliced_config[sliced_config_key] = config_value.dup
    end

    sliced_config
  end

  private

  # @param config_key [String]
  # @return [void]
  #
  # @raise [RedisQueuedLocks::ConfigNotFoundError]
  #
  # @api private
  # @since 1.13.0
  def prevent_key__non_existent(config_key)
    unless config_state.key?(config_key)
      raise(
        RedisQueuedLocks::ConfigNotFoundError,
        "Config with '#{config_key}' key does not exist."
      )
    end
  end

  # @param config_key [String]
  # @param config_value [Any]
  # @return [void]
  #
  # @raise [RedisQueuedLocks::ConfigValidationError]
  #
  # @api private
  # @since 1.13.0
  def prevent_key__invalid_type(config_key, config_value)
    unless config_validators[config_key].call(config_value)
      raise(
        RedisQueuedLocks::ConfigValidationError,
        "Trying to assing an invalid value to the '#{config_key}' config key."
      )
    end
  end
end
# rubocop:enable Metrics/ClassLength
