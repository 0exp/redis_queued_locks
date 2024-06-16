# frozen_string_literal: true

# @api private
# @since 1.9.0
class RedisQueuedLocks::Swarm
  require_relative 'swarm/swarm_acquirers'
  require_relative 'swarm/swarm_element'
  require_relative 'swarm/probe_itself'
  require_relative 'swarm/flush_zombies'

  # @return [RedisQueuedLocks::Client]
  #
  # @api private
  # @since 1.9.0
  attr_reader :rql_client

  # @return [Thread]
  #
  # @api private
  # @since 1.9.0
  attr_reader :swarm_visor

  # @return [Ractor]
  #
  # @api private
  # @since 1.9.0
  attr_reader :probe_itself_element

  # @return [Ractor]
  #
  # @api private
  # @since 1.9.0
  attr_reader :flush_zombies_element

  # @param rql_client [RedisQueuedLocks::Client]
  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def initialize(rql_client)
    @rql_client = rql_client
    @swarm_visor = nil
    @probe_itself_element = RedisQueuedLocks::Swarm::ProbeItself.new(rql_client)
    @flush_zombies_element = RedisQueuedLocks::Swarm::FlushZombies.new(rql_client)
  end

  # @return [Hash<Symbol,Boolean|<Hash<Symbol,Boolean>>]
  #
  # @api public
  # @since 1.9.0
  def swarm_status
    swarm_enabled = rql_client.config[:swarm][:enabled]
    visor_running = swarm_visor != nil
    visor_alive = swarm_visor != nil && swarm_visor.alive?
    probe_itself_enabled = probe_itself_element.enabled?
    probe_itself_alive = probe_itself_element.alive?
    flush_zombies_enabled = flush_zombies_element.enabled?
    flush_zombies_alive = flush_zombies_element.alive?

    {
      enabled: swarm_enabled,
      visor: {
        running: visor_running,
        alive: visor_alive
      },
      probe_itself: {
        enabled: probe_itself_enabled,
        alive: probe_itself_alive
      },
      flush_zombies: {
        enabled: flush_zombies_enabled,
        alive: flush_zombies_alive
      }
    }
  end

  # @option zombie_ttl [Integer]
  # @return [Hash<String,Hash<Symbol,Float|Time>>]
  #
  # @api public
  # @since 1.9.0
  def swarm_info(zombie_ttl: rql_client.config[:swarm][:flush_zombies][:zombie_ttl])
    RedisQueuedLocks::Swarm::SwarmAcquirers.swarm_acquirers(
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
  # @option lock_flushing [Boolean]
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
    lock_scan_size: config[:swarm][:flush_zombies][:zombie_lock_scan_size],
    queue_scan_size: config[:swarm][:flush_zombies][:zombie_queue_scan_size],
    lock_flushing: config[:swarm][:flush_zombies][:lock_flushing],
    lock_flushing_ttl: config[:swarm][:flush_zombies][:lock_flushing_ttl]
  )
    RedisQueuedLocks::Swarm::FlushZombies.flush_zombies(
      rql_client.redis_client,
      zombie_ttl,
      lock_scan_size,
      queue_scan_size,
      lock_flushing,
      lock_flushing_ttl
    )
  end

  # @param redis_client [RedisClient]
  # @return [Hash<Symbol<Hash<Symbol,Boolean>>>]
  #
  # @see RedisQueuedLocks::Swarm#swarm_status
  #
  # @api public
  # @since 1.9.0
  def swarm!
    probe_itself_element.try_swarm!
    flush_zombies_element.try_swarm!

    @swarm_visor = Thread.new do
      loop do
        probe_itself_element.reswarm_if_dead!
        flush_zombies_element.reswarm_if_dead!
        sleep(rql_client.config[:swarm][:visor][:check_period])
      end
    end

    RedisQueuedLocks::Data[ok: true, result: swarm_status]
  end
end
