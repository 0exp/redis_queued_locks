# frozen_string_literal: true

# @api private
# @since 1.9.0
class RedisQueuedLocks::Swarm::ProbeItself < RedisQueuedLocks::Swarm::SwarmElement
  class << self
    # @param redis_client [RedisClient]
    # @param acquirer_id [String]
    # @return [
    #   RedisQueuedLocks::Data[
    #     ok: <Boolean>,
    #     acq_id: <String>,
    #     probe_score: <Float>
    #   ]
    # ]
    #
    # @api private
    # @since 1.9.0
    def probe_itself(redis_client, acquirer_id)
      redis_client.call(
        'HSET',
        RedisQueuedLocks::Resource::SWARM_KEY,
        acquirer_id,
        probe_score = Time.now.to_f
      )

      RedisQueuedLocks::Data[ok: true, acq_id: acquirer_id, probe_score:]
    end
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def enabled?
    rql_client.config[:swarm][:probe_itself][:enabled_for_swarm]
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def swarm!
    @swarm_element = Ractor.new(
      rql_client.config[:swarm][:probe_itself][:redis_config],
      rql_client.current_acquier_id,
      rql_client.config['swarm.probe_itself.probe_period']
    ) do |rc, acq_id, prb_prd|
      thrd = Thread.new do
        rcl = RedisClient.config(**rc).new_client

        loop do
          RedisQueuedLocks::Swarm::ProbeItself.probe_itself(rcl, acq_id)
          sleep(prb_prd)
        end
      end

      loop do
        command = Ractor.receive
        case command
        when :status
          Ractor.yield({ main_loop: { alive: thrd.alive? } })
        when :restart
          thrd.kill
          thrd = Thread.new do
            rcl = RedisClient.config(**rc).new_client

            loop do
              RedisQueuedLocks::Swarm::ProbeItself.probe_itself(rcl, acq_id)
              sleep(prb_prd)
            end
          end
        when :stop
          thrd.kill
          exit
        end
      end
    end
  end
end
