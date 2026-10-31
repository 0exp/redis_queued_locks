---
name: rql-code-review
description: Code review of redis_queued_locks changes against the project's own invariants and conventions (WATCH/MULTI lock safety, read/write key families and the order between modes, lock request priority bands and their head-driven dead request cleanup, the lock index superset invariant in both lookup modes, one-pass iteration, operation-module independence, long explicit argument lists, log/instrumentation visitors, RBS/Steep, docs sync). Use when the user asks to review / code-review (ревью, код-ревью, проверь изменения) a branch, diff, commit range, PR, staged changes or files of this repository. Also run it automatically on the uncommitted changes when a task in this repository is done and ready to commit, right before asking about the commit (never earlier). Spec files (*_spec.rb) are exempt from style/principle checks until the suite rework; only the coverage of the changed library behavior is checked.
argument-hint: "[uncommitted | base..head | <commit> | pr <N> | staged | <paths...>]"
---

# redis_queued_locks code review

Review a change of this gem the way its maintainer does: lock safety first, then the project invariants
(read/write locks, lock request priorities, lock index, iteration), then architecture, types, docs and style. The rules live in
`CLAUDE.md`, `.claude/project-overview.md` and `.claude/rules/*.md`; this skill says what to check, where the
details are, and what must not be reported.

- Report defects, with a concrete failure scenario and the rule they break. Every rule-based finding cites its
  source (`acquirer.md#12` = rule 12 of the "Claude rules" list in `.claude/rules/acquirer.md`, `overview "Lock index"`).
- The review is read-only: don't edit, stage or commit anything. After a review on request, offer to fix the
  findings; the automatic pre-commit run acts on them itself (see "When to run").
- Write the report from the template that matches the Claude Code `language` setting, English when that language
  has no template (§7); code identifiers, rule names and quotes stay as they are.

## When to run

- On request: the user asks for a review (any scope of §1).
- Automatically, as the pre-commit review (`git.md#7`): when a task in this repository (a feature, a fix, a prompt,
  a docs or `.claude` change) is done and committable, at the moment the commit question would be asked or a commit
  authorized in advance would be made (`git.md#8`). Never earlier: not during the implementation, not after
  intermediate edits, not for incomplete or red states (`git.md#9`), not for an explicit commit request.
  - Scope `uncommitted`: the changes of the step (earlier steps are reviewed before their own commits).
  - The completion checks have just run: report their results, don't re-run them. A step without code changes (docs,
    `.claude` files) gets a docs review only: accuracy against the code, the overview and the rules, cross-file
    consistency (§4 K).
  - Blocker/Major findings in the step's own changes mean the step is not complete: fix them as part of the task (the
    review itself stays read-only), re-run the affected checks and review the fixed hunks once more; findings that
    need the user's decision, or remain after that pass, are reported instead of the commit question (`git.md#9`).
  - The report is followed by the commit question (`git.md#7`) with the verdict and the remaining Minor/Nit findings.

## 1. Scope

| Argument | Diff to review |
|---|---|
| `uncommitted` | the changes of the current step: `git diff HEAD` (staged + unstaged) plus untracked files (`git status --porcelain`); the scope of the automatic pre-commit run |
| none | the branch against `master`: `git merge-base master HEAD`, then `git diff <base>` (committed + staged + unstaged) plus untracked files (`git status --porcelain`). On `master` with a clean tree there is nothing to review: ask for a target |
| `base..head` / `<commit>` | `git diff base..head` / `git show <commit>` |
| `staged` | `git diff --cached` |
| `pr <N>` | `gh pr diff <N>` when `gh` is installed, otherwise `git fetch origin pull/<N>/head` + `git diff master...FETCH_HEAD` (no local branch) |
| `<paths...>` | the whole files: report real defects and rule violations, but pre-existing known debt (§5) is not a finding |

- Start with `git diff --name-status` and `git diff --stat`, record the base sha.
- Environment artifacts are never part of a change (`git.md#10`): `rbs_collection.lock.yaml` rewritten by
  `rbs collection install`, `coverage/`, `.gem_rbs_collection/`, `.claude/settings.local.json`, `.DS_Store`.
  Flag them only when they are committed or about to be.
- Big diffs: learn the intent first (commit subjects `git log --format=%s <base>..HEAD`, the CHANGELOG
  `[Unreleased]` and overview hunks), then review in dependency order: `resource.rb`/`config.rb` →
  `acquire_lock/*` → other `acquirer/*` → `client.rb` → `swarm/*` → `sig/` → docs; specs last, for coverage only.

## 2. Context to load before judging

