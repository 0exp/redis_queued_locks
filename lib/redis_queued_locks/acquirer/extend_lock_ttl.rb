# frozen_string_literal: true

# @api private
# @since 1.0.0
# @version 1.21.0
# rubocop:disable Metrics/ModuleLength
module RedisQueuedLocks::Acquirer::ExtendLockTTL
  # @return [String]
  #
  # @api private
  # @since 1.0.0
  EXTEND_LOCK_PTTL = <<~LUA_SCRIPT.strip.tr("\n", '').freeze
    local new_lock_pttl = redis.call("PTTL", KEYS[1]) + ARGV[1];
    return redis.call("PEXPIRE", KEYS[1], new_lock_pttl);
  LUA_SCRIPT

  # @since 1.21.0
  extend RedisQueuedLocks::Utilities

  # rubocop:disable Metrics/ClassLength
  class << self
    # Extends the lock TTL and reports the operation (one log and one instrumentation event
    # `redis_queued_locks.extend_lock_ttl` with the time of the whole operation).
    #
    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @param milliseconds [Integer]
    #   How many milliseconds should be added: a positive Integer.
    # @param read_write_mode [Symbol]
    #   - `:write` - extends the write lock (of any acquirer);
    #   - `:read` - extends the read lock of the given acquirer (other read locks are not affected)
    #     or all live read locks of the lock (see `all_read_locks`);
    # @param all_read_locks [Boolean]
    #   Extend all live read locks of the lock instead of the read lock of the given acquirer
    #   (used for `:read` mode only, ignored for `:write` mode).
    # @param acquirer_id [String]
    #   The read lock acquirer (used for `:read` mode without `all_read_locks` only).
    # @param lock_index_enabled [Boolean]
    #   Increase the lock index score of the lock name by the extension (the enabled lock index).
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
    # @return [Hash<Symbol,Boolean|Symbol|Hash<Symbol,Integer>>]
    #
    # @api private
    # @since 1.0.0
    # @version 1.21.0
    # rubocop:disable Metrics/MethodLength
    def extend_lock_ttl(
      redis_client,
      lock_name,
      milliseconds,
      read_write_mode,
      all_read_locks,
      acquirer_id,
      lock_index_enabled,
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
      if read_write_mode != :read && read_write_mode != :write
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:read_write_mode` argument should be `:read` or `:write`, " \
          "got #{read_write_mode.inspect}."
        )
      end

      # NOTE: a non-positive value would decrease the lock ttl or delete the lock;
      if !milliseconds.is_a?(::Integer) || milliseconds <= 0
        raise(
          RedisQueuedLocks::ArgumentError,
          "`milliseconds` argument should be a positive Integer, got #{milliseconds.inspect}."
        )
      end

      if read_write_mode == :read && all_read_locks != true && all_read_locks != false
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:all_read_locks` argument should be a boolean, got #{all_read_locks.inspect}."
        )
      end

      lock_key = RedisQueuedLocks::Resource.prepare_lock_key(lock_name)

      ext_start_time = clock_gettime
      result = fully_extend_lock_ttl(
        redis_client, lock_name, lock_key, milliseconds, read_write_mode, all_read_locks,
        acquirer_id, lock_index_enabled
      )
      time_at = Time.now.to_f
      ext_end_time = clock_gettime
      ext_time = ((ext_end_time - ext_start_time) / 1_000.0).ceil(2)
      ext_result = result[:result]
      extended_locks_count = ext_result.is_a?(::Hash) ? ext_result[:extended_locks_count] : 0

      log_sampled = RedisQueuedLocks::Logging.should_log?(
        log_sampling_enabled,
        log_sample_this,
        log_sampling_percent,
        log_sampler
      )
      instr_sampled = RedisQueuedLocks::Instrument.should_instrument?(
        instr_sampling_enabled,
        instr_sample_this,
        instr_sampling_percent,
        instr_sampler
      )

      run_non_critical do
        logger.debug do
          "[redis_queued_locks.extend_lock_ttl] " \
          "lock_key => '#{lock_key}' " \
          "rw_mode => '#{read_write_mode}' " \
          "all_read_locks => #{all_read_locks} " \
          "ext_ttl => #{milliseconds} " \
          "extended_locks_count => #{extended_locks_count} " \
          "ext_time => #{ext_time} " \
          "at => #{time_at}"
        end
      end if log_sampled

      run_non_critical do
        instrumenter.notify('redis_queued_locks.extend_lock_ttl', {
          lock_key: lock_key,
          rw_mode: read_write_mode,
          all_read_locks: all_read_locks,
          ext_ttl: milliseconds,
          extended_locks_count: extended_locks_count,
          ext_time: ext_time,
          at: time_at,
          instrument: instrument
        })
      end if instr_sampled

      result
    end
    # rubocop:enable Metrics/MethodLength

    private

    # Extends the write lock, the read lock of the acquirer or all read locks of the lock.
    #
    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @param lock_key [String]
    # @param milliseconds [Integer]
    # @param read_write_mode [Symbol]
    # @param all_read_locks [Boolean]
    # @param acquirer_id [String]
    # @param lock_index_enabled [Boolean]
    # @return [Hash<Symbol,Boolean|Symbol|Hash<Symbol,Integer>>]
    #
    # @api private
    # @since 1.21.0
    # rubocop:disable Metrics/MethodLength
    def fully_extend_lock_ttl(
      redis_client,
      lock_name,
      lock_key,
      milliseconds,
      read_write_mode,
      all_read_locks,
      acquirer_id,
      lock_index_enabled
    )
      if read_write_mode == :read
        # NOTE: (RW) all live read locks of the lock
        if all_read_locks
          return extend_all_read_locks_ttl(
            redis_client, lock_name, lock_key, milliseconds, lock_index_enabled
          )
        end

        # NOTE: (RW) read lock of the concrete acquirer
        return extend_read_lock_ttl(
          redis_client, lock_name, lock_key, acquirer_id, milliseconds, lock_index_enabled
        )
      end

      # NOTE:
      #   - EVAL signature -> <lua script>, (number of keys), *(keys), *(arguments);
      #   - (lock index) the enabled lock index: the lock index score is increased by the extension
      #     in the same transaction (`ZADD XX INCR`: the upper bound of the lock lifetime stays
      #     the upper bound, locks without the index entry (of older RQL versions) are not indexed
      #     with a wrong score); a failed extension (no lock) increases the score of the lock name
      #     too: the name just stays in the index a bit longer;
      #   - the disabled lock index: one EVAL command (no transaction);
      # @type var extended: Integer
      extended =
        if lock_index_enabled
          # @type var result: [Integer, Float?]
          result = redis_client.multi do |transact|
            transact.call('EVAL', EXTEND_LOCK_PTTL, 1, lock_key, milliseconds)
            transact.call(
              'ZADD', RedisQueuedLocks::Resource::LOCK_INDEX_KEY,
              'XX', 'INCR', milliseconds, lock_name
            )
          end
          result[0]
        else
          redis_client.call('EVAL', EXTEND_LOCK_PTTL, 1, lock_key, milliseconds)
        end
      # TODO: upload scripts to the redis

      if extended == 1
        { ok: true, result: { extended_locks_count: 1 } }
      else
        { ok: false, result: :async_expire_or_no_lock }
      end
    end
    # rubocop:enable Metrics/MethodLength

    # Extends the live read lock of the acquirer:
    #   - the read lock expiration (readers registry score), the registry TTL and the read lock
    #     data TTL are extended;
    #   - the write lock key is watched: an expired read lock can be already replaced by a writer,
    #     so the expired (or replaced) read lock is never "revived";
    #
    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @param lock_key [String]
    # @param acquirer_id [String]
    # @param milliseconds [Integer]
    # @param lock_index_enabled [Boolean]
    # @return [Hash<Symbol,Boolean|Symbol|Hash<Symbol,Integer>>]
    #
    # @api private
    # @since 1.18.0
    # @version 1.21.0
    # rubocop:disable Metrics/MethodLength
    def extend_read_lock_ttl(
      redis_client,
      lock_name,
      lock_key,
      acquirer_id,
      milliseconds,
      lock_index_enabled
    )
      lock_readers_key = RedisQueuedLocks::Resource.prepare_lock_readers(lock_name)
      read_lock_key = RedisQueuedLocks::Resource.prepare_read_lock_key(lock_name, acquirer_id)

      result = redis_client.with do |rconn|
        rconn.multi(watch: [lock_key]) do |transact|
          # @type var lock_state: [Integer, Array[String], Float?]
          lock_state = rconn.pipelined do |pipeline|
            pipeline.call('EXISTS', lock_key)
            pipeline.call('TIME')
            pipeline.call('ZSCORE', lock_readers_key, acquirer_id)
          end
          redis_time = RedisQueuedLocks::Resource.redis_time_ms(lock_state[1])
          read_lock_expiration = lock_state[2].to_f

          # NOTE: no write lock and the read lock of the acquirer is alive
          if lock_state[0] == 0 && read_lock_expiration > redis_time
            extended_ttl = (read_lock_expiration + milliseconds - redis_time).ceil
            transact.call('ZADD', lock_readers_key, 'XX', 'INCR', milliseconds, acquirer_id)
            transact.call('PEXPIRE', lock_readers_key, extended_ttl, 'NX')
            transact.call('PEXPIRE', lock_readers_key, extended_ttl, 'GT')
            transact.call('PEXPIRE', read_lock_key, extended_ttl, 'NX')
            transact.call('PEXPIRE', read_lock_key, extended_ttl, 'GT')
            # NOTE: (lock index) the lock index score is increased by the extension
            #   (the enabled lock index only; the last command: its reply is not read);
            if lock_index_enabled
              transact.call(
                'ZADD', RedisQueuedLocks::Resource::LOCK_INDEX_KEY,
                'XX', 'INCR', milliseconds, lock_name
              )
            end
          end
        end
      rescue RedisQueuedLocks::LockAcquirementIntermediateTimeoutError,
             RedisQueuedLocks::TimedLockIntermediateTimeoutError
        # NOTE: (internal timeouts) an interrupted WATCH block: the closed connection drops
        #   the WATCH state (redis-client sends `UNWATCH` only on `StandardError`);
        rconn.close
        raise
      end

      # NOTE:
      #   - [] => there is no live read lock of the acquirer (nothing to extend);
      #   - nil => the write lock is changed during the extension (the read lock can be expired);
      #   - result[0] => the new read lock expiration (nil if the read lock is removed);
      if result.is_a?(::Array) && !result.empty? && result[0] != nil
        { ok: true, result: { extended_locks_count: 1 } }
      else
        { ok: false, result: :async_expire_or_no_lock }
      end
    end
    # rubocop:enable Metrics/MethodLength

    # Extends all live read locks of the lock (the same rules as for `extend_read_lock_ttl`):
    #   - each live read lock expiration (readers registry score) and its read lock data TTL are
    #     extended by the given milliseconds; the registry TTL is extended to the longest read lock;
    #   - expired read locks are not extended ("revived");
    #   - the write lock key is watched (a writer can replace the expired read locks), the registry
    #     is not watched: concurrent read lock acquirements/releases do not abort the extension
    #     (read locks obtained after the registry snapshot are not extended, read locks released
    #     after it are not revived cuz of `ZADD XX`);
    #
    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @param lock_key [String]
    # @param milliseconds [Integer]
    # @param lock_index_enabled [Boolean]
    # @return [Hash<Symbol,Boolean|Symbol|Hash<Symbol,Integer>>]
    #
    # @api private
    # @since 1.18.0
    # @version 1.21.0
    # rubocop:disable Metrics/MethodLength
    def extend_all_read_locks_ttl(
      redis_client,
      lock_name,
      lock_key,
      milliseconds,
      lock_index_enabled
    )
      lock_readers_key = RedisQueuedLocks::Resource.prepare_lock_readers(lock_name)
      extended_read_locks_count = 0

      result = redis_client.with do |rconn|
        rconn.multi(watch: [lock_key]) do |transact|
          # @type var lock_state: [Integer, Array[String], Array[[String, Float]]]
          lock_state = rconn.pipelined do |pipeline|
            pipeline.call('EXISTS', lock_key)
            pipeline.call('TIME')
            pipeline.call('ZRANGE', lock_readers_key, '0', '-1', 'WITHSCORES')
          end
          redis_time = RedisQueuedLocks::Resource.redis_time_ms(lock_state[1])

          # NOTE: no write lock => extend all live read locks
          if lock_state[0] == 0
            registry_ttl = 0

            lock_state[2].each do |(acquirer_id, read_lock_expiration)|
              next unless read_lock_expiration > redis_time

              read_lock_key =
                RedisQueuedLocks::Resource.prepare_read_lock_key(lock_name, acquirer_id)
              extended_ttl = (read_lock_expiration + milliseconds - redis_time).ceil
              registry_ttl = extended_ttl if extended_ttl > registry_ttl
              extended_read_locks_count += 1

              transact.call('ZADD', lock_readers_key, 'XX', 'INCR', milliseconds, acquirer_id)
              transact.call('PEXPIRE', read_lock_key, extended_ttl, 'NX')
              transact.call('PEXPIRE', read_lock_key, extended_ttl, 'GT')
            end

            if extended_read_locks_count > 0
              transact.call('PEXPIRE', lock_readers_key, registry_ttl, 'NX')
              transact.call('PEXPIRE', lock_readers_key, registry_ttl, 'GT')
              # NOTE: (lock index) the lock index score is increased by the extension
              #   (each read lock is extended by the same milliseconds; the enabled lock index
              #   only; the last command: its reply is not read);
              if lock_index_enabled
                transact.call(
                  'ZADD', RedisQueuedLocks::Resource::LOCK_INDEX_KEY,
                  'XX', 'INCR', milliseconds, lock_name
                )
              end
            end
          end
        end
      rescue RedisQueuedLocks::LockAcquirementIntermediateTimeoutError,
             RedisQueuedLocks::TimedLockIntermediateTimeoutError
        # NOTE: (internal timeouts) an interrupted WATCH block: the closed connection drops
        #   the WATCH state (redis-client sends `UNWATCH` only on `StandardError`);
        rconn.close
        raise
      end

      # NOTE:
      #   - [] => there are no live read locks (nothing to extend);
      #   - nil => the write lock is changed during the extension (read locks can be expired);
      #   - result[index * 3] => the new read lock expiration of each extended read lock
      #     (nil if the read lock is released during the extension => it is not counted);
      extended_locks_count =
        if result.is_a?(::Array)
          extended_read_locks_count.times.count { |index| result[index * 3] != nil }
        else
          0
        end

      if extended_locks_count > 0
        { ok: true, result: { extended_locks_count: } }
      else
        { ok: false, result: :async_expire_or_no_lock }
      end
    end
    # rubocop:enable Metrics/MethodLength
  end
  # rubocop:enable Metrics/ClassLength
end
# rubocop:enable Metrics/ModuleLength
