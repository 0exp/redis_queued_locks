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
- Purpose: zombie-lock elimination. `ProbeHosts` periodically `HSET`s every host id (`rql:hst:<pid>/<thread>/<ractor>/<identity>`) with `Time.now.to_f` into `rql:swarm:hsts`; `FlushZombies` treats hosts older than `zombie_ttl` (ms) as zombies and deletes their write locks, their read locks (registry members + reader data), their entries in both request queues and the hosts themselves.
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
- Redis keys come only from `RedisQueuedLocks::Resource.prepare_*` helpers and its `*_PATTERN` / `SWARM_KEY` constants. Key families: write lock `rql:lock:` (`LOCK_PATTERN`), write requests `rql:lock_queue:` (`LOCK_QUEUE_PATTERN`), readers registry `rql:lock_readers:` (`LOCK_READERS_PATTERN`), read requests `rql:lock_read_queue:` (`READ_LOCK_QUEUE_PATTERN`), reader data `rql:lock_reader:<name>:<acq_id>` (`READ_LOCK_PATTERN`); all of them match `KEY_PATTERN` (`rql:lock*`).
- New key families use a distinct **prefix** (`rql:lock_<kind>:<name>`), never a suffix of the lock name: the lock name is an arbitrary string, so `rql:lock_queue:<name>:read` would collide with the queue of a lock named `<name>:read`.
- Time: lock expirations that affect safety use Redis time (`PEXPIRE`, or `TIME` via `Resource.redis_time_ms` for reader scores); client `Time.now.to_f` is used only for queue positions, `ts` fields and zombie probes.
- Config: `setting('key', default)` + `validate('key') { |val| ... }` in `config.rb`; dotted keys for nested groups (`swarm.flush_zombies.zombie_ttl`); units in a trailing `# NOTE: in milliseconds` comment.
- Errors: subclasses in `errors.rb`, written as `class XError < Error; end` (not `Class.new`) so RBS/Steep can see the superclass.
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
7. New config option: `setting` with default + `validate` with a type check, both in `config.rb`; read it in `Client` as `config['key']`.
8. Logs and instrumentation events go through visitor modules (see `visitors.md`); event names follow `redis_queued_locks.<snake_case>`.
9. Keep thread/Ractor safety: guard shared state with `Utilities::Lock`, never share a `RedisClient` across Ractors.
10. Disable rubocop cops only locally with a matching `rubocop:enable`, and only for Metrics/Layout on large methods.
11. After any change here, update the mirrored `sig/` file (see `type-checking.md`) and add/adjust a spec (see `tests.md`).
12. Keep `.claude/project-overview.md` and the affected `.claude/rules/*.md` in sync in the same change (keys, options, results, events, algorithm steps, limitations); read the relevant overview sections before implementing and follow their invariants.
13. Read/write awareness: every new or changed operation over locks/queues (release, cleanup, info, zombies, series) must handle the read key family too (see the key families above) and keep the result shape for write-only usage unchanged (add keys/branches only when read data exists).
14. Never derive safety from queues or client clocks: mutual exclusion is decided by the lock state checked under WATCH (writers WATCH the write key + readers registry, readers WATCH the write key only), queues and positions only order requests.

## Recommendations (proposed, not yet project policy)
Apply to new or touched code; don't refactor existing code for these unless asked.
1. Avoid `# rubocop:disable all` (used in `client.rb` lock_series and `lock_series_poc.rb`); disable only the specific cops.
2. Document every option fully in YARD.
3. Spell new identifiers correctly and don't copy existing typos (`swarm_element__termiante` method, `Acquier` in comments and the `acquier.rbs` filename); fix them only in a dedicated change.
4. Include context in raised errors (lock name, acquirer id, timeout) so failures are diagnosable.
5. Prefer `then` (the modern alias) over `yield_self` in new code.
