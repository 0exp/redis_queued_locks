# frozen_string_literal: true

# @api private
# @since 1.0.0
# @version 1.18.0
# rubocop:disable Metrics/ModuleLength
module RedisQueuedLocks::Acquirer::Locks
  # rubocop:disable Metrics/ClassLength
  class << self
    # @param redis_client [RedisClient]
    # @option scan_size [Integer]
    # @option with_info [Boolean]
    # @return [Set<String>,Set<Hash<Symbol,Any>>]
    #
    # @api private
    # @since 1.0.0
    def locks(redis_client, scan_size:, with_info:)
      redis_client.with do |rconn|
        lock_keys = scan_locks(rconn, scan_size)
        with_info ? extract_locks_info(rconn, lock_keys) : lock_keys
      end
    end

    private

    # @param redis_client [RedisClient]
    # @param scan_size [Integer]
    # @return [Set<String>]
    #   - (RW) read locks are represented by their lock keys (`rql:lock:<lock_name>`) too;
    #
    # @api private
    # @since 1.0.0
    # @version 1.18.0
    def scan_locks(redis_client, scan_size)
      Set.new.tap do |lock_keys|
        redis_client.scan(
          'MATCH',
          RedisQueuedLocks::Resource::LOCK_PATTERN,
          count: scan_size
        ) do |lock_key|
          # TODO: reduce unnecessary iterations
          lock_keys.add(lock_key)
        end

        # NOTE: (RW) read locks (readers registries can contain expired read locks only)
        redis_client.scan(
          'MATCH',
          RedisQueuedLocks::Resource::LOCK_READERS_PATTERN,
          count: scan_size
        ) do |lock_readers_key|
          # TODO: reduce unnecessary iterations
          lock_keys.add(RedisQueuedLocks::Resource.lock_key_from_readers(lock_readers_key))
        end
      end
    end

    # NOTE:
    #   - the lock info is extracted by the module itself with the same approach as in `LockInfo`:
    #     public operation modules do not reuse each other (they share logic via `Resource`,
    #     `Utilities`), so the similar logic is duplicated on purpose;
    #
    # @param redis_client [RedisClient]
    # @param lock_keys [Set<String>]
    # @return [Set<Hash<Symbol,Any>>]
    #
    # @api private
    # @since 1.0.0
    # @version 1.18.0
    # rubocop:disable Metrics/MethodLength
    def extract_locks_info(redis_client, lock_keys)
      Set.new.tap do |seeded_locks|
        # rubocop:disable Layout/LineLength
        # @type var seeded_locks: Set[{ lock: String, status: :released|:alive, info: Hash[String,untyped] }]
        # rubocop:enable Layout/LineLength

        # Step X: iterate each lock and extract their info
        lock_keys.each do |lock_key|
          # Step 1: extract lock info from redis

          # NOTE: (RW) readers registry of the lock
          lock_name = lock_key.delete_prefix('rql:lock:')
          lock_readers_key = RedisQueuedLocks::Resource.prepare_lock_readers(lock_name)

          # @type var lock_info: RedisQueuedLocks::Acquirer::Locks::lockInfo
          lock_info = redis_client.pipelined do |pipeline|
            pipeline.call('HGETALL', lock_key)
            pipeline.call('PTTL', lock_key)
            pipeline.call('TIME')
            pipeline.call('ZRANGE', lock_readers_key, '0', '-1', 'WITHSCORES')
          end.yield_self do |result| # Step 2: format the result
            # Step 2.X: lock is released
            if result == nil
              {} #: Hash[String,String|Float|Integer]
            else
              # NOTE: the result of MULTI-command is an array of results of each internal command
              #   - result[0] (HGETALL) (Hash<String,String>)
              #     => (will be mutated further with different value types)
              #   - result[1] (PTTL) (Integer)
              #     => (without any mutation, integer is atomic)

              # rubocop:disable Layout/LineLength
              # @type var result: [Hash[String,String|Float|Integer],Integer,Array[String],Array[[String, Float]]]
              # rubocop:enable Layout/LineLength
              hget_cmd_res = result[0] # NOTE: HGETALL result (hash)
              pttl_cmd_res = result[1] # NOTE: PTTL result (integer)

              # Step 2.Y: write lock is released
              if hget_cmd_res == {} || pttl_cmd_res == -2 # NOTE: key does not exist
                # NOTE: (RW) read locks (or nothing if there are no live read locks)
                read_lock_info(
                  redis_client, lock_name, lock_key, result[2], result[3]
                ) || {} #: Hash[String,String|Float|Integer]
              else
                # Step 2.Z: lock is alive => format received info + add additional rem_ttl info
                hget_cmd_res.tap do |lock_data|
                  lock_data['rw_mode'] = 'write'
                  lock_data['ts'] = Float(lock_data['ts'])
                  lock_data['ini_ttl'] = Integer(lock_data['ini_ttl'])
                  lock_data['rem_ttl'] = ((pttl_cmd_res == -1) ? Float::INFINITY : pttl_cmd_res)
                  lock_data['spc_cnt'] = Integer(lock_data['spc_cnt']) if lock_data['spc_cnt']
                  lock_data['l_spc_ts'] = Float(lock_data['l_spc_ts']) if lock_data['l_spc_ts']
                  lock_data['spc_ext_ttl'] =
                    Integer(lock_data['spc_ext_ttl']) if lock_data['spc_ext_ttl']
                  lock_data['l_spc_ext_ini_ttl'] =
                    Integer(lock_data['l_spc_ext_ini_ttl']) if lock_data.key?('l_spc_ext_ini_ttl')
                  lock_data['l_spc_ext_ts'] =
                    Float(lock_data['l_spc_ext_ts']) if lock_data['l_spc_ext_ts']
                end
              end
            end
          end

          # Step 3: push the lock info to the result store
          seeded_locks << {
            lock: lock_key,
            status: (lock_info.empty? ? :released : :alive),
            info: lock_info
          }
        end
      end
    end
    # rubocop:enable Metrics/MethodLength

    # Formats live read locks of the lock (expired read locks are ignored).
    #
    # NOTE: the same approach as in `LockInfo` (duplicated on purpose: operation modules are
    #   independent of each other, see `extract_locks_info`);
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
  # rubocop:enable Metrics/ClassLength
end
# rubocop:enable Metrics/ModuleLength
