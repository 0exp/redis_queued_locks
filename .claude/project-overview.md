# redis_queued_locks: Project Overview

Ruby gem providing **distributed locks on Redis with a prioritized lock-acquisition queue**.
Each lock has its own request queue; requests are processed FIFO (`:queued`) or first-come
(`:random`). Requests have TTLs (with requeue), so queues never get stuck. Includes reentrancy
(conflict) strategies, timed locks, retries/fail-fast, logging, instrumentation with sampling,
and a background "swarm" that detects dead hosts and flushes their locks.

- Repo: https://github.com/0exp/redis_queued_locks (MIT); main branch `master`
- Runtime dependency: `redis-client ~> 0.20` (locked 0.30.1), nothing else
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
```

`Client.new(redis_client) { |config| ... }`:
1. builds `Config` from the block,
2. computes `uniq_identity` via `config['uniq_identifier']`,
3. creates `Swarm` and starts it when `config['swarm.auto_swarm']` is true.

Every other public method is a thin wrapper: it fills option defaults from `config[...]` and calls
an `Acquirer::*` module function with `redis_client`.

### Client → implementation map

| Client method | Implementation |
|---|---|
| `lock` / `lock!` | `acquirer/acquire_lock.rb` + `acquirer/acquire_lock/*` |
| `lock_series` / `lock_series!` | `acquirer/lock_series_poc.rb` (proof of concept) |
| `unlock` | `acquirer/release_lock.rb` |
| `extend_lock_ttl` | `acquirer/extend_lock_ttl.rb` |
| `locked?` / `queued?` | `acquirer/is_locked.rb` / `acquirer/is_queued.rb` |
| `lock_info` / `queue_info` | `acquirer/lock_info.rb` / `acquirer/queue_info.rb` |
| `locks`, `locks_info`, `queues`, `queues_info`, `keys` | `acquirer/locks.rb`, `queues.rb`, `keys.rb` (SCAN-based) |
| `clear_locks` | `acquirer/release_all_locks.rb` |
| `clear_locks_of`, `clear_current_locks` | `acquirer/release_locks_of.rb` |
| `clear_dead_requests` | `acquirer/clear_dead_requests.rb` |
| `current_acquirer_id`, `current_host_id`, `possible_host_ids` | `resource.rb` |
| `swarmize!`, `deswarmize!`, `swarm_status`, `swarm_info`, `probe_hosts`, `flush_zombies`, `zombie_locks`, `zombie_acquirers`, `zombie_hosts`, `zombies_info` | `swarm.rb` + `swarm/*` |

### Lock acquisition flow (`acquirer/acquire_lock.rb` + `acquire_lock/`)

`AcquireLock` is assembled from mixins (`extend`):

| Mixin | Role |
|---|---|
| `TryToLock` (`try_to_lock.rb`) | One attempt: `ZADD NX` acquirer into the lock queue (timestamp score), then `multi(watch: [lock_key])` and take the lock if allowed (head of queue for `:queued`, any position for `:random`). Handles reentrant conflicts; TTL extension via inline Lua (`PTTL` + `PEXPIRE`). |
| `WithAcqTimeout` | Global acquisition timeout (`timeout`). |
| `DelayExecution` | Retry delay + jitter between attempts. |
| `DequeueFromLockQueue` | Removes the acquirer from the queue on timeout/failure. |
| `YieldExpire` | Runs the user block (optionally `timed`), then releases/expires the lock. |
| `LogVisitor` / `InstrVisitor` | One method per lifecycle event for logs and instrumentation. |

### Main `lock` options (defaults from config)

`ttl`, `queue_ttl`, `timeout`, `timed`, `retry_count`, `retry_delay`, `retry_jitter`,
`raise_errors`, `fail_fast`, `conflict_strategy`, `access_strategy`, `read_write_mode`
(default `:write`; its doc is unfinished), `identity`, `meta`, `logger`, `log_lock_try`,
`instrumenter`, `instrument`, log/instr sampling options, `log_sample_this`, `instr_sample_this`.

- `access_strategy`: `:queued` (FIFO, default) or `:random`.
- `conflict_strategy` (same process re-acquires its own lock): `:wait_for_lock` (default),
  `:work_through`, `:extendable_work_through`, `:dead_locking`.

### Redis data layout (`resource.rb`)

| Key | Type | Purpose |
|---|---|---|
| `rql:lock:<name>` | HASH | lock owner + metadata (e.g. `l_spc_ts`, `l_spc_ext_ts` for reentrant cases) |
| `rql:lock_queue:<name>` | ZSET | acquirer queue scored by enqueue time |
| `rql:lock_queue:<name>:read` / `:write` | ZSET | read/write mode queues |
| `rql:swarm:hsts` | HASH | swarm host heartbeats |

- Acquirer ID: `rql:acq:<pid>/<thread>/<fiber>/<ractor>/<identity>`
- Host ID: `rql:hst:<pid>/<thread>/<ractor>/<identity>` (no fiber)

### Instrumentation events

`redis_queued_locks.` + `lock_obtained`, `reentrant_lock_obtained`,
`extendable_reentrant_lock_obtained`, `lock_hold_and_release`, `reentrant_lock_hold_completes`,
`lock_series_obtained`, `lock_series_hold_and_release`, `explicit_lock_release`,
`explicit_all_locks_release`, `release_locks_of`.

### Errors (`errors.rb`)

Base `RedisQueuedLocks::Error < StandardError`, plus `ArgumentError`, `LockAlreadyObtainedError`,
`LockAcquirementTimeoutError`, `LockAcquirementRetryLimitError`, `TimedLockTimeoutError`,
`ConflictLockObtainError`, `SwarmError`, `SwarmArgumentError`, `ConfigError`
(`ConfigNotFoundError`, `ConfigValidationError`). Internal `*IntermediateTimeoutError`s
inherit from `Timeout::Error`.

---

## 2. Architecture patterns by module

| Module | Patterns |
|---|---|
| `Client` | Facade; constructor injection (caller-supplied `RedisClient`); `x` returns a result hash, `x!` raises |
| `Acquirer::*` | One module per command; stateless `class << self` functions; uniform `{ ok:, result: }` returns (public API contract; swarm element internals use bare scalars/primitives) |
| `AcquireLock` | Composition via `extend` mixins; optimistic concurrency (WATCH/MULTI) + Lua for atomic updates; strategy options (`access_strategy`, `conflict_strategy`) |
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
| Strategies | `default_conflict_strategy` (`:wait_for_lock`), `default_access_strategy` (`:queued`) |
| Batching | `lock_release_batch_size` (100), `clear_locks_of__lock_scan_size` / `__queue_scan_size` (300), `key_extraction_batch_size` (500) |
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
spec/                              redis_queued_locks_spec.rb (~2.6k lines, integration), spec_helper.rb, setup_simplecov.rb
.github/workflows/                 tests, lint, typecheck-static, typecheck-runtime
bin/console, bin/setup             dev scripts
Rakefile, Steepfile, rbs_collection.yaml
```

Known quirk: `sig/redis_queued_locks/acquier.rbs` is misspelled (should be `acquirer.rbs`).

---

## 5. Technology stack

### Runtime
- Ruby >= 4.0; stdlib `timeout`, `securerandom`, `logger`; Thread, Fiber, Ractor, Mutex
- Redis server: WATCH/MULTI, EVAL (Lua), ZSET, HASH, PTTL/PEXPIRE, SCAN
- `redis-client ~> 0.20`
- Optional, duck-typed: any `::Logger`-compatible logger; any `#notify(event, payload)` instrumenter (ActiveSupport adapter included; SemanticLogger has only an RBS stub)

### Test / development
- RSpec 3.13: random order, no monkey patching, `expect` syntax, `Thread.abort_on_exception = true`
- rspec-retry 0.6.2: 5 retries per example (marked temporary)
- A real Redis is required (CI: `supercharge/redis-github-action@1.8.1`)
- SimpleCov 1.3.2: line + branch coverage, HTML report; 100% minimum disabled (TODO)
- RBS 4.2 + `rbs collection` + tsort; Steep 2.1 (static); RBS runtime testing via `rbs/test/setup`
- RuboCop 1.89 through `armitage-rubocop` (general, rake, rspec, rbs presets) with plugins rubocop-rspec, -performance, -rake, -on-rbs, -thread_safety; several Metrics cops disabled
- rake, bundler, pry, pry-doc, reline, activesupport 8.1

### Rake tasks
`rspec` (default), `rubocop`, `steep:check`, plus bundler gem tasks (`build`, `release`, ...).

### CI (GitHub Actions, ubuntu-latest, Ruby 4.0, on every push)

| Workflow | Command |
|---|---|
| tests | `bundle exec rake rspec` (with a Redis service) |
| lint | `bundle exec rake rubocop` |
| typecheck-static | `bundle exec rbs collection install && bundle exec rake steep:check -j 10` |
| typecheck-runtime | `RBS_TEST_RAISE=true RUBYOPT='-rrbs/test/setup' RBS_TEST_OPT='-I sig' RBS_TEST_TARGET='RedisQueuedLocks::*' bundle exec rspec --failure-exit-code=0` (never fails the build) |

---

## 6. Conventions

- `# frozen_string_literal: true` in every Ruby file.
- YARD tags on every class/method: `@api public|private`, `@since`, `@version` (bump `@version` when changing behavior).
- Every `lib/` change gets a matching `sig/` RBS update; use `# steep:ignore` only where Steep can't infer types.
- New operation: new `Acquirer::*` module, thin `Client` method (+ `!` variant if it should raise), RBS, spec.
- New config option: `setting` (+ `validate`) in `config.rb`, read via `config['key']`, document defaults.
- Development gems go in `Gemfile` (`Gemspec/DevelopmentDependencies: Gemfile`), not the gemspec.
- Temporary debt: rspec-retry, disabled coverage minimum, runtime type-check job that can't fail.
