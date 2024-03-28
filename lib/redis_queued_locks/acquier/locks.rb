# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Acquier::Locks
  # @return [Hash]
  #
  # @api private
  # @since 0.1.0
  NO_LOCK_INFO = {}.freeze

  class << self
    # @param redis_client [RedisClient]
    # @option scan_size [Integer]
    # @option with_info [Boolean]
    # @return [Set<String>,Set<Hash<Symbol,Any>>]
    #
    # @api private
    # @since 0.1.0
    def locks(redis_client, scan_size:, with_info:)
      lock_keys = scan_locks(redis_client, scan_size)
      with_info ? extract_locks_info(redis_client, lock_keys) : lock_keys
    end

    private

    # @param redis_client [RedisClient]
    # @param scan_size [Integer]
    # @return [Set<String>]
    #
    # @api private
    # @since 0.1.0
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
    # @since 0.1.0
    # rubocop:disable Metrics/MethodLength
    def extract_locks_info(redis_client, lock_keys)
      # TODO: refactor with RedisQueuedLocks::Acquier::LockInfo
      Set.new.tap do |seeded_locks|
        # Step X: iterate each lock and extract their info
        lock_keys.each do |lock_key|
          # Step 1: extract lock info from redis
          lock_info = redis_client.multi(watch: [lock_key]) do |transact|
            transact.call('HGETALL', lock_key)
            transact.call('PTTL', lock_key)
          end.yield_self do |result| # Step 2: format the result
            # Step 2.X: lock is released
            if result == nil
              {}
            else
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
                  lock_data['rem_ttl'] = ((pttl_cmd_res == -1) ? Infinity : pttl_cmd_res)
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
