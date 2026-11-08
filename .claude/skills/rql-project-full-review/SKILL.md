---
name: rql-project-full-review
description: Full audit of the whole redis_queued_locks repository (not a diff) - every instruction (CLAUDE.md, .claude/project-overview.md, .claude/rules/*.md, the skills) against the code (lib/, sig/, spec coverage, CI, Rakefile, gemspec) and against each other, plus a hunt for defects in the code itself. Reports "everything matches" or "matches, but these things should be updated/corrected" with a list, separating intentional decisions (never proposed for change) and intentionally deferred items (their own section). Use only when the user asks for a full/project-wide review or audit (полное ревью проекта, аудит, проверь соответствие инструкций и кода); a diff/branch/PR review is rql-code-review.
argument-hint: "[<areas...>: lib | sig | swarm | acquirer | keeper | docs | rules | ci] [--with-specs] [--no-checks]"
---

# redis_queued_locks full project review

Audit the repository as it is at `HEAD` (+ uncommitted changes, named as such): do the instructions describe the
code truthfully, does the code follow the instructions, do the instructions agree with each other, and what is
broken or fragile regardless of the instructions. Diff-based reviews are `rql-code-review`; this skill reuses its
checklist (§4) and its "Do not report" list (§5) as the single source of the project invariants and settled
decisions: read `.claude/skills/rql-code-review/SKILL.md` first.

- Read-only: never edit, stage or commit. After the report offer to fix the selected items (one change per topic,
  each going through the usual completion checks and the pre-commit review of `git.md#7`).
- Inline, in this session (no subagents unless the user asks for them).
- Arguments narrow the audit to areas (the default is all of §3). `--with-specs` also runs the suite
  (`bundle exec rake rspec:parallel`: needs a local Redis, flushes db `0..2n-1`); `--no-checks` skips rubocop/steep.
- The report language follows the Claude Code `language` setting exactly as in `rql-code-review` §7 (templates
  `templates/report.<code>.md` of this skill, English when no template matches).

## 1. Classification: what is a finding

Every candidate is put into exactly one class before it goes into the report.

1. **Intentional decision** (never proposed for change, not a finding): the trade-off is documented as chosen:
   - `rql-code-review` §5 (settled design, priorities design, known limitations kept by the user, `NOTE: (debug)`
     methods, spec exemption of §3 there);
   - wording in the overview/rules/README/code: "on purpose", "kept by the user's decision", "settled", "design
     decision", "rejected", "duplicated on purpose", "intentional", a design `NOTE` next to the code;
   - CLAUDE.md "Rules" (long explicit argument lists, operation-module independence over DRY, etc.);
   - decisions recorded outside the repository (the user's auto-memory of this project, when loaded): the gemspec
     packages `git ls-files` (incl. `.claude/`); `rql-code-review` runs inline (no forked/subagent variant);
     `@raise` YARD tags are not required.
   - The report lists them only as a short "accounted for" line (count + the topics), so the user sees they were
     recognized; an intentional decision whose documentation contradicts the code is still a finding (sync class).
2. **Intentionally deferred** (section "Намеренно отложенное" / "Intentionally deferred"; reported, not proposed as
   a fix now): the item is documented as a future fix:
   - "Known debt" / "Temporary debt" (CLAUDE.md, overview "Conventions", `acquirer.md`, `logic.md#16`), `swarm.md`
     "Known quirks", `tests.md` (coverage minimum, rspec-retry, the spec rework);
   - the "Recommendations (proposed, not yet project policy)" sections of the rule files;
   - `TODO` comments in `lib/`, `sig/`, `Rakefile`, workflows (`git grep -n "TODO" -- lib sig Rakefile .github`);
   - README `## Roadmap`: don't copy it; mention a Roadmap item only when the audit found its gap in the code;
   - deferred work from the auto-memory, when loaded (e.g. the inline argument checks: no `check_*` helpers until a
     refactoring; the postponed RW optimization plan; open review findings): verify each against the current code,
     drop the ones that are done (and say so in "Stale instructions" when a repo file still calls them open).
   - Each entry: what, where it is documented, the current state in the code (still present / partly fixed / already
     fixed: then the documentation is stale, a sync finding), the risk if it stays.
3. **Finding** (sections by kind, §5): anything else that is wrong, contradictory, stale or fragile. An undocumented
   deviation is a finding even when it looks deliberate: the fix is either the code or the documentation of the
   decision (say which is more plausible; when unsure, ask the user in the report rather than guess).

Doubtful cases: a deviation that matches the spirit of a documented decision but not its letter is a finding of the
"instructions should say it" kind (Minor), never a code change proposal.

## 2. Inventory (read before judging)

1. `git rev-parse --short HEAD`, `git status --porcelain` (uncommitted changes are audited too and marked as such),
   `RedisQueuedLocks::VERSION` (`lib/redis_queued_locks/version.rb`), the CHANGELOG `[Unreleased]` head.
2. Instructions: `CLAUDE.md`, `.claude/project-overview.md`, every `.claude/rules/*.md`, every
   `.claude/skills/*/SKILL.md` and templates.
3. User docs: `README.md` (TOC, method sections, config block, `## Logging`, `### Instrumentation Events`,
   Requirements, Roadmap, Build and Develop), `CHANGELOG.md`.
