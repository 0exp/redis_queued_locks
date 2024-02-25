# frozen_string_literal: true

# @api public
# @since 0.1.0
module RedisQueuedLocks::Instrument::VoidNotifier
  class << self
    # @param event [String]
    # @param payload [Hash<String|Symbol,Any>]
    # @return [void]
    #
    # @api private
    # @since 0.1.0
    def notify(event, payload = {}); end
  end
end
