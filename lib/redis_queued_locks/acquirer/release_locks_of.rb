# frozen_string_literal: true

# @api private
# @since 1.14.0
# @version 1.20.0
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
    #   The number of lock keys that should be released in a time (and the SCAN count of
    #   the single SCAN pass over the lock keys and lock queues).
    #   Affects the RubyVM memmory (cuz each found lock will be temporary stored in memory for
    #   subsequent removal from redis in one query at a time).
    # @param queue_scan_size [Integer]
    #   The number of lock queues that should be processed removing an acquirer from them
    #   (in one round trip).
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
    #   - take an effect when <config['log_sampling_enalbed']> is true;
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
    #   - take an effect when <config['instr_sampling_enalbed']> is true;
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
    # @version 1.20.0
    # rubocop:disable Metrics/MethodLength
    def release_locks_of(
      refused_host_id,
      refused_acquirer_id,
      redis,
      lock_scan_size,
      queue_scan_size,
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
    ) # TODO: move from SCAN to indexes :thinking:
      rel_start_time = clock_gettime

      # steep:ignore:start
      fully_release_locks_of(
        refused_host_id,
        refused_acquirer_id,
        redis,
        lock_scan_size,
        queue_scan_size
      ) => { ok:, result: }
      # steep:ignore:end

      # @type var ok: bool
      # @type var result: Hash[Symbol,Integer]

      time_at = Time.now.to_f
      rel_end_time = clock_gettime
      rel_time = ((rel_end_time - rel_start_time) / 1_000.0).ceil(2)

      instr_sampled = RedisQueuedLocks::Instrument.should_instrument?(
        instr_sampling_enabled,
        instr_sample_this,
        instr_sampling_percent,
        instr_sampler
      )

      run_non_critical do
        instrumenter.notify('redis_queued_locks.release_locks_of', {
          at: time_at,
          hst_id: refused_host_id,
          acq_id: refused_acquirer_id,
          rel_time: rel_time,
          rel_key_cnt: result[:rel_key_cnt],
          tch_queue_cnt: result[:tch_queue_cnt]
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

    # One SCAN pass over the RQL keys (`KEY_PATTERN`): the found keys are processed in batches
    # with one round trip per batch (batches are collected across SCAN pages):
    #   - write locks of the passed acquirer (`lock_scan_size` locks per batch);
    #   - (RW) read locks of the passed acquirer (`lock_scan_size` readers registries per batch);
    #   - requests of the passed acquirer in the lock queues (`queue_scan_size` queues per batch);
    #
    # @param refused_host_id [String]
    # @param refused_acquirer_id [String]
    # @param redis [RedisClient]
    # @param lock_scan_size [Integer] SCAN count and the batch size of locks.
    # @param queue_scan_size [Integer] The batch size of lock queues.
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
      queue_scan_size
    )
      # TODO: some indexing approach isntead of <scan>
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

            rel_key_cnt += release_refused_read_locks(rconn, lock_readers_keys, refused_acquirer_id)
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
          rel_key_cnt += release_refused_read_locks(rconn, lock_readers_keys, refused_acquirer_id)
        end
        unless lock_queues.empty?
          tch_queue_cnt += dequeue_refused_acquirer(rconn, lock_queues, refused_acquirer_id)
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
  end
  # rubocop:enable Metrics/ClassLength
end
# rubocop:enable Metrics/ModuleLength
