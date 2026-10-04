---
paths:
  - "sig/**/*.rbs"
  - "Steepfile"
  - "rbs_collection.yaml"
  - "lib/**/*.rb"
---

# Type-checking rules (`sig/`, Steep, RBS)

## Observed conventions
- `sig/` mirrors `lib/` one file per file (`lib/redis_queued_locks/acquirer/is_locked.rb` → `sig/redis_queued_locks/acquirer/is_locked.rbs`). Known typo: `sig/redis_queued_locks/acquier.rbs` is the `Acquirer` namespace file.
- RBS uses fully nested `module RedisQueuedLocks / module Acquirer / ...` blocks (unlike compact Ruby constants).
- Common aliases at the top: `use RedisQueuedLocks as RQL`, `use RedisClient as RC`; Redis connections typed as `RC::client`.
- Shared duck types live in `sig/redis_queued_locks.rbs`: `_Loggable`, `_Instrumentable`, `loggerObj`, `instrObj`; samplers as `RQL::Logging::samplerObj` / `RQL::Instrument::samplerObj`.
- Result shapes are named record aliases inside the module, e.g. `type extendResult = { ok: bool, result: Symbol }`.
- Module functions are declared `def self.name: (...) -> T`; long signatures put one param per line with names.
- Instance variables are declared (`@config_setters: configSetters`) and attr readers typed.
- Third-party types: `sig/vendor/*.rbs` hand-written stubs (redis_client, active_support, semantic_logger) plus `rbs collection` gems (redis-client, securerandom, timeout, logger, monitor) installed into `.gem_rbs_collection/`.
- `Steepfile`: target `lib`, signatures `sig`, ignores `spec`, libraries timeout/securerandom/logger/monitor, diagnostics `Steep::Diagnostic::Ruby.strict`.
- In Ruby code: `# @type var x: T` and `x = ... #: T` annotations narrow types; `# steep:ignore` silences dynamic spots (mostly `config['...']` defaults in `Client`).
- Runtime checking: CI runs specs with `RUBYOPT=-rrbs/test/setup RBS_TEST_TARGET='RedisQueuedLocks::*'`, so signatures must match real runtime values, not just Steep's view.

## Claude rules
1. Every change to a `lib/` file's public or private API (new method, param, return shape, constant, ivar) must be reflected in the mirrored `.rbs` file in the same change.
2. Create new `.rbs` files at the mirrored path with nested module blocks and `use RedisQueuedLocks as RQL` / `use RedisClient as RC` aliases when needed.
3. Reuse shared types (`RQL::loggerObj`, `RQL::instrObj`, `samplerObj`, `RC::client`) instead of `untyped`; use `untyped` only for truly dynamic values (e.g. user `meta`, `instrument`).
4. Name result hashes with a `type xxxResult = { ok: bool, result: ... }` alias next to the method.
5. Prefer fixing types or adding `# @type var` / `#: T` annotations over `# steep:ignore`; use `steep:ignore` only for `config['...']` lookups and other DSL-driven dynamic calls.
6. Don't loosen `Steep::Diagnostic::Ruby.strict` or add `ignore` entries to the `Steepfile`.
7. New third-party gem used in `lib/`: add it to `rbs_collection.yaml` (and `sig/manifest.yml` for stdlib) or write a minimal stub in `sig/vendor/`.
8. Verify with `bundle exec rbs collection install && bundle exec rake steep:check`; for signature/runtime mismatches run the specs under RBS runtime testing (command in `.github/workflows/typecheck-runtime.yml`).
9. Don't rename `acquier.rbs` unless asked; it is a known quirk.

## Recommendations (proposed, not yet project policy)
1. Make the runtime type-check CI job blocking (drop `--failure-exit-code=0`) once current violations are fixed.
2. Reduce the ~150 `# steep:ignore` in `client.rb` with a typed config accessor (e.g. per-key typed readers or an RBS overload table for `Config#[]`).
3. Remove duplicate entries in `rbs_collection.yaml` (`redis-client` and `securerandom` are listed twice) and pin the `gem_rbs_collection` revision instead of `main` for reproducible checks.
4. Rename `sig/redis_queued_locks/acquier.rbs` to `acquirer.rbs` in a dedicated change.
5. Replace remaining `untyped` in signatures with precise unions or interfaces where the value set is known (e.g. strategy symbols as `:queued | :random`).
6. Type strategy and mode options as literal unions (`conflict_strategy: :wait_for_lock | :work_through | :extendable_work_through | :dead_locking`) so Steep catches invalid values.
