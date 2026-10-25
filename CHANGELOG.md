## [Unreleased]
### Added
- *Brand New Feature*: **Lock Request Prioritization**: the `priority:` option of `#lock`/`#lock!`/`#lock_series`/`#lock_series!` (an Integer from `-100`,
  the lowest, to `100`, the highest, `0` by default; pre-configured in the new `config['default_lock_priority']`): with the
  `:queued` access strategy a lock request is placed in the lock request queue after all requests of the same or higher
  priority and before all requests of the lower priority (strict priority, FIFO inside the same priority; read and write lock
  requests too); the priority orders the waiting lock requests only (the obtained lock is never taken away), `:random`
  ignores it:
  - the position of the lock request (the queue score) is the request time shifted by `-priority * 2**32` seconds: the default
    priority keeps the request time (the queue data of the default priority is the same as before);
  - every lock request drops dead lock requests of its own priority in both lock queues (in the same queueing pipeline: no new
    commands and round trips); dead lock requests of other priorities that block the lock request (the head of the lock queue
    and the earlier lock request of the other read/write mode, decoded from their positions) are dropped with the dead lock
    requests of their priorities in one more round trip of the same attempt (up to 5 such round trips per attempt); the cost of
    an attempt does not depend on the number of priorities;
  - `#clear_dead_requests` drops the dead lock requests of every priority found in the lock queues (two round trips per batch of
    lock queues: the lock requests are read, then the dead ones are dropped);
  - lock requests at infinite positions (`-inf`/`+inf`: manual writes of the lock queues) have the bound priorities (`100`/`-100`);
    a request at `-inf` is dropped as a dead one when it blocks a lock request and by `#clear_dead_requests`, a request at `+inf`
    is never dropped as a dead one (like before priorities);
  - the new `log_lock_try` log event `[redis_queued_locks.try_lock.dead_request_removed]` (`dead_acq_id`, `dead_priority`);
  - priority names: `priority:` and `config['default_lock_priority']` accept a priority name (Symbol) of the new
    `config['lock_priorities']` (a priority name => its Integer priority; default names: `:lowest` (`-100`), `:low` (`-50`),
    `:normal` (`0`), `:high` (`50`), `:highest` (`100`); applications define their own names); a name is resolved to its
    Integer priority on each lock acquirement (queues, `#queue_info`, logs and instrumentation have the Integer priority),
    an unknown name fails with `RedisQueuedLocks::ArgumentError`;
  - all processes that share locks should be upgraded before the priorities are used: older versions drop the lock requests
    of the high priority as dead ones (the order is broken, the mutual exclusion is not affected);
### Changed
- `#queue_info`/`#queues_info`: each lock request has the `"priority"` field (`Integer`, decoded from its position);
- logs and instrumentation payloads of the lock acquirement have the lock request `priority` (an Integer: a priority name is
  reported as its priority): the events `lock_obtained`, `lock_obtaining_failed`, `lock_hold_and_release`,
  `reentrant_lock_obtained`, `extendable_reentrant_lock_obtained`, `reentrant_lock_hold_completes`, `lock_series_obtained`,
  `lock_series_hold_and_release` and the logs `start_lock_obtaining`, `start_try_to_lock_cycle`,
  `dead_score_reached__reset_acquirer_position`, `lock_obtained`, `lock_obtaining_failed`, `reentrant_lock_obtained`,
  `extendable_reentrant_lock_obtained`, `start_lock_series_obtaining`, `lock_series_obtained`, `expire_lock_series`,
  `try_lock.acq_added_to_queue`; the `log_lock_try` logs that name another lock request have its priority too:
  `first_priority_in_queue` (`try_lock.get_first_from_queue`, `try_lock.exit__no_first`, `try_lock.exit__lock_still_obtained`,
  `try_lock.exit__read_lock_still_obtained`) and `ahead_priority` (`try_lock.exit__write_request_ahead`,
  `try_lock.exit__read_request_ahead`);
- `#lock_series`/`#lock_series!`: the `priority:` is validated (and a priority name is resolved) before the series is
  acquired;
- RBS: `RedisQueuedLocks::Config#[]` is typed per config key (one overload per key with its value type) instead of
  `(String) -> untyped`: Steep users get precise types of `config['...']` reads and type errors on unknown keys;
  lookups with a dynamic `String` key no longer type-check (the runtime behavior is unchanged).
- RBS: the option literal unions `RedisQueuedLocks::readWriteMode` (`:read | :write`), `RedisQueuedLocks::accessStrategy`
  (`:queued | :random`) and `RedisQueuedLocks::conflictStrategy` (`:wait_for_lock | :work_through |
  :extendable_work_through | :dead_locking`) replace `Symbol` for `read_write_mode`, `access_strategy` and
  `conflict_strategy` in the `Client` signatures (and the config defaults): Steep rejects an invalid strategy/mode value.
### Fixed
- a lock request that waits longer than its `queue_ttl` (its position is reset: requeued at the end of its priority) could be
  missing in the lock queue for one attempt: the queueing kept its old dead position (`ZADD NX`) and dropped it as a dead
  request right after, so the attempt could fail (`:dead_score_reached`, `:acquirer_is_not_first_in_queue`) and spend
  a retry; the queueing drops the dead lock requests before the lock request is queued now (the same commands in the same
  round trip);

## [1.21.0] - 2026-10-13
### Added
- Logging and instrumentation of all operations that change Redis keys (the swarm is not covered yet):
  - the lock acquirement: the new `redis_queued_locks.lock_obtaining_failed` instrumentation event and log
    (`#lock`/`#lock!` and each lock of `#lock_series`/`#lock_series!`: the lock is not obtained, the failure `result`
    (`:timeout_reached`, `:retry_limit_reached`, `:fail_fast_no_try`, `:fail_fast_after_try`, `:conflict_dead_lock`,
    `:conflict_lock_upgrade`) is in the payload; with `raise_errors: true` it is reported before the error is raised);
  - each lock mutation operation is reported with one log line and one instrumentation event with the time of the whole
    operation (the same name and data; the payload ends with `instrument`): the new `redis_queued_locks.extend_lock_ttl`
    (`#extend_lock_ttl`), `redis_queued_locks.clear_dead_requests` (`#clear_dead_requests`), `redis_queued_locks.reindex_locks`
    (`#reindex_locks`) events, and the new log lines of the existing `explicit_lock_release` (`#unlock`),
    `explicit_read_lock_release` (`#unlock_read`), `explicit_all_locks_release` (`#clear_locks`), `release_locks_of`
    (`#clear_locks_of`/`#clear_current_locks`) events (the `logger:` option of these methods was not used);
  - `#reindex_locks`: `logger:`, `instrumenter:`, `instrument:` and the log/instrumentation sampling options;
