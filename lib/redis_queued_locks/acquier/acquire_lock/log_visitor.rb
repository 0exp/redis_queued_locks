# frozen_string_literal: true

# @api private
# @since 1.7.0
module RedisQueuedLocks::Acquier::AcquireLock::LogVisitor
  extend self

  # @param logger [::Logger,#debug]
  # @param log_sampled [Boolean]
  # @param lock_key [String]
  # @param queue_ttl [Integer]
  # @param acquier_id [String]
  # @return [void]
  #
  # @api private
  # @since 1.7.0
  def start_lock_obtaining(
    logger,
    log_sampled,
    lock_key,
    queue_ttl,
    acquier_id
  )
    return unless log_sampled

    logger.debug do
      "[redis_queued_locks.start_lock_obtaining] " \
      "lock_key => '#{lock_key}' " \
      "queue_ttl => #{queue_ttl} " \
      "acq_id => '#{acquier_id}'"
    end rescue nil
  end

  # @param logger [::Logger,#debug]
  # @param log_sampled [Boolean]
  # @param lock_key [String]
  # @param queue_ttl [Integer]
  # @param acquier_id [String]
  # @return [void]
  #
  # @api private
  # @since 1.7.0
  def start_try_to_lock_cycle(
    logger,
    log_sampled,
    lock_key,
    queue_ttl,
    acquier_id
  )
    return unless log_sampled

    logger.debug do
      "[redis_queued_locks.start_try_to_lock_cycle] " \
      "lock_key => '#{lock_key}' " \
      "queue_ttl => #{queue_ttl} " \
      "acq_id => '{#{acquier_id}'"
    end rescue nil
  end

  # @param logger [::Logger,#debug]
  # @param log_sampled [Boolean]
  # @param lock_key [String]
  # @param queue_ttl [Integer]
  # @param acquier_id [String]
  # @return [void]
  #
  # @api private
  # @since 1.7.0
  def dead_score_reached__reset_acquier_position(
    logger,
    log_sampled,
    lock_key,
    queue_ttl,
    acquier_id
  )
    return unless log_sampled

    logger.debug do
      "[redis_queued_locks.dead_score_reached__reset_acquier_position] " \
      "lock_key => '#{lock_key} " \
      "queue_ttl => #{queue_ttl} " \
      "acq_id => '#{acquier_id}'"
    end rescue nil
  end

  # @param logger [::Logger,#debug]
  # @param log_sampled [Boolean]
  # @param lock_key [String]
  # @param queue_ttl [Integer]
  # @param acquier_id [String]
  # @param acq_time [Numeric]
  # @return [void]
  #
  # @api private
  # @since 1.7.0
  def extendable_reentrant_lock_obtained(
    logger,
    log_sampled,
    lock_key,
    queue_ttl,
    acquier_id,
    acq_time
  )
    return unless log_sampled

    logger.debug do
      "[redis_queued_locks.extendable_reentrant_lock_obtained] " \
      "lock_key => '#{lock_key}' " \
      "queue_ttl => #{queue_ttl} " \
      "acq_id => '#{acquier_id}' " \
      "acq_time => #{acq_time} (ms)"
    end rescue nil
  end

  # @param logger [::Logger,#debug]
  # @param log_sampled [Boolean]
  # @param lock_key [String]
  # @param queue_ttl [Integer]
  # @param acquier_id [String]
  # @param acq_time [Numeric]
  # @return [void]
  #
  # @api private
  # @since 1.7.0
  def reentrant_lock_obtained(
    logger,
    log_sampled,
    lock_key,
    queue_ttl,
    acquier_id,
    acq_time
  )
    return unless log_sampled

    logger.debug do
      "[redis_queued_locks.reentrant_lock_obtained] " \
      "lock_key => '#{lock_key}' " \
      "queue_ttl => #{queue_ttl} " \
      "acq_id => '#{acquier_id}' " \
      "acq_time => #{acq_time} (ms)"
    end rescue nil
  end

  # @param logger [::Logger,#debug]
  # @param log_sampled [Boolean]
  # @param lock_key [String]
  # @param queue_ttl [Integer]
  # @param acquier_id [String]
  # @param acq_time [Numeric]
  # @return [void]
  #
  # @api private
  # @since 1.7.0
  def lock_obtained(
    logger,
    log_sampled,
    lock_key,
    queue_ttl,
    acquier_id,
    acq_time
  )
    return unless log_sampled

    logger.debug do
      "[redis_queued_locks.lock_obtained] " \
      "lock_key => '#{lock_key}' " \
      "queue_ttl => #{queue_ttl} " \
      "acq_id => '#{acquier_id}' " \
      "acq_time => #{acq_time} (ms)"
    end rescue nil
  end
end
