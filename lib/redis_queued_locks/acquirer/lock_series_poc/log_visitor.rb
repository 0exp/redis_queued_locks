# frozen_string_literal: true

# NOTE: Lock Series PoC
# steep:ignore
# @api private
# @since 1.16.1
module RedisQueuedLocks::Acquirer::LockSeriesPoC::LogVisitor # steep:ignore
  class << self
    # NOTE: Lock Series PoC
    # @api private
    # @since 1.16.0
    def start_lock_series_obtaining( # steep:ignore
      logger,
      log_sampled,
      lock_keys,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.start_lock_series_obtaining] " \
        "lock_keys => '#{lock_keys.inspect}'" \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}'"
      end # rescue nil
    end

    # NOTE: Lock Series PoC
    # @api private
    # @since 1.16.0
    def lock_series_obtained( # steep:ignore
      logger,
      log_sampled,
      lock_keys,
      queue_ttl,
      acquirer_id,
      host_id,
      acq_time,
      access_strategy
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.lock_series_obtained] " \
        "lock_keys => '#{lock_keys.inspect}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}' " \
        "acq_time => #{acq_time} (ms)"
      end # rescue nil
    end

    # NOTE: Lock Series PoC
    # @api private
    # @since 1.16.0
    def expire_lock_series( # steep:ignore
      logger,
      log_sampled,
      lock_series,
      queue_ttl,
      acquirer_id,
      host_id,
      access_strategy
    )
      return unless log_sampled

      logger.debug do
        "[redis_queued_locks.expire_lock_series] " \
        "lock_keys => '#{lock_series.inspect}' " \
        "queue_ttl => #{queue_ttl} " \
        "acq_id => '#{acquirer_id}' " \
        "hst_id => '#{host_id}' " \
        "acs_strat => '#{access_strategy}'"
      end rescue nil
    end
  end
end
