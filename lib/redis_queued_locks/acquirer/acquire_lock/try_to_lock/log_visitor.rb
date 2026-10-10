# frozen_string_literal: true

# @api private
# @since 1.7.0
# rubocop:disable Metrics/ModuleLength
module RedisQueuedLocks::Acquirer::AcquireLock::TryToLock::LogVisitor
  # rubocop:disable Metrics/ClassLength
  class << self
    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def start(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.start] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def rconn_fetched(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.rconn_fetched] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def same_process_conflict_detected(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.same_process_conflict_detected] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @param sp_conflict_status [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def same_process_conflict_analyzed(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode,
      sp_conflict_status
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.same_process_conflict_analyzed] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "spc_status => '#{sp_conflict_status}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @param sp_conflict_status [Symbol]
    # @param ttl [Integer]
    # @param spc_processed_timestamp [Float]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def reentrant_lock__extend_and_work_through(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode,
      sp_conflict_status,
      ttl,
      spc_processed_timestamp
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.reentrant_lock__extend_and_work_through] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
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
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @param sp_conflict_status [Symbol]
    # @param spc_processed_timestamp [Float]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def reentrant_lock__work_through(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode,
      sp_conflict_status,
      spc_processed_timestamp
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.reentrant_lock__work_through] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "spc_status => '#{sp_conflict_status}' " \
        "last_spc_ts => '#{spc_processed_timestamp}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @param sp_conflict_status [Symbol]
    # @param spc_processed_timestamp [Float]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def single_process_lock_conflict__dead_lock(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode,
      sp_conflict_status,
      spc_processed_timestamp
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.single_process_lock_conflict__dead_lock] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "spc_status => '#{sp_conflict_status}' " \
        "last_spc_ts => '#{spc_processed_timestamp}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @param sp_conflict_status [Symbol]
    # @param spc_processed_timestamp [Float]
    # @return [void]
    #
    # @api private
    # @since 1.18.0
    def single_process_lock_conflict__lock_upgrade(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode,
      sp_conflict_status,
      spc_processed_timestamp
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.single_process_lock_conflict__lock_upgrade] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "spc_status => '#{sp_conflict_status}' " \
        "last_spc_ts => '#{spc_processed_timestamp}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def acq_added_to_queue(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.acq_added_to_queue] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def remove_expired_acqs(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.remove_expired_acqs] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @param waiting_acquirer [String,NilClass]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def get_first_from_queue(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode,
      waiting_acquirer
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.get_first_from_queue] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "first_acq_id_in_queue => '#{waiting_acquirer}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def exit__queue_ttl_reached(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.exit__queue_ttl_reached] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @param waiting_acquirer [String,NilClass]
    # @param current_lock_data [Hash<String,Any>]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def exit__no_first(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode,
      waiting_acquirer,
      current_lock_data
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.exit__no_first] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "first_acq_id_in_queue => '#{waiting_acquirer}' " \
        "<current_lock_data> => <<#{current_lock_data}>>"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @param waiting_acquirer [String,NilClass]
    # @param locked_by_acquirer [String]
    # @param current_lock_data [Hash<String,Any>]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def exit__lock_still_obtained(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode,
      waiting_acquirer,
      locked_by_acquirer,
      current_lock_data
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.exit__lock_still_obtained] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "first_acq_id_in_queue => '#{waiting_acquirer}' " \
        "locked_by_acq_id => '#{locked_by_acquirer}' " \
        "<current_lock_data> => <<#{current_lock_data}>>"
      end rescue nil
    end

    # Read lock request is blocked by an earlier write lock request (FIFO between modes).
    #
    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @param ahead_acquirer [String]
    # @return [void]
    #
    # @api private
    # @since 1.18.0
    def exit__write_request_ahead(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode,
      ahead_acquirer
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.exit__write_request_ahead] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "ahead_acq_id => '#{ahead_acquirer}'"
      end rescue nil
    end

    # Write lock request is blocked by an earlier read lock request (FIFO between modes).
    #
    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @param ahead_acquirer [String]
    # @return [void]
    #
    # @api private
    # @since 1.18.0
    def exit__read_request_ahead(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode,
      ahead_acquirer
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.exit__read_request_ahead] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "ahead_acq_id => '#{ahead_acquirer}'"
      end rescue nil
    end

    # The lock is still held by readers: write lock requests wait for all readers,
    # read lock requests wait for their own (same acquirer) read lock (see `:wait_for_lock`).
    #
    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @param waiting_acquirer [String,NilClass]
    # @return [void]
    #
    # @api private
    # @since 1.18.0
    def exit__read_lock_still_obtained(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode,
      waiting_acquirer
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.exit__read_lock_still_obtained] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}' " \
        "first_acq_id_in_queue => '#{waiting_acquirer}'"
      end rescue nil
    end

    # @param logger [::Logger,#debug]
    # @param log_sampled [Boolean]
    # @param log_lock_try [Boolean]
    # @param lock_key [String]
    # @param queue_ttl [Integer]
    # @param acquirer_id [String]
    # @param host_id [String]
    # @param access_strategy [Symbol]
    # @param rw_mode [Symbol]
    # @return [void]
    #
    # @api private
    # @since 1.7.0
    # @version 1.18.0
    def obtain__free_to_acquire(
      logger,
      log_sampled,
      log_lock_try,
      lock_key,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy,
      rw_mode
    )
      return unless log_sampled && log_lock_try

      logger.debug do
        "[redis_queued_locks.try_lock.obtain__free_to_acquire] " \
        "lock_key => '#{lock_key}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "rw_mode => '#{rw_mode}'"
      end rescue nil
    end
  end
  # rubocop:enable Metrics/ClassLength
end
# rubocop:enable Metrics/ModuleLength
