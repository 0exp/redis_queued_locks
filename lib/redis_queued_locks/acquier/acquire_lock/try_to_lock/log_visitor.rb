# frozen_string_literal: true

# @api private
# @since 1.7.0
# rubocop:disable Metrics/ModuleLength
module RedisQueuedLocks::Acquier::AcquireLock::TryToLock::LogVisitor
  class << self
    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquier_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def start(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquier_id,
      host_id,
      access_strategy
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.start] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquier_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquier_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def rconn_fetched(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquier_id,
      host_id,
      access_strategy
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.rconn_fetched] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquier_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquier_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def same_process_conflict_detected(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquier_id,
      host_id,
      access_strategy
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.same_process_conflict_detected] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquier_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquier_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param sp_conflict_status [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def same_process_conflict_analyzed(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquier_id,
      host_id,
      access_strategy,
      sp_conflict_status
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.same_process_conflict_analyzed] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquier_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "spc_status => '#{sp_conflict_status}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquier_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param sp_conflict_status [Symbol]
    # @param ttl [Integer]
    # @param spc_processed_timestamp [Float]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def reentrant_lock__extend_and_work_through(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquier_id,
      host_id,
      access_strategy,
      sp_conflict_status,
      ttl,
      spc_processed_timestamp
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.reentrant_lock__extend_and_work_through] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquier_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "spc_status => '#{sp_conflict_status}' " \
        "last_ext_ttl => #{ttl} " \
        "last_ext_ts => '#{spc_processed_timestamp}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquier_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param sp_conflict_status [Symbol]
    # @param spc_processed_timestamp [Float]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def reentrant_lock__work_through(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquier_id,
      host_id,
      access_strategy,
      sp_conflict_status,
      spc_processed_timestamp
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.reentrant_lock__work_through] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquier_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "spc_status => '#{sp_conflict_status}' " \
        "last_spc_ts => '#{spc_processed_timestamp}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquier_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param sp_conflict_status [Symbol]
    # @param spc_processed_timestamp [Float]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def single_process_lock_conflict__dead_lock(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquier_id,
      host_id,
      access_strategy,
      sp_conflict_status,
      spc_processed_timestamp
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.single_process_lock_conflict__dead_lock] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquier_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "spc_status => '#{sp_conflict_status}' " \
        "last_spc_ts => '#{spc_processed_timestamp}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquier_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def acq_added_to_queue(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquier_id,
      host_id,
      access_strategy
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.acq_added_to_queue] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquier_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquier_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def remove_expired_acqs(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquier_id,
      host_id,
      access_strategy
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.remove_expired_acqs] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquier_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquier_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param waiting_acquier [String,NilClass]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def get_first_from_queue(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquier_id,
      host_id,
      access_strategy,
      waiting_acquier
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.get_first_from_queue] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquier_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "first_acq_id_in_queue => '#{waiting_acquier}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquier_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def exit__queue_ttl_reached(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquier_id,
      host_id,
      access_strategy
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.exit__queue_ttl_reached] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquier_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquier_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param waiting_acquier [String,NilClass]
    # @param current_lock_data [Hash<String,Any>]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def exit__no_first(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquier_id,
      host_id,
      access_strategy,
      waiting_acquier,
      current_lock_data
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.exit__no_first] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquier_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "first_acq_id_in_queue => '#{waiting_acquier}' " \
        "<current_lock_data> => <<#{current_lock_data}>>"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquier_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param waiting_acquier [String,NilClass]
    # @param locked_by_acquier [String]
    # @param current_lock_data [Hash<String,Any>]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def exit__lock_still_obtained(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquier_id,
      host_id,
      access_strategy,
      waiting_acquier,
      locked_by_acquier,
      current_lock_data
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.exit__lock_still_obtained] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquier_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "first_acq_id_in_queue => '#{waiting_acquier}' " \
        "locked_by_acq_id => '#{locked_by_acquier}' " \
        "<current_lock_data> => <<#{current_lock_data}>>"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquier_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.9.0
    def obtain__free_to_acquire(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquier_id,
      host_id,
      access_strategy
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.obtain__free_to_acquire] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquier_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}'"
      end rescue nil
    end
  end
end
# rubocop:enable Metrics/ModuleLength
