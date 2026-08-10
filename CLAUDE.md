# zensu-claude-code Repo Conventions

## Language

**English only.** All code, comments, docs, commit messages, plan files,
prompts, fixture content, and pattern alternations must be in English.

Runtime `.zensu/plans/*.md` and `.zensu/logs/*.log` are local-only artifacts
(gitignored, never committed) — not part of the repository and exempt from this
rule. Every tracked file must be English-only.

**Carve-out — verbatim user-utterance match literals.** Hook directive strings
— and verbatim citations of those literals in structure-test pins, in
README/CHANGELOG feature descriptions, and in this carve-out — may contain
non-English phrases ONLY as match literals for real user input:
the TDD preference fast-paths (e.g. `'kein tdd'`, `'mit tdd'`, `'tdd bitte'`)
and the generic-action literals that are explicitly NOT a preference
(e.g. `'mach mal'`, `'los gehts'`, `'jetzt umsetzen'`) in
`plan-approved-delegate.sh` / `user-prompt-tdd-reminder.sh`. They exist to
recognize what multilingual users actually type, never as prose. Keep these
phrase lists in lockstep across every directive variant (strict and vanilla)
— never edit one variant alone.

## Version Bumps

**Every plugin version bump MUST update `.claude-plugin/plugin.json`, the
marketplace version, AND the marketplace source `ref` in the same commit.**

The two files serve different consumers:

- `.claude-plugin/plugin.json` — manifest read by claude-code when loading the installed plugin. Defines runtime agents/skills/hooks/mcpServers.
- `.claude-plugin/marketplace.json` — catalog read by `claude plugin marketplace update <name>`. Its Zensu entry uses the official GitHub source object for `MKITConsulting/zensu-claude-code` and an immutable `v<plugin version>` ref. Both `.plugins[0].version` and `.plugins[0].source.ref` must match `plugin.json`; a mutable branch source is forbidden.

Historical: `marketplace.json` was created at `0.2.0` (commit `a0a58b2`) and never re-bumped while `plugin.json` advanced through 0.2.x → 0.3.x. Result: every release between 0.2.0 and 0.3.15 was invisible to the directory marketplace and users running `claude plugin install zensu@zensu` could not pull the new code without uninstalling + manually clearing the cache directory. Fixed in PR #31; this convention prevents recurrence.

**Releasing — automated via the `Release` workflow** (`.github/workflows/release.yml`):

1. Actions → **Release** → run with a `version_type` (`patch`/`minor`/`major`). The `prepare` job computes the next version from the latest `vX.Y.Z` tag, bumps `plugin.json` + marketplace version + marketplace `ref` + the README badge **together**, and generates a `## [X.Y.Z]` CHANGELOG section from the conventional commits since the last tag (git-cliff, `cliff.toml`). For a real run it creates the `release/vX.Y.Z` commit locally, then runs `bash tests/run-all.sh --ci` **against that exact commit** — the suite gates the tree that actually ships, never a pre-bump tree nobody releases — verifies the exact clean commit SHA plus the Session Control runtime digest, uploads deterministic SHA-bound evidence, and **only then pushes the branch** and prints a "Compare & PR" link. The suite runs once per job on purpose: two full runs inside one job exceeded the runner limit and made every release time out. Promptfoo and live-model suites are local-only and are never invoked by GitHub Actions. `dry_run: true` remains an offline version/notes preview: it creates no commit, uploads no release evidence, and pushes nothing.
2. Open the PR from that link, then review + **squash-merge** it. (CI pushes the branch but does not open the PR — the org caps the workflow token for PR creation; release/tag creation only needs the per-job `contents: write`, which works.)
3. The release commit landing on `main` is **not** plugin go-live: the updated catalog points to an as-yet unavailable tag. The `publish` job verifies the GitHub repo/ref/version invariant and rejects a pre-existing tag at any other commit, re-runs `bash tests/run-all.sh --ci` against the exact clean `${{ github.sha }}`, revalidates the runtime digest, and uploads a second deterministic SHA-bound evidence artifact. Only then does it create `vX.Y.Z` at that SHA and a **published** GitHub Release (notes = the new CHANGELOG section, source zip attached). Successful tag creation makes the source resolvable and is go-live. An exact existing tag with a missing release can be repaired idempotently after repeating the deterministic gate. Users pull it via `claude plugin marketplace update zensu`. The release notes were already reviewed in the bump PR body, so there is no separate draft-publish step.

