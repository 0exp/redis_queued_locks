# redis_queued_locks: Project Overview

Ruby gem providing **distributed locks on Redis with a prioritized lock-acquisition queue**.
Each lock has its own request queue; requests are processed FIFO (`:queued`, ordered by the lock request
priority first: `priority` -100..100) or first-come (`:random`). Requests have TTLs (with requeue), so queues never get stuck. Includes reentrancy
(conflict) strategies, timed locks, retries/fail-fast, logging, instrumentation with sampling,
and a background "swarm" that detects dead hosts and flushes their locks.

- Repo: https://github.com/0exp/redis_queued_locks (MIT); main branch `master`
- Runtime dependency: `redis-client ~> 0.20` (locked 0.31.0), nothing else
- Ruby `>= 4.0` (`.ruby-version` = 4.0.7)

---

## 1. Architecture

```
RedisQueuedLocks (lib/redis_queued_locks.rb)   entry point; requires all parts; extends Debugger::Interface
        │
        ▼
Client (client.rb)                              public API facade
  ├── Config (config.rb + config/dsl.rb)        declarative settings + validators
  ├── Swarm  (swarm.rb + swarm/*)               supervised background workers
  └── Acquirer::* modules                       one stateless module per operation
              │
              ▼
        RedisClient (redis-client gem)          WATCH/MULTI, Lua (EVAL), ZSET, HASH, SCAN

Resource (resource.rb)                          keys, acquirer/host ids, queue score layout (priority bands)
```

`Client.new(redis_client) { |config| ... }`:
1. builds `Config` from the block,
2. computes `uniq_identity` via `config['uniq_identifier']`,
3. creates `Swarm` and starts it when `config['swarm.auto_swarm']` is true.

Every other public method is a thin wrapper: it fills option defaults from `config[...]` and calls
an `Acquirer::*` module function with `redis_client`.

Operation modules are independent of each other (all `Acquirer::*` except the `AcquireLock` core
and PoC modules such as `LockSeriesPoC`, which may reuse other modules and `AcquireLock`): no
cross-calls and no shared RBS types; common logic lives in `Resource`/`Utilities`, similar logic is
duplicated on purpose (`Locks` duplicates the `LockInfo` write/read lock formatting, `Queues` the
`QueueInfo` request formatting). Known debt: `AcquireLock::WithAcqTimeout` calls
`LockInfo`/`QueueInfo` for detailed timeout errors.

### Read/Write locks in the architecture

`read_write_mode: :write` (default) is the exclusive classic lock (its keys and data are unchanged); `:read` is a shared
lock: readers share the lock with each other, a writer waits for the write lock and for all live readers, a reader waits
for the write lock only. Mutual exclusion comes only from WATCH/MULTI on the lock state (no Lua in the RW path); the
request queues only order the requests (FIFO between modes by `(score, acq_id)`).

Keys of one lock name (all of them match `KEY_PATTERN`, classified by `Resource.lock_key_family`):

```
rql:lock:<name>                 HASH  write lock: owner + data                      write lock state
rql:lock_readers:<name>         ZSET  readers registry: acq_id => expiry (Redis ms)  read lock state (the source of truth)
rql:lock_reader:<name>:<acq_id> HASH  reader data (the write lock format without ids: a data carrier only)
rql:lock_queue:<name>           ZSET  write lock requests                            ordering only
rql:lock_read_queue:<name>      ZSET  read lock requests (the same scores)           ordering only
```

The path of the mode through the components:

```
Client#lock / #lock! (read_write_mode:)            #lock_series / #lock_series! (one mode per series),
  │                                                #unlock_read / #release_read_lock, #extend_lock_ttl(read_write_mode:,
  │                                                all_read_locks:)
  ▼
AcquireLock Step 0.1 (RW)                          validates the mode; the keys are computed once (read_lock_key: readers only)
  ▼
TryToLock (each attempt and pre-check)             WATCH: writers [lock_key, lock_readers_key], readers [lock_key] only
  │                                                (readers never abort each other); one state pipeline: HGET acq_id,
  │                                                TIME, own reader score, longest reader (writers); the conditions:
  │                                                write = no write lock + no live reader (score > Redis now),
  │                                                read = no write lock; the order: write = head of the write queue +
  │                                                no earlier read request, read = no earlier write request; the
  │                                                obtaining MULTI: write HSET + PEXPIRE, read ZADD expiry + registry
  │                                                PEXPIRE NX + GT + reader data; same-acquirer conflicts by
  │                                                conflict_strategy (held mode `sp_conflict_rw_mode`; read->write
  │                                                upgrade never works through)
  ▼
YieldExpire                                        releases the held mode (`held_rw_mode`): write EXPIRE 0, read ZREM +
                                                   DEL of the own reader data (owner-safe)
ReleaseLock (unlock)                               write lock + readers + both queues in one MULTI, then one DEL of the
                                                   released readers' data (only when readers existed)
ReleaseReadLock / ExtendLockTTL                    one read lock (own or `acquirer_id:`) / own or all live read locks
Info, iteration, cleanup, swarm                    the read family everywhere: lock_info readers, queue_info read_queue,
                                                   locks/queues/keys, clear_*, clear_dead_requests, zombies
LogVisitor / InstrVisitor (+ series, try-lock)     rw_mode in every lock log/event (requested; YieldExpire: held; series)
```

- Invariants for any lock-touching code: cover the read family next to `rql:lock:*`/`rql:lock_queue:*`; writers WATCH
  the registry, readers never; reader liveness only by the Redis-time score (`score > now`), never `ZCARD`/`EXISTS`;
  registry and reader data TTLs keep the max with `PEXPIRE NX` + `PEXPIRE GT`; write-only result shapes stay unchanged
  (read keys/fields only when read data exists); the lock index covers the read keys (enabled mode).
- Details (reentrancy matrix, fail_fast, results, release semantics, design decisions): "Read/Write locks" below; the
  public description: README "Read/Write Locks".

### Lock request prioritization in the architecture

The lock request priority orders the waiting requests of a lock (`:queued`): strict priority between priorities, FIFO
inside a priority, in both read/write modes. It is carried by the queue score only (no new keys, fields or commands per
request) and never takes part in mutual exclusion (WATCH/MULTI on the lock state decides it, as before). The path of the
priority through the components:

