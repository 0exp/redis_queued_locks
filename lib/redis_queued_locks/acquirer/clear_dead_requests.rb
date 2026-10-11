# frozen_string_literal: true

# @api private
# @since 1.0.0
module RedisQueuedLocks::Acquirer::ClearDeadRequests
  class << self
    # @param redis_client [RedisClient]
    # @param scan_size [Integer]
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

      { ok: true, result: { processed_queues: result } }
    end

    private

    # Write and read lock queues in one SCAN pass.
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

    # Drops dead requests of the given lock queues in one round trip.
    #
    # @param redis_client [RedisClient]
    # @param lock_queues [Array<String>]
    # @param dead_score [Float]
    # @return [void]
    #
    # @api private
    # @since 1.20.0
    def drop_dead_requests(redis_client, lock_queues, dead_score)
      redis_client.pipelined do |pipeline|
        lock_queues.each do |lock_queue|
          pipeline.call('ZREMRANGEBYSCORE', lock_queue, '-inf', dead_score)
        end
      end
    end
  end
end
