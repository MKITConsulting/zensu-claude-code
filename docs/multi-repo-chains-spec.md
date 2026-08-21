# Multi-Repo Chains — Anchor and Declared Code Roots

**Status: proposed. Nothing in this repository implements any part of it.** Every
"today" statement below was read at the cited site in the worktree that authored
this document; every "would" statement is design, not behavior.

Companion pages: `docs/multi-repo-chains-principle.html` states the principle in
one diagram; `docs/multi-repo-chains-overview.html` walks the same material
visually, including the per-site findings this document cites.

## 1. The problem

A session whose `CLAUDE_PROJECT_DIR` is an orchestrator repository, while the code
it writes lands in sibling repositories or worktrees, is served by a chain that
cannot see that code. The chain's evidence spine — the edit-landing audit, the
review packet, the terminus checks — is anchored on one project root, and the
reviewer is anchored on the same root. The result is not a refusal. It is a chain
that converges green having audited and reviewed nothing.

## 2. What is verified today

Six sites, all single-root.

**The anchor has one resolver.** `tdd_state_file()` builds
`<project_root>/.zensu/state/tdd-phase-<session>.json` from
`zensu_resolve_project_dir()` (`hooks/lib/zensu-tdd-phase.sh:144-151`), and
`pre-bash-source-write-gate.sh:266-275` refuses an empty recorded root outright
rather than letting the parser fall back to the payload cwd. The anchor is a
trusted value derived from the immutable Session Control record, not an ambient
environment variable. Nothing in this proposal weakens that.

**The edit-landing audit already takes a `--project` argument** — it defaults to
`CLAUDE_PROJECT_DIR` (`hooks/lib/zensu-edit-landing.sh:36`, flag at `:49`) and
enumerates the change set with `git -C "$REPO_ROOT"` (`:69-93`). But its receipt
lands at `<--project>/.zensu/state/edit-landing-<session>.json` (`:266`), while
`--tdd-complete` looks for it beside the ANCHOR's workflow document
(`hooks/lib/zensu-log.sh:572`). Running the audit once per repository therefore
writes receipts nothing reads, and each run reports the other repository's claims
as not landed, so no run can exit 0.

**The receipt gate is scoped by the anchor's change count.**
`hooks/lib/zensu-log.sh:558-568` counts `git -C "${CLAUDE_PROJECT_DIR:-.}" diff`
plus untracked files and skips the receipt requirement entirely at zero. A clean
orchestrator therefore closes the chain with no receipt at all. The comment at
`:552` states this mirrors the `--chain-done` dirty-tree refusal; the
`--chain-done` site itself was not read for this document.

**The write gate confines Bash writes, the edit gate does not confine paths.**
Rule (B) denies at `!within(projectRoot, p)`
(`hooks/lib/bash-source-write-parse.js:808`) and rule (C) at the same predicate
for git targets (`:854`), with `projectRoot` taken from the passed
`CLAUDE_PROJECT_DIR` (`:695`). `hooks/pre-edit-tdd-reminder.sh:137-164` resolves a
relative path against the project root and then classifies it only as `state`,
`zensu`, or `other` — an absolute path outside the root is not denied there. So
`Edit`/`Write` reach a sibling repository today and Bash writes do not. The two
other hooks on the `Bash` matcher, `pre-bash-zensu-gate.sh` and
`pre-write-secret-scan.sh`, carry no project-root reference at all and need no
change.

**The reviewer is confined to the project root.**
`protectedAccessViolation` in `hooks/lib/reviewer-capability-v1.js:319` refuses any
reviewer path input outside the root with `file access must remain inside the
immutable project root`, and `:285-291` rejects an absolute Grep/Glob pattern, a
`..` segment, and a `.zensu` segment. A reviewer cannot read a sibling repository
even when the packet names its files.

**Claims are repo-root-relative.** `skills/tdd/SKILL.md:184` requires every logged
`WIRED — files:` / `IMPL completed — files:` list to be relative to
`git rev-parse --show-toplevel`. Across two roots `src/foo.ts` is ambiguous.

## 3. Non-goals

- Multiple equal project roots. There is exactly one anchor, and it keeps the
  Session Control record, the state directory, the run log, the workflow
  document, the phase gate and every `/zensu:doctor` row.
- Any change to `~/.claude` state, to the session registry, or to how Claude Code
  itself records a session.
- Making a satellite resumable. See §6.4.
- Cross-repository commits, pushes, or a merged pull request. Each root keeps its
  own VCS lifecycle.

## 4. Terminology

**Anchor** — the session's single project root, resolved exactly as today.