### Changed
- stricter validation (the details are in "Fixed"): invalid values raise `RedisQueuedLocks::ArgumentError`
  (`RedisQueuedLocks::SwarmArgumentError` for the swarm methods, `RedisQueuedLocks::ConfigValidationError` for the config)
  instead of the previous silent misbehavior:
  - `ttl` of `#lock`/`#lock!`/`#lock_series`/`#lock_series!` should be a positive `Integer` in both modes (`ttl: 0` was
    accepted in the write mode);
  - `#extend_lock_ttl`: `milliseconds` should be a positive `Integer` (`extend_lock_ttl(name, 0)` was a successful no-op);
  - the per-call numeric options should be `Integer`s in the ranges of their config keys: `Float` values (e.g.
    `timeout: 0.5`, `retry_delay: 10.0`) are rejected now;
  - the config: positive TTLs, periods and batch/scan sizes;
  - `:meta`: reserved lock data keys are rejected as Symbol keys too;
- the internal timeout errors of `timed: true` and `timeout` inherit from `RedisQueuedLocks::Exception < ::Exception`
  (were `Timeout::Error`s): a `rescue Timeout::Error` (or `rescue => e`) inside the block does not catch the lock timeout
  anymore; the public errors/results are the same;
- `#locks_info`: the info of write locks has the `"lock_key"` field (like `#lock_info`);
- instrumentation payloads: `explicit_lock_release`, `explicit_all_locks_release` and `release_locks_of` have `instrument`;
### Fixed
- the `instrument:` option of `#unlock`, `#clear_locks`, `#clear_locks_of`/`#clear_current_locks` (README: "passed to
  the instrumenter's payload") was not passed to the payload (`#unlock` did not even forward it); the payloads of
  `explicit_lock_release`, `explicit_all_locks_release` and `release_locks_of` have `instrument` now; `#extend_lock_ttl` and
  `#clear_dead_requests` had no instrumentation events at all (see "Added");
- `#lock`/`#lock!` with a non-positive `ttl` in the write mode: the lock was reported as obtained, but `PEXPIRE` with
  a non-positive ttl deleted the lock key in the obtaining transaction, so other acquirers could obtain the same lock
  at the same time (no mutual exclusion); `ttl` should be a positive `Integer` in both modes now
  (`RedisQueuedLocks::ArgumentError`, previously validated for read locks only); `ttl: nil` was never supported
  (the YARD docs described it as "without timeout");
- `#lock_series`/`#lock_series!` (PoC) with a non-positive `ttl` (both modes): the locks of the series were obtained with
  the ttl made of the retry delay and jitter only; the series `ttl` should be a positive `Integer` now
  (`RedisQueuedLocks::ArgumentError`);
- `config['default_lock_ttl']` should be a positive `Integer` (`RedisQueuedLocks::ConfigValidationError`);
- the config validation accepted zero and negative TTLs, periods and batch/scan sizes: `config['default_queue_ttl'] = 0`
  dropped the own lock request in the queueing pipeline (endless `:dead_score_reached`), zero batch/scan sizes failed
  `SCAN`/`ZSCAN` (`COUNT 0`: `ERR syntax error`) and `each_slice(0)`, zero/negative swarm periods killed the swarm main loops
  and the supervisor (`sleep` with a negative value) or made them busy loops, a non-positive `zombie_ttl` made all hosts
  zombies; these keys should be positive `Integer`s now (`RedisQueuedLocks::ConfigValidationError`): `default_queue_ttl`,
  `lock_release_batch_size`, `clear_locks_of__lock_scan_size`, `clear_locks_of__queue_scan_size`, `key_extraction_batch_size`,
  `swarm.supervisor.liveness_probing_period`, `swarm.probe_hosts.probe_period`, `swarm.flush_zombies.zombie_ttl`,
  `swarm.flush_zombies.zombie_flush_period`, `swarm.flush_zombies.zombie_lock_scan_size`,
  `swarm.flush_zombies.zombie_queue_scan_size`;
- `#extend_lock_ttl` with a non-positive `milliseconds` decreased the lock TTL (or deleted the lock) and reported a successful
  extension: `milliseconds` should be a positive `Integer` now (`RedisQueuedLocks::ArgumentError`);
- `#lock`/`#lock!`/`#lock_series`/`#lock_series!` (both modes): reserved lock data keys were rejected in `:meta` only as
  String keys, while Symbol keys (`meta: { acq_id: '...' }`) passed the validation and overwrote the lock data fields
  (`acq_id`, `hst_id`, `ts`, `ini_ttl`, `spc_*`, ...: reentrant locks, owner checks of lock releases and lock info were
  broken while the lock lived); Symbol keys are validated too now (`RedisQueuedLocks::ArgumentError`);
- `timed: true` and `timeout`: the internal timeout errors inherited from `Timeout::Error` (a `StandardError`), so `rescue => e`,
  `rescue StandardError`, `rescue Timeout::Error` and `rescue nil` of the interrupted code swallowed them: a `timed` block with
  such a `rescue` continued after the lock TTL (another acquirer could obtain the expired lock, and the write lock release
  after the block deleted the lock of that acquirer), and the acquirement timeout that interrupted a logger/instrumenter
  call (`rescue nil` of the log/instrumentation events) was lost (with `retry_count: nil` the acquirement waited without
  the timeout); the internal timeouts inherit from the new private base `RedisQueuedLocks::Exception < ::Exception` now
  (like `Timeout::ExitException`): only `rescue Exception` catches them, `ensure` still runs, the public errors/results
  are the same (`RedisQueuedLocks::TimedLockTimeoutError`, `RedisQueuedLocks::LockAcquirementTimeoutError`,
  `:timeout_reached`); a connection interrupted inside a `WATCH` block is closed (redis-client sends `UNWATCH` only on
  `StandardError`s: the next transaction on the connection would be aborted);
- `#lock_series`/`#lock_series!` (PoC): the log events and the `redis_queued_locks.lock_series_hold_and_release`
  instrumentation event raised the errors of the logger/instrumenter: a failing logger broke the series call (after
  obtaining all the locks of the series the locks were not released till their ttl), a failing instrumenter replaced
  the block result with its error; the logger/instrumenter errors are swallowed now (like in all other events);
- `#locks_info` (and `#locks(with_info: true)`): the info of write locks had no `"lock_key"` field (the info of read locks and
  `#lock_info` have it), so the info shape depended on the lock mode; the write lock info has `"lock_key"` now (the same
  fields as `#lock_info`);
- `RedisQueuedLocks::Logging::Sampler` and `RedisQueuedLocks::Instrument::Sampler` (the default log/instrumentation samplers)
  sampled `sampling_percent` of 101 values (`SecureRandom.rand(0..100)`): `0%` sampled ~1% of the cases (instead of none),
  `15%` sampled ~15.8%; they sample exactly `sampling_percent` of 100 values now (`0%` - never, `100%` - always);
  the private `SAMPLING_PERCENT_RANGE` constants are removed;
- swarm: the Redis client builder of the swarm elements mutated the `swarm.*.redis_config.config`/`pool_config` hashes of
  the client config (`transform_keys!`): with frozen hashes each start of the host probing and zombie flushing main loops
  failed with `FrozenError` (the hosts were not probed, zombie locks were not flushed); the hashes are not mutated now;
- RBS: the `RedisQueuedLocks::Client#current_acq_id` alias was declared as `ccurrent_acq_id` (a typo: the public method was
  missing in the signatures); `RedisQueuedLocks::Client#queues_info` returned the `queues` union (`queueList | queuesInfo`)
  instead of `queuesInfo`;
- `RedisQueuedLocks::Resource.lock_key_from_queue` (a private debug helper for manual checks in a console, not used by
  the library) returned a wrong key for the read lock request queues (`rql:lock:ueue:<name>`); it supports the write and
  read lock request queues now and returns `nil` for other keys;
- a connection interrupted inside a `WATCH` block by a `Timeout.timeout` of your code without an exception class
  (`Timeout::ExitException`, e.g. `Timeout.timeout(5) { rql.lock("x") { ... } }`) returned to the connection pool with
  the active `WATCH` (redis-client sends `UNWATCH` only on `StandardError`s): the next transaction on the connection could
  be aborted (e.g. a lock release); the connection is closed now (like with the internal timeouts);
- the per-call numeric options were not validated (zero/negative values broke the operations like the same config values
  before the config validation fix): they are validated with the same ranges as their config keys now
  (`RedisQueuedLocks::ArgumentError`; `RedisQueuedLocks::SwarmArgumentError` for the swarm methods), before any Redis
  command; the values should be `Integer`s (like the config values: `Float` values such as `timeout: 0.5` or
  `retry_delay: 10.0` are rejected now):
  - `#lock`/`#lock!`/`#lock_series`/`#lock_series!`: `queue_ttl` > 0, `timeout` and `retry_count` - `nil` or >= 0,
    `retry_delay`, `retry_jitter` and `lock_index_grace_period` >= 0;
  - `#locks`, `#locks_info`, `#queues`, `#queues_info`, `#keys`, `#clear_dead_requests`, `#reindex_locks`: `scan_size` > 0;
    `#clear_locks`: `batch_size` > 0; `#clear_locks_of`/`#clear_current_locks`: `lock_scan_size`, `queue_scan_size` > 0;
    `#clear_dead_requests`: `dead_ttl` > 0; `#reindex_locks`: `queue_ttl` > 0, `lock_index_grace_period` >= 0;
  - `#swarm_info`, `#flush_zombies`, `#zombie_locks`, `#zombie_acquirers`, `#zombie_hosts`, `#zombies_info`: `zombie_ttl`
    and the scan sizes > 0;
- README/YARD documentation that did not match the code:
  - config keys: `config['instr_sampling_enabled']` in the configuration example (was `nstr_sampling_enabled`),
    `config['log_sampling_enabled']` (was `log_samplign_enabled`), `*_sampling_enabled` (was `*_sampling_enalbed`);
  - `#lock` results: `:retry_limit_reached` (was `:retry_count_reached`), `:conflict_lock_upgrade` is listed, `:unknown`
    is not returned, `:dead_locking` is not a `:process` value (it fails with `:conflict_dead_lock`), the result has `hst_id`;
  - `#lock_info`: `"ini_ttl"` (was `"init_ttl"`), `"spc_cnt"` (was `"spc_count"`), host ids `rql:hst:...` in the examples;
  - `#unlock`: `rel_time` is in milliseconds (was "in seconds");
  - `#clear_dead_requests` returns `{ ok: true, result: { processed_queues: Set<String> } }` (write and read request queues);
  - `#extend_lock_ttl`: the write lock TTL is extended atomically by one Lua script, without the lock owner check
    (was "non-atomic, two commands");
  - the log lists of the `### Configuration` section: `rw_mode`, the key order, the read/write and lock series logs
    (the same as in the `## Logging` section);
  - the `#lock!` link of the Usage list and the `#lock` link of `#lock_info`, the Usage list and the table of contents: `unlock_read`, `clear_locks_of`,
    `clear_current_locks`, `reindex_locks`;
  - YARD: the `#clear_current_locks` options (`lock_scan_size`, `queue_scan_size` instead of the missing `batch_size`), the tag
    typos (`@sine`, `@since ?.?.?`, `@since 19.0.0`, `@api ppublic`/`pulic`/`pub;ic`); the inert `# steep:ingore` comments
    are removed;
  - YARD: the `@version` tags of the classes/modules (versions >= 1.17.0) follow the interface changes only (method
    signatures, added/removed methods, `extend`/`include`/`prepend`, the superclass), not the behavior changes inside
    the methods;

## [1.20.0] - 2026-10-12
### Added
- **Lock index** (opt-in: `config['lock_index_enabled']`, `false` by default: lock-iterating operations scan the keyspace as before):
  `rql:index:locks` (`ZSET`: lock name => the upper bound of the lifetime of all lock keys in client time, ms); with the enabled
  lock index all lock-iterating operations find locks without the full keyspace `SCAN` (see the "Lock Index" README section):
  - the client-wide mode (not a per-call option): the lock acquirement maintains the lock index and lock-iterating operations
    read it only when it is enabled; use the same mode on all processes that share the Redis database (enable it everywhere,
    then invoke `#reindex_locks` once); the swarm reads the mode when it is started;
  - maintained by the lock acquirement itself without new Redis round trips: each lock request adds the lock name (`ZADD GT`
    with the queue ttl), sets the request queue TTL and drops the expired lock names (`ZREMRANGEBYSCORE`) in the queueing pipeline
    (4 more commands per attempt), each lock obtaining (write and read) adds the lock name with the lock ttl in the same
    transaction (1 more command), each extension (`#extend_lock_ttl`, `:extendable_work_through` reentrant locks) increases
    the score by the extension (`ZADD XX INCR`; `#extend_lock_ttl` of write locks sends `EVAL` and the index update in one
    transaction);
  - `#unlock` and `#clear_locks` drop the lock names from the index in the same transaction with the lock keys;
  - lock request queues have TTL: the queue lives as long as its latest lock request (`PEXPIRE NX` + `GT` with the queue ttl on
    each lock request), queues of dead acquirers expire by themselves;
  - lock-iterating operations find locks and lock queues via one `ZSCAN` pass over the lock names (lock keys are derived from
    the lock names): the cost depends on the number of locks only, keys of other applications are never visited; locks without
    the lock index entry (older RQL versions, the disabled lock index) are not found until `#reindex_locks`:
    - swarm (`#flush_zombies`, the zombie flusher, `#zombie_locks`/`#zombie_acquirers`/`#zombies_info`): `zombie_lock_scan_size` is
      the `ZSCAN` count and the batch size of locks, `zombie_queue_scan_size` - the batch size of lock queues (both processed during
      the same pass); `#flush_zombies` drops the expired lock names from the index;
    - `#locks`/`#locks_info`, `#queues`/`#queues_info`, `#keys`: `scan_size` is the `ZSCAN` count and the batch size of locks;
      `#keys` returns the existing keys of the lock key families of the indexed locks (other `rql:lock*` keys are not listed);
    - `#clear_locks`: the keys of each batch of locks are deleted with one `DEL` in one transaction with the removal of their lock
      names from the lock index; `batch_size` is the number of locks;
    - `#clear_locks_of`/`#clear_current_locks`: `clear_locks_of__lock_scan_size` is the `ZSCAN` count and the batch size of locks,
      `clear_locks_of__queue_scan_size` - the number of lock queues processed in one round trip;
    - `#clear_dead_requests`: `scan_size` is the `ZSCAN` count and the number of locks (both lock queues of each lock) processed in
      one round trip; the expired lock names are dropped from the index;
  - `config['lock_index_grace_period']` (`60_000` ms by default) and `lock_index_grace_period:` option of `#lock`/`#lock!`/
    `#lock_series`/`#lock_series!`: the lock name stays in the index for this period after the expiration of all its keys
    (the client clock skew and network latency tolerance);
- `#reindex_locks`: adds the lock keys without the lock index entry (keys of older RQL versions and keys created with the disabled
  lock index) to the lock index (one `SCAN` pass, lock queues without TTL get the queue ttl); **invoke it once after the lock index
  is enabled on all your processes**;
### Changed
- `#flush_zombies` (and the zombie flusher of the swarm): zombie lock requests are dropped with one `ZREM` per lock queue
  (previously one `ZREM` per zombie acquirer and lock queue);
- `#queue_info` / `#queues_info`: lock queues are read without `EXISTS` checks (Redis does not keep empty sorted sets);
- Lock acquirement attempt: read lock requests do not fetch the longest read lock (it is used by write lock requests only),
  write lock requests do not build the read lock data key, disabled try-lock logs get a shared frozen hash instead of a new one;
- Lock acquirement attempt: the lock request queueing (`ZADD NX`, expired requests pruning, queue heads) is one pipelined
  round trip instead of three; with `:wait_for_lock`/`:dead_locking` conflict strategies (without `fail_fast`) it is sent
  in the lock state round trip: `#lock` with a block takes 4 Redis round trips instead of 7, a failed attempt - 3 instead of 6;
- SCAN-based operations (`#clear_locks`, `#clear_locks_of`/`#clear_current_locks`, `#clear_dead_requests`, `#locks`/`#locks_info`,
  `#queues`/`#queues_info`, `#flush_zombies`, `#zombie_locks`/`#zombie_acquirers`/`#zombies_info`) make one `SCAN` pass instead
  of 2-5 passes (one per key family) and send per-key commands in pipelined batches instead of one round trip per key:
  - `#clear_locks` deletes the found keys during the scan with one `DEL` per batch (previously all keys were expired at the end,
    lock queues first);
  - `#clear_locks_of`/`#clear_current_locks` (`clear_locks_of__queue_scan_size`) and `#flush_zombies` (`zombie_queue_scan_size`):
    the queue scan size is the number of lock queues processed in one round trip (queues are found by the same pass as locks);
  - `#zombie_locks`/`#zombie_acquirers`/`#zombies_info` do not scan the keyspace when there are no zombie hosts;
- Read lock data (`rql:lock_reader:<lock_name>:<acquirer_id>`) does not store `acq_id`/`hst_id` (both are derived from the acquirer id):
  ~40% less memory per read lock (`MEMORY USAGE` 280 -> 168 bytes without `:meta`); `#lock_info`/`#locks_info` report them as before
  (the first fields of each reader; read lock data of older versions is supported);
- `#unlock`: one Redis round trip when there are no read locks (the readers registry is read in the release transaction;
  the read lock data is dropped with one more `DEL` only when read locks existed);
- `#lock_series` (PoC): write locks of the series are released (compare-and-delete) in one transaction for the whole series
  (three round trips per series instead of three round trips per lock);
- `#flush_zombies` (and the zombie flusher of the swarm): requests of zombie hosts are dropped from the lock queues by the host
  of the request (derived from its acquirer id): requests of dead hosts that hold no locks are dropped too (previously they stayed
  until the queue ttl) and their acquirers are reported in `deleted_zombie_acquirers`;
- Lock acquirement: retries and `fail_fast` attempts pre-check the lock state without `WATCH` (one round trip): a retry that can not
  obtain the lock takes 1 Redis round trip instead of 3 and a `fail_fast` attempt on an obtained lock - 1 instead of 3 (an attempt
  that can obtain the lock continues with `WATCH`/`MULTI`: one more round trip); mutual exclusion still relies on `WATCH`/`MULTI` only;

## [1.19.0] - 2026-10-11
### Added
- `#unlock_read` (aka `#release_read_lock`): an ability to unlock the read lock of any acquirer
  - `acquirer_id:` option (`nil` by default: the current acquirer) to release the read lock of a different acquirer
    (`identity:` is ignored when `acquirer_id:` is passed: the acquirer id already contains its own identity);

## [1.18.0] - 2026-10-11
### Added
- Brand new feature - **Read/Write locks**: `read_write_mode:` attribute of `#lock`/`#lock!`/`#lock_series`/`#lock_series!` (`:write` by default):
  - `:write` - exclusive lock (the classic RQL lock): waits for the write lock and for all read locks;
  - `:read` - shared lock: waits for the write lock only (read locks of different acquirers work in parallel);
  - `:queued` access strategy orders read and write lock requests in FIFO between modes (writers are not starved by readers);
  - `:random` access strategy ignores lock queues (a continuous flow of readers can starve writers);
  - read locks are stored in `rql:lock_readers:<lock_name>` (`ZSET`: acquirer id => expiration time in Redis time),
    read lock requests - in `rql:lock_read_queue:<lock_name>`, read lock data - in `rql:lock_reader:<lock_name>:<acquirer_id>`
    (the same structure as the write lock: acquirer, host, timestamp, ttl, `:meta`, reentrant lock data);
    write locks and write lock requests use the classic keys;
  - mutual exclusion is based on optimistic transactions (`WATCH`/`MULTI`, no Lua): readers watch the write lock key,
    writers watch the write lock key and the read locks key (readers never invalidate transactions of each other);
  - reentrant locks: read lock request under the obtained lock works as a reentrant lock of the obtained lock;
    read-to-write lock upgrade fails with `RedisQueuedLocks::ConflictLockObtainError` (`:conflict_lock_upgrade`)
    for `:work_through`/`:extendable_work_through` conflict strategies;
  - `#unlock`, `#clear_locks`, `#clear_locks_of`, `#clear_current_locks`, `#clear_dead_requests`, `#flush_zombies`,
    `#zombie_locks`, `#zombie_acquirers`, `#zombies_info`, `#locked?`, `#queued?`, `#lock_info`, `#queue_info`,
    `#locks`, `#locks_info`, `#queues`, `#queues_info` support read locks and read lock requests;
  - logs: `rw_mode` in the lock logs and in the lock series logs (`start_lock_series_obtaining`, `lock_series_obtained`,
    `expire_lock_series`: the mode of the series); new try-lock log events: `exit__write_request_ahead`, `exit__read_request_ahead`,
    `exit__read_lock_still_obtained`, `single_process_lock_conflict__lock_upgrade`;
  - instrumentation: `rw_mode` in `lock_obtained`, `reentrant_lock_obtained`, `extendable_reentrant_lock_obtained`,
    `lock_hold_and_release`, `reentrant_lock_hold_completes` payloads and in the lock series payloads
    (`lock_series_obtained`, `lock_series_hold_and_release`: the mode of the series);
  - `:meta` for read locks (stored in the read lock data of each reader, returned by `#lock_info`/`#locks_info`);
  - `#lock_series` with `read_write_mode: :read` (PoC): a series of read locks; only read locks obtained by the series
    are released (reentrant read locks of the outer logic are kept);
  - `#unlock_read` (aka `#release_read_lock`): releases the read lock of the current acquirer only
    (new instrumentation event: `redis_queued_locks.explicit_read_lock_release`);
  - `#extend_lock_ttl`: `read_write_mode:` (`:write` by default) and `identity:` options; `:read` mode extends the read lock
    of the current acquirer only (an expired read lock or a read lock replaced by a writer is not extended);
  - `#extend_lock_ttl`: `all_read_locks:` option (`false` by default, `:read` mode only, ignored in `:write` mode):
    extends all live read locks of the lock (expired read locks are not revived);
  - RBS: `read_write_mode` is typed as `:read | :write`;
  - `#queue_info` / `#queues_info`: each lock request has `"rw_mode"` (`"write"` / `"read"`);
  - `#lock_info` / `#locks_info`: write lock info has `"rw_mode" => "write"` (read locks info - `"rw_mode" => "read"`);
  - `:meta`: `"rw_mode"` is a reserved lock data key (`RedisQueuedLocks::ArgumentError`), for write and read locks and lock series;
  - **all processes should use the RQL version with read/write locks** before read locks are used
    (write locks of older RQL versions do not check read locks);
### Changed
- `lock_series_obtained` instrumentation event (`#lock_series`, PoC): `:ts` is an epoch timestamp (`Float`)
  like in all other instrumentation events (previously a `Time#to_s` string);
- **Breaking**: `#extend_lock_ttl` success result is `{ ok: true, result: { extended_locks_count: Integer } }`
  instead of `{ ok: true, result: :ttl_extended }` (the number of locks whose TTL is extended: `1` for the write lock
  and for the own read lock, the number of extended read locks for `all_read_locks: true`);
  the failure result is unchanged (`{ ok: false, result: :async_expire_or_no_lock }`);
- Lock acquirement attempt: the lock state is fetched in one pipelined round trip; lock data for
  `exit__no_first`/`exit__lock_still_obtained` try-lock logs is extracted only when these logs are enabled
  (previously `HGETALL` was called on every unsuccessful attempt);
### Fixed
- `dequeue_from_lock_queue` log: unclosed quote in the `acs_strat` value;
- `extendable_reentrant_lock_obtained` log: the host identifier is logged as `hst_id` (was `host_id`), like in all other logs;
- `start_lock_series_obtaining` log: missing space between the `lock_keys` and `queue_ttl` values;
- `lock_series` PoC:
  - locks obtained by the failed series are released when the series fails without an exception
    (`raise_errors: false`); previously they lived till their TTL;
  - reentrant locks of the series (already obtained by the outer logic of the same acquirer) are not released
    by the series anymore (previously the outer logic continued to work without its lock);
  - the series releases only write locks that are still owned by the current acquirer (compare-and-delete):
    a lock expired during the block and obtained by another acquirer is not deleted anymore;

## [1.17.0] - 2026-10-04
### Changed
- [**Breaking**] Minimal Ruby Version - **4.0** (previously - **3.3**):
  - removed `3.3` and `3.4` from `CI`;
- Swarm: isolated swarm elements (`RedisQueuedLocks::Swarm::SwarmElement::Isolated`, `FlushZombies`) are reworked
  to the Ruby 4 Ractor API: `Ractor.yield`/`Ractor#take` are replaced with `Ractor::Port`s (each element owns
  its own pair of ports: the results port is created in the main ractor where the swarm supervisor lives and the
  command port is created inside the element ractor), element ractor termination is tracked via `Ractor#monitor`;
- Swarm: isolated element ractor is terminated deterministically on `#try_kill!` / `#deswarm!`
  (all ractor threads are killed and joined);
- Swarm: `RedisQueuedLocks::Swarm::SwarmElement::Isolated` subclasses implement `#spawn_swarm_element!(results_port)`
  instead of `#swarm!`;
- Swarm: internal swarm element protocol (`Threaded` and `Isolated` command replies, isolated element handshake)
  uses bare scalars/primitives instead of `{ ok:, result: }` wrappers (the wrapper is kept for the public API only);
### Fixed
- `RedisQueuedLocks::Client#zombies_info`: default `lock_scan_size` was taken from the
  `swarm.flush_zombies.zombie_ttl` config instead of `swarm.flush_zombies.zombie_lock_scan_size`;

## [1.16.2] - 2026-02-06
### Fixed
- `lock_series` PoC:
  - acquired locks are not released when the block of code invoked under the lock series fails with
    an exception
  - `raise_errors: true` option incorrectly suppresses the lock releasing when the lock series
    reaches their obtaning limits

## [1.16.1] - 2026-01-28
### Changed
- `lock_series` PoC:
  - added own instrumentation visitor and log ivsitor (`RedisQueuedLocks::Acquirer::LockSeriesPoC::LogVisitor` and
   `RedisQueuedLocks::Acquirer::LockSeriesPoC::InstrVisitor` respectively) and all `lock_series`-related
   instrumentation/log methods were moved to these modules;
  - documentaiton updates;
- YARDOC documentaiton updates;
### Added
- `lock_series` PoC updates:
  - added missing instrumentation event `lock_series_obtained`;
  - added more data to the `detailed_event: true` lock invocation result:
    - `locks_release_strategy` - `:immediate_release_after_yield` or `:redis_key_ttl`
### Fixed
- `lock_series` PoC:
  - incorrect instrumentation/logs data:
    - `expire_lock_series` log and instrumentation event should not be produced
      when locks were obtained without a block of code (for this case obtained locks
      lives in redis with their TTL);
    - `locks_released_at` and `locks_hold_time` of the detailed invocation result (`detailed: true`)
      has nil values in case when locks are obtained without a block of code
      (lokcs are not released at this moment and lives in redis with their TTL);

## [1.16.0] - 2026-01-27
### Added
- Brand new Feature **"Lock series of locks"**
  - (*Proof of Concpet*-based implementation at the moment) 
  - lock series of lock simultainously (and release them all at the finish of your the invocation of block of code under the obtained locks);
  - exmaple: `client.lock_series("a", "b", "c")` (or in exceptional-based way `client.lock_series!("a", "b", "c")`;
### Changed
- YARDOC documentation updates in order to prepare to the 100% yardoc-coverage;
- updated dev deps;
### Fixed
- fixed some yardoc documentation typos;

## [1.15.1] - 2025-10-22
### Fixed
- **Config Layer**:
  - some config keys has no correspondig validator so during config instantation
    custom configuraiton of these keys leads to **NoMethodError**. Missing validators were added and
    a correspondig test added too.

## [1.15.0] - 2025-10-17
### Changed
- `"redis_queud_locks.release_locks_of"` instrumentation event payload now includes `hst_id` and `acq_id`;

## [1.14.0] - 2025-10-17
### Added
- `#clear_locks_of`/`#release_locks_of`
- `#clear_current_locks`/`#release_current_locks`
- aliases for `RedisQueuedLocks::Client#current_acquirer_id`: `current_acq_id`, `acq_id`;
- aliases for `RedisQueuedLocks::Client#current_host_id`: `current_hst_id`, `hst_id`;
### Changed
- bumped ruby development version to 3.4.5;
- bumped development dependencies;
- (**internal**): `Process.clock_gettime` explicit invocations is moved to the `RedisQueuedLocks::Utils`;

## [1.13.0] - 2025-06-07
### Changed
- Updated development dependencies (`armitage-rubocop`, `rbs`, `steep`);
- Bumped development Ruby version (from `3.3.6` to `3.4.3`);
- CI is splitted to "mainstream ruby version" and "previous actually maintaned ruby versions";
- `Acquier` -> `Acquirer`, `Acquierment` -> `Acquirement` (typos):
  - [**Breaking**] Constant renaming: all constants and constant parts were renamed from `Acquier` to `Acquirer`;
  - [**Breaking**] Method and variable names renaming: all `acquier` text parts of method/variable names were renamed to `acquirer`;
  - [**Breaking**] Logs: all `acquier` text parts of each log message type were renamed to `acquirer`;
  - [**Breaking**] Instrumentation:  all `acquier` text parts of each event name were renamed to `acquirer`;
  - [**Breaking**] Exceptions: all `Acquierment` exception constant name parts were renamed to `Acquirement`;
- [**Breaking**] `RedisQueuedLocks::Data` is not used (**temporary**) as result type of some APIs.
  The reason is that this type can not be used as a record type in `steep`/`rbs` (working on it);
- [**Breaking**] Minimal Ruby Version - **3.3** (previously - **3.1**):
  - removed `3.1` and `3.2` from `CI`;
- [**Breaking**] Config layer was fully reworked in order to improve performance:
  - Config API has changed from "method invocation" to "hash key/value access/assignment" with a validation layer and config-data-access wrapping;
### Added
- **Type Checking**:
  - library codebase is fully typed;
  - integrated `RBS` with `Steep` that is configured on **strict mode** (see `sig` directory, `Steepfile` config, `sig/manifest.yml` and `rbs_collection.yml` for dependencies);
  - CI integration;
  - Integrated RBS linting to `Rubocop`;
- Test coverage (via `simplecov` with `html` and `lcov` formats). `minimum_coverage` config is temporary disabled (and the CI step is not configured yet) cuz we need to refactor tests in first;
- CI:
  - `rspec-retry` is temporary added until the tests are fully refactored;
  - typecheck steps: `TypeCheck (Static)` (based on `steep` checks) and `TypeCheck (Runtime)` (based on `RBS` runtime type checking/testing);
- Support for `ActiveSupport::BroadcastLogger` logger instances;

## [1.12.1]
### Changed
- Internal Private API: an internal Reentrant's Lock utility (`RedisQueuedLocks::Utilities::Lock`) basis
  is changed from `::Mutex` to `::Monitor` in order to use Ruby's Core C-based
  implementation (prevent some Ruby-runtime based GVL-oriented locking) of re-entrant locks
  instead of the custom Ruby-based implementation;
### Fixed
- `redis_queued_locks.lock_hold_and_release` instrumentation event has incorrect `acq_time` payload value
  (it incorrectly stores `lock_key` payload value);

## [1.12.0] - 2024-08-11
### Changed
- Timed blocks of code and their timeout errors: reduced error message object allocations;

## [1.11.0] - 2024-08-11
### Changed
- Lock Acquirement Timeout (`acq_timeout`/`queue_ttl`): more correct timeout error interception
  inside the `RedisQueuedLocks::Acquier::AcquireLock::WithAcqTimeout` logic that now raises and
  intercepts an internal timeout error class in order to prevent interceptions of
  other timeouts that can be raised from the wrapped block of code;

## [1.10.0] - 2024-08-11
### Changed
- Timed invocations (`"timeed blocks of code"` / `timed: true`):
  - the way of timeout error interception has been changed:
    - instead of the `rescue Timeout::Error` around the block of code the timeout interception
      now uses `Timeout#timeout`'s custom exception class/message replacement API;
    - `rescue Timeout::Error` can lead to incorrect exception interception: intercept block's-related
      Timeout::Error that is not RQL-related error;
- Updated development dependencies;
- Some minor readme updates;
### Added
- `RedisQueuedLocks::Swarm`: missing YARDocs;
- Separated `Logging Configuration` readme section (that is placed inside the main configuration section already);
- Separated `Instrumentation Configuration` readme section (that is placed inside the main configuration section already);
### Removed
- `RedisQueudLocks::Swarm`: some useless YARDocs;

## [1.9.0] - 2024-07-15
### Added
- Brand New Extremely Major Feature: **Swarm Mode** - eliminate zombie locks with a swarm:
  - works by `supervisor` + `actor model` abstractions;
  - all your ruby workers can become an element of the processs swarm;
  - each ruby worker of the swarm probes himself that he is alive;
  - worker that does not probes himselfs treats as a zombie;
  - worekr becomes dead when your ruby process is dead, or thread is dead or your ractor is dead;
  - each zombie's lock, acquirer and position in queue are flushed in background via `flush_zombies` swarm element;
  - the supervisor module keeps up and running each swarm melement (`probe_hosts` and `flush_zombies`):
    - cuz each element works in background and can fail by any unexpected exception the supervisor guarantees that your elements will ressurect after that;
  - each element can be deeply configured (and enabled/disabled);
  - abilities:
    - configurable swarming and deswarming (`#swarmize!`, `#deswarmize!`);
    - encapsulated swarm interface;
    - two fully isolated swarm elements: `probe_hosts` and `flush_zombies`;
    - supervisor that keeps all elements running and wokring;
    - an ability to check the swarm status (`#swarm_status`): who is working, who is dead, running status, internal main loop states, etc;
    - an abiltiy to check the swarm information (`#swarm_info`): showing the current swarm hosts and their last probes and current zombie status;
    - an ability to find zombie locks, zombie acquirers and zombie hosts (`#zombie_locks`, `#zombie_acquiers`, `#zombie_hosts`);
    - an ability to extract the full zombie information (`#zombies_info`/`#zombies`);
    - each zombie lock will be flushed in background by appropriated swarm element (`flush_zombies`);
    - deeply configurable zombie factors: zombie ttl, host probing period, supervisor check period;
    - an ability to manually probe hosts;
    - an ability to flush zombies manually;
    - you can made `swarm`-based logic by yourself (by manually runnable `#flush_zombies` and `#probe_hosts`);
  - summarized interface:
    - `#swarmize!`, `#deswarmize!`;
    - `#swarm_status`/`#swarm_state`, `#swarm_info`
    - `#zombie_locks`, `#zmobie_acquiers`, `#zombie_hosts`, `#zombies_info`/`#zombies`;
    - manual abilities: `#probe_hosts`, `#flush_zombies`;
  - **general note**: each swarm element should have their own `RedisClient` instance so each have their own redis-client configuration
    and each of the can be configured separately (**RedisClient** multithreading limitation and **Ractor** limitations);
- Added the `lock host` abstraction (`hst_id`):
  - each lock is hosted by some ruby workers so this fact is abstracted into the host identifier represended as a combination of `process_id`/`thread_id`/`ractor_id`/`uniq_identity`;
  - the ruby worker is a combination of `process_id`/`thread_id`/`ractor_id`/`uniq_identity`);
  - each lock stores the host id (`hst_id` field) indisde their data (for debugging purposes and zombie identification purposes);
  - every lock information method now includes `hst_id` field: `#lock_info`, `#lock_data`, `#locks_info`;
  - an ability to fetch the current host id (your ruby worker host id): `#current_host_id`;
  - an ability to fetch all possible host ids in the current Ractor (all possible and reachable ruby workers from the current ractor): `#possible_host_ids`;
  - extended `RedisQueuedLocks::TimedLocktimeoutError` message: added `hst_id` field data from the lock data;
- **Instrumentation** updates:
  - added the `hst_id` field to each locking-process-related instrumentation event;
- **Logging** updates:
  - added `hst_id` field to each locking-process-related log;
- **Logging/Instrumentation Sampling** updates:
  - an ability to mark any loggable/instrumentable method as sampled for instrumentation/logging despite of the enabled instrumentation/log sampling
    by providing the `log_sample_this: true` attribute and `instr_sample_this: true` attribute respectively;
- an alias for `#clear_locks`: `#release_locks`;
- an alias for `#unlock`: `#release_lock`;

## [1.8.0] - 2024-06-13
### Added
- A configurable option that enables the adding additional lock/queue data to "Acquirement Timeout"-related error messages for better debugging;
  - Configurable option is used beacuse of the extra error data requires some additional Redis requests that can be costly for memory/cpu/etc resources;
- An ability to get the current acquirer id (`RedisQueuedLocks::Client#current_acquirer_id`);
### Changed
- Added additional lock information to some exceptions that does not require extra Redis requests;

## [1.7.0] - 2024-06-12
### Added
- New feature: **Lock Access Strategy**: you can obtain a lock in different ways: `queued` (classic queued FIFO), `random` (get the lock immideatly if lock is free):
  - `:queued` is used by default (classic `redis_queued_locks` behavior);
  - `:random`: obtain a lock without checking the positions in the queue => if lock is free to obtain - it will be obtained;
### Changed
- Some logging refactorings, some instrumentation refactorings: the code that uses them is more readable and supportable;

## [1.6.0] - 2024-05-25
### Added
- New Feature: **Instrumentation Sampling**: configurable instrumentation sampling based on `weight` algorithm (where the weight is a percentage of RQL cases that should be logged);
- Missing instrumenter customization in public `RedisQueuedLocks::Client` methods;
- Documentation updates;

## [1.5.0] - 2024-05-23
### Added
- New Feature: **Log sampling** - configurable log sampling based on `weight` algorithm (where the weight is a percentage of RQL cases that should be logged);

## [1.4.0] - 2024-05-13
### Added
- `#lock`/`#lock!`: reduced memory allocaiton during `:meta` attribute type checking;
### Changed
- More accurate time analyzis operations;

## [1.3.1] - 2024-05-10
### Fixed
- `:meta` attribute type validation of `#lock`/`#lock!` was incorrect;
### Added
- documentation updates and clarifications;

## [1.3.0] - 2024-05-08
### Added
- **Major Feature**: support for **Reentrant Locks**;
- The result of lock obtaining now includes `:process` key that shows the type of logical process that obtains the lock
  (`:lock_obtaining`, `:extendable_conflict_work_through`, `:conflict_work_through`, `:dead_locking`);
- Added reentrant lock details to `RedisQueuedLocks::Client#lock_info` and `RedisQueuedLocks::Client#locks` method results;
- Documentation updates;
### Changed
- Logging: `redis_queued_locks.fail_fast_or_limits_reached__dequeue` log is renamed to `redis_queued_locks.fail_fast_or_limits_reached_or_deadlock__dequeue`
  in order to reflect the lock conflict failures too;

## [1.2.0] - 2024-04-27
### Added
- Documentation updates;
- Logging: support for `semantic_logger` loggers (see: https://logger.rocketjob.io/) (https://github.com/reidmorrison/semantic_logger)

## [1.1.0] - 2024-04-01
### Added
- Documentation updates:
  - more `#lock` examples;
  - added missing docs for `config.dead_request_ttl`;
  - some minor updates;
### Changed
- `#clear_dead_requests`: `:scan_size` is equal to `config[:lock_release_batch_size]` now (instead of to `config[:key_extraction_batch_size]`), cuz `#clear_dead_requests` works with lock releasing;

## [1.0.0] - 2024-04-01
- First Major Release;

## [0.0.40] - 2024-04-01
### Added
- `RedisQueuedLocks::Client#clear_dead_requests` implementation;
- Logger and instrumentation are passed everywhere where any changes in Redis (with locks and queus)
  are expected;
- New config `is_timed_by_default` (boolean, `false` by default) that reflects the `timed` option of `#lock` and `#lock!` methods;
- Ther result of `#unlock` is changed: added `:lock_res` and `:queue_res` result data in order to reflect
  what happened inside (`:released` or `:nothing_to_release`) and to adopt to the case when you trying
  to unlock the non-existent lock;
- A lot of documentation updates;
- Github CI Workflow;
### Changed
- `:rel_key_cnt` result of `#clear_locks` is more accurate now;

## [0.0.39] - 2024-03-31
### Added
- Logging:
  - added new log `[redis_queued_locks.fail_fast_or_limits_reached__dequeue]`;
- Client:
  - `#extend_lock_ttl` implementation;
### Changed
- Removed `RadisQueuedLocks::Debugger.debug(...)` injections;
- Instrumentation:
  - the `:at` payload field of `"redis_queued_locks.explicit_lock_release"` event and
  `"redis_queued_locks.explicit_all_locks_release"` event is changed from `Integer` to `Float`
  in order to reflect micro/nano seconds too for more accurate time value;
- Lock information:
  - the lock infrmation extracting now uses `RedisClient#pipelined` instead of `RedisClient#mutli` cuz
    it is more reasonable for information-oriented logic (the queue information extraction works via `pipelined` invocations for example);
- Logging:
  - log message is used as a `message` (not `pragma`) according to `Logger#debug` signature;

## [0.0.38] - 2024-03-28
### Changed
- Minor update (dropped useless constant);

## [0.0.37] - 2024-03-28
### Changed
- `#queues_info`: `:contains` is renamed to `:reqeusts` in order to reflect it's domain area;

## [0.0.36] - 2024-03-28
### Added
- Requirements:
  - redis version: `>= 7.x`;
  - redis protocol: `RESP3`;
- Additional debugging methods:
  - `#locks_info` (or `#locks(with_info: true)`) - get obtained locks with their info;
  - `#queus_info` (or `#queues(with_info: true`) - get active lock queues with their info;

## [0.0.35] - 2024-03-26
### Changed
- The random unique client instance identifier now uses 16-byte strings instead of 10-bytes in order to prevent potential collisions;

## [0.0.34] - 2024-03-26
### Changed
- Removing the acquirer from the request queue during the lock obtaining logic is using more proper and accurate `ZREM` now instead of `ZPOPMIN`;

## [0.0.33] - 2024-03-26
### Added
- Logging: added current lock data info to the detailed `#try_to_lock` log to the cases when lock is still obtained. It is suitable
  when you pass a custom metadata with lock obtainer (for example: the current string of code) and want to see this information
  in logs when you can not acquire the concrete lock long time;

## [0.0.32] - 2024-03-26
### Added
- Support for custom metadata that merged to the lock data. This data also returned from `RedisQueudLocks::Client#lock_info` method;
  - Custom metadata should be represented as a `key => value` `Hash` (`nil` by default);
  - Custom metadata values is returned as raw data from Redis (commonly as strings);
  - Custom metadata can not contain reserved lock data keys;
- Reduced some memory consuption;
### Changed
- `RedisQueuedLocks::Client#lock_info`: hash key types of method result is changed from `Symbol` type to `String` type;
- `RedisQueuedLocks::Client#queue_info`: hash key types of method result is changed from `Symbol` type to `String` type;

## [0.0.31] - 2024-03-25
### Changed
- `:metadata` renamed to `:instrument` in order to reflect its domain area;
- `:metadata` is renamed to `:meta` and reserved for future updates;

## [0.0.30] - 2024-03-23
### Fixed
- Re-enqueue problem: fixed a problem when the expired lock requests were infinitly re-added to the lock queue
  and immediately removed from the lock queue rather than being re-positioned. It happens when the lock request
  ttl reached the queue ttl, and the new request now had the dead score forever (fix: its score now will be correctly
  recalculated from the current time at the dead score time moment);
### Added
- Logging: more detailed logs to the `RedisQueuedLocks::Acquier::AcquierLock` logic and its sub-modules:
  - added new logs;
  - added `queue_ttl` to each log;

## [0.0.29] - 2024-03-23
### Added
- Logging: added more detailed logs to `RedisQueuedLocks::Acquier::AcquireLock::TryToLock`;

## [0.0.28] - 2024-03-21
### Added
- Logging: added `acq_id` to every log message;
- Logging: updated documentation;

## [0.0.27] - 2024-03-21
### Changed
- Better acquirer position accuracy: acquirer position in lock queue
  should be represented as EPOCH in seconds+microseconds (previously: simply in seconds);

## [0.0.26] - 2024-03-21
### Added
- Logging: add `acquier_id`;

## [0.0.25] - 2024-03-21
### Changed
- Minor logs stylization;

## [0.0.24] - 2024-03-21
### Added
- An optional ability to log each try of lock obtaining (see `RedisQueuedLocks::Acquier::AcquireLock::TryToLock.try_to_lock`);

## [0.0.23] - 2024-03-21
### Changed
- Composed redis commands are invoked from the same *one* conenction
  (instead of mutiple connection fetching from redis connection pool on each redis command);

## [0.0.22] - 2024-03-21
### Added
- Logging infrastructure. Initial implementation includes the only debugging features.

## [0.0.21] - 2024-03-19
### Changed
- Refactored `RedisQueuedLocks::Acquier`;

## [0.0.20] - 2024-03-14
### Added
- An ability to provide custom metadata to `lock` and `lock!` methods that will be passed
  to the instrumentation level inside the `payload` parameter with `:meta` key;

## [0.0.19] - 2024-03-12
### Added
- An ability to set the invocation time period to the block of code invoked under
  the obtained lock;

## [0.0.18] - 2024-03-04
### Changed
- Semantic results for methods returning `{ ok: true/false, result: Any }` hash objects.
  Now these objects are represented as `RedisQueuedLocks::Data` objects inherited from `Hash`;

## [0.0.17] - 2024-02-29
### Added
- `RedisQueuedLocks::Client#locks` - list of obtained locks;
- `RedisQueuedLocks::Client#queues` - list of existing lock request queus;
- `RedisQueuedLocks::Client#keys` - get list of taken locks and queues;

## [0.0.16] - 2024-02-29
### Fixed
- Execution delay formula returns the value "in seconds" (should be "in milliseconds");

## [0.0.15] - 2024-02-28
### Added
- An ability to fail fast if the required lock is already obtained;

## [0.0.14] - 2024-02-28
### Changed
- Minor documentation updates;

## [0.0.13] - 2024-02-27
### Changed
- Minor development updates;

## [0.0.12] - 2024-02-27
### Changed
- Deleted `redis expiration error` (1 millisecond time drift) from lock ttl calculation;

## [0.0.11] - 2024-02-27
### Changed
- Minor documentation updates;

## [0.0.10] - 2024-02-27
### Changed
- Minor documentation updates;

## [0.0.9] - 2024-02-27
### Changed
- The lock acquirer identifier (`acq_id`) now includes the fiber id, the ractor id and an unique per-process
  10 byte string. It is added in order to prevent collisions between different processes/pods
  that will have the same process id / thread id identifiers (cuz it is an object_id integers) that can lead
  to the same position with the same `acq_id` for different processes/pods in the lock request queue.

## [0.0.8] - 2024-02-27
### Added
- `RedisQueuedLock::Client#locked?`
- `RedisQueuedLock::Client#queued?`
- `RedisQueuedLock::Client#lock_info`
- `RedisQueuedLock::Client#queue_info`

## [0.0.7] - 2024-02-27
### Changed
- Minor documentation updates;

## [0.0.6] - 2024-02-27
### Changed
- Major documentation updates;
- `RedisQueuedLock#release_lock!` now returns detaield semantic result;
- `RediSQueuedLock#release_all_locks!` now returns detailed semantic result;

## [0.0.5] - 2024-02-26
### Changed
- Minor gem update with documentation and configuration updates inside.

## [0.0.4] - 2024-02-26
### Changed
- changed default configuration values of `RedisQueuedLocks::Client` config;

## [0.0.3] - 2024-02-26
### Changed
- Instrumentation events:
  - `"redis_queued_locks.explicit_all_locks_release"`
    - re-factored with fully pipelined invocation;
    - removed `rel_queue_cnt` and `rel_lock_cnt` because of the pipelined invocation
      misses the concrete results and now we can receive only "released redis keys count";
    - adde `rel_keys` payload data (released redis keys);

## [0.0.2] - 2024-02-26
### Added
- Instrumentation events:
  - `"redis_queued_locks.lock_obtained"`;
  - `"redis_queued_locks.lock_hold_and_release"`;
  - `"redis_queued_locks.explicit_lock_release"`;
  - `"redis_queued_locks.explicit_all_locks_release"`;

## [0.0.1] - 2024-02-26

- Still the initial release version;
- Downgrade the minimal Ruby version requirement from 3.2 to 3.1;

## [0.0.0] - 2024-02-25

- Initial release
