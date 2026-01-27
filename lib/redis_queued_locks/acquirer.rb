# frozen_string_literal: true

# @api private
# @since 1.0.0
module RedisQueuedLocks::Acquirer
  require_relative 'acquirer/acquire_lock'
  require_relative 'acquirer/lock_series_poc'
  require_relative 'acquirer/release_lock'
  require_relative 'acquirer/release_all_locks'
  require_relative 'acquirer/release_locks_of'
  require_relative 'acquirer/is_locked'
  require_relative 'acquirer/is_queued'
  require_relative 'acquirer/lock_info'
  require_relative 'acquirer/queue_info'
  require_relative 'acquirer/locks'
  require_relative 'acquirer/queues'
  require_relative 'acquirer/keys'
  require_relative 'acquirer/extend_lock_ttl'
  require_relative 'acquirer/clear_dead_requests'
end
