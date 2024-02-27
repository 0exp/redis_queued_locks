# frozen_string_literal: true

RSpec.describe RedisQueuedLocks do
  before { RedisQueuedLocks.enable_debugger! }

  it 'has a version number' do
    expect(RedisQueuedLocks::VERSION).not_to be nil
  end

  specify do
    redis = RedisClient.config.new_pool(timeout: 5, size: 50)
    client = RedisQueuedLocks::Client.new(redis)
    lock_name = "kekpek-#{rand(100_000)}"

    expect(client.queue_info(lock_name)).to eq(nil)
    expect(client.lock_info(lock_name)).to eq(nil)
    expect(client.locked?(lock_name)).to eq(false)
    expect(client.queued?(lock_name)).to eq(false)

    expect(client.locked?(lock_name)).to eq(false)
    client.lock(lock_name, ttl: 10_000)
    lock_info = client.lock_info(lock_name)

    expect(lock_info).to match({
      lock_key: "rql:lock:#{lock_name}",
      acq_id: be_a(String),
      ts: be_a(Integer),
      ini_ttl: 10_000 + 2, # 2 is redis expiration deviation
      rem_ttl: be_a(Integer)
    })

    expect(client.locked?(lock_name)).to eq(true)
    expect(client.queued?(lock_name)).to eq(false)

    # NOTE: two new requests
    Thread.new { client.lock(lock_name, ttl: 10_000, timeout: nil, retry_count: nil) }
    Thread.new { client.lock(lock_name, ttl: 10_000, timeout: nil, retry_count: nil) }
    sleep(1)

    expect(client.queued?(lock_name)).to eq(true)
    expect(client.queue_info(lock_name)).to match({
      lock_queue: "rql:lock_queue:#{lock_name}",
      queue: match_array([
        match({ acq_id: be_a(String), score: be_a(Numeric) }),
        match({ acq_id: be_a(String), score: be_a(Numeric) })
      ])
    })

    redis.call('FLUSHDB')
  end

  specify do
    test_notifier = Class.new do
      attr_reader :notifications

      def initialize
        @notifications = []
      end

      def notify(event, payload = {})
        notifications << { event:, payload: }
      end
    end.new

    redis = RedisClient.config.new_pool(timeout: 5, size: 50)

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

    Array.new(120) do |kek|
      Thread.new do
        client.lock!("locklock#{kek}", ttl: 10_000, retry_count: nil, timeout: nil)
      end
    end

    client.unlock('locklock1')
    sleep(3)
    client.clear_locks

    puts test_notifier.notifications
    redis.call('FLUSHDB')
  end
end
