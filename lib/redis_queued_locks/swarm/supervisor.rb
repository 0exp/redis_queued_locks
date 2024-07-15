# frozen_string_literal: true

# @api private
# @since 1.9.0
class RedisQueuedLocks::Swarm::Supervisor
  # @since 1.9.0
  include RedisQueuedLocks::Utilities

  # @return [RedisQueuedLocks::Client]
  #
  # @api private
  # @since 1.9.0
  attr_reader :rql_client

  # @return [Thread,NilClass]
  #
  # @api private
  # @since 1.9.0
  attr_reader :visor

  # @return [Proc,NilClass]
  #
  # @api private
  # @since 1.9.0
  attr_reader :observable

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def initialize(rql_client)
    @rql_client = rql_client
    @visor = nil
    @observable = nil
  end

  # @param observable [Block]
  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def observe!(&observable)
    @observable = observable
    @visor = Thread.new do
      loop do
        yield rescue nil # TODO/CHECK: may be we need to process exceptions here
        sleep(rql_client.config[:swarm][:supervisor][:liveness_probing_period])
      end
    end
    # NOTE: need to give a timespot to initialize visor thread;
    sleep(0.1)
  end

  # @return [Boolean]
  #
  # @api private
  # @since 1.9.0
  def running?
    visor != nil && visor.alive?
  end

  # @return [void]
  #
  # @api private
  # @since 1.9.0
  def stop!
    visor.kill if running?
    @visor = nil
    @observable = nil
  end

  # @return [Hash<Symbol|Hash<Symbol,String|Boolean>>]
  #
  # @api private
  # @since 1.9.0
  def status
    {
      running: running?,
      state: (visor == nil) ? 'non_initialized' : thread_state(visor),
      observable: (observable == nil) ? 'non_initialized' : 'initialized'
    }
  end
end
