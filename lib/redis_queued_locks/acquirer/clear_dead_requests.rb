# frozen_string_literal: true

# @api private
# @since 1.0.0
# @version 1.20.0
module RedisQueuedLocks::Acquirer::ClearDeadRequests
  class << self
    # Drops dead lock requests (requests older than `dead_ttl`) from the lock queues (write and
    # read) of the locks of the lock index: one ZSCAN pass over the lock names (the keyspace is
    # never scanned), one round trip per batch of `scan_size` lock names (both lock queues of each
    # lock name). Expired lock names are dropped from the lock index first.
    #
    # @param redis_client [RedisClient]
    # @param scan_size [Integer] ZSCAN count and the number of lock names in one batch.
    # @param dead_ttl [Integer] In milliseconds
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
    # @version 1.20.0
    def clear_dead_requests(
      redis_client,
      scan_size,
      dead_ttl,
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
      dead_score = RedisQueuedLocks::Resource.acquirer_dead_score(dead_ttl / 1_000.0)

      # @type var result: Set[String]
      result = Set.new.tap do |processed_queues|
        # @type var processed_queues: Set[String]
        redis_client.with do |rconn|
          # Step 1: drop the expired lock names from the lock index (all their keys are expired)
          rconn.call(
            'ZREMRANGEBYSCORE', RedisQueuedLocks::Resource::LOCK_INDEX_KEY,
            '-inf', RedisQueuedLocks::Resource.lock_index_time - 1
          )

          # Step 2: drop dead requests from the lock queues of the lock index
          each_lock_name_batch(rconn, scan_size) do |lock_names|
            drop_dead_requests(rconn, lock_names, dead_score, processed_queues)
          end
        end
      end

      { ok: true, result: { processed_queues: result } }
    end

    private

    # Drops dead requests of both lock queues of the given lock names in one round trip.
    #
    # @param redis_client [RedisClient]
    # @param lock_names [Array<String>]
    # @param dead_score [Float]
    # @param processed_queues [Set<String>] Collects the existing (processed) lock queues.
    # @return [void]
    #
    # @api private
    # @since 1.20.0
    def drop_dead_requests(redis_client, lock_names, dead_score, processed_queues)
      # NOTE: (pipeline layout) two replies per lock queue (two lock queues per lock name) in
      #   the batch order: EXISTS (the queue is processed when it exists), ZREMRANGEBYSCORE;
      # @type var replies: Array[Integer]
      replies = redis_client.pipelined do |pipeline|
        lock_names.each do |lock_name|
          lock_queue = RedisQueuedLocks::Resource.prepare_lock_queue(lock_name)
          read_lock_queue = RedisQueuedLocks::Resource.prepare_read_lock_queue(lock_name)
          pipeline.call('EXISTS', lock_queue)
          pipeline.call('ZREMRANGEBYSCORE', lock_queue, '-inf', dead_score)
          pipeline.call('EXISTS', read_lock_queue)
          pipeline.call('ZREMRANGEBYSCORE', read_lock_queue, '-inf', dead_score)
        end
      end

      lock_names.each_with_index do |lock_name, index|
        if replies[index * 4] == 1
          processed_queues << RedisQueuedLocks::Resource.prepare_lock_queue(lock_name)
        end
        if replies[(index * 4) + 2] == 1
          processed_queues << RedisQueuedLocks::Resource.prepare_read_lock_queue(lock_name)
        end
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
end
