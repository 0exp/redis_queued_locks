# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Acquier::LockInfo
  class << self
    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @return [Hash<Symbol,String|Numeric>,NilClass]
    #   - `nil` is returned when lock key does not exist or expired;
    #   - result format: {
    #     lock_key: "rql:lock:your_lockname", # acquired lock key
    #     acq_id: "rql:acq:process_id/thread_id", # lock acquier identifier
    #     ts: 123456789, # <locked at> time stamp (epoch)
    #     ini_ttl: 123456789, # initial lock key ttl (milliseconds),
    #     rem_ttl: 123456789, # remaining lock key ttl (milliseconds)
    #   }
    #
    # @api private
    # @since 0.1.0
    def lock_info(redis_client, lock_name)
      lock_key = RedisQueuedLocks::Resource.prepare_lock_key(lock_name)

      result = redis_client.multi(watch: [lock_key]) do |transact|
        transact.call('HGETALL', lock_key)
        transact.call('PTTL', lock_key)
      end

      if result == nil
        # NOTE:
        #   - nil result means that during transaction invocation the lock is changed (CAS):
        #     - lock is expired;
        #     - lock is released;
        #     - lock is expired + re-obtained;
        nil
      else
        hget_cmd_res = result[0]
        pttl_cmd_res = result[1]

        if hget_cmd_res == {} || pttl_cmd_res == -2 # NOTE: key does not exist
          nil
        else
          # NOTE: the result of MULTI-command is an array of results of each internal command
          #   - result[0] (HGETALL) (Hash<String,String>)
          #   - result[1] (PTTL) (Integer)
          {
            lock_key: lock_key,
            acq_id: hget_cmd_res['acq_id'],
            ts: Integer(hget_cmd_res['ts']),
            ini_ttl: Integer(hget_cmd_res['ini_ttl']),
            rem_ttl: ((pttl_cmd_res == -1) ? Infinity : pttl_cmd_res)
          }
        end
      end
    end
  end
end
