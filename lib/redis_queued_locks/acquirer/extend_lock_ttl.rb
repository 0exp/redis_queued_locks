# frozen_string_literal: true

# @api private
# @since 1.0.0
module RedisQueuedLocks::Acquirer::ExtendLockTTL
  # @return [String]
  #
  # @api private
  # @since 1.0.0
  EXTEND_LOCK_PTTL = <<~LUA_SCRIPT.strip.tr("\n", '').freeze
    local new_lock_pttl = redis.call("PTTL", KEYS[1]) + ARGV[1];
    return redis.call("PEXPIRE", KEYS[1], new_lock_pttl);
  LUA_SCRIPT

  class << self
    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @param milliseconds [Integer]
    # @param logger [::Logger,#debug]
    # @param instrumenter [#notify]
    # @param instrument [NilClass,Any]
    # @param log_sampling_enabled [Boolean]
    # @param log_sampling_percent [Integer]
    # @param log_sampler [#sampling_happened?,Module<RedisQueuedLocks::Logging::Sampler>]
    # @param log_sample_this [Boolean]
    # @param instr_sampling_enabled [Boolean]
    # @param instr_sampling_percent [Integer]
    # @param instr_sampler [#sampling_happened?,Module<RedisQueuedLocks::Instrument::Sampler>]
    # @param instr_sample_this [Boolean]
    # @return [Hash<Symbol,Boolean|Symbol>]
    #
    # @api private
    # @since 1.0.0
    # @version 1.6.0
    def extend_lock_ttl(
      redis_client,
      lock_name,
      milliseconds,
      logger,
      instrumenter,
      instrument,
      log_sampling_enabled,
      log_sampling_percent,
      log_sampler,
      log_sample_this,
      instr_sampling_enabled,
      instr_sampling_percent,
      instr_sampler,
      instr_sample_this
    )
      lock_key = RedisQueuedLocks::Resource.prepare_lock_key(lock_name)

      # NOTE: EVAL signature -> <lua script>, (number of keys), *(keys), *(arguments)
      result = redis_client.call('EVAL', EXTEND_LOCK_PTTL, 1, lock_key, milliseconds)
      # TODO: upload scripts to the redis

      # @type var result: ::Integer
      if result == 1
        RedisQueuedLocks::Data[ok: true, result: :ttl_extended] # steep:ignore
      else
        RedisQueuedLocks::Data[ok: false, result: :async_expire_or_no_lock] # steep:ignore
      end
    end
  end
end
