# frozen_string_literal: true

# @api public
# @since 1.0.0
# rubocop:disable Metrics/ClassLength
class RedisQueuedLocks::Client
  # @since 1.0.0
  include Qonfig::Configurable

  configuration do
    setting :retry_count, 3
    setting :retry_delay, 200 # NOTE: in milliseconds
    setting :retry_jitter, 25 # NOTE: in milliseconds
    setting :try_to_lock_timeout, 10 # NOTE: in seconds
    setting :default_lock_ttl, 5_000 # NOTE: in milliseconds
    setting :default_queue_ttl, 15 # NOTE: in seconds
    setting :lock_release_batch_size, 100
    setting :key_extraction_batch_size, 500
    setting :instrumenter, RedisQueuedLocks::Instrument::VoidNotifier
    setting :uniq_identifier, -> { RedisQueuedLocks::Resource.calc_uniq_identity }
    setting :logger, RedisQueuedLocks::Logging::VoidLogger
    setting :log_lock_try, false
    setting :dead_request_ttl, (1 * 24 * 60 * 60 * 1000) # NOTE: 1 day in milliseconds
    setting :is_timed_by_default, false
    setting :default_conflict_strategy, :wait_for_lock
    setting :default_access_strategy, :queued
    setting :log_sampling_enabled, false
    setting :log_sampling_percent, 15
    setting :log_sampler, RedisQueuedLocks::Logging::Sampler
    setting :instr_sampling_enabled, false
    setting :instr_sampling_percent, 15
    setting :instr_sampler, RedisQueuedLocks::Instrument::Sampler

    validate('retry_count') { |val| val == nil || (val.is_a?(::Integer) && val >= 0) }
    validate('retry_delay') { |val| val.is_a?(::Integer) && val >= 0 }
    validate('retry_jitter') { |val| val.is_a?(::Integer) && val >= 0 }
    validate('try_to_lock_timeout') { |val| val == nil || (val.is_a?(::Integer) && val >= 0) }
    validate('default_lock_tt', :integer)
    validate('default_queue_ttl', :integer)
    validate('lock_release_batch_size', :integer)
    validate('instrumenter') { |val| RedisQueuedLocks::Instrument.valid_interface?(val) }
    validate('uniq_identifier', :proc)
    validate('logger') { |val| RedisQueuedLocks::Logging.valid_interface?(val) }
    validate('log_lock_try', :boolean)
    validate('dead_request_ttl') { |val| val.is_a?(::Integer) && val > 0 }
    validate('is_timed_by_default', :boolean)
    validate('log_sampler') { |val| RedisQueuedLocks::Logging.valid_sampler?(val) }
    validate('log_sampling_enabled', :boolean)
    validate('log_sampling_percent') { |val| val.is_a?(::Integer) && val >= 0 && val <= 100 }
    validate('instr_sampling_enabled', :boolean)
    validate('instr_sampling_percent') { |val| val.is_a?(::Integer) && val >= 0 && val <= 100 }
    validate('instr_sampler') { |val| RedisQueuedLocks::Instrument.valid_sampler?(val) }
    validate('default_conflict_strategy') do |val|
      # rubocop:disable Layout/MultilineOperationIndentation
      val == :work_through ||
      val == :extendable_work_through ||
      val == :wait_for_lock ||
      val == :dead_locking
      # rubocop:enable Layout/MultilineOperationIndentation
    end
    validate('default_access_strategy') do |val|
      # rubocop:disable Layout/MultilineOperationIndentation
      val == :queued ||
      val == :random
      # SOON: val == :lifo
      # SOON: val == :barrier
      # rubocop:enable Layout/MultilineOperationIndentation
    end
  end

  # @return [RedisClient]
  #
  # @api private
  # @since 1.0.0
  attr_reader :redis_client

  # NOTE: attr_access here is chosen intentionally in order to have an ability to change
  #  uniq_identity value for debug purposes in runtime;
  # @return [String]
  #
  # @api private
  # @since 1.0.0
  attr_accessor :uniq_identity

  # @param redis_client [RedisClient]
  #   Redis connection manager, which will be used for the lock acquierment and distribution.
  #   It should be an instance of RedisClient.
  # @param configs [Block]
  #   Custom configs for in-runtime configuration.
  # @return [void]
  #
  # @api public
  # @since 1.0.0
  def initialize(redis_client, &configs)
    configure(&configs)
    @uniq_identity = config[:uniq_identifier].call
    @redis_client = redis_client
  end

  # @param lock_name [String]
  #   Lock name to be obtained.
  # @option ttl [Integer]
  #   Lock's time to live (in milliseconds).
  # @option queue_ttl [Integer]
  #   Lifetime of the acuier's lock request. In seconds.
  # @option timeout [Integer,NilClass]
  #   Time period whe should try to acquire the lock (in seconds). Nil means "without timeout".
  # @option timed [Boolean]
  #   Limit the invocation time period of the passed block of code by the lock's TTL.
  # @option retry_count [Integer,NilClass]
  #   How many times we should try to acquire a lock. Nil means "infinite retries".
  # @option retry_delay [Integer]
  #   A time-interval between the each retry (in milliseconds).
  # @option retry_jitter [Integer]
  #   Time-shift range for retry-delay (in milliseconds).
  # @option raise_errors [Boolean]
  #   Raise errors on library-related limits such as timeout or failed lock obtain.
  # @option identity [String]
  #   Unique acquire identifier that is also should be unique between processes and pods
  #   on different machines. By default the uniq identity string is
  #   represented as 10 bytes hexstr.
  # @option fail_fast [Boolean]
  #   - Should the required lock to be checked before the try and exit immidietly if lock is
  #   already obtained;
  #   - Should the logic exit immidietly after the first try if the lock was obtained
  #   by another process while the lock request queue was initially empty;
  # @option conflict_strategy [Symbol]
  #   - The conflict strategy mode for cases when the process that obtained the lock
  #     want to acquire this lock again;
  #   - By default uses `:wait_for_lock` strategy;
  #   - pre-confured in `config[:default_conflict_strategy]`;
  #   - Supports:
  #     - `:work_through` - continue working under the lock without lock's TTL extension;
  #     - `:extendable_work_through` - continue working under the lock with lock's TTL extension;
  #     - `:wait_for_lock` - (default) - work in classic way
  #       (with timeouts, retry delays, retry limits, etc - in classic way :));
  #     - `:dead_locking` - fail with deadlock exception;
  # @option access_strategy [Symbol]
  #   - The way in which the lock will be obtained;
  #   - By default it uses `:queued` strategy pre-defined in `config[:default_access_strategy]`;
  #   - Supports following strategies:
  #     - `:queued` (FIFO): the classic queued behavior (default), your lock will be
  #       obitaned if you are first in queue and the required lock is free;
  #     - `:random` (RANDOM):
  #       - obtain a lock without checking the positions in the queue
  #         (but with checking the limist, retries, timeouts and so on);
  #        - if lock is free to obtain - it will be obtained;
  # @option meta [NilClass,Hash<String|Symbol,Any>]
  #   - A custom metadata wich will be passed to the lock data in addition to the existing data;
  #   - Metadata can not contain reserved lock data keys;
  # @option logger [::Logger,#debug]
  #   - Logger object used from the configuration layer (see config[:logger]);
  #   - See `RedisQueuedLocks::Logging::VoidLogger` for example;
  #   - Supports `SemanticLogger::Logger` (see "semantic_logger" gem)
  # @option log_lock_try [Boolean]
  #   - should be logged the each try of lock acquiring (a lot of logs can
  #     be generated depending on your retry configurations);
  #   - see `config[:log_lock_try]`;
  # @option instrumenter [#notify]
  #   - Custom instrumenter that will be invoked via #notify method with `event` and `payload` data;
  #   - See RedisQueuedLocks::Instrument::ActiveSupport for examples and implementation details;
  #   - See [Instrumentation](#instrumentation) section of docs;
  #   - pre-configured in `config[:isntrumenter]` with void notifier
  #     (`RedisQueuedLocks::Instrumenter::VoidNotifier`);
  # @option instrument [NilClass,Any]
  #   - Custom instrumentation data wich will be passed to the instrumenter's payload
  #     with :instrument key;
  # @option log_sampling_enabled [Boolean]
  #   - enables <log sampling>: only the configured percent of RQL cases will be logged;
  #   - disabled by default;
  #   - works in tandem with <config.log_sampling_percent and <log.sampler>;
  # @option log_sampling_percent [Integer]
  #   - the percent of cases that should be logged;
  #   - take an effect when <config.log_sampling_enalbed> is true;
  #   - works in tandem with <config.log_sampling_enabled> and <config.log_sampler> configs;
  # @option log_sampler [#sampling_happened?,Module<RedisQueuedLocks::Logging::Sampler>]
  #   - percent-based log sampler that decides should be RQL case logged or not;
  #   - works in tandem with <config.log_sampling_enabled> and
  #     <config.log_sampling_percent> configs;
  #   - based on the ultra simple percent-based (weight-based) algorithm that uses SecureRandom.rand
  #     method so the algorithm error is ~(0%..13%);
  #   - you can provide your own log sampler with bettter algorithm that should realize
  #     `sampling_happened?(percent) => boolean` interface
  #     (see `RedisQueuedLocks::Logging::Sampler` for example);
  # @option instr_sampling_enabled [Boolean]
  #   - enables <instrumentaion sampling>: only the configured percent
  #     of RQL cases will be instrumented;
  #   - disabled by default;
  #   - works in tandem with <config.instr_sampling_percent and <log.instr_sampler>;
  # @option instr_sampling_percent [Integer]
  #   - the percent of cases that should be instrumented;
  #   - take an effect when <config.instr_sampling_enalbed> is true;
  #   - works in tandem with <config.instr_sampling_enabled> and <config.instr_sampler> configs;
  # @option instr_sampler [#sampling_happened?,Module<RedisQueuedLocks::Instrument::Sampler>]
  #   - percent-based log sampler that decides should be RQL case instrumented or not;
  #   - works in tandem with <config.instr_sampling_enabled> and
  #     <config.instr_sampling_percent> configs;
  #   - based on the ultra simple percent-based (weight-based) algorithm that uses SecureRandom.rand
  #     method so the algorithm error is ~(0%..13%);
  #   - you can provide your own log sampler with bettter algorithm that should realize
  #     `sampling_happened?(percent) => boolean` interface
  #     (see `RedisQueuedLocks::Instrument::Sampler` for example);
  # @param block [Block]
  #   A block of code that should be executed after the successfully acquired lock.
  # @return [RedisQueuedLocks::Data,Hash<Symbol,Any>,yield]
  #   - Format: { ok: true/false, result: Symbol/Hash }.
  #   - If block is given the result of block's yeld will be returned.
  #
  # @api public
  # @since 1.0.0
  # @version 1.7.0
  # rubocop:disable Metrics/MethodLength
  def lock(
    lock_name,
    ttl: config[:default_lock_ttl],
    queue_ttl: config[:default_queue_ttl],
    timeout: config[:try_to_lock_timeout],
    timed: config[:is_timed_by_default],
    retry_count: config[:retry_count],
    retry_delay: config[:retry_delay],
    retry_jitter: config[:retry_jitter],
    raise_errors: false,
    fail_fast: false,
    conflict_strategy: config[:default_conflict_strategy],
    access_strategy: config[:default_access_strategy],
    identity: uniq_identity,
    meta: nil,
    logger: config[:logger],
    log_lock_try: config[:log_lock_try],
    instrumenter: config[:instrumenter],
    instrument: nil,
    log_sampling_enabled: config[:log_sampling_enabled],
    log_sampling_percent: config[:log_sampling_percent],
    log_sampler: config[:log_sampler],
    instr_sampling_enabled: config[:instr_sampling_enabled],
    instr_sampling_percent: config[:instr_sampling_percent],
    instr_sampler: config[:instr_sampler],
    &block
  )
    RedisQueuedLocks::Acquier::AcquireLock.acquire_lock(
      redis_client,
      lock_name,
      process_id: RedisQueuedLocks::Resource.get_process_id,
      thread_id: RedisQueuedLocks::Resource.get_thread_id,
      fiber_id: RedisQueuedLocks::Resource.get_fiber_id,
      ractor_id: RedisQueuedLocks::Resource.get_ractor_id,
      ttl:,
      queue_ttl:,
      timeout:,
      timed:,
      retry_count:,
      retry_delay:,
      retry_jitter:,
      raise_errors:,
      instrumenter:,
      identity:,
      fail_fast:,
      conflict_strategy:,
      access_strategy:,
      meta:,
      logger:,
      log_lock_try:,
      instrument:,
      log_sampling_enabled:,
      log_sampling_percent:,
      log_sampler:,
      instr_sampling_enabled:,
      instr_sampling_percent:,
      instr_sampler:,
      &block
    )
  end
  # rubocop:enable Metrics/MethodLength

  # @note See #lock method signature.
  #
  # @api public
  # @since 1.0.0
  # @version 1.7.0
  # rubocop:disable Metrics/MethodLength
  def lock!(
    lock_name,
    ttl: config[:default_lock_ttl],
    queue_ttl: config[:default_queue_ttl],
    timeout: config[:try_to_lock_timeout],
    timed: config[:is_timed_by_default],
    retry_count: config[:retry_count],
    retry_delay: config[:retry_delay],
    retry_jitter: config[:retry_jitter],
    fail_fast: false,
    conflict_strategy: config[:default_conflict_strategy],
    access_strategy: config[:default_access_strategy],
    identity: uniq_identity,
    instrumenter: config[:instrumenter],
    meta: nil,
    logger: config[:logger],
    log_lock_try: config[:log_lock_try],
    instrument: nil,
    log_sampling_enabled: config[:log_sampling_enabled],
    log_sampling_percent: config[:log_sampling_percent],
    log_sampler: config[:log_sampler],
    instr_sampling_enabled: config[:instr_sampling_enabled],
    instr_sampling_percent: config[:instr_sampling_percent],
    instr_sampler: config[:instr_sampler],
    &block
  )
    lock(
      lock_name,
      ttl:,
      queue_ttl:,
      timeout:,
      timed:,
      retry_count:,
      retry_delay:,
      retry_jitter:,
      raise_errors: true,
      identity:,
      fail_fast:,
      logger:,
      log_lock_try:,
      meta:,
      instrument:,
      instrumenter:,
      conflict_strategy:,
      access_strategy:,
      log_sampling_enabled:,
      log_sampling_percent:,
      log_sampler:,
      instr_sampling_enabled:,
      instr_sampling_percent:,
      instr_sampler:,
      &block
    )
  end
  # rubocop:enable Metrics/MethodLength

  # @param lock_name [String] The lock name that should be released.
  # @option logger [::Logger,#debug]
  # @option instrumenter [#notify]
  # @option instrument [NilClass,Any]
  # @option log_sampling_enabled [Boolean]
  # @option log_sampling_percent [Integer]
  # @option log_sampler [#sampling_happened?,Module<RedisQueuedLocks::Logging::Sampler>]
  # @option instr_sampling_enabled [Boolean]
  # @option instr_sampling_percent [Integer]
  # @option instr_sampler [#sampling_happened?,Module<RedisQueuedLocks::Instrument::Sampler>]
  # @return [RedisQueuedLocks::Data, Hash<Symbol,Any>]
  #   Format: {
  #     ok: true/false,
  #     result: {
  #       rel_time: Integer, # <millisecnds>
  #       rel_key: String, # lock key
  #       rel_queue: String, # lock queue
  #       queue_res: Symbol, # :released or :nothing_to_release
  #       lock_res: Symbol # :released or :nothing_to_release
  #     }
  #   }
  #
  # @api public
  # @since 1.0.0
  # @version 1.6.0
  def unlock(
    lock_name,
    logger: config[:logger],
    instrumenter: config[:instrumenter],
    instrument: nil,
    log_sampling_enabled: config[:log_sampling_enabled],
    log_sampling_percent: config[:log_sampling_percent],
    log_sampler: config[:log_sampler],
    instr_sampling_enabled: config[:instr_sampling_enabled],
    instr_sampling_percent: config[:instr_sampling_percent],
    instr_sampler: config[:instr_sampler]
  )
    RedisQueuedLocks::Acquier::ReleaseLock.release_lock(
      redis_client,
      lock_name,
      instrumenter,
      logger,
      log_sampling_enabled,
      log_sampling_percent,
      log_sampler,
      instr_sampling_enabled,
      instr_sampling_percent,
      instr_sampler
    )
  end

  # @param lock_name [String]
  # @return [Boolean]
  #
  # @api public
  # @since 1.0.0
  def locked?(lock_name)
    RedisQueuedLocks::Acquier::IsLocked.locked?(redis_client, lock_name)
  end

  # @param lock_name [String]
  # @return [Boolean]
  #
  # @api public
  # @since 1.0.0
  def queued?(lock_name)
    RedisQueuedLocks::Acquier::IsQueued.queued?(redis_client, lock_name)
  end

  # @param lock_name [String]
  # @return [Hash<String,String|Numeric>,NilClass]
  #
  # @api public
  # @since 1.0.0
  def lock_info(lock_name)
    RedisQueuedLocks::Acquier::LockInfo.lock_info(redis_client, lock_name)
  end

  # @param lock_name [String]
  # @return [Hash<String|Array<Hash<String,String|Numeric>>,NilClass]
  #
  # @api public
  # @since 1.0.0
  def queue_info(lock_name)
    RedisQueuedLocks::Acquier::QueueInfo.queue_info(redis_client, lock_name)
  end

  # This method is non-atomic cuz redis does not provide an atomic function for TTL/PTTL extension.
  # So the methid is spliited into the two commands:
  #   (1) read current pttl
  #   (2) set new ttl that is calculated as "current pttl + additional milliseconds"
  # What can happen during these steps
  # - lock is expired between commands or before the first command;
  # - lock is expired before the second command;
  # - lock is expired AND newly acquired by another process (so you will extend the
  #   totally new lock with fresh PTTL);
  # Use it at your own risk and consider async nature when calling this method.
  #
  # @param lock_name [String]
  # @param milliseconds [Integer] How many milliseconds should be added.
  # @option logger [::Logger,#debug]
  # @option instrumenter [#notify] See `config[:instrumenter]` docs for details.
  # @option instrument [NilClass,Any]
  # @option log_sampling_enabled [Boolean]
  # @option log_sampling_percent [Integer]
  # @option log_sampler [#sampling_happened?,Module<RedisQueuedLocks::Logging::Sampler>]
  # @option instr_sampling_enabled [Boolean]
  # @option instr_sampling_percent [Integer]
  # @option instr_sampler [#sampling_happened?,Module<RedisQueuedLocks::Instrument::Sampler>]
  # @return [Hash<Symbol,Boolean|Symbol>]
  #   - { ok: true, result: :ttl_extended }
  #   - { ok: false, result: :async_expire_or_no_lock }
  #
  # @api public
  # @since 1.0.0
  # @version 1.6.0
  def extend_lock_ttl(
    lock_name,
    milliseconds,
    logger: config[:logger],
    instrumenter: config[:instrumenter],
    instrument: nil,
    log_sampling_enabled: config[:log_sampling_enabled],
    log_sampling_percent: config[:log_sampling_percent],
    log_sampler: config[:log_sampler],
    instr_sampling_enabled: config[:instr_sampling_enabled],
    instr_sampling_percent: config[:instr_sampling_percent],
    instr_sampler: config[:instr_sampler]
  )
    RedisQueuedLocks::Acquier::ExtendLockTTL.extend_lock_ttl(
      redis_client,
      lock_name,
      milliseconds,
      logger,
      instrumenter,
      instrument,
      log_sampling_enabled,
      log_sampling_percent,
      log_sampler,
      instr_sampling_enabled,
      instr_sampling_percent,
      instr_sampler
    )
  end

  # Releases all queues and locks.
  # Returns:
  #   - :rel_time - (milliseconds) - time spent to release all locks and queues;
  #   - :rel_key_cnt - (integer) - the number of released redis keys (queus+locks);
  #
  # @option batch_size [Integer]
  # @option logger [::Logger,#debug]
  # @option instrumenter [#notify] See `config[:instrumenter]` docs for details.
  # @option instrument [NilClass,Any]
  # @option log_sampling_enabled [Boolean]
  # @option log_sampling_percent [Integer]
  # @option log_sampler [#sampling_happened?,Module<RedisQueuedLocks::Logging::Sampler>]
  # @option instr_sampling_enabled [Boolean]
  # @option instr_sampling_percent [Integer]
  # @option instr_sampler [#sampling_happened?,Module<RedisQueuedLocks::Instrument::Sampler>]
  # @return [RedisQueuedLocks::Data,Hash<Symbol,Boolean|Hash<Symbol,Numeric>>]
  #   Example: { ok: true, result { rel_key_cnt: 100, rel_time: 0.01 } }
  #
  # @api public
  # @since 1.0.0
  # @version 1.6.0
  def clear_locks(
    batch_size: config[:lock_release_batch_size],
    logger: config[:logger],
    instrumenter: config[:instrumenter],
    instrument: nil,
    log_sampling_enabled: config[:log_sampling_enabled],
    log_sampling_percent: config[:log_sampling_percent],
    log_sampler: config[:log_sampler],
    instr_sampling_enabled: config[:instr_sampling_enabled],
    instr_sampling_percent: config[:instr_sampling_percent],
    instr_sampler: config[:instr_sampler]
  )
    RedisQueuedLocks::Acquier::ReleaseAllLocks.release_all_locks(
      redis_client,
      batch_size,
      logger,
      instrumenter,
      instrument,
      log_sampling_enabled,
      log_sampling_percent,
      log_sampler,
      instr_sampling_enabled,
      instr_sampling_percent,
      instr_sampler
    )
  end

  # @option scan_size [Integer]
  #   The batch of scanned keys for Redis'es SCAN command.
  # @option with_info [Boolean]
  #   Extract lock info or not. If you want to extract a lock info too you have to consider
  #   that during info extration the lock key may expire. The keys extraction (SCAN) without
  #   any info extraction is doing first.
  #   Possible options:
  #   - `true` => returns a set of hashes that represents the lock state: <lock:, status:, info:>
  #     - :lock (String) - the lock key in Redis database;
  #     - :status (Symbol) - lock key state in redis. possible values:
  #       - :released - the lock is expired/released during the info extraction;
  #       - :alive - the lock still obtained;
  #     - :info (Hash) - see #lock_info method for detals;
  #   - `false` => returns a set of strings that represents an active locks
  #     at the moment of Redis'es SCAN;
  # @return [Set<String>,Set<Hash<Symbol,Any>>]
  #
  # @api public
  # @since 1.0.0
  def locks(scan_size: config[:key_extraction_batch_size], with_info: false)
    RedisQueuedLocks::Acquier::Locks.locks(redis_client, scan_size:, with_info:)
  end

  # Extracts lock keys with their info. See #locks(with_info: true) for details.
  #
  # @option scan_size [Integer]
  # @return [Set<Hash<String,Any>>]
  #
  # @api public
  # @since 1.0.0
  def locks_info(scan_size: config[:key_extraction_batch_size])
    locks(scan_size:, with_info: true)
  end

  # @option scan_size [Integer]
  #   The batch of scanned keys for Redis'es SCAN command.
  # @option with_info [Boolean]
  #   Extract lock qeue info or not. If you want to extract a lock queue info too you have to
  #   consider that during info extration the lock queue may become empty. The queue key extraction
  #   (SCAN) without queue info extraction is doing first.
  #   Possible options:
  #   - `true` => returns a set of hashes that represents the queue state: <queue:, containing:>
  #     - :queue (String) - the lock queue key in Redis database;
  #     - :requests (Array<Hash<String,Any>>) - queue state in redis. see #queue_info for details;
  #   - `false` => returns a set of strings that represents an active queues
  #     at the moment of Redis'es SCAN;
  # @return [Set<String>,String<Hash<Symbol,Any>>]
  #
  # @api public
  # @since 1.0.0
  def queues(scan_size: config[:key_extraction_batch_size], with_info: false)
    RedisQueuedLocks::Acquier::Queues.queues(redis_client, scan_size:, with_info:)
  end

  # Extracts lock queues with their info. See #queues(with_info: true) for details.
  #
  # @option scan_size [Integer]
  # @return [Set<Hash<Symbol,Any>>]
  #
  # @api public
  # @since 1.0.0
  def queues_info(scan_size: config[:key_extraction_batch_size])
    queues(scan_size:, with_info: true)
  end

  # @option scan_size [Integer]
  # @return [Set<String>]
  #
  # @api public
  # @since 1.0.0
  def keys(scan_size: config[:key_extraction_batch_size])
    RedisQueuedLocks::Acquier::Keys.keys(redis_client, scan_size:)
  end

  # @option dead_ttl [Integer]
  #   - the time period (in millsiecnds) after whcih the lock request is
  #     considered as dead;
  #   - `config[:dead_request_ttl]` is used by default;
  # @option scan_size [Integer]
  #   - the batch of scanned keys for Redis'es SCAN command;
  #   - `config[:lock_release_batch_size]` is used by default;
  # @option logger [::Logger,#debug]
  # @option instrumenter [#notify]
  # @option instrument [NilClass,Any]
  # @option log_sampling_enabled [Boolean]
  # @option log_sampling_percent [Integer]
  # @option log_sampler [#sampling_happened?,Module<RedisQueuedLocks::Logging::Sampler>]
  # @option instr_sampling_enabled [Boolean]
  # @option instr_sampling_percent [Integer]
  # @option instr_sampler [#sampling_happened?,Module<RedisQueuedLocks::Instrument::Sampler>]
  # @return [Hash<Symbol,Boolean|Hash<Symbol,Set<String>>>]
  #   Format: { ok: true, result: { processed_queus: Set<String> } }
  #
  # @api public
  # @since 1.0.0
  # @version 1.6.0
  def clear_dead_requests(
    dead_ttl: config[:dead_request_ttl],
    scan_size: config[:lock_release_batch_size],
    logger: config[:logger],
    instrumenter: config[:instrumenter],
    instrument: nil,
    log_sampling_enabled: config[:log_sampling_enabled],
    log_sampling_percent: config[:log_sampling_percent],
    log_sampler: config[:log_sampler],
    instr_sampling_enabled: config[:instr_sampling_enabled],
    instr_sampling_percent: config[:instr_sampling_percent],
    instr_sampler: config[:instr_sampler]
  )
    RedisQueuedLocks::Acquier::ClearDeadRequests.clear_dead_requests(
      redis_client,
      scan_size,
      dead_ttl,
      logger,
      instrumenter,
      instrument,
      log_sampling_enabled,
      log_sampling_percent,
      log_sampler,
      instr_sampling_enabled,
      instr_sampling_percent,
      instr_sampler
    )
  end
end
# rubocop:enable Metrics/ClassLength
