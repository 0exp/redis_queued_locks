# RedisQueuedLocks

Distributed lock implementation with "lock acquisition queue" capabilities based on the Redis Database.

## Configuration

```ruby
redis_client = RedisClient.config.new_pool # NOTE: provide your own RedisClient instance

clinet = RedisQueuedLocks::Client.new(redis_client) do |config|
  # (default: 3) (supports nil)
  # - nil means "infinite retries" and you are only limited by the "try_to_lock_timeout" config;
  config.retry_count = 3

  # (milliseconds) (default: 200)
  config.retry_delay = 200

  # (milliseconds) (default: 50)
  config.retry_jitter = 50

  # (seconds) (supports nil)
  # - nil means "no timeout" and you are only limited by "retry_count" config;
  config.try_to_lock_timeout = 10

  # (milliseconds) (default: 1)
  # - expiration precision. affects the ttl (ttl + precision);
  config.exp_precision = 1

  # (milliseconds) (default: 5_000)
  # - lock's time to live
  config.default_lock_ttl = 5_000

  # (seconds) (default: 15)
  # - lock request timeout. after this timeout your lock request in queue will be requeued;
  config.default_queue_ttl = 15

  # (default: 100)
  # - how many items will be released at a time in RedisQueuedLocks::Client#clear_locks logic;
  # - affects the performancs capabilites (redis, rubyvm);
  config.lock_release_batch_size = 100

  # (default: RedisQueuedLocks::Instrument::VoidNotifier)
  # - instrumentation layer;
  # - you can provde your own instrumenter with `#notify(event, payload = {})`
  #   - event: <string> requried;
  #   - payload: <hash> requried;
  # - disabled by default via VoidNotifier;
  config.instrumenter = RedisQueuedLocks::Instrument::ActiveSupport
end
```

## Usage

```ruby
redis_clinet = RedisClient.config.new_pool # NOTE: provide your ounw RedisClient instance
rq_lock = RedisQueuedLocks::Client.new(redis_client) do |config|
  # NOTE: some your application-related configs
end
```

- `#lock`
- `#lock!`
- `#unlock`
- `#clear_locks`

## Instrumentation events

- `"redis_queued_locks.lock_obtained"`
  - a moment when the lock was obtained;
  - payload:
    - `ttl` - `integer`/`milliseconds` - lock ttl;
    - `acq_id` - `string` - lock acquier identifier;
    - `lock_key` - `string` - lock name;
    - `ts` - `integer`/`epoch` - the time when the lock was obtaiend;
    - `acq_time` - `float`/`milliseconds` - time spent on lock acquiring;
- `"redis_queued_locks.lock_hold_and_release"`
  - an event signalizes about the "hold+and+release" process
    when the lock obtained and hold by the block of logic;
  - payload:
    - `hold_time` - `float`/`milliseconds` - lock hold time;
    - `ttl` - `integer`/`milliseconds` - lock ttl;
    - `acq_id` - `string` - lock acquier identifier;
    - `lock_key` - `string` - lock name;
    - `ts` - `integer`/`epoch` - the time when lock was obtained;
    - `acq_time` - `float`/`milliseconds` - time spent on lock acquiring;
- `"redis_queued_locks.explicit_lock_release"`
  - an event signalizes about the explicit lock release (invoked via `RedisQueuedLock#unlock`);
  - payload:
    - `at` - `integer`/`epoch` - the time when the lock was released;
    - `rel_time` - `float`/`milliseconds` - time spent on lock releasing;
    - `lock_key` - `string` - released lock (lock name);
    - `lock_key_queue` - `string` - released lock queue (lock queue name);
- `"redis_queued_locks.explicit_all_locks_release"`
  - an event signalizes about the explicit all locks release (invoked via `RedisQueuedLock#clear_locks`);
  - payload:
    - `rel_time` - `float`/`milliseconds` - time spent on "realese all locks" operation;
    - `at` - `integer`/`epoch` - the time when the operation has ended;
    - `rel_keys` - `integer` - released redis keys count (`released queu keys` + `released lock keys`);
