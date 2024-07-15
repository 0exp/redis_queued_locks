# frozen_string_literal: true

# @api private
# @since 1.9.0
# rubocop:disable Metrics/ClassLength
class RedisQueuedLocks::Swarm::SwarmElement::Threaded
  # @since 1.9.0
  include RedisQueuedLocks::Utilities

  # @return [RedisQueuedLocks::Client]
  #
  # @api private
  # @since 1.9.0
  attr_reader :rql_client

  # @return [Thread,NilClass]
  #
  # @api private
  # @since 1.9.0
  attr_reader :swarm_element

  # The main loop reference is only used inside the swarm element thread and
  # swarm element termination. It should not be used everywhere else!
  # This is strongly technical variable refenrece.
  #
  # @return [Thread,NilClass]
  #
  # @api private
  # @since 1.9.0
  attr_reader :main_loop

  # @return [Thread::SizedQueue,NilClass]
  #
  # @api private
  # @since 1.9.0
  attr_reader :swarm_element_commands

  # @return [Thread::SizedQueue]
  #
  # @api private
  # @since 1.9.0
  attr_reader :swarm_element_results

  # @return [RedisQueuedLocks::Utilities::Lock]
  #
  # @api private
  # @since 1.9.0
  attr_reader :sync

  # @param rql_client [RedisQueuedLocks::Client]
  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def initialize(rql_client)
    @rql_client = rql_client
    @swarm_element = nil
    @main_loop = nil # NOTE: strongly technical variable refenrece (see attr_reader docs)
    @swarm_element_commands = nil
    @swarm_element_results = nil
    @sync = RedisQueuedLocks::Utilities::Lock.new
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def try_swarm!
    return unless enabled?

    sync.synchronize do
      swarm_element__termiante
      swarm!
      swarm_loop__start
    end
  end

  # @return [void]
  #
  # @api private
  # @since 19.0.0
  def reswarm_if_dead!
    return unless enabled?

    sync.synchronize do
      if swarmed__stopped?
        swarm_loop__start
      elsif swarmed__dead? || idle?
        swarm!
        swarm_loop__start
      end
    end
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def try_kill!
    sync.synchronize do
      swarm_element__termiante
    end
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def enabled?
    # NOTE: provide an <is enabled> logic here by analyzing the redis queued locks config.
  end

  # @return [Hash<Symbol,Boolean|Hash<Symbol,String|Boolean>>]
  #   Format: {
  #     enabled: <Boolean>,
  #     thread: {
  #       running: <Boolean>,
  #       state: <String>,
  #     },
  #     main_loop: {
  #       running: <Boolean>,
  #       state: <String>
  #     }
  #   }
  #
  # @api private
  # @since 1.9.0
  # rubocop:disable Style/RedundantBegin
  def status
    sync.synchronize do
      thread_running = swarmed__alive?
      thread_state = swarmed? ? thread_state(swarm_element) : 'non_initialized'

      main_loop_running = swarmed__running?
      main_loop_state = begin
        if main_loop_running
          swarm_loop__status[:result][:main_loop][:state]
        else
          'non_initialized'
        end
      end

      {
        enabled: enabled?,
        thread: {
          running: thread_running,
          state: thread_state
        },
        main_loop: {
          running: main_loop_running,
          state: main_loop_state
        }
      }
    end
  end
  # rubocop:enable Style/RedundantBegin

  private

  # Swarm element lifecycle have the following flow:
  # => 1) init (swarm!): create a thread, main loop is not started;
  # => 2) start (swarm_loop__start): run the main lopp inside the created thread;
  # => 3) stop (swarm_loop__stop): stop the main loop inside the created thread;
  # => 4) terminate (swarm_element__termiante): kill the created thread;
  # In addition you should implement `#spawn_main_loop!` method that will be the main logic
  # of the your swarm element.
  #
  # @return [void]
  #
  # @api private
  # @since 1.9.0
  # rubocop:disable Metrics/MethodLength
  def swarm!
    # NOTE: kill the main loop at start to prevent any async-thread-race-based memory leaks;
    main_loop&.kill

    @swarm_element_commands = Thread::SizedQueue.new(1)
    @swarm_element_results = Thread::SizedQueue.new(1)

    @swarm_element = Thread.new do
      loop do
        command = swarm_element_commands.pop

        case command
        when :status
          main_loop_alive = main_loop != nil && main_loop.alive?
          main_loop_state = (main_loop == nil) ? 'non_initialized' : thread_state(main_loop)
          swarm_element_results.push({
            ok: true,
            result: { main_loop: { alive: main_loop_alive, state: main_loop_state } }
          })
        when :is_active
          is_active = main_loop != nil && main_loop.alive?
          swarm_element_results.push({ ok: true, result: { is_active: } })
        when :start
          main_loop&.kill
          @main_loop = spawn_main_loop!.tap { |thread| thread.abort_on_exception = false }
          swarm_element_results.push({ ok: true, result: nil })
        when :stop
          main_loop&.kill
          swarm_element_results.push({ ok: true, result: nil })
        end
      end
    end
  end
  # rubocop:enable Metrics/MethodLength

  # @return [Thread] Thread with #abort_onexception == false that wraps loop'ed logic;
  #
  # @api private
  # @since 1.9.0
  def spawn_main_loop!
    # NOTE:
    #   - provide the swarm element looped logic here wrapped into the thread;
    #   - created thread will be reconfigured inside the swarm_element logic with a
    #     `abort_on_exception = false` (cuz the stauts of the thread is
    #     totally controlled by the @swarm_element's logic);
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def idle?
    swarm_element == nil
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def swarmed?
    swarm_element != nil
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def swarmed__alive?
    swarmed? && swarm_element.alive? && !terminating?
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def swarmed__dead?
    swarmed? && (!swarm_element.alive? || terminating?)
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def swarmed__running?
    swarmed__alive? && !terminating? && (swarm_loop__is_active.yield_self do |result|
      result && result[:ok] && result[:result][:is_active]
    end)
  end

  # @return [Boolean,NilClass]
  #
  # @api private
  # @since 1.9.0
  # rubocop:disable Layout/MultilineOperationIndentation
  def terminating?
    swarm_element_commands == nil ||
    swarm_element_commands&.closed? ||
    swarm_element_results == nil ||
    swarm_element_results&.closed?
  end
  # rubocop:enable Layout/MultilineOperationIndentation

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def swarmed__stopped?
    swarmed__alive? && (terminating? || !(swarm_loop__is_active.yield_self do |result|
      result && result[:ok] && result[:result][:is_active]
    end))
  end

  # @return [Boolean,NilClass]
  #
  # @api private
  # @since 1.9.0
  def swarm_loop__is_active
    return if idle? || swarmed__dead? || terminating?
    sync.synchronize do
      swarm_element_commands.push(:is_active)
      swarm_element_results.pop
    end
  end

  # @return [Hash,NilClass]
  #
  # @api private
  # @since 1.9.0
  def swarm_loop__status
    return if idle? || swarmed__dead? || terminating?
    sync.synchronize do
      swarm_element_commands.push(:status)
      swarm_element_results.pop
    end
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def swarm_loop__start
    return if idle? || swarmed__dead? || terminating?
    sync.synchronize do
      swarm_element_commands.push(:start)
      swarm_element_results.pop
    end
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def swarm_loop__stop
    return if idle? || swarmed__dead? || terminating?
    sync.synchronize do
      swarm_element_commands.push(:stop)
      swarm_element_results.pop
    end
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def swarm_element__termiante
    return if idle? || swarmed__dead?
    sync.synchronize do
      main_loop&.kill
      swarm_element.kill
      swarm_element_commands.close
      swarm_element_results.close
      swarm_element_commands.clear
      swarm_element_results.clear
      @swarm_element_commands = nil
      @swarm_element_results = nil
    end
  end
end
# rubocop:enable Metrics/ClassLength
