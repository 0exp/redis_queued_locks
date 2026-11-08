---
paths:
  - "README.md"
---

# README rules (`README.md`)

Paired with `logic.md#12`: that rule says *when* README changes (in the same change as the code), this file says *what* in README changes. A change of `lib/` that is visible to the user goes through both.

## Observed conventions
- Layout: title + badges, intro (description, strategies, the "Supports ..." / "Provides ..." feature lines), `## Table of Contents`, `### Requirements` .. `### Configuration`, `### Usage` (one `#### #method - short description` per `Client` method, aliases as `(aka \`...\`)` in the TOC), feature sections (`## Swarm Mode and Zombie Locks`, `## Lock Index`, `## Lock Access Strategies`, `## Lock Request Prioritization`, `## Read/Write Locks`, `## Lock Auto Extension`, ...), `## Logging`, `## Instrumentation`, `## Roadmap`, `## Build and Develop`, `## Contributing`, `## License`, `## Authors`.
- Each section starts with `<sup>\[[back to top](#table-of-contents)\]</sup>` (a subsection points to its parent section); sections are separated by `---`.
- Code examples are fenced with a language (`ruby`, `shell`); results are shown as `# =>` comments.
- Anchors are GitHub slugs: lowercase, punctuation dropped except `-` and `_`, spaces become `-` (`#lock` + ` - obtain a lock` => `#lock---obtain-a-lock`, `Read/Write Locks` => `#readwrite-locks`, `swarmize!` => `#swarmize`).

## Rules
1. Sync scope (what changes with the code, `logic.md#12`):
   - a new `Client` method (operation): its `#### #method` section in `### Usage` (signature with every keyword and its default as in `Client`, the result shapes, an example, the `!` variant and aliases) + its TOC line;
   - a new/changed `Client` keyword or default: the signature and the keyword list of every method section that takes it (`#lock`, `#lock!`, `#lock_series`, ...);
   - a new config option (`setting` in `config.rb`): its commented entry in the `### Configuration` block (default, meaning, valid values, the same order and grouping as `config.rb`); defaults always equal the `config.rb` ones;
   - new/changed log events and keys, instrumentation events and payload keys: `## Logging` / `### Instrumentation Events` (`visitors.md#14`; events also get their TOC line);
   - new public errors and documented limitations: the method/feature section that raises or has them;
   - a fundamentally new feature (`*Brand New Feature*` of `changelog.md#8`): its own `##` section + TOC lines (with its subsections) + a mention in the intro "Supports ..." / "Provides ..." line with a link to the section;
   - the result shapes and examples of changed operations (read/write data, lock index, priorities: the shapes shown must be the real ones).
2. Duplicated texts change together: the intro paragraphs and `### Algorithm` (queue order, strategies), the swarm configuration in `### Configuration` and in the swarm usage preview, the log lists of `## Logging` and the `config['logger']` / `config['log_lock_try']` comments (`visitors.md#14`).
3. `## Roadmap`: an item implemented (fully or partly) by the change is removed or narrowed to what is left in the same change.
4. `### Requirements`: Ruby / Redis / `redis-client` versions follow the gemspec and the commands the code uses (overview "Stack").
5. `## Build and Develop`: rake tasks, the parallel runner (`WORKERS`, databases, log paths), the CI commands and their environment (`RBS_TEST_SKIP`, `type-checking.md#13`) follow the `Rakefile`, `spec/support/` and `.github/workflows/`.
6. TOC: every `##` section, every `#### #method` of `### Usage`, every feature subsection and every instrumentation event has a TOC line; the nested lists of sections (swarm) follow the same rule; no link without a heading behind it, except the reserved swarm anchors (the TOC and the list of `## Swarm Mode and Zombie Locks`: `#how-to-swarm`, `#`, `#swarm_status`, `#swarm_info`, `#swarmize!`, `#deswarmize!`, `#probe_hosts`, `#flush_zombies` (text `flush_zobmies`), `#zombies_info`, `#zombie_locks`, `#zombie_hosts`, `#zombie_acquirers`): kept as is by the user's decision until those sections are written, never "fixed" or reported; the check of rule 8 lists them.
7. Formatting: no trailing whitespace (blank lines inside code blocks included), a back-to-top line in each new section, fenced code with a language, no tabs.
8. Before finishing a README change, check the anchors and the whitespace (no output = clean):
   ```shell
   ruby -e 'src=File.read("README.md");c=false;n=Hash.new(0);s={};src.each_line{|l|c=!c if l.start_with?("```");next if c || l !~ /^#+ (.+)$/;g=$1.strip.downcase.gsub(/<[^>]+>/,"").gsub(/[^\p{Word}\- ]/,"").tr(" ","-");s[n[g]>0 ? "#{g}-#{n[g]}" : g]=1;n[g]+=1};src.scan(/\]\(#([^)]*)\)/).flatten.uniq.each{|a|puts "broken anchor: ##{a}" unless s[a]}'
   grep -n '[[:space:]]$' README.md
   ```
