# redis_queued_locks: Project Overview

Ruby gem providing **distributed locks on Redis with a prioritized lock-acquisition queue**.
Each lock has its own request queue; requests are processed FIFO (`:queued`, ordered by the lock request
priority first: `priority` -100..100) or first-come (`:random`). Requests have TTLs (with requeue), so queues never get stuck. Includes read/write
locks, atomic lock series, reentrancy (conflict) strategies, timed locks, retries/fail-fast, an opt-in lock index, logging,
instrumentation with sampling, and a background "swarm" that detects dead hosts and flushes their locks.

- Repo: https://github.com/0exp/redis_queued_locks (MIT); main branch `master`
- Runtime dependency: `redis-client ~> 0.20` (locked 0.31.0), nothing else
- Ruby `>= 4.0` (`.ruby-version` = 4.0.9)

---

## 1. Architecture

```
RedisQueuedLocks (lib/redis_queued_locks.rb)   entry point; requires all parts; extends Debugger::Interface
        │
        ▼
Client (client.rb)                              public API facade
  ├── Config (config.rb + config/dsl.rb)        declarative settings + validators
  ├── Swarm  (swarm.rb + swarm/*)               supervised background workers
  ├── LockKeeper (lock_keeper.rb + lock_keeper/*)  keeps the locks of running blocks alive (`auto_extend`)
  └── Acquirer::* modules                       one stateless module per operation
              │
              ▼
        RedisClient (redis-client gem)          WATCH/MULTI, Lua (EVAL), ZSET, HASH, SCAN

Resource (resource.rb)                          keys, acquirer/host ids, queue score layout (priority bands)
```

`Client.new(redis_client) { |config| ... }`:
1. builds `Config` from the block,
2. computes `uniq_identity` via `config['uniq_identifier']`,
3. creates `LockKeeper` (no thread until the first `auto_extend: true` block),
4. creates `Swarm` and starts it when `config['swarm.auto_swarm']` is true.

Every other public method is a thin wrapper: it fills option defaults from `config[...]` and calls
an `Acquirer::*` module function with `redis_client`.

Operation modules are independent of each other (all `Acquirer::*` except the lock acquisition core:
`AcquireLock` and `LockSeries`, which reuses the `AcquireLock` mixins): no
cross-calls and no shared RBS types; common logic lives in `Resource`/`Utilities`, similar logic is
duplicated on purpose (`Locks` duplicates the `LockInfo` write/read lock formatting, `Queues` the
`QueueInfo` request formatting). Known debt: `AcquireLock::WithAcqTimeout` calls
`LockInfo`/`QueueInfo` for detailed timeout errors.

### Read/Write locks in the architecture

`rw_mode: :write` (default) is the exclusive classic lock (its keys and data are unchanged); `:read` is a shared
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
Client#lock / #lock! (rw_mode:)            #lock_series / #lock_series! (one mode per series),
  │                                                #unlock_read / #release_read_lock, #extend_lock_ttl(rw_mode:,
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
AcquireLock Step 0.1 / LockSeries Step 0.1              name -> Integer, range -100..100 (ArgumentError); Integer only below
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
  ├──▶ ClearDeadRequests                                per-band cleanup of the bands found in the queues (<= 2 round trips/batch;
  │                                                     by_priority: a walk over the first request of each band, the most
  │                                                     bands of a batch queue + 1 round trips, no full queue read)
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
| `lock_series` / `lock_series!` | `acquirer/lock_series.rb` + `acquirer/lock_series/*` (atomic, see "Lock series"; one `rw_mode`, `priority` and `ttl` for the whole series) |
| `auto_extend:` of the four lock methods | `lock_keeper.rb` + `lock_keeper/*` (see "Lock auto extension") |
| `unlock` / `release_lock` | `acquirer/release_lock.rb` |
| `unlock_read` / `release_read_lock` | `acquirer/release_read_lock.rb` (own read lock or `acquirer_id:` read lock only) |
| `extend_lock_ttl` | `acquirer/extend_lock_ttl.rb` (`rw_mode: :read` extends own read lock, `+ all_read_locks: true` all live read locks) |
| `locked?` / `queued?` | `acquirer/is_locked.rb` / `acquirer/is_queued.rb` |
| `lock_info` / `queue_info` | `acquirer/lock_info.rb` / `acquirer/queue_info.rb` |
| `locks`, `locks_info`, `queues`, `queues_info`, `keys` | `acquirer/locks.rb`, `queues.rb`, `keys.rb` (keyspace SCAN or lock index: `lock_index_enabled`) |
| `clear_locks` / `release_locks` | `acquirer/release_all_locks.rb` |
| `clear_locks_of` / `release_locks_of`, `clear_current_locks` / `release_current_locks` | `acquirer/release_locks_of.rb` |
| `clear_dead_requests` | `acquirer/clear_dead_requests.rb` (`by_priority: true` reads the first request of each priority band instead of all requests) |
| `reindex_locks` | `acquirer/reindex_locks.rb` (adds keys without lock index entries to the lock index: one SCAN pass; works in both modes) |
| `current_acquirer_id` (`current_acq_id`, `acq_id`), `current_host_id` (`current_hst_id`, `hst_id`), `possible_host_ids` | `resource.rb` |
| `swarmize!`, `deswarmize!`, `swarm_status` / `swarm_state`, `swarm_info`, `probe_hosts`, `flush_zombies`, `zombie_locks`, `zombie_acquirers`, `zombie_hosts`, `zombies_info` / `zombies` | `swarm.rb` + `swarm/*` |
| `configure` | `config.rb` (`Config#configure`) |

### Lock acquisition flow (`acquirer/acquire_lock.rb` + `acquire_lock/`)

`AcquireLock` is assembled from mixins (`extend`):

