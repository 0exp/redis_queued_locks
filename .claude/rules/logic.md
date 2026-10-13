---
paths:
  - "lib/**/*.rb"
---

# Logic rules: general (`lib/`)

Related rule files (loaded for narrower paths):
- `acquirer.md`: acquirer operations, Redis access, `AcquireLock` algorithm
- `visitors.md`: log & instrumentation visitors
- `arguments.md`: long explicit keyword/parameter lists (core API design principle)
- `swarm.md`: swarm architecture, element lifecycle, Ractor/Thread coding rules

## Swarm overview (details in `swarm.md`)
- Purpose: zombie-lock elimination. `ProbeHosts` periodically `HSET`s every host id (`rql:hst:<pid>/<thread>/<ractor>/<identity>`) with `Time.now.to_f` into `rql:swarm:hsts`; `FlushZombies` treats hosts older than `zombie_ttl` (ms) as zombies and deletes their write locks, their read locks (registry members + reader data), their entries in both request queues and the hosts themselves; locks are found via one keyspace `SCAN` pass (default) or via the lock index (`rql:index:locks`, `ZSCAN`) with the enabled `config['lock_index_enabled']`.
- `Client#swarm` → `Swarm` facade (one per client) owns a `Supervisor` and the swarm elements; started by `swarmize!` / `swarm.auto_swarm`, stopped by `deswarmize!`.
- Elements are independent background units: a control unit (`SwarmElement::Threaded` = Thread + `SizedQueue` command channel; `SwarmElement::Isolated` = Ractor driven via its own pair of `Ractor::Port`s: results port created in the main Ractor, where the Swarm and Supervisor live; command port created inside the element Ractor) that spawns, stops and reports on a main-loop Thread with its own Redis connection (`Swarm::RedisClientBuilder`).
- `ProbeHosts` is Threaded (it must see the client's ractor threads); `FlushZombies` is Isolated (copied config values only).
- `Supervisor` is one Thread that calls `reswarm_if_dead!` on every element each `liveness_probing_period`, restarting dead control units or stopped main loops; `swarm_status` aggregates `{ running:, state: }` of all of them.
- Redis work lives in stateless class-level functions (`ProbeHosts.probe_hosts`, `FlushZombies.flush_zombies`, `ZombieInfo.*`, `Acquirers.acquirers`), shared by main loops and the manual public API.

## Observed conventions
- Every file starts with `# frozen_string_literal: true`.
- Constants are defined compactly: `class RedisQueuedLocks::Acquirer::IsLocked` / `module ...`, never nested `module A; module B`.
- Namespace files (`acquirer.rb`, `swarm.rb`, `logging.rb`, `swarm/swarm_element.rb`) only `require_relative` their children; the root `lib/redis_queued_locks.rb` requires the namespaces in dependency order.
- YARD doc block on every class, module, constant, attr and method:
  `@param name [Type]`, `@option`, `@return [Type]`, blank `#` line, then `@api public|private`, `@since X.Y.Z`, optional `@version X.Y.Z` (latest behavior change).
- Operations are stateless modules with `class << self` functions; dependencies (`redis_client`, logger, instrumenter, sampling options) are passed as explicit args, never read from globals.
- Operation modules (except PoC modules such as `LockSeriesPoC`) are independent of each other: no cross-calls and no shared RBS types between them; common logic lives in `Resource`/`Utilities`, similar logic is duplicated on purpose (see `acquirer.md`, "Independence of operation modules").
- Public API results are hashes `{ ok: Boolean, result: Symbol|Hash }` (`Client`, `Acquirer::*`, `Swarm` facade actions); `Client` `!` methods raise `RedisQueuedLocks::*Error`. Internal swarm element APIs return bare scalars/primitives (see `swarm.md`).
- `Client` methods only fill defaults from `config['...']` and delegate to `Acquirer::*` / `Swarm`.
- Redis keys come only from `RedisQueuedLocks::Resource.prepare_*` helpers and its `*_PATTERN` / `SWARM_KEY` constants. Key families: write lock `rql:lock:` (`LOCK_PATTERN`), write requests `rql:lock_queue:` (`LOCK_QUEUE_PATTERN`), readers registry `rql:lock_readers:` (`LOCK_READERS_PATTERN`), read requests `rql:lock_read_queue:` (`READ_LOCK_QUEUE_PATTERN`), reader data `rql:lock_reader:<name>:<acq_id>` (`READ_LOCK_PATTERN`); all of them match `KEY_PATTERN` (`rql:lock*`); `Resource.lock_key_family(key)` classifies a key by its prefix (`:lock`, `:lock_queue`, `:lock_readers`, `:read_lock_queue`, `:read_lock`, `nil`).
- New key families use a distinct **prefix** (`rql:lock_<kind>:<name>`), never a suffix of the lock name: the lock name is an arbitrary string, so `rql:lock_queue:<name>:read` would collide with the queue of a lock named `<name>:read`.
- Lock index `rql:index:locks` (`Resource::LOCK_INDEX_KEY`), opt-in via the client-wide `config['lock_index_enabled']` (`false` by default: lock-iterating operations scan the keyspace, no lock index commands, queues without TTL): a global ZSET of lock names (score = upper bound of the lifetime of all lock keys, client ms + ttl + `lock_index_grace_period`); not matched by `KEY_PATTERN`. With the enabled lock index every key-creating command is followed by the index `ZADD GT` (queueing pipeline, obtaining `MULTI`), every extension by `ZADD XX INCR`, names are removed only with all their keys (`unlock`, `clear_locks`), lock request queues have TTL; all lock-iterating operations use it (`ZSCAN`), only `reindex_locks` scans the keyspace. Every lock-iterating module keeps both lookups (keyspace and lock index) side by side with the shared processing in one copy (details in `acquirer.md`, "Iteration" and "Lock index").
- Time: lock expirations that affect safety use Redis time (`PEXPIRE`, or `TIME` via `Resource.redis_time_ms` for reader scores); client `Time.now.to_f` is used only for queue positions, `ts` fields and zombie probes; lock index scores use client ms (`Resource.lock_index_time`) with the `lock_index_grace_period` margin (clock skew tolerance; the index never affects mutual exclusion).
- Config: `setting('key', default)` + `validate('key') { |val| ... }` in `config.rb`; dotted keys for nested groups (`swarm.flush_zombies.zombie_ttl`); units in a trailing `# NOTE: in milliseconds` comment.
- Errors: subclasses in `errors.rb`, written as `class XError < Error; end` (not `Class.new`) so RBS/Steep can see the superclass. Each error inherits from the global base error of its branch: `Error < ::StandardError` (the main hierarchy), `ArgumentError < ::ArgumentError` (`SwarmArgumentError`), `Exception < ::Exception` (the internal timeouts `LockAcquirementIntermediateTimeoutError`, `TimedLockIntermediateTimeoutError`); inside `module RedisQueuedLocks` the bare `Error`/`ArgumentError`/`Exception` are these bases.
- Comments use `# NOTE:`, `# TODO:` and `# @type var x: T` / `#: T` for inline type hints.
- Rubocop is suppressed locally with `# rubocop:disable Metrics/MethodLength` etc. (paired `enable`), mostly for large algorithm methods.
- Shared mutable state is guarded by `RedisQueuedLocks::Utilities::Lock#synchronize`; Ractor code must not capture non-shareable objects (build a fresh Redis client via `Swarm::RedisClientBuilder`).

## Claude rules
1. Start new files with `# frozen_string_literal: true` and use compact constant paths.
2. Add a full YARD block to every new public/private method; new code gets `@since <next version>`; when changing existing behavior, add/bump `@version`.
3. New operation = new `Acquirer::*` module + thin `Client` method delegating to it (+ `!` variant only if it must raise); details in `acquirer.md`.
4. Return `{ ok:, result: }` hashes from public API operations (`Client`, `Acquirer::*`, `Swarm` facade actions); raise only in `!` methods or on invalid arguments (`RedisQueuedLocks::ArgumentError`). Internal APIs, and swarm element internals in particular, use bare scalars/primitives (`true`/`false`, String, Symbol, Integer, `nil`, a flat Hash of scalars) without the wrapper.
5. Never hardcode `rql:` strings; add a `Resource.prepare_*` helper or constant instead.
6. Use WATCH/MULTI or a Lua constant for any read-modify-write on lock/queue keys; never do check-then-set in Ruby without a transaction.
7. New config option: `setting` with default + `validate` with a type check and the valid range (TTLs, periods, batch/scan sizes are positive Integers: `val.is_a?(Integer) && val > 0`), both in `config.rb`; read it in `Client` as `config['key']`.
8. Logs and instrumentation events go through visitor modules (see `visitors.md`); event names follow `redis_queued_locks.<snake_case>`.
9. Keep thread/Ractor safety: guard shared state with `Utilities::Lock`, never share a `RedisClient` across Ractors.
10. Disable rubocop cops only locally with a matching `rubocop:enable`, and only for Metrics/Layout on large methods (the only exception: the line-level `Lint/InheritException` of the base `RedisQueuedLocks::Exception < ::Exception` in `errors.rb`, see rule 15).
11. After any change here, update the mirrored `sig/` file (see `type-checking.md`) and add/adjust a spec (see `tests.md`).
12. Keep `.claude/project-overview.md` and the affected `.claude/rules/*.md` in sync in the same change (keys, options, results, events, algorithm steps, limitations); read the relevant overview sections before implementing and follow their invariants.
13. Read/write awareness: every new or changed operation over locks/queues (release, cleanup, info, zombies, series) must handle the read key family too (see the key families above) and keep the result shape for write-only usage unchanged (add keys/branches only when read data exists).
14. Never derive safety from queues or client clocks: mutual exclusion is decided by the lock state checked under WATCH (writers WATCH the write key + readers registry, readers WATCH the write key only), queues and positions only order requests.
15. Error hierarchy (`errors.rb`, mirrored in `sig/redis_queued_locks/errors.rbs`):
    - every `RedisQueuedLocks` error inherits from the global base error of its branch, never directly from a Ruby class; the main base is `Error < ::StandardError`;
    - a branch that can not be a part of the main hierarchy (a Ruby core error that our error must stay, e.g. `ArgumentError < ::ArgumentError`) gets its own base error named after the Ruby class (`class TypeError < ::TypeError` for a new one), listed in the `errors.rb` header and in the overview "Errors";
    - errors are built per case on the `StandardError` hierarchy or on the Ruby core errors (through the base of their branch), not on `::Exception`;
    - `Exception < ::Exception` is for super exceptional cases only (internal interrupts that the interrupted user/observability code must not rescue: `rescue => e`, `rescue StandardError`, `rescue nil`); each error of this branch states in its comment why it is not a `StandardError` and where the library rescues it (it never reaches the public API: it is converted to a public error/result); only the base disables `Lint/InheritException` (subclasses use the relative `< Exception`);
    - new public errors are `@api public` and documented in README/CHANGELOG; the `Exception` branch is `@api private`.
16. Observability of the logic (logs and instrumentation):
    - every logic that creates, changes or deletes Redis keys has both logs and instrumentation; logic that only reads the lock data (`locked?`, `queued?`, `lock_info`, `queue_info`, `locks`, `queues`, `keys`, `*_info`, zombie queries) has neither;
    - lock acquirement (`AcquireLock`, `LockSeriesPoC`): each meaningful step/outcome is logged and instrumented through the visitors (`visitors.md`): obtained (classic and reentrant), held and released, not obtained (`lock_obtaining_failed`, also before a raised acquirement error); the per-attempt `try_lock.*` steps are logs only (gated by `log_lock_try`), never instrumented (no `notify` per attempt);
    - lock mutation operations (release, extension, cleanup, reindexing): exactly one log line and one instrumentation event per operation with the time of the whole work of the root operation module called by the public `Client` method (the two-layer pattern of `acquirer.md`: the timer wraps the `fully_*` helper), never of its internal parts; the log line and the event have the same name (`redis_queued_locks.<event>`) and the same data in the same order (the log has no `instrument`), the payload ends with the user's `instrument`; they are written inline in the module (`run_non_critical`, gated by `Logging.should_log?` / `Instrument.should_instrument?`);
    - every such public `Client` method takes `logger:`, `instrumenter:`, `instrument:` and the log/instrumentation sampling keywords (defaults from `config`) and forwards them by name to the operation module;
    - known debt: the swarm elements and the manual swarm actions (`ProbeHosts`, `FlushZombies`: `#probe_hosts`, `#flush_zombies`) are neither logged nor instrumented yet (the flusher Ractor can not get the user's logger/instrumenter).
17. Debug methods of `Resource`: `Resource` may keep methods that the library does not use when they are justified for debugging: they let you check a subtle part of the logic by hand at runtime (in a console), e.g. `lock_key_from_queue` maps a lock request queue of any mode to its lock. Each of them:
    - has a `# NOTE: (debug)` comment in its YARD block: that it is not used by the library and what it checks (with a console example);
    - is correct for every key family it can get (write and read keys), has the full YARD block, the RBS signature and a spec;
    - is not a dead code finding; an unused method without the `(debug)` note is dead code (remove it); a debug method that the library starts to use loses the note.

## Recommendations (proposed, not yet project policy)
Apply to new or touched code; don't refactor existing code for these unless asked.
1. Avoid `# rubocop:disable all` (used in `client.rb` lock_series and `lock_series_poc.rb`); disable only the specific cops.
2. Document every option fully in YARD.
3. Spell new identifiers correctly and don't copy existing typos (`swarm_element__termiante` method, `Acquier` in comments and the `acquier.rbs` filename); fix them only in a dedicated change.
4. Include context in raised errors (lock name, acquirer id, timeout) so failures are diagnosable.
5. Prefer `then` (the modern alias) over `yield_self` in new code.
