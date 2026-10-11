# frozen_string_literal: true

# @api private
# @since 1.0.0
# rubocop:disable Metrics/ModuleLength
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

  # NOTE:
  #   - read/write keys use their own prefixes (not suffixes of the lock name) cuz the lock name
  #     is an arbitrary string: `rql:lock_queue:<name>:read` collides with the queue of a lock
  #     named "<name>:read";
  #   - new prefixes are not matched by LOCK_PATTERN/LOCK_QUEUE_PATTERN
  #     (`rql:lock_` vs `rql:lock:`) but are matched by KEY_PATTERN;
  #   - write lock requests use the classic lock queue (LOCK_QUEUE_PATTERN);
  # @return [String]
  #
  # @api private
  # @since 1.18.0
  READ_LOCK_QUEUE_PATTERN = 'rql:lock_read_queue:*'

  # @return [String]
  #
  # @api private
  # @since 1.18.0
  LOCK_READERS_PATTERN = 'rql:lock_readers:*'

  # @return [String]
  #
  # @api private
  # @since 1.18.0
  READ_LOCK_PATTERN = 'rql:lock_reader:*'

  # Write and read lock queues in one SCAN pass (the keyspace lookup: the disabled lock index).
  # NOTE:
  #   - the pattern matches other keys too when the lock name contains `queue:` (for example,
  #     `rql:lock_readers:my_queue:a`), so callers check the key family (`lock_key_family`);
  # @return [String]
  #
  # @api private
  # @since 1.20.0
  ALL_LOCK_QUEUES_PATTERN = 'rql:lock_*queue:*'

  # @return [String]
  #
  # @api private
  # @since 1.9.0
  SWARM_KEY = 'rql:swarm:hsts'

  # Lock index: a sorted set of lock names (members) where the score is the upper bound of the
  # lifetime of all keys of the lock (client time, epoch milliseconds + the index grace period).
  # It replaces the full keyspace SCAN for the operations that iterate over locks (lock names are
  # taken from the index, lock keys are derived from the lock names).
  # NOTE:
  #   - it is used and maintained only with the enabled lock index (`config['lock_index_enabled']`,
  #     disabled by default: lock-iterating operations scan the keyspace (`KEY_PATTERN`) then);
  #   - the key is not matched by `KEY_PATTERN` (`rql:index:` vs `rql:lock`) and can not collide
  #     with lock keys (`rql:lock:<name>`, `rql:lock_<kind>:<name>`);
  #   - the index is a superset of the existing locks: a lock name is added (or its score is
  #     increased) by every command that creates or extends a lock key (in the same pipeline or
  #     transaction, after the key command) and it is removed only when its score is reached
  #     (`ZREMRANGEBYSCORE`: all the keys of the lock are expired by that time) or in the same
  #     transaction with all the keys of the lock (`#unlock`, `#clear_locks`);
  # @return [String]
  #
  # @api private
  # @since 1.20.0
  LOCK_INDEX_KEY = 'rql:index:locks'

  # @return [Integer] Redis time error (in milliseconds).
  #
  # @api private
  # @since 1.3.0
  REDIS_TIMESHIFT_ERROR = 2

  # rubocop:disable Metrics/ClassLength
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

    # Queue of read lock requests (write lock requests use the classic lock queue).
    #
    # @param lock_name [String]
    # @return [String]
    #
    # @api private
    # @since 1.18.0
    def prepare_read_lock_queue(lock_name)
      "rql:lock_read_queue:#{lock_name}"
    end

    # Registry of read lock holders: a sorted set where the member is an acquirer id and
    # the score is the read lock expiration time (redis server time, epoch milliseconds).
    #
    # @param lock_name [String]
    # @return [String]
    #
    # @api private
    # @since 1.18.0
    def prepare_lock_readers(lock_name)
      "rql:lock_readers:#{lock_name}"
    end

    # Read lock data of the concrete acquirer: a hash with the same structure as the write lock
    # (timestamp, ttl, meta, reentrant lock data; acquirer and host are derived from the acquirer
    # id and are not stored). It is a data carrier only: the readers registry is the source of
    # truth for the read lock existence.
    #
    # @param lock_name [String]
    # @param acquirer_id [String]
    # @return [String]
    #
    # @api private
    # @since 1.18.0
    def prepare_read_lock_key(lock_name, acquirer_id)
      "rql:lock_reader:#{lock_name}:#{acquirer_id}"
    end

    # Mode of the lock requests stored in the given lock queue.
    #
    # @param lock_queue [String]
    #   Write lock queue (`rql:lock_queue:*`) or read lock queue (`rql:lock_read_queue:*`).
    # @return [String,NilClass]
    #   - `'write'` for the write lock queue, `'read'` for the read lock queue;
    #   - `nil` for any other key (unreachable: lock queues are always passed consistently);
    #
    # @api private
    # @since 1.18.0
    def lock_queue_rw_mode(lock_queue)
      # NOTE:
      #   - `start_with?` instead of regexp `when`-matchers: no MatchData allocations;
      #   - write lock queues are checked first: they are met more often than read lock queues;
      case
      when lock_queue.start_with?('rql:lock_queue:') then 'write'
      when lock_queue.start_with?('rql:lock_read_queue:') then 'read'
      else
        # NOTE: unreachable: the logic always passes a consistent lock queue (read or write)
        nil
      end
    end

    # Family of the given RQL key: one SCAN pass over `KEY_PATTERN` (or `ALL_LOCK_QUEUES_PATTERN`)
    # returns keys of several families, so callers keep the keys of the families they need.
    #
    # @param key [String]
    # @return [Symbol,NilClass]
    #   - `:lock` - write lock (`rql:lock:*`);
    #   - `:lock_queue` - write lock requests (`rql:lock_queue:*`);
    #   - `:lock_readers` - readers registry (`rql:lock_readers:*`);
    #   - `:read_lock_queue` - read lock requests (`rql:lock_read_queue:*`);
    #   - `:read_lock` - read lock data (`rql:lock_reader:*`);
    #   - `nil` - any other key (for example, `rql:lockX` matched by `KEY_PATTERN`);
    #
    # @api private
    # @since 1.20.0
    def lock_key_family(key)
      # NOTE:
      #   - `start_with?` instead of regexp `when`-matchers: no MatchData allocations;
      #   - prefixes are unambiguous: `rql:lock_reader:` is not a prefix of `rql:lock_readers:`;
      case
      when key.start_with?('rql:lock:') then :lock
      when key.start_with?('rql:lock_queue:') then :lock_queue
      when key.start_with?('rql:lock_readers:') then :lock_readers
      when key.start_with?('rql:lock_read_queue:') then :read_lock_queue
      when key.start_with?('rql:lock_reader:') then :read_lock
      end
    end

    # Lock name of the given RQL key (the member of the lock index).
    #
    # @param key [String]
    # @param key_family [Symbol,NilClass] Family of the key (see `lock_key_family`).
    # @return [String,NilClass]
    #   - the lock name for the write lock, the readers registry and the lock queues (both modes);
    #   - `nil` for the read lock data (`:read_lock`: the lock name can not be separated from
    #     the acquirer id unambiguously) and for any other key;
    #
    # @api private
    # @since 1.20.0
    def lock_name_from_key(key, key_family)
      case key_family
      when :lock then key.delete_prefix('rql:lock:')
      when :lock_queue then key.delete_prefix('rql:lock_queue:')
      when :lock_readers then key.delete_prefix('rql:lock_readers:')
      when :read_lock_queue then key.delete_prefix('rql:lock_read_queue:')
      end
    end

    # Client time for the lock index scores (see `LOCK_INDEX_KEY`).
    #
    # @return [Integer] Epoch, in milliseconds.
    #
    # @api private
    # @since 1.20.0
    def lock_index_time
      # NOTE: an Integer of milliseconds without Time/Float objects
      ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
    end

    # @param lock_readers_key [String]
    # @return [String]
    #
    # @api private
    # @since 1.18.0
    def lock_name_from_readers(lock_readers_key)
      lock_readers_key.delete_prefix('rql:lock_readers:')
    end

    # @param lock_readers_key [String]
    # @return [String]
    #
    # @api private
    # @since 1.18.0
    def lock_key_from_readers(lock_readers_key)
      "rql:lock:#{lock_readers_key.delete_prefix('rql:lock_readers:')}"
    end

    # Host identifier of the given acquirer
    # (acquirer and host identifiers are built from the same process/thread/ractor/identity data):
    #   - acquirer id: `rql:acq:<pid>/<thread>/<fiber>/<ractor>/<identity>`;
    #   - host id: `rql:hst:<pid>/<thread>/<ractor>/<identity>` (the same as `host_identifier`);
    #
    # @param acquirer_id [String]
    # @return [String]
    #
    # @api private
    # @since 1.18.0
    def host_identifier_from_acquirer(acquirer_id)
      # NOTE:
      #   - the host id is the acquirer id with another prefix and without the fiber part, so it is
      #     built in place from the acquirer id copy (one allocation: no intermediate strings and
      #     arrays of `delete_prefix`/`split`, no substrings);
      #   - 8 is the size of the `rql:acq:` prefix;
      #   - byte positions are used cuz identity can contain any (multibyte) symbols;
      thread_end = acquirer_id.byteindex('/', acquirer_id.byteindex('/', 8).to_i + 1).to_i
      fiber_end = acquirer_id.byteindex('/', thread_end + 1).to_i
      host_id = acquirer_id.dup
      host_id.bytesplice(thread_end, fiber_end - thread_end, '') # NOTE: drop "/<fiber>"
      host_id.bytesplice(0, 8, 'rql:hst:')
    end

    # @param redis_time [Array<String>] Result of the redis `TIME` command (seconds, microseconds).
    # @return [Integer] Redis server time (epoch, in milliseconds).
    #
    # @api private
    # @since 1.18.0
    def redis_time_ms(redis_time)
      (Integer(redis_time[0]) * 1_000) + (Integer(redis_time[1]) / 1_000)
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
  # rubocop:enable Metrics/ClassLength
end
# rubocop:enable Metrics/ModuleLength
