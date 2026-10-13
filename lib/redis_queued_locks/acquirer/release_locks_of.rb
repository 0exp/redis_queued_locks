# frozen_string_literal: true

# @api private
# @since 1.14.0
# @version 1.21.0
# rubocop:disable Metrics/ModuleLength
module RedisQueuedLocks::Acquirer::ReleaseLocksOf
  # @since 1.14.0
  extend RedisQueuedLocks::Utilities

  # rubocop:disable Metrics/ClassLength
  class << self
    # Release all queues and locks (write locks and read locks) that belong to the given host
    # and its associated acquirer.
    #
    # @param refused_host_id [String]
    #   A host whose locks and queues should be released.
    # @param refused_acquirer_id [String]
    #   An acquirer (of the passed host) whose locks and queues should be released.
    # @param redis [RedisClient]
    #   Redis connection client.
    # @param lock_scan_size [Integer]
    #   The number of lock keys (the disabled lock index: the SCAN count of the single SCAN pass
    #   over the lock keys and lock queues) or locks (lock names, the enabled lock index: the ZSCAN
    #   count of the single ZSCAN pass over the lock index) that should be processed in a time.
    #   Affects the RubyVM memmory (cuz each found lock will be temporary stored in memory for
    #   subsequent removal from redis in one query at a time).
    # @param queue_scan_size [Integer]
    #   The number of lock queues that should be processed removing an acquirer from them
    #   (in one round trip).
    # @param lock_index_enabled [Boolean]
    #   Find locks via the lock index instead of the keyspace SCAN.
    # @param logger [::Logger,#debug]
    #   - Logger object used from `configuration` layer (see config['logger']);
    #   - See RedisQueuedLocks::Logging::VoidLogger for example;
    # @param instrumenter [#notify]
    #   See RedisQueuedLocks::Instrument::ActiveSupport for example.
    # @param instrument [NilClass,Any]
    #    - Custom instrumentation data wich will be passed to the instrumenter's payload
    #      with :instrument key;
    # @param log_sampling_enabled [Boolean]
    #   - enables <log sampling>: only the configured percent of RQL cases will be logged;
    #   - disabled by default;
    #   - works in tandem with <config['log_sampling_percent']> and <config['log_sampler']>;
    # @param log_sampling_percent [Integer]
    #   - the percent of cases that should be logged;
    #   - take an effect when <config['log_sampling_enabled']> is true;
    #   - works in tandem with <config['log_sampling_enabled']> and <config['log_sampler']> configs;
    # @param log_sampler [#sampling_happened?,Module<RedisQueuedLocks::Logging::Sampler>]
    #   - percent-based log sampler that decides should be RQL case logged or not;
    #   - works in tandem with <config['log_sampling_enabled']> and
    #     <config['log_sampling_percent']> configs;
    #   - based on the ultra simple percent-based (weight-based) algorithm that uses
    #     SecureRandom.rand method so the algorithm error is ~(0%..13%);
    #   - you can provide your own log sampler with bettter algorithm that should realize
    #     `sampling_happened?(percent) => boolean` interface
    #     (see `RedisQueuedLocks::Logging::Sampler` for example);
    # @param log_sample_this [Boolean]
    #   - marks the method that everything should be logged despite the enabled log sampling;
    #   - makes sense when log sampling is enabled;
    # @param instr_sampling_enabled [Boolean]
    #   - enables <instrumentaion sampling>: only the configured percent
    #     of RQL cases will be instrumented;
    #   - disabled by default;
    #   - works in tandem with <config['instr_sampling_percent']> and <config['instr_sampler']>;
    # @param instr_sampling_percent [Integer]
    #   - the percent of cases that should be instrumented;
    #   - take an effect when <config['instr_sampling_enabled']> is true;
    #   - works in tandem with <config['instr_sampling_enabled']>
    #     and <config['instr_sampler']> configs;
    # @param instr_sampler [#sampling_happened?,Module<RedisQueuedLocks::Instrument::Sampler>]
    #   - percent-based log sampler that decides should be RQL case instrumented or not;
    #   - works in tandem with <config['instr_sampling_enabled']> and
    #     <config['instr_sampling_percent']> configs;
    #   - based on the ultra simple percent-based (weight-based) algorithm that uses
    #     SecureRandom.rand method so the algorithm error is ~(0%..13%);
    #   - you can provide your own log sampler with bettter algorithm that should realize
    #     `sampling_happened?(percent) => boolean` interface
    #     (see `RedisQueuedLocks::Instrument::Sampler` for example);
    # @param instr_sample_this [Boolean]
    #   - marks the method that everything should be instrumneted
    #     despite the enabled instrumentation sampling;
    #   - makes sense when instrumentation sampling is enabled;
    # @return [Hash<Symbol,Any>]
    #   Format: {
    #     ok: true,
    #     result: {
    #       rel_key_cnt: Integer,
    #       tch_queue_cnt: Integer,
    #       rel_time: Numeric
    #     }
    #   }
    #
    # @api private
    # @since 1.14.0
    # @version 1.21.0
    # rubocop:disable Metrics/MethodLength
    def release_locks_of(
      refused_host_id,
      refused_acquirer_id,
      redis,
      lock_scan_size,
      queue_scan_size,
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
      # NOTE: (arguments) the same ranges as the config keys: zero/negative sizes fail SCAN/ZSCAN
      #   (`COUNT 0`) and the batching (`each_slice(0)`);
      if !lock_scan_size.is_a?(::Integer) || lock_scan_size <= 0
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:lock_scan_size` argument should be a positive Integer, got #{lock_scan_size.inspect}."
        )
      end
      if !queue_scan_size.is_a?(::Integer) || queue_scan_size <= 0
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:queue_scan_size` argument should be a positive Integer, " \
          "got #{queue_scan_size.inspect}."
        )
      end

      rel_start_time = clock_gettime

      # steep:ignore:start
      fully_release_locks_of(
        refused_host_id,
        refused_acquirer_id,
        redis,
        lock_scan_size,
        queue_scan_size,
        lock_index_enabled
      ) => { ok:, result: }
      # steep:ignore:end

      # @type var ok: bool
      # @type var result: Hash[Symbol,Integer]

      time_at = Time.now.to_f
      rel_end_time = clock_gettime
      rel_time = ((rel_end_time - rel_start_time) / 1_000.0).ceil(2)

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
          "[redis_queued_locks.release_locks_of] " \
          "at => #{time_at} " \
          "hst_id => '#{refused_host_id}' " \
          "acq_id => '#{refused_acquirer_id}' " \
          "rel_time => #{rel_time} " \
          "rel_key_cnt => #{result[:rel_key_cnt]} " \
          "tch_queue_cnt => #{result[:tch_queue_cnt]}"
        end
      end if log_sampled

      run_non_critical do
        instrumenter.notify('redis_queued_locks.release_locks_of', {
          at: time_at,
          hst_id: refused_host_id,
          acq_id: refused_acquirer_id,
          rel_time: rel_time,
          rel_key_cnt: result[:rel_key_cnt],
          tch_queue_cnt: result[:tch_queue_cnt],
          instrument: instrument
        })
      end if instr_sampled

      {
        ok: true,
        result: {
          rel_key_cnt: result[:rel_key_cnt],
          tch_queue_cnt: result[:tch_queue_cnt],
          rel_time: rel_time
        }
      }
    end
    # rubocop:enable Metrics/MethodLength

    private

    # Releases the locks and the lock requests of the passed host/acquirer found in one pass:
    #   - the disabled lock index: one SCAN pass over the RQL keys (`KEY_PATTERN`): the found keys
    #     are processed in batches with one round trip per batch (batches are collected across
    #     SCAN pages);
    #   - the enabled lock index: one ZSCAN pass over the lock index (`LOCK_INDEX_KEY`: lock names,
    #     the keyspace is never scanned): the keys of each batch of `lock_scan_size` lock names are
    #     derived from the lock names and processed with one round trip per key family and batch;
    #     the lock names stay in the lock index (other keys of the locks can exist);
    # Batches:
    #   - write locks of the passed acquirer (`lock_scan_size` locks per batch);
    #   - (RW) read locks of the passed acquirer (`lock_scan_size` readers registries per batch);
    #   - requests of the passed acquirer in the lock queues (`queue_scan_size` queues per batch);
    #
    # @param refused_host_id [String]
    # @param refused_acquirer_id [String]
    # @param redis [RedisClient]
    # @param lock_scan_size [Integer]
    #   SCAN count and the batch size of locks (the disabled lock index) or ZSCAN count and
    #   the batch size of locks (lock names, the enabled lock index).
    # @param queue_scan_size [Integer] The batch size of lock queues.
    # @param lock_index_enabled [Boolean]
    # @return [Hash<Symbol,Boolean|Hash<Symbol,Integer>>]
    #   - Example: { ok: true, result: { rel_key_cnt: 12345, tch_queue_cnt: 321 } }
    #
    # @api private
    # @since 1.14.0
    # @version 1.20.0
    # rubocop:disable Metrics/MethodLength
    def fully_release_locks_of(
      refused_host_id,
      refused_acquirer_id,
      redis,
      lock_scan_size,
      queue_scan_size,
      lock_index_enabled
    )
      rel_key_cnt = 0
      tch_queue_cnt = 0
      # NOTE: (RW) read locks store acquirer ids only (the host is a part of the acquirer id),
      #   so they are released only when the passed acquirer belongs to the passed host;
      with_read_locks =
        RedisQueuedLocks::Resource.host_identifier_from_acquirer(refused_acquirer_id) ==
        refused_host_id

      redis.with do |rconn|
        # @type var lock_keys: Array[String]
        lock_keys = []
        # @type var lock_readers_keys: Array[String]
        lock_readers_keys = []
        # @type var lock_queues: Array[String]
        lock_queues = []

        if lock_index_enabled
          # NOTE: (lock index) the keys of each batch of lock names are derived from the lock names
          each_lock_name_batch(rconn, lock_scan_size) do |lock_names|
            lock_names.each do |lock_name|
              lock_keys << RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
              if with_read_locks
                lock_readers_keys << RedisQueuedLocks::Resource.prepare_lock_readers(lock_name)
              end
              lock_queues << RedisQueuedLocks::Resource.prepare_lock_queue(lock_name)
              lock_queues << RedisQueuedLocks::Resource.prepare_read_lock_queue(lock_name)
            end

            # Step A: drop locks of the passed host/acquirer
            rel_key_cnt += release_refused_locks(
              rconn, lock_keys, refused_host_id, refused_acquirer_id
            )
            # Step A (RW): drop read locks of the passed host/acquirer
            unless lock_readers_keys.empty?
              rel_key_cnt += release_refused_read_locks(
                rconn, lock_readers_keys, refused_acquirer_id
              )
            end
            # Step B: drop passed host/acquirer from lock queues (write and read)
            lock_queues.each_slice(queue_scan_size) do |lock_queues_batch|
              tch_queue_cnt += dequeue_refused_acquirer(
                rconn, lock_queues_batch, refused_acquirer_id
              )
            end

            lock_keys.clear
            lock_readers_keys.clear
            lock_queues.clear
          end
        else
          # NOTE: (keyspace) the found keys are collected into batches by their key families
          rconn.scan(
            'MATCH',
            RedisQueuedLocks::Resource::KEY_PATTERN,
            count: lock_scan_size
          ) do |key|
            case RedisQueuedLocks::Resource.lock_key_family(key)
            when :lock
              # Step A: drop locks of the passed host/acquirer
              lock_keys << key
              next if lock_keys.size < lock_scan_size

              rel_key_cnt += release_refused_locks(
                rconn, lock_keys, refused_host_id, refused_acquirer_id
              )
              lock_keys.clear
            when :lock_readers
              # Step A (RW): drop read locks of the passed host/acquirer
              next unless with_read_locks

              lock_readers_keys << key
              next if lock_readers_keys.size < lock_scan_size

              rel_key_cnt += release_refused_read_locks(
                rconn, lock_readers_keys, refused_acquirer_id
              )
              lock_readers_keys.clear
            when :lock_queue, :read_lock_queue
              # Step B: drop passed host/acquirer from lock queues (write and read)
              lock_queues << key
              next if lock_queues.size < queue_scan_size

              tch_queue_cnt += dequeue_refused_acquirer(rconn, lock_queues, refused_acquirer_id)
              lock_queues.clear
            end
          end

          unless lock_keys.empty?
            rel_key_cnt += release_refused_locks(
              rconn, lock_keys, refused_host_id, refused_acquirer_id
            )
          end
          unless lock_readers_keys.empty?
            rel_key_cnt += release_refused_read_locks(
              rconn, lock_readers_keys, refused_acquirer_id
            )
          end
          unless lock_queues.empty?
            tch_queue_cnt += dequeue_refused_acquirer(rconn, lock_queues, refused_acquirer_id)
          end
        end
      end

      { ok: true, result: { rel_key_cnt:, tch_queue_cnt: } }
    end
    # rubocop:enable Metrics/MethodLength

    # Drops the locks of the passed host/acquirer from the given batch of write locks
    # (two round trips: lock owners, then one `DEL` of the refused locks).
    #
    # @param redis_client [RedisClient]
    # @param lock_keys [Array<String>]
    # @param refused_host_id [String]
    # @param refused_acquirer_id [String]
    # @return [Integer] The number of the refused locks.
    #
    # @api private
    # @since 1.20.0
    def release_refused_locks(redis_client, lock_keys, refused_host_id, refused_acquirer_id)
      # NOTE: (pipeline layout) one reply (acquirer and host) per lock in the batch order
      # @type var lock_owners: Array[[String?, String?]]
      lock_owners = redis_client.pipelined do |pipeline|
        lock_keys.each { |lock_key| pipeline.call('HMGET', lock_key, 'acq_id', 'hst_id') }
      end

      # @type var refused_locks: Array[String]
      refused_locks = []
      lock_keys.each_with_index do |lock_key, index|
        acquirer_id, host_id = lock_owners[index]
        if refused_host_id == host_id && refused_acquirer_id == acquirer_id
          refused_locks << lock_key
        end
      end
      return 0 if refused_locks.empty?

      redis_client.call('DEL', *refused_locks)
      refused_locks.size
    end

    # (RW) Drops the read locks of the passed acquirer from the given batch of readers registries
    # in one round trip: `ZREM` of the acquirer and `DEL` of its read lock data for each registry
    # (the read lock data is a data carrier only: `DEL` of an absent data is a no-op).
    #
    # @param redis_client [RedisClient]
    # @param lock_readers_keys [Array<String>]
    # @param refused_acquirer_id [String]
    # @return [Integer] The number of the dropped read locks.
    #
    # @api private
    # @since 1.20.0
    def release_refused_read_locks(redis_client, lock_readers_keys, refused_acquirer_id)
      # NOTE: (pipeline layout) two replies per registry in the batch order: ZREM, DEL
      # @type var replies: Array[Integer]
      replies = redis_client.pipelined do |pipeline|
        lock_readers_keys.each do |lock_readers_key|
          pipeline.call('ZREM', lock_readers_key, refused_acquirer_id)
          pipeline.call(
            'DEL',
            RedisQueuedLocks::Resource.prepare_read_lock_key(
              RedisQueuedLocks::Resource.lock_name_from_readers(lock_readers_key),
              refused_acquirer_id
            )
          )
        end
      end

      released = 0
      replies.each_slice(2) { |(zrem_cmd_res, _del_cmd_res)| released += 1 if zrem_cmd_res != 0 }
      released
    end

    # Drops the requests of the passed acquirer from the given batch of lock queues
    # (write and read) in one round trip.
    #
    # @param redis_client [RedisClient]
    # @param lock_queues [Array<String>]
    # @param refused_acquirer_id [String]
    # @return [Integer] The number of the touched lock queues.
    #
    # @api private
    # @since 1.20.0
    def dequeue_refused_acquirer(redis_client, lock_queues, refused_acquirer_id)
      # @type var replies: Array[Integer]
      replies = redis_client.pipelined do |pipeline|
        lock_queues.each { |lock_queue| pipeline.call('ZREM', lock_queue, refused_acquirer_id) }
      end
      replies.count { |zrem_cmd_res| zrem_cmd_res != 0 }
    end

    # Iterates over the lock names of the lock index (one ZSCAN pass) in batches of `scan_size`
    # lock names (batches are collected across ZSCAN pages). Expired lock names (not dropped from
    # the index yet) are skipped: all their keys are expired.
    #
    # NOTE: each operation module iterates over the lock index by itself (duplicated on purpose:
    #   operation modules are independent of each other, see `Locks.each_lock_name_batch`);
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
  end
  # rubocop:enable Metrics/ClassLength
end
# rubocop:enable Metrics/ModuleLength
