# RedisQueuedLocks &middot; [![Gem Version](https://badge.fury.io/rb/redis_queued_locks.svg)](https://badge.fury.io/rb/redis_queued_locks)

Distributed locks with "lock acquisition queue" capabilities based on the Redis Database.

Provides flexible invocation flow, parametrized limits (lock request ttl, lock ttls, queue ttls, fast failing, etc), logging and instrumentation.

Each lock request is put into the request queue (each lock is hosted by it's own queue separately from other queues) and processed in order of their priority (FIFO). Each lock request lives some period of time (RTTL) (with requeue capabilities) which guarantees the request queue will never be stacked.

---

## Table of Contents

- [Requirements](#requirements)
- [Experience](#experience)
- [Algorithm](#algorithm)
- [Installation](#installation)
- [Setup](#setup)
- [Configuration](#configuration)
- [Usage](#usage)
  - [lock](#lock---obtain-a-lock)
  - [lock!](#lock---exceptional-lock-obtaining)
  - [lock_info](#lock_info)
  - [queue_info](#queue_info)
  - [locked?](#locked)
  - [queued?](#queued)
  - [unlock](#unlock---release-a-lock)
  - [clear_locks](#clear_locks---release-all-locks-and-lock-queues)
  - [extend_lock_ttl](#extend_lock_ttl)
  - [locks](#locks---get-list-of-obtained-locks)
  - [queues](#queues---get-list-of-lock-request-queues)
  - [keys](#keys---get-list-of-taken-locks-and-queues)
  - [locks_info](#locks_info---get-list-of-locks-with-their-info)
  - [queues_info](#queues_info---get-list-of-queues-with-their-info)
  - [clear_dead_queues](#clear_dead_queues---cleanup-queues-with-dead-requests)
- [Instrumentation](#instrumentation)
  - [Instrumentation Events](#instrumentation-events)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)
- [Authors](#authors)

---

### Requirements

- Redis Version: `~> 7.x`;
- Redis Protocol: `RESP3`;
- gem `redis-client`: `~> 0.20`;

---

### Experience

- Battle-tested on huge ruby projects in production: `~1500` locks-per-second are obtained and released on an ongoing basis;
- Works well with `hiredis` driver enabled (it is enabled by default on our projects where `redis_queued_locks` are used);

---

### Algorithm

> Each lock request is put into the request queue (each lock is hosted by it's own queue separately from other queues) and processed in order of their priority (FIFO). Each lock request lives some period of time (RTTL) which guarantees that the request queue will never be stacked.

**Soon**: detailed explanation.

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
redis_client = RedisClient.config.new_pool # NOTE: provide your own RedisClient instance

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

  # (milliseconds) (default: 25)
  config.retry_jitter = 25

  # (seconds) (supports nil)
  # - nil means "no timeout" and you are only limited by "retry_count" config;
  config.try_to_lock_timeout = 10

  # (milliseconds) (default: 5_000)
  # - lock's time to live
  config.default_lock_ttl = 5_000

  # (seconds) (default: 15)
  # - lock request timeout. after this timeout your lock request in queue will be requeued with new position (at the end of the queue);
  config.default_queue_ttl = 15

  # (default: 100)
  # - how many items will be released at a time in RedisQueuedLocks::Client#clear_locks logic (uses SCAN);
  # - affects the performancs of your Redis and Ruby Application (configure thoughtfully);
  config.lock_release_batch_size = 100

  # (default: 500)
  # - how many items should be extracted from redis during the #locks, #queues and #keys operations (uses SCAN);
  # - affects the performance of your Redis and Ruby Application (configure thoughtfully;)
  config.key_extraction_batch_size = 500

  # (default: RedisQueuedLocks::Instrument::VoidNotifier)
  # - instrumentation layer;
  # - you can provde your own instrumenter with `#notify(event, payload = {})`
  #   - event: <string> requried;
  #   - payload: <hash> requried;
  # - disabled by default via VoidNotifier;
  config.instrumenter = RedisQueuedLocks::Instrument::ActiveSupport

  # (default: -> { RedisQueuedLocks::Resource.calc_uniq_identity })
  # - uniqude idenfitier that is uniq per process/pod;
  # - prevents potential lock-acquirement collisions bettween different process/pods
  #   that have identical process_id/thread_id/fiber_id/ractor_id (identivcal acquier ids);
  # - it is calculated once per `RedisQueudLocks::Client` instance;
  # - expects the proc object;
  # - `SecureRandom.hex(8)` by default;
  config.uniq_identifier = -> { RedisQueuedLocks::Resource.calc_uniq_identity }

  # (default: RedisQueuedLocks::Logging::VoidLogger)
  # - the logger object;
  # - should implement `debug(progname = nil, &block)` (minimal requirement) or be an instance of Ruby's `::Logger` class/subclass;
  # - at this moment the only debug logs are realised in following cases:
  #   - "[redis_queued_locks.start_lock_obtaining]" (logs "lock_key", "queue_ttl", "acq_id");
  #   - "[redis_queued_locks.start_try_to_lock_cycle]" (logs "lock_key", "queue_ttl", "acq_id");
  #   - "[redis_queued_locks.dead_score_reached__reset_acquier_position]" (logs "lock_key", "queue_ttl", "acq_id");
  #   - "[redis_queued_locks.lock_obtained]" (logs "lockkey", "queue_ttl", "acq_id", "acq_time");
  # - by default uses VoidLogger that does nothing;
  config.logger = RedisQueuedLocks::Logging::VoidLogger

  # (default: false)
  # - adds additional debug logs;
  # - enables additional logs for each internal try-retry lock acquiring (a lot of logs can be generated depending on your retry configurations);
  # - it adds following logs in addition to the existing:
  #   - "[redis_queued_locks.try_lock.start]" (logs "lock_key", "queue_ttl", "acq_id");
  #   - "[redis_queued_locks.try_lock.rconn_fetched]" (logs "lock_key", "queue_ttl", "acq_id");
  #   - "[redis_queued_locks.try_lock.acq_added_to_queue]" (logs "lock_key", "queue_ttl", "acq_id)";
  #   - "[redis_queued_locks.try_lock.remove_expired_acqs]" (logs "lock_key", "queue_ttl", "acq_id");
  #   - "[redis_queued_locks.try_lock.get_first_from_queue]" (logs "lock_key", "queue_ttl", "acq_id", "first_acq_id_in_queue");
  #   - "[redis_queued_locks.try_lock.exit__queue_ttl_reached]" (logs "lock_key", "queue_ttl", "acq_id");
  #   - "[redis_queued_locks.try_lock.exit__no_first]" (logs "lock_key", "queue_ttl", "acq_id", "first_acq_id_in_queue", "<current_lock_data>");
  #   - "[redis_queued_locks.try_lock.exit__still_obtained]" (logs "lock_key", "queue_ttl", "acq_id", "first_acq_id_in_queue", "locked_by_acq_id", "<current_lock_data>");
  #   - "[redis_queued_locks.try_lock.run__free_to_acquire]" (logs "lock_key", "queue_ttl", "acq_id");
  config.log_lock_try = false
end
```

---

### Usage

- [lock](#lock---obtain-a-lock)
- [lock!](#lock---exeptional-lock-obtaining)
- [lock_info](#lock_info)
- [queue_info](#queue_info)
- [locked?](#locked)
- [queued?](#queued)
- [unlock](#unlock---release-a-lock)
- [clear_locks](#clear_locks---release-all-locks-and-lock-queues)
- [extend_lock_ttl](#extend_lock_ttl)
- [locks](#locks---get-list-of-obtained-locks)
- [queues](#queues---get-list-of-lock-request-queues)
- [keys](#keys---get-list-of-taken-locks-and-queues)
- [locks_info](#locks_info---get-list-of-locks-with-their-info)
- [queues_info](#queues_info---get-list-of-queues-with-their-info)
- [clear_dead_queues](#clear_dead_queues---cleanup-queues-with-dead-requests)

---

#### #lock - obtain a lock

- If block is passed the obtained lock will be released after the block execution or the lock's ttl (what will happen first);
- If block is not passed the obtained lock will be released after lock's ttl;
- If block is passed the block's yield result will be returned;
- If block is not passed the lock information will be returned;

```ruby
def lock(
  lock_name,
  ttl: config[:default_lock_ttl],
  queue_ttl: config[:default_queue_ttl],
  timeout: config[:try_to_lock_timeout],
  timed: false,
  retry_count: config[:retry_count],
  retry_delay: config[:retry_delay],
  retry_jitter: config[:retry_jitter],
  raise_errors: false,
  fail_fast: false,
  identity: uniq_identity, # (attr_accessor) calculated during client instantiation via config[:uniq_identifier] proc;
  meta: nil,
  instrument: nil,
  logger: config[:logger],
  log_lock_try: config[:log_lock_try],
  &block
)
```

- `lock_name` - `[String]`
  - Lock name to be obtained.
- `ttl` [Integer]
  - Lock's time to live (in milliseconds).
- `queue_ttl` - `[Integer]`
  - Lifetime of the acuier's lock request. In seconds.
- `timeout` - `[Integer,NilClass]`
  - Time period whe should try to acquire the lock (in seconds). Nil means "without timeout".
- `timed` - `[Boolean]`
  - Limit the invocation time period of the passed block of code by the lock's TTL.
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
- `fail_fast` - `[Boolean]`
    - Should the required lock to be checked before the try and exit immidietly if lock is
      already obtained;
    - Should the logic exit immidietly after the first try if the lock was obtained
      by another process while the lock request queue was initially empty;
- `identity` - `[String]`
  - An unique string that is unique per `RedisQueuedLock::Client` instance. Resolves the
    collisions between the same process_id/thread_id/fiber_id/ractor_id identifiers on different
    pods or/and nodes of your application;
  - It is calculated once during `RedisQueuedLock::Client` instantiation and stored in `@uniq_identity`
    ivar (accessed via `uniq_dentity` accessor method);
- `meta` - `[NilClass,Hash<String|Symbol,Any>]`
  - A custom metadata wich will be passed to the lock data in addition to the existing data;
  - Custom metadata can not contain reserved lock data keys (such as `lock_key`, `acq_id`, `ts`, `ini_ttl`, `rem_ttl`);
- `instrument` - `[NilClass,Any]`
  - Custom instrumentation data wich will be passed to the instrumenter's payload with :instrument key;
- `logger` - `[::Logger,#debug]`
  - Logger object used from the configuration layer (see config[:logger]);
  - See `RedisQueuedLocks::Logging::VoidLogger` for example;
- `log_lock_try` - `[Boolean]`
  - should be logged the each try of lock acquiring (a lot of logs can be generated depending on your retry configurations);
  - see `config[:log_lock_try]`;
- `block` - `[Block]`
  - A block of code that should be executed after the successfully acquired lock.
  - If block is **passed** the obtained lock will be released after the block execution or it's ttl (what will happen first);
  - If block is **not passed** the obtained lock will be released after it's ttl;

Return value:

- If block is passed the block's yield result will be returned;
- If block is not passed the lock information will be returned;
- Lock information result:
  - Signature: `[yield, Hash<Symbol,Boolean|Hash<Symbol,Numeric|String>>]`
  - Format: `{ ok: true/false, result: <Symbol|Hash<Symbol,Hash>> }`;
  - for successful lock obtaining:
    ```ruby
    {
      ok: true,
      result: {
        lock_key: String, # acquierd lock key ("rql:lock:your_lock_name")
        acq_id: String, # acquier identifier ("process_id/thread_id/fiber_id/ractor_id/identity")
        ts: Integer, # time (epoch) when lock was obtained (integer)
        ttl: Integer # lock's time to live in milliseconds (integer)
      }
    }
    ```
  - for failed lock obtaining:
    ```ruby
    { ok: false, result: :timeout_reached }
    { ok: false, result: :retry_count_reached }
    { ok: false, result: :fail_fast_no_try } # see <fail_fast> option
    { ok: false, result: :fail_fast_after_try } # see <fail_fast> option
    { ok: false, result: :unknown }
    ```

---

#### #lock! - exceptional lock obtaining

- fails when (and with):
  - (`RedisQueuedLocks::LockAlreadyObtainedError`) when `fail_fast` is `true` and lock is already obtained;
  - (`RedisQueuedLocks::LockAcquiermentTimeoutError`) `timeout` limit reached before lock is obtained;
  - (`RedisQueuedLocks::LockAcquiermentRetryLimitError`) `retry_count` limit reached before lock is obtained;

```ruby
def lock!(
  lock_name,
  ttl: config[:default_lock_ttl],
  queue_ttl: config[:default_queue_ttl],
  timeout: config[:default_timeout],
  retry_count: config[:retry_count],
  retry_delay: config[:retry_delay],
  retry_jitter: config[:retry_jitter],
  identity: uniq_identity,
  fail_fast: false,
  meta: nil,
  instrument: nil,
  logger: config[:logger],
  log_lock_try: config[:log_lock_try],
  &block
)
```

See `#lock` method [documentation](#lock---obtain-a-lock).

---

#### #lock_info

- get the lock information;
- returns `nil` if lock does not exist;
- lock data (`Hash<Symbol,String|Integer>`):
  - `"lock_key"` - `string` - lock key in redis;
  - `"acq_id"` - `string` - acquier identifier (process_id/thread_id/fiber_id/ractor_id/identity);
  - `"ts"` - `integer`/`epoch` - the time lock was obtained;
  - `"init_ttl"` - `integer` - (milliseconds) initial lock key ttl;
  - `"rem_ttl"` - `integer` - (milliseconds) remaining lock key ttl;
  - `custom metadata`- `string`/`integer` - custom metadata passed to the `lock`/`lock!` methods via `meta:` keyword argument (see [lock]((#lock---obtain-a-lock)) method documentation);

```ruby
# without custom metadata
rql.lock_info("your_lock_name")

# =>
{
  "lock_key" => "rql:lock:your_lock_name",
  "acq_id" => "rql:acq:123/456/567/678/374dd74324",
  "ts" => 123456789,
  "ini_ttl" => 123456789,
  "rem_ttl" => 123456789
}
```

```ruby
# with custom metadata
rql.lock("your_lock_name", meta: { "kek" => "pek", "bum" => 123 })
rql.lock_info("your_lock_name")

# =>
{
  "lock_key" => "rql:lock:your_lock_name",
  "acq_id" => "rql:acq:123/456/567/678/374dd74324",
  "ts" => 123456789,
  "ini_ttl" => 123456789,
  "rem_ttl" => 123456789,
  "kek" => "pek",
  "bum" => "123" # NOTE: returned as a raw string directly from Redis
}
```

---

#### #queue_info

- get the lock queue information;
- queue represents the ordered set of lock key reqests:
  - set is ordered by score in ASC manner (inside the Redis Set);
  - score is represented as a timestamp when the lock request was made;
  - represents the acquier identifier and their score as an array of hashes;
- returns `nil` if lock queue does not exist;
- lock queue data (`Hash<Symbol,String|Array<Hash<Symbol,String|Numeric>>`):
  - `"lock_queue"` - `string` - lock queue key in redis;
  - `"queue"` - `array` - an array of lock requests (array of hashes):
    - `"acq_id"` - `string` - acquier identifier (process_id/thread_id/fiber_id/ractor_id/identity by default);
    - `"score"` - `float`/`epoch` - time when the lock request was made (epoch);

```
| Returns an information about the required lock queue by the lock name. The result
| represnts the ordered lock request queue that is ordered by score (Redis sets) and shows
| lock acquirers and their position in queue. Async nature with redis communcation can lead
| the situation when the queue becomes empty during the queue data extraction. So sometimes
| you can receive the lock queue info with empty queue value (an empty array).
```

```ruby
rql.queue_info("your_lock_name")

# =>
{
  "lock_queue" => "rql:lock_queue:your_lock_name",
  "queue" => [
    { "acq_id" => "rql:acq:123/456/567/678/fa76df9cc2", "score" => 1},
    { "acq_id" => "rql:acq:123/567/456/679/c7bfcaf4f9", "score" => 2},
    { "acq_id" => "rql:acq:555/329/523/127/7329553b11", "score" => 3},
    # ...etc
  ]
}
```

---

#### #locked?

- is the lock obtaied or not?

```ruby
rql.locked?("your_lock_name") # => true/false
```

---

#### #queued?

- is the lock queued for obtain / has requests for obtain?

```ruby
rql.queued?("your_lock_name") # => true/false
```

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
- `[Hash<Symbol,Numeric|String>]` - Format: `{ ok: true/false, result: Hash<Symbol,Numeric|String> }`;

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
  - the size of batch of locks and lock queus that should be cleared under the one pipelined redis command at once;

Return:
- `[Hash<Symbol,Numeric>]` - Format: `{ ok: true/false, result: Hash<Symbol,Numeric> }`;

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

#### #extend_lock_ttl

- soon

---

#### #locks - get list of obtained locks

- uses redis `SCAN` under the hood;
- accepts:
  - `:scan_size` - `Integer` - (`config[:key_extraction_batch_size]` by default);
  - `:with_info` - `Boolean` - `false` by default (for details see [#locks_info](#locks_info---get-list-of-locks-with-their-info));
- returns:
  - `Set<String>` (for `with_info: false`);
  - `Set<Hash<Symbol,Any>>` (for `with_info: true`). See [#locks_info](#locks_info---get-list-of-locks-with-their-info) for details;

```ruby
rql.locks # or rql.locks(scan_size: 123)

=>
#<Set:
 {"rql:lock:locklock75",
  "rql:lock:locklock9",
  "rql:lock:locklock108",
  "rql:lock:locklock7",
  "rql:lock:locklock48",
  "rql:lock:locklock104",
  "rql:lock:locklock13",
  "rql:lock:locklock62",
  "rql:lock:locklock80",
  "rql:lock:locklock28",
  ...}>
```

---

#### #queues - get list of lock request queues

- uses redis `SCAN` under the hood;
- accepts
  - `:scan_size` - `Integer` - (`config[:key_extraction_batch_size]` by default);
  - `:with_info` - `Boolean` - `false` by default (for details see [#queues_info](#queues_info---get-list-of-queues-with-their-info));
- returns:
  - `Set<String>` (for `with_info: false`);
  - `Set<Hash<Symbol,Any>>` (for `with_info: true`). See [#locks_info](#locks_info---get-list-of-locks-with-their-info) for details;

```ruby
rql.queues # or rql.queues(scan_size: 123)

=>
#<Set:
 {"rql:lock_queue:locklock75",
  "rql:lock_queue:locklock9",
  "rql:lock_queue:locklock108",
  "rql:lock_queue:locklock7",
  "rql:lock_queue:locklock48",
  "rql:lock_queue:locklock104",
  "rql:lock_queue:locklock13",
  "rql:lock_queue:locklock62",
  "rql:lock_queue:locklock80",
  "rql:lock_queue:locklock28",
  ...}>
```

---

#### #keys - get list of taken locks and queues

- uses redis `SCAN` under the hood;
- accepts:
  `:scan_size` - `Integer` - (`config[:key_extraction_batch_size]` by default);
- returns: `Set<String>`

```ruby
rql.keys # or rql.keys(scan_size: 123)

=>
#<Set:
 {"rql:lock_queue:locklock75",
  "rql:lock_queue:locklock9",
  "rql:lock:locklock9",
  "rql:lock_queue:locklock108",
  "rql:lock_queue:locklock7",
  "rql:lock:locklock7",
  "rql:lock_queue:locklock48",
  "rql:lock_queue:locklock104",
  "rql:lock:locklock104",
  "rql:lock_queue:locklock13",
  "rql:lock_queue:locklock62",
  "rql:lock_queue:locklock80",
  "rql:lock:locklock80",
  "rql:lock_queue:locklock28",
  ...}>
```

---

#### #locks_info - get list of locks with their info

- uses redis `SCAN` under the hod;
- accepts `scan_size:`/`Integer` option (`config[:key_extraction_batch_size]` by default);
- returns `Set<Hash<Symbol,Any>>` (see [#lock_info](#lock_info) and examples below for details).
  - contained data: `{ lock: String, status: Symbol, info: Hash<String,Any> }`;
  - `:lock` - `String` - lock key in Redis;
  - `:status` - `Symbol`- `:released` or `:alive`
    - the lock may become relased durign the lock info extraction process;
    - `:info` for `:released` keys is empty (`{}`);
  - `:info` - `Hash<String,Any>` - lock data stored in the lock key in Redis. See [#lock_info](#lock_info) for details;

```ruby
rql.locks_info # or rql.locks_info(scan_size: 123)

# =>
=> #<Set:
 {{:lock=>"rql:lock:some-lock-123",
   :status=>:alive,
   :info=>{
    "acq_id"=>"rql:acq:41478/4320/4340/4360/848818f09d8c3420",
    "ts"=>1711607112.670343,
    "ini_ttl"=>15000,
    "rem_ttl"=>13998}},
  {:lock=>"rql:lock:some-lock-456",
   :status=>:released,
   :info=>{},
  ...}>
```

---

#### #queues_info - get list of queues with their info

- uses redis `SCAN` under the hod;
- accepts `scan_size:`/`Integer` option (`config[:key_extraction_batch_size]` by default);
- returns `Set<Hash<Symbol,Any>>` (see [#queue_info](#queue_info) and examples below for details).
  - contained data: `{ queue: String, requests: Array<Hash<String,Any>> }`
  - `:queue` - `String` - lock key queue in Redis;
  - `:requests` - `Array<Hash<String,Any>>` - lock requests in the que with their acquier id and score.

```ruby
rql.queues_info # or rql.qeuues_info(scan_size: 123)

=> #<Set:
 {{:queue=>"rql:lock_queue:some-lock-123",
   :requests=>
    [{"acq_id"=>"rql:acq:38529/4500/4520/4360/66093702f24a3129", "score"=>1711606640.540842},
     {"acq_id"=>"rql:acq:38529/4580/4600/4360/66093702f24a3129", "score"=>1711606640.540906},
     {"acq_id"=>"rql:acq:38529/4620/4640/4360/66093702f24a3129", "score"=>1711606640.5409632}]},
  {:queue=>"rql:lock_queue:some-lock-456",
   :requests=>
    [{"acq_id"=>"rql:acq:38529/4380/4400/4360/66093702f24a3129", "score"=>1711606640.540722},
     {"acq_id"=>"rql:acq:38529/4420/4440/4360/66093702f24a3129", "score"=>1711606640.5407748},
     {"acq_id"=>"rql:acq:38529/4460/4480/4360/66093702f24a3129", "score"=>1711606640.540808}]},
  ...}>
```
---

#### #clear_dead_queues - cleanup queues with dead requests

- soon

---

## Instrumentation

- [Instrumentation Events](#instrumentation-events)

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

- `redis_queued_locks.lock_obtained`
- `redis_queued_locks.lock_hold_and_release`
- `redis_queued_locks.explicit_lock_release`
- `redis_queued_locks.explicit_all_locks_release`

Detalized event semantics and payload structure:

- `"redis_queued_locks.lock_obtained"`
  - a moment when the lock was obtained;
  - payload:
    - `:ttl` - `integer`/`milliseconds` - lock ttl;
    - `:acq_id` - `string` - lock acquier identifier;
    - `:lock_key` - `string` - lock name;
    - `:ts` - `integer`/`epoch` - the time when the lock was obtaiend;
    - `:acq_time` - `float`/`milliseconds` - time spent on lock acquiring;
    - `:instrument` - `nil`/`Any` - custom data passed to the `lock`/`lock!` method as `:instrument` attribute;
- `"redis_queued_locks.lock_hold_and_release"`
  - an event signalizes about the "hold+and+release" process
    when the lock obtained and hold by the block of logic;
  - payload:
    - `:hold_time` - `float`/`milliseconds` - lock hold time;
    - `:ttl` - `integer`/`milliseconds` - lock ttl;
    - `:acq_id` - `string` - lock acquier identifier;
    - `:lock_key` - `string` - lock name;
    - `:ts` - `integer`/`epoch` - the time when lock was obtained;
    - `:acq_time` - `float`/`milliseconds` - time spent on lock acquiring;
    - `:instrument` - `nil`/`Any` - custom data passed to the `lock`/`lock!` method as `:instrument` attribute;
- `"redis_queued_locks.explicit_lock_release"`
  - an event signalizes about the explicit lock release (invoked via `RedisQueuedLock#unlock`);
  - payload:
    - `:at` - `integer`/`epoch` - the time when the lock was released;
    - `:rel_time` - `float`/`milliseconds` - time spent on lock releasing;
    - `:lock_key` - `string` - released lock (lock name);
    - `:lock_key_queue` - `string` - released lock queue (lock queue name);
- `"redis_queued_locks.explicit_all_locks_release"`
  - an event signalizes about the explicit all locks release (invoked via `RedisQueuedLock#clear_locks`);
  - payload:
    - `:rel_time` - `float`/`milliseconds` - time spent on "realese all locks" operation;
    - `:at` - `integer`/`epoch` - the time when the operation has ended;
    - `:rel_keys` - `integer` - released redis keys count (`released queue keys` + `released lock keys`);

---

## Roadmap

- Semantic Error objects for unexpected Redis errors;
- `100%` test coverage;
- per-block-holding-the-lock sidecar `Ractor` and `in progress queue` in RedisDB that will extend
  the acquired lock for long-running blocks of code (that invoked "under" the lock
  whose ttl may expire before the block execution completes). It only makes sense for non-`timed` locks;
- lock prioritization;
- support for LIFO strategy;
- structured logging (separated docs);
- GitHub Actions CI;
- `RedisQueuedLocks::Acquier::Try.try_to_lock` - detailed successful result analization;
- better code stylization and interesting refactorings (observers);
- dead queue keys cleanup (empty queues);
- statistics with UI;

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
