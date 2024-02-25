# frozen_string_literal: true

RSpec.describe RedisQueuedLocks do
  it 'has a version number' do
    expect(RedisQueuedLocks::VERSION).not_to be nil
  end

  specify do
    RedisQueuedLocks.enable_debugger!

    redis = RedisClient.config.new_client
    client = RedisQueuedLocks::Client.new(redis) do |config|
      config.retry_count = 3
    end
    15.times { client.lock("locklock#{_1}") }
    15.times { client.lock("locklock#{_1}") {} }

    client.unlock('locklock')
    client.clear_locks
  end
end
