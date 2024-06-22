# frozen_string_literal: true

# @api private
# @since 1.9.0
class RedisQueuedLocks::Swarm
  require_relative 'swarm/redis_client_builder'
  require_relative 'swarm/supervisor'
  require_relative 'swarm/acquirers'
  require_relative 'swarm/swarm_element'
  require_relative 'swarm/probe_itself'
  require_relative 'swarm/flush_zombies'

  # @return [RedisQueuedLocks::Client]
  #
  # @api private
  # @since 1.9.0
  attr_reader :rql_client

  # @return [RedisQueuedLocks::Swarm::Supervisor]
  #
  # @api private
  # @since 1.9.0
  attr_reader :supervisor

  # @return [RedisQueuedLocks::Swarm::ProbeItself]
  #
  # @api private
  # @since 1.9.0
  attr_reader :probe_itself_element

  # @return [RedisQueuedLocks::Swarm::FlushZombies]
  #
  # @api private
  # @since 1.9.0
  attr_reader :flush_zombies_element

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
    @sync = RedisQueuedLocks::Utilities::Lock.new
    @supervisor = RedisQueuedLocks::Swarm::Supervisor.new(rql_client)
    @probe_itself_element = RedisQueuedLocks::Swarm::ProbeItself.new(rql_client)
    @flush_zombies_element = RedisQueuedLocks::Swarm::FlushZombies.new(rql_client)
  end

  # @return [Hash<Symbol,Boolean|<Hash<Symbol,Boolean>>]
  #
  # @api public
  # @since 1.9.0
  def swarm_status
    sync.synchronize do
      {
        auto_swarm: rql_client.config[:swarm][:auto_swarm],
        supervisor: supervisor.status,
        probe_itself: probe_itself_element.status,
        flush_zombies: flush_zombies_element.status
      }
    end
  end

  # @option zombie_ttl [Integer]
  # @return [Hash<String,Hash<Symbol,Float|Time>>]
  #
  # @api public
  # @since 1.9.0
  def swarm_info(zombie_ttl: rql_client.config[:swarm][:flush_zombies][:zombie_ttl])
    RedisQueuedLocks::Swarm::Acquirers.acquirers(
      rql_client.redis_client,
      zombie_ttl
    )
  end

  # @return [
  #   RedisQueuedLocks::Data[
  #     ok: <Boolean>,
  #     acq_id: <String>,
  #     probe_score: <Float>
  #   ]
  # ]
  #
  # @api public
  # @since 1.9.0
  def probe_itself
    RedisQueuedLocks::Swarm::ProbeItself.probe_itself(
      rql_client.redis_client,
      rql_client.current_acquier_id
    )
  end

  # @option zombie_ttl [Integer]
  # @option lock_scan_size [Integer]
  # @option queue_scan_size [Integer]
  # @return [
  #   RedisQueuedLocks::Data[
  #     ok: <Boolean>,
  #     del_zombie_acqs: <Array<String>>,
  #     del_zombie_locks: <Set<String>>
  #   ]
  # ]
  #
  # @api public
  # @since 1.9.0
  def flush_zombies(
    zombie_ttl: rql_client.config[:swarm][:flush_zombies][:zombie_ttl],
    lock_scan_size: rql_client.config[:swarm][:flush_zombies][:zombie_lock_scan_size],
    queue_scan_size: rql_client.config[:swarm][:flush_zombies][:zombie_queue_scan_size]
  )
    RedisQueuedLocks::Swarm::FlushZombies.flush_zombies(
      rql_client.redis_client,
      zombie_ttl,
      lock_scan_size,
      queue_scan_size
    )
  end

  # @option silently [Boolean]
  # @return [NilClass,Hash<Symbol,Symbol|Boolean>]
  #
  # @api public
  # @since 1.9.0
  def swarm!
    sync.synchronize do
      # Step 0:
      #   - stop the supervisor (kill internal observer objects if supervisor is alredy running);
      supervisor.stop!

      # Step 1:
      #   - initialize swarm elements and start their main loop;
      probe_itself_element.try_swarm!
      flush_zombies_element.try_swarm!

      # Step 2:
      #   - run supercisor that should keep running created swarm elements and their main loops;
      unless supervisor.running?
        supervisor.observe! do
          probe_itself_element.reswarm_if_dead!
          flush_zombies_element.reswarm_if_dead!
        end
      end

      # NOTE: need to give a little timespot to initialize ractor objects and their main loops;
      sleep(0.1)

      RedisQueuedLocks::Data[ok: true, result: :swarming]
    end
  end

  # @option silently [Boolean]
  # @return [NilClass,Hash<Symbol,Symbol|Boolean>]
  #
  # @api private
  # @since 1.9.0
  def deswarm!
    sync.synchronize do
      supervisor.stop!
      probe_itself_element.try_kill!
      flush_zombies_element.try_kill!

      # NOTE: need to give a little timespot to initialize ractor objects and their main loops;
      sleep(0.1)

      RedisQueuedLocks::Data[ok: true, result: :terminating]
    end
  end
end
