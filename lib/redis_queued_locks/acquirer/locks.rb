# frozen_string_literal: true

# @api private
# @since 1.0.0
# @version 1.20.0
# rubocop:disable Metrics/ModuleLength
module RedisQueuedLocks::Acquirer::Locks
  # The number of replies of one lock in the lock state pipeline of a batch of locks
  # (`extract_locks_info`): HGETALL (write lock), PTTL (write lock), ZRANGE (readers registry).
  #
  # @return [Integer]
  #
  # @api private
  # @since 1.20.0
  LOCK_STATE_REPLIES = 3

  # rubocop:disable Metrics/ClassLength
  class << self
    # @param redis_client [RedisClient]
    # @option scan_size [Integer]
    # @option with_info [Boolean]
    # @option lock_index_enabled [Boolean]
    #   Find locks via the lock index (`index_locks`) instead of the keyspace SCAN (`scan_locks`).
    # @return [Set<String>,Set<Hash<Symbol,Any>>]
    #
    # @api private
    # @since 1.0.0
    # @version 1.20.0
    def locks(redis_client, scan_size:, with_info:, lock_index_enabled:)
      redis_client.with do |rconn|
        lock_keys =
          lock_index_enabled ? index_locks(rconn, scan_size) : scan_locks(rconn, scan_size)
        with_info ? extract_locks_info(rconn, lock_keys, scan_size) : lock_keys
      end
    end

    private

    # Write locks and read locks in one SCAN pass (the disabled lock index).
    #
    # @param redis_client [RedisClient]
    # @param scan_size [Integer]
    # @return [Set<String>]
    #   - (RW) read locks are represented by their lock keys (`rql:lock:<lock_name>`) too;
    #
    # @api private
    # @since 1.0.0
    # @version 1.20.0
    def scan_locks(redis_client, scan_size)
      Set.new.tap do |lock_keys|
        # @type var lock_keys: Set[String]
        redis_client.scan(
          'MATCH',
          RedisQueuedLocks::Resource::KEY_PATTERN,
          count: scan_size
        ) do |key|
          case RedisQueuedLocks::Resource.lock_key_family(key)
          when :lock
            lock_keys.add(key)
          when :lock_readers
            # NOTE: (RW) read locks (readers registries can contain expired read locks only)
            lock_keys.add(RedisQueuedLocks::Resource.lock_key_from_readers(key))
          end
        end
      end
    end

    # Write locks and read locks of the lock index (the enabled lock index): one ZSCAN pass over
    # the lock names (`RedisQueuedLocks::Resource::LOCK_INDEX_KEY`, the keyspace is never scanned)
    # with one round trip per batch of `scan_size` lock names (`EXISTS` of the write lock and of
    # the readers registry of each lock name).
    #
    # @param redis_client [RedisClient]
    # @param scan_size [Integer] ZSCAN count and the number of lock names in one batch.
    # @return [Set<String>]
    #   - (RW) read locks are represented by their lock keys (`rql:lock:<lock_name>`) too
    #     (readers registries can contain expired read locks only);
    #
    # @api private
    # @since 1.20.0
    def index_locks(redis_client, scan_size)
      Set.new.tap do |lock_keys|
        # @type var lock_keys: Set[String]
        each_lock_name_batch(redis_client, scan_size) do |lock_names|
          # NOTE: (pipeline layout) one reply per lock name in the batch order: the number of
          #   the existing keys of the lock (the write lock and the readers registry);
          # @type var lock_keys_count: Array[Integer]
          lock_keys_count = redis_client.pipelined do |pipeline|
            lock_names.each do |lock_name|
              pipeline.call(
                'EXISTS',
                RedisQueuedLocks::Resource.prepare_lock_key(lock_name),
                RedisQueuedLocks::Resource.prepare_lock_readers(lock_name)
              )
            end
          end

          lock_names.each_with_index do |lock_name, index|
            next if lock_keys_count[index] == 0

            lock_keys.add(RedisQueuedLocks::Resource.prepare_lock_key(lock_name))
          end
        end
      end
    end

    # Iterates over the lock names of the lock index (one ZSCAN pass) in batches of `scan_size`
    # lock names (batches are collected across ZSCAN pages). Expired lock names (not dropped from
    # the index yet) are skipped: all their keys are expired.
    #
    # NOTE: each operation module iterates over the lock index by itself (duplicated on purpose:
    #   operation modules are independent of each other, see `extract_locks_info`);
    #
    # @param redis_client [RedisClient]
    # @param scan_size [Integer] ZSCAN count and the number of lock names in one batch.
    # @yield [lock_names]
    # @yieldparam lock_names [Array<String>] The batch of lock names (reused between batches).
    # @return [void]
    #
    # @api private
    # @since 1.20.0
    def each_lock_name_batch(redis_client, scan_size)
      lock_index_time = RedisQueuedLocks::Resource.lock_index_time
      # @type var lock_names: Array[String]
      lock_names = []

      redis_client.zscan(
        RedisQueuedLocks::Resource::LOCK_INDEX_KEY, count: scan_size
      ) do |lock_name, lock_index_score|
        next if lock_index_score.to_f < lock_index_time

        lock_names << lock_name
        next if lock_names.size < scan_size

        yield(lock_names)
        lock_names.clear
      end

      yield(lock_names) unless lock_names.empty?
    end

    # NOTE:
    #   - the lock info is extracted by the module itself with the same approach as in `LockInfo`:
    #     public operation modules do not reuse each other (they share logic via `Resource`,
    #     `Utilities`), so the similar logic is duplicated on purpose;
    #   - locks are processed in batches of `scan_size` locks: two round trips per batch
    #     (the state of the locks, then the data of the live read locks);
    #
    # @param redis_client [RedisClient]
    # @param lock_keys [Set<String>]
    # @param scan_size [Integer] The number of locks in one batch.
    # @return [Set<Hash<Symbol,Any>>]
    #
    # @api private
    # @since 1.0.0
    # @version 1.20.0
    # rubocop:disable Metrics/MethodLength
    def extract_locks_info(redis_client, lock_keys, scan_size)
      Set.new.tap do |seeded_locks|
        # rubocop:disable Layout/LineLength
        # @type var seeded_locks: Set[{ lock: String, status: :released|:alive, info: Hash[String,untyped] }]
        # rubocop:enable Layout/LineLength

        lock_keys.each_slice(scan_size) do |lock_keys_batch|
          # Step 0: lock names of the batch (once per lock: the readers registry keys and the read
          #   lock data keys are built from them)
          # @type var lock_names_batch: Array[String]
          lock_names_batch = lock_keys_batch.map do |lock_key|
            RedisQueuedLocks::Resource.lock_name_from_key(lock_key, :lock) #: String
          end

          # Step 1: extract the state of the batch of locks in one round trip
          # NOTE: (pipeline layout) [0] TIME (read locks are checked in redis time), then
          #   `LOCK_STATE_REPLIES` replies per lock in the batch order (the replies of the lock
          #   with the index N start at `1 + N * LOCK_STATE_REPLIES`): HGETALL (write lock),
          #   PTTL (write lock), ZRANGE WITHSCORES (readers registry);
          # @type var batch_state: Array[untyped]
          batch_state = redis_client.pipelined do |pipeline|
            pipeline.call('TIME')
            lock_keys_batch.each_with_index do |lock_key, index|
              lock_readers_key =
                RedisQueuedLocks::Resource.prepare_lock_readers(lock_names_batch[index])
              pipeline.call('HGETALL', lock_key)
              pipeline.call('PTTL', lock_key)
              pipeline.call('ZRANGE', lock_readers_key, '0', '-1', 'WITHSCORES')
            end
          end
          now = RedisQueuedLocks::Resource.redis_time_ms(batch_state[0])

          # Step 2: (RW) live read locks of the locks without a write lock
          #   (`nil` for the locks with a write lock: their read locks are not reported);
          # @type var live_read_locks: Array[Array[[String, Float]]?]
          live_read_locks = lock_keys_batch.each_with_index.map do |_lock_key, index|
            replies_at = 1 + (index * LOCK_STATE_REPLIES)
            # NOTE: `nil` when the write lock is alive (the key exists)
            next unless batch_state[replies_at].empty? || batch_state[replies_at + 1] == -2

            # @type var read_locks: Array[[String, Float]]
            read_locks = batch_state[replies_at + 2]
            read_locks.select { |(_acquirer_id, expiration)| expiration > now }
          end

          # Step 3: (RW) read lock data of the live read locks in one round trip
          # NOTE: (pipeline layout) one reply per live read lock in the lock and reader order;
          #   read lock data can be absent if it is dropped during the read lock life;
          # @type var read_locks_data: Array[Hash[String,String]]
          read_locks_data = redis_client.pipelined do |pipeline|
            lock_keys_batch.each_index do |index|
              live_read_locks[index]&.each do |(acquirer_id, _expiration)|
                pipeline.call(
                  'HGETALL',
                  RedisQueuedLocks::Resource.prepare_read_lock_key(
                    lock_names_batch[index], acquirer_id
                  )
                )
              end
            end
          end

          # Step 4: format the info of each lock and push it to the result store
          read_locks_data_at = 0
          lock_keys_batch.each_with_index do |lock_key, index|
            lock_live_read_locks = live_read_locks[index]

            # @type var lock_info: RedisQueuedLocks::Acquirer::Locks::lockInfo
            lock_info =
              if lock_live_read_locks
                # Step 4.Y: write lock is released
                # NOTE: (RW) read locks (or nothing if there are no live read locks)
                read_lock_info(
                  lock_key, now, lock_live_read_locks, read_locks_data, read_locks_data_at
                ) || {} #: Hash[String,String|Float|Integer]
              else
                # Step 4.Z: lock is alive => format received info + add additional rem_ttl info
                replies_at = 1 + (index * LOCK_STATE_REPLIES)
                # @type var hget_cmd_res: Hash[String,String|Float|Integer]
                hget_cmd_res = batch_state[replies_at] # NOTE: HGETALL result (hash)
                # @type var pttl_cmd_res: Integer
                pttl_cmd_res = batch_state[replies_at + 1] # NOTE: PTTL result (integer)

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
            read_locks_data_at += lock_live_read_locks.size if lock_live_read_locks

            seeded_locks << {
              lock: lock_key,
              status: (lock_info.empty? ? :released : :alive),
              info: lock_info
            }
          end
        end
      end
    end
    # rubocop:enable Metrics/MethodLength

    # Formats live read locks of the lock.
    #
    # NOTE: the same approach as in `LockInfo` (duplicated on purpose: operation modules are
    #   independent of each other, see `extract_locks_info`); the read lock data is extracted
    #   for the whole batch of locks in advance;
    #
    # @param lock_key [String]
    # @param now [Integer] Redis time (in milliseconds).
    # @param live_read_locks [Array<Array<String,Float>>] Live read locks (acquirer id, expiration).
    # @param read_locks_data [Array<Hash<String,String>>] Read lock data of the batch of locks.
    # @param read_locks_data_at [Integer] Position of the first read lock data of the lock.
    # @return [Hash<String,String|Numeric|Array<Hash<String,String|Numeric>>>,NilClass]
    #   - `nil` is returned when there are no live read locks;
    #   - each reader has the same data as the write lock (acq_id, hst_id, ts, ini_ttl, rem_ttl,
    #     meta, reentrant lock data);
    #
    # @api private
    # @since 1.18.0
    # @version 1.20.0
    # rubocop:disable Metrics/MethodLength
    def read_lock_info(lock_key, now, live_read_locks, read_locks_data, read_locks_data_at)
      return nil if live_read_locks.empty?

      longest_rem_ttl = 0
      readers = live_read_locks.each_with_index.map do |(acquirer_id, expiration), index|
        rem_ttl = (expiration - now).ceil
        longest_rem_ttl = rem_ttl if rem_ttl > longest_rem_ttl

        # NOTE: acquirer and host ids are not stored in the read lock data (both are derived from
        #   the acquirer id): they are the first fields like in the write lock info (read lock data
        #   of older versions contains them with the same values);
        # @type var reader: Hash[String,String|Float|Integer|nil]
        reader = {
          'acq_id' => acquirer_id,
          'hst_id' => RedisQueuedLocks::Resource.host_identifier_from_acquirer(acquirer_id)
        }
        read_locks_data[read_locks_data_at + index]&.each { |field, value| reader[field] = value }
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
