---
paths:
  - "lib/redis_queued_locks/acquirer/**/*.rb"
  - "lib/redis_queued_locks/logging.rb"
  - "lib/redis_queued_locks/logging/**/*.rb"
  - "lib/redis_queued_locks/instrument.rb"
  - "lib/redis_queued_locks/instrument/**/*.rb"
---

# Log & instrumentation visitors

## What it is
The project calls these modules "visitors", but they are not GoF Visitor (no `accept`/double dispatch). They are **stateless event-hook modules**: one module per algorithm component, one method per lifecycle event. They take the observability "port" (`logger` or `instrumenter`) plus event data, and emit exactly one log line or one notification. The algorithm code only says *what happened* (`LogVisitor.lock_obtained(...)`); the visitor decides *how it is reported*.

**Why**: keeps the lock algorithm readable (one call per event instead of inline string building), centralizes event names and payload shapes, makes sampling and error-swallowing uniform, and gives RBS a typed contract for every event.

## Where they live
| Visitor | File | Events |
|---|---|---|
| `AcquireLock::LogVisitor` | `acquire_lock/log_visitor.rb` | 6: `start_lock_obtaining`, `start_try_to_lock_cycle`, `dead_score_reached__reset_acquirer_position`, `extendable_reentrant_lock_obtained`, `reentrant_lock_obtained`, `lock_obtained` |
| `AcquireLock::InstrVisitor` | `acquire_lock/instr_visitor.rb` | 5: `extendable_reentrant_lock_obtained`, `reentrant_lock_obtained`, `lock_obtained`, `reentrant_lock_hold_completes`, `lock_hold_and_release` |
| `AcquireLock::TryToLock::LogVisitor` | `acquire_lock/try_to_lock/log_visitor.rb` | 18 step-level events (`start`, `rconn_fetched`, `acq_added_to_queue`, `exit__no_first`, `exit__read_lock_still_obtained`, `obtain__free_to_acquire`, ...); every lock event logs `rw_mode` |
| `AcquireLock::YieldExpire::LogVisitor` | `acquire_lock/yield_expire/log_visitor.rb` | `expire_lock`, `decrease_lock` |
| `AcquireLock::DequeueFromLockQueue::LogVisitor` | `acquire_lock/dequeue_from_lock_queue/log_visitor.rb` | `dequeue_from_lock_queue` |
| `LockSeriesPoC::LogVisitor` / `InstrVisitor` | `lock_series_poc/*_visitor.rb` | lock series events (no RBS, `# steep:ignore`) |

Not covered by visitors: `release_lock`, `release_read_lock`, `release_all_locks`, `release_locks_of` call `instrumenter.notify` inline inside `run_non_critical`, and do not log at all (their `logger` param is unused).

## Observed conventions
- **Placement**: a visitor sits in a subdirectory named after the component it reports on (`<component>/log_visitor.rb`, `<component>/instr_visitor.rb`) and is loaded by that component with `require_relative` at the top of the module body.
- **Shape**: `module <Component>::LogVisitor` / `::InstrVisitor`, `# @api private`, all methods inside `class << self`, full YARD block per method; return `void`.
- **Method name = event name**: snake_case; double underscore separates phase and detail (`exit__queue_ttl_reached`, `reentrant_lock__work_through`). The LogVisitor and InstrVisitor use the same method name for the same event.
- **Parameter order**: `(port, sampled_flag, [extra gate], lock_key, ...event data..., [instrument])`:
  - LogVisitor: `(logger, log_sampled, ...)`; `TryToLock::LogVisitor` adds `log_lock_try` as the third arg (fine-grained step logs are opt-in through `config['log_lock_try']`). Lock lifecycle events (AcquireLock, TryToLock, YieldExpire, DequeueFromLockQueue) take `rw_mode` right after `access_strategy`, before event-specific data, and log it as `rw_mode => '<mode>'` right after `acs_strat`.
  - InstrVisitor: `(instrumenter, instr_sampled, lock_key, rw_mode, ttl, acq_id, hst_id, ts, acq_time, [hold_time], instrument)`; the payload carries `rw_mode:` (requested mode); the user's `instrument` value is always last.
  - `rw_mode` in AcquireLock/TryToLock events is the **requested** mode; in YieldExpire events it is the **held** mode (the lock that is released/decreased).
