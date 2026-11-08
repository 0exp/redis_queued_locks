## Full project review: <areas> (HEAD <sha>, v<VERSION>[, + uncommitted changes])
**Verdict:** <Everything matches | Matches, with things to update | Serious mismatches> — <one sentence why>

### Code defects
1. `<path>:<line>` — <the defect in one sentence>. [<Blocker | Major | Minor | Nit>] [CONFIRMED | PLAUSIBLE: <assumption>]
   Scenario: <state / interleaving → wrong result>.
   Source: <`acquirer.md#16` | overview "Lock index" | general defect>.
   Fix: <what to do> → <code | instruction | README | CHANGELOG>.

### Instructions ↔ code
<findings in the same format; each rule file without findings: `<file>.md`: ok>

### Contradictions between instructions
<findings in the same format: both places and their wording>

### User docs (README, CHANGELOG) ↔ code
<findings in the same format>

### Stale instructions and dead references
<findings in the same format>

### Tooling and CI
<findings in the same format>

### Suggestions (optional)
- <a rule-file recommendation applied to existing code: what, where, why>

### Intentionally deferred
- <what> — documented in: <source>; state in the code: <present | partly fixed | already fixed → the docs are stale>; risk if kept: <...>.

### Accounted-for intentional decisions
<N decisions not proposed for change: <topics, comma-separated>>

### Checks
- rubocop: <result | skipped (--no-checks)>
- steep: <result | skipped (--no-checks)>
- rspec: <not run (no --with-specs) | result>

### Audit coverage
- Audited: <areas, rule files, key greps>
- Not audited: <what and why>
