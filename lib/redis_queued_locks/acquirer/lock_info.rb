# frozen_string_literal: true

# @api private
# @since 1.0.0
# @version 1.18.0
module RedisQueuedLocks::Acquirer::LockInfo
  class << self
    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @return [Hash<String,String|Numeric|Array<Hash<String,String|Numeric>>>,NilClass]
    #   - `nil` is returned when lock key does not exist or expired (and there are no read locks);
    #   - result format (write lock): {
    #     'lock_key' => "rql:lock:your_lockname", # acquired lock key
    #     'rw_mode' => 'write', # lock mode
    #     'acq_id' => "rql:acq:123/456/789/987/uniqstring", # lock acquirer identifier
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
    #   - result format (read locks, when there is no write lock): {
    #     'lock_key' => "rql:lock:your_lockname", # lock key
    #     'rw_mode' => 'read', # lock mode
    #     'rem_ttl' => 123456789, # remaining ttl of the longest read lock (milliseconds)
    #     'readers' => [ # live read locks
    #       {
    #         'acq_id' => "rql:acq:123/456/789/987/uniqstring", # read lock acquirer identifier
    #         'hst_id' => "rql:hst:123/456/987/uniqstring", # read lock host identifier
    #         'ts' => 123456789.2649841, # <locked at> time stamp (epoch, seconds.microseconds)
    #         'ini_ttl' => 123456789, # initial read lock ttl (milliseconds)
    #         'rem_ttl' => 123456789, # remaining read lock ttl (milliseconds)
    #         <custom metadata (`meta`) and additional keys for reentrant locks (see above)>
    #       },
    #       ...
    #     ]
    #   }
    #
    # @api private
    # @since 1.0.0
    # @version 1.18.0
    # rubocop:disable Metrics/MethodLength
    def lock_info(redis_client, lock_name)
      lock_key = RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
      lock_readers_key = RedisQueuedLocks::Resource.prepare_lock_readers(lock_name)

      result = redis_client.pipelined do |pipeline|
        pipeline.call('HGETALL', lock_key)
        pipeline.call('PTTL', lock_key)
        pipeline.call('TIME')
        pipeline.call('ZRANGE', lock_readers_key, '0', '-1', 'WITHSCORES')
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
        #   - result[2] (TIME) (Array<String>) (redis time)
        #   - result[3] (ZRANGE) (Array<[String,Float]>) (read locks)

        # rubocop:disable Layout/LineLength
        # @type var result: [Hash[String,String|Float|Integer], Integer, Array[String], Array[[String, Float]]]
        # rubocop:enable Layout/LineLength
        hget_cmd_res = result[0]
        pttl_cmd_res = result[1]

        if hget_cmd_res == {} || pttl_cmd_res == -2 # NOTE: key does not exist
          # NOTE: (RW) there is no write lock => check read locks
          read_lock_info(redis_client, lock_name, lock_key, result[2], result[3])
        else
          hget_cmd_res.tap do |lock_data|
            lock_data['lock_key'] = lock_key
            lock_data['rw_mode'] = 'write'
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

    # Formats live read locks of the lock (expired read locks are ignored).
    #
    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @param lock_key [String]
    # @param redis_time [Array<String>] Result of the redis `TIME` command.
    # @param read_locks [Array<Array<String,Float>>] Readers registry (acquirer id, expiration).
    # @return [Hash<String,String|Numeric|Array<Hash<String,String|Numeric>>>,NilClass]
    #   - `nil` is returned when there are no live read locks;
    #   - each reader has the same data as the write lock (acq_id, hst_id, ts, ini_ttl, rem_ttl,
    #     meta, reentrant lock data);
    #
    # @api private
    # @since 1.18.0
    # rubocop:disable Metrics/MethodLength
    def read_lock_info(redis_client, lock_name, lock_key, redis_time, read_locks)
      now = RedisQueuedLocks::Resource.redis_time_ms(redis_time)
      live_read_locks = read_locks.select { |(_acquirer_id, expiration)| expiration > now }
      return nil if live_read_locks.empty?

      # NOTE: read lock data (it can be absent if it is dropped during the read lock life)
      # @type var read_locks_data: Array[Hash[String,String]]
      read_locks_data = redis_client.pipelined do |pipeline|
        live_read_locks.each do |(acquirer_id, _expiration)|
          pipeline.call(
            'HGETALL',
            RedisQueuedLocks::Resource.prepare_read_lock_key(lock_name, acquirer_id)
          )
        end
      end

      longest_rem_ttl = 0
      readers = live_read_locks.each_with_index.map do |(acquirer_id, expiration), index|
        rem_ttl = (expiration - now).ceil
        longest_rem_ttl = rem_ttl if rem_ttl > longest_rem_ttl

        # @type var reader: Hash[String,String|Float|Integer|nil]
        reader = read_locks_data[index] || {}
        reader['acq_id'] = acquirer_id
        reader['hst_id'] ||= RedisQueuedLocks::Resource.host_identifier_from_acquirer(acquirer_id)
        reader['ts'] = Float(reader['ts']) if reader['ts']
        reader['ini_ttl'] = Integer(reader['ini_ttl']) if reader['ini_ttl']
        reader['rem_ttl'] = rem_ttl
        reader['spc_cnt'] = Integer(reader['spc_cnt']) if reader['spc_cnt']
        reader['l_spc_ts'] = Float(reader['l_spc_ts']) if reader['l_spc_ts']
        reader['spc_ext_ttl'] = Integer(reader['spc_ext_ttl']) if reader['spc_ext_ttl']
        reader['l_spc_ext_ini_ttl'] =
          Integer(reader['l_spc_ext_ini_ttl']) if reader['l_spc_ext_ini_ttl']
        reader['l_spc_ext_ts'] = Float(reader['l_spc_ext_ts']) if reader['l_spc_ext_ts']
        reader
      end

      {
        'lock_key' => lock_key,
        'rw_mode' => 'read',
        'rem_ttl' => longest_rem_ttl,
        'readers' => readers
      }
    end
    # rubocop:enable Metrics/MethodLength
  end
end