**Code root** — an additional repository or worktree, declared at arming time,
that this chain may write to and must audit and review. Never carries state.

**Union** — the anchor plus every code root. The only new set.

## 5. Stage 1 — Detect and refuse (patch, no schema change)

Stage 1 ships no multi-root capability. It removes the silent green.

1. The edit-landing audit fails, rather than silently reporting "not landed", when
   a claim resolves to a path outside the audited root, and names the foreign
   root in the failure.
2. `--tdd-complete` evaluates the receipt requirement even when the anchor's
   change count is zero, whenever the run log carries at least one
   `IMPL completed — files:` or `WIRED — files:` claim. A chain that logged
   claims has something to verify regardless of what the anchor's tree looks like.
   A chain with no claims stays exempt, as today.
3. A `/zensu:doctor` row names the topology: claims logged against a root that is
   not the anchor.

After stage 1 the chain is still single-root. It no longer reports success for
work it did not see.

## 6. Stage 2 — Declared code roots (minor)

### 6.1 Data model

One new field in the workflow document, written once by `--tdd-begin` and never
again:

```
codeRoots: [ { label: "<slug>", path: "<canonical absolute path>" }, … ]
```

`label` is the claim prefix. Claims become `label:path/relative/to/that/root`;
the anchor's own claims keep their current unprefixed spelling, so every existing
log line stays valid and stage 1's failure mode does not fire for single-root
chains.

Absent or empty means single-root, which every chain armed before this field
existed is. Reading code must treat absence as the current behavior, never as an
error.

### 6.2 Validation, performed once at arming

A path is accepted only if it canonicalizes, is a directory, is the top level of
a git work tree, is not the anchor, is not a parent of the anchor, is not a
filesystem root, and does not repeat another entry's canonical path. `label` must
be unique and must match a conservative slug pattern, because it reaches a
filename in the merged receipt.

A rejected entry refuses the arming with the reason. It is never silently
dropped: a dropped root is a root nothing audits.

### 6.3 The four multi-repo consumers

| Consumer | Change | Site |
|---|---|---|
| Edit-landing | Enumerate the union; resolve each claim through its label; write ONE merged receipt beside the anchor's workflow document, carrying a per-root verdict. | `hooks/lib/zensu-edit-landing.sh`, receipt path `:266` |
| Review packet | Enumerate `changed_files` per root and emit them label-prefixed. | `skills/tdd/SKILL.md` step 10.2 |
| Write gate | Rules (B) and (C) accept a path inside ANY union member. | `hooks/lib/bash-source-write-parse.js:808`, `:854` |
| Terminus | The zero-change scoping of `--tdd-complete` and `--chain-done` counts the union. | `hooks/lib/zensu-log.sh:558-568` |

The write gate receives the union the same way it receives the anchor today —
from the hook, which reads it from the trusted record and the workflow document,
never from the parser's own environment.

### 6.4 Session transferability

`/zensu:session-trail` keeps working unchanged, because a multi-root session still
has exactly one `cwd` and one transcript. What degrades is fidelity, and one part
of it degrades dangerously.

`gitState(cwd, full)` (`skills/session-trail/scripts/trail.mjs:769`) takes a
single path, and that path is the anchor. In this topology the anchor is clean
while the changed files sit in the code roots, so a `takeover` brief would report
no uncommitted changes for a session with a dirty tree in two other repositories.
That is the same silent-green failure as §2, relocated into the handover path.

The fix costs no schema. `trail.mjs` has no write channel
(`skills/session-trail/SKILL.md:51`); it may read the anchor's workflow document,
take `codeRoots`, and call `gitState` once per union member, rendering the results
grouped by label.

Two properties stay as they are, deliberately:

- **Resume happens in the anchor, always.** The printed
  `cd <cwd> && claude --resume <id>` (`trail.mjs:1067`) already lands there.
  Resuming inside a code root would present a different `CLAUDE_PROJECT_DIR`, the
  recorded `project_root` would no longer match, and the session would bind as
  orphaned or not at all. The resume line must never be rewritten to a code root,
  however plainly the work lives there.
- **Discovery stays anchor-scoped.** `list` keeps only transcript directories
  whose name starts with the slug of the repo's main checkout
  (`skills/session-trail/SKILL.md:152`), so from a code root's repository the
  session is reachable only via `--all` or from the anchor. This is pre-existing
  behavior that multi-repo makes more consequential; this proposal does not
  change it and must not claim to.

## 7. Stage 3 — Cross-repo review (minor)

