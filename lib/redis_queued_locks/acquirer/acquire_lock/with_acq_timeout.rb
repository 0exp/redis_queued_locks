# frozen_string_literal: true

# @api private
# @since 1.0.0
module RedisQueuedLocks::Acquirer::AcquireLock::WithAcqTimeout
  # @param redis [RedisClient]
  #   Redis connection manager required for additional data extraction for error message.
  # @param timeout [NilClass,Integer]
  #   Time period after which the logic will fail with timeout error.
  # @param lock_key [String]
  #   Lock name in RQL notation (rql:lock:some-lock-name).
  # @param read_lock_key [String]
  #   - ?
  # @param write_lock_key [String]
  #   - ?
  # @param read_write_mode [Symbol]
  #   - ?
  # @param lock_name [String]
  #   Original lock name passed by the businessl logic (without RQL notaiton parts).
  # @param raise_errors [Boolean]
  #   Raise erros on exceptional cases.
  # @param detailed_acq_timeout_error [Boolean]
  #   Add additional error data about lock queue and required lock to the timeout error or not.
  # @option on_timeout [Proc,NilClass]
  #   Callback invoked on Timeout::Error.
  # @param block [Block] Custom logic that should be invoked under the obtained lock.
  # @return [Any]
  #
  # @raise [RedisQueuedLocks::LockAcquirementIntermediateTimeoutError]
  # @raise [RedisQueuedLocks::LockAcquirementTimeoutError]
  #
  # @api private
  # @since 1.0.0
  # @version 1.11.0
  def with_acq_timeout(
    redis,
    timeout,
    lock_key,
    read_lock_key,
    write_lock_key,
    read_write_mode,
    lock_name,
    raise_errors,
    detailed_acq_timeout_error,
    on_timeout: nil,
    &block
  )
    ::Timeout.timeout(timeout, RedisQueuedLocks::LockAcquirementIntermediateTimeoutError, &block)
  rescue RedisQueuedLocks::LockAcquirementIntermediateTimeoutError
    if on_timeout != nil
      # @type var on_timeout: Proc
      on_timeout.call
    end

    if raise_errors
      if detailed_acq_timeout_error
        # TODO: rewrite these invocations to separated inner-AcquireLock-related modules
        #   in order to remove any dependencies from the other public RQL commands cuz
        #   all AcquireLock logic elements should be fully independent from others as a core;
        lock_info = RedisQueuedLocks::Acquirer::LockInfo.lock_info(redis, lock_name)
        queue_info = RedisQueuedLocks::Acquirer::QueueInfo.queue_info(redis, lock_name)

        # rubocop:disable Metrics/BlockNesting
        raise(
          RedisQueuedLocks::LockAcquirementTimeoutError,
          "Failed to acquire the lock \"#{lock_key}\" " \
          "for the given <#{timeout} seconds> timeout. Details: " \
          "<Lock Data> => #{lock_info ? lock_info.inspect : '<no_data>'}; " \
          "<Queue Data> => #{queue_info ? queue_info.inspect : '<no_data>'};"
        )
        # rubocop:enable Metrics/BlockNesting
      else
        raise(
          RedisQueuedLocks::LockAcquirementTimeoutError,
          "Failed to acquire the lock \"#{lock_key}\" " \
          "for the given <#{timeout} seconds> timeout."
        )
      end
    end
  end
end