```
Client#lock / #lock! / #lock_series / #lock_series!     priority: (Integer or a name), default config['default_lock_priority'];
  │                                                     lock_priorities: config['lock_priorities'] (internal keyword)
  ▼
Config (config.rb)                                      lock_priorities (name => Integer) + default_lock_priority validators,
  │                                                     the default name checked against the names (configure / []=)
  │
  ▼
AcquireLock Step 0.1 / LockSeriesPoC                    name -> Integer, range -100..100 (ArgumentError); Integer only below
  │
  ├──▶ Resource                                         the single source of the score layout:
  │      calc_initial_acquirer_position(priority)       score = enqueue time - priority * 2**32 (one band per priority)
  │      dead_score_reached?(position, priority, ttl)   requeue check (decodes the enqueue time)
  │      lock_priority_band_floor / _dead_score         the bounds of the dead requests of a band
  │      lock_request_priority(score)                   the priority decoded from a score
  │
  ├──▶ TryToLock (each attempt and pre-check)           queueing: the own band pruned in both queues + ZADD NX with the
  │                                                     shifted score (queue_lock_request, no extra round trip); Step 2.2:
  │                                                     dead blocking requests of other bands dropped with their bands
  │                                                     (drop_dead_requests_ahead, dead_request_priority: one round trip
  │                                                     per removal, none while nothing dead blocks); ordering: queue heads
  │                                                     and the cross-mode (score, acq_id) comparison on shifted scores
  │
  ├──▶ ClearDeadRequests                                per-band cleanup of the bands found in the queues (<= 2 round trips/batch)
  ├──▶ QueueInfo / Queues                               'priority' of each request decoded from its score
  └──▶ LogVisitor / InstrVisitor (+ series, try-lock)   priority in every lock acquirement log/event; try-lock logs decode
                                                        the priorities of the requests ahead (first/ahead/dead)
```

- Unchanged by prioritization: the lock keys and their data, queue members (`acq_id`), dequeue (`ZREM`), `unlock` /
  `clear_locks` (full queue clears), the swarm (hosts and zombies come from acquirer ids), the lock index, the obtaining
  transactions.
- Invariants for any code that touches lock queues: never prune a queue with one `-inf..now-ttl` range (prune bands with
  the `Resource` bounds); never enumerate the priority range per attempt or per queue (decode the bands from the data);
  read priorities only through `Resource.lock_request_priority`; the attempt cost must not depend on the priority range.
- Details (encoding, liveness, cleanup, limitations, mixed versions): "Lock request priorities" below; the public
  description: README "Lock Request Prioritization".

### Client → implementation map

| Client method | Implementation |
|---|---|
| `lock` / `lock!` | `acquirer/acquire_lock.rb` + `acquirer/acquire_lock/*` |
| `lock_series` / `lock_series!` | `acquirer/lock_series_poc.rb` (proof of concept; one `read_write_mode` for the whole series) |
| `unlock` | `acquirer/release_lock.rb` |
| `unlock_read` / `release_read_lock` | `acquirer/release_read_lock.rb` (own read lock or `acquirer_id:` read lock only) |
| `extend_lock_ttl` | `acquirer/extend_lock_ttl.rb` (`read_write_mode: :read` extends own read lock, `+ all_read_locks: true` all live read locks) |
| `locked?` / `queued?` | `acquirer/is_locked.rb` / `acquirer/is_queued.rb` |
| `lock_info` / `queue_info` | `acquirer/lock_info.rb` / `acquirer/queue_info.rb` |
| `locks`, `locks_info`, `queues`, `queues_info`, `keys` | `acquirer/locks.rb`, `queues.rb`, `keys.rb` (keyspace SCAN or lock index: `lock_index_enabled`) |
| `clear_locks` | `acquirer/release_all_locks.rb` |
| `clear_locks_of`, `clear_current_locks` | `acquirer/release_locks_of.rb` |
| `clear_dead_requests` | `acquirer/clear_dead_requests.rb` |
| `reindex_locks` | `acquirer/reindex_locks.rb` (adds keys without lock index entries to the lock index: one SCAN pass; works in both modes) |
| `current_acquirer_id`, `current_host_id`, `possible_host_ids` | `resource.rb` |
| `swarmize!`, `deswarmize!`, `swarm_status`, `swarm_info`, `probe_hosts`, `flush_zombies`, `zombie_locks`, `zombie_acquirers`, `zombie_hosts`, `zombies_info` | `swarm.rb` + `swarm/*` |

### Lock acquisition flow (`acquirer/acquire_lock.rb` + `acquire_lock/`)

`AcquireLock` is assembled from mixins (`extend`):