Read the rule files of the touched paths and the overview sections of the touched topics (lock flow, "Read/Write
locks in the architecture" + "Read/Write locks", "Lock request prioritization in the architecture" + "Lock request
priorities", key layout, "Lock index", lock lookup modes, events, errors, conventions):

| Changed path | Rule files |
|---|---|
| `lib/**` | `logic.md`, `type-checking.md` |
| `lib/redis_queued_locks/acquirer/**` | + `acquirer.md`, `arguments.md`, `visitors.md` |
| `client.rb`, `config.rb`, `swarm.rb` | + `arguments.md` |
| `swarm/**`, `sig/redis_queued_locks/swarm/**` | + `swarm.md` |
| `logging/**`, `instrument/**` | + `visitors.md` |
| `sig/**`, `Steepfile`, `rbs_collection.yaml` | `type-checking.md` |
| `spec/**` | `tests.md` (coverage expectations only, see §3) |
| `CHANGELOG.md` | `changelog.md` |
| commits / messages | `git.md` |

- Read every changed method in full, its callers, its RBS signature and every copy of duplicated logic. Copies
  that must change together:
  - write lock info formatting `LockInfo.lock_info` ↔ `Locks.extract_locks_info`; reader formatting
    `LockInfo.read_lock_info` ↔ `Locks.read_lock_info`; request formatting `QueueInfo.queue_info` ↔
    `Queues.extract_queues_info`;
  - `each_lock_name_batch` in `Locks`, `Queues`, `Keys`, `ReleaseAllLocks`, `ReleaseLocksOf`,
    `ClearDeadRequests` (inline iteration in `FlushZombies.flush_lock_index_zombies` and
    `ZombieInfo.each_lock_index_zombie_lock`); `ZombieInfo` lookups mirror `FlushZombies`;
  - `EXTEND_LOCK_PTTL` in `TryToLock` and `ExtendLockTTL`;
  - lock state reply reading in `try_to_lock` Step 0.1 and `precheck_lock` (shared `pipeline_lock_state`,
    position constants, `lock_obstacle`, `log_lock_obstacle`);
  - the argument validations of `AcquireLock` Step 0 and `LockSeries` Step 0 (reserved `meta` keys, numeric ranges, the
    `priority` resolution and range check: the same messages);
  - the attempt flow of `TryToLock#try_to_lock`/`precheck_lock` and `TryToLockSeries#try_to_lock_series`/`precheck_lock_series`
    (the commands and decisions are shared helpers, the flow exists twice), `drop_dead_requests_ahead` and
    `drop_series_dead_requests_ahead`;
  - the band liveness rule (a request is dead when its score is `<= Resource.lock_priority_band_dead_score(dead_score,
    band)`): `TryToLock#dead_request_priority` / `pipeline_dead_requests_removal` and `ClearDeadRequests.drop_dead_requests` /
    `drop_dead_requests_by_priority`;
  - the `'priority'` field of a request (`Resource.lock_request_priority`) in `QueueInfo.queue_info` and
    `Queues.extract_queues_info`;
  - lock-family options in `Client#lock`, `#lock!`, `#lock_series`, `#lock_series!` and the keyword lists of
    `AcquireLock.acquire_lock` and `LockSeries.lock_series`.
- Next version for `@since`/`@version`: the version the unreleased work already uses (`git diff <base> -- lib |
  grep -oE '^\+.*@(since|version) [0-9.]+'`, the CHANGELOG `[Unreleased]` code), otherwise the next minor of
  `RedisQueuedLocks::VERSION` (`version.rb`); don't take the maximum over `lib/` (old tags can be wrong).
  A value older than `VERSION` on new code, a method behavior/signature change (a typo fix in the method or keyword
  argument name included; a renamed positional parameter is not a signature change) without the method `@version` bump, or a
  class/module header `@version` that does not match its latest interface change (`logic.md#2`: signatures,
  added/removed methods, `extend`/`include`/`prepend`, the superclass; behavior changes never bump the header) is a
  Minor finding.

## 3. Spec files are exempt (until the suite rework)

`spec/**/*_spec.rb` are not ideal and are going to be rewritten entirely (header `NOTE` of
`spec/redis_queued_locks_spec.rb`, overview "Conventions", rspec-retry as temporary debt). Until then any coding
principle may be broken there. Never report the way specs are written: duplication, long or nested examples, `sleep` waits,
anonymous fakes, magic numbers, naming, structure, `it`/`specify`, rubocop directives, thread handling,
cleanup style, retry reliance, file size, the `tests.md` rules on writing specs and its recommendations.

Still in scope (the exemption covers how specs are written, not whether the library is tested):
1. Coverage of the changed library behavior (finding against the `lib/` change, category `test-coverage`):
   new behavior without an example; RW changes without both modes (`tests.md#13`); lock-iterating changes without
   the small-batch examples of both lookups and the recorded-command checks (`acquirer.md#7`); new lock index
   writes without `describe 'lock index'` examples (`acquirer.md#16`); a changed pipeline layout without an updated
   `lock state pipeline layout` spec (`acquirer.md#15`); a touched obtaining transaction that the spec
   `the lock obtaining transaction indexes the lock` no longer exercises (it drops the index entry right before the
   obtaining `MULTI`); a new log/instrumentation event without a fake logger/notifier assertion (`visitors.md#11`).
2. A changed spec that asserts behavior contradicting the overview/rules, or that can't fail for the behavior
   it claims to check (vacuous expectation, expectation never reached).

`spec/spec_helper.rb` and `spec/setup_simplecov.rb` are support files: review them for correctness only (the
`around` hook that switches `config['lock_index_enabled']` and restores the library default).

## 4. Checklist

### A. Lock safety and Redis correctness
- Mutual exclusion only from the lock state checked under `WATCH`/`MULTI` (`logic.md#6`, `#14`); Lua only for the
  existing write TTL extension/decrease, no new Lua in the RW acquisition path unless the user asked. No
  check-then-set in Ruby without a transaction; queues, client clocks, the lock index and the pre-check never
  decide mutual exclusion (the pre-check never obtains the lock).
- Asymmetric WATCH (`acquirer.md#12`): writers watch `[lock_key, lock_readers_key]`, readers `[lock_key]` only.
  No write to a watched key outside `MULTI` after `WATCH` (aborts the own `EXEC`); never merge `WATCH` into a
  pipeline (unsafe on reconnect).
- Lock state: write needs no write lock and no live readers; read needs no write lock; same-acquirer cases go
  through `conflict_strategy`; read→write upgrade never works through (`:conflict_lock_upgrade`, waits with
  `:wait_for_lock`).
- Time: reader liveness and expirations in Redis time (`TIME` → `Resource.redis_time_ms`, `PEXPIRE`); client
  `Time.now.to_f` only for queue positions, `ts` fields, zombie probes; lock index scores in
  `Resource.lock_index_time` (epoch ms) + grace. Readers are live only while `score > now`: never decide by
  `ZCARD`/`EXISTS` alone.
- TTLs: max-TTL keys (registry, reader data, queues) get the `PEXPIRE NX` + `PEXPIRE GT` pair (`GT` alone sets
  nothing on a key without TTL); `PTTL` sentinels handled (`-2` missing, `-1` → `Float::INFINITY` / `'+inf'`);
  units right (ttl ms, `queue_ttl` s → `(queue_ttl * 1_000).ceil`, `zombie_ttl` ms → `/ 1_000.0`), integers for
  `PEXPIRE`.
- Replies read by position (`acquirer.md#15`): `NOTE: (pipeline layout)` next to the commands, conditional
  commands form a tail after the unconditional ones and are read under the same condition, position constants
  (`LOCK_STATE_*`, `QUEUE_HEAD_REPLY`, `KEY_STATE_REPLIES`, `LOCK_STATE_REPLIES`) and the layout spec updated;
  the reentrant write extension check `result.size == (lock_index_enabled ? 5 : 4)` follows its `MULTI`.
- Round trips of the hot path must not regress silently (overview "Lock acquisition flow"): `lock {}` = 4, a
  failed attempt = 3, a failed retry = 1 (pre-check), `fail_fast` on an obtained lock = 1, `unlock` without
  readers = 1; the only extra round trips are the dead blocking request removals of Step 2.2 (one per removal, none
  while nothing dead blocks). Independent reads share one `pipelined` round trip (also inside `multi(watch:)`).
- New destructive paths (delete/shorten a lock) check the owner, unless the change documents the trade-off as
  accepted by the user (like the known limitations in §5).
- Shared mutable state behind `Utilities::Lock#synchronize` (`logic.md#9`).

### B. Read/write awareness (`logic.md#13`, `acquirer.md#12`, overview "Read/Write locks in the architecture")
- Every operation over locks, queues, zombies or lock info covers `rql:lock:*`, `rql:lock_queue:*`,
  `rql:lock_readers:*`, `rql:lock_read_queue:*` and `rql:lock_reader:<name>:<acq_id>`; every attempt prunes the dead
  requests of its priority band in both queues (and the bands of the dead requests that block it, §4 C);
  dequeue/cleanup removes the request from the queue of its mode.
- Order between modes (`:queued`, `find_opposite_request_ahead`/`lock_obstacle`, shared by the attempt and the
  pre-check): a write request must be the head of the write queue and have no earlier read request, a read request
  must have no earlier write request ("earlier" = the `(score, acq_id)` comparison on the shifted scores); the
  order never decides mutual exclusion.
- The held mode decides the release: `acquire_lock` keeps the try result `rw_mode` as `held_rw_mode` for
  `yield_expire` (a read request that works through the own write lock holds the write lock); a reader is released
  owner-safe (`ZREM` of the own member + `DEL` of the own reader data), `unlock` releases everything; the internal
  `rw_mode` never appears in the public `lock` result.
- Read lock extension (`extend_lock_ttl(..., read_write_mode: :read)`): `multi(watch: [lock_key])`, only a live read
  lock and only while no write lock exists, never revives an expired reader; `all_read_locks: true` extends every
  live reader (`ZADD XX INCR`), the registry/reader data TTLs keep the max (`PEXPIRE NX` + `GT`).
- `fail_fast`: write fails on a write holder or live readers, read fails on a write holder (or the own live read);
  lock series: one mode for the whole series, one `acquirer_position` in all its queues, all locks in one transaction,
  nothing held between attempts, `release_lock_series` releases only the locks the series obtained and only the current
  acquirer's (write: compare-and-delete in one transaction, read: `ZREM` + `DEL`), extended reentrant locks get their
  ttl back (overview "Lock series").
- Write-only result shapes stay unchanged; read keys/fields appear only when read data exists.
- `read_lock_key` is `nil` for write requests; reader data is a data carrier only (the registry decides existence),
  without `acq_id`/`hst_id`; don't store derivable values; a new lock field updates every formatting copy (§2,
  `acquirer.md#11`); `rw_mode` stays a reserved `meta` key.
