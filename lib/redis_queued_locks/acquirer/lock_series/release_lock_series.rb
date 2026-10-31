# frozen_string_literal: true

# Releases the lock series: only the locks that are obtained by the series itself and only if they
# are still owned by the current acquirer; the reentrant locks (obtained by the outer logic of
# the current acquirer) are kept and the extended ones get their ttl back.
#
# @api private
# @since 1.23.0
module RedisQueuedLocks::Acquirer::LockSeries::ReleaseLockSeries
  # @param redis [RedisClient]
  # @param lock_names [Array<String>]
  # @param lock_processes [Array<Symbol,NilClass>]
  #   - The way each lock of the series is held (the order of `lock_names`):
  #   - `:lock_obtaining` - obtained by the series itself (released);
  #   - `:extendable_conflict_work_through` - extended reentrant lock (its ttl is decreased);
  #   - `:conflict_work_through` - reentrant lock (kept as is);
  # @param held_rw_modes [Array<Symbol>]
  #   The mode of the lock that is really held by the acquirer (the order of `lock_names`).
  # @param acquirer_id [String]
  # @param decreased_ttl [Integer]
  #   The ttl to take back from the extended reentrant locks (in milliseconds): the extension
  #   without the time spent under the locks; a non-positive value keeps these locks as is.
  # @return [void]
  #
  # @api private
  # @since 1.23.0
  def release_lock_series(
    redis,
    lock_names,
    lock_processes,
    held_rw_modes,
    acquirer_id,
    decreased_ttl
  )
    # @type var write_lock_names: Array[String]
    write_lock_names = []
    # @type var read_lock_names: Array[String]
    read_lock_names = []
    # @type var extended_write_lock_names: Array[String]
    extended_write_lock_names = []
    # @type var extended_read_lock_names: Array[String]
    extended_read_lock_names = []

    lock_names.each_with_index do |lock_name, index|
      read_lock = held_rw_modes[index] == :read

      case lock_processes[index]
      when :lock_obtaining
        (read_lock ? read_lock_names : write_lock_names) << lock_name
      when :extendable_conflict_work_through
        (read_lock ? extended_read_lock_names : extended_write_lock_names) << lock_name
      end
    end

    # NOTE: a non-positive decreased ttl: the spent time exceeds the extension
    if decreased_ttl <= 0
      extended_read_lock_names.clear
      extended_write_lock_names.clear
    end

    release_write_lock_series(
      redis, write_lock_names, extended_write_lock_names, acquirer_id, decreased_ttl
    )
    release_read_lock_series(
      redis, read_lock_names, extended_read_lock_names, acquirer_id, decreased_ttl
    )
  end

  private

  # Releases the write locks (and decreases the ttl of the extended ones) of the given acquirer
  # (compare-and-delete: the lock can be expired and obtained by another acquirer when the series
  # logic exceeds the lock ttl) in one transaction for the whole series (three round trips: WATCH,
  # lock owners, MULTI/EXEC):
  #   - an aborted transaction (one of the watched locks is changed) is retried with the locks
  #     that were still owned by the acquirer at the last check: the locks of other acquirers
  #     are neither touched nor watched, so the retries converge;
  #
  # @param redis [RedisClient]
  # @param lock_names [Array<String>] The locks to release.
  # @param extended_lock_names [Array<String>] The extended reentrant locks.
  # @param acquirer_id [String]
  # @param decreased_ttl [Integer] In milliseconds.
  # @return [void]
  #
  # @api private
  # @since 1.23.0
  # rubocop:disable Metrics/MethodLength
  def release_write_lock_series(redis, lock_names, extended_lock_names, acquirer_id, decreased_ttl)
    return if lock_names.empty? && extended_lock_names.empty?

    own_lock_keys = lock_names.map do |lock_name|
      RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
    end
    own_extended_lock_keys = extended_lock_names.map do |lock_name|
      RedisQueuedLocks::Resource.prepare_lock_key(lock_name)
    end

    redis.with do |conn|
      until own_lock_keys.empty? && own_extended_lock_keys.empty?
        released = conn.multi(watch: own_lock_keys + own_extended_lock_keys) do |transaction|
          # NOTE: (pipeline layout) one reply (lock owner) per lock: the released locks first
          # @type var lock_owners: Array[String?]
          lock_owners = conn.pipelined do |pipeline|
            own_lock_keys.each { |lock_key| pipeline.call('HGET', lock_key, 'acq_id') }
            own_extended_lock_keys.each { |lock_key| pipeline.call('HGET', lock_key, 'acq_id') }
          end
          extended_locks_at = own_lock_keys.size
          own_lock_keys = own_lock_keys.select.with_index do |_lock_key, index|
            lock_owners[index] == acquirer_id
          end
          own_extended_lock_keys = own_extended_lock_keys.select.with_index do |_lock_key, index|
            lock_owners[extended_locks_at + index] == acquirer_id
          end
          own_lock_keys.each { |lock_key| transaction.call('DEL', lock_key) }
          # NOTE: EVAL signature -> <lua script>, (number of keys), *(keys), *(arguments)
          own_extended_lock_keys.each do |lock_key|
            transaction.call(
              'EVAL',
              RedisQueuedLocks::Acquirer::AcquireLock::YieldExpire::DECREASE_LOCK_PTTL,
              1,
              lock_key,
              decreased_ttl
            )
          end
        end
        # NOTE: `nil` => the transaction is aborted (a watched lock is changed) => retry
        break unless released == nil
      end
    rescue RedisQueuedLocks::LockAcquirementIntermediateTimeoutError,
           RedisQueuedLocks::TimedLockIntermediateTimeoutError,
           ::Timeout::ExitException
      # NOTE: (timeouts) an interrupted WATCH block (the internal timeouts and the user's
      #   `Timeout.timeout` without an exception class): the closed connection drops the WATCH
      #   state (redis-client sends `UNWATCH` only on `StandardError`);
      conn.close
      raise
    end
  end
  # rubocop:enable Metrics/MethodLength

  # Releases the read locks (and decreases the extended ones) of the given acquirer in one
  # transaction (other readers are not affected).
  #
  # @param redis [RedisClient]
  # @param lock_names [Array<String>] The locks to release.
  # @param extended_lock_names [Array<String>] The extended reentrant locks.
  # @param acquirer_id [String]
  # @param decreased_ttl [Integer] In milliseconds.
  # @return [void]
  #
  # @api private
  # @since 1.23.0
  def release_read_lock_series(redis, lock_names, extended_lock_names, acquirer_id, decreased_ttl)
    return if lock_names.empty? && extended_lock_names.empty?

    redis.multi do |transaction|
      lock_names.each do |lock_name|
        transaction.call(
          'ZREM', RedisQueuedLocks::Resource.prepare_lock_readers(lock_name), acquirer_id
        )
        transaction.call(
          'DEL', RedisQueuedLocks::Resource.prepare_read_lock_key(lock_name, acquirer_id)
        )
      end
      # NOTE:
      #   - XX => do nothing if the read lock is already expired and removed from the registry;
      #   - the read lock data TTL is not decreased (it is not used without the read lock);
      extended_lock_names.each do |lock_name|
        transaction.call(
          'ZADD',
          RedisQueuedLocks::Resource.prepare_lock_readers(lock_name),
          'XX',
          'INCR',
          -decreased_ttl,
          acquirer_id
        )
      end
    end
  end
end