| Mixin | Role |
|---|---|
| `TryToLock` (`try_to_lock.rb`) | One attempt: `multi(watch:)` (write: lock key + readers registry, read: lock key only), one pipelined read of the lock state (`HGET acq_id`, `TIME`, own reader score, longest reader: write requests only), the lock request queueing in one pipelined round trip (`queue_lock_request`: prune the priority band of the request in both queues (first: the old dead position of a requeued request is dropped before `ZADD NX` adds its new position), `ZADD NX` into the queue of the requested mode (timestamp score shifted by the priority band, see "Lock request priorities"), both queue heads with scores, then (the enabled lock index only) the lock index commands: request queue `PEXPIRE NX`+`GT` (queue ttl), `ZADD GT` of the lock name into the lock index (queue ttl), `ZREMRANGEBYSCORE` of expired lock names), drop the dead requests of other priority bands that block the request (the write queue head and the earlier opposite-mode request) with their bands in one more round trip that re-reads the heads (`drop_dead_requests_ahead`, Step 2.2, also in the pre-check: up to `MAX_DEAD_REQUEST_REMOVALS` = 5 such round trips per attempt, none while no dead request blocks), take the lock if allowed (see Read/Write locks; with the enabled lock index the obtaining `MULTI` ends with the lock index `ZADD GT` (lock ttl), the `:extendable_work_through` extension `MULTI` with `ZADD XX INCR`). Eager queueing (`:wait_for_lock`/`:dead_locking` without `fail_fast`) sends the queueing commands in the lock state round trip: `lock {}` = 4 round trips (`WATCH`, state + queueing, `MULTI/EXEC`, release), a failed attempt = 3. Pre-check (`precheck_lock`, retries and `fail_fast` attempts): the lock state (+ the queueing for retries) without `WATCH` in one round trip; an attempt that can not obtain the lock fails there (same results and log events: `lock_obstacle`/`log_lock_obstacle`), otherwise the attempt continues with `WATCH`/`MULTI` (a failed retry = 1 round trip, a successful one = 4; `fail_fast` on an obtained lock = 1); same-process conflicts are never decided by the pre-check. Handles reentrant conflicts (incl. read/write ones); write TTL extension via inline Lua (`PTTL` + `PEXPIRE`). |
| `WithAcqTimeout` | Global acquisition timeout (`timeout`). |
| `DelayExecution` | Retry delay + jitter between attempts. |
| `DequeueFromLockQueue` | Removes the acquirer from the queue of the requested mode on timeout/failure. |
| `YieldExpire` | Runs the user block (optionally `timed`), then releases/expires the lock of the held mode (write: `EXPIRE 0`; read: `ZREM` own reader + `DEL` own read lock data; extendable reentrant: decrease). Known limitation (kept by the user's decision, documented in README): the write release and the write ttl decrease have no owner check, so a block longer than the ttl can delete/shorten the lock of another acquirer. |
| `LogVisitor` / `InstrVisitor` | One method per lifecycle event for logs and instrumentation. |

### Main `lock` options (defaults from config)

`ttl`, `queue_ttl`, `lock_index_grace_period` (used with the enabled lock index only; the mode itself, `config['lock_index_enabled']`,
is client-wide: `Client` passes it to the acquirers, it is not a `lock` option), `timeout`, `timed`, `retry_count`, `retry_delay`, `retry_jitter`,
`raise_errors`, `fail_fast`, `conflict_strategy`, `access_strategy`, `priority` (`-100`..`100` or a priority name of `config['lock_priorities']`, default
`config['default_lock_priority']` = `0`, see "Lock request priorities"), `read_write_mode`
(`:write` (default, exclusive) | `:read` (shared)), `identity`, `meta`, `logger`, `log_lock_try`,
`instrumenter`, `instrument`, log/instr sampling options, `log_sample_this`, `instr_sample_this`.

- `access_strategy`: `:queued` (FIFO, default) or `:random`.
- `conflict_strategy` (same process re-acquires its own lock): `:wait_for_lock` (default),
  `:work_through`, `:extendable_work_through`, `:dead_locking`.
- `read_write_mode`: `:write` (default) | `:read`, see "Read/Write locks" below.

### Read/Write locks (`read_write_mode`)

- Semantics: `:write` is exclusive (waits for the write lock and all live read locks); `:read` is
  shared (waits for the write lock only). Default `:write` keeps the classic behavior and keys.
- Safety (no Lua, WATCH/MULTI only): readers WATCH the write lock key; writers WATCH the write lock
  key + readers registry. Readers never invalidate each other; a new reader aborts a concurrent
  writer's EXEC and vice versa. Queues never participate in safety.
- Reader liveness: registry score = expiration in Redis server time (`TIME`, ms); expired members are
  ignored (`score > now`) and pruned on reader acquisition; registry TTL = max reader TTL (`PEXPIRE NX`
  + `PEXPIRE GT` in the same MULTI).
- Ordering (`:queued`): FIFO between modes by `(score, acq_id)`: read waits for earlier write requests;
  write must be the head of the write queue and waits for earlier read requests. Scores are shifted by the priority
  bands (see "Lock request priorities"), so "earlier" means "ahead": a higher priority is ahead in both modes. Every attempt prunes
  dead requests of its priority band in both queues (and the dead requests of other bands that block it). `:random` requests ignore the order of the queues (writers can starve), but they are queued like any request (`:queued` requests wait for them). Ordering is best effort
  (client clocks, `unlock` clears queues); it never affects mutual exclusion.
- Read lock data: `rql:lock_reader:<name>:<acq_id>` HASH with the write-lock format without `acq_id`/`hst_id`
  (`ts`, `ini_ttl`, `meta`, `spc_*` reentrant counters; acquirer and host are derived from the acquirer id and are
  added by `lock_info`/`locks_info` as the first reader fields), TTL = read lock TTL; data carrier only (the
  registry decides existence). Recreated (DEL + HSET) on each read acquisition.
- Reentrancy (same acquirer): read under own write/read lock -> `conflict_strategy` as usual
  (`held_rw_mode` decides which lock is extended/decreased/released); read->write upgrade ->
  `:conflict_lock_upgrade` (`ConflictLockObtainError`) for `:work_through`/`:extendable_work_through`,
  `:conflict_dead_lock` for `:dead_locking`, waits for own read expiration for `:wait_for_lock`.
- `fail_fast`: write fails on write holder or live readers; read fails on write holder (or own live read).
- Try results (internal symbols): `:write_request_is_ahead`, `:read_request_is_ahead`,
  `:read_lock_is_still_acquired`, `:conflict_lock_upgrade`, `:read_lock_is_expired_during_extension`;
  try success result carries internal `rw_mode` (held mode), not exposed in the public `lock` result.
- Validation (`AcquireLock`): `read_write_mode` must be `:read`/`:write`; `ttl` must be a positive
  Integer in both modes (`RedisQueuedLocks::ArgumentError`; write: `PEXPIRE` with a non-positive ttl would
  delete the lock key in the obtaining `MULTI`, read: the reader expiration is computed from it);
  `LockSeriesPoC` checks the series `ttl` the same way before computing the lock ttls (they include
  the retry delay and jitter); `config['default_lock_ttl']` must be positive too; `extend_lock_ttl`
  `milliseconds` must be a positive Integer (a non-positive one would decrease/delete the lock);
  `meta` keys must not be reserved lock data keys, String or Symbol (Symbol keys are written as
  Strings: `Symbol#name`; the same check in `AcquireLock` and `LockSeriesPoC`); the other per-call
  numeric options are validated with the ranges of their config keys (`logic.md#7`): `priority` Integer from
  `Resource::MIN_LOCK_PRIORITY` (-100) to `MAX_LOCK_PRIORITY` (100), `queue_ttl` > 0,
  `timeout`/`retry_count` nil or >= 0, `retry_delay`/`retry_jitter`/`lock_index_grace_period` >= 0
  (`AcquireLock`; `LockSeriesPoC` checks the retry delay/jitter before the lock ttl calculation),
  scan/batch sizes, `dead_ttl`, reindexing `queue_ttl` > 0 (operation modules), `zombie_ttl` and the
  zombie scan sizes > 0 (`Swarm` facade: `SwarmArgumentError`).
- RW-aware operations: `unlock` (write lock + readers + reader data + both queues + the lock index entry (the enabled lock index), same result shape; one release
  `MULTI` that also reads the readers registry, then one `DEL` of the released readers' data only when readers existed:
  1 round trip without readers; trade-off: a released reader that obtains a new read lock in between loses its new data),
  `clear_locks`, `clear_locks_of`/`clear_current_locks` (host derived from acq id via
  `Resource.host_identifier_from_acquirer`), `clear_dead_requests`, `flush_zombies`/`zombie_*`
  (zombie readers reported as their registry key), `locked?`, `queued?`, `lock_info` (read info:
  `'rw_mode' => 'read'`, `'rem_ttl'`, `'readers' => [reader data + rem_ttl]` when no write lock),
  `queue_info` (`'read_lock_queue'`/`'read_queue'` when present), `locks`/`locks_info`, `queues`/`queues_info`;
  write lock info in `lock_info`/`locks_info` has `'lock_key'` and `'rw_mode' => 'write'` (computed on formatting,
  not stored), so `'rw_mode'` is a reserved `meta` key (validated in `AcquireLock` and `LockSeriesPoC`);
  every request in `queue_info`/`queues_info` is `{ 'acq_id', 'score', 'rw_mode' => 'write'|'read' }`
  (`queues_info` derives the mode from the queue key via `Resource.lock_queue_rw_mode`).
- `lock_series` (both modes): one mode per series; `release_lock_series` releases only locks the series
  obtained itself (`process == :lock_obtaining`, reentrant ones are kept) and only the current acquirer's:
  write = compare-and-delete in one transaction per series (`WATCH` the own lock keys + pipelined `HGET acq_id` + `DEL`,
  retried on abort with the keys still owned at the last check), read = `ZREM` + `DEL` reader data. It runs
  after the block and on any failure (exception or `raise_errors: false`), once per failed series.
- Own read lock operations (current acquirer via `current_acquirer_id(identity:)`): `unlock_read` /
  `release_read_lock` (`ZREM` + `DEL` reader data, event `explicit_read_lock_release`, result
  `{ rel_time:, rel_key:, rel_acq_id:, lock_res: }`; `acquirer_id:` (default `nil` => current acquirer;
  when passed, `identity:` is ignored: the acquirer id already contains its identity) releases the read lock of a different acquirer) and `extend_lock_ttl(..., read_write_mode: :read)`
  (`multi(watch: [lock_key])`: extends only a live read lock while no write lock exists, never revives
  an expired one; registry and reader data TTLs via `PEXPIRE NX`+`GT`). `unlock` releases everything.
- `extend_lock_ttl(..., read_write_mode: :read, all_read_locks: true)` (`false` by default, ignored for
  `:write`; non-boolean in `:read` => `ArgumentError`): same `multi(watch: [lock_key])` (registry not
  watched, so concurrent readers don't abort it), `ZRANGE WITHSCORES` snapshot, every live reader gets
  `ZADD XX INCR` + reader data `PEXPIRE NX`+`GT`, registry TTL = longest extended reader;
  `extended_locks_count` = the number of non-nil `ZADD` results (0 => `:async_expire_or_no_lock`).
  `extend_lock_ttl` success result (all modes): `{ ok: true, result: { extended_locks_count: Integer } }`
  (write / own read = 1); failure stays `{ ok: false, result: :async_expire_or_no_lock }`. Internal param order: `read_write_mode, all_read_locks, acquirer_id`.
- Design decisions (release semantics, not limitations to "fix"): read->write upgrade is an error unless
  `:wait_for_lock`; nested reads of one acquirer go through `conflict_strategy` (no hold counting);
  `:random` gives no fairness between modes; cross-host FIFO is best effort; no Lua in the RW path.
- RBS: `Client` types `read_write_mode` as `:read | :write`. Older gem versions ignore readers: all processes must be upgraded
  before read locks are used.

### Lock request priorities (`priority`)

- Option `priority` of `lock`/`lock!`/`lock_series`/`lock_series!` (one value per series): Integer from
  `Resource::MIN_LOCK_PRIORITY` (-100, the lowest) to `Resource::MAX_LOCK_PRIORITY` (100, the highest) or a priority
  name (Symbol, RBS `RQL::lockPriority`), default `config['default_lock_priority']` (0, a name allowed); validated in
  `AcquireLock` (Step 0.1), in `LockSeriesPoC` (before the series: the same check, duplicated like its ttl checks) and by the
  config validators.
- Priority names: `config['lock_priorities']` (Hash Symbol => Integer in the range, default frozen
  `{ lowest: -100, low: -50, normal: 0, high: 50, highest: 100 }`, validated by the config) is read by `Client#lock` /
  `#lock_series` and forwarded as the internal keyword `lock_priorities:` (`AcquireLock`, `LockSeriesPoC`; not a public
  keyword: a client-wide registry); `AcquireLock` Step 0.1 resolves a Symbol `priority` to its Integer
  (`lock_priorities.fetch(priority, priority)`, an unknown name stays a Symbol and fails the range check with
  `ArgumentError`; `LockSeriesPoC` resolves it the same way before the series events), so everything after Step 0.1 (scores,
  logs, events, `queue_info`) sees Integers only; a name in `default_lock_priority` must be a key of `lock_priorities`
  (validators see one value: `Config#prevent_default_priority__unknown_name`, `ConfigValidationError`): `Config#configure`
  checks the pair once after the block (the keys can be assigned in any order; on a failure both keys keep their values from
  before the block, nested blocks: after the outer one), `Config#[]=` checks a direct assignment of either key (out of a
  block) before it is applied.
- Semantics (`:queued`): strict priority, FIFO inside a priority, in both modes (the read and write queues use the same scores);
  orders waiting requests only (no preemption); a `:random` request does not wait for its turn (it ignores the order and the
  priorities of other requests), but it is queued at the position of its priority (`ZADD NX` like any request): `:queued`
  requests wait for it; the obtained lock is never taken away.
- Encoding (`Resource`, the single source of the score layout): position (score) = enqueue time (client `Time.now.to_f`) -
  `priority * Resource::LOCK_PRIORITY_BAND` (2**32 s: bands never overlap until 2106, the priority is decoded by
  `Resource.lock_request_priority(score) = -floor(score / 2**32)`); priority 0 keeps the pre-priority score (old data and old
  clients' default requests are unchanged). `calc_initial_acquirer_position(priority)` encodes, `dead_score_reached?(position,
  priority, queue_ttl)` decodes the enqueue time for the requeue check.
- Liveness (score = order + liveness): dead requests are pruned per band, `ZREMRANGEBYSCORE <queue>
  <Resource.lock_priority_band_floor(p)> <Resource.lock_priority_band_dead_score(now - queue_ttl, p)>` (the floor is `-p * 2**32`
  for every band, inclusive: positions never reach band edges). Head-driven cleanup (the attempt cost does not depend on the
  priority range): `queue_lock_request` prunes the band of the request in both queues before `ZADD NX` and the heads (5 queueing commands, 9
  with the lock index, as before priorities) and reads both heads with scores; `drop_dead_requests_ahead` (Step 2.2 of the attempt
  and of the pre-check, before the obstacle decision, `:queued` only) decodes the band and the enqueue time of the blocking requests
  (the write queue head for writers, the earlier opposite-mode request for both modes) from their scores (`dead_request_priority`)
  and prunes the bands of the dead ones (by the barrier of the current request: its `queue_ttl`) in both queues and re-reads both
  heads in one round trip (one or two bands; a live write queue head stops the removal; `try_lock.dead_request_removed` log per
  dropped request), up to `MAX_DEAD_REQUEST_REMOVALS` (5) round trips per attempt (more dead blocking requests: the next
  attempts); no round trip while the blocking requests are alive or there are none. Any band is decoded (also out of the range:
  newer versions). Dead requests of lower priorities never block: they are dropped by the attempts of their band (or lower),
  `clear_dead_requests`, the queue TTL (enabled lock index) or the swarm. `ClearDeadRequests.drop_dead_requests` (both lookups):
  one round trip reads the batch queues (`ZRANGE 0 -1 WITHSCORES`), one more prunes only the bands whose first request is dead
  (the requests of a band are adjacent and ordered by time), none without dead requests; `processed_queues` of the lock index
  lookup = non-empty queues.
- Infinite positions (`-inf`/`+inf`: manual writes of the queues, RQL never writes them; out of all bands): the decoding never
  raises (`Resource.lock_request_priority`: `-inf` => `MAX_LOCK_PRIORITY`, `+inf` => `MIN_LOCK_PRIORITY`: info results and logs);
  a request at `-inf` is always dead (like before priorities: no enqueue time) and is dropped by its position
  (`ZREMRANGEBYSCORE <queue> -inf -inf`, both queues) when it blocks an attempt (`drop_dead_requests_ahead`, the same round trip)
  and by `clear_dead_requests` (the first requests of the queue); a request at `+inf` is never dead and never ahead of an RQL
  request (kept like before priorities).
- Unchanged by priorities: keys, members (`acq_id`), `ZADD NX`, `ZRANGE 0 0`, the cross-mode `(score, acq_id)` comparison, dequeue,
  `unlock`/`clear_locks` (`-inf..+inf`), swarm (hosts from acquirer ids), lock index.
- Info/observability: `queue_info`/`queues_info` requests have `'priority'` (decoded); every lock acquirement log and event
  carries the Integer `priority` of the request (classic, reentrant: the requested one, they never queue; lock series: the
  priority of the series, resolved and validated by `LockSeriesPoC` before the series events); `log_lock_try` logs that name
  another request carry its decoded priority (`first_priority_in_queue`, `ahead_priority`, `dead_priority`; decoded for logs
  only: gated by `log_sampled && log_lock_try`; `first_priority_in_queue => nil` without the first request).
- Limitations: the priority range is a library constant that bounds the score shift (float precision of the shifted positions:
  ~61 µs at ±100, ~0.5 ms at ±1000; requests of the same priority within this interval are ordered by acquirer ids); mixed
  versions: older clients prune high-priority requests as dead ones (`-inf..now-ttl`) and never prune low-priority ones (always
  behind): the order degrades, no stuck queues, no safety impact (upgrade all processes before using positive priorities; `0` and negative priorities are compatible: older clients keep them behind their own requests and never prune them, the upgraded processes drop the dead ones); strict priority
  can starve lower priorities (bounded by their timeout/retry limits); the handoff is polled (`retry_delay`); dead requests are
  pruned with the pruner's `queue_ttl` (existing behavior: a request that waits longer than the shorter `queue_ttl` of the
  requests of its band or of the requests it blocks is dropped by their attempts and comes back at its old position on its own
  ones (its own `queue_ttl` keeps the position): it loses its place and the advantage of its priority to the requests behind it
  with a shorter `queue_ttl`; README recommends one `queue_ttl` for the lock requests of a lock); dead requests of lower
  priorities can stay in the queues until an attempt of their band (they never block; visible in `queue_info`).

### Redis data layout (`resource.rb`)

| Key | Type | Purpose |
|---|---|---|
| `rql:lock:<name>` | HASH | lock owner + metadata (e.g. `l_spc_ts`, `l_spc_ext_ts` for reentrant cases) |
| `rql:lock_queue:<name>` | ZSET | acquirer queue scored by enqueue time shifted by the priority band (`ts - priority * 2**32`) |
| `rql:lock_readers:<name>` | ZSET | read locks: acquirer id => expiration (Redis `TIME`, ms) |
| `rql:lock_read_queue:<name>` | ZSET | read lock requests (write requests use `rql:lock_queue:<name>`), same scores |
| `rql:lock_reader:<name>:<acq_id>` | HASH | read lock data (same fields as `rql:lock:<name>` incl. meta, without `acq_id`/`hst_id`; data carrier only) |
| `rql:swarm:hsts` | HASH | swarm host heartbeats |
| `rql:index:locks` | ZSET | lock index (the enabled lock index only): lock name => upper bound of the lifetime of all its keys (client time ms + ttl + grace), see "Lock index" |

- Lock request queues have TTL only with the enabled lock index: `PEXPIRE NX` + `GT` with the queue ttl on each queueing (the queue lives as long as its latest request).

- Lock lookup modes of all lock-iterating operations (`locks`/`locks_info`, `queues`/`queues_info`, `keys`, `clear_locks`, `clear_locks_of`/`clear_current_locks`, `clear_dead_requests`, `flush_zombies` and the zombie flusher, `zombie_locks`/`zombie_acquirers`/`zombies_info`), switched by `config['lock_index_enabled']` (client-wide, `false` by default; `Client`/`Swarm` read it and pass it to the modules, the zombie flusher Ractor gets a copy at spawn). Each module keeps both lookups side by side (shared processing in one copy):
  - keyspace (disabled lock index, default): one SCAN pass over `KEY_PATTERN` (or `ALL_LOCK_QUEUES_PATTERN` for queues), keys classified by `Resource.lock_key_family`, per-key commands in pipelined batches collected across SCAN pages (`scan_locks`, `scan_queues`, `each_lock_queue`, `flush_keyspace_zombies`, `each_keyspace_zombie_lock`, inline SCAN branches in `keys`/`clear_locks`/`clear_locks_of`); no lock index commands at all;
  - lock index (enabled): one `ZSCAN` pass over `rql:index:locks` (lock names; names with an expired score are skipped: `Resource.lock_index_score_expired?`, ZSCAN scores are Strings, the `+inf` score of a key without TTL (`"inf"`) never expires) in batches of `scan_size`/`batch_size` lock names collected across ZSCAN pages, the lock keys are derived from the names (`prepare_lock_key`, `prepare_lock_readers`, both queues, reader data via registry members), per-key commands in pipelined batches; the full keyspace is never scanned. Each module has its own copy of the iteration (`each_lock_name_batch`, duplicated on purpose: module independence; `index_locks`, `index_queues`, `flush_lock_index_zombies`, `each_lock_index_zombie_lock`). Info queries check key existence (`EXISTS`); `clear_locks` deletes the keys of a batch with one `DEL` in a `MULTI` with the `ZREM` of the batch names; `clear_locks`/`clear_dead_requests`/`flush_zombies` prune expired names first.
- `reindex_locks`: one SCAN pass over `KEY_PATTERN` (keys classified by `Resource.lock_key_family`) that adds keys without index entries to the lock index; it works regardless of the mode (it is needed after enabling the lock index).
- Acquirer ID: `rql:acq:<pid>/<thread>/<fiber>/<ractor>/<identity>`
- Host ID: `rql:hst:<pid>/<thread>/<ractor>/<identity>` (no fiber)

### Lock index (`Resource::LOCK_INDEX_KEY` = `rql:index:locks`)

- Opt-in: `config['lock_index_enabled']` (`false` by default), a client-wide mode (not a per-call option: one call without the index
  would break the superset invariant). With the disabled lock index nothing below is sent or read (the pre-index behavior: keyspace
  `SCAN` lookups, queues without TTL, `extend_lock_ttl` write = one `EVAL`); the hot path passes `lock_index_enabled` down
  (`AcquireLock` keyword → `TryToLock` positional before `lock_index_grace_period`) and the lock index commands are conditional
  tails of their pipelines/transactions (their replies are never read: the reply positions do not depend on the mode, except the
  reentrant write extension check `result.size == (lock_index_enabled ? 5 : 4)`). All processes sharing a Redis database must use
  the same mode: locks of processes without the index are invisible to the index lookups (enable everywhere, then `reindex_locks`).
- ZSET: member = lock name, score = upper bound of the lifetime of all keys of the lock (write lock, readers registry, both queues;
  reader data is found via the registry) in client time: `Resource.lock_index_time` (epoch ms, `CLOCK_REALTIME`) + key ttl +
  `lock_index_grace_period` (config `lock_index_grace_period`, 60_000 ms; tolerance of client clock skew + network latency).
- Invariant: the index is a superset of the existing lock names (stale names are harmless, a missing name hides a lock from
  lock-iterating operations).
  - every command that creates a lock key is followed by `ZADD GT <now + ttl + grace> <name>` in the same pipeline/transaction,
    after the key command: the request queue in the queueing pipeline (`queue_lock_request`, queue ttl), the lock (write lock /
    registry + reader data) at the end of the obtaining `MULTI` (lock ttl);
  - the obtaining `MULTI` must index the lock itself (atomically): `unlock`/`clear_locks` can drop the name between the queueing and
    the obtaining (`EXPIRE`/`DEL` of an absent lock key does not abort the attempt's `WATCH`); spec `the lock obtaining transaction
    indexes the lock` drops the entry right before the obtaining `MULTI`;
  - every extension of a lock key: `ZADD XX INCR <ms> <name>` in the same transaction (reentrant `:extendable_work_through`, `extend_lock_ttl`
    write (`MULTI { EVAL; ZADD }`), own read, all read locks); `XX`: names without an entry (older versions) are not indexed with a wrong score;
  - the score is never decreased (`GT`; ttl decreases and releases do not touch the index);
  - lock request queues have TTL (`PEXPIRE NX` + `GT` = queue ttl on each queueing): the lifetime of every indexed key is bounded;
  - pruning: `ZREMRANGEBYSCORE <index> -inf <now - 1>` in every queueing pipeline (amortized, no background jobs) and in `flush_zombies`,
    `clear_locks`, `clear_dead_requests`; lock-iterating operations skip names with an expired score (`+inf`: never);
  - removal: only together with the deletion of all indexed keys of the name in one `MULTI` (`unlock`: `ZREM` in the release transaction;
    `clear_locks`: `DEL` of the batch keys + `ZREM` of the batch names); never remove a name while some of its keys can stay (`clear_locks_of`,
    `yield_expire` releases, `flush_zombies` keep the names).
- Migration: keys of older RQL versions and keys created with the disabled lock index have no entries: `reindex_locks` (one SCAN pass:
  `PEXPIRE NX` queue ttl for queues, `PTTL` of locks/registries/queues, `ZADD GT <now + pttl + grace>`; `-1` => `+inf`; idempotent)
  once after the lock index is enabled on all processes. Disabling: the index key is neither used nor maintained (stale, can be deleted).
- Limitations: completeness needs `grace > clock skew + network latency`; one hot key (fine for standalone/Sentinel; Cluster unsupported anyway);
  hot path cost: 4 more commands per attempt in the existing queueing pipeline + 1 in the obtaining `MULTI` (no new round trips);
  index size ~ distinct lock names per second x (max(queue ttl, lock ttl) + grace): lock-iterating operations visit dead names of this window too.

### Instrumentation events

`redis_queued_locks.` + `lock_obtained`, `reentrant_lock_obtained`,
`extendable_reentrant_lock_obtained`, `lock_hold_and_release`, `reentrant_lock_hold_completes`,
`lock_obtaining_failed`, `lock_series_obtained`, `lock_series_hold_and_release`, `explicit_lock_release`,
`explicit_all_locks_release`, `release_locks_of`, `explicit_read_lock_release`, `extend_lock_ttl`, `clear_dead_requests`,
`reindex_locks`. Observability rule (`logic.md#16`): logic that changes keys is logged and instrumented, the lock
acquirement per meaningful outcome (visitors; `lock_obtaining_failed` with the failure `result` also before a raised
acquirement error), each mutation operation with one log line + one event of the whole operation (the same name and data,
`instrument` last in the payload, inline in the module); lock info queries are neither; the swarm is known debt.
Lock events (`lock_obtained`, `reentrant_lock_obtained`, `extendable_reentrant_lock_obtained`,
`lock_hold_and_release`, `reentrant_lock_hold_completes`) carry `rw_mode` (requested mode) in the payload;
lock series events (`lock_series_obtained`, `lock_series_hold_and_release`) carry the mode of the series;
all lock acquirement events (the lock events above, `lock_obtaining_failed` and the lock series events) carry `priority`
after `rw_mode` (the Integer lock request priority: a priority name is resolved before; the series events: the priority of
the series); all lock acquirement log lines of `AcquireLock` and `LockSeriesPoC` (not the release logs of `YieldExpire`)
log `priority => N` after `rw_mode`, `try_lock.acq_added_to_queue` too; the try-lock logs that name another request log
its priority (`first_priority_in_queue` after `first_acq_id_in_queue`, `ahead_priority` after `ahead_acq_id`);
lock log lines (incl. lock series logs) carry `rw_mode => '...'`. RW try-lock log events: `exit__write_request_ahead`,
`exit__read_request_ahead`, `exit__read_lock_still_obtained`, `single_process_lock_conflict__lock_upgrade`. Priorities try-lock
log event: `dead_request_removed` (`dead_acq_id`, `dead_priority`: a dead blocking request of another band was dropped).

### Errors (`errors.rb`)

Global base errors per branch (`logic.md#15`): `RedisQueuedLocks::Error < StandardError` (the main
hierarchy: `LockAlreadyObtainedError`, `LockAcquirementTimeoutError`, `LockAcquirementRetryLimitError`,
`TimedLockTimeoutError`, `ConflictLockObtainError`, `SwarmError`, `ConfigError` (`ConfigNotFoundError`,
`ConfigValidationError`)), `RedisQueuedLocks::ArgumentError < ::ArgumentError` (`SwarmArgumentError`),
`RedisQueuedLocks::Exception < ::Exception` (`@api private`, super exceptional cases only: the internal
`*IntermediateTimeoutError`s of `Timeout.timeout` for `timeout` and `timed`; like `Timeout::ExitException`,
`rescue => e`/`rescue StandardError`/`rescue Timeout::Error`/`rescue nil` of the interrupted code (the user
block, logger and instrumenter calls) can not swallow them; the library converts them to the public errors/results).
redis-client sends `UNWATCH` on an interrupted `multi(watch:)` only for `StandardError`s, so every `with` block
around a `multi(watch:)` (`TryToLock`, `ExtendLockTTL` read extensions, `LockSeriesPoC` write release) rescues
both internal timeouts and `Timeout::ExitException` (the user's `Timeout.timeout` without an exception class), closes
the connection (drops the WATCH state, reconnected on the next use) and re-raises.

---

## 2. Architecture patterns by module

| Module | Patterns |
|---|---|
| `Client` | Facade; constructor injection (caller-supplied `RedisClient`); `x` returns a result hash, `x!` raises |
| `Acquirer::*` | One module per command; stateless `class << self` functions; uniform `{ ok:, result: }` returns (public API contract; swarm element internals use bare scalars/primitives) |
| `AcquireLock` | Composition via `extend` mixins; optimistic concurrency (WATCH/MULTI; asymmetric WATCH for read/write locks) + Lua only for write TTL extension/decrease; strategy options (`access_strategy`, `conflict_strategy`, `read_write_mode`) |
| Log/Instr visitors | Visitor-style event hooks keep observability out of the algorithm; percent sampling via `sampling_happened?(percent)` |
| `Logging` / `Instrument` | Null Object defaults (`VoidLogger`, `VoidNotifier`); Adapter (`instrument/active_support.rb`); duck typing (`::Logger` API, `#notify(event, payload)`) |
| `Config` | Declarative DSL: `setting(key, default)` and `validate(key) { }` registries; access as `config['a.b']`; runtime `Client#configure` |
| `Swarm` | Template base classes `SwarmElement::Threaded` (Thread) and `SwarmElement::Isolated` (Ractor; commands/replies via a per-element pair of `Ractor::Port`s, termination via `Ractor#monitor`). `ProbeHosts < Threaded`; `FlushZombies < Isolated` with its own connection from `RedisClientBuilder` (plain, pooled or sentinel). `Supervisor` watchdog thread restarts dead elements. |
| `Resource` | Single source of truth for key names and identity strings |
| Misc | `Data < Hash` result object; `Utilities::Lock` mutex wrapper; global `Debugger` toggle |

---

## 3. Configuration (`config.rb`)

| Group | Keys (default) |
|---|---|
| Retry/timeouts | `retry_count` (3), `retry_delay` (200 ms), `retry_jitter` (25 ms), `try_to_lock_timeout` (10 s), `is_timed_by_default` (false) |
| TTLs | `default_lock_ttl` (5000 ms), `default_queue_ttl` (15 s), `dead_request_ttl` (1 day, ms) |
| Strategies | `default_conflict_strategy` (`:wait_for_lock`), `default_access_strategy` (`:queued`), `default_lock_priority` (0, from -100 to 100 or a priority name), `lock_priorities` (priority names => Integer priorities) |
| Batching | `lock_release_batch_size` (100), `clear_locks_of__lock_scan_size` / `__queue_scan_size` (300), `key_extraction_batch_size` (500) |
| Lock index | `lock_index_enabled` (false; client-wide mode, config only), `lock_index_grace_period` (60_000 ms; also a `lock`/`lock!`/`lock_series`/`lock_series!`/`reindex_locks` option) |
| Identity | `uniq_identifier` (lambda → `Resource.calc_uniq_identity`) |
| Logging | `logger` (VoidLogger), `log_lock_try`, `log_sampling_enabled`, `log_sampling_percent` (15), `log_sampler` |
| Instrumentation | `instrumenter` (VoidNotifier), `instr_sampling_enabled`, `instr_sampling_percent` (15), `instr_sampler` |
| Errors | `detailed_acq_timeout_error` (false) |
| Swarm | `swarm.auto_swarm` (false), `swarm.supervisor.liveness_probing_period` (2 s), `swarm.probe_hosts.*` (enabled, `probe_period` 2 s, `redis_config.*`), `swarm.flush_zombies.*` (enabled, `zombie_ttl` 15000 ms, scan sizes 500, `zombie_flush_period` 10, `redis_config.*`) |

---

## 4. Directory map

```
lib/redis_queued_locks.rb          entry point
lib/redis_queued_locks/
  client.rb                        public API
  config.rb, config/dsl.rb         settings DSL + defaults
  acquirer/*.rb                    one operation per file
  acquirer/acquire_lock/*          lock algorithm mixins + visitors
  swarm.rb, swarm/*                supervisor, swarm elements, zombie logic, redis client builder
  logging/, instrument/            void defaults, samplers, ActiveSupport adapter
  resource.rb                      keys and identities
  data.rb, errors.rb, utilities.rb, utilities/lock.rb, debugger/, version.rb
sig/                               RBS mirror of lib/ + sig/vendor stubs (redis_client, active_support, semantic_logger)
spec/                              redis_queued_locks_spec.rb (~5.6k lines, integration: shared examples run with both lock lookup modes), redis_queued_locks/config_spec.rb (Redis-free: `Config#[]` RBS table == `setting` registry), spec_helper.rb, setup_simplecov.rb, support/parallel_runner.rb (the `rake rspec:parallel` runner, not a spec)
.github/workflows/                 tests, lint, typecheck-static, typecheck-runtime
bin/console, bin/setup             dev scripts
Rakefile, Steepfile, rbs_collection.yaml
```

---

## 5. Technology stack

### Runtime
- Ruby >= 4.0; stdlib `timeout`, `securerandom`, `logger`; Thread, Fiber, Ractor, Mutex
- Redis server: WATCH/MULTI, EVAL (Lua), ZSET, HASH, PTTL/PEXPIRE (NX/GT: Redis >= 7), SCAN/ZSCAN
- `redis-client ~> 0.20`
- Optional, duck-typed: any `::Logger`-compatible logger; any `#notify(event, payload)` instrumenter (ActiveSupport adapter included; SemanticLogger has only an RBS stub)

### Test / development
- RSpec 3.13: random order, no monkey patching, `expect` syntax, `Thread.abort_on_exception = true`
- rspec-retry 0.6.2: 5 retries per example (marked temporary)
- A real Redis is required (CI: `supercharge/redis-github-action@1.8.1`)
- SimpleCov 1.3.2: line + branch coverage, HTML report; 100% minimum disabled (TODO)
- RBS 4.2 + `rbs collection` + tsort; Steep 2.1 (static); RBS runtime testing via `rbs/test/setup`
- RuboCop 1.91 through `armitage-rubocop`, in two separate runs so Ruby cops (and their rubydex project index, `AllCops/UseProjectIndex`) never see RBS files:
  - `.rubocop.yml`: Ruby sources (general, rake, rspec presets; plugins rubocop-rspec, -performance, -rake, -thread_safety); several Metrics cops disabled
  - `.rubocop.rbs.yml`: RBS cops only (rbs preset, plugin rubocop-on-rbs, no project index): `RBS/*` on `sig/**/*.rbs` and `RBSInline/*` on inline annotations in `lib/**/*.rb`; Ruby cop departments are excluded explicitly because inline `# rubocop:enable` directives would re-enable them despite `DisabledByDefault`
- rake, bundler, pry, pry-doc, reline, activesupport 8.1

### Rake tasks
`rspec` (default), `rspec:parallel` (`spec/support/parallel_runner.rb`, the `Rakefile` only declares the task: the specs in `WORKERS` processes, ~1 min instead of ~6: each worker gets its own pair of Redis databases via `RQL_SPEC_DB_OFFSET` = worker index * 2, prepended to `RedisClient::Config::Common#initialize` in `spec_helper.rb` (the library, swarm and Ractor clients included; after the URL is resolved: the database of a `url:` gets the offset too); examples listed by `rspec --dry-run` and distributed by the durations of the previous runs (`tmp/rspec_parallel/durations.json`, the longest first to the least loaded worker); per-worker logs/JSON in `tmp/rspec_parallel/` (the worker files of the previous run are deleted before the workers start: a worker that dies before RSpec writes its JSON output is reported as broken, never with stale results); coverage: each worker stores only its SimpleCov result in `coverage/parallel/worker-<n>` (`rspec:worker:<n>` command names, no report), the task collates one report into `coverage/` after all workers (`SimpleCov.collate`) and drops the collated resultset (later `rspec` runs don't merge it); the environment is passed to the workers: the RBS runtime checks and `RSPEC_RETRY_RETRY_COUNT` work as with `rspec`), `rubocop` (runs `rubocop:ruby` and `rubocop:rbs`, fails if either fails), `steep:check`, plus bundler gem tasks (`build`, `release`, ...).

### CI (GitHub Actions, ubuntu-latest, Ruby 4.0, on every push)

| Workflow | Command |
|---|---|
| tests | `bundle exec rake rspec:parallel` (with a Redis service; 4 workers on the 4-core runner; `tmp/rspec_parallel/durations.json` restored/saved with `actions/cache` (a new key per run, `restore-keys` prefix) to balance the workers; the worker logs are uploaded as an artifact on failure) |
| lint | `bundle exec rake rubocop` (precompiled native gems: no `BUNDLE_FORCE_RUBY_PLATFORM`, a rubydex 0.4.1 source build on the runner flags constants as `@deprecated` and breaks `Lint/DeprecatedReference`) |
| typecheck-static | `bundle exec rbs collection install && bundle exec rake steep:check -j 10` |
| typecheck-runtime | `RBS_TEST_RAISE=true RUBYOPT='-rbundler/setup -rrbs/test/setup' RBS_TEST_OPT='-I sig' RBS_TEST_TARGET='RedisQueuedLocks::*' RBS_TEST_SKIP='::RedisQueuedLocks::Swarm::FlushZombies,::RedisQueuedLocks::Swarm::SwarmElement::Isolated,::RedisQueuedLocks::Swarm::RedisClientBuilder' bundle exec rspec` (blocking; serial on purpose: the RBS hooks keep a worker on a CPU core, and parallel workers on the runner (4 vCPU = 2 physical cores) starved the timing-sensitive examples: Redis connect timeouts with 4 workers, swarm flush waits with 2; locally `rake rspec:parallel` works for the RBS checks; Ractor-executed methods are skipped: `RBS_TEST_SKIP` + `%a{rbs:test:skip}` in `resource.rbs`/`utilities.rbs`) |

---

## 6. Conventions

- `# frozen_string_literal: true` in every Ruby file.
- YARD tags on every class/method: `@api public|private`, `@since`, `@version` (methods: bump on a behavior/signature change; classes/modules: only on an interface change: signatures, added/removed methods, `extend`/`include`/`prepend` or the superclass; `logic.md#2`).
- Every `lib/` change gets a matching `sig/` RBS update; use `# steep:ignore` only where Steep can't infer types.
- New operation: new `Acquirer::*` module, thin `Client` method (+ `!` variant if it should raise), RBS, spec.
- New config option: `setting` (+ `validate`) in `config.rb` + the typed `Config#[]` overload line in `sig/redis_queued_locks/config.rbs`, read via `config['key']`, document defaults.
- Development gems go in `Gemfile` (`Gemspec/DevelopmentDependencies: Gemfile`), not the gemspec.
- This overview and `.claude/rules/*.md` are updated in the same change as the code (keys, options, results, events, algorithm steps, limitations); README and CHANGELOG `[Unreleased]` for user-visible behavior (log keys and instrumentation payloads: README `## Logging` / `### Instrumentation Events`).
- Temporary debt: rspec-retry, disabled coverage minimum.
- Specs (`spec/**/*_spec.rb`) are not ideal and will be totally reworked (header `NOTE` of `spec/redis_queued_locks_spec.rb`): until then any coding principle may be broken there; code review checks only that the library behavior is covered and that changed expectations are correct (`.claude/skills/rql-code-review`).