- Backward compatibility: data written by older versions (readers with `acq_id`/`hst_id`, names without index
  entries) is still read correctly; a key/data format change states the rolling-deploy requirement in README and
  CHANGELOG.

### C. Lock request priorities (`acquirer.md` "Lock request priorities", overview "Lock request prioritization in the architecture")
- Queue scores only through `Resource` (the single source of the layout): `calc_initial_acquirer_position(priority)`
  (enqueue time - `priority * LOCK_PRIORITY_BAND`), the requeue check `dead_score_reached?(position, priority, ttl)`
  (a requeued request goes to the end of its own band), decoding with `lock_request_priority(score)`; no raw
  `Time.now.to_f` positions, no own band arithmetic outside `Resource`.
- Dead request pruning per band only: `ZREMRANGEBYSCORE <queue> <lock_priority_band_floor(p)>
  <lock_priority_band_dead_score(dead_score, p)>`; a new `-inf .. now - ttl` range on a request queue is a Blocker
  (it drops alive higher-priority requests and keeps dead lower-priority ones); full clears (`-inf .. +inf`) and
  member removals (`ZREM`) are band-independent; `-inf .. -inf` drops the requests at `-inf` only (manual writes:
  always dead, out of all bands; `+inf` is never dead), and decoding an infinite score must never raise
  (`lock_request_priority` maps `-inf`/`+inf` to the range bounds).