A single additional review stage between per-root convergence and the terminus.
Each root's review chain runs to convergence exactly as today. The new stage then
runs once, reads the union, and reports only findings that are about the relation
between roots: a field or payload key added in one root with no consumer in
another, a port and its client disagreeing on shape, version skew across a
published contract. Its findings feed the ordinary fix loop in the affected root.

### 7.1 Why it is mode-independent

`skills/tdd/SKILL.md:193` lists the whole review chain — fan-out, judge second
pass, Finding Verification Gate, the consuming reviewer, the self-review terminus
— among what runs exactly as written in vanilla. A reviewer reports a finding; it
does not demand a Characterization test. That demand is precisely why the
Cross-Layer Value Flow Audit cannot run in vanilla (`:194`, `:198`, `:201`), and
the new stage does not inherit it.

### 7.2 The capability lease

The reviewer confinement of §2 is not opened, it is redirected. The new agent's
lease carries the union, and `protectedAccessViolation` accepts a path inside a
leased root instead of the anchor alone. Per-root reviewers keep their present,
narrower confinement — the widening belongs to one agent type, not to the class.

The Grep/Glob pattern rule at `reviewer-capability-v1.js:285-291` needs a
decision this document does not make: a cross-root reviewer needs to search more
than one tree, and the present rule forbids an absolute pattern. Either the tool
call carries an explicit root selector, or the pattern rule learns the same leased
set. Deciding this by widening the pattern rule to "absolute is fine" would
remove the guard for every reviewer, which is not acceptable.

### 7.3 The chain shape cost

A stage between convergence and the terminus is a new chain shape in
`classifyChain()`. Per the repository conventions in `CLAUDE.md`, that shape and
its supported next command travel with roughly eight consumers: `--chain-status`,
`--chain-recover`, the refusal-hint renderer, `stop-chain-enforcer.sh`, the
`/zensu:doctor` renderer, the ticket issuer, the rearm writer, and the
`reviewRearm` validator in `session-control-core-v1.js`. The validator is the one
that must land first: it rejects the ENTIRE workflow document on an unexpected key
set, which fails every hook closed — strictly worse than a wedged chain. These
consumers were taken from the conventions document; the `classifyChain()`
implementation itself was not read for this document.

## 8. Security considerations

Two of the changes are capability grants, not configuration.

Widening rule (B)/(C) lets Bash write outside the previously bound tree. Widening
the reviewer confinement lets a read-only agent read outside it. Both are
therefore bound to the same list, and that list must satisfy all of:

1. It is written once, at arming, into the workflow document, and is immutable
   for the life of the chain — the same discipline as the `vanilla` flag.
2. It is never carried by an environment variable, and never derived from
   model-authored text: not from the plan body, not from a spec, not from a review
   comment. A root the model can name is a confinement the model can leave.
3. Every entry passes §6.2 before it is admitted anywhere.
4. An entry that fails validation refuses the arming rather than being skipped.

The existing inline escapes (`ZENSU_BASH_WRITE_GATE=off`,
`ZENSU_EDIT_LANDING_GATE=off`) are unchanged and keep landing their bypass-ledger
entries. Nothing here adds a new escape.

## 9. Versioning

Under the runtime-lineage rule in `CLAUDE.md`, while the plugin is at major `0`
the minor is the breaking axis, and any change to the workflow-state schema or to
a strict key set forces a minor release. `codeRoots[]` is a schema field, and the
stage 3 chain shape touches the `reviewRearm` strict key set. Stage 2 and stage 3
are therefore each a `minor`. Stage 1 adds no field and is a `patch`.

## 10. Test obligations

- The truth table of §6.2, one case per rejection reason, including the
  parent-of-anchor and filesystem-root cases.
- A merged receipt with a per-root verdict, and the negative: a claim in root B
  that never landed fails the audit while root A is clean.
- Rule (B) and rule (C) allow inside every union member and still deny outside
  all of them, with the temp carve-out unchanged.
- A chain armed with no `codeRoots` behaves byte-identically to today. This is
  the regression pin that matters most, because every existing chain is that
  chain.
- The reviewer lease admits a leased root and still refuses an unleased one.
- `trail.mjs` renders per-root git state, and the resume line still names the
  anchor.

## 11. Open questions

- The Grep/Glob pattern rule for the cross-root reviewer (§7.2) is undecided.
- The `--chain-done` dirty-tree refusal was inferred from the comment at
  `hooks/lib/zensu-log.sh:552`; its own implementation must be read before §6.3's
  terminus row is implemented.
- `classifyChain()` was not read; the consumer roster in §7.3 comes from the
  conventions document and must be re-derived from the code.
- Whether a code root should be allowed to be a worktree of the anchor's own
  repository. Nothing above forbids it, and nothing above needs it.
