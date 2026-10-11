---
paths:
  - "lib/redis_queued_locks/acquirer.rb"
  - "lib/redis_queued_locks/acquirer/**/*.rb"
---

# Acquirer modules (`lib/redis_queued_locks/acquirer/**`)

## Observed style and patterns
- **Module shape**: `module RedisQueuedLocks::Acquirer::<CamelName>` in `acquirer/<snake_name>.rb`, `# @api private`, a single public entry function inside `class << self` named after the file (`ReleaseLock.release_lock`, `IsLocked.locked?`), helpers under `private` in the same `class << self`.
- **Utilities**: modules that time or instrument `extend RedisQueuedLocks::Utilities` (gives `clock_gettime`, `run_non_critical`).
- **Independence of operation modules** (core principle): the modules behind `Client` public methods that don't acquire locks (`ClearDeadRequests`, `ExtendLockTTL`, `IsLocked`, `IsQueued`, `Keys`, `LockInfo`, `Locks`, `QueueInfo`, `Queues`, `ReleaseAllLocks`, `ReleaseLock`, `ReleaseLocksOf`, `ReleaseReadLock`) never call each other and never reference each other's RBS types. They share logic only through `Resource`, `Utilities` and other non-operation helpers; similar logic is duplicated on purpose (independence wins over DRY):
  - `Locks.extract_locks_info` / `Locks.read_lock_info` duplicate the write/read lock formatting of `LockInfo.lock_info` / `LockInfo.read_lock_info`;
  - `Queues.extract_queues_info` duplicates the request formatting of `QueueInfo.queue_info`;
  - each module declares its own RBS aliases (`Locks::lockInfo` / `Locks::readerInfo` mirror `LockInfo::lockInfo` / `LockInfo::readerInfo`); only `Client` signatures reference them.
  - `AcquireLock` is the lock acquisition core, not an operation module of this list.
  - PoC modules (`*PoC`, e.g. `LockSeriesPoC`) are not covered by this principle: they may reuse operation modules and the `AcquireLock` core (`LockSeriesPoC` uses `AcquireLock.acquire_lock` and its `YieldExpire` mixin).
  - Known debt (don't copy): `AcquireLock::WithAcqTimeout` calls `LockInfo.lock_info` / `QueueInfo.queue_info` for detailed timeout errors (its TODO asks to make `AcquireLock` independent of them).
- **Signatures** (see `arguments.md` for the design rationale):
  - Read-only queries: few positional args `(redis_client, lock_name)`; collection queries use keywords `(redis_client, scan_size:, with_info:)`.
  - Mutating operations: long positional lists ending with the fixed observability tail
    `logger, instrumenter, instrument, log_sampling_enabled, log_sampling_percent, log_sampler, log_sample_this, instr_sampling_enabled, instr_sampling_percent, instr_sampler, instr_sample_this`
    (order of `logger`/`instrumenter` varies between modules; check the existing signature).
  - Only `AcquireLock.acquire_lock` and `LockSeriesPoC.lock_series_poc` use keyword args (`process_id:`, `thread_id:`, ...).
- **Two-layer mutating operations** (`release_lock`, `release_read_lock`, `release_all_locks`, `release_locks_of`):
  1. `rel_start_time = clock_gettime`
  2. call a private `fully_*` helper returning `{ ok:, result: }` and destructure it: `fully_x(...) => { ok:, result: }`
  3. `time_at = Time.now.to_f`; `rel_time = ((rel_end_time - rel_start_time) / 1_000.0).ceil(2)` (microseconds → ms)
  4. `instr_sampled = RedisQueuedLocks::Instrument.should_instrument?(...)`
  5. `run_non_critical { instrumenter.notify('redis_queued_locks.<event>', { at:, rel_time:, ... }) } if instr_sampled`
  6. return `{ ok: true, result: { ..., rel_time: } }`
- **Results**: always `{ ok: Boolean, result: ... }` for operations; `result` is a Symbol status (`:async_expire_or_no_lock`, `:released`, `:nothing_to_release`) or a Symbol-keyed Hash (`rel_key_cnt`, `tch_queue_cnt`, `rel_time`, `extended_locks_count`). Info queries return a String-keyed Hash / Set or `nil` when absent.
- **Redis access**:
  - Keys only via `Resource.prepare_lock_key` / `prepare_lock_queue` / `prepare_read_lock_queue` / `prepare_lock_readers` / `prepare_read_lock_key(lock_name, acquirer_id)` and `Resource::*_PATTERN` (`LOCK_PATTERN`, `LOCK_QUEUE_PATTERN`, `READ_LOCK_QUEUE_PATTERN`, `LOCK_READERS_PATTERN`, `READ_LOCK_PATTERN`); `Resource.lock_name_from_readers` / `lock_key_from_readers` map registry keys back.
  - Several independent reads inside one attempt/operation go into one `pipelined` round trip (it works inside `multi(watch:)` too: reads are sent after WATCH).
  - Raw commands: `redis.call('CMD', ...)` with uppercase string command names and string args (`'0'`, `'-inf'`, `'+inf'`).
  - Pooled connection: wrap multi-command work in `redis.with do |rconn| ... end`.
  - Atomic writes: `rconn.multi do |transact| ... end` (or `multi(watch: [lock_key])` in `TryToLock`); batch reads: `pipelined do |pipeline| ... end` then index `result[0]`, `result[1]` into named vars (`hget_cmd_res`, `pttl_cmd_res`).
  - Iteration: `scan('MATCH', PATTERN, count: scan_size) { |key| ... }`, collecting into `Set.new.tap { |set| ... }`; deletes are batched by scan size.
  - Lua: frozen heredoc constant (`<<~LUA_SCRIPT.strip.tr("\n", '').freeze`) + `call('EVAL', SCRIPT, 1, key, arg)`.
  - Release = `EXPIRE key 0` / `ZREMRANGEBYSCORE queue -inf +inf`; a read lock is released with `ZREM <readers> <acq_id>` + `DEL <reader data>` (owner-safe, other readers untouched); Redis TTL sentinels handled explicitly (`PTTL` `-2` = missing, `-1` = no expiry → `Float::INFINITY`).
  - Readers registry members are live only while `score > Redis TIME (ms)` (`Resource.redis_time_ms`); expired members can stay till cleanup, so info/checks must filter by score, never by `ZCARD`/`EXISTS` alone.
- **Data normalization**: Redis hash strings are converted with `Float(...)` / `Integer(...)` inside `hget_cmd_res.tap do |lock_data| ... end`, optional fields guarded with `if lock_data['x']`.
- **AcquireLock**:
  - Main module `require_relative`s its parts, then `extend`s the mixins (`TryToLock`, `DelayExecution`, `YieldExpire`, `WithAcqTimeout`, `DequeueFromLockQueue`); mixins are plain modules with instance methods (`def try_to_lock(...)`), visitors are `class << self` modules called explicitly (see `visitors.md`).
  - The algorithm is a numbered step script (`# Step 0`, `# Step 2.1`, `# Step 2.2.a`) driven by a mutable `acq_process` hash (`:should_try`, `:tries`, `:acquired`, `:result`, `:lock_info`, timings).
  - Failure modes are Symbols (`:fail_fast_no_try`, `:fail_fast_after_try`, `:conflict_dead_lock`, `:conflict_lock_upgrade`, ...); exceptions are raised only when `raise_errors` is true, with a message naming the lock key / acquirer id.
  - `TryToLock` attempt (both modes): `multi(watch:)` (write: `[lock_key, lock_readers_key]`, read: `[lock_key]`) → one pipelined state read (`HGET acq_id`, `TIME`, own reader score, longest reader) → same-process conflict detection (`sp_conflict_rw_mode` = held `:write`/`:read`) → `ZADD NX` into the queue of the requested mode → prune dead requests in **both** queues → queue heads of both queues (`:queued`: write must be first in its queue; any mode waits for an earlier `(score, acq_id)` request of the opposite mode) → lock state (write held → `:lock_is_still_acquired`; live readers for write / own live read for read → `:read_lock_is_still_acquired`) → MULTI (write: `ZREM` + `HSET` + `PEXPIRE`; read: `ZREM` + prune registry + `ZADD expiry` + registry `PEXPIRE NX`+`GT` + reader data `DEL`+`HSET`+`PEXPIRE`).
  - The try result carries internal `rw_mode` (the **held** lock mode); `acquire_lock` stores it as `acq_process[:held_rw_mode]` and passes it to `yield_expire`, which releases/decreases the held lock. The public `lock` result shape does not include it.
  - Read lock data (`rql:lock_reader:<name>:<acq_id>`) uses the write-lock field format (`acq_id`, `hst_id`, `ts`, `ini_ttl`, meta, `spc_*`) and the read lock TTL; it is a data carrier only (writers never read it).
  - Timing via monotonic `clock_gettime` (microseconds); wall time only for `at:`/`ts` fields.
- **Inline typing**: `# @type var result: Symbol`, `{} #: Hash[String,String|Float|Integer]`, and `# steep:ignore` on pattern-matching destructures and splats (`rconn.call('DEL', *keys) # steep:ignore`).

## Claude rules
1. New operation: create `acquirer/<snake_name>.rb` with `module RedisQueuedLocks::Acquirer::<CamelName>`, one public `class << self` entry function named after the file, private helpers below `private`; add `require_relative` to `acquirer.rb` and a mirrored `sig/redis_queued_locks/acquirer/<snake_name>.rbs`.
2. Read-only query → small positional args or `scan_size:` / `with_info:` keywords, return data or `nil`. Mutating operation → follow the two-layer pattern (public timing/instrumentation wrapper + private `fully_*` helper).
3. Keep the observability tail parameters in the established order of the closest sibling module; pass them through unchanged from `Client`.
4. Return `{ ok:, result: }`; use Symbol statuses for simple outcomes and abbreviated Symbol keys (`rel_*`, `*_cnt`, `*_time`) consistent with existing results. Don't raise from acquirer modules except through the `raise_errors` path in `AcquireLock`.
5. Use `redis.with { |rconn| ... }` for any multi-command work; use `multi` for writes that must be atomic, `pipelined` for independent reads, `multi(watch:)` or Lua when a write depends on a read.
6. Use uppercase string Redis commands and string numeric args; handle `PTTL`/`TTL` sentinel values explicitly.
7. Iterate keys with `scan('MATCH', Resource::*_PATTERN, count:)`, never `KEYS`; batch deletes by scan size.
8. Measure durations with `clock_gettime` and report ms with `/ 1_000.0).ceil(2)`; use `Time.now.to_f` only for event timestamps.
9. Wrap every `instrumenter.notify` / logger call in `run_non_critical` (or a visitor) and gate it with `Instrument.should_instrument?` / `Logging.should_log?`; observability must never break locking. Payload changes of inline `notify` calls are documented in README `### Instrumentation Events` in the same change (see `visitors.md` rule 14).
10. In `AcquireLock`, add behavior as a new step or mixin rather than growing `acquire_lock`; keep the `# Step N.x` comment numbering, update `acq_process` keys consistently, and add a matching `LogVisitor`/`InstrVisitor` method for each new lifecycle event.
11. When normalizing lock hash fields, follow the `Float()` / `Integer()` conversion pattern; if a new lock field is added, update every copy of the formatting: write locks in `LockInfo.lock_info` and `Locks.extract_locks_info`, readers in `LockInfo.read_lock_info` and `Locks.read_lock_info` (reader data uses the same fields).
12. Read/write checklist for any change in this directory:
    - lock state checks: write requires no write lock and no **live** readers; read requires no write lock; same-acquirer reader/writer cases go through `conflict_strategy` (read→write upgrade never "works through");
    - WATCH: writers watch the write key + readers registry, readers watch the write key only (never the registry: readers must not abort each other); don't modify a watched key outside MULTI after WATCH (it aborts your own EXEC);
    - every attempt prunes dead requests in both queues; dequeue/cleanup removes the acquirer from the queue of its mode;
    - every release/cleanup/info/zombie path covers write lock, readers registry, reader data and both queues;
    - registry/reader-data TTLs: `PEXPIRE NX` + `PEXPIRE GT` pair to keep max TTL (`GT` alone never sets TTL on a key without one);
    - keep write-only result shapes unchanged; add read keys/fields only when read data exists.
13. Values used only for logs (e.g. `HGETALL` of lock data) are fetched only when the log is enabled (`(log_sampled && log_lock_try) ? ... : {}`): visitor arguments are evaluated before the visitor's guard.
14. Keep operation modules independent (see "Independence of operation modules"; PoC modules such as `LockSeriesPoC` are exempt): never call another operation module's function (public or private) or reference its RBS types from an operation module. When similar logic is needed, duplicate it inside the module (same method name and shape as the original copy, with a `NOTE` that it is duplicated on purpose) or move a pure, data-only helper (key names, id parsing, time conversion) to `Resource` / `Utilities`. Helpers used by one module stay `private`. When changing logic that has copies, update every copy in the same change.

## Recommendations (proposed, not yet project policy)
Apply to new or touched code; don't refactor existing code for these unless asked.
1. Load Lua scripts once (`SCRIPT LOAD` + `EVALSHA`, falling back to `EVAL` on `NOSCRIPT`), as the TODO in `extend_lock_ttl.rb` asks.
2. Prefer indexed lookups over full `SCAN` loops for new features (see TODOs in `release_locks_of.rb`, `locks.rb`, `queues.rb`).
3. Treat `lock_series_poc.rb` as experimental: don't build new features on it without asking. Its locks are released only through `release_lock_series` (obtained-by-series locks only, owner-checked, on success and on every failure path).
4. Unify the observability tail order (`logger, instrumenter` vs `instrumenter, logger` in `release_lock`) when those signatures are next changed.