- **Guard first**: `return unless log_sampled` (`&& log_lock_try` for try-lock steps) / `return unless instr_sampled`. The sampling decision is computed **once per operation** in the caller via `Logging.should_log?` / `Instrument.should_instrument?` and passed down as a boolean.
- **Log format**: one `logger.debug { ... }` block (lazy string), message = `"[redis_queued_locks.<event>] "` (`[redis_queued_locks.try_lock.<event>]` for TryToLock steps) followed by `key => value` pairs; string values in single quotes (`lock_key => '...'`), numbers bare; abbreviated keys `acq_id`, `hst_id`, `acs_strat`. Built with `\` line continuations.
- **Instrumentation format**: `instrumenter.notify('redis_queued_locks.<event>', { lock_key:, ttl:, acq_id:, hst_id:, ts:, acq_time:, instrument: })` using shorthand hash syntax and Symbol keys.
- **Never raise**: every emit ends with `rescue nil` (modifier), so a broken logger/instrumenter can't affect lock correctness.
- **Call sites**: plain module calls with positional args, usually grouped on 2-3 lines (`LogVisitor.lock_obtained(logger, log_sampled, lock_key, ...)`); data comes from local vars or the `result` hash of the step.
- **Typing**: each visitor (except lock_series_poc) has an RBS file with `def self.<event>: (RQL::loggerObj logger, bool log_sampled, ...) -> void` / `RQL::instrObj instrumenter`.

## Claude rules
**When to use**
1. Any new log line or instrumentation event inside `AcquireLock` (and its mixins) or `LockSeriesPoC` must go through a visitor method; never call `logger.*` or `instrumenter.notify` directly in algorithm code.
2. Add a LogVisitor event for each new meaningful step or branch of the algorithm (start, decision, exit, success). Add an InstrVisitor event only for outcomes users would want to measure (obtained, held/released, completed); not for internal steps.
3. Fine-grained per-attempt logging belongs in `TryToLock::LogVisitor` and must be gated by `log_lock_try`.
4. For a new algorithm component (new mixin under `acquire_lock/`), create its own `<component>/log_visitor.rb` (and `instr_visitor.rb` if needed) and `require_relative` it from the component.

**How to write one**
5. Method: inside `class << self`, named exactly after the event (snake_case, `__` for phase/detail), full YARD with `@return [void]`, `@api private`, `@since <next version>`.
6. Parameters: port first, sampled flag second, extra gates next, then `lock_key`, then event data; lock events take `rw_mode` (after `access_strategy` for logs, after `lock_key` for instrumentation); for instrumentation keep the user `instrument` value last. Keep the list explicit (see `arguments.md`).
7. First line: `return unless <sampled>` (plus gate). Don't compute sampling inside the visitor and don't recompute it at the call site per event; reuse the operation's `log_sampled` / `instr_sampled`.
8. Logs: `logger.debug do ... end rescue nil` with message `"[redis_queued_locks.<event>] "` (`try_lock.` prefix for TryToLock steps) and `key => value` pairs, quoting strings, using the existing abbreviations (`acq_id`, `hst_id`, `acs_strat`, `queue_ttl`).
9. Instrumentation: `instrumenter.notify('redis_queued_locks.<event>', { ... }) rescue nil` with shorthand Symbol keys; reuse the standard payload keys (`lock_key`, `rw_mode`, `ttl`, `acq_id`, `hst_id`, `ts`, `acq_time`, `hold_time`, `instrument`). Event names are public API: never rename or remove one without being asked, and document new ones in the README/CHANGELOG.
10. Use the same method name in LogVisitor and InstrVisitor when both report the same event.
11. Add the method to the mirrored RBS visitor file (`RQL::loggerObj` / `RQL::instrObj`, `bool` sampled flag, `-> void`) and cover the new event in specs via the fake logger/notifier (assert on the `[redis_queued_locks.<event>]` prefix or event name).
12. Never pass Redis reads (or other costly computations) as visitor arguments unconditionally: arguments are evaluated before the visitor's `return unless` guard. Gate them at the call site with the same condition (`(log_sampled && log_lock_try) ? rconn.call('HGETALL', ...).to_h : {}`).
13. A new branch/exit of the read/write algorithm gets its own TryToLock event (`exit__write_request_ahead`, `exit__read_request_ahead`, `exit__read_lock_still_obtained`, `single_process_lock_conflict__lock_upgrade` are the existing ones). Don't add events to the default write success path: specs assert its exact log sequence (10 lines with `log_lock_try`).

## Recommendations (proposed, not yet project policy)
Apply to new or touched code; don't refactor existing code for these unless asked.
1. Give the release operations (`release_lock`, `release_all_locks`, `release_locks_of`) their own `InstrVisitor`/`LogVisitor` instead of inline `instrumenter.notify`, and either use or drop their currently unused `logger` param.
2. Use one error-swallowing style consistently (visitors use modifier `rescue nil`, release modules use `run_non_critical`). Both silently hide bugs such as a `NoMethodError` inside the log block, so consider reporting swallowed errors when the debugger is enabled.
3. Keep log and instrumentation event names in one registry constant (e.g. `RedisQueuedLocks::Instrument::EVENTS`) so README, specs and RBS can be checked against it.
4. Fix the RBS path mismatch: `sig/.../acquire_lock/yield_with_expire/log_visitor.rbs` mirrors `lib/.../acquire_lock/yield_expire/log_visitor.rb`; add RBS for `lock_series_poc` visitors when the PoC stabilizes.