4. Tooling: `redis_queued_locks.gemspec`, `Gemfile`, `Rakefile`, `spec/support/parallel_runner.rb`, `.rubocop.yml`,
   `.rubocop.rbs.yml`, `Steepfile`, `rbs_collection.yaml`, `.github/workflows/*.yml`.
5. Code: `lib/**` (dependency order: `resource.rb`, `config.rb`, `errors.rb`, `utilities.rb`, `acquirer/acquire_lock/*`,
   `acquirer/lock_series/*`, other `acquirer/*`, `lock_keeper*`, `client.rb`, `swarm*`, `logging/`, `instrument/`, then the rest of `lib/`: `config/`, `utilities/`,
   `data.rb`, `debugger*`, `stats/`),
   `sig/**`, `spec/spec_helper.rb`; specs only for coverage (`rql-code-review` §3).
6. Build the two ledgers of §1 (intentional, deferred) from these files before looking for findings.

Big areas are read in full, not sampled: an audit claim "X holds everywhere" needs the grep that proves it (§4).

## 3. Areas and checks

### A. Instructions ↔ code (does the code follow every rule?)
- Walk every numbered "Claude rule" of every rule file and every CLAUDE.md "Rules" bullet; for each, check the whole
  codebase (not a diff): the `rql-code-review` §4 A–J checklist applied repository-wide. Record per rule file:
  `ok` or the findings.
- Repository-wide greps (each one with its expected result):
  - `'rql:`/`"rql:` literals outside `resource.rb`; `'KEYS'`, `.scan(`/`.zscan(` outside the known lookups;
  - `git grep -n LOCK_INDEX_KEY -- lib`: every use behind `lock_index_enabled` (except `ReindexLocks`, `Resource`);
  - cross-module calls `git grep -n "RedisQueuedLocks::Acquirer::" -- lib/redis_queued_locks/acquirer` (only the
    known `WithAcqTimeout` debt and the `LockSeries` uses of the `AcquireLock` mixins);
  - `Struct`/`Data.define`/`OpenStruct`/`**opts`/`options = {}`/`(...)` in `lib/`;
  - `ZREMRANGEBYSCORE` on request queues: per band only (`rql-code-review` §4 C);
  - `.nil?`, `# rubocop:disable all`, missing `# frozen_string_literal: true`
    (`git grep -L "frozen_string_literal: true" -- '*.rb'`);
  - every `lib/**/*.rb` has its `sig/**/*.rbs` mirror and back (`comm` of both file lists, path-mapped);
  - every `Client` public method: `Acquirer::*` module, RBS, README section, spec (`describe`/`it` grep), `!` variant
    where the rules require one, the lock-family options in all four lock methods (`arguments.md#10`);
  - every `setting` in `config.rb`: `validate`, its `Config#[]` overload line in `config.rbs`, the README config
    block, the overview "Configuration" table;
  - every visitor method: the same name in the Log and Instr visitors; every event/log key in README `## Logging` /
    `### Instrumentation Events` and the overview "Instrumentation events";
  - every error class in `errors.rb`: under the right base, in the overview "Errors", raised somewhere (or
    documented as public API kept for compatibility);
  - YARD: `@api`/`@since`/`@version` on every class/module/method; no `@since`/`@version` newer than the unreleased
    version or older than the code that introduced it where git history proves it (`git log -S`).
- Duplicated logic copies (`rql-code-review` §2 list): every copy pair compared side by side; a diverged copy is a
  Major finding (behavioral divergence) or Minor (cosmetic).

### B. Instructions ↔ instructions (contradictions and dead references)
- Each fact stated in several places (CLAUDE.md, overview, rule files, `rql-code-review` checklist, README,
  CHANGELOG) says the same: option names and defaults, round-trip counts, key layout, event names, result shapes,
  the paths-ignore list (`git.md#7` ↔ CLAUDE.md ↔ every `.github/workflows/*.yml`), worker/database counts, commands.
