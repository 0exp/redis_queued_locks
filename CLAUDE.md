# CLAUDE.md

Ruby gem: distributed Redis locks with a per-lock FIFO acquisition queue. Ruby >= 4.0; only runtime dep is `redis-client ~> 0.20`.
Full details (config keys, key layout, events, errors, stack, CI): `.claude/project-overview.md`.

## Commands
- Tests (need a running local Redis): `bundle exec rake rspec`
- Lint: `bundle exec rake rubocop`
- Static types: `bundle exec rbs collection install && bundle exec rake steep:check`

## Architecture
- `client.rb`: public API facade; fills defaults from `config[...]`, delegates to `Acquirer::*`.
- `acquirer/*.rb`: one stateless module per operation (`class << self`), returns `{ ok:, result: }`; `!` client methods raise.
- `acquirer/acquire_lock.rb`: composed via `extend` mixins in `acquire_lock/` (try_to_lock, with_acq_timeout, delay_execution, dequeue_from_lock_queue, yield_expire) + `LogVisitor`/`InstrVisitor` event hooks.
- Locking: `ZADD NX` into the request queue, then WATCH/MULTI; Lua only for write TTL extension/decrease.
- Read/Write locks (`read_write_mode: :write|:read`): write lock `rql:lock:<name>` + queue `rql:lock_queue:<name>`; readers registry `rql:lock_readers:<name>` (ZSET acq_id => Redis-time expiry), read queue `rql:lock_read_queue:<name>`, per-reader data `rql:lock_reader:<name>:<acq_id>`. Readers WATCH the write key only, writers WATCH the write key + registry; queues give ordering only. Details: overview "Read/Write locks".
- Strategies: `access_strategy` `:queued`|`:random`; `conflict_strategy` `:wait_for_lock`|`:work_through`|`:extendable_work_through`|`:dead_locking`.
- `resource.rb`: all key names and acquirer/host IDs. `config.rb`: `setting`/`validate` DSL, read as `config['a.b']`.
- `swarm/`: zombie-lock cleanup. `Supervisor` thread revives `ProbeHosts` (`SwarmElement::Threaded`) and `FlushZombies` (`SwarmElement::Isolated`, Ractor talking via `Ractor::Port`s); each element runs a main-loop thread with its own Redis connection.
- `logging/`, `instrument/`: Void null-object defaults, percent samplers, ActiveSupport adapter.
- `sig/`: RBS mirror of `lib/`. `spec/redis_queued_locks_spec.rb`: single integration spec.

## Rules
Detailed, path-scoped rules in `.claude/rules/`: `logic.md` (lib, general), `acquirer.md` (acquirer modules, Redis access), `visitors.md` (log/instrumentation visitors), `arguments.md` (long keyword lists), `swarm.md` (swarm supervisor/elements, Ractor/Thread rules), `tests.md` (spec), `type-checking.md` (sig/Steep), `git.md` (commit messages and commit flow, always loaded).
- Long explicit keyword/parameter lists are intentional (minimal allocations, signature-as-DSL): never introduce parameter objects, option structs or `**opts`; add new options as explicit keywords to every `Client` variant and forward them by name.
- Update the matching `sig/*.rbs` for every `lib/` change; keep Steep green.
- Keep `# frozen_string_literal: true` and YARD `@api`/`@since`/`@version` tags.
- `{ ok:, result: }` is for the public API only (`Client`, `Acquirer::*`, `Swarm` facade actions). Internal swarm element APIs (commands, replies, helpers) use bare scalars/primitives (see `swarm.md`).
- New operation: `Acquirer::*` module, thin `Client` method (+ `!` variant), RBS, spec.
- New option: `setting` (+ `validate`) in `config.rb`.
- Dev gems go in `Gemfile`, not the gemspec.
- Commits (`git.md`): subject only `[<scope>] <summary>` (several features: 1-2 words each, comma-separated), no body; when a step is complete (requirement fully implemented, specs/rubocop/steep green) ask before committing, with the proposed subject and a recap of the changes; an explicit "commit" request needs no extra question; never on `master`, never push.
- Before implementing, read the relevant sections of `.claude/project-overview.md` (key layout, lock flow, "Read/Write locks", events) and keep their invariants. In the same change, update the overview and the affected `.claude/rules/*.md` for every new/changed key, option, result shape, event, algorithm step or limitation (and README/CHANGELOG `[Unreleased]` for user-visible behavior).
- Lock-touching code is read/write-aware: any operation over locks, queues, zombies or lock info must cover the read family (`rql:lock_readers:*`, `rql:lock_read_queue:*`, `rql:lock_reader:*`) next to `rql:lock:*`/`rql:lock_queue:*`. Mutual exclusion comes only from WATCH/MULTI on lock state (no Lua in the RW acquisition path unless asked); queues never guarantee safety.
- Known debt: rspec-retry, disabled coverage minimum, runtime type-check CI uses `--failure-exit-code=0`.
