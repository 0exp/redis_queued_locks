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

  # @return [String]
  #
  # @api private
  # @since ?.?.?
  READ_LOCK_QUEUE_PATTERN = 'rql:lock_queue:*:read'

  # @return [String]
  #
  # @api private
  # @since ?.?.?
  WRITE_LOCK_QUEUE_PATTERN = 'rql:lock_queue:*:write'

  # @return [String]
  #
  # @api private
  # @since 1.9.0
  SWARM_KEY = 'rql:swarm:hsts'

  # @return [Integer] Redis time error (in milliseconds).
  #
  # @api private
  # @since 1.3.0
  REDIS_TIMESHIFT_ERROR = 2

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
    def acquirer_identifier(process_id, thread_id, fiber_id, ractor_id, identity)
      "rql:acq:#{process_id}/#{thread_id}/#{fiber_id}/#{ractor_id}/#{identity}"
    end

    # @param process_id [Integer,String]
    # @param thread_id [Integer,String]
    # @param ractor_id [Integer,String]
    # @param identity [String]
    # @return [String]
    #
    # @api private
    # @since 1.9.0
    def host_identifier(process_id, thread_id, ractor_id, identity)
      # NOTE:
      #   - fiber's object_id is not used cuz we can't analyze fiber objects via ObjectSpace
      #     after the any new Ractor object is created in the current process
      #     (ObjectSpace no longer sees objects of Thread and Fiber classes after that);
      "rql:hst:#{process_id}/#{thread_id}/#{ractor_id}/#{identity}"
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

    # @param lock_name [String]
    # @return [String]
    #
    # @api private
    # @api ?.?.?
    def prepare_read_lock_queue(lock_name)
      "rql:lock_queue:#{lock_name}:read"
    end

    # @param lock_name [String]
    # @return [String]
    #
    # @api private
    # @api ?.?.?
    def prepare_write_lock_queue(lock_name)
      "rql:lock_queue:#{lock_name}:write"
    end

    # @return [Float] Redis's <Set> score that is calculated from the time (epoch) as a float.
    #
    # @api private
    # @since 1.0.0
    def calc_initial_acquirer_position
      Time.now.to_f
    end

    # @param queue_ttl [Numeric] In seconds
    # @return [Float] Redis's <Set> score barrier for acquirers that should be removed from queue.
    #
    # @api private
    # @since 1.0.0
    def acquirer_dead_score(queue_ttl)
      Time.now.to_f - queue_ttl
    end

    # @param zombie_ttl [Float] In seconds with milliseconds.
    # @return [Float]
    #
    # @api private
    # @since 1.9.0
    def calc_zombie_score(zombie_ttl)
      Time.now.to_f - zombie_ttl
    end

    # @param acquirer_position [Float]
    #   A time (epoch, seconds.milliseconds) that represents
    #   the acquirer position in lock request queue.
    # @param queue_ttl [Integer]
    #   In second.
    # @return [Boolean]
    #   Is the lock request time limit has reached or not.
    #
    # @api private
    # @since 1.0.0
    def dead_score_reached?(acquirer_position, queue_ttl)
      (acquirer_position + queue_ttl) < Time.now.to_f
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

    # @return [Array<String>]
    #
    # @api private
    # @since 1.9.0
    def possible_host_identifiers(identity)
      # NOTE №1: we can not use ObjectSpace.each_object for Thread and Fiber cuz after the any
      #   ractor creation the ObjectSpace stops seeing ::Thread and ::Fiber objects: each_object
      #   for each of them returns `0`;
      # NOTE №2: we have no any approach to count Fiber objects in the current process without
      #   object space API (or super memory-expensive) so host identification works without fibers;
      # NOTE №3: we still can extract thread objects via Thread.list API;

      # @type var current_process_id: Integer
      current_process_id = get_process_id
      # @type var current_threads: Array[Thread]
      current_threads = ::Thread.list
      # @type var current_ractor_id: Integer
      current_ractor_id = get_ractor_id

      # NOTE: steep can't resolve a type of dynamic `[]` literal mutated via inline tap;
      # steep:ignore:start
      [].tap do |acquirers|
        # @type var acquirers: Array[String]
        current_threads.each do |thread|
          acquirers << host_identifier(
            current_process_id,
            thread.object_id,
            current_ractor_id,
            identity
          )
        end
      end
      # steep:ignore:end
    end
  end
end