- Head-driven cleanup, cost independent of the priority range: the queueing prunes the own band in both queues (in
  its pipeline, before `ZADD NX`: a requeued request must not lose its new position to the removal of its old one),
  Step 2.2 (`drop_dead_requests_ahead`, attempt and pre-check, `:queued` only) drops the bands of the
  dead blocking requests (the write queue head for writers, the earlier opposite-mode request) with the queue heads
  re-read in the same round trip, bounded by `MAX_DEAD_REQUEST_REMOVALS`; `ClearDeadRequests` prunes only the bands
  whose first request is dead. Never enumerate the priority range per attempt or per queue; any band is decoded
  (also out of the range: newer versions).
- Ordering uses the shifted scores as is (queue heads, the cross-mode `(score, acq_id)` comparison): strict priority
  between bands, FIFO inside a band, the same in both modes; the priority never takes part in mutual exclusion.
- The option: `priority:` in all four lock `Client` methods (default `config['default_lock_priority']`), an Integer
  `MIN_LOCK_PRIORITY..MAX_LOCK_PRIORITY` or a name of `config['lock_priorities']` (the client-wide registry is
  forwarded as the internal keyword `lock_priorities:`, never a public keyword); the name is resolved and the range
  checked in `AcquireLock` Step 0.1 and `LockSeries` Step 0.1: code below sees Integers only (RBS
  `RQL::lockPriority` at the boundary, `Integer` below); config validators for both keys, and a name of
  `default_lock_priority` checked against `lock_priorities` by `Config` (after a `configure` block, before a direct `[]=`).
- Observability: every lock acquirement log line and event (classic, reentrant: the requested priority, lock series:
  the series priority, `lock_obtaining_failed`) carries the Integer `priority` right after `rw_mode`; try-lock logs
  that name another request carry its decoded priority (`first_priority_in_queue`, `ahead_priority`, `dead_priority`)
  computed at the call site only when `log_sampled && log_lock_try` (one helper: `TryToLock#logged_request_priority`); info results carry `'priority'` (every copy).
- Compatibility: priority `0` keeps the raw timestamp scores of older versions/data; a change of the score layout or
  of the pruning states the rolling-deploy effect in README and CHANGELOG (older versions prune positive-priority
  requests as dead ones).

### D. Lock index, both lookup modes (`acquirer.md#16`, overview "Lock index")
- Disabled mode (default): no lock index command at all (`LOCK_INDEX_KEY` only under `if lock_index_enabled` /
  after `return unless lock_index_enabled`), no `ZSCAN`, queues without TTL. Enabled mode: no keyspace `SCAN`
  except `ReindexLocks`.
- Superset invariant: every key-creating command is followed by `ZADD <index> GT <now + lifetime + grace> <name>`
  in the same pipeline/transaction, after the key command; the obtaining `MULTI` indexes the lock itself; every
  extension is followed by `ZADD XX INCR`; scores never decrease; names are removed only in the same `MULTI`
  that deletes all their keys (`ReleaseLocksOf`, `YieldExpire` releases and `FlushZombies` never remove names).
- Lock index commands are conditional tails: reply positions never depend on the mode.
- A new key family: distinct prefix `rql:lock_<kind>:<name>` (never a suffix of the name), bounded TTL in the
  enabled mode, covered by the index score, `Resource.lock_key_family`/`lock_name_from_key`, both lookups and
  `ReindexLocks`.
