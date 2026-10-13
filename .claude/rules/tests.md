---
paths:
  - "spec/**/*.rb"
  - ".rspec"
---

# Test rules (`spec/`)

## Observed conventions
- All behavior specs live in one integration file, `spec/redis_queued_locks_spec.rb` (~3.4k lines), under `RSpec.describe RedisQueuedLocks`; groups: `describe 'Lock Series PoC'`, `describe 'swarm'`, `describe 'read/write locks'`, plus top-level `specify` blocks. The file header says it will be reworked; rspec-retry (5 retries) masks flakiness meanwhile.
- Known flaky example: `all in + notifications` (timing-dependent `sleep(1)`; passes in isolation).
- `.rspec` auto-requires `spec_helper`; `spec_helper.rb` loads SimpleCov first (`setup_simplecov.rb`), then `rspec/retry`, `pry`, the gem.
- RSpec config: random order (`Kernel.srand config.seed`), `disable_monkey_patching!`, `expect` syntax only, `filter_run_when_matching :focus`, `Thread.abort_on_exception = true`.
- Tests hit a real Redis (db 0) via `let(:redis) { RedisClient.config(db: 0).new_pool(timeout: 5, size: 50, ...) }` with long timeouts (RBS runtime-check runs are slow); `all in + notifications` also flushes db 1. Check the local Redis dbs before running the suite on a machine with other data.
- Read/write lock specs use: a monotonic `timeline` hash + `mark` lambda (guarded by a `Mutex`) to assert ordering (`reader_in < other_reader_out`, `writer_in >= reader_out`); an invariant spec with shared reader/writer counters checked inside lock blocks; helper threads that take locks without a block (each thread is a separate acquirer).
- `before`: `FLUSHDB`, `DEL Resource::SWARM_KEY`, `RedisQueuedLocks.enable_debugger!`; `after`: `DEL SWARM_KEY`, `FLUSHDB`.
- Examples are written with `specify '<feature>'` (few `it`); grouped with `describe` only for big areas (`'Lock Series PoC'`, `'swarm'`).
- Clients are built inline: `RedisQueuedLocks::Client.new(redis) { |config| ... }`.
- Logger/instrumenter fakes are anonymous classes (`Class.new { def debug(...); def notify(event, payload = {}) }`) collecting calls into arrays.
- Concurrency is tested with real `Thread.new` and `sleep` to wait for async swarm elements; assertions use `match(...)`, `eq(...).or(eq(...))`, `include`, `raise_error(RedisQueuedLocks::...Error)`.
- Every example cleans up its own state (`client.clear_locks`, `deswarmize!`, `redis.close`).
- Command-layout specs observe the sent commands through a separate pool on db 0 built with a recording `redis-client` middleware (a `Module` with `define_method(:call_pipelined) { |commands, config, &block| ...; super(commands, config, &block) }`: the block must be forwarded explicitly), e.g. `lock state pipeline layout` (it reads the position constants of `TryToLock`). Update their expectations deliberately when a pipeline layout changes.
- Coverage: SimpleCov line + branch, HTML only; `minimum_coverage 100` is a TODO.
- Both lock lookup modes (`config['lock_index_enabled']`): the behavior examples are `RSpec.shared_examples 'redis_queued_locks'` (the `redis` pool and the FLUSHDB hooks are `RSpec.shared_context 'redis_queued_locks redis'`), included by `RSpec.describe RedisQueuedLocks` twice: `context 'with the disabled lock index (keyspace SCAN)', lock_index_enabled: false` and `context 'with the enabled lock index (lock index ZSCAN)', lock_index_enabled: true`; the `around` hook of `spec_helper` switches the default of `config['lock_index_enabled']` for the example by this metadata (`RedisQueuedLocks::Config.setting`, the library default is restored after the example), so `RedisQueuedLocks::Client.new(redis)` inside the shared examples gets the mode of the context (explicit config values win). One `bundle exec rake rspec` runs the shared examples in both modes (~2x time).
- Mode-dependent expectations inside the shared examples branch on `client.config['lock_index_enabled']` (e.g. `lock state pipeline layout`: 5 queueing commands, 9 with the lock index; `lock-iterating operations: one pass (keyspace or lock index) with small batches`: `#keys` lists other `rql:lock*` keys only with the keyspace lookup); keys written directly with raw commands (`ZADD` queues, `HSET` locks) are found by the keyspace SCAN and are indexed with `client.reindex_locks if client.config['lock_index_enabled']` before lock-iterating assertions.
- Lock index specifics live in `describe 'lock index'` (outside the shared examples: run once, every client enables the lock index explicitly with `config['lock_index_enabled'] = true`; `let(:index_score_ahead)` = index score minus the current client ms, `let(:upper_bound)` = `be_between(lifetime + grace - 1_000, lifetime + grace)`); `the lock obtaining transaction indexes the lock` drops the index entry right before the obtaining `MULTI` with a middleware (keep it when touching the obtaining transaction); `the disabled lock index (default): no lock index commands, keyspace lookups` records all commands of the default mode (no `rql:index:locks` argument, no `ZSCAN`, queues without TTL); `enabling the lock index: ...` covers the migration (`#reindex_locks` after enabling).

