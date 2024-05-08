# RedisQueuedLocks &middot; ![Gem Version](https://img.shields.io/gem/v/redis_queued_locks) ![build](https://github.com/0exp/redis_queued_locks/actions/workflows/build.yml/badge.svg??branch=master)

<a href="https://redis.io/docs/manual/patterns/distributed-locks/">Distributed locks</a> with "prioritized lock acquisition queue" capabilities based on the Redis Database.

Each lock request is put into the request queue (each lock is hosted by it's own queue separately from other queues) and processed in order of their priority (FIFO). Each lock request lives some period of time (RTTL) (with requeue capabilities) which guarantees the request queue will never be stacked.

Provides flexible invocation flow, parametrized limits (lock request ttl, lock ttls, queue ttls, lock attempts limit, fast failing, etc), logging and instrumentation.

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
  - [clear_dead_requests](#clear_dead_requests)
- [Dead locks and Reentrant locks](#dead-locks-and-reentrant-locks)
- [Logging](#logging)
- [Instrumentation](#instrumentation)
  - [Instrumentation Events](#instrumentation-events)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)
- [Authors](#authors)

---

### Requirements

<sup>\[[back to top](#table-of-contents)\]</sup>

- Redis Version: `~> 7.x`;
- Redis Protocol: `RESP3`;
- gem `redis-client`: `~> 0.20`;
- Ruby: `>= 3.1`;

---

### Experience

<sup>\[[back to top](#table-of-contents)\]</sup>

- Battle-tested on huge ruby projects in production: `~3000` locks-per-second are obtained and released on an ongoing basis;
- Works well with `hiredis` driver enabled (it is enabled by default on our projects where `redis_queued_locks` are used);

---

### Algorithm

<sup>\[[back to top](#table-of-contents)\]</sup>

> Each lock request is put into the request queue (each lock is hosted by it's own queue separately from other queues) and processed in order of their priority (FIFO). Each lock request lives some period of time (RTTL) which guarantees that the request queue will never be stacked.

**Soon**: detailed explanation.

---

### Installation

<sup>\[[back to top](#table-of-contents)\]</sup>

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

<sup>\[[back to top](#table-of-contents)\]</sup>

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

<sup>\[[back to top](#table-of-contents)\]</sup>

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

  # (boolean) (default: false)
  # - should be all blocks of code are timed by default;
  config.is_timed_by_default = false

  # (symbol) (default: :wait_for_lock)
  # - The conflict strategy mode for cases when the process that obtained the lock want to acquire this lock again;
  # - Realizes "reentrant locks" abstraction (same process conflict / same process deadlock);
  # - By default uses `:wait_for_lock` strategy (classic way);
  # - Strategies:
  #   - `:work_through` - continue working under the lock <without> lock's TTL extension;
  #   - `:extendable_work_through` - continue working under the lock <with> lock's TTL extension;
  #   - `:wait_for_lock` - (default) - work in classic way (with timeouts, retry delays, retry limits, etc - in classic way :));
  #   - `:dead_locking` - fail with deadlock exception;
  # - Can be customized in methods via `:conflict_strategy` attribute (see method signatures of #lock and #lock! methods);
  # - See "Dead locks and Reentrant Locks" documentation section in REDME.md for details;
  config.default_conflict_strategy = :wait_for_lock

  # (default: 100)
  # - how many items will be released at a time in #clear_locks and in #clear_dead_requests (uses SCAN);
  # - affects the performance of your Redis and Ruby Application (configure thoughtfully);
  config.lock_release_batch_size = 100

  # (default: 500)
  # - how many items should be extracted from redis during the #locks, #queues, #keys
  #   #locks_info, and #queues_info operations (uses SCAN);
  # - affects the performance of your Redis and Ruby Application (configure thoughtfully;)
  config.key_extraction_batch_size = 500

  # (default: 1 day)
  # - the default period of time (in milliseconds) after which a lock request is considered dead;
  # - used for `#clear_dead_requests` as default vaule of `:dead_ttl` option;
  config.dead_request_ttl = (1 * 24 * 60 * 60 * 1000) # one day in milliseconds

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
  # - supports `SemanticLogger::Logger` (see "semantic_logger" gem)
  # - at this moment the only debug logs are realised in following cases:
  #   - "[redis_queued_locks.start_lock_obtaining]" (logs "lock_key", "queue_ttl", "acq_id");
  #   - "[redis_queued_locks.start_try_to_lock_cycle]" (logs "lock_key", "queue_ttl", "acq_id");
  #   - "[redis_queued_locks.dead_score_reached__reset_acquier_position]" (logs "lock_key", "queue_ttl", "acq_id");
  #   - "[redis_queued_locks.lock_obtained]" (logs "lock_key", "queue_ttl", "acq_id", "acq_time");
  #   - "[redis_queued_locks.extendable_reentrant_lock_obtained]" (logs "lock_key", "queue_ttl", "acq_id", "acq_time");
  #   - "[redis_queued_locks.reentrant_lock_obtained]" (logs "lock_key", "queue_ttl", "acq_id", "acq_time");
  #   - "[redis_queued_locks.fail_fast_or_limits_reached_or_deadlock__dequeue]" (logs "lock_key", "queue_ttl", "acq_id");
  #   - "[redis_queued_locks.expire_lock]" (logs "lock_key", "queue_ttl", "acq_id");
  #   - "[redis_queued_locks.decrease_lock]" (logs "lock_key", "decreased_ttl", "queue_ttl", "acq_id");
  # - by default uses VoidLogger that does nothing;
  config.logger = RedisQueuedLocks::Logging::VoidLogger

  # (default: false)
  # - adds additional debug logs;
  # - enables additional logs for each internal try-retry lock acquiring (a lot of logs can be generated depending on your retry configurations);
  # - it adds following logs in addition to the existing:
  #   - "[redis_queued_locks.try_lock.start]" (logs "lock_key", "queue_ttl", "acq_id");
  #   - "[redis_queued_locks.try_lock.rconn_fetched]" (logs "lock_key", "queue_ttl", "acq_id");
  #   - "[redis_queued_locks.try_lock.same_process_conflict_detected]" (logs "lock_key", "queue_ttl", "acq_id");
  #   - "[redis_queued_locks.try_lock.same_process_conflict_analyzed]" (logs "lock_key", "queue_ttl", "acq_id", "spc_status");
  #   - "[redis_queued_locks.try_lock.reentrant_lock__extend_and_work_through]" (logs "lock_key", "queue_ttl", "acq_id", "spc_status", "last_ext_ttl", "last_ext_ts");
  #   - "[redis_queued_locks.try_lock.reentrant_lock__work_through]" (logs "lock_key", "queue_ttl", "acq_id", "spc_status", last_spc_ts);
  #   - "[redis_queued_locks.try_lock.acq_added_to_queue]" (logs "lock_key", "queue_ttl", "acq_id)";
  #   - "[redis_queued_locks.try_lock.remove_expired_acqs]" (logs "lock_key", "queue_ttl", "acq_id");
  #   - "[redis_queued_locks.try_lock.get_first_from_queue]" (logs "lock_key", "queue_ttl", "acq_id", "first_acq_id_in_queue");
  #   - "[redis_queued_locks.try_lock.exit__queue_ttl_reached]" (logs "lock_key", "queue_ttl", "acq_id");
  #   - "[redis_queued_locks.try_lock.exit__no_first]" (logs "lock_key", "queue_ttl", "acq_id", "first_acq_id_in_queue", "<current_lock_data>");
  #   - "[redis_queued_locks.try_lock.exit__lock_still_obtained]" (logs "lock_key", "queue_ttl", "acq_id", "first_acq_id_in_queue", "locked_by_acq_id", "<current_lock_data>");
  #   - "[redis_queued_locks.try_lock.obtain__free_to_acquire]" (logs "lock_key", "queue_ttl", "acq_id");
  config.log_lock_try = false
end
```

---

### Usage

<sup>\[[back to top](#table-of-contents)\]</sup>

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
- [clear_dead_requests](#clear_dead_requests)

---

#### #lock - obtain a lock

<sup>\[[back to top](#usage)\]</sup>

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
  timed: config[:is_timed_by_default],
  retry_count: config[:retry_count],
  retry_delay: config[:retry_delay],
  retry_jitter: config[:retry_jitter],
  raise_errors: false,
  fail_fast: false,
  conflict_strategy: config[:default_conflict_strategy],
  identity: uniq_identity, # (attr_accessor) calculated during client instantiation via config[:uniq_identifier] proc;
  meta: nil,
  instrument: nil,
  logger: config[:logger],
  log_lock_try: config[:log_lock_try],
  &block
)
```

- `lock_name` - (required) `[String]`
  - Lock name to be obtained.
- `ttl` - (optional) - [Integer]
  - Lock's time to live (in milliseconds);
  - pre-configured in `config[:default_lock_ttl]`;
- `queue_ttl` - (optional) `[Integer]`
  - Lifetime of the acuier's lock request. In seconds.
  - pre-configured in `config[:default_queue_ttl]`;
- `timeout` - (optional) `[Integer,NilClass]`
  - Time period a client should try to acquire the lock (in seconds). Nil means "without timeout".
  - pre-configured in `config[:try_to_lock_timeout]`;
- `timed` - (optiona) `[Boolean]`
  - Limit the invocation time period of the passed block of code by the lock's TTL.
  - pre-configured in `config[:is_timed_by_default]`;
  - `false` by default;
- `retry_count` - (optional) `[Integer,NilClass]`
  - How many times we should try to acquire a lock. Nil means "infinite retries".
  - pre-configured in `config[:retry_count]`;
- `retry_delay` - (optional) `[Integer]`
  - A time-interval between the each retry (in milliseconds).
  - pre-configured in `config[:retry_delay]`;
- `retry_jitter` - (optional) `[Integer]`
  - Time-shift range for retry-delay (in milliseconds);
  - pre-configured in `config[:retry_jitter]`;
- `instrumenter` - (optional) `[#notify]`
  - See RedisQueuedLocks::Instrument::ActiveSupport for example;
  - See [Instrumentation](#instrumentation) section of docs;
  - pre-configured in `config[:isntrumenter]` with void notifier (`RedisQueuedLocks::Instrumenter::VoidNotifier`);
- `raise_errors` - (optional) `[Boolean]`
  - Raise errors on library-related limits (such as timeout or retry count limit) and on lock conflicts (such as same-process dead locks);
  - `false` by default;
- `fail_fast` - (optional) `[Boolean]`
    - Should the required lock to be checked before the try and exit immidietly if lock is
      already obtained;
    - Should the logic exit immidietly after the first try if the lock was obtained
      by another process while the lock request queue was initially empty;
    - `false` by default;
- `conflict_strategy` - (optional) - `[Symbol]``
  - The conflict strategy mode for cases when the process that obtained the lock
    want to acquire this lock again;
  - By default uses `:wait_for_lock` strategy;
  - pre-confured in `config[:default_conflict_strategy]`;
  - Strategies:
    - `:work_through` - continue working under the lock **without** lock's TTL extension;
    - `:extendable_work_through` - continue working under the lock **with** lock's TTL extension;
    - `:wait_for_lock` - (default) - work in classic way (with timeouts, retry delays, retry limits, etc - in classic way :));
    - `:dead_locking` - fail with deadlock exception;
  - See [Dead locks and Reentrant locks](#dead-locks-and-reentrant-locks) readme section for details;
- `identity` - (optional) `[String]`
  - An unique string that is unique per `RedisQueuedLock::Client` instance. Resolves the
    collisions between the same process_id/thread_id/fiber_id/ractor_id identifiers on different
    pods or/and nodes of your application;
  - It is calculated once during `RedisQueuedLock::Client` instantiation and stored in `@uniq_identity`
    ivar (accessed via `uniq_dentity` accessor method);
  - Identity calculator is pre-configured in `config[:uniq_identifier]`;
- `meta` - (optional) `[NilClass,Hash<String|Symbol,Any>]`
  - A custom metadata wich will be passed to the lock data in addition to the existing data;
  - Custom metadata can not contain reserved lock data keys (such as `lock_key`, `acq_id`, `ts`, `ini_ttl`, `rem_ttl`);
  - `nil` by default (means "no metadata");
- `instrument` - (optional) `[NilClass,Any]`
  - Custom instrumentation data wich will be passed to the instrumenter's payload with :instrument key;
  - `nil` by default (means "no custom instrumentation data");
- `logger` - (optional) `[::Logger,#debug]`
  - Logger object used for loggin internal mutation oeprations and opertioan results / process progress;
  - pre-configured in `config[:logger]` with void logger `RedisQueuedLocks::Logging::VoidLogger`;
- `log_lock_try` - (optional) `[Boolean]`
  - should be logged the each try of lock acquiring (a lot of logs can be generated depending on your retry configurations);
  - pre-configured in `config[:log_lock_try]`;
  - `false` by default;
- `block` - (optional) `[Block]`
  - A block of code that should be executed after the successfully acquired lock.
  - If block is **passed** the obtained lock will be released after the block execution or it's ttl (what will happen first);
  - If block is **not passed** the obtained lock will be released after it's ttl;
  - If you want the block to have a TTL too and this TTL to be the same as TTL of the lock
    use `timed: true` option (`rql.lock("my_lock", timed: true, ttl: 5_000) { ... }`)

Return value:

- If block is passed the block's yield result will be returned:
  ```ruby
  result = rql.lock("my_lock") { 1 + 1 }
  result # => 2
  ```
- If block is not passed the lock information will be returned:
  ```ruby
  result = rql.lock("my_lock")
  result # =>
  {
    ok: true,
    result: {
      lock_key: "rql:lock:my_lock",
      acq_id: "rql:acq:26672/2280/2300/2320/70ea5dbf10ea1056",
      ts: 1711909612.653696,
      ttl: 10000,
      process: :lock_obtaining
    }
  }
  ```
- Lock information result:
  - Signature: `[yield, Hash<Symbol,Boolean|Hash<Symbol,Numeric|String>>]`
  - Format: `{ ok: true/false, result: <Symbol|Hash<Symbol,Hash>> }`;
  - Includes the `:process` key that describes a logical type of the lock obtaining process. Possible values:
    - `:lock_obtaining` - classic lock obtaining proces. Default behavior (`conflict_strategy: :wait_for_lock`);
    - `:extendable_conflict_work_through` - reentrant lock acquiring process with lock's TTL extension. Suitable for `conflict_strategy: :extendable_work_through`;
    - `:conflict_work_through` - reentrant lock acquiring process without lock's TTL extension. Suitable for `conflict_strategy: :work_through`;
    - `:dead_locking` - current process tries to acquire a lock that is already acquired by them. Suitalbe for `conflict_startegy: :dead_locking`;
    - For more details see [Dead locks and Reentrant locks](#dead-locks-and-reentrant-locks) readme section;
  - For successful lock obtaining:
    ```ruby
    {
      ok: true,
      result: {
        lock_key: String, # acquierd lock key ("rql:lock:your_lock_name")
        acq_id: String, # acquier identifier ("process_id/thread_id/fiber_id/ractor_id/identity")
        ts: Float, # time (epoch) when lock was obtained (float, Time#to_f)
        ttl: Integer, # lock's time to live in milliseconds (integer)
        process: Symbol # which logical process has acquired the lock (:lock_obtaining, :extendable_conflict_work_through, :conflict_work_through, :conflict_dead_lock)
      }
    }
    ```

    ```ruby
    # example:
    {
      ok: true,
      result: {
        lock_key: "rql:lock:my_lock",
        acq_id: "rql:acq:26672/2280/2300/2320/70ea5dbf10ea1056",
        ts: 1711909612.653696,
        ttl: 10000,
        process: :lock_obtaining # for custom conflict strategies may be: :conflict_dead_lock, :conflict_work_through, :extendable_conflict_work_through
      }
    }
    ```
  - For failed lock obtaining:
    ```ruby
    { ok: false, result: :timeout_reached }
    { ok: false, result: :retry_count_reached }
    { ok: false, result: :conflict_dead_lock } # see <conflict_strategy> option for details (:dead_locking strategy)
    { ok: false, result: :fail_fast_no_try } # see <fail_fast> option
    { ok: false, result: :fail_fast_after_try } # see <fail_fast> option
    { ok: false, result: :unknown }
    ```

Examples:

- obtain a lock:

```ruby
rql.lock("my_lock") { print "Hello!" }
```

- obtain a lock with custom lock TTL:

```ruby
rql.lock("my_lock", ttl: 5_000) { print "Hello!" } # for 5 seconds
```

- obtain a lock and limit the passed block of code TTL with lock's TTL:

```ruby
rql.lock("my_lock", ttl: 5_000, timed: true) { sleep(4) }
# => OK

rql.lock("my_lock", ttl: 5_000, timed: true) { sleep(6) }
# => fails with RedisQueuedLocks::TimedLockTimeoutError
```

- infinite lock obtaining (no retry limit, no timeout limit):

```ruby
rql.lock("my_lock", retry_count: nil, timeout: nil)
```

- try to obtain with a custom waiting timeout:

```ruby
# First Ruby Process:
rql.lock("my_lock", ttl: 5_000) { sleep(4) } # acquire a long living lock

# Another Ruby Process:
rql.lock("my_lock", timeout: 2) # try to acquire but wait for a 2 seconds maximum
# =>
{ ok: false, result: :timeout_reached }
```

- obtain a lock and immediatly continue working (the lock will live in the background in Redis with the passed ttl)

```ruby
rql.lock("my_lock", ttl: 6_500) # blocks execution until the lock is obtained
puts "Let's go" # will be called immediately after the lock is obtained
```

- add custom metadata to the lock (via `:meta` option):

```ruby
rql.lock("my_lock", ttl: 123456, meta: { "some" => "data", key: 123.456 })

rql.lock_info("my_lock")
# =>
{
  "lock_key" => "rql:lock:my_lock",
  "acq_id" => "rql:acq:123/456/567/678/374dd74324",
  "ts" => 123456789,
  "ini_ttl" => 123456,
  "rem_ttl" => 123440,
  "some" => "data",
  "key" => "123.456" # NOTE: returned as a raw string directly from Redis
}
```

- (`:queue_ttl`) setting a short limit of time to the lock request queue position (if a process fails to acquire
  the lock within this period of time (and before timeout/retry_count limits occurs of course) -
  it's lock request will be moved to the end of queue):

```ruby
rql.lock("my_lock", queue_ttl: 5, timeout: 10_000, retry_count: nil)
# "queue_ttl: 5": 5 seconds time slot before the lock request moves to the end of queue;
# "timeout" and "retry_count" is used as "endless lock try attempts" example to show the lock queue behavior;

# lock queue: =>
[
 "rql:acq:123/456/567/676/374dd74324", 
 "rql:acq:123/456/567/677/374dd74322", # <- long living lock
 "rql:acq:123/456/567/679/374dd74321",
 "rql:acq:123/456/567/683/374dd74322", # <== we are here
 "rql:acq:123/456/567/685/374dd74329", # some other waiting process
]

# ... some period of time (2 seconds later)
# lock queue: =>
[
 "rql:acq:123/456/567/677/374dd74322", # <- long living lock
 "rql:acq:123/456/567/679/374dd74321",
 "rql:acq:123/456/567/683/374dd74322", # <== we are here
 "rql:acq:123/456/567/685/374dd74329", # some other waiting process
]

# ... some period of time (3 seconds later)
# ... queue_ttl time limit is reached
# lock queue: =>
[
 "rql:acq:123/456/567/685/374dd74329", # some other waiting process
 "rql:acq:123/456/567/683/374dd74322", # <== we are here (moved to the end of the queue)
]

```

---

#### #lock! - exceptional lock obtaining

<sup>\[[back to top](#usage)\]</sup>

- fails when (and with):
  - (`RedisQueuedLocks::LockAlreadyObtainedError`) when `fail_fast` is `true` and lock is already obtained;
  - (`RedisQueuedLocks::LockAcquiermentTimeoutError`) `timeout` limit reached before lock is obtained;
  - (`RedisQueuedLocks::LockAcquiermentRetryLimitError`) `retry_count` limit reached before lock is obtained;

```ruby
def lock!(
  lock_name,
  ttl: config[:default_lock_ttl],
  queue_ttl: config[:default_queue_ttl],
  timeout: config[:try_to_lock_timeout],
  timed: config[:is_timed_by_default],
  retry_count: config[:retry_count],
  retry_delay: config[:retry_delay],
  retry_jitter: config[:retry_jitter],
  fail_fast: false,
  identity: uniq_identity,
  meta: nil,
  logger: config[:logger],
  log_lock_try: config[:log_lock_try],
  instrument: nil,
  conflict_strategy: config[:default_conflict_strategy],
  &block
)
```

See `#lock` method [documentation](#lock---obtain-a-lock).

---

#### #lock_info

<sup>\[[back to top](#usage)\]</sup>

- get the lock information;
- returns `nil` if lock does not exist;
- lock data (`Hash<String,String|Integer>`):
  - `"lock_key"` - `string` - lock key in redis;
  - `"acq_id"` - `string` - acquier identifier (process_id/thread_id/fiber_id/ractor_id/identity);
  - `"ts"` - `numeric`/`epoch` - the time when lock was obtained;
  - `"init_ttl"` - `integer` - (milliseconds) initial lock key ttl;
  - `"rem_ttl"` - `integer` - (milliseconds) remaining lock key ttl;
  - `<custom metadata>`- `string`/`integer` - custom metadata passed to the `lock`/`lock!` methods via `meta:` keyword argument (see [lock]((#lock---obtain-a-lock)) method documentation);
  - additional keys for **reentrant locks** and **extendable reentrant locks**:
    - for any type of reentrant locks:
      - `"spc_cnt"` - `integer` - how many times the lock was obtained as reentrant lock;
    - for non-extendable reentrant locks:
      - `"l_spc_ts"` - `numeric`/`epoch` - timestamp of the last **non-extendable** reentrant lock obtaining;
    - for extendalbe reentrant locks:
      - `"spc_ext_ttl"` - `integer` - (milliseconds) sum of TTL of the each **extendable** reentrant lock (the total TTL extension time);
      - `"l_spc_ext_ini_ttl"` - `integer` - (milliseconds) TTL of the last reentrant lock;
      - `"l_spc_ext_ts"` - `numeric`/`epoch` - timestamp of the last extendable reentrant lock obtaining;

```ruby
# <without custom metadata>
rql.lock_info("your_lock_name")

# =>
{
  "lock_key" => "rql:lock:your_lock_name",
  "acq_id" => "rql:acq:123/456/567/678/374dd74324",
  "ts" => 123456789.12345,
  "ini_ttl" => 5_000,
  "rem_ttl" => 4_999
}
```

```ruby
# <with custom metadata>
rql.lock("your_lock_name", meta: { "kek" => "pek", "bum" => 123 })
rql.lock_info("your_lock_name")

# =>
{
  "lock_key" => "rql:lock:your_lock_name",
  "acq_id" => "rql:acq:123/456/567/678/374dd74324",
  "ts" => 123456789.12345,
  "ini_ttl" => 5_000,
  "rem_ttl" => 4_999,
  "kek" => "pek",
  "bum" => "123" # NOTE: returned as a raw string directly from Redis
}
```

```ruby
# <for reentrant locks>
# (see `conflict_strategy:` kwarg attribute of #lock/#lock! methods and `config.default_conflict_strategy` config)

rql.lock("your_lock_name", ttl: 5_000)
rql.lock("your_lock_name", ttl: 3_000)
rql.lock("your_lock_name", ttl: 2_000)
rql.lock_info("your_lock_name")

# =>
{
  "lock_key" => "rql:lock:your_lock_name",
  "acq_id" => "rql:acq:123/456/567/678/374dd74324",
  "ts" => 123456789.12345,
  "ini_ttl" => 5_000,
  "rem_ttl" => 9_444,
  # ==> keys for any type of reentrant lock:
  "spc_count" => 2, # how many times the lock was obtained as reentrant lock
  # ==> keys for extendable reentarnt locks with `:extendable_work_through` strategy:
  "spc_ext_ttl" => 5_000, # sum of TTL of the each <extendable> reentrant lock (3_000 + 2_000)
  "l_spc_ext_ini_ttl" => 2_000, # TTL of the last <extendable> reentrant lock
  "l_spc_ext_ts" =>  123456792.12345 # timestamp of the last <extendable> reentrant lock obtaining
  # ==> keys for non-extendable locks with `:work_through` strategy:
  "l_spc_ts" => 123456.789 # timestamp of the last <non-extendable> reentrant lock obtaining
}
```

---

#### #queue_info

<sup>\[[back to top](#usage)\]</sup>

Returns an information about the required lock queue by the lock name. The result
represnts the ordered lock request queue that is ordered by score (Redis Sets) and shows
lock acquirers and their position in queue. Async nature with redis communcation can lead
the situation when the queue becomes empty during the queue data extraction. So sometimes
you can receive the lock queue info with empty queue value (an empty array).

- get the lock queue information;
- queue represents the ordered set of lock key reqests:
  - set is ordered by score in ASC manner (inside the Redis Set);
  - score is represented as a timestamp when the lock request was made;
  - represents the acquier identifier and their score as an array of hashes;
- returns `nil` if lock queue does not exist;
- lock queue data (`Hash<String,String|Array<Hash<String|Numeric>>`):
  - `"lock_queue"` - `string` - lock queue key in redis;
  - `"queue"` - `array` - an array of lock requests (array of hashes):
    - `"acq_id"` - `string` - acquier identifier (process_id/thread_id/fiber_id/ractor_id/identity by default);
    - `"score"` - `float`/`epoch` - time when the lock request was made (epoch);

```ruby
rql.queue_info("your_lock_name")

# =>
{
  "lock_queue" => "rql:lock_queue:your_lock_name",
  "queue" => [
    { "acq_id" => "rql:acq:123/456/567/678/fa76df9cc2", "score" => 1711606640.540842},
    { "acq_id" => "rql:acq:123/567/456/679/c7bfcaf4f9", "score" => 1711606640.540906},
    { "acq_id" => "rql:acq:555/329/523/127/7329553b11", "score" => 1711606640.540963},
    # ...etc
  ]
}
```

---

#### #locked?

<sup>\[[back to top](#usage)\]</sup>

- is the lock obtaied or not?

```ruby
rql.locked?("your_lock_name") # => true/false
```

---

#### #queued?

<sup>\[[back to top](#usage)\]</sup>

- is the lock queued for obtain / has requests for obtain?

```ruby
rql.queued?("your_lock_name") # => true/false
```

---

#### #unlock - release a lock

<sup>\[[back to top](#usage)\]</sup>

- release the concrete lock with lock request queue;
- queue will be relased first;
- accepts:
  - `lock_name` - (required) `[String]` - the lock name that should be released.
  - `:logger` - (optional) `[::Logger,#debug]`
    - custom logger object;
    - pre-configured in `config[:logger]`;
  - `:instrumenter` - (optional) `[#notify]`
    - custom instrumenter object;
    - pre-configured in `config[:instrumetner]`;
  - `:instrument` - (optional) `[NilClass,Any]`;
    - custom instrumentation data wich will be passed to the instrumenter's payload with :instrument key;
    - `nil` by default (no additional data);
- if you try to unlock non-existent lock you will receive `ok: true` result with operation timings
  and `:nothing_to_release` result factor inside;

Return:
- `[Hash<Symbol,Boolean|Hash<Symbol,Numeric|String|Symbol>>]` (`{ ok: true/false, result: Hasn }`);
- `:result` format;
  - `:rel_time` - `Float` - time spent to process redis commands (in seconds);
  - `:rel_key` - `String` - released lock key (RedisQueudLocks-internal lock key name from Redis);
  - `:rel_queue` - `String` - released lock queue key (RedisQueuedLocks-internal queue key name from Redis);
  - `:queue_res` - `Symbol` - `:released` (or `:nothing_to_release` if the required queue does not exist);
  - `:lock_res` - `Symbol` - `:released` (or `:nothing_to_release` if the required lock does not exist);

Consider that `lock_res` and `queue_res` can have different value because of the async nature of invoked Redis'es commands.

```ruby
rql.unlock("your_lock_name")

# =>
{
  ok: true,
  result: {
    rel_time: 0.02, # time spent to lock release (in seconds)
    rel_key: "rql:lock:your_lock_name", # released lock key
    rel_queue: "rql:lock_queue:your_lock_name", # released lock key queue
    queue_res: :released, # or :nothing_to_release
    lock_res: :released # or :nothing_to_release
  }
}
```

---

#### #clear_locks - release all locks and lock queues

<sup>\[[back to top](#usage)\]</sup>

- release all obtained locks and related lock request queues;
- queues will be released first;
- accepts:
  - `:batch_size` - (optional) `[Integer]`
    - the size of batch of locks and lock queus that should be cleared under the one pipelined redis command at once;
    - pre-configured in `config[:lock_release_batch_size]`;
  - `:logger` - (optional) `[::Logger,#debug]`
    - custom logger object;
    - pre-configured value in `config[:logger]`;
  - `:instrumenter` - (optional) `[#notify]`
    - custom instrumenter object;
    - pre-configured value in `config[:isntrumenter]`;
  - `:instrument` - (optional) `[NilClass,Any]`
    - custom instrumentation data wich will be passed to the instrumenter's payload with `:instrument` key;
- returns:
  - `[Hash<Symbol,Numeric>]` - Format: `{ ok: true, result: Hash<Symbol,Numeric> }`;
  - result data:
    - `:rel_time` - `Numeric` - time spent to release all locks and related queus;
    - `:rel_key_cnt` - `Integer` - the number of released Redis keys (queues+locks);

```ruby
rql.clear_locks

# =>
{
  ok: true,
  result: {
    rel_time: 3.07,
    rel_key_cnt: 1234
  }
}
```

---

#### #extend_lock_ttl

<sup>\[[back to top](#usage)\]</sup>

- extends lock ttl by the required number of milliseconds;
- expects the lock name and the number of milliseconds;
- accepts:
  - `lock_name` - (required) `[String]`
    - the lock name which ttl should be extended;
  - `milliseconds` - (required) `[Integer]`
    - how many milliseconds should be added to the lock's TTL;
  - `:logger` - (optional) `[::Logger,#debug]`
    - custom logger object;
    - pre-configured in `config[:logger]`;
- returns `{ ok: true, result: :ttl_extended }` when ttl is extended;
- returns `{ ok: false, result: :async_expire_or_no_lock }` when a lock not found or a lock is already expired during
  some steps of invocation (see **Important** section below);
- **Important**:
  - the method is non-atomic cuz redis does not provide an atomic function for TTL/PTTL extension;
  - the method consists of two commands:
    - (1) read current pttl;
    - (2) set new ttl that is calculated as "current pttl + additional milliseconds";
  - the method uses Redis'es **CAS** (check-and-set) behavior;
  - what can happen during these steps:
    - lock is expired between commands or before the first command;
    - lock is expired before the second command;
    - lock is expired AND newly acquired by another process (so you will extend the
      totally new lock with fresh PTTL);
  - use it at your own risk and consider the async nature when calling this method;

```ruby
rql.extend_lock_ttl("my_lock", 5_000) # NOTE: add 5_000 milliseconds

# => `ok` case
{ ok: true, result: :ttl_extended }

# => `failed` case
{ ok: false, result: :async_expire_or_no_lock }
```

---

#### #locks - get list of obtained locks

<sup>\[[back to top](#usage)\]</sup>

- get list of obtained locks;
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

<sup>\[[back to top](#usage)\]</sup>

- get list of lock request queues;
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

<sup>\[[back to top](#usage)\]</sup>

- get list of taken locks and queues;
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

<sup>\[[back to top](#usage)\]</sup>

- get list of locks with their info;
- uses redis `SCAN` under the hod;
- accepts `scan_size:`/`Integer` option (`config[:key_extraction_batch_size]` by default);
- returns `Set<Hash<Symbol,Any>>` (see [#lock_info](#lock_info) and examples below for details).
  - contained data: `{ lock: String, status: Symbol, info: Hash<String,Any> }`;
  - `:lock` - `String` - lock key in Redis;
  - `:status` - `Symbol`- `:released` or `:alive`
    - the lock may become relased durign the lock info extraction process;
    - `:info` for `:released` keys is empty (`{}`);
  - `:info` - `Hash<String,Any>`
      - lock data stored in the lock key in Redis;
      - See [#lock_info](#lock_info) for details;

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

<sup>\[[back to top](#usage)\]</sup>

- get list of queues with their info;
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

#### #clear_dead_requests

<sup>\[[back to top](#usage)\]</sup>

In some cases your lock requests may become "dead". It means that your lock request lives in lock queue in Redis without
any processing. It can happen when your processs that are enqueeud to the lock queue is failed unexpectedly (for some reason)
before the lock acquire moment occurs and when no any other process does not need this lock anymore.
For this case your lock reuquest will be cleared only when any process will try
to acquire this lock again (cuz lock acquirement triggers the removement of expired requests).

In order to help with these dead requests you may periodically call `#clear_dead_requests`
with corresponding `:dead_ttl` option, that is pre-configured by default via `config[:dead_request_ttl]`.

`:dead_ttl` option is required because of it is no any **fast** and **resource-free** way to understand which request
is dead now and is it really dead cuz each request queue can host their requests with
a custom queue ttl for each request differently.

Accepts:
- `:dead_ttl` - (optional) `[Integer]`
  - lock request ttl after which a lock request is considered dead;
  - has a preconfigured value in `config[:dead_request_ttl]` (1 day by default);
- `:sacn_size` - (optional) `[Integer]`
  - the batch of scanned keys for Redis'es SCAN command;
  - has a preconfigured valie in `config[:lock_release_batch_size]`;
- `:logger` - (optional) `[::Logger,#debug]`
  - custom logger object;
  - pre-configured in `config[:logger]`;
- `:instrumenter` - (optional) `[#notify]`
  - custom instrumenter object;
  - pre-configured in `config[:isntrumenter]`;
- `:instrument` - (optional) `[NilClass,Any]`
  - custom instrumentation data wich will be passed to the instrumenter's payload with :instrument key;
  - `nil` by default (no additional data);

Returns: `{ ok: true, processed_queues: Set<String> }` returns the list of processed lock queues;

```ruby
rql.clear_dead_requests(dead_ttl: 60 * 60 * 1000) # 1 hour in milliseconds

# =>
{
  ok: true,
  processed_queues: [
    "rql:lock_queue:some-lock-123",
    "rql:lock_queue:some-lock-456",
    "rql:lock_queue:your-other-lock",
    ...
  ]
}
```

---

## Dead locks and Reentrant locks

<sup>\[[back to top](#table-of-contents)\]</sup>

- **detailed documentation is in progress at the momend** ;
- (little details for a context of the current implementation and feautres):
  - at this moment we support only **reentrant locks**: they works via customizable conflict strategy behavior
    (`:wait_for_lock` (default), `:conflict_work_through`, `:extendable_conflict_work_through`, `:dead_locking`);
  - by default behavior (`:wait_for_lock`) your lock obtaining process will work in a classic way (limits, retries, etc);
  - for current implementation details check:
    - [Configuration](#configuration) documentation: see `config.default_conflict_strategy` config docs;
    - [#lock](#lock---obtain-a-lock) method documentation: see `conflict_strategy` attribute docs;

---

## Logging

<sup>\[[back to top](#table-of-contents)\]</sup>

- default logs (raised from `#lock`/`#lock!`):

```ruby
"[redis_queued_locks.start_lock_obtaining]" # (logs "lock_key", "queue_ttl", "acq_id");
"[redis_queued_locks.start_try_to_lock_cycle]" # (logs "lock_key", "queue_ttl", "acq_id");
"[redis_queued_locks.dead_score_reached__reset_acquier_position]" # (logs "lock_key", "queue_ttl", "acq_id");
"[redis_queued_locks.lock_obtained]" # (logs "lock_key", "queue_ttl", "acq_id", "acq_time");
"[redis_queued_locks.extendable_reentrant_lock_obtained]" # (logs "lock_key", "queue_ttl", "acq_id", "acq_time");
"[redis_queued_locks.reentrant_lock_obtained]" # (logs "lock_key", "queue_ttl", "acq_id", "acq_time");
"[redis_queued_locks.fail_fast_or_limits_reached_or_deadlock__dequeue]" # (logs "lock_key", "queue_ttl", "acq_id");
"[redis_queued_locks.expire_lock]" # (logs "lock_key", "queue_ttl", "acq_id");
"[redis_queued_locks.decrease_lock]" # (logs "lock_key", "decreased_ttl", "queue_ttl", "acq_id");
```

- additional logs (raised from `#lock`/`#lock!` with `confg[:log_lock_try] == true`):

```ruby
"[redis_queued_locks.try_lock.start]" # (logs "lock_key", "queue_ttl", "acq_id");
"[redis_queued_locks.try_lock.rconn_fetched]" # (logs "lock_key", "queue_ttl", "acq_id");
"[redis_queued_locks.try_lock.same_process_conflict_detected]" # (logs "lock_key", "queue_ttl", "acq_id");
"[redis_queued_locks.try_lock.same_process_conflict_analyzed]" # (logs "lock_key", "queue_ttl", "acq_id", "spc_status");
"[redis_queued_locks.try_lock.reentrant_lock__extend_and_work_through]" # (logs "lock_key", "queue_ttl", "acq_id", "spc_status", "last_ext_ttl", "last_ext_ts");
"[redis_queued_locks.try_lock.reentrant_lock__work_through]" # (logs "lock_key", "queue_ttl", "acq_id", "spc_status", last_spc_ts);
"[redis_queued_locks.try_lock.single_process_lock_conflict__dead_lock]" # (logs "lock_key", "queue_ttl", "acq_id", "spc_status", "last_spc_ts");
"[redis_queued_locks.try_lock.acq_added_to_queue]" # (logs "lock_key", "queue_ttl", "acq_id)";
"[redis_queued_locks.try_lock.remove_expired_acqs]" # (logs "lock_key", "queue_ttl", "acq_id");
"[redis_queued_locks.try_lock.get_first_from_queue]" # (logs "lock_key", "queue_ttl", "acq_id", "first_acq_id_in_queue");
"[redis_queued_locks.try_lock.exit__queue_ttl_reached]" # (logs "lock_key", "queue_ttl", "acq_id");
"[redis_queued_locks.try_lock.exit__no_first]" # (logs "lock_key", "queue_ttl", "acq_id", "first_acq_id_in_queue", "<current_lock_data>");
"[redis_queued_locks.try_lock.exit__lock_still_obtained]" # (logs "lock_key", "queue_ttl", "acq_id", "first_acq_id_in_queue", "locked_by_acq_id", "<current_lock_data>");
"[redis_queued_locks.try_lock.obtain__free_to_acquire]" # (logs "lock_key", "queue_ttl", "acq_id");
```

---

## Instrumentation

<sup>\[[back to top](#table-of-contents)\]</sup>

- [Instrumentation Events](#instrumentation-events)

An instrumentation layer is incapsulated in `instrumenter` object stored in [config](#configuration) (`RedisQueuedLocks::Client#config[:instrumenter]`).

Instrumenter object should provide `notify(event, payload)` method with the following signarue:

- `event` - `string`;
- `payload` - `hash<Symbol,Any>`;

`redis_queued_locks` provides two instrumenters:

- `RedisQueuedLocks::Instrument::ActiveSupport` - **ActiveSupport::Notifications** instrumenter
  that instrument events via **ActiveSupport::Notifications** API;
- `RedisQueuedLocks::Instrument::VoidNotifier` - instrumenter that does nothing;

By default `RedisQueuedLocks::Client` is configured with the void notifier (which means "instrumentation is disabled").

---

### Instrumentation Events

<sup>\[[back to top](#instrumentation)\]</sup>

List of instrumentation events

- `redis_queued_locks.lock_obtained`;
- `redis_queued_locks.extendable_reentrant_lock_obtained`;
- `redis_queued_locks.reentrant_lock_obtained`;
- `redis_queued_locks.lock_hold_and_release`;
- `redis_queued_locks.reentrant_lock_hold_completes`;
- `redis_queued_locks.explicit_lock_release`;
- `redis_queued_locks.explicit_all_locks_release`;

Detalized event semantics and payload structure:

- `"redis_queued_locks.lock_obtained"`
  - a moment when the lock was obtained;
  - raised from `#lock`/`#lock!`;
  - payload:
    - `:ttl` - `integer`/`milliseconds` - lock ttl;
    - `:acq_id` - `string` - lock acquier identifier;
    - `:lock_key` - `string` - lock name;
    - `:ts` - `numeric`/`epoch` - the time when the lock was obtaiend;
    - `:acq_time` - `float`/`milliseconds` - time spent on lock acquiring;
    - `:instrument` - `nil`/`Any` - custom data passed to the `#lock`/`#lock!` method as `:instrument` attribute;

- `"redis_queued_locks.extendable_reentrant_lock_obtained"`
  - an event signalizes about the "extendable reentrant lock" obtaining is happened;
  - raised from `#lock`/`#lock!` when the lock was obtained as reentrant lock;
  - payload:
    - `:lock_key` - `string` - lock name;
    - `:ttl` - `integer`/`milliseconds` - last lock ttl by reentrant locking;
    - `:acq_id` - `string` - lock acquier identifier;
    - `:ts` - `numeric`/`epoch` - the time when the lock was obtaiend as extendable reentrant lock;
    - `:acq_time` - `float`/`milliseconds` - time spent on lock acquiring;
    - `:instrument` - `nil`/`Any` - custom data passed to the `#lock`/`#lock!` method as `:instrument` attribute;

- `"redis_queued_locks.reentrant_lock_obtained"`
  - an event signalizes about the "reentrant lock" obtaining is happened (without TTL extension);
  - raised from `#lock`/`#lock!` when the lock was obtained as reentrant lock;
  - payload:
    - `:lock_key` - `string` - lock name;
    - `:ttl` - `integer`/`milliseconds` - last lock ttl by reentrant locking;
    - `:acq_id` - `string` - lock acquier identifier;
    - `:ts` - `numeric`/`epoch` - the time when the lock was obtaiend as reentrant lock;
    - `:acq_time` - `float`/`milliseconds` - time spent on lock acquiring;
    - `:instrument` - `nil`/`Any` - custom data passed to the `#lock`/`#lock!` method as `:instrument` attribute;

- `"redis_queued_locks.lock_hold_and_release"`
  - an event signalizes about the "hold+and+release" process is finished;
  - raised from `#lock`/`#lock!` when invoked with a block of code;
  - payload:
    - `:hold_time` - `float`/`milliseconds` - lock hold time;
    - `:ttl` - `integer`/`milliseconds` - lock ttl;
    - `:acq_id` - `string` - lock acquier identifier;
    - `:lock_key` - `string` - lock name;
    - `:ts` - `numeric`/`epoch` - the time when lock was obtained;
    - `:acq_time` - `float`/`milliseconds` - time spent on lock acquiring;
    - `:instrument` - `nil`/`Any` - custom data passed to the `#lock`/`#lock!` method as `:instrument` attribute;

- `"redis_queued_locks.reentrant_lock_hold_completes"`
  - an event signalizes about the "reentrant lock hold" is complete (both extendable and non-extendable);
  - lock re-entering can happen many times and this event happens for each of them separately;
  - raised from `#lock`/`#lock!` when the lock was obtained as reentrant lock;
  - payload:
    - `:hold_time` - `float`/`milliseconds` - lock hold time;
    - `:ttl` - `integer`/`milliseconds` - last lock ttl by reentrant locking;
    - `:acq_id` - `string` - lock acquier identifier;
    - `:ts` - `numeric`/`epoch` - the time when the lock was obtaiend as reentrant lock;
    - `:lock_key` - `string` - lock name;
    - `:acq_time` - `float`/`milliseconds` - time spent on lock acquiring;
    - `:instrument` - `nil`/`Any` - custom data passed to the `#lock`/`#lock!` method as `:instrument` attribute;

- `"redis_queued_locks.explicit_lock_release"`
  - an event signalizes about the explicit lock release (invoked via `RedisQueuedLock#unlock`);
  - raised from `#unlock`;
  - payload:
    - `:at` - `float`/`epoch` - the time when the lock was released;
    - `:rel_time` - `float`/`milliseconds` - time spent on lock releasing;
    - `:lock_key` - `string` - released lock (lock name);
    - `:lock_key_queue` - `string` - released lock queue (lock queue name);

- `"redis_queued_locks.explicit_all_locks_release"`
  - an event signalizes about the explicit all locks release (invoked via `RedisQueuedLock#clear_locks`);
  - raised from `#clear_locks`;
  - payload:
    - `:rel_time` - `float`/`milliseconds` - time spent on "realese all locks" operation;
    - `:at` - `float`/`epoch` - the time when the operation has ended;
    - `:rel_keys` - `integer` - released redis keys count (`released queue keys` + `released lock keys`);

---

## Roadmap

<sup>\[[back to top](#table-of-contents)\]</sup>

- **Major**:
  - support for Random Access strategy (non-queued behavior);
  - lock request prioritization;
  - **strict redlock algorithm support** (support for many `RedisClient` instances);
  - `#lock_series` - acquire a series of locks:
    ```ruby
    rql.lock_series('lock_a', 'lock_b', 'lock_c') { puts 'locked' }
    ```
  - support for `Dragonfly` database backend (https://github.com/dragonflydb/dragonfly) (https://www.dragonflydb.io/);
- **Minor**:
  - Semantic error objects for unexpected Redis errors;
  - change all `::Process.clock_gettime(::Process::CLOCK_MONOTONIC)` milliseconds-related invocations to
    `::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :millisecond)` in order to reduce time-related math operations count;
  - **Experimental feature**: (non-`timed` locks): per-ruby-block-holding-the-lock sidecar `Ractor` and `in progress queue` in RedisDB that will extend
    the acquired lock for long-running blocks of code (that invoked "under" the lock
    whose ttl may expire before the block execution completes). It makes sense for non-`timed` locks *only*;
  - better code stylization (+ some refactorings);
  - `RedisQueuedLocks::Acquier::Try.try_to_lock` - detailed successful result analization;
  - Support for LIFO strategy;
  - better specs with 100% test coverage (total specs rework);
  - statistics with UI;
  - JSON log formatter;
  - `go`-lang implementation;

---

## Contributing

<sup>\[[back to top](#table-of-contents)\]</sup>

- Fork it ( https://github.com/0exp/redis_queued_locks )
- Create your feature branch (`git checkout -b feature/my-new-feature`)
- Commit your changes (`git commit -am '[feature_context] Add some feature'`)
- Push to the branch (`git push origin feature/my-new-feature`)
- Create new Pull Request

## License

<sup>\[[back to top](#table-of-contents)\]</sup>

Released under MIT License.

## Authors

<sup>\[[back to top](#table-of-contents)\]</sup>

[Rustam Ibragimov](https://github.com/0exp)
