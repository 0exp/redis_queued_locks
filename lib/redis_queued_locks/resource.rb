# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Resource
  # @return [String]
  #
  # @api private
  # @since 0.1.0
  LOCK_PATTERN = 'rql:lock:*'

  # @return [String]
  #
  # @api private
  # @since 0.1.0
  LOCK_QUEUE_PATTERN = 'rql:lock_queue:*'

  class << self
    # @param process_id [Integer,String]
    # @param thread_id [Integer,String]
    # @return [String]
    #
    # @api private
    # @since 0.1.0
    def acquier_identifier(process_id = get_process_id, thread_id = get_thread_id)
      "rql:acq:#{process_id}/#{thread_id}"
    end

    # @param lock_name [String]
    # @return [String]
    #
    # @api private
    # @since 0.1.0
    def prepare_lock_key(lock_name)
      "rql:lock:#{lock_name}"
    end

    # @param lock_name [String]
    # @return [String]
    #
    # @api private
    # @since 0.1.0
    def prepare_lock_queue(lock_name)
      "rql:lock_queue:#{lock_name}"
    end

    # @return [Integer] Redis's <Set> score that is calculated from the time (epoch) as an integer.
    #
    # @api private
    # @since 0.1.0
    def calc_initial_acquier_position
      Time.now.to_i
    end

    # @param queue_ttl [Integer] In seconds
    # @return [Integer] Redis's <Set> score barrier before wich all other acquiers are removed.
    #
    # @api private
    # @since 0.1.0
    def acquier_dead_score(queue_ttl)
      Time.now.to_i - queue_ttl
    end

    # @param lock_queue [String]
    # @return [String]
    #
    # @api private
    # @since 0.1.0
    def lock_key_from_queue(lock_queue)
      # NOTE: 15 is a start position of the lock name
      "rql:lock:#{lock_queue[15..]}"
    end

    # @return [Integer]
    #
    # @api private
    # @since 0.1.0
    def get_thread_id
      ::Thread.current.object_id
    end

    # @return [Integer]
    #
    # @api private
    # @since 0.1.0
    def get_process_id
      ::Process.pid
    end
  end
end
