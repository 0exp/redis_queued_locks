# frozen_string_literal: true

# @api private
# @since 1.0.0
# @version 1.7.0
# rubocop:disable Metrics/ModuleLength
# rubocop:disable Metrics/MethodLength
# rubocop:disable Metrics/ClassLength
# rubocop:disable Metrics/BlockNesting
# rubocop:disable Style/IfInsideElse
module RedisQueuedLocks::Acquier::AcquireLock
  require_relative 'acquire_lock/log_visitor'
  require_relative 'acquire_lock/instr_visitor'
  require_relative 'acquire_lock/delay_execution'
  require_relative 'acquire_lock/with_acq_timeout'
  require_relative 'acquire_lock/yield_expire'
  require_relative 'acquire_lock/try_to_lock'
  require_relative 'acquire_lock/dequeue_from_lock_queue'

  # @since 1.0.0
  extend TryToLock
  # @since 1.0.0
  extend DelayExecution
  # @since 1.3.0
  extend YieldExpire
  # @since 1.0.0
  extend WithAcqTimeout
  # @since 1.7.0
  extend DequeueFromLockQueue

  class << self
    # @param redis [RedisClient]
    #   Redis connection client.
    # @param lock_name [String]
    #   Lock name to be acquier.
    # @option process_id [Integer,String]
    #   The process that want to acquire a lock.
    # @option thread_id [Integer,String]
    #   The process's thread that want to acquire a lock.
    # @option fiber_id [Integer,String]
    #   A current fiber that want to acquire a lock.
    # @option ractor_id [Integer,String]
    #   The current ractor that want to acquire a lock.
    # @option ttl [Integer,NilClass]
    #   Lock's time to live (in milliseconds). Nil means "without timeout".
    # @option queue_ttl [Integer]
    #   Lifetime of the acuier's lock request. In seconds.
    # @option timeout [Integer]
    #   Time period whe should try to acquire the lock (in seconds).
    # @option timed [Boolean]
    #   Limit the invocation time period of the passed block of code by the lock's TTL.
    # @option retry_count [Integer,NilClass]
    #   How many times we should try to acquire a lock. Nil means "infinite retries".
    # @option retry_delay [Integer]
    #   A time-interval between the each retry (in milliseconds).
    # @option retry_jitter [Integer]
    #   Time-shift range for retry-delay (in milliseconds).
    # @option raise_errors [Boolean]
    #   Raise errors on exceptional cases.
    # @option instrumenter [#notify]
    #   See RedisQueuedLocks::Instrument::ActiveSupport for example.
    # @option identity [String]
    #   Unique acquire identifier that is also should be unique between processes and pods
    #   on different machines. By default the uniq identity string is
    #   represented as 10 bytes hexstr.
    # @option fail_fast [Boolean]
    #   Should the required lock to be checked before the try and exit immidetly if lock is
    #   already obtained.
    # @option meta [NilClass,Hash<String|Symbol,Any>]
    #   - A custom metadata wich will be passed to the lock data in addition to the existing data;
    #   - Metadata can not contain reserved lock data keys;
    # @option detailed_acq_timeout_error [Boolean]
    #   - Add additional data to the acquirement timeout error such as the current lock queue state
    #   and the required lock state;
    #   - See `config[:detailed_acq_timeout_error]` for details;
    # @option logger [::Logger,#debug]
    #   - Logger object used from the configuration layer (see config[:logger]);
    #   - See `RedisQueuedLocks::Logging::VoidLogger` for example;
    #   - Supports `SemanticLogger::Logger` (see "semantic_logger" gem)
    # @option log_lock_try [Boolean]
    #   - should be logged the each try of lock acquiring (a lot of logs can be generated depending
    #     on your retry configurations);
    #   - see `config[:log_lock_try]`;
    # @option instrument [NilClass,Any]
    #   - Custom instrumentation data wich will be passed to the instrumenter's payload
    #     with :instrument key;
    # @option conflict_strategy [Symbol]
    #   - The conflict strategy mode for cases when the process that obtained the lock
    #     want to acquire this lock again;
    #   - By default uses `:wait_for_lock` strategy;
    #   - pre-confured in `config[:default_conflict_strategy]`;
    #   - Supports:
    #     - `:work_through`;
    #     - `:extendable_work_through`;
    #     - `:wait_for_lock`;
    #     - `:dead_locking`;
    # @option access_strategy [Symbol]
    #   - The way in which the lock will be obtained;
    #   - By default it uses `:queued` strategy;
    #   - Supports following strategies:
    #     - `:queued` (FIFO): the classic queued behavior (default), your lock will be
    #       obitaned if you are first in queue and the required lock is free;
    #     - `:random` (RANDOM): obtain a lock without checking the positions in the queue
    #       (but with checking the limist, retries, timeouts and so on). if lock is
    #       free to obtain - it will be obtained;
    #   - pre-configured in `config[:default_access_strategy]`;
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
    #   - based on the ultra simple percent-based (weight-based) algorithm that uses
    #     SecureRandom.rand method so the algorithm error is ~(0%..13%);
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
    #   - based on the ultra simple percent-based (weight-based) algorithm that uses
    #     SecureRandom.rand method so the algorithm error is ~(0%..13%);
    #   - you can provide your own log sampler with bettter algorithm that should realize
    #     `sampling_happened?(percent) => boolean` interface
    #     (see `RedisQueuedLocks::Instrument::Sampler` for example);
    # @param [Block]
    #   A block of code that should be executed after the successfully acquired lock.
    # @return [RedisQueuedLocks::Data,Hash<Symbol,Any>,yield]
    #  - Format: { ok: true/false, result: Any }
    #  - If block is given the result of block's yeld will be returned.
    #
    # @api private
    # @since 1.0.0
    # @version 1.9.0
    def acquire_lock(
      redis,
      lock_name,
      process_id:,
      thread_id:,
      fiber_id:,
      ractor_id:,
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
      meta:,
      detailed_acq_timeout_error:,
      instrument:,
      logger:,
      log_lock_try:,
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
      # Step 0: Prevent argument type incompatabilities
      # Step 0.1: prevent :meta incompatabiltiies (type)
      case meta # NOTE: do not ask why case/when is used here
      when Hash, NilClass then nil
      else
        raise(
          RedisQueuedLocks::ArgumentError,
          "`:meta` argument should be a type of NilClass or Hash, got #{meta.class}."
        )
      end

      # Step 0.2: prevent :meta incompatabiltiies (structure)
      if meta.is_a?(::Hash) && (meta.any? do |key, _value|
        key == 'acq_id' ||
        key == 'hst_id' ||
        key == 'ts' ||
        key == 'ini_ttl' ||
        key == 'lock_key' ||
        key == 'rem_ttl' ||
        key == 'spc_ext_ttl' ||
        key == 'spc_cnt' ||
        key == 'l_spc_ext_ini_ttl' ||
        key == 'l_spc_ext_ts' ||
        key == 'l_spc_ts'
      end)
        raise(
          RedisQueuedLocks::ArgumentError,
          '`:meta` keys can not overlap reserved lock data keys ' \
          '"acq_id", "hst_id", "ts", "ini_ttl", "lock_key", "rem_ttl", "spc_cnt", ' \
          '"spc_ext_ttl", "l_spc_ext_ini_ttl", "l_spc_ext_ts", "l_spc_ts"'
        )
      end

      # Step 1: prepare lock requirements (generate lock name, calc lock ttl, etc).
      acquier_id = RedisQueuedLocks::Resource.acquier_identifier(
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
      lock_ttl = ttl
      lock_key = RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
      lock_key_queue = RedisQueuedLocks::Resource.prepare_lock_queue(lock_name)
      acquier_position = RedisQueuedLocks::Resource.calc_initial_acquier_position

      log_sampled = RedisQueuedLocks::Logging.should_log?(
        log_sampling_enabled,
        log_sampling_percent,
        log_sampler
      )
      instr_sampled = RedisQueuedLocks::Instrument.should_instrument?(
        instr_sampling_enabled,
        instr_sampling_percent,
        instr_sampler
      )

      # Step X: intermediate result observer
      acq_process = {
        lock_info: {},
        should_try: true,
        tries: 0,
        acquired: false,
        result: nil,
        acq_time: nil, # NOTE: in milliseconds
        hold_time: nil, # NOTE: in milliseconds
        rel_time: nil # NOTE: in milliseconds
      }

      acq_dequeue = proc do
        dequeue_from_lock_queue(
          redis,
          logger,
          lock_key,
          lock_key_queue,
          queue_ttl,
          acquier_id,
          host_id,
          access_strategy,
          log_sampled,
          instr_sampled
        )
      end

      LogVisitor.start_lock_obtaining(
        logger, log_sampled, lock_key,
        queue_ttl, acquier_id, host_id, access_strategy
      )

      # Step 2: try to lock with timeout
      with_acq_timeout(
        redis,
        timeout,
        lock_key,
        lock_name,
        raise_errors,
        detailed_acq_timeout_error,
        on_timeout: acq_dequeue
      ) do
        acq_start_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond)

        # Step 2.1: cyclically try to obtain the lock
        while acq_process[:should_try]

          LogVisitor.start_try_to_lock_cycle(
            logger, log_sampled, lock_key,
            queue_ttl, acquier_id, host_id, access_strategy
          )

          # Step 2.X: check the actual score: is it in queue ttl limit or not?
          if RedisQueuedLocks::Resource.dead_score_reached?(acquier_position, queue_ttl)
            # Step 2.X.X: dead score reached => re-queue the lock request with the new score;
            acquier_position = RedisQueuedLocks::Resource.calc_initial_acquier_position

            LogVisitor.dead_score_reached__reset_acquier_position(
              logger, log_sampled, lock_key,
              queue_ttl, acquier_id, host_id, access_strategy
            )
          end

          try_to_lock(
            redis,
            logger,
            log_lock_try,
            lock_key,
            lock_key_queue,
            acquier_id,
            host_id,
            acquier_position,
            lock_ttl,
            queue_ttl,
            fail_fast,
            conflict_strategy,
            access_strategy,
            meta,
            log_sampled,
            instr_sampled
          ) => { ok:, result: }

          acq_end_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond)
          acq_time = ((acq_end_time - acq_start_time) / 1_000.0).ceil(2)

          # Step X: save the intermediate results to the result observer
          acq_process[:result] = result
          acq_process[:acq_end_time] = acq_end_time

          # Step 2.1: analyze an acquirement attempt
          if ok
            # Step X: (instrumentation)
            if acq_process[:result][:process] == :extendable_conflict_work_through
              # instrumetnation: (reentrant lock with ttl extension)
              LogVisitor.extendable_reentrant_lock_obtained(
                logger, log_sampled, result[:lock_key],
                queue_ttl, acquier_id, host_id, acq_time, access_strategy
              )
              InstrVisitor.extendable_reentrant_lock_obtained(
                instrumenter, instr_sampled, result[:lock_key],
                result[:ttl], result[:acq_id], result[:hst_id], result[:ts], acq_time,
                instrument
              )
            elsif acq_process[:result][:process] == :conflict_work_through
              # instrumetnation: (reentrant lock without ttl extension)
              LogVisitor.reentrant_lock_obtained(
                logger, log_sampled, result[:lock_key],
                queue_ttl, acquier_id, host_id, acq_time, access_strategy
              )
              InstrVisitor.reentrant_lock_obtained(
                instrumenter, instr_sampled, result[:lock_key],
                result[:ttl], result[:acq_id], result[:hst_id], result[:ts], acq_time,
                instrument
              )
            else
              # instrumentation: (classic lock obtain)
              # NOTE: classic is: acq_process[:result][:process] == :lock_obtaining
              LogVisitor.lock_obtained(
                logger, log_sampled, result[:lock_key],
                queue_ttl, acquier_id, host_id, acq_time, access_strategy
              )
              InstrVisitor.lock_obtained(
                instrumenter, instr_sampled, result[:lock_key],
                result[:ttl], result[:acq_id], result[:hst_id], result[:ts], acq_time,
                instrument
              )
            end

            # Step 2.1.a: successfully acquired => build the result
            acq_process[:lock_info] = {
              lock_key: result[:lock_key],
              acq_id: result[:acq_id],
              hst_id: result[:hst_id],
              ts: result[:ts],
              ttl: result[:ttl],
              process: result[:process]
            }
            acq_process[:acquired] = true
            acq_process[:should_try] = false
            acq_process[:acq_time] = acq_time
            acq_process[:acq_end_time] = acq_end_time
          else
            # Step 2.2: failed to acquire. anylize each case and act in accordance
            if acq_process[:result] == :fail_fast_no_try # Step 2.2.a: fail without try
              acq_process[:should_try] = false

              if raise_errors
                raise(
                  RedisQueuedLocks::LockAlreadyObtainedError,
                  "Lock \"#{lock_key}\" is already obtained."
                )
              end
            elsif acq_process[:result] == :conflict_dead_lock # Step 2.2.b: fail after dead lock
              acq_process[:tries] += 1
              acq_process[:should_try] = false
              acq_process[:result] = :conflict_dead_lock
              acq_dequeue.call

              if raise_errors
                raise(
                  RedisQueuedLock::ConflictLockObtainError,
                  "Lock Conflict: trying to acquire the lock \"#{lock_key}\" " \
                  "that is already acquired by the current acquier (acq_id: \"#{acquired_id}\")."
                )
              end
            else
              acq_process[:tries] += 1 # Step RETRY: possible retry case

              if fail_fast # Step RETRY.A: fail after try
                acq_process[:should_try] = false
                acq_process[:result] = :fail_fast_after_try
                acq_dequeue.call

                if raise_errors
                  raise(
                    RedisQueuedLocks::LockAlreadyObtainedError,
                    "Lock \"#{lock_key}\" is already obtained."
                  )
                end
              else
                # Step RETRY.B: fail cuz the retry count is reached
                if retry_count != nil && acq_process[:tries] >= retry_count
                  acq_process[:should_try] = false
                  acq_process[:result] = :retry_limit_reached
                  acq_dequeue.call

                  if raise_errors
                    raise(
                      RedisQueuedLocks::LockAcquiermentRetryLimitError,
                      "Failed to acquire the lock \"#{lock_key}\" " \
                      "for the given retry_count limit (#{retry_count} times)."
                    )
                  end
                else
                  # Step RETRY.X: no significant failures => retry easily :)
                  # NOTE:
                  #   delay the exceution in order to prevent chaotic lock-acquire attempts
                  #   and to allow other processes and threads to obtain the lock too.
                  delay_execution(retry_delay, retry_jitter)
                end
              end
            end
          end
        end
      end

      # Step 3: analyze acquirement result
      if acq_process[:acquired]
        # Step 3.a: acquired successfully => run logic or return the result of acquirement
        if block_given?
          begin
            yield_time = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond)

            ttl_shift = (
              (yield_time - acq_process[:acq_end_time]) / 1_000.0 -
              RedisQueuedLocks::Resource::REDIS_TIMESHIFT_ERROR
            ).ceil(2)

            should_expire =
              acq_process[:result][:process] != :extendable_conflict_work_through &&
              acq_process[:result][:process] != :conflict_work_through

            should_decrease =
              acq_process[:result][:process] == :extendable_conflict_work_through

            yield_expire(
              redis,
              logger,
              lock_key,
              acquier_id,
              host_id,
              access_strategy,
              timed,
              ttl_shift,
              ttl,
              queue_ttl,
              meta,
              log_sampled,
              instr_sampled,
              should_expire, # NOTE: should expire the lock after the block execution
              should_decrease, # NOTE: should decrease the lock ttl in reentrant locks?
              &block
            )
          ensure
            acq_process[:rel_time] = ::Process.clock_gettime(
              ::Process::CLOCK_MONOTONIC, :microsecond
            )
            acq_process[:hold_time] = (
              (acq_process[:rel_time] - acq_process[:acq_end_time]) / 1_000.0
            ).ceil(2)

            if acq_process[:result][:process] == :extendable_conflict_work_through ||
               acq_process[:result][:process] == :conflict_work_through
              # Step X (instrumentation): reentrant_lock_hold_completes
              InstrVisitor.reentrant_lock_hold_completes(
                instrumenter,
                instr_sampled,
                acq_process[:lock_info][:lock_key],
                acq_process[:lock_info][:ttl],
                acq_process[:lock_info][:acq_id],
                acq_process[:lock_info][:hst_id],
                acq_process[:lock_info][:ts],
                acq_process[:acq_time],
                acq_process[:hold_time],
                instrument
              )
            else
              # Step X (instrumentation): lock_hold_and_release
              InstrVisitor.lock_hold_and_release(
                instrumenter,
                instr_sampled,
                acq_process[:lock_info][:lock_key],
                acq_process[:lock_info][:ttl],
                acq_process[:lock_info][:acq_id],
                acq_process[:lock_info][:hst_id],
                acq_process[:lock_info][:ts],
                acq_process[:lock_info][:lock_key],
                acq_process[:acq_time],
                instrument
              )
            end
          end
        else
          RedisQueuedLocks::Data[ok: true, result: acq_process[:lock_info]]
        end
      else
        if acq_process[:result] != :retry_limit_reached &&
           acq_process[:result] != :fail_fast_no_try &&
           acq_process[:result] != :fail_fast_after_try &&
           acq_process[:result] != :conflict_dead_lock
          # NOTE: we have only two situations if lock is not acquired without explicit failures:
          #   - time limit is reached;
          #   - retry count limit is reached;
          #   - **(notice: in other cases the lock obtaining time and tries count are infinite)
          acq_process[:result] = :timeout_reached
        end
        # Step 3.b: lock is not acquired (acquier is dequeued by timeout callback)
        RedisQueuedLocks::Data[ok: false, result: acq_process[:result]]
      end
    end
  end
end
# rubocop:enable Metrics/ModuleLength
# rubocop:enable Metrics/MethodLength
# rubocop:enable Metrics/ClassLength
# rubocop:enable Metrics/BlockNesting
# rubocop:enable Style/IfInsideElse
