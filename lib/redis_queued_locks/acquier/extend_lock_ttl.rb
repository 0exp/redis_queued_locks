# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Acquier::ExtendLockTTL
  # @return [String]
  #
  # @api private
  # @since 0.1.0
  EXTEND_LOCK_PTTL = <<~LUA_SCRIPT.strip.tr("\n", '').freeze
    local new_lock_pttl = redis.call("PTTL", KEYS[1]) + ARGV[1];
    return redis.call("PEXPIRE", KEYS[1], new_lock_pttl);
  LUA_SCRIPT

  class << self
    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @param milliseconds [Integer]
    # @param logger [::Logger,#debug]
    # @return [Hash<Symbol,Boolean|Symbol>]
    #
    # @api private
    # @since 0.1.0
    def extend_lock_ttl(redis_client, lock_name, milliseconds, logger)
      lock_key = RedisQueuedLocks::Resource.prepare_lock_key(lock_name)

      # NOTE: EVAL signature -> <lua script>, (keys number), *(keys), *(arguments)
      result = redis_client.call('EVAL', EXTEND_LOCK_PTTL, 1, lock_key, milliseconds)
      # TODO: upload scripts to the redis

      if result == 1
        RedisQueuedLocks::Data[ok: true, result: :ttl_extended]
      else
        RedisQueuedLocks::Data[ok: false, result: :async_expire_or_no_lock]
      end
    end
  end
end
