# frozen_string_literal: true

# @api public
# @since 1.0.0
module RedisQueuedLocks::Logging::VoidLogger
  class << self
    # @api public
    # @since 1.0.0
    def warn(progname = nil, &block); end

    # @api public
    # @since 1.0.0
    def unknown(progname = nil, &block); end

    # @api public
    # @since 1.0.0
    def log(progname = nil, &block); end

    # @api public
    # @since 1.0.0
    def info(progname = nil, &block); end

    # @api public
    # @since 1.0.0
    def error(progname = nil, &block); end

    # @api public
    # @since 1.0.0
    def fatal(progname = nil, &block); end

    # @api public
    # @since 1.0.0
    def debug(progname = nil, &block); end

    # @api public
    # @since 1.0.0
    def add(*, &block); end

    # @api public
    # @since 1.0.0
    def <<(message); end
  end
end
