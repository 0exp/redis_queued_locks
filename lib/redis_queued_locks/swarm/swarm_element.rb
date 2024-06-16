# frozen_string_literal: true

# @api private
# @since 1.9.0
class RedisQueuedLocks::Swarm::SwarmElement
  # @return [RedisQueuedLocks::Client]
  #
  # @api private
  # @since 1.9.0
  attr_reader :rql_client

  # @return [NilClass,Ractor]
  #
  # @api private
  # @since 1.9.0
  attr_reader :swarm_element

  # @param rql_client [RedisQueuedLocks::Client]
  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def initialize(rql_client)
    @rql_client = rql_client
    @swarm_element = nil
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def try_swarm!
    return if alive?
    swarm! && start! if enabled?
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def reswarm_if_dead!
    try_swarm! unless alive?
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def enabled?
    # NOTE: check configs for the correspondng swarm element
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def alive?
    swarm_element != nil && RedisQueuedLocks::Utilities.ractor_alive?(swarm_element)
  end

  # @return [Hash<Symbol,Boolean,Hash<Symbol,Boolean>>]
  #
  # @api private
  # @since 1.9.0
  def swarm_status
    swarm_element.send(:status).take
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def run!
    swarm_element.send(:start)
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def stop!
    swarm_element.send(:stop)
  end

  private

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def swarm!
    # NOTE: Initialize @swarm_element here with a Ractor object
  end
end