The version/ref invariant above is machine-enforced: the gate runs `tests/run-all.sh --ci` (including the version-sync and immutable-marketplace tests) before the branch is pushed. For a manual hotfix bump, follow the invariant by hand — `plugin.json` version + marketplace version + marketplace `ref: vX.Y.Z` + README badge (same version) + a new `## [X.Y.Z] - YYYY-MM-DD` CHANGELOG section + commit subject `chore(release): bump version to X.Y.Z`.

If marketplace version or source `ref` ever lags `plugin.json` (for example, a hand bump forgot one field), fix both in the release PR before any tag is created or any user-side `claude plugin install <name>@<name>` attempt.

## CLI Command Classification (`hooks/lib/zensu-mcp-tools.sh` + `hooks/lib/zensu-cli-map.sh`)

The plugin drives Zensu through the typed `zensu` CLI (the MCP server still exists for the Zensu web app, but is no longer wired into the plugin). The write-gate now intercepts `zensu <noun> <verb>` Bash invocations rather than MCP tool calls.

**When the Zensu backend gains a new operation, two files move together:** classify the canonical tool name in `hooks/lib/zensu-mcp-tools.sh` (state-mutating → `ZENSU_MUTATION_TOOL_NAMES`; read/telemetry → the `zensu_is_read_tool` allowlist `ZENSU_READ_TOOL_PREFIXES` / `ZENSU_READ_TOOL_NAMES`), AND map its `zensu <noun> <verb>` CLI form to that tool name in `hooks/lib/zensu-cli-map.sh`.

`zensu-mcp-tools.sh` is the single source of truth for read/mutation classification, consumed by:

- `hooks/pre-bash-zensu-gate.sh` — the PreToolUse(Bash) write-gate: parses `zensu <noun> <verb>` from the command, resolves each via `zensu-cli-map.sh`, and classifies via this SoT — `zensu_is_read_tool` commands pass ungated, mutations are default-denied unless workflow-driven.
- `hooks/lib/zensu-cli-map.sh` — the CLI→tool-name adapter the gate and the marker test use. Its mutation entries stay a subset of `ZENSU_MUTATION_TOOL_NAMES`.
- `tests/structure/test-skill-workflow-markers.sh` — the build-time guard that fails if a skill runs a `zensu` mutation command (resolved via the map) without the `--workflow-begin` / `--workflow-end` markers.

Consequences of forgetting a new operation:

- **New mutation, not added to `ZENSU_MUTATION_TOOL_NAMES`:** the marker test will NOT flag a skill that runs it un-wrapped. **Test-coverage gap, not an open gate.**
- **New read, not added to the read-allowlist:** if the map resolves it to a name that classifies as a mutation, it is wrongly gated on the main thread until added.
- **New CLI verb, not added to `zensu-cli-map.sh`:** the gate cannot resolve it → treated as unknown/neutral → allowed ungated, so a mutating verb would slip the nudge. Add every new mutating verb to the map.

Invariant: `ZENSU_MUTATION_TOOL_NAMES` must stay a strict superset of every skill's `--workflow-begin --tools` declaration AND of every mutation the CLI map emits. `tests/structure/test-bash-zensu-gate.sh` + `test-skill-workflow-markers.sh` pin the read/mutation classification and the CLI-form detection.

## Git Mutation Tables (`hooks/lib/bash-source-write-parse.js`)

Rule (C) of the PreToolUse(Bash) source-write gate denies a working-tree-mutating
git subcommand whose target repository escapes the session root. Four module-scope
tables are its single source of truth — `GIT_MUTATIONS`, `GIT_READONLY_FORMS`,
`GIT_OPTS_WITH_OPERAND`, `LINKED_WORKTREE_GIT_DIR` — plus a fifth constant,
`UNEXPANDED`, which is NOT exported and therefore cannot be pinned from the unit
layer at all. The first three are re-encoded outside the module; the admin-dir
shape is re-encoded only as the W153 probe path.

