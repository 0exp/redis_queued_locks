# frozen_string_literal: true

# @api private
# @since 1.0.0
module RedisQueuedLocks::Acquier::Locks
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
    #
    # @api private
    # @since 1.0.0
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
      end
    end

    # @param redis_client [RedisClient]
    # @param lock_keys [Set<String>]
    # @return [Set<Hash<Symbol,Any>>]
    #
    # @api private
    # @since 1.0.0
    # @version 1.9.0
    # rubocop:disable Metrics/MethodLength
    def extract_locks_info(redis_client, lock_keys)
      # TODO: refactor with RedisQueuedLocks::Acquier::LockInfo
      Set.new.tap do |seeded_locks|
        # @type var seeded_locks: ::Set[{ lock: ::String, status: :released|:alive, info: ::Hash[::String,untyped] }]

        # Step X: iterate each lock and extract their info
        lock_keys.each do |lock_key|
          # Step 1: extract lock info from redis

          # @type var lock_info: ::Hash[::String,::String|::Float|::Integer]
          lock_info = redis_client.pipelined do |pipeline|
            pipeline.call('HGETALL', lock_key)
            pipeline.call('PTTL', lock_key)
          end.yield_self do |result| # Step 2: format the result
            # Step 2.X: lock is released
            if result == nil
              {}
            else
              # NOTE: the result of MULTI-command is an array of results of each internal command
              #   - result[0] (HGETALL) (Hash<String,String>)
              #     => (will be mutated further with different value types)
              #   - result[1] (PTTL) (Integer)
              #     => (without any mutation, integer is atomic)

              # @type var result: [::Hash[::String,::String|::Float|::Integer],::Integer]
              hget_cmd_res = result[0] # NOTE: HGETALL result (hash)
              pttl_cmd_res = result[1] # NOTE: PTTL result (integer)

              # Step 2.Y: lock is released
              if hget_cmd_res == {} || pttl_cmd_res == -2 # NOTE: key does not exist
                {}
              else
                # Step 2.Z: lock is alive => format received info + add additional rem_ttl info
                hget_cmd_res.tap do |lock_data|
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
  end
end