| Mixin | Role |
|---|---|
| `TryToLock` (`try_to_lock.rb`) | One attempt: `multi(watch:)` (write: lock key + readers registry, read: lock key only), one pipelined read of the lock state (`HGET acq_id`, `TIME`, own reader score, longest reader: write requests only), the lock request queueing in one pipelined round trip (`queue_lock_request`: prune the priority band of the request in both queues (first: the old dead position of a requeued request is dropped before `ZADD NX` adds its new position), `ZADD NX` into the queue of the requested mode (timestamp score shifted by the priority band, see "Lock request priorities"), both queue heads with scores, then (the enabled lock index only) the lock index commands: request queue `PEXPIRE NX`+`GT` (queue ttl), `ZADD GT` of the lock name into the lock index (queue ttl), `ZREMRANGEBYSCORE` of expired lock names), drop the dead requests of other priority bands that block the request (the write queue head and the earlier opposite-mode request) with their bands in one more round trip that re-reads the heads (`drop_dead_requests_ahead`, Step 2.2, also in the pre-check: up to `MAX_DEAD_REQUEST_REMOVALS` = 5 such round trips per attempt, none while no dead request blocks), take the lock if allowed (see Read/Write locks; with the enabled lock index the obtaining `MULTI` ends with the lock index `ZADD GT` (lock ttl), the `:extendable_work_through` extension `MULTI` with `ZADD XX INCR`). Eager queueing (`:wait_for_lock`/`:dead_locking` without `fail_fast`) sends the queueing commands in the lock state round trip: `lock {}` = 4 round trips (`WATCH`, state + queueing, `MULTI/EXEC`, release), a failed attempt = 3. Pre-check (`precheck_lock`, retries and `fail_fast` attempts): the lock state (+ the queueing for retries) without `WATCH` in one round trip; an attempt that can not obtain the lock fails there (same results and log events in the same order: `lock_obstacle`/`log_lock_obstacle`, the dropped dead requests after the queueing events: `log_dropped_requests`), otherwise the attempt continues with `WATCH`/`MULTI` (a failed retry = 1 round trip, a successful one = 4 + the release; `fail_fast` on an obtained lock = 1); same-process conflicts are never decided by the pre-check. Handles reentrant conflicts (incl. read/write ones); write TTL extension via inline Lua (`PTTL` + `PEXPIRE`). |
| `WithAcqTimeout` | Global acquisition timeout (`timeout`). Its callback (`acq_dequeue` of `acquire_lock`) completes the acquirement when the lock is already obtained (`true`: no timeout error), otherwise releases the lock of an obtaining transaction that Redis can apply without the reply (`acq_process[:lock_obtaining_sent]`, set by `try_to_lock` right before `EXEC`, dropped at the start of each attempt and after a failed one: the same as `drop_failed_lock_series` of the series) and dequeues the request. |
| `DelayExecution` | Retry delay + jitter between attempts. |
| `DequeueFromLockQueue` | Removes the acquirer from the queue of the requested mode on timeout/failure; `release_unconfirmed_lock`: the owner-checked release of the lock of an interrupted obtaining (write: `RELEASE_OWN_LOCK`, read: own `ZREM` + `DEL`; `expire_lock` log). |
| `YieldExpire` | Runs the user block (optionally `timed`: budget = `ttl` - time from the start of the successful attempt - `REDIS_TIMESHIFT_ERROR`, always within the lock lifetime; no budget left => the block is not invoked, `LockTtlTimeBudgetIsSpentError`; the budget exceeded => `TimedBlockExceedsLockTtlError`; `Timeout.timeout(0)` means no timeout; a long `ensure` of the block, `rescue Exception` and non-interruptible code can still outlive the lock; `auto_extend`: the block gets a lease of `LockKeeper` and the budget is `max_hold_time_during_auto_extend`, see "Lock auto extension"), then releases/expires the lock of the held mode (write: `EXPIRE 0`; read: `ZREM` own reader + `DEL` own read lock data; extendable reentrant: decrease). Known limitation (kept by the user's decision, documented in README): without `auto_extend` the write release and the write ttl decrease have no owner check, so a block longer than the ttl can delete/shorten the lock of another acquirer (with a lease: `RELEASE_OWN_LOCK`, `DECREASE_OWN_LOCK_PTTL`). |
| `LogVisitor` / `InstrVisitor` | One method per lifecycle event for logs and instrumentation. |

### Lock auto extension (`lock_keeper.rb`)

`auto_extend: true` (`lock`, `lock!`, `lock_series`, `lock_series!`): the lock ttl is a lease that is extended while the block of code is running. Without a block the option has no effect. The acquirement is the same: the extension concerns an already held lock; `TryToLock`/`TryToLockSeries` only recognize a reentrant attempt that is aborted by a tick (see "Reentrancy" below).

- `RedisQueuedLocks::LockKeeper`: one per `Client` (`client.lock_keeper`, forwarded as the internal keyword `lock_keeper:`, like `lock_priorities:`), one thread `rql.lock_keeper`. No module-level state: a client lives in its Ractor. The only stateful object of the lock path: `Acquirer::*` stay stateless and get it as an argument.
- `LockKeeper::Lease`: one per block of code, not per lock: the block is interrupted once and the hold limit is one for the whole block (a series with several lost locks would get several `Thread#raise`s otherwise, the second one reaches the application as an internal exception); the locks are parallel arrays (the series arrays as is; one-element arrays for `lock`).
- Connection: `redis_client.config.new_client` (own connection, no new settings; plain client, pool, sentinel). The client's `RedisClient` can be one connection: using it from another thread is the issue #10 protocol desync. Not a swarm element: the swarm is opt-in and its `redis_config.*` default to localhost.
- Settings: `config['lock_keeper.*']` (`idle_timeout`, `min_idle_wake_up_interval`, `extension_retry_ratio`, `extension_batching_ratio`, `schedule_slot`, `fiber_interruption_timeout`, `fiber_interruption_wait_step`), the keeper gets the client (`LockKeeper.new(client)`, like `Swarm`) and reads them into its attributes in `load_settings`: at the creation and at each start of the thread (`run_keeper_thread`, under `sync`, followed by `rebuild_schedule`: the slots of the registered leases are recomputed with the new `schedule_slot`; `schedule`/`unschedule` must use one slot length, so the settings never change while the thread runs). A changed setting takes effect at the next start of the thread. `EXTEND_LOCK_LUA_LOST_LOCK_REPLY` stays a constant: it is the reply of the extension scripts.
- Lifecycle: `start` (`AcquireLock`/`LockSeries` Step 1.1, before the lock is obtained: connecting takes several round trips, a slow start under load eats the first lease) → `keep` (in `yield_expire`/`lock_series`, inside the `ensure` scope of the release: an interrupted caller leaves a lease on a released lock, the next tick drops it) → `forget` (before the release: the keeper can not report a released lock as a lost one). The thread starts on demand, stops after `config['lock_keeper.idle_timeout']` (`#idle_timeout`) without new leases (counted from the last `keep`: a short block can end before the thread gets the GVL, so the leases it sees say nothing), and is revived by the next `start`/`keep` (`Thread#alive?`, a new process: `fork` keeps no threads; the leases of the parent are dropped by the pid check: a child never extends the locks of the parent). Without leases the thread keeps waking up each last extension interval, `min_idle_wake_up_interval` at least: `keep` wakes it only for an earlier extension (`@wake_at`), so a stream of short blocks of one ttl costs no context switch per block.
- Tick: leases due now (and in `extension_interval / extension_batching_ratio` of the nearest one) → one pipeline with one `EVAL` per lock; replies by position (one per lock that is not lost). Time is taken before the commands, all deadlines are counted from the start of the successful attempt (`try_start_time`) or of the tick.
- Timer wheel (under `sync`): slots of `schedule_slot` (10 ms) by `next_extension_at` (`@buckets` slot => leases, sorted `@slot_keys`), so the work under the lock does not grow with the number of running blocks (a wake-up with 1k/10k/100k leases: 0.001 ms; the former scan of the registry took 0.04/0.4/13.6 ms and blocked `keep`/`forget`). `keep`/`forget` schedule/unschedule in O(1) (an empty slot stays till its time and is reused by a stream of short blocks: no slot per block; `planned_extension_at` drops empty front slots); `take_due_leases` takes the due slots out, the tick puts the kept leases back in one section (`reschedule`), the membership checks of a tick are one section too; a limit moved by `hold_for` after the tick has found it reached (`stop_hold` → `:moved`) is extended with the others. A new thread rebuilds the schedule from the registry (`rebuild_schedule`: a killed thread can leave the leases of its tick out). The global `sync` stays on purpose: a single owner thread with a queue of leases was tried and rejected (one consumer with its share of the GVL can not drain a stream of blocks; with real locks both designs kept 240/240 extensions under 16-32 churn threads).
- Schedule: the first extension at `max(ttl / 3, ttl - extension_ttl * 2 / 3)` (at once for a reentrant `:work_through` lock and for a series with one: the attempt does not extend it, its remaining ttl is unknown, `keep` gets `0` as the ttl), then each `extension_ttl / 3` (a constant interval: never derive the next tick from the `PTTL` of the reply: a nested `:extendable_work_through` raises the ttl for a moment and takes it back after the nested block, the postponed tick comes after the expiration). `extension_ttl` = `auto_extend_ttl || ttl`.
- Extension semantics: "live `extension_ttl` from now", not "add": `EXTEND_WRITE_LOCK` (`HGET acq_id` owner check, `PEXPIRE GT`, returns `PTTL`), `EXTEND_READ_LOCK` (no write lock, live own reader (`TIME`), `ZADD XX GT`, `PEXPIRE NX`+`GT` of the registry and the reader data). Replies: `-3` = lost (`EXTEND_LOCK_LUA_LOST_LOCK_REPLY`, not a `PTTL` sentinel). A lost lock is never revived. Owner = `acq_id` only (like `release_lock_series`): `ts` of a reentrant result is not the `ts` of the lock; a late tick of a finished block can only extend the next lock of the same acquirer. Lua is not the acquirement path: mutual exclusion stays with `WATCH`/`MULTI`.
- `max_hold_time_during_auto_extend`: the protection against blocks that never finish (hung forever, or abandoned midway: a fiber that is never resumed never runs its `ensure`, its lease stays registered and its lock is extended while the process lives; an exception in the block releases the lock at once); `hold_deadline` = attempt start + limit; `extension_ttl_at` caps an extension by the time left, so the lock expires at the limit, nothing depends on the client (no renewal = expiry). At the deadline the lease is dropped and `lock_hold_limit_reached` is reported (`stop_hold` checks the limit again under `sync`: a limit moved after the partition of the tick is kept, the lease stays due). Validated against `ttl` only with `auto_extend`. The docs mark the option and `config['default_max_hold_time_during_auto_extend']` as **!IMPORTANT** (README: the config, `#lock` and "Lock Auto Extending"; the `Client#lock` YARD; CHANGELOG): the application sets the limit deliberately (`nil` or a period of its logic), the default (1 hour) is only a fallback.
- Lease of the block (`lock_keeper/lock_lease.rb`, `RedisQueuedLocks::LockKeeper::LockLease`, public): the argument of a block of code with parameters (`block.arity != 0`, no object otherwise; rbs/test wraps the blocks of the checked methods, so in the runtime type checks a lambda without parameters gets it too); a facade over the `Lease`, the keeper and the client connection. `hold_for(ms)` → `LockKeeper#hold_for`: under `sync`: lost → `:lock_lost`, stopped → `:hold_limit_reached`, not registered (forgotten, a lease of the parent after `fork`) → `:released`, else the thread is revived and `Lease#hold_until(now + ms)` (never back, no limit stays no limit); then one pipeline of the extension scripts at once through the client connection (the keeper connection belongs to its thread; at once: the last extensions end the lock at the old limit, a tick can come too late), lost replies → `report_lost_lock`, the others → `lock_hold_limit_extended`. `lost?` (local), `hold_time_left`. The deadline is moved by the thread of the block under `sync`; the schedule stays the keeper's.
- Two threads can lose a lock (the tick, `hold_for`): the replies of a pipeline are read by the lock indexes captured before it (`extended_lock_indexes`), `report_lost_lock` reports a lock once and skips an already lost one, a tick does not report the extension of a lock lost meanwhile.
- Lost lock: `auto_extended_lock_lost`, the lock is not extended anymore, other locks of the lease continue. `timed: true`: the block is interrupted with `TimedLockIntermediateTimeoutError` from the keeper thread (under `sync`, once: the lease is dropped; so no list of the WATCH rescues changes), `yield_with_timeout` converts it (`TimedBlockLostLockError` for a lost lease, `TimedBlockExceedsMaxHoldTimeError` for the hold limit). A lock lost by `hold_for` of the `timed` block itself: the error is raised in that thread after the report. The interruption period is limited by `interrupt_timed_block` and `forget`, both inside the `rescue` scope of `yield_with_timeout` (a lease is not interruptible from `keep`: a lock can be lost before the block starts, an interruption there is out of the `rescue` scope and the internal error reaches the application; `interrupt_timed_block` raises it synchronously instead (a lost lock or a stopped hold), the block is not invoked). Interruption targets (set by `interrupt_timed_block`, used by `Lease#interrupt` under `sync`): a blocking fiber → `interrupted_thread` (`Thread#raise`); a non-blocking fiber → `fiber_scheduler` when it responds to `fiber_interrupt` (a Ruby 4.0 hook that may be called by another thread; `Thread#raise` would reach another task, `Fiber#raise` raises `FiberError` across threads); no hook or no scheduler → not interruptible (`Lease#interruptible?` false). `timed_fiber` is set in every mode: `hold_for` of the block itself raises after the report in any fiber, and a non-interruptible block is interrupted by `hold_for` for a lock lost earlier too. A fiber interruption comes at the next suspension point of the fiber and can not be cancelled: `Lease#interrupt` keeps it pending (`@pending_interruption`), `forget(lease, raised_error)` ends the interruption period under `sync` (`timed_fiber` = nil: `hold_for` of a kept lease after the block never raises), takes it and, when the block ended before it came, waits for it inside the `rescue` scope (`wait_for_interruption`: `sleep(fiber_interruption_wait_step)` up to `fiber_interruption_timeout`, 1 s, then gives up: a scheduler that never raises it); `yield_with_timeout` passes the interruption that has come (inner `rescue`) and calls `forget` once more in its outer `rescue` (it can come while `forget` waits for `sync`: the next `forget` calls do not wait). A failing hook clears the pending state (the loss is reported only). An error of another source during the wait stops it (the interruption can come after the block then, like two asynchronous errors in a thread).
- `timed` + `auto_extend`: an interruptible block (a blocking fiber, or a non-blocking one with an interrupting scheduler: `async` >= 2.25): no `Timeout`, `stop_hold` interrupts the block at the hold limit (movable by `hold_for`; a dead keeper thread interrupts nothing till it is revived by the next `keep`/`hold_for`; a fiber scheduler interrupts a CPU-bound block when it yields); a non-blocking fiber without an interrupting scheduler: `Timeout` with the budget `max_hold_time_during_auto_extend` - attempt time (`nil`: no `Timeout`), `hold_for` does not move it. Specs: `async` (dev gem) in `Sync` blocks; a scheduler without the hook: its `fiber_interrupt` is undefined on the singleton class. No budget left: the block is not invoked (`LockTtlTimeBudgetIsSpentError`).
- Failed tick (`StandardError` from the pipeline): `lock_auto_extension_failed` per lock, the next try in `extension_interval / extension_retry_ratio`, the thread stays alive.
- Reentrancy: a nested block with `auto_extend` gets its own lease (no ref counters: two leases of one lock are harmless, `GT` and the owner check make them idempotent). `held_rw_mode` decides the script (a read request under the own write lock extends the write lock). A lease of a series covers its reentrant locks too. A `:work_through` lock (single or in a series) is extended at once: the outer logic can have spent its ttl (see Schedule). A tick changes the watched lock key, so it can abort `EXEC` of a reentrant attempt of the same acquirer (a series: of any attempt with a reentrant lock; `:work_through` of a single lock does not read its result): it is not a failed acquirement, the lock is held. The attempt returns `:reentrant_lock_is_changed_during_extension` (`try_lock.exit__reentrant_lock_is_changed` log) and `acquire_lock`/`lock_series` repeat it at once, Step 2.1.b: no delay, no spent try, no `fail_fast` failure, up to `TryToLock::MAX_REENTRANT_EXTENSION_RETRIES` times; a really lost lock is found by the repeated attempt.
- Limits (measured, README "Lock Auto Extending"): a Ruby thread waits for the GVL and the GC: delay ≈ 110 ms per CPU-bound thread + the longest GVL-holding call; the lock is kept while delay < 2/3 of the extension ttl (`RUBY_THREAD_TIMESLICE` scales it). Redis applies the renewal at the write, a late reply matters only for the next tick. `Thread#priority` and a raw socket (`recv_nonblock`) gave nothing. A sidecar Ractor is immune to the CPU contention but stalls at the GC barrier during long C calls, fails on non-shareable redis-client middlewares (APM) and has no `Thread` access; a helper process is immune but heavy; a presence on a subscribed connection (`PUBSUB NUMSUB`) is a separate idea (no renewals, failover and hot path costs).

### Lock series (`acquirer/lock_series.rb`)

The second part of the lock acquisition core (not an operation module): `LockSeries` extends `TryToLockSeries` (it includes
`AcquireLock::TryToLock` and `ReleaseLockSeries`), `AcquireLock::DelayExecution` and `AcquireLock::YieldExpire` (`yield_with_timeout`).

- Semantics: all or nothing; all locks are obtained by one transaction with the same `ttl` at the same moment; nothing is held while
  the series waits (no hold-and-wait, no ttl staircase); `timeout`, `retry_count`, `queue_ttl` are limits of the whole series; one
  `rw_mode`, `priority`, `ttl`, `meta` per series; lock names: at least one (`ArgumentError`), `uniq(&:to_s)`.
- Deadlock freedom: one `acquirer_position` in all request queues of the series, reset for all queues at once when the dead score is
  reached: all requests of a lock are ordered by `(score, acq_id)` in the same way in all queues, a request waits only for earlier
  requests, so a wait cycle is impossible for any order of the lock names (nested holders of the user's logic are out of it).
- Attempt (`TryToLockSeries#try_to_lock_series`): the single lock attempt for N locks, built from its helpers: `multi(watch: watched_keys)`
  (write: all lock keys + all registries, read: all lock keys) → one pipeline with `pipeline_lock_state` of each lock (`pipeline_series_lock_state`,
  each lock has the same number of replies: `series_lock_state_replies`, read by the `LOCK_STATE_*` constants: `series_lock_states`) →
  conflicts per lock (`same_process_conflict_status`: `:conflict_dead_lock`/`:conflict_lock_upgrade` fail the series, work through locks are
  not queued and not obtained) → fail-fast check → the queueing of the other locks (eager queueing or `queue_series_lock_requests`) →
  `drop_series_dead_requests_ahead` (batch Step 2.2: one round trip for all locks, up to `MAX_DEAD_REQUEST_REMOVALS`, none while nothing dead
  blocks) → `find_series_lock_obstacle` (the first obstacle in the order of the lock names, `lock_obstacle` per lock) → one `MULTI`:
  (transaction layout) read lock extensions first (`READ_LOCK_EXTENSION_COMMANDS` + 1 with the lock index, `ZADD XX INCR` first: its `nil` reply =
  expired during the extension, the transaction is applied and can not be rolled back: the series releases its locks and fails the
  attempt with `:read_lock_is_expired_during_extension`), then the commands of the other locks (`transact_*` helpers of `TryToLock`, shared with the single lock attempt;
  reentrant locks also `ZREM` their request: the pre-check of a retry queues all locks).
- Pre-check (`precheck_lock_series`): retries and `fail_fast`, the lock state of all locks without `WATCH` in one round trip (with the queueing
  for retries); a same-process conflict of any lock continues the attempt (no decision), an obstacle fails it; never obtains locks.
- Round trips (any number of locks): obtained series with a block: write = 6 (`WATCH`, state + queueing, `MULTI/EXEC`, release: `WATCH`, owners,
  `MULTI/EXEC`), read = 4; failed attempt = 3; failed retry = 1 (pre-check); `fail_fast` on an obtained lock = 1; the dequeue of a failed series = 1.
- Failures: `drop_failed_lock_series` runs in `ensure` for every series that is not obtained (a failure, the `timeout`, `Timeout.timeout` of the
  outer logic, Redis errors, `Thread#kill`): best effort (`run_non_critical`, never replaces the original error): the locks of the obtaining
  transaction whose reply is lost (`acq_process[:lock_processes]`, set before `EXEC`: owner-checked release of the `:lock_obtaining` locks) and the
  requests in all queues (one pipeline of `ZREM`, except `:fail_fast_no_try`: nothing is queued). The result is built after it, in one place
  (`lock_series_obtaining_failed` log + event, then `raise_lock_series_error` with `raise_errors` or the failure result). Both releases go through
  `complete_lock_series_release`: an interrupted release is repeated once (`ensure`, `run_non_critical`: an interruption is delivered once, the release is idempotent). All of it is best
  effort: an interruption right at the entry of `ensure`, a second interruption or a dead process leave the locks till their ttl (the safe direction).
- Release (`ReleaseLockSeries#release_lock_series`): by `lock_processes` and `held_rw_modes`: `:lock_obtaining` write locks: compare-and-delete in
  one transaction (`WATCH` own keys + pipelined `HGET acq_id` + `DEL`, retried on abort with the keys still owned), read locks: `ZREM` + `DEL` of
  the reader data; `:extendable_conflict_work_through`: the ttl is decreased by `ttl - spent time - REDIS_TIMESHIFT_ERROR` (write: `EVAL DECREASE_LOCK_PTTL`
  in the same owner-checked transaction, read: `ZADD XX INCR`); `:conflict_work_through` locks are kept as is.
- Results: with a block: the block result; without: `{ ok: true, result: { lock_series:, rql_lock_series:, acq_id:, hst_id:, ts:, ttl: } }`;
  `detailed_result: true`: `yield_result`, `locks_release_strategy`, `locks_released_at`, `locks_acq_time`, `locks_hold_time`, `lock_series`, `rql_lock_series`;
  failure: `{ ok: false, result: { error: :failed_to_acquire_lock_series, detailed_errors:, lock_series:, acquired_locks: [], missing_locks:, failed_on_lock: } }`
  (`failed_on_lock`: the first lock that blocked the last attempt with a known lock, `nil` without such an attempt).
- Observability (`logic.md#16`, `visitors.md`): the `AcquireLock` events are not raised, the series has its own events, with the series context in their names:
  of the series: `lock_series_obtained`, `lock_series_hold_and_release`, `lock_series_obtaining_failed`; of each lock (`lock_key` + `lock_keys`):
  `lock_series_intermediate_lock_obtained` (the lock passed all checks of an attempt: `ready_locks` of the attempt, added by `find_series_lock_obstacle`, reported by
  `lock_series` out of the WATCH block; nothing is held; once per lock, never per attempt: `reported_ready_locks`; in the order of the lock names up to the blocking lock, so a failed
  attempt shows the same picture as the old sequential series; a failed conflict or `fail_fast` check reports nothing: these attempts fail before the checks), `lock_series_lock_obtained` (after the
  transaction is applied, before `lock_series_obtained`, `:lock_obtaining` locks only), `lock_series_lock_obtaining_failed` (the blocking lock, once per failed series, before
  `lock_series_obtaining_failed`; not raised without a known blocking lock). `log_lock_try` logs of each attempt are the `try_lock.*` logs of `TryToLock::LogVisitor`, one per lock
  (per the blocking lock for the exit events); the detailed timeout error reads the raw state of the blocking lock (`blocking_lock_details`: no dependency on `LockInfo`/`QueueInfo`).
- Design decisions: a waiting series reserves its turn in the queues of its free locks (`:queued`: these locks stay free, new requests wait for the
  series, bounded by its limits); `:random` needs all locks free at the same moment; a retry of a series with a reentrant lock has no one round
  trip failure (the attempt decides conflicts); no Lua (WATCH/MULTI only).

### Main `lock` options (defaults from config)

`ttl`, `queue_ttl`, `lock_index_grace_period` (used with the enabled lock index only; the mode itself, `config['lock_index_enabled']`,
is client-wide: `Client` passes it to the acquirers, it is not a `lock` option), `timeout`, `timed`, `auto_extend`, `auto_extend_ttl`, `max_hold_time_during_auto_extend`
(see "Lock auto extension"), `retry_count`, `retry_delay`, `retry_jitter`,
`raise_errors`, `fail_fast`, `conflict_strategy`, `access_strategy`, `priority` (`-100`..`100` or a priority name of `config['lock_priorities']`, default
`config['default_lock_priority']` = `0`, see "Lock request priorities"), `rw_mode`
(`:write` (default, exclusive) | `:read` (shared)), `identity`, `meta`, `detailed_acq_timeout_error`, `logger`, `log_lock_try`,
`instrumenter`, `instrument`, log/instr sampling options, `log_sample_this`, `instr_sample_this`.

- `access_strategy`: `:queued` (FIFO, default) or `:random`.
- `conflict_strategy` (same process re-acquires its own lock): `:wait_for_lock` (default),
  `:work_through`, `:extendable_work_through`, `:dead_locking`.
- `rw_mode`: `:write` (default) | `:read`, see "Read/Write locks" below.

### Read/Write locks (`rw_mode`)

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
  `:read_lock_is_still_acquired`, `:conflict_lock_upgrade`, `:read_lock_is_expired_during_extension`,
  `:reentrant_lock_is_changed_during_extension` (see "Lock auto extension");
  try success result carries internal `rw_mode` (held mode), not exposed in the public `lock` result.
- Validation (`AcquireLock`): `rw_mode` must be `:read`/`:write`; `ttl` must be a positive
  Integer in both modes (`RedisQueuedLocks::ArgumentError`; write: `PEXPIRE` with a non-positive ttl would
  delete the lock key in the obtaining `MULTI`, read: the reader expiration is computed from it);
  `LockSeries` checks the same arguments itself (duplicated on purpose); `config['default_lock_ttl']` must be positive too; `extend_lock_ttl`
  `milliseconds` must be a positive Integer (a non-positive one would decrease/delete the lock);
  `meta` keys must not be reserved lock data keys, String or Symbol (Symbol keys are written as
  Strings: `Symbol#name`; the same check in `AcquireLock` and `LockSeries`); the other per-call
  numeric options are validated with the ranges of their config keys (`logic.md#7`): `priority` Integer from
  `Resource::MIN_LOCK_PRIORITY` (-100) to `MAX_LOCK_PRIORITY` (100), `queue_ttl` > 0,
  `timeout`/`retry_count` nil or >= 0, `retry_delay`/`retry_jitter`/`lock_index_grace_period` >= 0
  (`AcquireLock`, `LockSeries`),
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
  not stored), so `'rw_mode'` is a reserved `meta` key (validated in `AcquireLock` and `LockSeries`);
  every request in `queue_info`/`queues_info` is `{ 'acq_id', 'score', 'rw_mode' => 'write'|'read' }`
  (`queues_info` derives the mode from the queue key via `Resource.lock_queue_rw_mode`).
- `lock_series` (both modes): one mode per series, see "Lock series".
- Own read lock operations (current acquirer via `current_acquirer_id(identity:)`): `unlock_read` /
  `release_read_lock` (`ZREM` + `DEL` reader data, event `explicit_read_lock_release`, result
  `{ rel_time:, rel_key:, rel_acq_id:, lock_res: }`; `acquirer_id:` (default `nil` => current acquirer;
  when passed, `identity:` is ignored: the acquirer id already contains its identity) releases the read lock of a different acquirer) and `extend_lock_ttl(..., rw_mode: :read)`
  (`multi(watch: [lock_key])`: extends only a live read lock while no write lock exists, never revives
  an expired one; registry and reader data TTLs via `PEXPIRE NX`+`GT`). `unlock` releases everything.
- `extend_lock_ttl(..., rw_mode: :read, all_read_locks: true)` (`false` by default, ignored for
  `:write`; non-boolean in `:read` => `ArgumentError`): same `multi(watch: [lock_key])` (registry not
  watched, so concurrent readers don't abort it), `ZRANGE WITHSCORES` snapshot, every live reader gets
  `ZADD XX INCR` + reader data `PEXPIRE NX`+`GT`, registry TTL = longest extended reader;
  `extended_locks_count` = the number of non-nil `ZADD` results (0 => `:async_expire_or_no_lock`).
  `extend_lock_ttl` success result (all modes): `{ ok: true, result: { extended_locks_count: Integer } }`
  (write / own read = 1); failure stays `{ ok: false, result: :async_expire_or_no_lock }`. Internal param order: `rw_mode, all_read_locks, acquirer_id`.
- Design decisions (release semantics, not limitations to "fix"): read->write upgrade is an error unless
  `:wait_for_lock`; nested reads of one acquirer go through `conflict_strategy` (no hold counting);
  `:random` gives no fairness between modes; cross-host FIFO is best effort; no Lua in the RW path.
- RBS: `Client` types `rw_mode` as `RQL::readWriteMode` (`:read | :write`). Older gem versions ignore readers: all processes must be upgraded
  before read locks are used.

### Lock request priorities (`priority`)

- Option `priority` of `lock`/`lock!`/`lock_series`/`lock_series!` (one value per series): Integer from
  `Resource::MIN_LOCK_PRIORITY` (-100, the lowest) to `Resource::MAX_LOCK_PRIORITY` (100, the highest) or a priority
  name (Symbol, RBS `RQL::lockPriority`), default `config['default_lock_priority']` (0, a name allowed); validated in
  `AcquireLock` (Step 0.1), in `LockSeries` (Step 0.1: the same check, duplicated like its ttl checks) and by the
  config validators.
- Priority names: `config['lock_priorities']` (Hash Symbol => Integer in the range, default frozen
  `{ lowest: -100, low: -50, normal: 0, high: 50, highest: 100 }`, validated by the config) is read by `Client#lock` /
  `#lock_series` and forwarded as the internal keyword `lock_priorities:` (`AcquireLock`, `LockSeries`; not a public
  keyword: a client-wide registry); `AcquireLock` Step 0.1 resolves a Symbol `priority` to its Integer
  (`lock_priorities.fetch(priority, priority)`, an unknown name stays a Symbol and fails the range check with
  `ArgumentError`; `LockSeries` resolves it the same way), so everything after Step 0.1 (scores,
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
  lookup = non-empty queues. `clear_dead_requests(by_priority: true)` (`false` by default; `drop_dead_requests_by_priority`)
  never reads a whole queue: a walk over the bands, each round trip reads the first request of the next band of each walked
  queue (`ZRANGE <queue> <bound> +inf BYSCORE LIMIT 0 1 WITHSCORES`, from `-inf`, the next bound is
  `lock_priority_band_floor(p - 1)`) and prunes the dead bands found by the previous one (the same removal commands, after the
  reads); a queue is walked till a read finds nothing: the most bands of a batch queue + 1 round trips per batch, with or
  without dead requests, the transfer depends on the bands, not on the requests (for long queues with few priorities);
  `-inf` requests are dropped by their position (the walk goes on with `(-inf`), the walk of a queue stops at `+inf`; a
  position out of the float precision of the band edges (manual writes) is passed with an exclusive bound (`(<position>`:
  the next band edge rounds to the position itself); `processed_queues` of the lock index lookup = the queues with a first
  request (non-empty).
- Design decision (the user's): the queue score is the only order and liveness of a lock request. A separate liveness registry
  (the deadlines of the requests in another key next to the queues) was considered and rejected: a new key family for the lock
  index, reindexing, release and zombie paths, more commands per attempt; the dead requests of other bands are dropped by the
  head-driven removal, the attempts of their band and `clear_dead_requests` (see Limitations).
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
  priority of the series); `log_lock_try` logs that name
  another request carry its decoded priority (`first_priority_in_queue`, `ahead_priority`, `dead_priority`; decoded for logs
  only: gated by `log_sampled && log_lock_try`, `TryToLock#logged_request_priority`; `first_priority_in_queue => nil` without the first request).
- Limitations: the priority range is a library constant that bounds the score shift (float precision of the shifted positions:
  ~61 µs at ±100, ~0.5 ms at ±1000; requests of the same priority within this interval are ordered by acquirer ids); mixed
  versions: older clients prune high-priority requests as dead ones (`-inf..now-ttl`) and never prune low-priority ones (always
  behind): the order degrades, no stuck queues, no safety impact (upgrade all processes before using positive priorities; `0` and negative priorities are compatible: older clients keep them behind their own requests and never prune them, the upgraded processes drop the dead ones); strict priority
  can starve lower priorities (bounded by their timeout/retry limits); the handoff is polled (`retry_delay`); dead requests are
  pruned with the pruner's `queue_ttl` (existing behavior: a request that waits longer than the shorter `queue_ttl` of the
  requests of its band or of the requests it blocks is dropped by their attempts and comes back at its old position on its own
  ones (its own `queue_ttl` keeps the position): it loses its place and the advantage of its priority to the requests behind it
  with a shorter `queue_ttl`; README recommends one `queue_ttl` for the lock requests of a lock); dead requests of lower
  priorities can stay in the queues until an attempt of their band (they never block; visible in `queue_info`; an accepted
  trade-off of the head-driven cleanup: README recommends a periodic `clear_dead_requests` without the lock index and the swarm).

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
    the lock keeper sets an absolute lifetime, so its scripts use `ZADD XX GT <now + extension ttl + grace> <name>` after the owner check (`KEYS[2]`/`KEYS[4]`, sent with the enabled lock index only);
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
`lock_obtaining_failed`, `lock_series_intermediate_lock_obtained`, `lock_series_lock_obtained`, `lock_series_lock_obtaining_failed`, `lock_series_obtained`,
`lock_series_hold_and_release`, `lock_series_obtaining_failed`, `lock_auto_extended`, `lock_auto_extension_failed`, `auto_extended_lock_lost`, `lock_hold_limit_reached`, `lock_hold_limit_extended`, `explicit_lock_release`,
`explicit_all_locks_release`, `release_locks_of`, `explicit_read_lock_release`, `extend_lock_ttl`, `clear_dead_requests`,
`reindex_locks`. Observability rule (`logic.md#16`): logic that changes keys is logged and instrumented, the lock
acquirement per meaningful outcome (visitors; `lock_obtaining_failed` with the failure `result` also before a raised
acquirement error), each mutation operation with one log line + one event of the whole operation (the same name and data,
`instrument` last in the payload, inline in the module); lock info queries are neither; the swarm is known debt.
Lock events (`lock_obtained`, `reentrant_lock_obtained`, `extendable_reentrant_lock_obtained`,
`lock_hold_and_release`, `reentrant_lock_hold_completes`) carry `rw_mode` (requested mode) in the payload;
lock series events (`lock_series_*`) carry the mode of the series (`lock_series_obtained` and `lock_series_hold_and_release` also `reentrant_lock_keys`,
`lock_series_obtaining_failed` `result` and `failed_lock_key`, the events of each lock `lock_key` and `lock_keys`, `lock_series_lock_obtaining_failed` `result`),
the `AcquireLock` events are not raised for the locks of a series;
all lock acquirement events (the lock events above, `lock_obtaining_failed` and the lock series events) carry `priority`
after `rw_mode` (the Integer lock request priority: a priority name is resolved before; the series events: the priority of
the series); all lock acquirement log lines of `AcquireLock` and `LockSeries` (not the release logs of `YieldExpire`)
log `priority => N` after `rw_mode`, `try_lock.acq_added_to_queue` too; the try-lock logs that name another request log
its priority (`first_priority_in_queue` after `first_acq_id_in_queue`, `ahead_priority` after `ahead_acq_id`);
lock log lines (incl. lock series logs) carry `rw_mode => '...'`. RW try-lock log events: `exit__write_request_ahead`,
`exit__read_request_ahead`, `exit__read_lock_still_obtained`, `single_process_lock_conflict__lock_upgrade`. Priorities try-lock
log event: `dead_request_removed` (`dead_acq_id`, `dead_priority`: a dead blocking request of another band was dropped).
Lock auto extension events and logs are raised by the keeper thread through `LockKeeper::LogVisitor`/`InstrVisitor`, one per lock (`rw_mode` = held mode), with the sampling of the lock acquirement (`at` is computed by the visitor after the sampling guard).

### Errors (`errors.rb`)

Global base errors per branch (`logic.md#15`): `RedisQueuedLocks::Error < StandardError` (the main
hierarchy: `LockAlreadyObtainedError`, `LockAcquirementTimeoutError`, `LockAcquirementRetryLimitError`,
`TimedLockTimeoutError` (`LockTtlTimeBudgetIsSpentError`, `TimedBlockExceedsLockTtlError`, `TimedBlockExceedsMaxHoldTimeError`, `TimedBlockLostLockError`), `ConflictLockObtainError`, `SwarmError` (never raised now: public, kept for compatibility: `rescue` of the applications), `ConfigError` (`ConfigNotFoundError`,
`ConfigValidationError`)), `RedisQueuedLocks::ArgumentError < ::ArgumentError` (`SwarmArgumentError`),
`RedisQueuedLocks::Exception < ::Exception` (`@api private`, super exceptional cases only: the internal
`*IntermediateTimeoutError`s of `Timeout.timeout` for `timeout` and `timed`; like `Timeout::ExitException`,
`rescue => e`/`rescue StandardError`/`rescue Timeout::Error`/`rescue nil` of the interrupted code (the user
block, logger and instrumenter calls) can not swallow them; the library converts them to the public errors/results).
redis-client sends `UNWATCH` on an interrupted `multi(watch:)` only for `StandardError`s, so every `with` block
around a `multi(watch:)` (`TryToLock`, `TryToLockSeries`, `ExtendLockTTL` read extensions, `ReleaseLockSeries` write release) rescues
both internal timeouts and `Timeout::ExitException` (the user's `Timeout.timeout` without an exception class), closes
the connection (drops the WATCH state, reconnected on the next use) and re-raises.

---

## 2. Architecture patterns by module

| Module | Patterns |
|---|---|
| `Client` | Facade; constructor injection (caller-supplied `RedisClient`); `x` returns a result hash, `x!` raises |
| `Acquirer::*` | One module per command; stateless `class << self` functions; uniform `{ ok:, result: }` returns (public API contract; swarm element internals use bare scalars/primitives) |
| `AcquireLock` | Composition via `extend` mixins; optimistic concurrency (WATCH/MULTI; asymmetric WATCH for read/write locks) + Lua only for write TTL extension/decrease and the owner-checked operations of a lease (the release and the decrease, `LockKeeper` extensions: not the acquirement); strategy options (`access_strategy`, `conflict_strategy`, `rw_mode`) |
| Log/Instr visitors | Visitor-style event hooks keep observability out of the algorithm; percent sampling via `sampling_happened?(percent)` |
| `Logging` / `Instrument` | Null Object defaults (`VoidLogger`, `VoidNotifier`); Adapter (`instrument/active_support.rb`); duck typing (`::Logger` API, `#notify(event, payload)`) |
| `Config` | Declarative DSL: `setting(key, default)` and `validate(key) { }` registries; access as `config['a.b']`; runtime `Client#configure` |
| `Swarm` | Template base classes `SwarmElement::Threaded` (Thread) and `SwarmElement::Isolated` (Ractor; commands/replies via a per-element pair of `Ractor::Port`s, termination via `Ractor#monitor`). `ProbeHosts < Threaded`; `FlushZombies < Isolated` with its own connection from `RedisClientBuilder` (plain, pooled or sentinel). `Supervisor` watchdog thread restarts dead elements. |
| `Resource` | Single source of truth for key names and identity strings |
| `LockKeeper` | One background thread per client (lazy, revived on demand, fork-aware), `Lease` per block of code, own connection, Lua with an owner check; no supervisor: `start`/`keep` revive it |
| Misc | `Data < Hash` result object; `Utilities::Lock` `Monitor` wrapper (reentrant); global `Debugger` toggle |

---

## 3. Configuration (`config.rb`)

| Group | Keys (default) |
|---|---|
| Retry/timeouts | `retry_count` (3), `retry_delay` (200 ms), `retry_jitter` (25 ms), `try_to_lock_timeout` (10 s), `is_timed_by_default` (false) |
| Lock auto extension | `is_auto_extended_by_default` (false), `default_auto_extend_ttl` (nil: the lock ttl, ms), `default_max_hold_time_during_auto_extend` (3_600_000 ms, nil: no limit) |
| TTLs | `default_lock_ttl` (5000 ms), `default_queue_ttl` (15 s), `dead_request_ttl` (1 day, ms) |
| Strategies | `default_conflict_strategy` (`:wait_for_lock`), `default_access_strategy` (`:queued`), `default_lock_priority` (0, from -100 to 100 or a priority name), `lock_priorities` (priority names => Integer priorities) |
| Batching | `lock_release_batch_size` (100), `clear_locks_of__lock_scan_size` / `__queue_scan_size` (300), `key_extraction_batch_size` (500) |
| Lock index | `lock_index_enabled` (false; client-wide mode, config only), `lock_index_grace_period` (60_000 ms; also a `lock`/`lock!`/`lock_series`/`lock_series!`/`reindex_locks` option) |
| Lock keeper | `lock_keeper.idle_timeout` (60_000 ms), `lock_keeper.min_idle_wake_up_interval` (100 ms), `lock_keeper.extension_retry_ratio` (3), `lock_keeper.extension_batching_ratio` (10), `lock_keeper.schedule_slot` (10 ms), `lock_keeper.fiber_interruption_timeout` (1_000 ms), `lock_keeper.fiber_interruption_wait_step` (0.001 s): read when the keeper thread starts (see "Lock auto extension") |
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
  acquirer/lock_series/*           lock series attempt and release mixins + visitors
  lock_keeper.rb, lock_keeper/*    lock auto extension: keeper thread, leases, visitors
  swarm.rb, swarm/*                supervisor, swarm elements, zombie logic, redis client builder
  logging/, instrument/            void defaults, samplers, ActiveSupport adapter
  resource.rb                      keys and identities
  data.rb, errors.rb, utilities.rb, utilities/lock.rb, debugger/, version.rb
sig/                               RBS mirror of lib/ + sig/vendor stubs (redis_client, active_support, semantic_logger), manifest.yml (dependencies of the signatures)
spec/                              redis_queued_locks_spec.rb (~10.5k lines, integration: shared examples run with both lock lookup modes), redis_queued_locks/config_spec.rb (Redis-free: `Config#[]` RBS table == `setting` registry), spec_helper.rb, setup_simplecov.rb, support/parallel_runner.rb (the `rake rspec:parallel` runner, not a spec)
.github/workflows/                 tests, lint, typecheck-static, typecheck-runtime
.claude/                           this overview, rules/*.md (path-scoped rules), settings.json (shared Claude Code settings: the ruby-lsp plugin of the `LSP` tool, rules/code-navigation.md), skills/rql-code-review (review of the changes), skills/rql-project-full-review (full audit of the repository, on request)
bin/console, bin/setup             dev scripts
Rakefile, Steepfile, rbs_collection.yaml, .rubocop.yml, .rubocop.rbs.yml
```

---

## 5. Technology stack

### Runtime
- Ruby >= 4.0; stdlib `timeout`, `securerandom`, `logger`, `monitor`; Thread, Fiber, Ractor, Monitor
- Redis server `>= 7`, `~> 8.x`, protocol RESP3 (README "Requirements"): WATCH/MULTI, EVAL (Lua), ZSET, HASH, PTTL/PEXPIRE (NX/GT: Redis >= 7), SCAN/ZSCAN
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
- ruby-lsp 0.26 (`Gemfile`): the language server of the Claude Code `LSP` tool (the `ruby-lsp` plugin enabled in `.claude/settings.json`; usage rules: `.claude/rules/code-navigation.md`)

### Rake tasks
`rspec` (default), `rspec:parallel` (`spec/support/parallel_runner.rb`, the `Rakefile` only declares the task, optional `rspec:parallel[<paths>]`: the specs in `WORKERS` processes, ~1 min instead of ~6: each worker gets its own pair of Redis databases via `RQL_SPEC_DB_OFFSET` = worker index * 2, prepended to `RedisClient::Config::Common#initialize` in `spec_helper.rb` (the library, swarm and Ractor clients included; after the URL is resolved: the database of a `url:` gets the offset too); examples listed by `rspec --dry-run` and distributed by the durations of the previous runs (`tmp/rspec_parallel/durations.json`, `durations-rbs.json` under the RBS runtime checks; the longest first to the least loaded worker, examples without a recorded duration count as the median one); per-worker logs/JSON in `tmp/rspec_parallel/` (the worker files of the previous run are deleted before the workers start: a worker that dies before RSpec writes its JSON output is reported as broken, never with stale results); coverage: each worker stores only its SimpleCov result in `coverage/parallel/worker-<n>` (`rspec:worker:<n>` command names, no report), the task collates one report into `coverage/` after all workers (`SimpleCov.collate`) and drops the collated resultset (later `rspec` runs don't merge it); the environment is passed to the workers: the RBS runtime checks and `RSPEC_RETRY_RETRY_COUNT` work as with `rspec`), `rubocop` (runs `rubocop:ruby` and `rubocop:rbs`, fails if either fails), `steep:check`, plus bundler gem tasks (`build`, `release`, ...).

### CI (GitHub Actions, ubuntu-latest, Ruby 4.0, on every push except gem docs-only pushes)

All workflows skip a push that changes only the gem documentation files (`paths-ignore`: `README.md`, `CHANGELOG.md`, `CODE_OF_CONDUCT.md`, `LICENSE.txt`); a push with any other file runs all of them. `master` has no required status checks, so a skipped run never blocks a merge (required checks would need a workaround: a skipped workflow stays pending).

| Workflow | Command |
|---|---|
| tests | `bundle exec rake rspec:parallel` (with a Redis service; 4 workers on the 4-core runner; `tmp/rspec_parallel/durations.json` restored/saved with `actions/cache` (a new key per run, `restore-keys` prefix) to balance the workers; the worker logs are uploaded as an artifact on failure; `timeout-minutes: 15`: a hung example fails the job instead of holding the runner for the default 6 hours) |
| lint | `bundle exec rake rubocop` (precompiled native gems: no `BUNDLE_FORCE_RUBY_PLATFORM`, a rubydex 0.4.1 source build on the runner flags constants as `@deprecated` and breaks `Lint/DeprecatedReference`) |
| typecheck-static | `bundle exec rbs collection install && bundle exec rake steep:check -j 10` |
| typecheck-runtime | `bundle exec rbs collection install && RBS_TEST_RAISE=true RUBYOPT='-rbundler/setup -rrbs/test/setup' RBS_TEST_OPT='-I sig' RBS_TEST_LOGLEVEL=error RBS_TEST_TARGET='RedisQueuedLocks::*' RBS_TEST_SKIP='::RedisQueuedLocks::Swarm::FlushZombies,::RedisQueuedLocks::Swarm::SwarmElement::Isolated,::RedisQueuedLocks::Swarm::RedisClientBuilder' bundle exec rake rspec:parallel` (blocking; parallel as tests: 4 workers, `tmp/rspec_parallel/durations-rbs.json` cached with its own `rspec-rbs-durations-` keys, the worker logs uploaded on failure; `RUBY_TCP_NO_FAST_FALLBACK=1` in the job env: no resolver threads per Redis connection (on a shared CPU they stretched the connection storm of the specs past its connect timeout and raced the closed resolution pipe, `Thread.abort_on_exception` turns either into a dead worker); serial until the runtime checks got cheaper (`Config#config_state` skip, 10 rounds of the sampling examples): the RBS hooks kept the workers on the CPU, and parallel workers on the runner (4 vCPU = 2 physical cores) starved the timing-sensitive examples: Redis connect timeouts with 4 workers, swarm flush waits with 2; Ractor-executed methods are skipped: `RBS_TEST_SKIP` + `%a{rbs:test:skip}` in `resource.rbs`/`utilities.rbs`; `Config#config_state` is skipped for speed (`config.rbs`, `type-checking.md#15`); gems come from the `bundler-cache` of `ruby/setup-ruby` as in the other jobs; `timeout-minutes: 20`) |

---

## 6. Conventions

- `# frozen_string_literal: true` in every Ruby file.
- YARD tags on every class/method: `@api public|private`, `@since`, `@version` (methods: bump on a behavior/signature change; classes/modules: only on an interface change: signatures, added/removed methods, `extend`/`include`/`prepend` or the superclass; `logic.md#2`); `# @since` right above each `include`/`extend`/`prepend` line (the version that added the mixin).
- Every `lib/` change gets a matching `sig/` RBS update; use `# steep:ignore` only where Steep can't infer types.
- New operation: new `Acquirer::*` module, thin `Client` method (+ `!` variant if it should raise), RBS, spec.
- New config option: `setting` (+ `validate`) in `config.rb` + the typed `Config#[]` overload line in `sig/redis_queued_locks/config.rbs`, read via `config['key']`, document defaults.
- Development gems go in `Gemfile` (`Gemspec/DevelopmentDependencies: Gemfile`), not the gemspec.
- This overview and `.claude/rules/*.md` are updated in the same change as the code (keys, options, results, events, algorithm steps, limitations); README and CHANGELOG `[Unreleased]` for user-visible behavior (log keys and instrumentation payloads: README `## Logging` / `### Instrumentation Events`; the full README sync list: `.claude/rules/readme.md`); CHANGELOG entries are compact, subject-level changes only, plus the project infrastructure (`.claude` instructions, CI, specs-only changes, dev dependencies) with bold area markers (`.claude/rules/changelog.md`).
- Temporary debt: rspec-retry, disabled coverage minimum, the swarm README docs (pending rework, `readme.md#9`: the reserved anchors, the `swarm.*` keys out of `### Configuration`, no swarm method sections; all these exceptions are removed by the rework).
- Specs (`spec/**/*_spec.rb`) are not ideal and will be totally reworked (header `NOTE` of `spec/redis_queued_locks_spec.rb`): until then any coding principle may be broken there; code review checks only that the library behavior is covered and that changed expectations are correct (`.claude/skills/rql-code-review`).