**Adding or removing a gated verb** must land with all of these in the same commit:

- the verb-count literal in `tests/structure/test-bash-source-write-gate.sh` (W164),
  which is what catches a REMOVED verb — the probe loop is driven by the set itself
  and therefore cannot;
- the hardcoded membership list in `tests/structure/git-repo-escape.test.js`, kept
  deliberately independent of the set under test for the same reason;
- a read-only spelling in `GIT_READONLY_FORMS` if the verb has one, plus the pins
  that every exemption key is a gated verb and that each verb's bare form is still
  a mutation.

**Adding an operand-consuming global option** requires the membership list in
`git-repo-escape.test.js`: drop one and its operand parses as the subcommand,
silently disabling rule (C) for that spelling with the whole suite green.

**Documentation is machine-enforced in two places that pull in opposite directions.**
The hook header in `hooks/pre-bash-source-write-gate.sh` must NAME `GIT_MUTATIONS`
and `GIT_READONLY_FORMS` and re-author neither — W165 fails if a gated verb is
enumerated there. The parser header must NAME every accepted gap — W192 matches each
gap's distinguishing clause, not a bare keyword. Both pins also require the "not a
security boundary" framing to survive. README §"Source-Write Gate", the README
hook-reference row and the `bashWriteGate` config row point at the tables rather than
listing them, for the same reason; they are not pinned.

The `worktree`/`remove|move` literals appear three times — the `GIT_READONLY_FORMS`
entry, the `paths` guard in `gitTargets`, and the `addressed` substitution in
`decideGit`. A divergence is caught behaviorally (W144/W145/W172-W175 plus the unit
`paths` cases), not structurally; keep them in step by hand.

**The Windows comparison namespace.** Every path string enters rule (B)'s and rule
(C)'s comparison through `msysToDrive(value, isWindows)`. Windows is the only host
where the gate compares two spellings of one location: MSYS converts an EXPORTED
variable, so `CLAUDE_PROJECT_DIR` arrives as `D:\a\proj`, while the payload cwd and
every command token arrive over stdin still spelled `/d/a/proj` — and `path.resolve`
reads that leading `/` as drive-RELATIVE, splicing the whole POSIX path under the
current drive (`D:\d\a\proj`). The session's own root then compares as an escape and
every in-project git verb denies. `hooks/pre-bash-source-write-gate.sh` exempts
`CLAUDE_ENV_FILE` from that same conversion by hand (`MSYS2_ENV_CONV_EXCL`), which is
why `controlPathNamespace` exists for that one variable and why it cannot be reused
here: it returns a lowercased forward-slash namespace, not `path.resolve`'s.

Two properties hold the fix, and W3c pins both because a POSIX host cannot observe
either: **every** `path.resolve` call routes through the normalizer (a new,
un-normalized resolution site silently reintroduces the split namespace), and the
normalizer stays platform-gated — on POSIX `/d/a/x` is a legitimate path, and
rewriting it there would hand both rules a different tree. `git-repo-escape.test.js`
drives the normalizer's own branches through its explicit `isWindows` parameter and
re-runs the production composition against `path.win32`. Deliberately absent: an
env-selectable platform switch. It would let the suite exercise the real hook
end-to-end on macOS, but an env var that changes path semantics is a bypass channel
that — unlike `ZENSU_BASH_WRITE_GATE=off` — lands no bypass-ledger entry.

