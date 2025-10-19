# frozen_string_literal: true

# @api private
# @since 1.16.0
module RedisQueuedLocks::Acquirer::ReleaseLocksOfAcquirer
  # @since 1.16.0
  extend RedisQueuedLocks::Utilities

  class << self
    # @param refused_acquirer_id [String]
    # @param redis [RedisClient]
    # @param lock_scan_size [Integer]
    # @param queue_scan_size [Integer]
    # @param logger [::Logger,#debug]
    # @param isntrumenter [#notify]
    # @param instrument [NilClass,Any]
    # @param log_sampling_enabled [Boolean]
    # @param log_sampling_percent [Integer]
    # @param log_sampler [#sampling_happened?,Module<RedisQueuedLocks::Logging::Sampler>]
    # @param log_sample_this [Boolean]
    # @param instr_sampling_enabled [Boolean]
    # @param instr_sampling_percent [Integer]
    # @param instr_sampler [#sampling_happened?,Module<RedisQueuedLocks::Instrument::Sampler>]
    # @param instr_sample_this [Boolean]
    # @return [Hash<Symbol,Boolean|Hash<Symbol,Integer>>]
    #
    # @api private
    # @since 1.16.0
    # rubocop:disable Metrics/MethodLength
    def release_locks_of_acquirer(
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
    )
      rel_start_time = clock_gettime

      fully_release_locks_of_acquirer(
        refused_acquirer_id,
        redis,
        lock_scan_size,
        queue_scan_size
      ) => { ok:, result: }

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
        instrumenter.notify('redis_queued_locks.release_locks_of_acquirer', {
          at: time_at,
          acq_id: refused_acquirer_id,
          rel_time: rel_time,
          rel_key_cnt: result[:rel_key_cnt],
          rel_req_cnt: result[:rel_req_cnt],
          tch_queue_cnt: result[:tch_queue_cnt]
        })
      end if instr_sampled

      {
        ok: true,
        result: {
          rel_key_cnt: result[:rel_key_cnt],
          rel_req_cnt: result[:rel_req_cnt],
          tch_queue_cnt: result[:tch_queue_cnt],
          rel_time: rel_time
        }
      }
    end
    # rubocop:enable Metrics/MethodLength

    private

    # @param refused_acquirer_id [String]
    # @param redis [RedisClient]
    # @param lock_scan_size [Integer]
    # @param queue_scan_size [Integer]
    # @return [Hash<Symbol,Bool|Hash<Symbol,Integer>>]
    #
    # @api private
    # @since 1.16.0
    # rubocop:disable Metrics/MethodLength
    def fully_release_locks_of_acquirer(
      refused_acquirer_id,
      redis,
      lock_scan_size,
      queue_scan_size
    )
      rel_key_cnt = 0
      tch_queue_cnt = 0
      rel_req_cnt = 0

      redis.with do |rconn|
        # Step A: drop locks of the passed acquirer
        refused_locks = Set.new #: Set[String]
        rconn.scan(
          'MATCH',
          RedisQueuedLocks::Resource::LOCK_PATTERN,
          count: lock_scan_size
        ) do |lock_key|
          acquirer_id = rconn.call('HMGET', lock_key, 'acq_id')
          if refused_acquirer_id == acquirer_id
            refused_locks << lock_key
          end

          if refused_locks.size >= lock_scan_size
            # NOTE: steep can not recognize the `*`-splat operator on Set objects
            rconn.call('DEL', *refused_locks) # steep:ignore
            rel_key_cnt += refused_locks.size
            refused_locks.clear
          end
        end

        if refused_locks.any?
          # NOTE: steep can not recognize the `*`-splat operator on Set objects
          rconn.call('DEL', *refused_locks) # steep:ignore
          rel_key_cnt += refused_locks.size
        end

        # Step B: drop passed acquirer from lock queues
        rconn.scan(
          'MATCH',
          RedisQueuedLocks::Resource::LOCK_QUEUE_PATTERN,
          count: queue_scan_size
        ) do |lock_queue|
          res = rconn.call('ZREM', lock_queue, refused_acquirer_id)
          rel_req_cnt += res
          tch_queue_cnt += 1 if res != 0
        end
      end

      { ok: true, result: { rel_key_cnt:, tch_queue_cnt:, rel_req_cnt: } }
    end
    # rubocop:enable Metrics/MethodLength
  end
end