## Claude rules
The suite is pending a total rework (overview "Conventions"): these rules guide new examples, but their violations in `*_spec.rb` are not code review findings until the rework; the review checks only that the changed library behavior is covered and that changed expectations are correct (`.claude/skills/rql-code-review`, §3).

1. Run specs with a local Redis available: `bundle exec rake rspec` (single example: `bundle exec rspec spec/redis_queued_locks_spec.rb:<line>`).
2. Add new examples to `spec/redis_queued_locks_spec.rb` with `specify '<feature>'`, inside an existing `describe` when one fits; don't create new spec files unless asked (the suite is pending a rework).
3. Use only `expect` syntax; no `should`, no monkey-patched DSL, no `focus` left behind.
4. Use the shared `redis` pool and rely on the global `before`/`after` FLUSHDB; never use a different DB or flush in the middle of an example without reason.
5. Build fakes as anonymous classes implementing the duck-typed interface (`debug`, `notify`, `sampling_happened?`), not with doubles of real loggers.
6. Clean up everything an example starts: release locks, `deswarmize!` swarm clients, join/kill threads.
7. Keep `sleep`-based waits minimal and comment why (`# give a timespot to ...`); prefer polling with a bounded timeout when adding new async checks.
8. Do not add new rspec-retry reliance or lower retry settings; do not enable `minimum_coverage` without being asked.
9. Specs are also run under RBS runtime checks, so pass correctly typed arguments to public API calls (type violations are logged in CI); e.g. test an invalid lock ttl with `ttl: 0`, not `ttl: nil` (`Client#lock` types `ttl` as `Integer`).
10. Check new or changed examples for flakiness without retries: `RSPEC_RETRY_RETRY_COUNT=1 bundle exec rspec spec/redis_queued_locks_spec.rb -e '<group>'`, several runs in a row; also watch for `RSpec::Retry: 2nd try` lines in normal runs.
11. Threads in specs: `Thread.abort_on_exception = true`, so never raise expected errors inside threads (call non-raising `lock` there and assert results in the main thread); keep references to helper threads until the end of the example (acquirer ids contain `Thread#object_id`, which can be reused after GC).
12. Timing assertions on TTLs allow the redis time shift error: extendable reentrant locks return the extension minus the time spent in the inner block and `Resource::REDIS_TIMESHIFT_ERROR` (2 ms), so the remaining TTL can slightly exceed the initial one.
13. New lock features get specs for both modes when relevant (`read_write_mode: :write` and `:read`): ordering, mutual exclusion, reentrancy per conflict strategy, `fail_fast`, timeouts/dequeue, release/cleanup/info/zombie paths, and that no `rql:*` keys are left (`client.keys` is empty) after blocks finish.

## Recommendations (proposed, not yet project policy)
Apply to new tests; don't restructure the existing suite unless asked.
1. Move toward one spec file per feature, mirroring `lib/` (`spec/redis_queued_locks/acquirer/extend_lock_ttl_spec.rb`), when the planned rework starts.
2. Extract the repeated fake logger/notifier classes into `spec/support/` shared helpers or `shared_context`.
3. Add a `wait_until(timeout:) { condition }` helper and use it instead of fixed `sleep` for swarm/thread checks; this reduces flakiness and rspec-retry reliance.
4. Add Redis-free unit specs for pure modules (`Resource`, `Config` + validators, samplers, `Logging.should_log?`); they are fast and stable.
5. Tag slow swarm/Ractor examples (e.g. `:swarm`) so they can be run or skipped separately.
6. Read the Redis connection from `ENV['REDIS_URL']` (default `redis://localhost:6379/0`) so specs can run against non-default Redis setups.
7. Once the suite is stable, remove rspec-retry and raise `minimum_coverage` step by step toward 100.
8. Cover failure paths explicitly: timeouts, retry exhaustion, `fail_fast`, `raise_errors`, each conflict and access strategy.
