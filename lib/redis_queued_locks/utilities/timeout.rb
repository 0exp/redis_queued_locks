# frozen_string_literal: true

# NOTE:
#   - this is a partial copy of the original Ruby Timeout that is written in order
#   to extract RQL timeouts from the global ruby timeout queue;
#   - it should prevent any logic intersection and problems related to the
#   application logic timeouts which are hosted by your app and other libreries where any other
#   timeout proces can affect (and block) RQL timeout process;
# TODO:
#   - each RQL instance should have their own timeout controller (as an instance);
#
# @api private
# @since 1.13.0
class RedisQueuedLocks::Utilities::Timeout
  require_relative 'timeout/process'
  require_relative 'timeout/process_watcher'


  attr_reader :process_queue

  def initialize
    @process_queue = ::Thread::Queue.new
  end
end
