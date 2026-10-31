# frozen_string_literal: true

# Lock series: a group of locks that are obtained atomically, held together and released together
# (the second part of the lock acquisition core next to `RedisQueuedLocks::Acquirer::AcquireLock`:
# it reuses the mixins of `AcquireLock`):
#   - all or nothing: one transaction obtains all locks of the series with the same ttl at the same
#     moment; the attempt that can not obtain some lock obtains nothing (see `TryToLockSeries`);
#   - nothing is held while the series waits for its locks, so the series can not hold locks
#     longer than its `ttl` and can not block other acquirers with partially obtained locks;
#   - the lock series are deadlock-free for any order of the lock names (one position of the lock
#     request in all queues of the series, see `TryToLockSeries`);
#   - the series limits are the limits of the whole series: `timeout`, `retry_count`, `queue_ttl`;
#   - one `read_write_mode`, one `priority`, one `ttl` for all locks of the series;
#   - the locks of the series are classic locks with the classic keys: lock info, `#unlock`,
#     `#extend_lock_ttl`, the swarm and other operations work with each of them separately;
#   - reentrant locks (`conflict_strategy`) are processed per lock: they are not obtained and not
#     released by the series;
#
# @api private
# @since 1.23.0
# rubocop:disable Metrics/ModuleLength
# rubocop:disable Metrics/ClassLength
# rubocop:disable Metrics/BlockNesting
module RedisQueuedLocks::Acquirer::LockSeries
  require_relative 'lock_series/log_visitor'
  require_relative 'lock_series/instr_visitor'
  require_relative 'lock_series/release_lock_series'
  require_relative 'lock_series/try_to_lock_series'

  # @since 1.23.0
  extend RedisQueuedLocks::Utilities
  # @since 1.23.0
  extend RedisQueuedLocks::Acquirer::AcquireLock::DelayExecution
  # @since 1.23.0
  extend RedisQueuedLocks::Acquirer::AcquireLock::YieldExpire
  # @since 1.23.0
  extend TryToLockSeries

  class << self
    # @param redis [RedisClient]
    #   Redis connection client.
    # @param lock_names [Array<String>]
    #   Controlled resources (a duplicated name is the same lock). At least one lock name.
    # @option detailed_result [Boolean]
    #   Return the detailed result of the series (the block result, times, lock keys).
    # @option process_id [Integer,String]
    #   The process that want to acquire the locks.
    # @option thread_id [Integer,String]
    #   The process's thread that want to acquire the locks.
    # @option fiber_id [Integer,String]
    #   A current fiber that want to acquire the locks.
    # @option ractor_id [Integer,String]
    #   The current ractor that want to acquire the locks.
    # @option ttl [Integer]
    #   The time to live of each lock of the series (in milliseconds). A positive Integer.
    # @option queue_ttl [Integer]
    #   Lifetime of the lock request of the series (in seconds).
    # @option lock_index_enabled [Boolean]
    #   Maintain the lock index (`config['lock_index_enabled']`, the client-wide mode).
    # @option lock_index_grace_period [Integer]
    #   The lock index score margin over the lock key lifetime (in milliseconds).
    # @option timeout [Integer,NilClass]
    #   Time period whe should try to acquire the whole series (in seconds). Nil means "without
    #   timeout" (`0` is the same as `nil`: `Timeout.timeout(0)` sets no timeout).
    # @option timed [Boolean]
    #   Limit the invocation time period of the passed block of code by the `ttl`.
    # @option retry_count [Integer,NilClass]
    #   How many times we should try to acquire the whole series. Nil means "infinite retries".
    # @option retry_delay [Integer]
    #   A time-interval between the each retry (in milliseconds).
    # @option retry_jitter [Integer]
    #   Time-shift range for retry-delay (in milliseconds).
    # @option raise_errors [Boolean]
    #   Raise errors on exceptional cases.
    # @option instrumenter [#notify]
    #   See RedisQueuedLocks::Instrument::ActiveSupport for example.
    # @option identity [String]
    #   Unique acquire identifier (see `AcquireLock.acquire_lock`).
    # @option fail_fast [Boolean]
    #   Should the required locks to be checked before the try and exit immidetly if any lock is
    #   already obtained.
    # @option meta [NilClass,Hash<String|Symbol,Any>]
    #   - A custom metadata wich will be passed to the data of each lock of the series;
    #   - Metadata can not contain reserved lock data keys;
    # @option detailed_acq_timeout_error [Boolean]
    #   Add the state of the lock that blocks the series to the acquirement timeout error.
    # @option logger [::Logger,#debug]
    #   Logger object used from the configuration layer (see config['logger']).
    # @option log_lock_try [Boolean]
    #   Should be logged the each try of the series acquiring (see `config['log_lock_try']`).
    # @option instrument [NilClass,Any]
    #   Custom instrumentation data wich will be passed to the instrumenter's payload.
    # @option conflict_strategy [Symbol]
    #   The conflict strategy of each lock of the series (see `AcquireLock.acquire_lock`).
    # @option read_write_mode [Symbol]
    #   The mode of all locks of the series: `:write` or `:read` (see `AcquireLock.acquire_lock`).
    # @option access_strategy [Symbol]
    #   The way in which the locks will be obtained (see `AcquireLock.acquire_lock`).
    # @option priority [Integer,Symbol]
    #   The lock request priority of the series (see `AcquireLock.acquire_lock`).
    # @option lock_priorities [Hash<Symbol,Integer>]
    #   The priority names (`config['lock_priorities']`): a priority name => its Integer priority.
    # @option log_sampling_enabled [Boolean]
    #   See `AcquireLock.acquire_lock`.
    # @option log_sampling_percent [Integer]
    #   See `AcquireLock.acquire_lock`.
    # @option log_sampler [#sampling_happened?,Module<RedisQueuedLocks::Logging::Sampler>]
    #   See `AcquireLock.acquire_lock`.
    # @option log_sample_this [Boolean]
    #   See `AcquireLock.acquire_lock`.
    # @option instr_sampling_enabled [Boolean]
    #   See `AcquireLock.acquire_lock`.
    # @option instr_sampling_percent [Integer]
    #   See `AcquireLock.acquire_lock`.
    # @option instr_sampler [#sampling_happened?,Module<RedisQueuedLocks::Instrument::Sampler>]
    #   See `AcquireLock.acquire_lock`.
    # @option instr_sample_this [Boolean]
    #   See `AcquireLock.acquire_lock`.
    # @yield A block of code that should be executed under all obtained locks.
    # @yieldreturn [Any]
    # @return [Hash<Symbol,Any>,yield]
    #  - Format: { ok: true/false, result: Any };
    #  - If block is given the result of block's yield will be returned;
    #  - `detailed_result: true`: the detailed result of the obtained series;
    #
    # @api private
    # @since 1.23.0
    # rubocop:disable Metrics/MethodLength
    def lock_series(
      redis,
      lock_names,
      detailed_result:,
      process_id:,
      thread_id:,
      fiber_id:,
      ractor_id:,
      ttl:,
      queue_ttl:,
      lock_index_enabled:,
      lock_index_grace_period:,
      timeout:,
      timed:,
      retry_count:,
      retry_delay:,
      retry_jitter:,
      raise_errors:,
      instrumenter:,
      identity:,
      fail_fast:,
      meta:,
      detailed_acq_timeout_error:,
      instrument:,
      logger:,
      log_lock_try:,
      conflict_strategy:,
      read_write_mode:,
      access_strategy:,
      priority:,
      lock_priorities:,
      log_sampling_enabled:,
      log_sampling_percent:,
      log_sampler:,
      log_sample_this:,
      instr_sampling_enabled:,
      instr_sampling_percent:,
      instr_sampler:,
      instr_sample_this:,
      &block
    )
      # Step 0: Prevent argument type incompatabilities (the same checks as in
      #   RedisQueuedLocks::Acquirer::AcquireLock, duplicated on purpose)
      # Step 0.1: prevent :lock_names incompatibilities
      if lock_names.empty?
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:lock_names` argument should contain at least one lock name, got #{lock_names.inspect}."
        )
      end

      # Step 0.1: prevent :meta incompatabiltiies (type)
      case meta # NOTE: do not ask why case/when is used here
      when Hash, NilClass then nil
      else
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:meta` argument should be a type of NilClass or Hash, got #{meta.class}."
        )
      end

      # Step 0.1 (RW): prevent :read_write_mode incompatabilities
      case read_write_mode # NOTE: (steep) case/when narrows `Symbol` to `RQL::readWriteMode` below
      when :read, :write then nil
      else
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:read_write_mode` argument should be `:read` or `:write`, " \
          "got #{read_write_mode.inspect}."
        )
      end

      # Step 0.1: prevent numeric argument incompatibilities (the same ranges as their config keys)
      if !ttl.is_a?(::Integer) || ttl <= 0
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:ttl` argument should be a positive Integer, got #{ttl.inspect}."
        )
      end
      if !queue_ttl.is_a?(::Integer) || queue_ttl <= 0
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:queue_ttl` argument should be a positive Integer, got #{queue_ttl.inspect}."
        )
      end
      if timeout != nil && (!timeout.is_a?(::Integer) || timeout < 0)
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:timeout` argument should be nil or a non-negative Integer, got #{timeout.inspect}."
        )
      end
      if retry_count != nil && (!retry_count.is_a?(::Integer) || retry_count < 0)
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:retry_count` argument should be nil or a non-negative Integer, " \
          "got #{retry_count.inspect}."
        )
      end
      if !retry_delay.is_a?(::Integer) || retry_delay < 0
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:retry_delay` argument should be a non-negative Integer, got #{retry_delay.inspect}."
        )
      end
      if !retry_jitter.is_a?(::Integer) || retry_jitter < 0
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:retry_jitter` argument should be a non-negative Integer, got #{retry_jitter.inspect}."
        )
      end
      if !lock_index_grace_period.is_a?(::Integer) || lock_index_grace_period < 0
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:lock_index_grace_period` argument should be a non-negative Integer, " \
          "got #{lock_index_grace_period.inspect}."
        )
      end

      # Step 0.1: prevent :priority incompatibilities (the same range as its config key)
      #   - a Symbol is a priority name of `config['lock_priorities']`: it is resolved to its
      #     Integer priority (an unknown name stays a Symbol and fails the check);
      priority = lock_priorities.fetch(priority, priority) if priority.is_a?(::Symbol)
      if !priority.is_a?(::Integer) ||
         priority < RedisQueuedLocks::Resource::MIN_LOCK_PRIORITY ||
         priority > RedisQueuedLocks::Resource::MAX_LOCK_PRIORITY
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:priority` argument should be an Integer from " \
          "#{RedisQueuedLocks::Resource::MIN_LOCK_PRIORITY} to " \
          "#{RedisQueuedLocks::Resource::MAX_LOCK_PRIORITY} or a priority name of " \
          "`config['lock_priorities']` (#{lock_priorities.keys.map(&:inspect).join(', ')}), " \
          "got #{priority.inspect}."
        )
      end

      # Step 0.2: prevent :meta incompatabiltiies (structure)
      #   - Symbol keys are written to the lock data as Strings (`Symbol#name`, as redis-client
      #     does it) and would overwrite the reserved lock data fields too;
      if meta.is_a?(::Hash) && (meta.any? do |key, _value|
        meta_key = key.is_a?(::Symbol) ? key.name : key
        meta_key == 'acq_id' ||
        meta_key == 'hst_id' ||
        meta_key == 'ts' ||
        meta_key == 'ini_ttl' ||
        meta_key == 'lock_key' ||
        meta_key == 'rem_ttl' ||
        meta_key == 'spc_ext_ttl' ||
        meta_key == 'spc_cnt' ||
        meta_key == 'l_spc_ext_ini_ttl' ||
        meta_key == 'l_spc_ext_ts' ||
        meta_key == 'l_spc_ts' ||
        meta_key == 'rw_mode'
      end)
        raise(
          RedisQueuedLocks::ArgumentError,
          '`:meta` keys can not overlap reserved lock data keys ' \
          '"acq_id", "hst_id", "ts", "ini_ttl", "lock_key", "rem_ttl", "spc_cnt", ' \
          '"spc_ext_ttl", "l_spc_ext_ini_ttl", "l_spc_ext_ts", "l_spc_ts", "rw_mode"'
        )
      end

      # Step 1: prepare the requirements of the series (lock keys, acquirer, lock request position)
      # NOTE: a duplicated lock name is the same lock (the series is obtained by one transaction
      #   and the lock state is checked once per lock);
      lock_names = lock_names.uniq(&:to_s)
      read_mode = (read_write_mode == :read)
      acquirer_id = RedisQueuedLocks::Resource.acquirer_identifier(
        process_id,
        thread_id,
        fiber_id,
        ractor_id,
        identity
      )
      host_id = RedisQueuedLocks::Resource.host_identifier(
        process_id,
        thread_id,
        ractor_id,
        identity
      )
      lock_keys = lock_names.map do |lock_name|
        RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
      end
      lock_key_queues = lock_names.map do |lock_name|
        RedisQueuedLocks::Resource.prepare_lock_queue(lock_name)
      end
      read_lock_key_queues = lock_names.map do |lock_name|
        RedisQueuedLocks::Resource.prepare_read_lock_queue(lock_name)
      end
      lock_readers_keys = lock_names.map do |lock_name|
        RedisQueuedLocks::Resource.prepare_lock_readers(lock_name)
      end
      # NOTE: (RW) read lock data keys are required by read lock requests only
      # @type var read_lock_keys: Array[String?]
      read_lock_keys = lock_names.map do |lock_name|
        RedisQueuedLocks::Resource.prepare_read_lock_key(lock_name, acquirer_id) if read_mode
      end
      # NOTE: (RW) the lock state keys: write lock requests watch the readers registries too, read
      #   lock requests do not (readers should not invalidate transactions of each other);
      watched_keys = read_mode ? lock_keys : (lock_keys + lock_readers_keys)

      # NOTE: one position in all lock request queues of the series: the lock requests are ordered
      #   in the same way in all queues, so they can not wait for each other in a cycle;
      acquirer_position = RedisQueuedLocks::Resource.calc_initial_acquirer_position(priority)

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

      # Step X: intermediate result observer
      # @type var acq_process: Hash[Symbol,untyped]
      acq_process = {
        should_try: true,
        tries: 0,
        acquired: false,
        result: nil,
        failed_lock_name: nil,
        ts: nil, # NOTE: see `try_to_lock_series`
        lock_processes: nil, # NOTE: see `try_to_lock_series`
        held_rw_modes: nil, # NOTE: see `try_to_lock_series`
        acq_time: nil, # NOTE: in milliseconds
        acq_end_time: nil,
        rel_ts: nil,
        hold_time: nil # NOTE: in milliseconds
      }
      # @type var reentrant_lock_keys: Array[String]
      reentrant_lock_keys = []
      # NOTE: (observability) the locks with the reported intermediate obtaining (once per lock)
      # @type var reported_ready_locks: Array[bool]
      reported_ready_locks = Array.new(lock_names.size, false)
      # @type var yield_result: untyped
      yield_result = nil

      LogVisitor.start_lock_series_obtaining(
        logger, log_sampled, lock_keys,
        queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, priority
      )

      # Step 2: try to obtain the series with timeout
      # NOTE: the acquirement start time is defined out of the timeout block: the failed
      #   acquirement reports the acquirement time too (Step 3.b);
      acq_start_time = clock_gettime

      begin
        begin
          ::Timeout.timeout(timeout, RedisQueuedLocks::LockAcquirementIntermediateTimeoutError) do
            # Step 2.1: cyclically try to obtain the series
            while acq_process[:should_try]
              LogVisitor.start_try_to_lock_series_cycle(
                logger, log_sampled, lock_keys,
                queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, priority
              )

              # Step 2.X: check the actual score: is it in queue ttl limit or not?
              if RedisQueuedLocks::Resource.dead_score_reached?(
                acquirer_position, priority, queue_ttl
              )
                # Step 2.X.X: dead score reached => re-queue the lock request of the series with
                #   the new score in all its queues (one position of the series);
                acquirer_position =
                  RedisQueuedLocks::Resource.calc_initial_acquirer_position(priority)

                LogVisitor.dead_score_reached__reset_series_position(
                  logger, log_sampled, lock_keys,
                  queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, priority
                )
              end

              attempt = try_to_lock_series(
                redis,
                logger,
                log_lock_try,
                lock_keys,
                read_write_mode,
                lock_key_queues,
                read_lock_key_queues,
                lock_readers_keys,
                read_lock_keys,
                lock_names,
                watched_keys,
                acquirer_id,
                host_id,
                acquirer_position,
                priority,
                ttl,
                queue_ttl,
                lock_index_enabled,
                lock_index_grace_period,
                fail_fast,
                conflict_strategy,
                access_strategy,
                meta,
                acq_process[:tries] > 0, # NOTE: retry attempt (see "pre-check" in the attempt)
                acq_process,
                log_sampled
              )
              acq_end_time = clock_gettime
              acq_time = ((acq_end_time - acq_start_time) / 1_000.0).ceil(2)

              # Step X: save the intermediate results to the result observer
              acq_process[:result] = attempt[:result]
              acq_process[:failed_lock_name] = attempt[:lock_name] if attempt[:lock_name]

              # Step 2.1: analyze an acquirement attempt
              if attempt[:ok]
                # Step 2.1.a: successfully acquired
                acq_process[:acq_time] = acq_time
                acq_process[:acq_end_time] = acq_end_time
                acq_process[:should_try] = false
                acq_process[:acquired] = true
              end

              # Step X: (observability) the intermediate obtaining of the locks of the series: the
              #   lock passed all checks of an attempt (nothing is held: the locks are obtained
              #   together, by the obtaining transaction of the attempt):
              #   - once per lock of the series (never per attempt), up to the lock that blocks
              #     the series, out of the WATCH block of the attempt;
              if log_sampled || instr_sampled
                ready_ts = Time.now.to_f
                attempt[:ready_locks].each do |lock_index|
                  next if reported_ready_locks[lock_index]

                  reported_ready_locks[lock_index] = true
                  LogVisitor.lock_series_intermediate_lock_obtained(
                    logger, log_sampled, lock_keys[lock_index], lock_keys, queue_ttl, acquirer_id,
                    host_id, acq_time, access_strategy, read_write_mode, priority
                  )
                  InstrVisitor.lock_series_intermediate_lock_obtained(
                    instrumenter, instr_sampled, lock_keys[lock_index], lock_keys, read_write_mode,
                    priority, ttl, acquirer_id, host_id, ready_ts, acq_time, instrument
                  )
                end
              end

              unless attempt[:ok]
                # Step 2.2: failed to acquire. anylize each case and act in accordance
                case attempt[:result]
                when :fail_fast_no_try # Step 2.2.a: fail without try
                  acq_process[:should_try] = false
                when :conflict_dead_lock, :conflict_lock_upgrade # Step 2.2.b: fail after conflict
                  acq_process[:tries] += 1
                  acq_process[:should_try] = false
                else
                  acq_process[:tries] += 1 # Step RETRY: possible retry case

                  if fail_fast # Step RETRY.A: fail after try
                    acq_process[:should_try] = false
                    acq_process[:result] = :fail_fast_after_try
                  elsif retry_count != nil && acq_process[:tries] >= retry_count
                    # Step RETRY.B: fail cuz the retry count is reached
                    acq_process[:should_try] = false
                    acq_process[:result] = :retry_limit_reached
                  else
                    # Step RETRY.X: no significant failures => retry easily :)
                    # NOTE:
                    #   delay the exceution in order to prevent chaotic lock-acquire attempts
                    #   and to allow other processes and threads to obtain the locks too.
                    delay_execution(retry_delay, retry_jitter)
                  end
                end
              end
            end
          end
        rescue RedisQueuedLocks::LockAcquirementIntermediateTimeoutError
          # NOTE: the acquirement time limit is reached: it is a failed acquirement (see Step 3.b)
          #   (the timeout can come right after the obtaining: `acq_process[:acquired]` decides);
          nil
        end

        # Step 3.a: acquired successfully => run logic or return the result of acquirement
        if acq_process[:acquired]
          # @type var lock_processes: Array[Symbol?]
          lock_processes = acq_process[:lock_processes]
          # NOTE: (observability) the full obtaining of the locks of the series; reentrant locks are
          #   not obtained by the series (the series events report them);
          lock_keys.each_with_index do |lock_key, index|
            if lock_processes[index] == :lock_obtaining
              LogVisitor.lock_series_lock_obtained(
                logger, log_sampled, lock_key, lock_keys, queue_ttl, acquirer_id, host_id,
                acq_process[:acq_time], access_strategy, read_write_mode, priority
              )
              InstrVisitor.lock_series_lock_obtained(
                instrumenter, instr_sampled, lock_key, lock_keys, read_write_mode, priority, ttl,
                acquirer_id, host_id, acq_process[:ts], acq_process[:acq_time], instrument
              )
            else
              reentrant_lock_keys << lock_key
            end
          end

          LogVisitor.lock_series_obtained(
            logger, log_sampled, lock_keys,
            queue_ttl, acquirer_id, host_id, acq_process[:acq_time], access_strategy,
            read_write_mode, priority, reentrant_lock_keys
          )
          InstrVisitor.lock_series_obtained(
            instrumenter, instr_sampled, lock_keys, read_write_mode, priority, ttl, acquirer_id,
            host_id, acq_process[:ts], acq_process[:acq_time], reentrant_lock_keys, instrument
          )

          ttl_shift = (
            (clock_gettime - acq_process[:acq_end_time]) / 1_000.0 -
            RedisQueuedLocks::Resource::REDIS_TIMESHIFT_ERROR
          ).ceil(2)

          yield_result = yield_lock_series(
            lock_keys, acquirer_id, host_id, timed, ttl_shift, ttl, meta, &block
          )
        end
      ensure
        if !acq_process[:acquired]
          # Step 3.b.X: the series is not obtained (a failure or an interruption of any kind)
          drop_failed_lock_series(
            redis, logger, lock_keys, read_write_mode, lock_key_queues, read_lock_key_queues,
            lock_names, queue_ttl, acquirer_id, host_id, access_strategy, priority, acq_process,
            log_sampled
          )
        elsif block_given?
          # Step 3.a.X: release the locks of the series after the block of code (on any failure too)
          spent_time = ((clock_gettime - acq_process[:acq_end_time]) / 1_000.0).ceil
          decreased_ttl = ttl - spent_time - RedisQueuedLocks::Resource::REDIS_TIMESHIFT_ERROR

          complete_lock_series_release(
            redis, lock_names, acq_process[:lock_processes], acq_process[:held_rw_modes],
            acquirer_id, decreased_ttl
          )

          acq_process[:rel_ts] = Time.now.to_f
          acq_process[:hold_time] =
            ((clock_gettime - acq_process[:acq_end_time]) / 1_000.0).ceil(2)

          LogVisitor.expire_lock_series(
            logger, log_sampled, lock_keys,
            queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, priority
          )
          # NOTE: an extended lock is the reentrant lock that was extended by the attempt
          if log_sampled && decreased_ttl > 0
            extended_lock_keys = lock_keys.select.with_index do |_lock_key, index|
              acq_process[:lock_processes][index] == :extendable_conflict_work_through
            end
            unless extended_lock_keys.empty?
              LogVisitor.decrease_lock_series(
                logger, log_sampled, extended_lock_keys, decreased_ttl,
                queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, priority
              )
            end
          end
          InstrVisitor.lock_series_hold_and_release(
            instrumenter, instr_sampled, lock_keys, read_write_mode, priority, ttl, acquirer_id,
            host_id, acq_process[:rel_ts], acq_process[:acq_time], acq_process[:hold_time],
            reentrant_lock_keys, instrument
          )
        end
      end

      if acq_process[:acquired]
        if detailed_result
          {
            yield_result: yield_result,
            locks_release_strategy: block_given? ? :immediate_release_after_yield : :redis_key_ttl,
            locks_released_at: acq_process[:rel_ts],
            locks_acq_time: acq_process[:acq_time],
            locks_hold_time: acq_process[:hold_time],
            lock_series: lock_names,
            rql_lock_series: lock_keys
          }
        elsif block_given?
          yield_result
        else
          {
            ok: true,
            result: {
              lock_series: lock_names,
              rql_lock_series: lock_keys,
              acq_id: acquirer_id,
              hst_id: host_id,
              ts: acq_process[:ts],
              ttl: ttl
            }
          }
        end
      else
        # Step 3.b: the series is not obtained
        # NOTE: the loop is interrupted by the acquirement timeout only (see the `rescue` above):
        #   all other interruptions are raised through the `ensure` part;
        acq_process[:result] = :timeout_reached if acq_process[:should_try]

        # @type var failure_result: Symbol
        failure_result = acq_process[:result]
        # @type var failed_lock_name: String?
        failed_lock_name = acq_process[:failed_lock_name]
        failed_lock_key =
          failed_lock_name ? RedisQueuedLocks::Resource.prepare_lock_key(failed_lock_name) : nil
        acq_time = ((clock_gettime - acq_start_time) / 1_000.0).ceil(2)
        failed_ts = Time.now.to_f

        # NOTE: the lock that blocks the series (unknown without an attempt with an obstacle)
        if failed_lock_key
          LogVisitor.lock_series_lock_obtaining_failed(
            logger, log_sampled, failed_lock_key, lock_keys, queue_ttl, acquirer_id, host_id,
            acq_time, access_strategy, read_write_mode, priority, failure_result
          )
          InstrVisitor.lock_series_lock_obtaining_failed(
            instrumenter, instr_sampled, failed_lock_key, lock_keys, read_write_mode, priority, ttl,
            acquirer_id, host_id, failed_ts, acq_time, failure_result, instrument
          )
        end
        LogVisitor.lock_series_obtaining_failed(
          logger, log_sampled, lock_keys, queue_ttl, acquirer_id, host_id, acq_time,
          access_strategy, read_write_mode, priority, failure_result, failed_lock_key
        )
        InstrVisitor.lock_series_obtaining_failed(
          instrumenter, instr_sampled, lock_keys, read_write_mode, priority, ttl, acquirer_id,
          host_id, failed_ts, acq_time, failure_result, failed_lock_key, instrument
        )

        if raise_errors
          raise_lock_series_error(
            redis, failure_result, lock_keys, failed_lock_name, failed_lock_key, acquirer_id,
            conflict_strategy, retry_count, timeout, detailed_acq_timeout_error
          )
        end

        # @type var detailed_errors: Hash[String, { ok: bool, result: Symbol }]
        detailed_errors = {}
        if failed_lock_name
          detailed_errors[failed_lock_name] = { ok: false, result: failure_result }
        end
        # NOTE: nothing is obtained by the failed series (all or nothing)
        # @type var acquired_locks: Array[String]
        acquired_locks = []

        {
          ok: false,
          result: {
            error: :failed_to_acquire_lock_series,
            detailed_errors:,
            lock_series: lock_names,
            acquired_locks:,
            missing_locks: lock_names,
            failed_on_lock: failed_lock_name
          }
        }
      end
    end
    # rubocop:enable Metrics/MethodLength

    private

    # Runs the block of code under the obtained series (`timed`: limited by the `ttl`).
    #
    # @param lock_keys [Array<String>]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param timed [Boolean]
    # @param ttl_shift [Numeric] In milliseconds.
    # @param ttl [Integer] In milliseconds.
    # @param meta [NilClass,Hash<String|Symbol,Any>]
    # @yield Custom logic that should be invoked under the obtained locks.
    # @yieldreturn [Any]
    # @return [Any,NilClass] nil is returned when no block parametr is provided.
    #
    # @api private
    # @since 1.23.0
    def yield_lock_series(lock_keys, acquirer_id, host_id, timed, ttl_shift, ttl, meta, &block)
      return unless block_given?
      return yield unless timed

      # NOTE: (steep) see `YieldExpire#yield_expire`: `::Integer - ::Integer|::Float`
      # steep:ignore:start
      # @type var timeout: Float
      timeout = ((ttl - ttl_shift) / 1_000.0).yield_self do |time|
        # NOTE: time in <seconds> cuz Ruby's Timeout requires <seconds>
        (time < 0) ? 0.0 : time
      end
      # steep:ignore:end

      yield_with_timeout(timeout, lock_keys.join(', '), ttl, acquirer_id, host_id, meta, &block)
    end

    # Releases the series: an interruption of the release itself (`Timeout.timeout` of the outer
    # logic, `Thread#kill`, a lost connection) is completed by the second release: an interruption
    # is delivered once and the release is idempotent (it checks the owner and works with own read
    # locks only); the error of the first release is raised as is.
    #
    # @param redis [RedisClient]
    # @param lock_names [Array<String>]
    # @param lock_processes [Array<Symbol,NilClass>] See `release_lock_series`.
    # @param held_rw_modes [Array<Symbol>] See `release_lock_series`.
    # @param acquirer_id [String]
    # @param decreased_ttl [Integer] See `release_lock_series`.
    # @return [void]
    #
    # @api private
    # @since 1.23.0
    def complete_lock_series_release(
      redis,
      lock_names,
      lock_processes,
      held_rw_modes,
      acquirer_id,
      decreased_ttl
    )
      is_series_released = false

      begin
        release_lock_series(
          redis, lock_names, lock_processes, held_rw_modes, acquirer_id, decreased_ttl
        )
        is_series_released = true
      ensure
        unless is_series_released
          run_non_critical do
            release_lock_series(
              redis, lock_names, lock_processes, held_rw_modes, acquirer_id, decreased_ttl
            )
          end
        end
      end
    end

    # Drops the traces of the series that is not obtained (a failure or an interruption of any
    # kind: the acquirement timeout, an error, `Timeout.timeout` of the outer logic, `Thread#kill`):
    #   - the obtaining transaction of an interrupted attempt can be applied by Redis without
    #     the reply: its locks are released (only the locks that are obtained by this transaction
    #     and only if they are owned by the current acquirer: nothing is released otherwise; the
    #     ttl of the extended reentrant locks is not decreased: the extension is unknown);
    #   - the lock requests are dropped from all lock request queues of the series;
    #   - errors are not raised here (they would replace the original error of the interrupted
    #     acquirement): dead lock requests are dropped by other lock requests, locks are released
    #     by their ttl;
    #
    # @param redis [RedisClient]
    # @param logger [::Logger,#debug]
    # @param lock_keys [Array<String>]
    # @param read_write_mode [Symbol]
    # @param lock_key_queues [Array<String>]
    # @param read_lock_key_queues [Array<String>]
    # @param lock_names [Array<String>]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param priority [Integer]
    # @param acq_process [Hash<Symbol,Any>]
    # @param log_sampled [Boolean]
    # @return [void]
    #
    # @api private
    # @since 1.23.0
    def drop_failed_lock_series(
      redis,
      logger,
      lock_keys,
      read_write_mode,
      lock_key_queues,
      read_lock_key_queues,
      lock_names,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      priority,
      acq_process,
      log_sampled
    )
      run_non_critical do
        if acq_process[:lock_processes]
          complete_lock_series_release(
            redis, lock_names, acq_process[:lock_processes], acq_process[:held_rw_modes],
            acquirer_id, 0
          )
          LogVisitor.expire_lock_series(
            logger, log_sampled, lock_keys,
            queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, priority
          )
        end
      end

      # NOTE: the failed "no try" attempt queues nothing
      return if acq_process[:result] == :fail_fast_no_try

      run_non_critical do
        request_queues = (read_write_mode == :read) ? read_lock_key_queues : lock_key_queues
        redis.pipelined do |pipeline|
          request_queues.each { |request_queue| pipeline.call('ZREM', request_queue, acquirer_id) }
        end
        LogVisitor.dequeue_from_lock_series_queues(
          logger, log_sampled, lock_keys,
          queue_ttl, acquirer_id, host_id, access_strategy, read_write_mode, priority
        )
      end
    end

    # Raises the error of the series that is not obtained (`raise_errors: true`): the same errors
    # as in the single lock acquirement.
    #
    # @param redis [RedisClient]
    # @param failure_result [Symbol]
    # @param lock_keys [Array<String>]
    # @param failed_lock_name [String,NilClass]
    # @param failed_lock_key [String,NilClass]
    # @param acquirer_id [String]
    # @param conflict_strategy [Symbol]
    # @param retry_count [Integer,NilClass]
    # @param timeout [Integer,NilClass]
    # @param detailed_acq_timeout_error [Boolean]
    # @return [void]
    #
    # @raise [RedisQueuedLocks::LockAlreadyObtainedError]
    # @raise [RedisQueuedLocks::ConflictLockObtainError]
    # @raise [RedisQueuedLocks::LockAcquirementRetryLimitError]
    # @raise [RedisQueuedLocks::LockAcquirementTimeoutError]
    #
    # @api private
    # @since 1.23.0
    # rubocop:disable Metrics/MethodLength
    def raise_lock_series_error(
      redis,
      failure_result,
      lock_keys,
      failed_lock_name,
      failed_lock_key,
      acquirer_id,
      conflict_strategy,
      retry_count,
      timeout,
      detailed_acq_timeout_error
    )
      series_description = "the lock series #{lock_keys.inspect}"
      series_description += " (blocked by \"#{failed_lock_key}\")" if failed_lock_key

      case failure_result
      when :fail_fast_no_try, :fail_fast_after_try
        raise(
          RedisQueuedLocks::LockAlreadyObtainedError,
          "Lock \"#{failed_lock_key || lock_keys.join(', ')}\" is already obtained."
        )
      when :conflict_dead_lock
        raise(
          RedisQueuedLocks::ConflictLockObtainError,
          "Lock Conflict: trying to acquire the lock \"#{failed_lock_key}\" " \
          "that is already acquired by the current acquirer (acq_id: \"#{acquirer_id}\")."
        )
      when :conflict_lock_upgrade
        raise(
          RedisQueuedLocks::ConflictLockObtainError,
          "Lock Conflict: trying to acquire the write lock \"#{failed_lock_key}\" " \
          "while the current acquirer holds its read lock (acq_id: \"#{acquirer_id}\"): " \
          "read-to-write lock upgrade is not supported " \
          "(conflict strategy: :#{conflict_strategy})."
        )
      when :retry_limit_reached
        raise(
          RedisQueuedLocks::LockAcquirementRetryLimitError,
          "Failed to acquire #{series_description} " \
          "for the given retry_count limit (#{retry_count} times)."
        )
      else
        details =
          if detailed_acq_timeout_error && failed_lock_name
            " Details: #{blocking_lock_details(redis, failed_lock_name)}"
          end
        raise(
          RedisQueuedLocks::LockAcquirementTimeoutError,
          "Failed to acquire #{series_description} " \
          "for the given <#{timeout} seconds> timeout.#{details}"
        )
      end
    end
    # rubocop:enable Metrics/MethodLength

    # The raw state of the lock that blocks the series (the detailed acquirement timeout error).
    #
    # @param redis [RedisClient]
    # @param failed_lock_name [String]
    # @return [String]
    #
    # @api private
    # @since 1.23.0
    def blocking_lock_details(redis, failed_lock_name)
      # NOTE: (pipeline layout) [0] the write lock data, [1] the readers registry,
      #   [2] write lock requests, [3] read lock requests;
      # @type var lock_state: Array[untyped]
      lock_state = redis.pipelined do |pipeline|
        pipeline.call('HGETALL', RedisQueuedLocks::Resource.prepare_lock_key(failed_lock_name))
        pipeline.call(
          'ZRANGE', RedisQueuedLocks::Resource.prepare_lock_readers(failed_lock_name),
          '0', '-1', 'WITHSCORES'
        )
        pipeline.call(
          'ZRANGE', RedisQueuedLocks::Resource.prepare_lock_queue(failed_lock_name),
          '0', '-1', 'WITHSCORES'
        )
        pipeline.call(
          'ZRANGE', RedisQueuedLocks::Resource.prepare_read_lock_queue(failed_lock_name),
          '0', '-1', 'WITHSCORES'
        )
      end

      "<Lock Data> => #{lock_state[0].to_h.inspect}; " \
      "<Readers Data> => #{lock_state[1].inspect}; " \
      "<Queue Data> => #{lock_state[2].inspect}; " \
      "<Read Queue Data> => #{lock_state[3].inspect};"
    end
  end
end
# rubocop:enable Metrics/ModuleLength
# rubocop:enable Metrics/ClassLength
# rubocop:enable Metrics/BlockNesting