**The MSYS drive rule is SHARED, not copied.** `claude-path-v1.js` exports
`msysDrivePrefix` as a TOTAL function — anything that is not an MSYS drive spelling comes
back unchanged — and both consumers apply their own policy on top: its own
`normalizeHostPathInput` layers a fail-closed-by-THROWING policy for the session-control
trust boundary, while `msysToDrive` in the parser declines that policy. It has to: the
parser RETURNS a deny reason, so an exception would exit non-zero and the hook's fail-closed
branch would deny every Bash call in the session rather than the one command — and
`/var/folders/x`, a DEFAULT entry of the rule-(B) temp list, is one of the spellings that
policy throws on. That is the whole reason the split exists; do not "simplify" the parser
onto `normalizeHostPathInput`. This is the ONE sibling `require` in
`bash-source-write-parse.js`, taken deliberately so a fourth `within()`↔`isInside()`-style
hand-copy never has to be maintained; if the module were missing the parser would fail to
load and its hook would deny, which is the fail-closed direction. W3d pins the delegation,
pins that no private copy reappears (the parser keeps exactly two `([A-Za-z])` rules of its
own, `controlPathNamespace`'s ungated lower-casing pair, which serve the separate
CLAUDE_ENV_FILE namespace), and pins that the shared rule stays throw-free.

Leaving an unconverted token raw changes no verdict: every rooted spelling the throwing
policy rejects resolves outside the session root, so `within()` reports an escape. Whether
that escape is DENIED is separate — `/tmp/x` and `/var/folders/x` are default temp members,
so `isTemp()` allows them by design and always did. Not converting a complete UNC is no gap
either: `path.resolve` already yields the same spelling.

