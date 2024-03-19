# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Acquier::AcquireLock::WithAcqTimeout
  # @param timeout [NilClass,Integer]
  #   Time period after which the logic will fail with timeout error.
  # @param lock_key [String]
  #   Lock name.
  # @param raise_errors [Boolean]
  #   Raise erros on exceptional cases.
  # @option on_timeout [Proc,NilClass]
  #   Callback invoked on Timeout::Error.
  # @return [Any]
  #
  # @api private
  # @since 0.1.0
  def with_acq_timeout(timeout, lock_key, raise_errors, on_timeout: nil, &block)
    ::Timeout.timeout(timeout, &block)
  rescue ::Timeout::Error
    on_timeout.call unless on_timeout == nil

    if raise_errors
      raise(RedisQueuedLocks::LockAcquiermentTimeoutError, <<~ERROR_MESSAGE.strip)
        Failed to acquire the lock "#{lock_key}" for the given timeout (#{timeout} seconds).
      ERROR_MESSAGE
    end
  end
end
