# frozen_string_literal: true

# @api private
# @since 1.14.0
module RedisQueuedLocks::Acquirer::ReleaseLocksOf
  # @since 1.14.0
  extend RedisQueuedLocks::Utilities

  class << self
    # Release all queues and locks that belong to the given host and its associated acquirer.
    #
    # @param refused_host_id [String]
    #   A host whose locks and queues should be released.
    # @param refused_acquirer_id [String]
    #   An acquirer (of the passed host) whose locks and queues should be released.
    # @param redis [RedisClient]
    #   Redis connection client.
    # @param lock_scan_size [Integer]
    #   The number of lock keys that should be released in a time.
    #   Affects the RubyVM memmory (cuz each found lock will be temporary stored in memory for
    #   subsequent removal from redis in one query at a time).
    # @param queue_scan_size [Integer]
    #   The number of lock queues that should be scanned removing an acquirer from them (at a time).
    # @param logger [::Logger,#debug]
    #   - Logger object used from `configuration` layer (see config['logger']);
    #   - See RedisQueuedLocks::Logging::VoidLogger for example;
    # @param isntrumenter [#notify]
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
    #   Format: { ok: true, result: Hash<Symbol,Numeric> }
    #
    # @api private
    # @since 1.14.0
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

    # @param refused_host_id [String]
    # @param refused_acquirer_id [String]
    # @param redis [RedisClient]
    # @param lock_scan_size [Integer]
    # @param queue_scan_size [Integer]
    # @return [Hash<Symbol,Boolean|Hash<Symbol,Integer>>]
    #   - Example: { ok: true, result: { rel_key_cnt: 12345, tch_queue_cnt: 321 } }
    #
    # @api private
    # @since 1.14.0
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

      redis.with do |rconn|
        # Step A: drop locks of the passed host/acquirer
        refused_locks = Set.new #: Set[String]
        rconn.scan(
          'MATCH',
          RedisQueuedLocks::Resource::LOCK_PATTERN,
          count: lock_scan_size
        ) do |lock_key|
          acquirer_id, host_id = rconn.call('HMGET', lock_key, 'acq_id', 'hst_id')
          if refused_host_id == host_id && refused_acquirer_id == acquirer_id
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

        # Step B: drop passed host/acquirer from lock queues
        rconn.scan(
          'MATCH',
          RedisQueuedLocks::Resource::LOCK_QUEUE_PATTERN,
          count: queue_scan_size
        ) do |lock_queue|
          res = rconn.call('ZREM', lock_queue, refused_acquirer_id)
          tch_queue_cnt += 1 if res != 0
        end
      end

      { ok: true, result: { rel_key_cnt:, tch_queue_cnt: } }
    end
  end
  # rubocop:enable Metrics/MethodLength
end