**The temp list travels with the namespace.** `ZENSU_BSWGATE_TEMP_DIRS` is a LIST, and on
Windows both conventions arrive: MSYS converts an exported POSIX `:` list, while an
operator may supply a native `;`-separated one with drive-qualified entries. (The repo's
own renderer, `zensu-host-path.sh`, emits drive-qualified FORWARD-slash paths — `D:/a/tmp`
— and is not wired to this variable; it shows the shape to expect, it does not produce
this list.) `splitTempList` therefore treats a colon as a separator
except in drive position — a plain `.split(":")` shredded `D:\a\tmp` into `["D",
"\\a\\tmp"]`, so the intended root never entered `TEMP` and the rule (B) carve-out
silently stopped applying. The map that follows also drops any entry that resolves to a
filesystem ROOT: `TEMP_SAFE` rejects only roots that CONTAIN the project, which on win32
cannot catch `C:\` while the project sits on `D:` — that entry would carve out an entire
drive with no bypass-ledger entry, and `/c` only became spellable as a drive root once
`msysToDrive` started normalizing it.

**One accepted gap is NOT fail-closed and is pinned rather than fixed:** drive-relative
`D:rel` on the project's own drive resolves against the base and lands INSIDE the session
root, so it is allowed; if the shell's real cwd on that drive is elsewhere the write
escapes. It predates the normalizer (`D:rel` has no leading slash, so `msysToDrive` never
sees it) and `git-repo-escape.test.js` pins the judgment so a change to it is deliberate.

**The harness lies on Windows in three ways, and each one fails SILENTLY on POSIX.**
Every one of these turned a check green — or red — for a reason unrelated to the
contract it names, and none is observable from a POSIX host:

- **Grep the DECODED deny reason, never the hook's raw stdout.** The hook emits through
  `JSON.stringify`, which doubles every backslash, so a `D:\a\…` needle can never match a
  `D:\\a\\…` haystack. This failed W121/W183/W204 on Windows against a message that was
  already correct, and made W121b — whose whole job is to prove a spelling is ABSENT —
  pass without testing anything. `reason()` decodes it; **W3g** pins that every
  `REASON_*` capture is piped through it, and **W3f** makes the encoding itself
  observable on any host. W87e is the deliberate exception: it greps the JSON envelope.
- **A PATH shim cannot intercept the parser's `git`.** `tracked()` uses `execFileSync`
  with no shell, and Windows resolves only a real executable image: an extensionless
  script named `git` is never reached and a `.cmd` twin is refused outright since
  CVE-2024-27980, so the real `git.exe` answers and the spy log stays empty. Both halves
  of W122 then go vacuous — an empty log "proving" an independence nothing tested. It
  probes reachability first and skips only where the parser could never reach the shim.
- **`ln -s` exiting 0 is not evidence of a symlink.** Git Bash satisfies it with a copy
  or a shortcut native Node does not follow; the two directories then genuinely differ
  and DENY is CORRECT, so W167/W168 failed on a premise that did not hold. They confirm
  the link through `fs.realpathSync.native` — the same primitive `canonical()` uses.

**The Windows timeout for this suite is a coverage boundary, not a formality.** At
`timeoutMs: 300000` in `tests/profiles/windows-ci.v1.json` the shard killed the suite
after roughly 210 of its checks, always mid-run at W122 — so W224, W233/W234 and
everything after them never executed on Windows at all while the shard still reported.
It is 600000 now (matching `autopilot-plan-delegate`). Adding checks costs Windows wall
clock; if the shard starts reporting `TIMED_OUT` again, the tail of the file has gone
unverified regardless of how many checks passed before it.

**Three cross-file couplings.** (The MSYS drive rule is deliberately NOT among them: it is
shared through `claude-path-v1.js`'s `msysDrivePrefix` rather than hand-copied — see the
paragraph above.) `WRAP` — the transparent-wrapper set rule (C)'s
`cmd0` anchoring depends on — is hand-duplicated as a JS literal in
`hooks/pre-bash-zensu-gate.sh`; a wrapper added to one and not the other means the
same wrapped invocation is gated by one Bash gate and not its sibling.
`within()` is a hand-copy of `isInside` in
`hooks/lib/reviewer-capability-v1.js`, held in lockstep only by W3b — and the same
predicate exists in `session-control-core-v1.js` and `review-evidence-lease-v1.js`,
with an UNANCHORED `startsWith("..")` variant in `finding-verify-v1.js` that has the
`..bak` defect this gate fixed. Unlike `within()`↔`isInside`, `WRAP` is NOT pinned
against its `pre-bash-zensu-gate.sh` copy — check that one by hand. And
`skills/pr-team-review` Phase E depends on `worktree remove` being judged on the tree
it destroys rather than on the addressed repository — narrow that carve-out and the
skill's documented cleanup starts denying, which is what W181/W185-W187 exist to
catch. That flow also depends on rule (B)'s temp carve-out, so `ZENSU_BSWGATE_TEMP_DIRS`
silently governs whether the shipped cleanup passes. Do not "fix" a deny there by
writing `ZENSU_BASH_WRITE_GATE=off` into a skill: a
shipped escape prefix teaches the hatch and lands a self-inflicted bypass-ledger entry.

## Chain Shape & Rearm Receipt (`hooks/lib/chain-recovery-v1.js`)

`chain-recovery-v1.js` is the single source of truth for two things, and it is **not**
cosmetic diagnostics code:

- `rearmReceiptVerdict()` decides whether a pending `reviewRearm` receipt agrees with its
  own workflow document. `_tdd_issue_review_ticket_critical` delegates its `markerValid`
  check to it, so **relaxing this predicate widens who may issue a review ticket** —
  treat it as write-gate code.
- `classifyChain()` maps a workflow document to the chain shape, the supported next
  command, and the `recoverable` flag that authorizes `--chain-recover`.

These consumers must move together with it, and `classifyChain`'s returned FIELD NAMES are
part of that contract: the `--chain-status` verb, the `--chain-recover` transaction (both in
`hooks/lib/zensu-tdd-phase.sh`), the refusal-hint renderer in `hooks/lib/zensu-log.sh` (a DIRECT `require`
consumer since it reads `BLOCKED_RECOVERY_COMMAND`, plus `wedged` / `deadEnd` /
`recoverable` / `nextCommand` / `shape` off the report), `hooks/stop-chain-enforcer.sh`
(hardcodes the shape literals `wedged-stale-rearm` and `self-review-unbindable`), the `/zensu:doctor` renderer
(`hooks/lib/zensu-doctor-report.js`), the ticket issuer, and the rearm writer
(`_tdd_rearm_autopilot_review_critical`, which takes `isLinkId`, `RETURN_STAGES` and
`REARM_MARKER_KEYS` from here) — adding a receipt field or a return stage in the writer
alone would make every receipt it mints classify as stale and wedge the chain permanently.

An eighth place hardcodes the same receipt schema independently: the `reviewRearm` validator
in `hooks/lib/session-control-core-v1.js` rejects the ENTIRE workflow document when the key
set does not match, which fails every hook closed — strictly worse than a wedged chain. A
receipt-key change must therefore land THERE FIRST, in the same commit as the module and the
writer. A ninth site hardcodes the key NAME only: `_tdd_mark_unclaimed_review_critical`
refuses the unqualified no-ticket terminus while `reviewRearm` is present. That conjunct
narrows the terminus only WHILE a chain is wedged — `--chain-recover` drops the receipt and
the terminus becomes reachable again, by design. Renaming the field without updating the
conjunct removes even that narrowing.

Two more sites hardcode the provenance literals rather than importing them:
`zensu-log.sh --phase` and `tdd_write_phase` / `_tdd_write_phase_critical` reserve the
`CHAIN_RECOVERED` phase and the `chain-recovered: ` reason prefix so only the repair can
mint a provenance entry. Renaming `RECOVERY_HISTORY_PHASE` or `RECOVERY_HISTORY_REASON_PREFIX`
without updating those guards leaves them reserving a dead name and makes the `recoveries`
counter forgeable again.

The repair runs under TWO locks, in this order and never the reverse: the external process
lease `_tdd_locked_run` takes (`external-<sha256(resourcePath)>`) and then the core CAS lock
`mutateWorkflowState` takes (`state-<sessionKey>`). Both are required — the ticket writers
serialize only on the lease, so the core lock alone would not exclude them — and the
`recoverable` predicate is deliberately re-evaluated INSIDE the mutation callback, after
both are held.

The operator-facing shape table in `skills/recover-chain/SKILL.md` mirrors `NEXT_COMMAND`
(a new shape means a new table row); a new `BLOCKED_RECOVERY_COMMAND` reason must be named
in that skill's "recoverable: false" paragraph. `tests/structure/test-chain-recover.sh` T42
enforces that every emitted shape and reason is documented somewhere in the skill.
`tests/structure/chain-recovery-v1.test.js` (node --test) pins the shape lattice and the
receipt predicate; `tests/structure/test-chain-recover.sh` pins the end-to-end behavior.

**Two invariants the recovery must never break**, both learned the hard way in review:

1. `recoverable` requires `reviewTicketConsumed === true`, and the repair NEVER WRITES the
   ticket slot. Writing `reviewTicketConsumed = true` on a document that has it `false` would
   complete the precondition of the *unqualified* no-ticket terminus
   (`_tdd_mark_unclaimed_review_critical`), letting `--code-review-done` close a chain with no
   reviewer, no ticket and no round — so the repair REFUSES such a document (`ticket-slot`)
   instead of normalizing it. A retained CONSUMED ticket is allowed, because `reviewTicket !== ''`
   keeps that terminus shut on its own. The invariant is "the repair never writes a value that
   was a missing precondition of a terminus" — NOT "the repair never makes a terminus
   reachable": dropping the receipt deliberately returns a wedged chain to exactly the
   permissiveness of any freshly armed chain, including that terminus.
2. The bypass ledger records gate escapes ONLY, so everything rendered under "Gates bypassed"
   is true. The repair records its provenance as a workflow `history` entry inside its own
   transaction — never as a ledger entry.

## Pull Request Workflow

**Never commit or push to a closed or merged PR's branch.** Once a PR is merged or closed, its branch is dead — additional commits there belong on a new branch with a new PR.

**Re-check immediately before EVERY push, not once per session.** A PR can flip from OPEN to MERGED between two of your commands (the user, a teammate, or an auto-merge can land it). Treat each push as a fresh interaction:

```bash
gh pr view <num> --json state,mergedAt
```

If `state` is `MERGED` or `CLOSED`, **abort the push**:

1. `git fetch origin main`
2. Create a new branch off `origin/main`
3. Cherry-pick or re-author the change onto the new branch
4. Push the new branch and open a new PR

A `gh pr list --head <branch>` check is not sufficient — it does not distinguish OPEN from MERGED/CLOSED. Read the `state` field explicitly.

This applies to AI agents and humans alike. The `/create-pr` slash command's "PR already exists for this branch" guard does NOT cover the merged-branch case. "I just rebased ten minutes ago" is not a substitute for the check — re-run it every push.
