# Code navigation rules (the `LSP` tool, ruby-lsp)

Applies to every search for Ruby definitions and usages in this repository (no `paths:` scope: always loaded, the
navigation starts before any file is read).

## Setup
- The server comes from the `ruby-lsp@claude-plugins-official` plugin, enabled for the project in the committed
  `.claude/settings.json` (`enabledPlugins`); the plugin runs the `ruby-lsp` executable for `.rb`, `.rake`,
  `.gemspec`, `.ru`, `.erb`.
- The gem is a development dependency of the project: `gem 'ruby-lsp', require: false` in `Gemfile` (never the
  gemspec), locked in `Gemfile.lock`; `bundle install` (`bin/setup`) installs it and puts the `ruby-lsp` executable
  on `PATH` (the plugin runs the bare `ruby-lsp`, not `bundle exec ruby-lsp`: with a custom `BUNDLE_PATH` the
  executable must be reachable some other way). Checked with 0.26.11 on Ruby 4.0. The server may keep its own
  composed bundle in `.ruby-lsp/` (ignored by its own `.gitignore`, never committed).
- No indexing configuration: all Ruby sources live in `lib/` and `spec/`; `.index.yml` is deprecated by ruby-lsp.
- Without the plugin or the installed bundle the `LSP` tool is absent or fails: fall back to grep (and say so).

## Observed behavior (ruby-lsp 0.26.11)
- Works: `findReferences`, `goToDefinition`, `hover` (signature + YARD doc), `documentSymbol`, `workspaceSymbol`.
- Not supported by the server (`Method not found`): `prepareCallHierarchy`, `incomingCalls`, `outgoingCalls`,
  `goToImplementation`.
- No server for `.rbs`: `sig/` is searched with grep and checked with Steep (`type-checking.md`).
- `workspaceSymbol` is fuzzy and never returns private methods (`drop_dead_requests_ahead` is not found); a
  namespace query (`RedisQueuedLocks::Acquirer::AcquireLock`) returns 140+ lines.
- A request sent while the server starts fails with `server is starting`. Seen once after such a start: the
  definitions, symbols and hover docs of the file opened at that moment (`resource.rb`) were doubled for the rest
  of the session, other files were not (harmless; the cause, a double indexing of that file, is an assumption).

## Claude rules
1. Semantic questions go to the `LSP` tool first, text questions to grep:
   - call sites of a method / usages of a constant (before a signature change, a rename, a removal):
     `findReferences` on the definition (exact usages in `lib/` and `spec/`, no comment or YARD mentions);
   - "where is it defined / what does it take and return": `goToDefinition` or `hover` on a call
     (`Resource.xxx`, the mixin methods of `AcquireLock`/`LockSeries`);
   - the outline of a big file (`client.rb`, `try_to_lock.rb`, `redis_queued_locks_spec.rb`) before reading it in
     parts: `documentSymbol`.
2. Warm-up: the first `LSP` call of a session is sent alone, never in a parallel batch; after `server is starting`
   repeat the call. Doubled results with one and the same position are not two definitions.
3. `workspaceSymbol` only with a narrow query (a method or constant name); a private method is found by
   `goToDefinition` from its call or by grep `def <name>`.
4. Callers come from `findReferences` (no call hierarchy, no `goToImplementation`).
5. Positions are 1-based and the character must be inside the identifier: take the line and the column from grep
   output (`grep -n`, the column of the name), not from a guess.
6. `findReferences` is not the whole picture, finish with grep for:
   - dynamic calls (`send`, `public_send`, `__send__`, `method(...)`, names built at runtime);
   - `sig/**/*.rbs` (the RBS mirror must change with the method: `type-checking.md`);
   - mentions in YARD/comments, `README.md`, `CHANGELOG.md`, `.claude/project-overview.md` and the rules;
   - strings: log messages, event names (`redis_queued_locks.*`), Redis key patterns, config keys (`config['a.b']`).
7. A changed behavior of the server (a new version supports the call hierarchy, private methods appear in
   `workspaceSymbol`, the start race is gone) updates this file in the same change.
