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
- Locking: `ZADD NX` into `rql:lock_queue:<name>`, then WATCH/MULTI on `rql:lock:<name>`; Lua for TTL extension.
- Strategies: `access_strategy` `:queued`|`:random`; `conflict_strategy` `:wait_for_lock`|`:work_through`|`:extendable_work_through`|`:dead_locking`.
- `resource.rb`: all key names and acquirer/host IDs. `config.rb`: `setting`/`validate` DSL, read as `config['a.b']`.
- `swarm/`: zombie-lock cleanup. `Supervisor` thread revives `ProbeHosts` (`SwarmElement::Threaded`) and `FlushZombies` (`SwarmElement::Isolated`, Ractor talking via `Ractor::Port`s); each element runs a main-loop thread with its own Redis connection.
- `logging/`, `instrument/`: Void null-object defaults, percent samplers, ActiveSupport adapter.
- `sig/`: RBS mirror of `lib/`. `spec/redis_queued_locks_spec.rb`: single integration spec.

## Rules
Detailed, path-scoped rules in `.claude/rules/`: `logic.md` (lib, general), `acquirer.md` (acquirer modules, Redis access), `visitors.md` (log/instrumentation visitors), `arguments.md` (long keyword lists), `swarm.md` (swarm supervisor/elements, Ractor/Thread rules), `tests.md` (spec), `type-checking.md` (sig/Steep).
- Long explicit keyword/parameter lists are intentional (minimal allocations, signature-as-DSL): never introduce parameter objects, option structs or `**opts`; add new options as explicit keywords to every `Client` variant and forward them by name.
- Update the matching `sig/*.rbs` for every `lib/` change; keep Steep green.
- Keep `# frozen_string_literal: true` and YARD `@api`/`@since`/`@version` tags.
- `{ ok:, result: }` is for the public API only (`Client`, `Acquirer::*`, `Swarm` facade actions). Internal swarm element APIs (commands, replies, helpers) use bare scalars/primitives (see `swarm.md`).
- New operation: `Acquirer::*` module, thin `Client` method (+ `!` variant), RBS, spec.
- New option: `setting` (+ `validate`) in `config.rb`.
- Dev gems go in `Gemfile`, not the gemspec.
- Known debt: rspec-retry, disabled coverage minimum, runtime type-check CI uses `--failure-exit-code=0`.
