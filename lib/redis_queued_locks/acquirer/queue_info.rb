# frozen_string_literal: true

# @api private
# @since 1.0.0
# @version 1.18.0
module RedisQueuedLocks::Acquirer::QueueInfo
  class << self
    # Returns an information about the required lock queue by the lock name. The result
    # represnts the ordered lock request queue that is ordered by score (Redis sets) and shows
    # lock acquirers and their position in queue. Async nature with redis communcation can lead
    # the sitaution when the queue becomes empty during the queue data extraction. So sometimes
    # you can receive the lock queue info with empty queue.
    #
    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @return [Hash<String,String|Array<Hash<String,String|Numeric>>,NilClass]
    #   - `nil` is returned when lock queues (write and read) do not exist;
    #   - result format: {
    #     "lock_queue" => "rql:lock_queue:your_lock_name", # lock queue key in redis,
    #     "queue" => [
    #       { "acq_id" => "rql:acq:123/456/789/987/id", "score" => 123.456, "rw_mode" => "write" },
    #       { "acq_id" => "rql:acq:123/686/789/987/id", "score" => 456.789, "rw_mode" => "write" },
    #       ...
    #     ] # ordered set (by score) with information about an acquirer, their position in queue
    #       # and the requested lock mode
    #     <additional keys when the queue of read lock requests exists>:
    #     "read_lock_queue" => "rql:lock_read_queue:your_lock_name", # read lock queue key in redis
    #     "read_queue" => [
    #       { "acq_id" => "rql:acq:123/456/789/987/id", "score" => 123.456, "rw_mode" => "read" },
    #       ...
    #     ] # read lock requests (positions are comparable with the write lock request positions)
    #   }
    #
    # @api private
    # @since 1.0.0
    # @version 1.18.0
    # rubocop:disable Metrics/MethodLength
    def queue_info(redis_client, lock_name)
      lock_key_queue = RedisQueuedLocks::Resource.prepare_lock_queue(lock_name)
      read_lock_key_queue = RedisQueuedLocks::Resource.prepare_read_lock_queue(lock_name)

      result = redis_client.pipelined do |pipeline|
        pipeline.call('EXISTS', lock_key_queue)
        pipeline.call('ZRANGE', lock_key_queue, '0', '-1', 'WITHSCORES')
        pipeline.call('EXISTS', read_lock_key_queue)
        pipeline.call('ZRANGE', read_lock_key_queue, '0', '-1', 'WITHSCORES')
      end

      # rubocop:disable Layout/LineLength
      # @type var result: [Integer,Array[[String,Integer|Float]],Integer,Array[[String,Integer|Float]]]
      # rubocop:enable Layout/LineLength
      exists_cmd_res = result[0]
      zrange_cmd_res = result[1]
      read_exists_cmd_res = result[2]
      read_zrange_cmd_res = result[3]

      if exists_cmd_res == 1 || read_exists_cmd_res == 1
        # NOTE: queue existed during the piepline invocation
        # @type var queue_info: RedisQueuedLocks::Acquirer::QueueInfo::queueInfo
        queue_info = {
          'lock_queue' => lock_key_queue,
          'queue' => zrange_cmd_res.map do |val|
            { 'acq_id' => val[0], 'score' => val[1], 'rw_mode' => 'write' }
          end
        }
        # NOTE: (RW) the queue of read lock requests
        if read_exists_cmd_res == 1
          queue_info['read_lock_queue'] = read_lock_key_queue
          queue_info['read_queue'] = read_zrange_cmd_res.map do |val|
            { 'acq_id' => val[0], 'score' => val[1], 'rw_mode' => 'read' }
          end
        end
        queue_info
      else
        # NOTE: queue did not exist during the pipeline invocation
        nil
      end
    end
    # rubocop:enable Metrics/MethodLength
  end
end
