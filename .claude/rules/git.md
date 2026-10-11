# Git commit rules

Applies to every commit Claude makes in this repository (no `paths:` scope: always loaded).

## Observed conventions (git history analysis)
- 653 of 687 non-merge subjects use the `[<scope>] <summary>` form: `[readme] minor updates`, `[gem] bump to 1.17.0`, `[lock_series] correct lock series releasing when blokc of code is failed with an exception`.
- Scope = the area of the change, lowercase:
  - docs and project files: `readme` (most frequent), `roadmap`, `changelog`, `docs`, `yardoc`, `license`;
  - gem lifecycle: `gem` (`bump to X.Y.Z`, dependency updates), `new-release`;
  - tooling: `rbs`, `types`, `ci`, `rubocop`, `linting`, `specs`, `dev`;
  - features/modules, named like the code or the README section: `swarm`, `lock_series`, `logging`, `instrumentation`, `reentrant-locks`, `release_locks_of/release_current_locks`, `#clear_dead_requests`.
- Sub-areas are joined with `/` (`ci/typechecking`, `readme/roadmap`, `features/rel_of_acquirer/rel_of_host`); multi-word scopes use `-` or keep the code identifier (`dead-locks-and-reentrant-locks`, `lock_series`).
- Summary: short, lowercase, no trailing period; imperative and past tense are mixed (`update`, `updated`, `bump`, `fixed typo`); several changes are joined with `+` or commas (`feature + doc updates`, `release_locks_of, release_current_locks`).
- Several areas in one commit (mostly squash-merged PRs): `[a] + [b] + [c]` (`[claude instructions] + [gem update] + [migration to Ractor 4 API]`).
- Version bumps: `[gem] bump to X.Y.Z`.
- Squash merges of PRs end with ` (#N)`; GitHub appends it, it is never typed by hand.
- Bodies are practically absent: only GitHub squash bullet lists and `Co-Authored-By:` trailers.
- Anti-patterns found in history (don't repeat): meaningless subjects (`dev`, `cheburek`, `work in progress`, `huuuge updates`), scope typos (`[roadma]`), stash/WIP entries.

## Claude rules
**Message format**
1. Subject only, one line: `[<scope>] <summary>`. Don't write a commit body (no description, overview, bullet lists or explanations). The only allowed extra lines are the attribution trailers the harness requires (`Co-Authored-By: ...`), separated by a blank line.
2. Scope: one lowercase area from the list above, or the feature/module name (`read-write-locks`, `swarm`, `lock_series`, `extend_lock_ttl`). Use `/` for a sub-area (`ci/typechecking`). Name the dominant area: specs, RBS, README/CHANGELOG and `.claude` docs that accompany a feature don't get their own scope.
3. Summary: a short, meaningful description of what the change does (the feature or the fix), not of the process (`changes`, `updates`, `fixes`, `wip` alone are not allowed). Lowercase start (code identifiers keep their spelling), no trailing period, imperative mood, aim for <= 72 characters in total.
4. Several features in one commit: list each feature in at most two words, comma-separated: `[read-write-locks] unlock_read, extend all-readers, rw_mode info`. Don't use `+` chains or sentences for lists.
5. Unrelated areas: prefer separate commits per area; if one commit is unavoidable, use the historical form `[a] + [b]` with a 1-2 word summary per scope.
6. Releases: `[gem] bump to X.Y.Z`. Never add ` (#N)` by hand.

**When to commit**
7. Never commit on your own. When a step with changes reaches completion, ask the user for permission to commit and wait for the answer:
   - completion = the feature/functionality required by the prompt is fully implemented (code, RBS, specs, README/CHANGELOG, `.claude/project-overview.md` and rules kept in sync) and checks are green: the touched examples and the full suite (`bundle exec rake rspec`), `bundle exec rake rubocop`, `bundle exec rake steep:check` (no `ERROR`/`FATAL` lines); changes without code (docs, `.claude` rules) need no test run;
   - the question contains: the proposed commit subject (following the format rules above), a short recap of what was done in the changes (features/fixes, touched areas, check results) and the list of files that will be committed;
   - commit only after an explicit "yes" (or with the subject the user corrects); on "no" leave the changes uncommitted (staging also only on request).
8. An explicit user request to commit ("commit", "закоммить") is the permission itself: commit right away with the given subject (or a subject built by the rules) without asking again.
9. Don't propose a commit for incomplete or red states (failing specs, lint/type errors, half-done requirements); report the blocker instead.
10. One commit per completed step. Stage only the files of that step (`git status` first); never commit environment artifacts: `rbs_collection.lock.yaml` rewritten by `rbs collection install` (restore it with `git checkout --`), `coverage/`, `.gem_rbs_collection/`, local settings.
11. Never commit to `master`: create a feature branch first (named after the feature, e.g. `read-write-locks-realisation`). Never push, amend, rebase, reset or force anything unless the user asks.
12. After committing, report the short hash and the subject.

**Examples**
- `[read-write-locks] extend all read locks`
- `[read-write-locks] unlock_read, rw_mode info, meta reservation`
- `[extend_lock_ttl] extended locks count result`
- `[rbs] remove duplicate collection gems`
- `[ci/typechecking] blocking runtime checks`
- `[gem] bump to 1.18.0`
