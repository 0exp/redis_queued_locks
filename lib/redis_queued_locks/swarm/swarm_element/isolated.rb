# frozen_string_literal: true

# @api private
# @since 1.9.0
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

  # @return [RedisQueuedLocks::Utilities::Lock]
  #
  # @api private
  # @since 1.9.0
  attr_reader :sync

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def initialize(rql_client)
    @rql_client = rql_client
    @swarm_element = nil
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
  def enabled?
    # NOTE: provide an <is enabled> logic here by analyzing the redis queued locks config.
  end

  # @return [Hash<Symbol,Boolean|Hash<Symbol,String|Boolean>>]
  #   Format: {
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
  def status
    sync.synchronize do
      ractor_running = swarmed__alive?
      ractor_state = swarmed? ? ractor_status(swarm_element) : 'non_initialized'

      main_loop_running = nil
      main_loop_state = nil
      begin
        main_loop_running = swarmed__running?
        main_loop_state =
          main_loop_running ? swarm_loop__status[:main_loop][:state] : 'non_initialized'
      rescue Ractor::ClosedError
        # NOTE: it can happend when you run RedisQueuedLocks::Swarm#deswarm!;
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
  # => 1) init (swarm!): create a ractor, main loop is not started;
  # => 2) start (swarm_loop__start!): run main lopp inside the ractor;
  # => 3) stop (swarm_loop__stop!): stop the main loop inside a ractor;
  # => 4) kill (swarm_loop__kill!): kill the main loop inside teh ractor and kill a ractor;
  #
  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def swarm!
    # IMPORTANT №1: initialize @swarm_element here with Ractor;
    # IMPORTANT №2: your Ractor should invoke .swarm_loop inside (see below);
    # IMPORTANT №3: you should pass the main loop logic as a block to .swarm_loop;
  end

  # @param main_loop_spawner [Block]
  # @return [void]
  #
  # @api private
  # @since 1.9.0
  # rubocop:disable Layout/ClassStructure, Lint/IneffectiveAccessModifier
  def self.swarm_loop(&main_loop_spawner)
    # NOTE:
    #   This self.-related part of code is placed in the middle of class in order
    #   to provide better code readability (it is placed next to the method inside
    #   wich it should be called (see #swarm!)). That's why some rubocop cops are disabled.

    main_loop = nil

    loop do
      command = Ractor.receive

      case command
      when :status
        main_loop_alive = main_loop != nil && main_loop.alive?
        main_loop_state =
          if main_loop == nil
            'non_initialized'
          else
            # NOTE: (full name resolution): ractor has no syntax-based constatnt context;
            RedisQueuedLocks::Utilities.thread_state(main_loop)
          end
        Ractor.yield({ main_loop: { alive: main_loop_alive, state: main_loop_state } })
      when :is_active
        Ractor.yield(main_loop != nil && main_loop.alive?)
      when :start
        main_loop.kill if main_loop != nil
        main_loop = yield # REFERENCE: `main_loop_spawner.call`
      when :stop
        main_loop.kill if main_loop != nil
      when :kill
        main_loop.kill if main_loop != nil
        exit
      end
    end
  end
  # rubocop:enable Layout/ClassStructure, Lint/IneffectiveAccessModifier

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
    swarm_element != nil && ractor_alive?(swarm_element)
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def swarmed__dead?
    swarm_element != nil && !ractor_alive?(swarm_element)
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def swarmed__running?
    swarm_element != nil && ractor_alive?(swarm_element) && swarm_loop__is_active
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def swarmed__stopped?
    swarm_element != nil && ractor_alive?(swarm_element) && !swarm_loop__is_active
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def swarm_loop__is_active
    return if idle? || swarmed__dead?
    sync.synchronize { swarm_element.send(:is_active).take }
  end

  # @return [Hash]
  #
  # @api private
  # @since 1.9.0
  def swarm_loop__status
    return if idle? || swarmed__dead?
    sync.synchronize { swarm_element.send(:status).take }
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def swarm_loop__start
    return if idle? || swarmed__dead?
    sync.synchronize { swarm_element.send(:start) }
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def swarm_loop__pause
    return if idle? || swarmed__dead?
    sync.synchronize { swarm_element.send(:stop) }
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def swarm_loop__kill
    return if idle? || swarmed__dead?
    sync.synchronize { swarm_element.send(:kill) }
  end
end
# rubocop:enable Metrics/ClassLength