- `lock_index_enabled` is client-wide (`arguments.md#9`): read from `config` inside `Client`/`Swarm` and forwarded,
  never a keyword of a public method; the flusher Ractor gets a copy. `lock_index_grace_period` is forwarded by
  `lock`, `lock!`, `lock_series`, `lock_series!`, `reindex_locks`. Pruning (`ZREMRANGEBYSCORE <index> -inf
  <now - 1>`) stays in the queueing pipeline, `flush_zombies`, `clear_locks`, `clear_dead_requests`.

### E. Iteration and performance (`acquirer.md#7`, `arguments.md#7`)
- One pass per operation: one `SCAN` over `KEY_PATTERN`/`ALL_LOCK_QUEUES_PATTERN` classified by
  `Resource.lock_key_family`, or one `ZSCAN` via `each_lock_name_batch` (expired scores skipped by `Resource.lock_index_score_expired?`: the `"inf"` score never expires). Never `KEYS`,
  never one round trip per key; per-key commands in pipelined batches collected across pages, plus the
  remainder batch.
- A new lock-iterating operation implements both lookups side by side, chooses the lookup in one place
  (`lock_index_enabled ? index_x : scan_x` or one `if`/`else` with `(lock index)`/`(keyspace)` step comments) and
  keeps the shared processing in one copy.
- No `EXISTS` next to `ZRANGE`/`HGETALL`: Redis never keeps empty sorted sets/hashes.
- Hot path (`AcquireLock`, `TryToLock`, `YieldExpire`, `DequeueFromLockQueue`, visitor call sites): no wrapper
  objects, hash merging, splats to build arguments, closures for argument plumbing, new `{}` per attempt (use
  `NO_LOCK_DATA`); keys computed once in `acquire_lock`; log-only Redis reads gated at the call site
  (`acquirer.md#13`); no `Set` splatted in a loop.

### F. Architecture and API design
- `Client` only fills defaults from `config['...']` and delegates (`logic.md#3`); an `x!` variant exists only when it
  must raise and repeats the full keyword list.
- No parameter objects, `Struct`/`Data.define`/`OpenStruct`, builders, `**opts`, `options = {}`, `...` forwarding
  (`arguments.md#1`, `#3`); a new public option goes to every `Client` variant with a `config` default
  (`arguments.md#2`, `#10`) and is forwarded by name with shorthand; defaults live only in `Client`, internal
  params are required (`arguments.md#4`); positional order: subject → domain data → observability tail
  `logger, instrumenter, instrument, log_sampling_*, log_sample_this, instr_sampling_*, instr_sample_this`, lock key
  params `lock_key, read_write_mode, lock_key_queue, read_lock_key_queue, lock_readers_key, read_lock_key, lock_name,
  acquirer_id, host_id, ...`, TTL params `ttl, queue_ttl, lock_index_enabled, lock_index_grace_period`
  (`arguments.md#5`); every call site and the RBS updated with the signature.
- Operation modules are independent (`acquirer.md#14`): no calls to another `Acquirer::*` module and no references to
  its RBS types (exception: the acquisition core, `AcquireLock` and `LockSeries`); shared logic only via `Resource`/`Utilities`;
  a duplicate keeps the original name and shape with a `NOTE` that it is duplicated on purpose; every copy changes
  in the same change. Don't copy the `WithAcqTimeout` → `LockInfo`/`QueueInfo` debt.
- New operation: `acquirer/<snake_name>.rb` with one public `class << self` entry named after the file and private
  helpers, `require_relative` in `acquirer.rb`, thin `Client` method, RBS, spec, README/CHANGELOG
  (`acquirer.md#1`). Mutating operations follow the two-layer pattern (timing wrapper + private `fully_*`,
  `acquirer.md#2`).
- Results: `{ ok:, result: }` only at the public boundary (`Client`, `Acquirer::*`, `Swarm` facade actions) with
  Symbol statuses and abbreviated Symbol keys (`rel_*`, `*_cnt`, `*_time`); info queries return a String-keyed
  Hash/Set or `nil`; swarm element internals return bare scalars (`swarm.md#15`). Raise only in `x!` methods, the
  `raise_errors` path of `AcquireLock` and on invalid arguments (`RedisQueuedLocks::ArgumentError`), with the lock
  key / acquirer id in the message.
- Keys only via `Resource.prepare_*`, `*_PATTERN`, `SWARM_KEY`, `LOCK_INDEX_KEY` (`logic.md#5`): flag every new
  `'rql:...'` literal outside `resource.rb`.
- Config: `setting` + `validate` in `config.rb` (booleans `val == true || val == false`, Integers with ranges; per-call
  numeric options validated with the same ranges in the operation module, `logic.md#7`), dotted
  keys for groups, unit in a trailing `# NOTE:` comment, read as `config['key']` (`logic.md#7`), one typed
  `Config#[]` overload line per key in `config.rbs` (`type-checking.md#12`). Errors:
  `class XError < Error; end` in `errors.rb`, each under the global base of its branch (`Error`, `ArgumentError`,
  `Exception`: super exceptional cases only, with the reason in the comment; `logic.md#15`). Runtime dependencies:
  `redis-client` only; dev gems in `Gemfile`.
