# frozen_string_literal: true

# @api public
# @since 0.1.0
# rubocop:disable Metrics/ClassLength
class RedisQueuedLocks::Client
  # @since 0.1.0
  include Qonfig::Configurable

  configuration do
    setting :retry_count, 3
    setting :retry_delay, 200 # NOTE: milliseconds
    setting :retry_jitter, 50 # NOTE: milliseconds
    setting :try_to_lock_timeout, 10 # NOTE: seconds
    setting :default_lock_ttl, 5_000 # NOTE: milliseconds
    setting :default_queue_ttl, 15 # NOTE: seconds
    setting :lock_release_batch_size, 100
    setting :instrumenter, RedisQueuedLocks::Instrument::VoidNotifier
    setting :uniq_identifier, -> { RedisQueuedLocks::Resource.calc_uniq_identity }

    # TODO: setting :logger, Logger.new(IO::NULL)
    # TODO: setting :debug, true/false

    validate('retry_count') { |val| val == nil || (val.is_a?(::Integer) && val >= 0) }
    validate('retry_delay') { |val| val.is_a?(::Integer) && val >= 0 }
    validate('retry_jitter') { |val| val.is_a?(::Integer) && val >= 0 }
    validate('try_to_lock_timeout') { |val| val == nil || (val.is_a?(::Integer) && val >= 0) }
    validate('default_lock_tt', :integer)
    validate('default_queue_ttl', :integer)
    validate('lock_release_batch_size', :integer)
    validate('instrumenter') { |val| RedisQueuedLocks::Instrument.valid_interface?(val) }
    validate('uniq_identifier', :proc)
  end

  # @return [RedisClient]
  #
  # @api private
  # @since 0.1.0
  attr_reader :redis_client

  # @return [String]
  #
  # @api private
  # @since 0.1.0
  attr_accessor :uniq_identity

  # NOTE: attr_access is chosen intentionally in order to have an ability to change
  #  uniq_identity values for debug purposes in runtime;

  # @param redis_client [RedisClient]
  #   Redis connection manager, which will be used for the lock acquierment and distribution.
  #   It should be an instance of RedisClient.
  # @param configs [Block]
  #   Custom configs for in-runtime configuration.
  # @return [void]
  #
  # @api public
  # @since 0.1.0
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
  # @option retry_count [Integer,NilClass]
  #   How many times we should try to acquire a lock. Nil means "infinite retries".
  # @option retry_delay [Integer]
  #   A time-interval between the each retry (in milliseconds).
  # @option retry_jitter [Integer]
  #   Time-shift range for retry-delay (in milliseconds).
  # @option instrumenter [#notify]
  #   See RedisQueuedLocks::Instrument::ActiveSupport for example.
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
  # @param block [Block]
  #   A block of code that should be executed after the successfully acquired lock.
  # @return [Hash<Symbol,Any>,yield]
  #   - Format: { ok: true/false, result: Symbol/Hash }.
  #   - If block is given the result of block's yeld will be returned.
  #
  # @api public
  # @since 0.1.0
  def lock(
    lock_name,
    ttl: config[:default_lock_ttl],
    queue_ttl: config[:default_queue_ttl],
    timeout: config[:try_to_lock_timeout],
    retry_count: config[:retry_count],
    retry_delay: config[:retry_delay],
    retry_jitter: config[:retry_jitter],
    raise_errors: false,
    fail_fast: false,
    identity: uniq_identity,
    &block
  )
    RedisQueuedLocks::Acquier.acquire_lock!(
      redis_client,
      lock_name,
      process_id: RedisQueuedLocks::Resource.get_process_id,
      thread_id: RedisQueuedLocks::Resource.get_thread_id,
      fiber_id: RedisQueuedLocks::Resource.get_fiber_id,
      ractor_id: RedisQueuedLocks::Resource.get_ractor_id,
      ttl:,
      queue_ttl:,
      timeout:,
      retry_count:,
      retry_delay:,
      retry_jitter:,
      raise_errors:,
      instrumenter: config[:instrumenter],
      identity:,
      fail_fast:,
      &block
    )
  end

  # @note See #lock method signature.
  #
  # @api public
  # @since 0.1.0
  def lock!(
    lock_name,
    ttl: config[:default_lock_ttl],
    queue_ttl: config[:default_queue_ttl],
    timeout: config[:try_to_lock_timeout],
    retry_count: config[:retry_count],
    retry_delay: config[:retry_delay],
    retry_jitter: config[:retry_jitter],
    fail_fast: false,
    identity: uniq_identity,
    &block
  )
    lock(
      lock_name,
      ttl:,
      queue_ttl:,
      timeout:,
      retry_count:,
      retry_delay:,
      retry_jitter:,
      raise_errors: true,
      identity:,
      fail_fast:,
      &block
    )
  end

  # @param lock_name [String] The lock name that should be released.
  # @return [Hash<Symbol,Any>] Format: { ok: true/false, result: Symbol/Hash }.
  #
  # @api public
  # @since 0.1.0
  def unlock(lock_name)
    RedisQueuedLocks::Acquier.release_lock!(redis_client, lock_name, config[:instrumenter])
  end

  # @param lock_name [String]
  # @return [Boolean]
  #
  # @api public
  # @since 0.1.0
  def locked?(lock_name)
    RedisQueuedLocks::Acquier.locked?(redis_client, lock_name)
  end

  # @param lock_name [String]
  # @return [Boolean]
  #
  # @api public
  # @since 0.1.0
  def queued?(lock_name)
    RedisQueuedLocks::Acquier.queued?(redis_client, lock_name)
  end

  # @param lock_name [String]
  # @return [Hash,NilClass]
  #
  # @api public
  # @since 0.1.0
  def lock_info(lock_name)
    RedisQueuedLocks::Acquier.lock_info(redis_client, lock_name)
  end

  # @param lock_name [String]
  # @return [Hash,NilClass]
  #
  # @api public
  # @since 0.1.0
  def queue_info(lock_name)
    RedisQueuedLocks::Acquier.queue_info(redis_client, lock_name)
  end

  # @param lock_name [String]
  # @param milliseconds [Integer] How many milliseconds should be added.
  # @return [?]
  #
  # @api public
  # @since 0.1.0
  def extend_lock_ttl(lock_name, milliseconds)
    RedisQueuedLocks::Acquier.extend_lock_ttl(redis_client, lock_name)
  end

  # @option batch_size [Integer]
  # @return [Hash<Symbol,Any>] Format: { ok: true/false, result: Symbol/Hash }.
  #
  # @api public
  # @since 0.1.0
  def clear_locks(batch_size: config[:lock_release_batch_size])
    RedisQueuedLocks::Acquier.release_all_locks!(redis_client, batch_size, config[:instrumenter])
  end
end
# rubocop:enable Metrics/ClassLength
