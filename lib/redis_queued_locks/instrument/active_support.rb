# frozen_string_literal: true

# @api public
# @since 0.1.0
module RedisQueuedLocks::Instrument::ActiveSupport
  class << self
    # @param event [String]
    # @param payload [Hash<String|Symbol,Any>]
    # @return [void]
    #
    # @api private
    # @since 0.1.0
    def notify(event, payload = {})
      ::ActiveSupport::Notifications.instrument(event, payload)
    end
  end
end
