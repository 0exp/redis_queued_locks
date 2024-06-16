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
    swarm! if enabled?
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
    # NOTE: Check RedisQueuedLocks config here for the correspondng swarm element
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def alive?
    swarm_element != nil && RedisQueuedLocks::Utilities.ractor_alive?(swarm_element)
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
