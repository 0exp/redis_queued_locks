---
paths:
  - "lib/redis_queued_locks/acquirer.rb"
  - "lib/redis_queued_locks/acquirer/**/*.rb"
---

# Acquirer modules (`lib/redis_queued_locks/acquirer/**`)

## Observed style and patterns
- **Module shape**: `module RedisQueuedLocks::Acquirer::<CamelName>` in `acquirer/<snake_name>.rb`, `# @api private`, a single public entry function inside `class << self` named after the file (`ReleaseLock.release_lock`, `IsLocked.locked?`), helpers under `private` in the same `class << self`.
- **Utilities**: modules that time or instrument `extend RedisQueuedLocks::Utilities` (gives `clock_gettime`, `run_non_critical`).
- **Signatures** (see `arguments.md` for the design rationale):
  - Read-only queries: few positional args `(redis_client, lock_name)`; collection queries use keywords `(redis_client, scan_size:, with_info:)`.
  - Mutating operations: long positional lists ending with the fixed observability tail
    `logger, instrumenter, instrument, log_sampling_enabled, log_sampling_percent, log_sampler, log_sample_this, instr_sampling_enabled, instr_sampling_percent, instr_sampler, instr_sample_this`
    (order of `logger`/`instrumenter` varies between modules; check the existing signature).
  - Only `AcquireLock.acquire_lock` uses keyword args (`process_id:`, `thread_id:`, ...).
- **Two-layer mutating operations** (`release_lock`, `release_all_locks`, `release_locks_of`):
  1. `rel_start_time = clock_gettime`
  2. call a private `fully_*` helper returning `{ ok:, result: }` and destructure it: `fully_x(...) => { ok:, result: }`
  3. `time_at = Time.now.to_f`; `rel_time = ((rel_end_time - rel_start_time) / 1_000.0).ceil(2)` (microseconds → ms)
  4. `instr_sampled = RedisQueuedLocks::Instrument.should_instrument?(...)`
  5. `run_non_critical { instrumenter.notify('redis_queued_locks.<event>', { at:, rel_time:, ... }) } if instr_sampled`
  6. return `{ ok: true, result: { ..., rel_time: } }`
- **Results**: always `{ ok: Boolean, result: ... }` for operations; `result` is a Symbol status (`:ttl_extended`, `:async_expire_or_no_lock`, `:released`, `:nothing_to_release`) or a Symbol-keyed Hash with abbreviated keys (`rel_key_cnt`, `tch_queue_cnt`, `rel_time`). Info queries return a String-keyed Hash / Set or `nil` when absent.
- **Redis access**:
  - Keys only via `Resource.prepare_lock_key` / `prepare_lock_queue` and `Resource::*_PATTERN`.
  - Raw commands: `redis.call('CMD', ...)` with uppercase string command names and string args (`'0'`, `'-inf'`, `'+inf'`).
  - Pooled connection: wrap multi-command work in `redis.with do |rconn| ... end`.
  - Atomic writes: `rconn.multi do |transact| ... end` (or `multi(watch: [lock_key])` in `TryToLock`); batch reads: `pipelined do |pipeline| ... end` then index `result[0]`, `result[1]` into named vars (`hget_cmd_res`, `pttl_cmd_res`).
  - Iteration: `scan('MATCH', PATTERN, count: scan_size) { |key| ... }`, collecting into `Set.new.tap { |set| ... }`; deletes are batched by scan size.
  - Lua: frozen heredoc constant (`<<~LUA_SCRIPT.strip.tr("\n", '').freeze`) + `call('EVAL', SCRIPT, 1, key, arg)`.
  - Release = `EXPIRE key 0` / `ZREMRANGEBYSCORE queue -inf +inf`; Redis TTL sentinels handled explicitly (`PTTL` `-2` = missing, `-1` = no expiry → `Float::INFINITY`).
- **Data normalization**: Redis hash strings are converted with `Float(...)` / `Integer(...)` inside `hget_cmd_res.tap do |lock_data| ... end`, optional fields guarded with `if lock_data['x']`.
- **AcquireLock**:
  - Main module `require_relative`s its parts, then `extend`s the mixins (`TryToLock`, `DelayExecution`, `YieldExpire`, `WithAcqTimeout`, `DequeueFromLockQueue`); mixins are plain modules with instance methods (`def try_to_lock(...)`), visitors are `class << self` modules called explicitly (see `visitors.md`).
  - The algorithm is a numbered step script (`# Step 0`, `# Step 2.1`, `# Step 2.2.a`) driven by a mutable `acq_process` hash (`:should_try`, `:tries`, `:acquired`, `:result`, `:lock_info`, timings).
  - Failure modes are Symbols (`:fail_fast_no_try`, `:fail_fast_after_try`, `:conflict_dead_lock`, ...); exceptions are raised only when `raise_errors` is true, with a message naming the lock key / acquirer id.
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
9. Wrap every `instrumenter.notify` / logger call in `run_non_critical` (or a visitor) and gate it with `Instrument.should_instrument?` / `Logging.should_log?`; observability must never break locking.
10. In `AcquireLock`, add behavior as a new step or mixin rather than growing `acquire_lock`; keep the `# Step N.x` comment numbering, update `acq_process` keys consistently, and add a matching `LogVisitor`/`InstrVisitor` method for each new lifecycle event.
11. When normalizing lock hash fields, follow the `Float()` / `Integer()` conversion pattern; if a new lock field is added, update both `lock_info.rb` and `locks.rb` (they duplicate the formatting).

## Recommendations (proposed, not yet project policy)
Apply to new or touched code; don't refactor existing code for these unless asked.
1. Load Lua scripts once (`SCRIPT LOAD` + `EVALSHA`, falling back to `EVAL` on `NOSCRIPT`), as the TODO in `extend_lock_ttl.rb` asks.
2. Prefer indexed lookups over full `SCAN` loops for new features (see TODOs in `release_locks_of.rb`, `locks.rb`, `queues.rb`).
3. Treat `lock_series_poc.rb` as experimental: don't build new features on it without asking.
4. Extract the duplicated lock-hash normalization in `lock_info.rb` / `locks.rb` and queue formatting in `queue_info.rb` / `queues.rb` into shared helpers (their TODOs ask for this).
5. Unify the observability tail order (`logger, instrumenter` vs `instrumenter, logger` in `release_lock`) when those signatures are next changed.
