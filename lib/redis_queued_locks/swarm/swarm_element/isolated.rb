# frozen_string_literal: true

# Swarm element isolated inside its own Ractor. Communication works via `Ractor::Port`s:
# - `swarm_element_results_port`: created in the main Ractor (where the Swarm and its Supervisor
#   live), receives element replies and the element ractor termination notice (`:exited`/`:aborted`,
#   registered via `Ractor#monitor`);
# - `swarm_element_commands_port`: created inside the element ractor (only the creator ractor can
#   receive from a port) and handed over to the main Ractor during the element startup;
# Each element instance owns its own pair of ports, so any number of isolated elements can work
# side by side.
#
# @api private
# @since 1.9.0
# @version 1.17.0
# rubocop:disable Metrics/ClassLength
class RedisQueuedLocks::Swarm::SwarmElement::Isolated
  # @since 1.9.0
  include RedisQueuedLocks::Utilities

  # @return [RedisQueuedLocks::Client]
  #
  # @api private
  # @since 1.9.0
  attr_reader :rql_client

  # @return [Ractor,NilClass]
  #
  # @api private
  # @since 1.9.0
  attr_reader :swarm_element

  # Port of the element ractor that receives commands (created inside the element ractor).
  #
  # @return [Ractor::Port,NilClass]
  #
  # @api private
  # @since 1.17.0
  attr_reader :swarm_element_commands_port

  # Port of the main Ractor that receives element replies and the element termination notice.
  #
  # @return [Ractor::Port,NilClass]
  #
  # @api private
  # @since 1.17.0
  attr_reader :swarm_element_results_port

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
  # @version 1.17.0
  def initialize(rql_client)
    @rql_client = rql_client
    @swarm_element = nil
    @swarm_element_commands_port = nil
    @swarm_element_results_port = nil
    @sync = RedisQueuedLocks::Utilities::Lock.new
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def try_swarm!
    return unless enabled?

    sync.synchronize do
      swarm_loop__kill
      swarm!
      swarm_loop__start
    end
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
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
      swarm_loop__kill
    end
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def enabled? # steep:ignore
    # NOTE: provide an <is enabled> logic here by analyzing the redis queued locks config.
  end

  # @return [Hash<Symbol,Boolean|Hash<Symbol,String|Boolean>>] Format:
  #   {
  #     enabled: <Boolean>,
  #     ractor: {
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
  # @version 1.17.0
  def status
    sync.synchronize do
      ractor_running = swarmed__alive?
      ractor_state = swarmed? ? ractor_status(swarm_element) : 'non_initialized' # steep:ignore

      # NOTE: `nil` when the element ractor is not alive (or has died during the request);
      loop_status = swarm_loop__status
      if loop_status && loop_status[:alive]
        main_loop_running = true
        main_loop_state = loop_status[:state]
      else
        main_loop_running = false
        main_loop_state = 'non_initialized'
      end

      {
        enabled: enabled?,
        ractor: {
          running: ractor_running,
          state: ractor_state
        },
        main_loop: {
          running: main_loop_running,
          state: main_loop_state
        }
      }
    end
  end

  private

  # Swarm element lifecycle have the following scheme:
  # => 1) init (swarm!): create a results port and a ractor (main loop is not started),
  #       receive the ractor's command port;
  # => 2) start (swarm_loop__start): run the main loop inside the ractor;
  # => 3) stop (swarm_loop__stop): stop the main loop inside the ractor;
  # => 4) kill (swarm_loop__kill): kill the main loop inside the ractor and finish the ractor;
  #
  # @return [void]
  #
  # @api private
  # @since 1.9.0
  # @version 1.17.0
  def swarm!
    # NOTE: the results port is created in the current (main) Ractor: only it can receive from it;
    results = Ractor::Port.new
    element = spawn_swarm_element!(results)
    @swarm_element_results_port = results
    @swarm_element = element
    # NOTE: `:exited`/`:aborted` will be sent to the results port when the ractor is finished
    #   (immediately if it is already finished), so no request can wait for a reply forever;
    element.monitor(results)
    # NOTE: the first message from the element ractor is its command port (see .swarm_loop),
    #   any other message is the termination notice (the ractor has died during the startup);
    handshake = results.receive
    @swarm_element_commands_port = handshake.is_a?(Ractor::Port) ? handshake : nil
  end

  # @param swarm_element_results_port [Ractor::Port] Results port of the main Ractor.
  # @return [Ractor]
  #
  # @api private
  # @since 1.17.0
  def spawn_swarm_element!(swarm_element_results_port) # steep:ignore
    # IMPORTANT №1: create and return a Ractor here (pass `swarm_element_results_port` and all
    #   required configs into `Ractor.new` as shareable/copyable values);
    # IMPORTANT №2: your Ractor should invoke .swarm_loop(swarm_element_results_port) inside
    #   (see below);
    # IMPORTANT №3: you should pass the main loop logic as a block to .swarm_loop
    #   (the block should return a Thread that wraps the looped logic);
  end

  # Internal protocol (bare scalars/primitives, no `{ ok:, result: }` wrapper):
  #   - handshake: the command port itself (the first message on the results port);
  #   - `:status` => `{ alive: <Boolean>, state: <String> }`;
  #   - `:is_active` => `true`/`false`;
  #   - `:start`, `:stop`, `:kill` => `true` (ack);
  #   - Symbol messages on the results port are reserved for the Ractor#monitor notice;
  #
  # @param swarm_element_results_port [Ractor::Port] Results port of the main Ractor.
  # @param main_loop_spawner [Block]
  # @return [void]
  #
  # @api private
  # @since 1.9.0
  # @version 1.17.0
  # rubocop:disable Layout/ClassStructure, Lint/IneffectiveAccessModifier, Metrics/MethodLength
  def self.swarm_loop(swarm_element_results_port, &main_loop_spawner)
    # NOTE:
    #   This self.-related part of code is placed in the middle of class in order
    #   to provide better code readability (it is placed next to the method inside
    #   wich it should be called (see #spawn_swarm_element!)). That's why some rubocop
    #   cops are disabled.

    # NOTE: the command port should be created inside the element ractor (only the creator
    #   ractor can receive from the port), so it is handed over to the main Ractor at startup;
    swarm_element_commands_port = Ractor::Port.new
    swarm_element_results_port << swarm_element_commands_port

    # @type var main_loop: Thread?
    main_loop = nil

    loop do
      command = swarm_element_commands_port.receive

      case command
      when :status
        main_loop_alive = main_loop != nil && main_loop.alive? # steep:ignore
        main_loop_state =
          if main_loop == nil
            'non_initialized'
          else
            # @type var main_loop: Thread
            RedisQueuedLocks::Utilities.thread_state(main_loop)
          end
        swarm_element_results_port << { alive: main_loop_alive, state: main_loop_state }
      when :is_active
        swarm_element_results_port << (main_loop != nil && main_loop.alive?) # steep:ignore
      when :start
        terminate_thread(main_loop)
        # REFERENCE: `main_loop_spawner.call`
        main_loop = yield.tap { |thread| thread.abort_on_exception = false }
        swarm_element_results_port << true
      when :stop
        terminate_thread(main_loop)
        swarm_element_results_port << true
      when :kill
        # NOTE: terminate the main loop and all auxiliary threads it may have left behind (for
        #   example, socket connection helper threads when the loop is killed during connection):
        #   the ractor stays alive while it has unfinished threads;
        (::Thread.list - [::Thread.current]).each { |thread| terminate_thread(thread) }
        swarm_element_results_port << true
        break
      end
    end
  end
  # rubocop:enable Layout/ClassStructure, Lint/IneffectiveAccessModifier, Metrics/MethodLength

  # Kills the thread and waits for its termination: the ractor can not finish
  # (and its status stays "running") while it has unfinished threads.
  #
  # @param thread [Thread,NilClass]
  # @return [void]
  #
  # @api private
  # @since 1.17.0
  # rubocop:disable Lint/IneffectiveAccessModifier
  def self.terminate_thread(thread)
    return if thread == nil
    thread.kill
    # NOTE: join re-raises the exception that has failed the thread: it is not our case here;
    thread.join rescue nil
  end
  # rubocop:enable Lint/IneffectiveAccessModifier

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
    swarm_element != nil && ractor_alive?(swarm_element) # steep:ignore
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def swarmed__dead?
    swarm_element != nil && !ractor_alive?(swarm_element) # steep:ignore
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  # @version 1.17.0
  def swarmed__running?
    swarmed__alive? && swarm_loop__is_active == true
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  # @version 1.17.0
  def swarmed__stopped?
    # NOTE: `nil` (the element ractor has died during the request) is neither active nor stopped;
    swarmed__alive? && swarm_loop__is_active == false
  end

  # @return [Boolean,NilClass] Is the main loop alive (`nil` when the element is not available).
  #
  # @api private
  # @since 1.9.0
  # @version 1.17.0
  def swarm_loop__is_active
    reply = swarm_loop__request(:is_active)
    reply.is_a?(Hash) ? nil : reply
  end

  # @return [Hash<Symbol,Boolean|String>,NilClass]
  #   Format: `{ alive: <Boolean>, state: <String> }` (`nil` when the element is not available).
  #
  # @api private
  # @since 1.9.0
  # @version 1.17.0
  def swarm_loop__status
    reply = swarm_loop__request(:status)
    reply.is_a?(Hash) ? reply : nil
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  # @version 1.17.0
  def swarm_loop__start
    swarm_loop__request(:start)
  end

  # @return [void]
  #
  # @api private
  # @since 1.17.0
  def swarm_loop__stop
    swarm_loop__request(:stop)
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  # @version 1.17.0
  def swarm_loop__kill
    sync.synchronize do
      # NOTE: wait for the ractor finish only when it has confirmed the kill command;
      killed = swarm_loop__request(:kill) == true
      @swarm_element_commands_port = nil
      swarm_element.join if killed # steep:ignore
    end
  rescue Ractor::RemoteError
    # NOTE: the element ractor has been finished with an exception: it is dead anyway;
  end

  # Sends the command to the element ractor and waits for its reply. Replies are received
  # strictly one by one under the lock, so each reply belongs to the sent command.
  #
  # @param command [Symbol]
  # @return [Boolean,Hash<Symbol,Boolean|String>,NilClass]
  #   The bare reply value (see .swarm_loop) or `nil` if the element is dead.
  #
  # @api private
  # @since 1.17.0
  def swarm_loop__request(command)
    return if idle? || swarmed__dead? || swarm_element_commands_port == nil
    sync.synchronize do
      swarm_element_commands_port << command
      reply = swarm_element_results_port.receive # steep:ignore
      # NOTE: Symbol replies are reserved for the Ractor#monitor notice (`:exited`/`:aborted`);
      reply.is_a?(Symbol) ? nil : reply
    end
  rescue Ractor::ClosedError
    # NOTE: the command port is closed together with the finished element ractor;
    nil
  end
end
# rubocop:enable Metrics/ClassLength
