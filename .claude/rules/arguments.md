---
paths:
  - "lib/redis_queued_locks/client.rb"
  - "lib/redis_queued_locks/acquirer/**/*.rb"
  - "lib/redis_queued_locks/swarm.rb"
  - "lib/redis_queued_locks/config.rb"
  - "sig/redis_queued_locks/client.rbs"
  - "sig/redis_queued_locks/acquirer/**/*.rbs"
---

# Long explicit keyword lists (core API design principle)

## The pattern
The public API and the lock pipeline use **long, flat, explicit argument lists**: every tunable is a named keyword with its default declared directly in the signature (usually `config['...']`), and every value is forwarded explicitly, name by name, through each layer:

```ruby
# Client (public DSL surface)
def lock(lock_name, ttl: config['default_lock_ttl'], queue_ttl: config['default_queue_ttl'],
         ..., instr_sample_this: false, &block)
  RedisQueuedLocks::Acquirer::AcquireLock.acquire_lock(
    redis_client, lock_name,
    process_id: RedisQueuedLocks::Resource.get_process_id, ...,
    ttl:, queue_ttl:, ..., instr_sample_this:, &block
  )
end
```

This is a deliberate framework-level decision, **not** something to refactor into parameter objects, option hashes, context structs or builders.

## Why (framework-engineering rationale)
- **Minimal object allocation on the hot path.** Lock acquisition runs in tight retry loops under contention. Keywords forwarded as `key:` shorthand and positional args into stateless `class << self` functions cost no extra objects; a parameter/context object, `**opts` hash, `Data`/`Struct` or builder allocates on every call (and per retry, per event). Fewer allocations = less GC pressure and more predictable latency in a concurrency primitive.
- **The signature is the DSL.** `client.lock('name', ttl: 1_000, fail_fast: true, conflict_strategy: :work_through) { ... }` reads as a declarative per-call configuration. Users override exactly what they need; everything else falls back to `config[...]`. There is one place to look for what a call accepts.
- **Layered defaults without merging.** Global config (`Config` DSL) → per-call keyword override → explicit forwarding. No hash merging, no hidden `opts.fetch`, no precedence rules to learn.
- **Fail-fast on typos.** Ruby rejects unknown keywords (`ArgumentError: unknown keyword`) at the call boundary; an options hash would silently accept `tll:`.
- **Typed and documented contract.** Every option has its own YARD `@option` line and RBS signature entry, so Steep and RBS runtime checks validate each value individually; opaque bags of options can't be typed this precisely.
- **Stateless, thread/Ractor-friendly internals.** No intermediate object carries mutable state between layers; each function receives everything it needs as plain values, which keeps `Acquirer::*` modules pure and shareable.
- **Grep-ability and traceability.** Searching for `log_sample_this:` shows every hop of a value from the public API down to the visitor that uses it.

## How it is applied (layer by layer)
| Layer | Style |
|---|---|
| `Client` public methods | Positional subject (`lock_name`) + long keyword list with defaults from `config['...']` (`# steep:ignore`) or literals; trailing `&block`. Paired `x` / `x!` methods duplicate the full keyword list (no `**kwargs` delegation). |
| `Client` → `Acquirer` | Explicit forwarding with Ruby 3.1 shorthand (`ttl:`, `queue_ttl:`); runtime identity values injected here (`process_id:`, `thread_id:`, `fiber_id:`, `ractor_id:`). |
| `AcquireLock.acquire_lock` | Required keywords without defaults (`ttl:`, `timeout:`, ...): defaults live only in `Client`. |
| Other `Acquirer::*`, mixins, visitors | Positional parameters in a fixed, documented order (subject, data, observability tail) for the cheapest possible internal calls. |
| Results | Public API (`Client`, `Acquirer::*`, `Swarm` facade actions): small literal Hashes (`{ ok:, result: }`), not result classes. Internal swarm element APIs: bare scalars/primitives (see `swarm.md`). |

## Claude rules
1. **Do not introduce** parameter objects, context/options structs (`Data.define`, `Struct`, `OpenStruct`), builders, or `**opts` / `options = {}` hashes in `Client`, `Acquirer::*`, mixins or visitors. Long explicit lists are the intended design.
2. New public option: add it as an explicit keyword to **every** affected `Client` method (`x` and `x!`, e.g. `lock` and `lock!`), with the default taken from `config['...']` (add the `setting` + `validate` first) or a literal for per-call-only flags (`raise_errors: false`, `meta: nil`).
3. Forward it explicitly by name through every layer using shorthand (`new_option:`); never forward via `**kwargs`, `...`, or `method(__method__).parameters` tricks.
4. Keep defaults only at the public boundary (`Client`); internal functions take required keywords/positionals with no defaults so a missed forward fails loudly.
5. Internal positional lists: append new params in the established order (subject → domain data → observability tail `logger, instrumenter, instrument, log_sampling_*, log_sample_this, instr_sampling_*, instr_sample_this`) and update every call site and the RBS signature in the same change.
6. Document each new option with its own `@option`/`@param` YARD line (type, meaning, default source) and add it to the RBS method signature as a named param/keyword.
7. Keep hot-path code allocation-light: no per-call wrapper objects, no hash merging, no splats to build args, no `tap`/closures purely for argument plumbing; prefer passing existing locals.
8. Silence length cops locally (`# rubocop:disable Metrics/MethodLength`) rather than shortening signatures; `Metrics/ParameterLists` is disabled project-wide on purpose.

## Recommendations (proposed, not yet project policy)
1. For new internal functions with many same-typed params (e.g. several Integers/Booleans in a row), consider required keywords instead of positionals to prevent misordering; keep the list flat and explicit.
