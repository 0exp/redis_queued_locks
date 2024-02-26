# RedisQueuedLocks

Distributed locks with "lock acquisition queue" capabilities based on the Redis Database.

Each lock request is put into a request queue and processed in order of their priority (FIFO).

---

## Table of Contents

- [Algorithm](#algorithm)
- [Installation](#installation)
- [Setup](#setup)
- [Configuration](#configuration)
- [Usage](#usage)
  - [lock](#lock---obtain-a-lock)
  - [lock!](#lock---exeptional-lock-obtaining)
  - [unlock](#unlock---release-a-lock)
  - [clear_locks](#clear_locks---release-all-locks-and-lock-queues)
- [Instrumentation](#instrumentation)
  - [Instrumentation Events](#instrumentation-events)
- [Todo](#todo)
- [Contributing](#contributing)
- [License](#license)
- [Authors](#authors)

---

### Algorithm

- soon;

---

### Installation

```ruby
gem 'redis_queued_locks'
```

```shell
bundle install
# --- or ---
gem install redis_queued_locks
```

```ruby
require 'redis_queued_locks'
```

---

### Setup

```ruby
require 'redis_queued_locks'

# Step 1: initialize RedisClient instance
redis_clinet = RedisClient.config.new_pool # NOTE: provide your ounw RedisClient instance

# Step 2: initialize RedisQueuedLock::Client instance
rq_lock_client = RedisQueuedLocks::Client.new(redis_client) do |config|
  # NOTE:
  #   - some your application-related configs;
  #   - for documentation see <Configuration> section in readme;
end

# Step 3: start to work with locks :)
rq_lock_client.lock("some-lock") { puts "Hello, lock!" }
```

---

### Configuration

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

---

### Usage

- [lock](#lock---obtain-a-lock)
- [lock!](#lock---exeptional-lock-obtaining)
- [unlock](#unlock---release-a-lock)
- [clear_locks](#clear_locks---release-all-locks-and-lock-queues)

---

#### #lock - obtain a lock

```ruby
def lock(
  lock_name,
  process_id: RedisQueuedLocks::Resource.get_process_id,
  thread_id: RedisQueuedLocks::Resource.get_thread_id,
  ttl: config[:default_lock_ttl],
  queue_ttl: config[:default_queue_ttl],
  timeout: config[:try_to_lock_timeout],
  retry_count: config[:retry_count],
  retry_delay: config[:retry_delay],
  retry_jitter: config[:retry_jitter],
  raise_errors: false,
  &block
)
```

- `lock_name` - `[String]`
  - Lock name to be obtained.
- `process_id` - `[Integer,String]`
  - The process that want to acquire the lock.
- `thread_id` - `[Integer,String]`
  - The process's thread that want to acquire the lock.
- `ttl` [Integer]
  - Lock's time to live (in milliseconds).
- `queue_ttl` - `[Integer]`
  - Lifetime of the acuier's lock request. In seconds.
- `timeout` - `[Integer,NilClass]`
  - Time period whe should try to acquire the lock (in seconds). Nil means "without timeout".
- `retry_count` - `[Integer,NilClass]`
  - How many times we should try to acquire a lock. Nil means "infinite retries".
- `retry_delay` - `[Integer]`
  - A time-interval between the each retry (in milliseconds).
- `retry_jitter` - `[Integer]`
  - Time-shift range for retry-delay (in milliseconds).
- `instrumenter` - `[#notify]`
  - See RedisQueuedLocks::Instrument::ActiveSupport for example.
- `raise_errors` - `[Boolean]`
  - Raise errors on library-related limits such as timeout or retry count limit.
- `block` - `[Block]`
  - A block of code that should be executed after the successfully acquired lock.
  - If block is **passed** the obtained lock will be released after the block execution or it's ttl (what will happen first);
  - If block is **not passed** the obtained lock will be released after it's ttl;

Return value:
- `[Hash<Symbol,Any>]` Format: `{ ok: true/false, result: Symbol/Hash }`;
- for successful lock obtaining:
  ```ruby
  {
    ok: true,
    result: {
      lock_key: String, # acquierd lock key ("rql:lock:your_lock_name")
      acq_id: String, # acquier identifier ("your_process_id/your_thread_id")
      ts: Integer, # time (epoch) when lock was obtained (integer)
      ttl: Integer # lock's time to live in milliseconds (integer)
    }
  }
  ```
- for failed lock obtaining:
  ```ruby
  { ok: false, result: :timeout_reached }
  { ok: false, result: :retry_count_reached }
  { ok: false, result: :unknown }
  ```

---

#### #lock! - exceptional lock obtaining

- fails when (and with):
  - (`RedisQueuedLocks::LockAcquiermentTimeoutError`) `timeout` limit reached before lock is obtained;
  - (`RedisQueuedLocks::LockAcquiermentRetryLimitError`) `retry_count` limit reached before lock is obtained;

```ruby
def lock!(
  lock_name,
  process_id: RedisQueuedLocks::Resource.get_process_id,
  thread_id: RedisQueuedLocks::Resource.get_thread_id,
  ttl: config[:default_lock_ttl],
  queue_ttl: config[:default_queue_ttl],
  timeout: config[:default_timeout],
  retry_count: config[:retry_count],
  retry_delay: config[:retry_delay],
  retry_jitter: config[:retry_jitter],
  &block
)
```

See `#lock` method [documentation](#lock---obtain-a-lock).

---

#### #unlock - release a lock

- release the concrete lock with lock request queue;
- queue will be relased first;

```ruby
def unlock(lock_name)
```

- `lock_name` - `[String]`
  - the lock name that should be released.

Return:
- `[Hash<Symbol,Any>]` - Format: `{ ok: true/false, result: Hash<Symbol,Numeric|String> }`;

```ruby
{
  ok: true,
  result: {
    rel_time: 0.02, # time spent to lock release (in seconds)
    rel_key: "rql:lock:your_lock_name", # released lock key
    rel_queue: "rql:lock_queue:your_lock_name" # released lock key queue
  }
}
```

---

#### #clear_locks - release all locks and lock queues

- release all obtained locks and related lock request queues;
- queues will be released first;

```ruby
def clear_locks(batch_size: config[:lock_release_batch_size])
```

- `batch_size` - `[Integer]`
  - batch of cleared locks and lock queus unde the one pipelined redis command;

Return:
- `[Hash<Symbol,Any>]` - Format: `{ ok: true/false, result: Hash<Symbol,Numeric> }`;

```ruby
{
  ok: true,
  result: {
    rel_time: 3.07, # time spent to release all locks and related lock queues
    rel_key_cnt: 100_500 # released redis keys (released locks + released lock queues)
  }
}
```

---

## Instrumentation

An instrumentation layer is incapsulated in `instrumenter` object stored in [config](#configuration) (`RedisQueuedLocks::Client#config[:instrumenter]`).

Instrumenter object should provide `notify(event, payload)` method with the following signarue:

- `event` - `string`;
- `payload` - `hash<Symbol,Any>`;

`redis_queued_locks` provides two instrumenters:

- `RedisQueuedLocks::Instrument::ActiveSupport` - `ActiveSupport::Notifications` instrumenter
  that instrument events via `ActiveSupport::Notifications` API;
- `RedisQueuedLocks::Instrument::VoidNotifier` - instrumenter that does nothing;

By default `RedisQueuedLocks::Client` is configured with the void notifier (which means "instrumentation is disabled").

---

### Instrumentation Events

List of instrumentation events

- **redis_queued_locks.lock_obtained**
- **redis_queued_locks.lock_hold_and_release**
- **redis_queued_locks.explicit_lock_release**
- **redis_queued_locks.explicit_all_locks_release**

Detalized event semantics and payload structure:

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

---

## Todo

- `RedisQueuedLocks::Acquier::Try.try_to_lock` - detailed successful result analization;
- `100%` test coverage;
- better code stylization and interesting refactorings;

---

## Contributing

- Fork it ( https://github.com/0exp/redis_queued_locks )
- Create your feature branch (`git checkout -b feature/my-new-feature`)
- Commit your changes (`git commit -am '[feature_context] Add some feature'`)
- Push to the branch (`git push origin feature/my-new-feature`)
- Create new Pull Request

## License

Released under MIT License.

## Authors

[Rustam Ibragimov](https://github.com/0exp)
