# frozen_string_literal: true

RSpec.describe RedisQueuedLocks do
  let(:redis) { RedisClient.config.new_pool(timeout: 5, size: 50) }

  before { RedisQueuedLocks.enable_debugger! }

  specify 'logger' do
    test_logger = Class.new do
      attr_reader :logs

      def initialize
        @logs = []
      end

      def debug(progname = nil, &block)
        logs << "#{progname} : #{yield if block_given?}"
      end
    end.new

    # NOTE: with log_lock_try test
    client = RedisQueuedLocks::Client.new(redis) do |conf|
      conf.logger = test_logger
      conf.log_lock_try = true
    end

    client.lock('pek.kek.cheburek') { 1 + 1 }

    expect(test_logger.logs.size).to eq(5)
    aggregate_failures 'logs content (with log_lock_try)' do
      # NOTE: lock_obtaining
      expect(test_logger.logs[0]).to include('[redis_queued_locks.start_lock_obtaining]')
      expect(test_logger.logs[0]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")

      # NOTE: try to lock - start
      expect(test_logger.logs[1]).to include('[redis_queued_locks.try_lock_start]')
      expect(test_logger.logs[1]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")

      # NOTE: try to lock - rconn fetched
      expect(test_logger.logs[2]).to include('[redis_queued_locks.try_lock_rconn_fetched]')
      expect(test_logger.logs[2]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")

      # NOTE: lock_obtained
      expect(test_logger.logs[3]).to include('[redis_queued_locks.lock_obtained]')
      expect(test_logger.logs[3]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")

      # NOTE: expire_lock
      expect(test_logger.logs[4]).to include('[redis_queued_locks.expire_lock]')
      expect(test_logger.logs[4]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")
    end

    # NOTE: rollback to the clean initial state in order to test another case
    test_logger.logs.clear

    # NOTE: without log_lock_try test
    client = RedisQueuedLocks::Client.new(redis) do |conf|
      conf.logger = test_logger
      conf.log_lock_try = false
    end

    client.lock('pek.kek.cheburek') { 1 + 1 }

    expect(test_logger.logs.size).to eq(3)
    aggregate_failures 'logs content (with log_lock_try)' do
      # NOTE: lock_obtaining
      expect(test_logger.logs[0]).to include('[redis_queued_locks.start_lock_obtaining]')
      expect(test_logger.logs[0]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")

      # NOTE: lock_obtained
      expect(test_logger.logs[1]).to include('[redis_queued_locks.lock_obtained]')
      expect(test_logger.logs[1]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")

      # NOTE: expire_lock
      expect(test_logger.logs[2]).to include('[redis_queued_locks.expire_lock]')
      expect(test_logger.logs[2]).to include("lock_key => 'rql:lock:pek.kek.cheburek'")
    end
  end

  specify 'metadata' do
    test_notifier = Class.new do
      attr_reader :notifications

      def initialize
        @notifications = []
      end

      def notify(event, payload = {})
        notifications << { event:, payload: }
      end
    end.new

    client = RedisQueuedLocks::Client.new(redis) do |conf|
      conf.instrumenter = test_notifier
    end

    expect(test_notifier.notifications).to be_empty
    client.lock('kek-pek-cheburgen', metadata: { test: :ok })
    expect(test_notifier.notifications.size).to eq(1)
    expect(test_notifier.notifications[0][:payload][:meta]).to eq({ test: :ok })
    client.lock('bum-bum-pek-mek')
    expect(test_notifier.notifications.size).to eq(2)
    expect(test_notifier.notifications[1][:payload][:meta]).to eq(nil)
  end

  specify 'timed lock' do
    redis = RedisClient.config.new_pool(timeout: 5, size: 50)
    client = RedisQueuedLocks::Client.new(redis)

    expect do
      client.lock('some-timed-lock', timed: true, ttl: 5_000) { sleep(6) }
    end.to raise_error(RedisQueuedLocks::TimedLockTimeoutError)

    expect(client.locked?('some-timed-lock')).to eq(false)

    expect do
      client.lock('some-timed-lock', timed: true, ttl: 6_000) { sleep(5.8) }
    end.not_to raise_error

    expect(client.locked?('some-timed-lock')).to eq(false)

    redis.call('FLUSHDB')
  end

  specify 'lock queues' do
    client = RedisQueuedLocks::Client.new(redis)

    client.lock('some-kek-super-pek', ttl: 5_000)
    res = client.lock('some-kek-super-pek', fail_fast: true) {}
    expect(res).to match({ ok: false, result: :fail_fast_no_try })

    expect do
      client.lock!('some-kek-super-pek', fail_fast: true)
    end.to raise_error(RedisQueuedLocks::LockAlreadyObtainedError)

    expect do
      client.lock!('some-kek-super-pek', retry_count: 1)
    end.to raise_error(RedisQueuedLocks::LockAcquiermentRetryLimitError)

    expect do
      client.lock!('some-kek-super-pek', retry_count: 1, timeout: 1)
    end.to raise_error(RedisQueuedLocks::LockAcquiermentRetryLimitError)

    redis.call('FLUSHDB')
  end

  specify do
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
      ini_ttl: 10_000,
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

    client.locks
    client.queues
    client.keys

    client.unlock('locklock1')
    sleep(3)
    client.clear_locks

    puts test_notifier.notifications
    redis.call('FLUSHDB')
  end
end