- `AcquireLock`: new behavior as a new step or mixin with `# Step N.x` numbering and consistent `acq_process` keys
  (`acquirer.md#10`).

### G. Swarm, Ractors, threads (`swarm.md`)
- Redis work in stateless class functions shared by the main loop and the manual API (`#1`); main loops build
  their own client with `RedisClientBuilder` inside the loop thread (`#4`).
- Into `Ractor.new` only copied plain values (`config.slice(...)`, scalars, `lock_index_enabled`): no `rql_client`,
  logger, Redis client; inside only shareable constants and module functions (`#4`, `#5`).
- Ports (`#13`): results port created in the main Ractor, commands port inside the element Ractor, `monitor`
  registered before waiting, one reply per command, Symbol messages reserved for death notices; no
  `Ractor.receive`/`Ractor#send`/default port; names end in `_port`, block params `r_res_p`/`r_com_p`.
- Threads: kill + join inside the Ractor (`#14`), `abort_on_exception = false` for main loops, no retry loops in
  elements (`#8`); state changes and request/reply pairs inside `sync.synchronize` (`#6`); the supervisor is
  stopped before elements are killed or re-created (`#9`).
- Lifecycle names and semantics identical in both bases (`#7`); a new element is registered everywhere (`#3`);
  status shapes `{ running:, state: }` with `'non_initialized'` and their RBS (`#10`).

### H. Logging and instrumentation (`visitors.md`)
- Logs/events of `AcquireLock`, `LockSeries` and their mixins go through visitor methods (`#1`); mutation
  modules write one log line and one event inline inside `run_non_critical`, gated by `log_sampled`/`instr_sampled`
  (`acquirer.md#9`).
- Observability coverage (`logic.md#16`): a new or changed logic that creates/changes/deletes keys without logs and
  instrumentation, a mutation event/log that times an internal part instead of the whole root operation, a mutation
  payload without `instrument`, a `Client` mutation method without the observability keywords, or instrumented lock
  info queries are findings; the swarm elements are known debt.
- Visitor shape: `class << self`, method name = event name (`__` between phase and detail), same name in the
  Log and Instr visitors, first line `return unless log_sampled` (`&& log_lock_try` for `TryToLock` steps), one
  `logger.debug do ... end rescue nil` with `"[redis_queued_locks.<event>] "` and `key => 'value'` pairs, or
  `instrumenter.notify('redis_queued_locks.<event>', { ... }) rescue nil` with shorthand Symbol keys (`#5`-`#9`).
- Parameter order: port, sampled flag, extra gates, `lock_key`, data; `rw_mode` after `access_strategy` (logs) or
  after `lock_key` (instrumentation), user `instrument` last (`#6`). `rw_mode` is the requested mode in
  `AcquireLock`/`TryToLock`/`DequeueFromLockQueue`, the held mode in `YieldExpire`, the series mode in `LockSeries`.
- Sampling decided once per operation (`Logging.should_log?` / `Instrument.should_instrument?`) and passed down (`#7`).
- Event names and payload keys are public API: no rename/removal without the user's request; no new event on
  the default write success path (`#13`); new or changed log keys/payload keys go to README `## Logging` /
  `### Instrumentation Events` and CHANGELOG (`#14`).

### I. Types (`type-checking.md`)
- Every changed method, param, return shape, constant or ivar is mirrored in `sig/` (`#1`): nested module blocks,
  `use RedisQueuedLocks as RQL` / `use RedisClient as RC`, shared types (`RC::client`, `RQL::loggerObj`,
  `RQL::instrObj`, `samplerObj`), `type xxxResult = { ok: bool, result: ... }` for public results, literal types for
  swarm internals, `Hash[String, ...]` instead of String-keyed records (they crash Steep).
- `# steep:ignore` only where Steep reports a diagnostic (strict mode fails on redundant ignores); prefer
  `# @type var x: T` / `#: T` and tuple annotations of pipeline results; a needed ignore without an honest
  annotation carries `NOTE: (steep)`; never shape runtime code around Steep (`#5`). `Steepfile` is never loosened (`#6`).
- RBS must match runtime values (runtime type checks run the suite): e.g. `Integer|Float` where a Float can arrive.

### J. Ruby style of the codebase
- `# frozen_string_literal: true`; compact constant paths (`module RedisQueuedLocks::Acquirer::Keys`); namespace
  files only `require_relative` (`logic.md#1`).
- YARD on every class, module, constant, attr and method: `@param`/`@option`/`@return` (`Format: { ... }` for hash
  results), blank `#`, `@api public|private`, `@since <next>`; a new `include`/`extend`/`prepend` line has
  `# @since <next>` right above it (no YARD block; the version that added the mixin); behavior/signature changes bump
  `@version <next>` on the method; the module/class header `@version` changes only with the interface (signatures,
  added/removed methods, `extend`/`include`/`prepend`, the superclass), never for behavior changes inside the methods
  (`logic.md#2`).
