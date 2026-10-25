# frozen_string_literal: true

# @api private
# @since 1.0.0
# @version 1.21.0
# rubocop:disable Metrics/ModuleLength
module RedisQueuedLocks::Acquirer::ClearDeadRequests
  # @since 1.21.0
  extend RedisQueuedLocks::Utilities

  # rubocop:disable Metrics/ClassLength
  class << self
    # Drops dead lock requests (requests older than `dead_ttl`) from the lock queues (write and
    # read; the requests of any priority: see `RedisQueuedLocks::Resource::LOCK_PRIORITY_BAND`):
    #   - the disabled lock index: the lock queues found in one SCAN pass, two round trips per
    #     batch of `scan_size` lock queues (batches are collected across SCAN pages);
    #   - the enabled lock index: the lock queues of the locks of the lock index: one ZSCAN pass
    #     over the lock names (the keyspace is never scanned), two round trips per batch of
    #     `scan_size` lock names (both lock queues of each lock name); expired lock names are
    #     dropped from the lock index first;
    #   - the batch round trips: the lock requests of the batch queues are read, then the dead
    #     requests of each priority band that has them are dropped (only when dead requests exist,
    #     see `drop_dead_requests`);
    #   - the operation is reported with one log and one instrumentation event
    #     (`redis_queued_locks.clear_dead_requests`) with the time of the whole operation;
    #
    # @param redis_client [RedisClient]
    # @param scan_size [Integer]
    #   SCAN count and the number of lock queues in one batch (the disabled lock index) or ZSCAN
    #   count and the number of lock names in one batch (the enabled lock index).
    # @param dead_ttl [Integer] In milliseconds
    # @param lock_index_enabled [Boolean]
    #   Find lock queues via the lock index instead of the keyspace SCAN.
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
    # @return [Hash<Symbol,Boolean|Hash<Symbol,Set<String>>>]
    #
    # @api private
    # @since 1.0.0
    # @version 1.22.0
    # rubocop:disable Metrics/MethodLength
    def clear_dead_requests(
      redis_client,
      scan_size,
      dead_ttl,
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
      #   (`COUNT 0`) and the batching, a non-positive dead ttl drops all lock requests;
      if !scan_size.is_a?(::Integer) || scan_size <= 0
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:scan_size` argument should be a positive Integer, got #{scan_size.inspect}."
        )
      end
      if !dead_ttl.is_a?(::Integer) || dead_ttl <= 0
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:dead_ttl` argument should be a positive Integer, got #{dead_ttl.inspect}."
        )
      end

      rel_start_time = clock_gettime
      processed_queues = fully_clear_dead_requests(
        redis_client, scan_size, dead_ttl, lock_index_enabled
      )
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
          "[redis_queued_locks.clear_dead_requests] " \
          "dead_ttl => #{dead_ttl} " \
          "prc_queue_cnt => #{processed_queues.size} " \
          "rel_time => #{rel_time} " \
          "at => #{time_at}"
        end
      end if log_sampled

      run_non_critical do
        instrumenter.notify('redis_queued_locks.clear_dead_requests', {
          dead_ttl: dead_ttl,
          prc_queue_cnt: processed_queues.size,
          rel_time: rel_time,
          at: time_at,
          instrument: instrument
        })
      end if instr_sampled

      { ok: true, result: { processed_queues: } }
    end
    # rubocop:enable Metrics/MethodLength

    private

    # Drops dead lock requests from the lock queues (see `clear_dead_requests`).
    #
    # @param redis_client [RedisClient]
    # @param scan_size [Integer]
    # @param dead_ttl [Integer] In milliseconds
    # @param lock_index_enabled [Boolean]
    # @return [Set<String>] The processed lock queues (write and read lock request queues).
    #
    # @api private
    # @since 1.21.0
    def fully_clear_dead_requests(redis_client, scan_size, dead_ttl, lock_index_enabled)
      dead_score = RedisQueuedLocks::Resource.acquirer_dead_score(dead_ttl / 1_000.0)

      Set.new.tap do |processed_queues|
        # @type var processed_queues: Set[String]
        redis_client.with do |rconn|
          if lock_index_enabled
            # Step 1 (lock index): drop the expired lock names from the lock index
            #   (all their keys are expired);
            rconn.call(
              'ZREMRANGEBYSCORE', RedisQueuedLocks::Resource::LOCK_INDEX_KEY,
              '-inf', RedisQueuedLocks::Resource.lock_index_time - 1
            )

            # Step 2 (lock index): drop dead requests from the lock queues of the lock index
            each_lock_name_batch(rconn, scan_size) do |lock_names|
              drop_dead_requests_of_locks(rconn, lock_names, dead_score, processed_queues)
            end
          else
            # Step 1 (keyspace): drop dead requests from the lock queues found in one SCAN pass
            # NOTE: dead requests are dropped with one pipeline per batch of `scan_size` queues
            #   (batches are collected across SCAN pages: lock queues can be rare among other keys);
            # @type var lock_queues: Array[String]
            lock_queues = []

            each_lock_queue(rconn, scan_size) do |lock_queue|
              processed_queues << lock_queue
              lock_queues << lock_queue
              next if lock_queues.size < scan_size

              drop_dead_requests(rconn, lock_queues, dead_score)
              lock_queues.clear
            end

            drop_dead_requests(rconn, lock_queues, dead_score) unless lock_queues.empty?
          end
        end
      end
    end

    # Write and read lock queues in one SCAN pass (the disabled lock index).
    #
    # @param redis_client [RedisClient]
    # @param scan_size [Integer]
    # @yield [lock_queue]
    # @yieldparam lock_queue [String]
    # @yieldreturn [void]
    # @return [void]
    #
    # @api private
    # @since 1.0.0
    # @version 1.20.0
    def each_lock_queue(redis_client, scan_size)
      redis_client.scan(
        'MATCH',
        RedisQueuedLocks::Resource::ALL_LOCK_QUEUES_PATTERN,
        count: scan_size
      ) do |key|
        # NOTE: the pattern matches other keys too (lock names with `queue:`): lock queues only
        family = RedisQueuedLocks::Resource.lock_key_family(key)
        yield(key) if family == :lock_queue || family == :read_lock_queue
      end
    end

    # Drops dead requests of the given lock queues (both lookups):
    #   - the first round trip reads the lock requests of the lock queues;
    #   - the second round trip drops the dead requests of each priority band that has them: one
    #     `ZREMRANGEBYSCORE` per band from the lower edge of the band to its time barrier (see
    #     `RedisQueuedLocks::Resource::LOCK_PRIORITY_BAND`), so the number of commands depends on
    #     the bands of the queued requests, not on the priority range; no round trip without dead
    #     requests (an empty pipeline sends nothing);
    #   - the requests of a band are adjacent and ordered by the enqueue time (the bands are
    #     disjoint position ranges): the first request of a band decides whether the band has dead
    #     requests;
    #   - requests queued (or re-queued) between the round trips are never dropped: they are after
    #     the time barrier of their band;
    #
    # @param redis_client [RedisClient]
    # @param lock_queues [Array<String>]
    # @param dead_score [Float] Requests queued before this time are dead.
    # @return [Array<Array<Array<String,Float>>>]
    #   The lock requests (acquirer id, position) of each lock queue before the removal, in the
    #   order of `lock_queues` (an empty list for a missing lock queue).
    #
    # @api private
    # @since 1.20.0
    # @version 1.22.0
    def drop_dead_requests(redis_client, lock_queues, dead_score)
      # NOTE: (pipeline layout) one ZRANGE WITHSCORES per lock queue (the `lock_queues` order)
      # @type var queued_requests: Array[Array[[String, Float]]]
      queued_requests = redis_client.pipelined do |pipeline|
        lock_queues.each do |lock_queue|
          pipeline.call('ZRANGE', lock_queue, '0', '-1', 'WITHSCORES')
        end
      end

      redis_client.pipelined do |pipeline|
        lock_queues.each_with_index do |lock_queue, index|
          # @type var checked_band: Integer?
          checked_band = nil

          queued_requests[index].each do |lock_request|
            position = lock_request[1]
            priority = RedisQueuedLocks::Resource.lock_request_priority(position)
            next if priority == checked_band

            # NOTE: the first request of the band: the band has dead requests when it is dead
            checked_band = priority
            band_dead_score =
              RedisQueuedLocks::Resource.lock_priority_band_dead_score(dead_score, priority)
            next if position > band_dead_score

            pipeline.call(
              'ZREMRANGEBYSCORE', lock_queue,
              RedisQueuedLocks::Resource.lock_priority_band_floor(priority), band_dead_score
            )
          end
        end
      end

      queued_requests
    end

    # Drops dead requests of both lock queues of the given lock names (the enabled lock index; the
    # round trips of `drop_dead_requests`).
    #
    # @param redis_client [RedisClient]
    # @param lock_names [Array<String>]
    # @param dead_score [Float]
    # @param processed_queues [Set<String>] Collects the existing (processed) lock queues.
    # @return [void]
    #
    # @api private
    # @since 1.20.0
    # @version 1.22.0
    def drop_dead_requests_of_locks(redis_client, lock_names, dead_score, processed_queues)
      # NOTE: both lock queues of each lock name in the batch order (write, read)
      # @type var lock_queues: Array[String]
      lock_queues = []
      lock_names.each do |lock_name|
        lock_queues << RedisQueuedLocks::Resource.prepare_lock_queue(lock_name)
        lock_queues << RedisQueuedLocks::Resource.prepare_read_lock_queue(lock_name)
      end

      queued_requests = drop_dead_requests(redis_client, lock_queues, dead_score)

      # NOTE: a lock queue is processed when it exists (Redis never keeps empty sorted sets)
      lock_queues.each_with_index do |lock_queue, index|
        processed_queues << lock_queue unless queued_requests[index].empty?
      end
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
