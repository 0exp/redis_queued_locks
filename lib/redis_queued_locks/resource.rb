# frozen_string_literal: true

# @api private
# @since 1.0.0
module RedisQueuedLocks::Resource
  # @return [String]
  #
  # @api private
  # @since 1.0.0
  KEY_PATTERN = 'rql:lock*'

  # @return [String]
  #
  # @api private
  # @since 1.0.0
  LOCK_PATTERN = 'rql:lock:*'

  # @return [String]
  #
  # @api private
  # @since 1.0.0
  LOCK_QUEUE_PATTERN = 'rql:lock_queue:*'

  class << self
    # Returns 16-byte unique identifier. It is used for uniquely
    # identify current process between different nodes/pods of your application
    # during the lock obtaining and self-identifying in the lock queue.
    #
    # @return [String]
    #
    # @api private
    # @since 1.0.0
    def calc_uniq_identity
      SecureRandom.hex(8)
    end

    # @param process_id [Integer,String]
    # @param thread_id [Integer,String]
    # @param fiber_id [Integer,String]
    # @param ractor_id [Integer,String]
    # @param identity [String]
    # @return [String]
    #
    # @api private
    # @since 1.0.0
    def acquier_identifier(process_id, thread_id, fiber_id, ractor_id, identity)
      "rql:acq:#{process_id}/#{thread_id}/#{fiber_id}/#{ractor_id}/#{identity}"
    end

    # @param lock_name [String]
    # @return [String]
    #
    # @api private
    # @since 1.0.0
    def prepare_lock_key(lock_name)
      "rql:lock:#{lock_name}"
    end

    # @param lock_name [String]
    # @return [String]
    #
    # @api private
    # @since 1.0.0
    def prepare_lock_queue(lock_name)
      "rql:lock_queue:#{lock_name}"
    end

    # @return [Float] Redis's <Set> score that is calculated from the time (epoch) as a float.
    #
    # @api private
    # @since 1.0.0
    def calc_initial_acquier_position
      Time.now.to_f
    end

    # @param queue_ttl [Integer] In seconds
    # @return [Float] Redis's <Set> score barrier for acquiers that should be removed from queue.
    #
    # @api private
    # @since 1.0.0
    def acquier_dead_score(queue_ttl)
      Time.now.to_f - queue_ttl
    end

    # @param acquier_position [Float]
    #   A time (epoch, seconds.microseconds) that represents
    #   the acquier position in lock request queue.
    # @parma queue_ttl [Integer]
    #   In second.
    # @return [Boolean]
    #   Is the lock request time limit has reached or not.
    #
    # @api private
    # @since 1.0.0
    def dead_score_reached?(acquier_position, queue_ttl)
      (acquier_position + queue_ttl) < Time.now.to_f
    end

    # @param lock_queue [String]
    # @return [String]
    #
    # @api private
    # @since 1.0.0
    def lock_key_from_queue(lock_queue)
      # NOTE: 15 is a start position of the lock name
      "rql:lock:#{lock_queue[15..]}"
    end

    # @return [Integer]
    #
    # @api private
    # @since 1.0.0
    def get_thread_id
      ::Thread.current.object_id
    end

    # @return [Integer]
    #
    # @api private
    # @since 1.0.0
    def get_fiber_id
      ::Fiber.current.object_id
    end

    # @return [Integer]
    #
    # @api private
    # @since 1.0.0
    def get_ractor_id
      ::Ractor.current.object_id
    end

    # @return [Integer]
    #
    # @api private
    # @since 1.0.0
    def get_process_id
      ::Process.pid
    end
  end
end