- Comments: `# NOTE:` with `#   - item;` lists, `# Step N.x` in algorithms, `(RW)`/`(lock index)`/`(keyspace)`
  tags, `NOTE: (pipeline layout)`/`(transaction layout)` for positional replies.
- Redis: uppercase String commands, String numeric args (`'0'`, `'-1'`, `'-inf'`, `'+inf'`), `redis.with do |rconn|`
  for multi-command work, `multi do |transact|`, `pipelined do |pipeline|`, named reply variables (`hget_cmd_res`,
  `lock_state`), Lua as a frozen `<<~LUA_SCRIPT.strip.tr("\n", '').freeze` constant (`acquirer.md#5`, `#6`).
- Normalization with `Float(...)`/`Integer(...)` inside `tap do |lock_data|`, optional fields guarded with
  `if lock_data['x']` (`acquirer.md#11`).
- Idioms: `x == nil`/`x != nil` or truthiness (not `.nil?`); `raise(Klass, "message")` with `\` continuations;
  subject-less `case` with `start_with?` instead of regexps on hot paths; shorthand `key:` forwarding;
  `clock_gettime` (µs) for durations reported as `((finish - start) / 1_000.0).ceil(2)` ms, `Time.now.to_f` only for
  `at:`/`ts`; names `rconn`, `transact`, `pipeline`, `*_key`, `*_queue`, `acquirer_id`/`host_id` (`acq_id`/`hst_id`
  in data, logs and payloads), private `fully_*`, `scan_*`/`index_*` lookups, `swarmed__*` predicates.
- Rubocop: only specific `Metrics`/`Layout` cops disabled locally with a paired `enable`, never
  `# rubocop:disable all` in new code (`logic.md#10`); long signatures are not "fixed" (`arguments.md#8`).
- Suggestions only (`logic.md` recommendations, not violations): correctly spelled new identifiers (don't copy the
  known typos).

### K. Docs and process
- The same change updates `.claude/project-overview.md` and the affected `.claude/rules/*.md` for every new/changed
  key, option, result shape, event, algorithm step or limitation (`logic.md#12`), README and CHANGELOG
  `[Unreleased]` for user-visible behavior, and the YARD of the touched `Client` methods.
- CHANGELOG entries are compact (`changelog.md`): one 1-2 line bullet per subject-level change, no implementation
  details (algorithm steps, Redis commands, round trips, internals, full event lists), no entries for internal-only
  changes; one entry per feature, released sections untouched; a fundamentally new feature or globally new support
  (Read/Write locks, Lock Index, Garnet support) is a separate `*Brand New Feature*` entry first in `### Added`.
- Commits under review (`git.md`): subject only `[<scope>] <summary>`, lowercase, imperative, no trailing period,
  no body except the attribution trailer, never on `master`.

## 5. Do not report

- Settled design (overview, `acquirer.md`, `swarm.md`): long explicit parameter lists and disabled
  `Metrics/ParameterLists`; logic duplicated between operation modules (report only diverged copies);
  read→write upgrade as an error unless `:wait_for_lock`; nested reads through `conflict_strategy`; no fairness
  between modes with `:random`; best-effort cross-host FIFO; no Lua in the RW path; one mode per lock series;
  `lock_index_enabled` as a config-only mode; the lock index defaulting to `false`.
