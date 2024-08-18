# frozen_string_literal: true

# @api private
# @since 1.13.0
module RedisQueuedLocks::Utilities::Timeout::Process
  # @return [Thread]
  #
  # @api private
  # @since 1.13.0
  attr_reader :causing_thread

  # @return [Integer]
  #
  # @api private
  # @since 1.13.0
  attr_reader :timeout_period

  # @return [Class<Exception>]
  #
  # @api private
  # @since 1.13.0
  attr_reader :klass_for_failure

  # @return [String]
  #
  # @api private
  # @since 1.13.0
  attr_reader :message_for_failure

  # @return [Float]
  #
  # @api private
  # @since 1.13.0
  attr_reader :process_deadline

  # @return [Mutext]
  #
  # @api private
  # @since 1.13.0
  attr_reader :process_state_lock

  # @return [Boolean]
  #
  # @api private
  # @since 1.13.0
  attr_reader :process_finished

  # @param causing_thread [Thread] Thread that causes a timeout
  # @param timeout_period [Integer] Required period of time
  # @param klass_for_failure [Class<Exception>]
  # @param messafe_for_failure [String]
  # @return [void]
  def initialize(
    causing_thread,
    timeout_period,
    klass_for_failure,
    message_for_failure
  )
    @causing_thread = causing_thread
    @timeout_period = timeout_period
    @process_deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout_period
    @klass_for_failure = klass_for_failure
    @message_for_failure = message_for_failure
    @process_state_lock = ::Mutex.new
    @process_finished = false
  end

  # @return [void]
  #
  # @api private
  # @since 1.13.0
  def iterrupt
    process_state_lock.synchronize do
      unless process_finished
        causing_thread.raise(klass_for_failure, message_for_failure)
        @process_finished = true
      end
    end
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.13.0
  def finished?
    process_state_lock.synchronize { process_finished }
  end

  # @param monotonic_clock_time [Float]
  # @return [Boolean]
  #
  # @api private
  # @since 1.13.0
  def expired?(monotonic_clock_time)
    monotonic_clock_time >= process_deadline
  end

  def finish!
    process_state_lock.synchronize { @process_finshed = false }
  end
end