- References resolve: `<file>.md#N` points to a rule N that exists and is about that topic; overview "<section>"
  names exist; `.claude/skills/...` paths, file paths and method/constant names mentioned in the docs exist
  (`git grep -n` each identifier in backticks that looks like code; report the ones absent from `lib/`, `sig/`,
  `spec/`).
- Renamed or removed things still mentioned (e.g. old option names in any file, `git log --format=%s -30` for recent
  renames and their leftovers).
- Duplicate or conflicting rules (the same rule in two files with different wording, a rule that forbids what
  another requires); the "Known debt" lists are consistent across CLAUDE.md, overview and rule files.

### C. User docs ↔ code
- README: every public method, keyword and default, config key and default, result shape, event and payload key,
  error, limitation and requirement matches the code; TOC entries and anchors resolve; `readme.md` rules followed.
- CHANGELOG: `[Unreleased]` covers the user-visible changes since the last release tag
  (`git describe --tags --abbrev=0`, `git log <tag>..HEAD --format=%s`); entries follow `changelog.md`; the gem
  version in `version.rb` and the latest released section agree.
- gemspec: Ruby requirement and runtime deps (`redis-client` only) match CLAUDE.md, README Requirements and the CI
  Ruby version.

### D. Defects in the code (the hunt)
Independent of the instructions, look for real bugs with a concrete scenario: race windows (name the interleaving
and why `WATCH` does not catch it), reply positions vs the commands of a pipeline/transaction, `nil`/missing key
handling, `PTTL` sentinels, unit mix-ups, infinite scores, error paths (`ensure`, `rescue` scope, swallowed errors
outside the documented `rescue nil` of observability), thread/fiber/Ractor safety (shared mutable state, the
keeper's mutex and interrupts), resource leaks (connections, threads), RBS that does not match runtime values, dead
code. Concentrate on the lock safety core first (`acquire_lock/*`, `lock_series/*`, `lock_keeper*`, releases), then
the operations, then the swarm. Every candidate goes through §1 (a documented limitation is not a defect).

### E. Tooling and CI
- Rake tasks, the parallel runner and the workflows do what the overview "Rake tasks"/"CI" and `tests.md` say;
  workflows use the same Ruby/Redis versions as documented; `.rubocop.yml` has no global loosening that contradicts
  "never tune `.rubocop.yml` to pass" (a pre-existing exclusion documented as intended is fine).
- Checks (unless `--no-checks`): `bundle exec rake rubocop`; `bundle exec rbs collection install && bundle exec rake
  steep:check` (grep for `ERROR`/`FATAL`; restore a rewritten `rbs_collection.lock.yaml` with
  `git checkout -- rbs_collection.lock.yaml`); with `--with-specs`: `bundle exec rake rspec:parallel` (a failure is
  reported with its output; the known flaky examples of `tests.md` are named as such).

## 4. Verify every finding

- Confirm it in the files (quote the line or the grep), never by memory or a pattern alone; `CONFIRMED` (traced) or
  `PLAUSIBLE` (name the assumption). Concurrency, layout, mode and priority claims follow `rql-code-review` §6.
- Re-check each finding against both ledgers of §1 right before writing the report; drop or reclassify.
- Severity as in `rql-code-review` §7 (Blocker, Major, Minor, Nit); for docs: a wrong statement about safety, the
  public API or a result shape is Major, a stale reference/typo/wording issue is Minor or Nit.
- Keep the report proportional: group repeated instances of one issue into one finding with all locations (or the
  first five + count).

## 5. Report

Fill `templates/report.<code>.md`. The verdict is exactly one of:
- **Всё соответствует** / **Everything matches**: no findings of any severity (deferred items may exist);
- **Соответствует, но есть что обновить/скорректировать** / **Matches, with things to update**: only Major and lower
  findings;
- **Есть серьёзные несоответствия** / **Serious mismatches**: at least one Blocker (or a Major that breaks lock safety
  or the public API).

Sections (empty ones are omitted, except "Intentionally deferred", which is always present when its ledger is not
empty): code defects; instructions ↔ code; contradictions between instructions; user docs ↔ code; stale instructions
and dead references; tooling and CI; optional suggestions (from the rule files' recommendations applied to existing
code: only when cheap and clearly useful, never as violations); intentionally deferred; accounted-for intentional
decisions (one line); checks; coverage of the audit (areas audited, greps run, what was not audited and why).

Each finding: location(s), the problem in one sentence, the source (rule/section/README anchor) it contradicts,
`CONFIRMED`/`PLAUSIBLE`, the proposed correction and where it belongs (code / instruction / README / CHANGELOG).
After the report, offer to fix (in the session language), grouped into suggested commits (`git.md` subjects).
