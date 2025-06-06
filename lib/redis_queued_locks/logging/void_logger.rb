# frozen_string_literal: true

# @api public
# @since 1.0.0
module RedisQueuedLocks::Logging::VoidLogger
  class << self
    # @param progname [Any]
    # @parma block [Block]
    # @return [void]
    #
    # @api public
    # @since 1.0.0
    def warn(progname = nil, &block); end

    # @param progname [Any]
    # @parma block [Block]
    # @return [void]
    #
    # @api public
    # @since 1.0.0
    def unknown(progname = nil, &block); end

    # @param progname [Any]
    # @parma block [Block]
    # @return [void]
    #
    # @api public
    # @since 1.0.0
    def log(progname = nil, &block); end

    # @param progname [Any]
    # @parma block [Block]
    # @return [void]
    #
    # @api public
    # @since 1.0.0
    def info(progname = nil, &block); end

    # @param progname [Any]
    # @parma block [Block]
    # @return [void]
    #
    # @api public
    # @since 1.0.0
    def error(progname = nil, &block); end

    # @param progname [Any]
    # @parma block [Block]
    # @return [void]
    #
    # @api public
    # @since 1.0.0
    def fatal(progname = nil, &block); end

    # @param progname [Any]
    # @parma block [Block]
    # @return [void]
    #
    # @api public
    # @since 1.0.0
    def debug(progname = nil, &block); end

    # @param severity [Any]
    # @param message [Any]
    # @param progname [Any]
    # @param block [Block]
    # @return [void]
    #
    # @api public
    # @since 1.0.0
    def add(severity = nil, message = nil, progname = nil, &block); end

    # @param message [Any]
    # @retorun [void]
    #
    # @api public
    # @since 1.0.0
    def <<(message); end
  end
end
