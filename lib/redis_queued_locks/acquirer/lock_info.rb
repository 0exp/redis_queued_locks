# frozen_string_literal: true

# @api private
# @since 1.0.0
module RedisQueuedLocks::Acquirer::LockInfo
  class << self
    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @return [Hash<String,String|Numeric>,NilClass]
    #   - `nil` is returned when lock key does not exist or expired;
    #   - result format: {
    #     'lock_key' => "rql:lock:your_lockname", # acquired lock key
    #     'acq_id' => "rql:acq:123/456/789/987/uniqstring", # lock acquier identifier
    #     'hst_id' => "rql:hst:123/456/987/uniqstring", # lock host identifier
    #     'ts' => 123456789.2649841, # <locked at> time stamp (epoch, seconds.microseconds)
    #     'ini_ttl' => 123456789, # initial lock key ttl (milliseconds)
    #     'rem_ttl' => 123456789, # remaining lock key ttl (milliseconds)
    #     <additional keys for reentrant locks>:
    #     'spc_cnt' => 2, # lock reentreing count (if lock was used as reentrant lock)
    #     'l_spc_ts' => 123456.1234 # (epoch) <non-extendable reentrant lock obtained at> timestamp
    #     'spc_ext_ttl' => 14500, # (milliseconds) the sum of all ttl extensions
    #     'l_spc_ext_ini_ttl' => 5000, # (milliseconds) the last ttl of reentrant lock
    #     'l_spc_ext_ts' => 123456.789 # (epoch) <extendable reentrant lock obtained at> timestamp
    #   }
    #
    # @api private
    # @since 1.0.0
    # @version 1.9.0
    # rubocop:disable Metrics/MethodLength
    def lock_info(redis_client, lock_name)
      lock_key = RedisQueuedLocks::Resource.prepare_lock_key(lock_name)

      result = redis_client.pipelined do |pipeline|
        pipeline.call('HGETALL', lock_key)
        pipeline.call('PTTL', lock_key)
      end

      if result == nil
        # NOTE:
        #   - nil result means that during transaction invocation the lock is changed (CAS):
        #     - lock is expired;
        #     - lock is released;
        #     - lock is expired + re-obtained;
        nil
      else
        # NOTE: the result of MULTI-command is an array of results of each internal command
        #   - result[0] (HGETALL) (Hash<String,String>)
        #     => (will be mutated further with different value types)
        #   - result[1] (PTTL) (Integer)
        #     => (without any mutation, integer is atomic)

        # @type var result: [::Hash[::String,::String|::Float|::Integer],::Integer]
        hget_cmd_res = result[0]
        pttl_cmd_res = result[1]

        if hget_cmd_res == {} || pttl_cmd_res == -2 # NOTE: key does not exist
          nil
        else
          hget_cmd_res.tap do |lock_data|
            lock_data['lock_key'] = lock_key
            lock_data['ts'] = Float(lock_data['ts'])
            lock_data['ini_ttl'] = Integer(lock_data['ini_ttl'])
            lock_data['rem_ttl'] = ((pttl_cmd_res == -1) ? Float::INFINITY : pttl_cmd_res)
            lock_data['spc_cnt'] = Integer(lock_data['spc_cnt']) if lock_data['spc_cnt']
            lock_data['l_spc_ts'] = Float(lock_data['l_spc_ts']) if lock_data['l_spc_ts']
            lock_data['spc_ext_ttl'] = Integer(lock_data['spc_ext_ttl']) if lock_data['spc_ext_ttl']
            lock_data['l_spc_ext_ini_ttl'] =
              Integer(lock_data['l_spc_ext_ini_ttl']) if lock_data.key?('l_spc_ext_ini_ttl')
            lock_data['l_spc_ext_ts'] =
              Float(lock_data['l_spc_ext_ts']) if lock_data['l_spc_ext_ts']
          end
        end
      end
    end
    # rubocop:enable Metrics/MethodLength
  end
end
