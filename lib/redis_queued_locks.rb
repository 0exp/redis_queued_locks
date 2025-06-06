# frozen_string_literal: true

require 'timeout'
require 'redis-client'
require 'securerandom'
require 'logger'

# @api public
# @since 1.0.0
module RedisQueuedLocks
  require_relative 'redis_queued_locks/version'
  require_relative 'redis_queued_locks/errors'
  require_relative 'redis_queued_locks/utilities'
  require_relative 'redis_queued_locks/logging'
  require_relative 'redis_queued_locks/data'
  require_relative 'redis_queued_locks/debugger'
  require_relative 'redis_queued_locks/resource'
  require_relative 'redis_queued_locks/acquirer'
  require_relative 'redis_queued_locks/instrument'
  require_relative 'redis_queued_locks/swarm'
  require_relative 'redis_queued_locks/client'
  require_relative 'redis_queued_locks/config'

  # @since 1.0.0
  extend RedisQueuedLocks::Debugger::Interface
end
