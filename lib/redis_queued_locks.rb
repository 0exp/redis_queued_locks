# frozen_string_literal: true

require 'redis-client'
require 'qonfig'
require 'timeout'
require 'securerandom'

# @api public
# @since 0.1.0
module RedisQueuedLocks
  require_relative 'redis_queued_locks/version'
  require_relative 'redis_queued_locks/errors'
  require_relative 'redis_queued_locks/utilities'
  require_relative 'redis_queued_locks/data'
  require_relative 'redis_queued_locks/debugger'
  require_relative 'redis_queued_locks/resource'
  require_relative 'redis_queued_locks/acquier'
  require_relative 'redis_queued_locks/instrument'
  require_relative 'redis_queued_locks/client'

  # @since 0.1.0
  extend RedisQueuedLocks::Debugger::Interface
end
