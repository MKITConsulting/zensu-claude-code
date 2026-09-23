---
paths:
  - "tests/structure/test-bash32-portability.sh"
  - "tests/structure/bash32-substitution-scan.js"
---

# bash 3.2 Command-Substitution Truncation (`test-bash32-portability.sh`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

macOS ships GNU bash **3.2.57** as `/bin/bash`, so it is the DEFAULT shell for every
hook and helper this plugin runs there — not an edge case, and not something a
`#!/bin/bash` shebang opts out of. That release extracts a `$( ... )` body with a naive
scanner that tracks quotes and parens instead of parsing, so any token the scanner
miscounts ends the substitution early. **The rule: inside a command substitution, write
every `case` pattern with the POSIX-optional leading paren — `(pattern)`.** The bare
`pattern)` form supplies an unbalanced `)` that CLOSES the substitution at that
character; the paren form balances the scanner and parses identically on bash 5.

**It shipped, and its cost was a whole verdict rather than a cosmetic row.** In 0.20.0
the `ZDOC_SESSION_PAIR` substitution in `hooks/lib/zensu-doctor.sh` carried the bare form.
Measured on 3.2.57 against a session that was genuinely bound: the body truncates
mid-`case`, the subshell dies of a syntax error, the assignment returns 1, the `elif`
falls to its `else`, neither follow-up question matches, and `/zensu:doctor` renders
`binding: this session has no valid Session Control record — … start a fresh Claude Code
session` over a record that is present, readable and already bound. Reproduced in the
shipped tree and closed by switching that one arm to `(*[[:cntrl:]]*)`.

**TWO properties made it survive, and both generalize to the next instance.** The failure
is INVISIBLE at build time: bash 3.2 parses a substitution body only when it expands it,
so `bash -n` over the whole file passes and no lint sees it. And the ORDER hides the
cause: 3.2 executes the body command by command, so everything above the malformed `case`
runs and SUCCEEDS first — in the doctor's case the session bind itself. The record was
never the problem, only the reporting of it, which is exactly why every other component
disagreed with that row. Do not diagnose a contradiction of this shape by re-examining the
state; check whether the reporter parsed.

**The guard is an ORACLE, not a heuristic**, which is what lets it run anywhere.
`tests/structure/bash32-substitution-scan.js` reproduces the naive scanner, takes the body
it would have handed the parser, and asks a real `bash -n` whether that text parses. A
truncated body is a syntax error under EVERY POSIX shell, so the check reports identically
on a macOS 3.2 host and on a Linux 5.x runner — verified in both, and in a `bash:5`
container. `test-bash32-portability.sh` drives it over the tree with four controls: the
scanned-file population (a scanner that walks nothing reports a clean tree), a probe pair
that must be reported and must not be, and a live-bash premise check. The pair is DERIVED
by deleting the single `(` from the fixed form rather than written twice — the suite is
itself a `*.sh` under the scanned root, so a literal bare case arm in a heredoc is a real
finding, and it failed on its own fixture the first time it ran.

**The coupling runs in the UNOBVIOUS direction**, the shape this file already records for
`ESCAPE_STEMS` and G12: an ordinary edit to ANY shell file in the tree can turn a suite
named for bash 3.2 red, and the remedy is in the file that changed, never in the suite.

**One sibling trap is documented and deliberately NOT machine-checked:** an apostrophe
inside a comment within a substitution opens a quote state the same scanner never closes,
and the file then fails to parse entirely rather than at that line. A detector for it was
written and measured over this tree — five candidates, none of them real — so it stays a
prose warning at the call sites rather than a check that cries wolf. The warning lives
beside the `ZDOC_SESSION_PAIR` substitution together with the case rule; `B3` pins that
both survive there.

**Version: `patch`.** Walked against §"Runtime Lineage" entry by entry: no context-record
or workflow-state schema field, no strict key set, no hook added, removed or renamed and no
matcher changed, no new config key, no attestation change, and no `permissionDecision` in
either direction — the doctor is read-only and always exits 0. The report's own binding row
CHANGES what it says for macOS users, which reads like a behaviour change and is not one in
the lineage sense: it is a renderer correcting a false verdict, and it persists nothing.

**Known gaps, accepted and named:**

- **The suite has no `windows-ci.v1.json` entry**, deliberately: every shard there is
  already close to its `profileTimeoutMs`, adding one has to be paid for by moving another
  suite off, and this check has no Windows dimension to justify that. It is in
  `ciStructureTests`, so the weekly Windows Safety structure shard does run it — say
  "not on the Windows PR shard", never "POSIX only".
- **No `tests/profiles/ci-shard-weights.v1.json` entry**, so it is costed at
  `defaultSeconds`. That file's own note sanctions the omission until a real CI figure
  exists; take one from the first green ubuntu-latest `--ci` run rather than estimating.
  Measured locally on macOS at roughly 20 s, spawn-dominated: one `bash -n` per multi-line
  substitution across the tree.
- **The scan is bounded to `*.sh`.** A hook body with no extension, or shell embedded in a
  `.js` heredoc, is invisible to it. Every shell carrier in this tree ends in `.sh` today.
- **It cannot see a substitution the naive scanner mis-delimits for the OTHER reason.** A
  comment apostrophe corrupts the walk before the body is extracted, so the body handed to
  `bash -n` is not the one 3.2 would parse and the finding may not surface. That is the
  same limitation the un-shipped detector above has, from the other side.