- Settled design of the lock request priorities (overview "Lock request priorities", limitations kept by the user):
  strict priority (lower priorities can starve within their timeout/retry limits), no preemption of an obtained lock,
  the polled handoff (`retry_delay`), dead requests pruned with the pruner's `queue_ttl`, dead requests of lower bands
  lingering until an attempt of their band/`clear_dead_requests`/the queue TTL/the swarm (they never block), the
  library-constant range `-100..100` and its ~61 µs FIFO precision inside a band, `MAX_DEAD_REQUEST_REMOVALS` per
  attempt, `:random` requests ignoring the order and the priorities of other requests (while their own requests are queued
  at their priority: `:queued` requests wait for them), `clear_dead_requests` reading the batch queues (2 round trips per batch; `by_priority: true`: the first
  request of each band only, the most bands of a batch queue + 1 round trips),
  the order degradation with older versions (no safety impact), the queue score as the only order and liveness of a request
  (a separate liveness registry of request deadlines was rejected by the user: don't propose it).
- Unused `Resource` methods marked `# NOTE: (debug)` (manual runtime checks, `logic.md#17`); report a debug method
  only when it is wrong for a key family it can get.
- Known limitations kept by the user: `YieldExpire` write release (`EXPIRE 0`) and ttl decrease without an owner
  check; `HMGET`→`DEL` without `WATCH` in `ReleaseLocksOf`/`FlushZombies`; `unlock` dropping the data of a reader
  re-acquired between its two round trips; `zombie_acquirers` vs `flush_zombies` acquirer sets.
- Known debt: `WithAcqTimeout` → `LockInfo`/`QueueInfo`; rspec-retry, disabled coverage minimum;
  `sleep(0.1)` readiness waits and missing logging in the swarm;
  one flusher per process; `EVAL` without `SCRIPT LOAD`.
- "Recommendations (proposed, not yet project policy)" in the rule files: never violations; mention one only as an
  optional suggestion for touched code.
- Pre-existing problems outside the diff: out of scope; mention a severe one briefly in the template's
  "outside the diff" section.
- Anything in `*_spec.rb` except §3.

## 6. Verify every finding

- Confirm it in the code (call sites, copies, RBS, specs), not by pattern match: concurrency claims name the
  interleaving (acquirer A at step X, B at step Y) and why `WATCH` doesn't catch it; layout claims count the
  commands and positions; mode claims check both `lock_index_enabled` values and both `read_write_mode` values;
  priority claims check a positive, the default (`0`) and a negative band, a request of another band ahead (alive and
  dead) and requests in both queues.
- Drop findings contradicted by §5, by a design `NOTE` in the code or by the overview. Mark the rest
  `CONFIRMED` (traced end to end) or `PLAUSIBLE` (depends on an assumption: name it).
- Helpful greps:
  - added key literals and scans (outside `resource.rb` every `'rql:` literal is a finding):
    `git diff <base> -U0 -- lib | grep '^+' | grep -v '^+\s*#' | grep -n "'rql:\|\"rql:\|'KEYS'\|'SCAN'\|\.scan(\|\.zscan("`;
  - `git grep -n LOCK_INDEX_KEY -- lib`: every use reachable only with `lock_index_enabled` (an `if`/`return unless`
    guard or a lock index lookup branch), except `ReindexLocks` and `Resource`;
  - cross-module calls: `git grep -n "RedisQueuedLocks::Acquirer::" -- lib/redis_queued_locks/acquirer` (only the
    known `WithAcqTimeout` debt and the `LockSeries` uses of the `AcquireLock` mixins are allowed);
  - `git diff --name-only <base>` against the `sig/` mirror (§2 exceptions); `git diff --check <base>`.
- Checks (read-only): a review on request of local changes runs `bundle exec rake rubocop` and
  `bundle exec rbs collection install && bundle exec rake steep:check` (grep the output for `ERROR`/`FATAL`, restore a
  rewritten `rbs_collection.lock.yaml` with `git checkout -- rbs_collection.lock.yaml`); the automatic pre-commit run
  reports the completion checks instead of re-running them (see "When to run"). Don't run the specs without
  asking: they need a local Redis; when asked, run them in parallel processes (`rake rspec:parallel`: ~1 minute,
  flushes db `0..2n-1` for `n` workers; the serial `rake rspec`, ~6 minutes and db 0/1, only for the one-process checks
  of `tests.md#1`).

## 7. Report

### Template language
The report template is chosen by the Claude Code `language` setting:
1. Take the effective value: the first settings file that defines `language`, in precedence order (run from the
   repository root; Ruby is always available here, `jq` may be not):
   ```sh
   for f in "/Library/Application Support/ClaudeCode/managed-settings.json" /etc/claude-code/managed-settings.json \
            .claude/settings.local.json .claude/settings.json ~/.claude/settings.json; do
     [ -f "$f" ] && v=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0]))["language"].to_s' "$f" 2>/dev/null) \
       && [ -n "$v" ] && { echo "$v"; break; }
   done
   ```
   Settings passed with `--settings` override these files; the session's response-language instruction (it comes
   from the same setting) then shows the effective value.
2. Map the value case-insensitively to a template in `.claude/skills/rql-code-review/templates/`:

   | `language` value | Template |
   |---|---|
   | Russian: `russian`, `русский`, `ru`, `ru-RU`, `ru_RU`, ... | `report.ru.md` |
   | English (`english`, `en`, `en-US`, ...), any language without a template (`japanese`, `de`, ...), no value | `report.en.md` |

3. Read the chosen template and fill it in. The whole report (headings, labels, verdict, findings) is written in the
   template language; code identifiers, rule names, quotes and the `CONFIRMED`/`PLAUSIBLE` markers stay as they
   are. Text outside the report (the offer to fix) follows the session language.

Both templates have the same structure: change them together. A new language = a new `report.<code>.md` with the
same structure plus a row in the table above.

### Severity and order
- Blocker: breaks mutual exclusion or the lock index superset, loses or leaks locks/data (e.g. a queue pruning that
  drops alive requests of another priority band), crashes, breaks the public API (method, result shape, event,
  config key) or turns CI red.
- Major: a rule violation with a real consequence: a missed read key family or lookup mode, a broken order between
  modes or priorities, a release of the wrong (requested instead of held) mode, a dead request that can block a
  queue, a cost that grows with the priority range, per-key round trips, a hot-path regression, broken module
  independence, a missing RBS/docs update for a changed contract, new behavior without specs.
- Minor: convention deviations with little impact (YARD tags, comment format, naming, idioms).
- Nit: optional polish.
- Order by severity, then by file. Empty sections are omitted; with no findings the verdict says so and the sync and
  checks sections list what was checked.
