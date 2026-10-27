---
paths:
  - "CHANGELOG.md"
---

# CHANGELOG rules (`CHANGELOG.md`)

## Observed conventions
- Keep a Changelog layout: `## [Unreleased]` on top, released versions as `## [X.Y.Z] - YYYY-MM-DD`; sections `### Added`, `### Changed`, `### Fixed` (`### Removed` once); entries are `- ` bullets, mostly ending with `;`.
- Markers: `[**Breaking**]` for incompatible changes, `*Brand New Feature*` for a fundamentally new feature (rule 8; older spellings: `Brand new Feature`, `Brand New Extremely Major Feature` of the swarm mode).
- Code identifiers in backticks: methods `#lock`/`#lock!`, options `priority:`, config keys `config['key']`, errors `RedisQueuedLocks::ArgumentError`, events `redis_queued_locks.<event>`.
- Anti-pattern: the 1.18.0-1.21.0 and lock priorities sections grew into implementation reports (algorithm steps, Redis commands, round trips, score formulas, full lists of affected events, multi-line sub-bullets) before they were compacted by this rule (`git show 28adc76:CHANGELOG.md` keeps the full text).

## Claude rules
1. Compact entries: one bullet per subject-level change, 1-2 lines (3 at most). A subject-level change is what a gem user gets, loses or has to do: a new method/option/config key/event/log key/error, a changed default/result shape/behavior, a fixed wrong behavior, a breaking change or an upgrade requirement.
2. No deep details: no algorithm steps, Redis commands, round trips/pipelines/transactions, internal modules/methods/constants, key layouts, score formulas, costs, implementation edge cases, reasoning or alternatives. They live in README (usage), YARD, `.claude/project-overview.md` and the rules; an entry may point to its README section instead.
3. Internal-only changes (refactoring, specs, CI, internal RBS, `.claude` docs, perf work without a visible effect) get no entry; a visible effect of such work (a typing change for Steep users, a notable speedup) gets one short line.
4. Sub-bullets only to list separate user-visible items of one feature (its new options, config keys, events), one short line each; one nesting level at most.
5. Collapse lists that share one change: "lock acquirement logs and instrumentation events carry the Integer `priority`", not the 20 event names (the exact lists live in README `## Logging` / `### Instrumentation Events`).
6. A fix: the wrong behavior and the scope in one sentence (`` `#zombies_info`: the default `lock_scan_size` was read from the wrong config key ``), not the mechanism of the bug.
7. Breaking changes and upgrade requirements: the `[**Breaking**]` marker or one sentence of what to do (`upgrade all processes before using positive priorities`), without the reasoning.
8. A fundamentally new feature gets its own entry marked `*Brand New Feature*`: a new capability of the library as a whole (Swarm Mode, Lock series, Read/Write locks, Lock Index, Lock Request Prioritization) or globally new support (a Redis-compatible server such as Garnet, a new runtime or platform); not an extension of the existing functionality (a new option, method variant, result field, event or log of an existing feature). Format: `- *Brand New Feature*: **<Feature Name>**: <one-sentence summary> (see README "<section>"):` first in `### Added`, the feature's methods/options/config keys/events and upgrade requirements as its sub-bullets (rule 4).
9. One feature = one entry: a later step of the same feature updates its entry instead of adding a bullet per step. Released sections are not rewritten unless asked.

## Example
- Bad: `` - every lock request drops dead lock requests of its own priority in both lock queues (in the same queueing pipeline: no new commands and round trips); dead lock requests of other priorities that block the lock request ... are dropped ... in one more round trip of the same attempt (up to 5 such round trips per attempt); ``
- Good: `` - *Brand New Feature*: **Lock Request Prioritization**: `priority:` of `#lock`/`#lock_series` (`-100..100` or a priority name, `0` by default) orders waiting lock requests (strict priority, FIFO inside a priority), see README "Lock Request Prioritization"; ``
