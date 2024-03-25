# frozen_string_literal: true

# @api private
# @since 0.1.0
module RedisQueuedLocks::Acquier::QueueInfo
  class << self
    # Returns an information about the required lock queue by the lock name. The result
    # represnts the ordered lock request queue that is ordered by score (Redis sets) and shows
    # lock acquirers and their position in queue. Async nature with redis communcation can lead
    # the sitaution when the queue becomes empty during the queue data extraction. So sometimes
    # you can receive the lock queue info with empty queue.
    #
    # @param redis_client [RedisClient]
    # @param lock_name [String]
    # @return [Hash<String|Array<Hash<String,String|Numeric>>,NilClass]
    #   - `nil` is returned when lock queue does not exist;
    #   - result format: {
    #     "lock_queue" => "rql:lock_queue:your_lock_name", # lock queue key in redis,
    #     queue: [
    #       { "acq_id" => "rql:acq:process_id/thread_id", "score" => 123 },
    #       { "acq_id" => "rql:acq:process_id/thread_id", "score" => 456 },
    #     ] # ordered set (by score) with information about an acquier and their position in queue
    #   }
    #
    # @api private
    # @since 0.1.0
    def queue_info(redis_client, lock_name)
      lock_key_queue = RedisQueuedLocks::Resource.prepare_lock_queue(lock_name)

      result = redis_client.pipelined do |pipeline|
        pipeline.call('EXISTS', lock_key_queue)
        pipeline.call('ZRANGE', lock_key_queue, '0', '-1', 'WITHSCORES')
      end

      exists_cmd_res = result[0]
      zrange_cmd_res = result[1]

      if exists_cmd_res == 1
        # NOTE: queue existed during the piepline invocation
        {
          'lock_queue' => lock_key_queue,
          'queue' => zrange_cmd_res.map { |val| { 'acq_id' => val[0], 'score' => val[1] } }
        }
      else
        # NOTE: queue did not exist during the pipeline invocation
        nil
      end
    end
  end
end
