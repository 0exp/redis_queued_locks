# frozen_string_literal: true

RSpec.describe RedisQueuedLocks do
  it 'has a version number' do
    expect(RedisQueuedLocks::VERSION).not_to be nil
  end

  specify do
    RedisQueuedLocks.enable_debugger!
    test_notifier = Class.new do
      attr_reader :notifications

      def initialize
        @notifications = []
      end

      def notify(event, payload = {})
        notifications << { event:, payload: }
      end
    end.new

    redis = RedisClient.config.new_pool(size: 15)

    client = RedisQueuedLocks::Client.new(redis) do |config|
      config.retry_count = 3
      config.instrumenter = test_notifier
    end

    Array.new(5) do |kek|
      Thread.new do
        client.lock!("locklock#{kek}", retry_count: nil, timeout: nil)
      end
    end

    Array.new(5) do |kek|
      Thread.new do
        client.lock!("locklock#{kek}", retry_count: nil, timeout: nil) { 'some_logic' }
      end
    end.each(&:join)

    Array.new(100) do |kek|
      Thread.new do
        client.lock!("locklock#{kek}", retry_count: nil, timeout: nil)
      end
    end

    client.unlock('locklock1')
    client.clear_locks

    puts test_notifier.notifications
  end
end
