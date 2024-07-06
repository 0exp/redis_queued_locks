# frozen_string_literal: true

# @api private
# @since 1.9.0
module RedisQueuedLocks::Swarm::SwarmElement
  require_relative 'swarm_element/isolated'
  require_relative 'swarm_element/threaded'
end
