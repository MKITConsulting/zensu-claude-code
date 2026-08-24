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

## TDD Mode Precedence (`hooks/lib/zensu-config.sh` + `zensu-log.sh --tdd-begin`)

The strict/vanilla implementation mode is decided by a FOUR-RANK ladder, and
`hooks/lib/zensu-log.sh`'s `--tdd-begin` branch is the only place that orders all four
ranks:

1. the session marker `/zensu:tdd-mode` records (`hooks/lib/zensu-tdd-mode.sh` writes
   `<project>/.zensu/state/tdd-mode-<session-key>.json`)
2. `--tdd-begin --tdd-mode strict` — the CALLING SKILL's own default
3. `hooks.tddImplementation`
4. vanilla

**Rank 2 is escalation-only, and that removes the one downgrade spelling a gate can
see.** The value reaches the flag from a `TDD-MODE:` line in a model-read
specification, and a spec body is not always user-authored — `/zensu:pr-fix-findings`
builds one out of PR review-comment bodies. `strict` is therefore the only accepted
value; relaxing the discipline stays rank 1, the user's own action. Widening the
whitelist re-opens a downgrade channel that lands no bypass-ledger entry.

It NARROWS the channel rather than closing it: rank 1's carrier is an ordinary file in
the project tree, and NO gate covers it while the chain is inactive — not the Edit gate
(`pre-edit-tdd-reminder.sh` returns early on an inactive chain, ahead of its
`.zensu/state/` deny) and not the Bash source-write gate (`bash-source-write-parse.js`
carries no `.zensu` rule at all). Both an `Edit`/`Write` and a shell redirect therefore
reach `{"mode":"vanilla"}` ungated. The controls there are prose — "only the user
changes the mode", in `skills/tdd-mode/SKILL.md` and `skills/pr-fix-findings/SKILL.md`
— not a gate. Say so plainly, name both channels, and do not upgrade the claim:
hardening one gate would not close it.

**Rank 2 must outrank rank 3**, or the shipped `tddImplementation: false` makes every
skill default unreachable. **Rank 1 must outrank rank 2**, or a skill overrides the
user.

**Two sites FREEZE the resolved mode into a chain's `vanilla` flag**, and both resolve
the same ladder for every rank that exists there: `zensu-log.sh --tdd-begin` (ranks
1-4), and the Stop-hook adoption of a deferred review (`stop-chain-enforcer.sh`
`VANILLA_SEED` → `autopilot_adopt_pending_review` → `tdd_seed_deferred_review`), which
has no caller-flag carrier and therefore resolves 1 → 3 → 4. Accepted consequence: a
chain armed strict purely through rank 2 in a default-config project seeds its adopted
deferred-review generation vanilla. Everything downstream — the edit gate, the Stop legend,
`--mode` — reads the FROZEN flag and never the marker, so a mid-chain switch changes
nothing. Say "the next chain", never "this session".

**`/zensu:tdd-mode --status` is the ONE reader that consults both**, and it is not a
counter-example to the rule above — it exists to report the rule. It resolves the session
mode from the marker (ranks 1 → 3 → 4) and then reads the running chain's FROZEN flag via
`tdd_state_file` / `tdd_session_active` / `tdd_vanilla_mode`, appending a disclosure when
the two disagree. That makes it a fourth frozen-flag reader, so a change to the flag's
name, shape or accessors lands here as well as in the three above. It degrades to the
resolved-mode answer when the phase library cannot be sourced, because the source happens
after the base line is computed — a load fault loses the disclosure, never the mode.

**Effective vs configured is a deliberate split.** `plan-approved-delegate.sh`,
`user-prompt-tdd-reminder.sh` and the Stop seed call `zensu_tdd_strict_effective`
(marker over config); `session-start-banner.sh` and `session-start-primer.sh` stay on
`zensu_tdd_strict_enabled` BY DESIGN — at SessionStart no marker for the new session
can exist yet, so an "effective" read there would only ever return the config anyway.
A directive that names a cause must name the one that actually decided: after the
switch to the effective mode, the vanilla branches may not assert
`hooks.tddImplementation=false`.

Moving together with the ladder: `zensu_tdd_mode_marker_path` / `zensu_tdd_mode_state_linked`
/ `zensu_tdd_mode_marker_state` / `zensu_tdd_mode_override` / `zensu_tdd_strict_effective`
(the single path template and parse — the writer sources
them rather than re-spelling, unlike zen-mode, whose template is hand-copied into its
reader hook). `zensu_tdd_mode_marker_state` owns the marker VOCABULARY —
`strict|vanilla|released|none`, four values, where `released` is a present `{"mode":"auto"}`
and `none` is absence-or-unreadable — and it is the only parse; `zensu_tdd_mode_override` is a
total reduction over it that collapses `released|none` to `auto`, so its callers keep a
three-value contract and the two cannot drift. `zensu_tdd_mode_state_linked` is the symlink
guard for the `.zensu` / state-dir / marker triple plus an optional extra leaf, and the WRITER
now calls the reader's copy rather than spelling its own; its pre-rename re-check is
deliberately a SECOND call, because that duplication is the TOCTOU defense and collapsing the
two would remove it. A new marker value lands in the reader, in the reduction, and in
`--status`'s label set. Then the `TDD-MODE:` producer (`skills/pr-fix-findings/SKILL.md`) and its parser
(`skills/tdd/SKILL.md` Phase 0 + Mandatory command protocol step 1), that same skill's
§"Vanilla Implementation Mode", which states the ladder a THIRD time for the model,
`skills/tdd-mode/SKILL.md`, `docs/configuration.md` (the `tddImplementation` row),
`docs/gates.md` §Activation, `docs/tdd-manager-workflow.md` §Vanilla implementation mode,
and `docs/architecture.md`. A site left behind does not fail closed — it leaves a stale
rank list the model reads while the helper resolves a different one.

**A second site re-encodes the ORDER**, not just the ladder's prose: `--status` in
`hooks/lib/zensu-tdd-mode.sh` resolves rank 1 → 3 → 4 itself to report provenance. It
is structurally blind to rank 2, and so are the two pre-begin directive hooks — a caller
flag exists only at the moment of arming. So `--status` can answer `vanilla (config)`
while the next `/zensu:pr-fix-findings` run legitimately arms strict; the `mode:` echo at
`--tdd-begin` is the only authoritative report. A new rank, or a fourth marker value,
lands in `--tdd-begin`, in `zensu_tdd_strict_effective` AND here.
`tests/structure/test-tdd-mode-toggle.sh` pins the ladder and the fail-safes;
`test-tdd-vanilla-mode.sh` E3/E3b pin that the freeze survives a marker flip.

**Known gap:** no `/zensu:doctor` row reports the marker or a chain's frozen `vanilla`
flag, so a session-scoped choice is visible only in the `--tdd-begin` echo and in
`/zensu:tdd-mode --status`. Do not claim doctor visibility until that row exists.

## Requirements-Table Gate (`hooks/lib/zensu-plan-requirements.sh`)

`--tdd-complete` refuses a chain whose plan carries no usable `## Requirements` table.
It exists because `/zensu:converge` anchors its whole flow-back audit on that table and
takes a documented LEGACY STOP without one — and in `/zensu:autopilot` the CONVERGE stage
is the ONLY edge into `OPEN_PR` (`hooks/lib/zensu-autopilot-state.sh`, `CONVERGE:CONVERGENCE_PASSED`),
so a missing table turned a machine-mandatory gate into a clean-looking no-op. Both ends
stayed green, which is why it went unnoticed: measured across the author's plan corpus,
a third of plans written after the feature shipped carried no table at all.

**The rule lives in ONE place, and it is STRICTER than converge — not identical.**
The library is the executable copy. Converge's own table rule is its **Phase 0 step 2**
legacy stop, which keys on the table being ABSENT; this library additionally refuses a
present-but-placeholder table, and the two also disagree about deprecated rows in the
opposite direction (counted here, EXCLUDED from converge's coverage audit). Say
"stricter", never "shared" or "cannot disagree": a plan this gate passes is not
automatically one converge can audit in full. The Requirement column is located from the
table's header row rather than assumed to be the second, because the repo-override contract
pins the columns and never their ORDER.

**Which plan is judged is the load-bearing decision, and BOTH channels are bounded.**
`--plan <path>` wins (the skill passes it, in both the Phase 6 spelling and the
Mandatory-command-protocol one — they must not disagree); otherwise the gate reads the
edit-landing receipt's `log` field and substitutes `.zensu/logs/<stem>.log` →
`.zensu/plans/<stem>.md`, because both artifacts are created from one
`{SESSION_TS}_tdd-{slug}` stem. The derivation binds the receipt's `schema` discriminator and
requires the `log` to resolve INSIDE the project's own `.zensu/logs/`; the explicit flag must
resolve inside `.zensu/plans/` and carry the same stem — and with no derivable stem the flag is
REFUSED rather than falling through to the directory bound alone, EXCEPT when
`ZENSU_EDIT_LANDING_GATE=off` is what removed the receipt. That switch is documented as
exempting a session from the receipt precondition, and no receipt means no stem, so refusing
there would make the documented exemption unusable for the shipped invocation, which always
passes `--plan`. In that one case the bound is DROPPED and DISCLOSED (`REQUIREMENTS GATE STEM
UNCHECKED` on stderr), never faked. Without those bounds the flag would
silently defeat the session anchoring the derivation exists to provide — any older plan with
one filled row would satisfy the gate — and a receipt is an ordinary file the session can
write. Every comparison canonicalizes both sides (`realpath` / `cd … && pwd -P`): on macOS a
temp root is spelled `/var/…` by the caller and `/private/var/…` by the kernel, and a raw
string compare there rejects the session's own plan. Four things must therefore move
together: the stem convention in `skills/tdd/SKILL.md` Phase 2, the receipt's `log` field and
its JSON ENCODING in `hooks/lib/zensu-edit-landing.sh`, the substitution in `zensu-log.sh`,
`templates/tdd-plan.md` — whose `{acceptance criterion — machine-checkable}` / `{functional requirement}` cells are exactly what the placeholder-stripping rule keys on, so changing that placeholder syntax makes the gate misjudge — and `{plan_file}`'s definition beside `{log_file}` in Principle 3 — which Phase 2 step 1 now
WRITES, so producer and consumer share one spelling. The receipt's `log` is JSON-ENCODED and
persisted PROJECT-ANCHORED, so the reader never has to guess a root. One of these IS pinned and
it is easy to miss: `tests/structure/test-autopilot-durable-skill.sh` D9 hardcodes the bound
`--tdd-complete` literal from the skill, so adding the flag to that spelling broke a CI suite
this session. The roster is neither fully unpinned nor fully pinned, and D9 is the pin.

**Asymmetric fail direction, deliberately.** An explicit `--plan` that names nothing REFUSES —
the caller asserted where the plan is. A DERIVED path that is not there does NOT, because
nothing was asserted — but the gate then prints `REQUIREMENTS GATE UNRESOLVED` instead of
staying quiet, because "the table passed" and "no table was checked" reading the same is the
exact failure this feature exists to remove. **Refusal wording is typed**: exits 3/4 are a
verdict about the plan, exit 2 and anything else (a missing library included) refuse with
"could not judge the plan" — the sibling rule CLAUDE.md already states for the plan-payload
gate, that a load fault must never be reported as a judged payload.

**Scoping and the switch are copied from the edit-landing receipt gate**, which sits directly
above it in the same verb: a resolvable git HEAD plus a non-empty change set. The two share ONE
change-set computation and ONE spelling of the receipt path — the shared values carry a
verb-scoped `_tc_` prefix, not an `_el_` one, so neither reads as the other's private state, and
`tests/structure/test-tdd-complete-receipt-gate.sh` W3pre/W3 hardcode that prefix (renaming it
made W3 silently vacuous once already, which is why W3pre now checks its own anchor first) —
but they must NEVER share a switch: the computation is armed when EITHER is on, and both
`ZENSU_EDIT_LANDING_GATE` and `ZENSU_REQUIREMENTS_GATE` record a bypass-ledger entry (both were
added to `ZENSU_BYPASS_GATE_ALLOWLIST`; the ledger is what keeps everything a chain renders
under "Gates bypassed" true). **All four consumers conjoin on the scope**, the two gates and the
two ledger records: out of scope there is no decision point to short-circuit, so recording an
escape there would name a gate that never ran.

**Every root in this verb comes from `zensu_resolve_project_dir`, and there is NO divergence to
defend against — a claim an earlier draft of this section got wrong.** `zensu-log.sh` matches
every `--*` verb at the top of the file, binds the session, and unconditionally re-exports
`CLAUDE_PROJECT_DIR="$(zensu_resolve_project_dir)"` BEFORE any verb body runs, so an inherited
`CLAUDE_PROJECT_DIR=` prefix cannot reach the gate at all. `_tc_root` therefore calls that
accessor for OWNERSHIP — the alternative was triple-`dirname` surgery over a layout
`tdd_state_file` owns, which a layout change would silently mis-root — not as a defense. Do not
reintroduce a "the two can disagree about which tree they looked at" residual; it is false. A `.zensu/plans` or `.zensu/logs` component that
is a SYMLINK is refused rather than resolved through — canonicalizing both sides and comparing
for equality would otherwise compare a link target with itself and admit a file anywhere on the
host — and the `..` test is anchored (`rel === ".." || rel.startsWith(".." + sep)`), because a
real file named `..bak.log` inside the directory is inside it.

**Ordering is a contract, not layout.** The receipt refusal must stay FIRST (a session with
neither artifact should hear about the audit it skipped, not about a plan it never reached),
and the table refusal must stay ABOVE the standalone/bound split, which is the only reason
Autopilot-bound chains are gated at all. `tests/structure/test-requirements-table-gate.sh`
B1/B2 pin both, anchored on the REFUSAL text rather than on the env var — the shared
computation names `ZENSU_REQUIREMENTS_GATE` above the receipt refusal, so the switch is the
wrong landmark. Note that source pins must match the ON-DISK bytes: the refusal spells the
section name as an escaped `` \`## Requirements\` `` inside a double-quoted echo, so a grep
written against the decoded message finds nothing.

**The `## Requirements` shape has SEVEN readers, not two**, and all five beside this library
and `/zensu:converge` are model-executed and PRESENCE-ONLY, so every one of them accepts a
placeholder-only table this library refuses: `skills/self-review/SKILL.md` twice (the per-AC
table in the chain-end summary, and the converge offer it renders), and `skills/tdd/SKILL.md`
three times (Phase 6 step 6c's "If the plan has no `## Requirements` table (legacy plan), skip
silently"; the step-10 converge offer, which this thread renders when `hooks.selfReview` is
disabled; and the vanilla-mode statement that the table and the `Covers` mapping stay binding).
A change to what counts as a usable table has to reach all seven. Two further containment
predicates were added by this gate — the JS one inside the `node -e` reader and the shell one in
the explicit channel — which extend the hand-copied `within()` / `isInside()` family this file
already tracks; neither is reachable from a unit layer, because the JS half lives in a `node -e`
string argument rather than a required module. That placement is a KNOWN COST, not an oversight:
it is why the Windows namespace defect in the derivation had to be found by review rather than by
a `path.win32` unit test, and extracting the resolver into a module is the standing fix.
**The two copies do not enforce the same bound**, which the cost note alone would not tell you:
the JS half accepts anything that does not ESCAPE `.zensu/logs/` — including a subdirectory —
while the shell half requires exact directory equality for `.zensu/plans/`. Low impact (a looser
logs bound only changes the derived stem) but it is a divergence, not one rule in two places.
**Neither half has ever run on Windows**: `test-requirements-table-gate.sh` is not in
`tests/profiles/windows-ci.v1.json`, which is a curated set, so the derived channel's Windows
behavior is unverified in both directions — say "unverified", never "covered".

**The receipt schema moved to `edit-landing-v2`, and the reader accepts BOTH.** Holding the
discriminator at `v1` while the `log` field became project-relative was tried first and was
wrong: one schema name then covered two value domains, so the reader had to infer the writer from
a leading slash — and that inference REFUSED a perfectly readable v1 receipt on win32, which,
because the shipped skill always passes `--plan`, became a completion-blocking `exit 1` rather
than a warning. The version cost was never avoidable: under the runtime-lineage rule above a
persisted shape that moves costs a `minor` release whether or not the NAME moves, so
`version_type: minor` is required for this change either way — moving the name is simply what
buys the reader something for that price. Keep this true: `v1` is a SUPPORTED input, not a
corruption. A plugin update landing between the step 5b audit and `--tdd-complete` is explicitly
served by the lineage rule, so both branches must stay readable, and both are judged by
CONTAINMENT rather than by spelling.

Operator-facing accounts that must move with it: `docs/gates.md` §"Requirements-Table Gate",
the `ZENSU_REQUIREMENTS_GATE` and `ZENSU_EDIT_LANDING_GATE` rows plus the visible-opt-outs
enumeration in `docs/configuration.md`, and discipline patch 11 in
`docs/tdd-manager-workflow.md`.

**Known gaps, accepted and named:**

- **The check is one-sided.** It proves a table EXISTS and is filled in; it cannot tell whether
  the rows describe the work actually done. A chain that copies eight plausible requirements it
  never implemented passes. Closing that is `/zensu:converge`'s job, which is what this gate
  exists to keep reachable.
- **A bound zero-change chain is not gated, and that is the edge the feature is about.** The
  scope requires a non-empty change set, but Phase 2 writes a plan unconditionally and
  `--outcome no-changes` is NOT special-cased in `zensu-autopilot-state.sh` — the run still
  travels its return stage into CONVERGE, the only edge into `OPEN_PR`, and converge
  mtime-resolves that ungated plan and legacy-stops. Do not read "CONVERGE is the only edge
  into OPEN_PR" as "that edge is now covered".
- **`ZENSU_EDIT_LANDING_GATE=off` weakens this gate too.** With no receipt there is no run-log
  stem, so an explicit `--plan` keeps only its plans-directory bound: a stale plan from an
  earlier session in the same project satisfies it. Disclosed on stderr, not silent, and the
  same switch already carries its own ledger entry.
- **The git-environment scrub is scoped to this verb, and its sibling is not scrubbed.**
  `--tdd-complete`'s three scope `git` calls run through a subshell that unsets `GIT_DIR`,
  `GIT_WORK_TREE` and `GIT_INDEX_FILE`; the `--chain-done` zero-change terminus in the same file
  still calls bare `git`, so a one-token prefix there still drives its change count to zero. The
  wrapper is defined INSIDE the `--tdd-complete` case arm, which makes the asymmetry structural
  rather than a one-line follow-up: sharing it means hoisting the definition above the verb
  dispatch. Knowingly left as is.
- **A mid-run commit disarms BOTH gates.** The change set is the worktree against `HEAD` with no
  baseline range, so a chain that committed its work measures zero changes and both preconditions
  skip — without even the `REQUIREMENTS GATE UNRESOLVED` line, because the whole block is out of
  scope. The sibling edit-landing library carries a `--baseline` range for exactly this case;
  this verb does not.
- **The standalone `/zensu:converge` offer carries no plan path**, so the gate and the consumer
  can resolve different plans: the gate judges the receipt-derived plan, converge takes the
  newest by mtime. `/zensu:autopilot` step 2b closes this for the bound flow by passing the
  session plan explicitly; the standalone offer literal is rendered by
  `post-review-tdd-delegate.sh` and pinned in several suites, so changing it is a
  cross-file edit that has not been made.
- **A THIRD renderer of the bound `--tdd-complete` deliberately omits `--plan`:**
  `hooks/lib/chain-recovery-v1.js`'s `NEXT_COMMAND` (mirrored in `skills/recover-chain/SKILL.md`)
  renders the recovery spelling flag-free, so an unwedged chain takes the derived channel — the
  weaker one, which can end at `REQUIREMENTS GATE UNRESOLVED` when no receipt exists. It is left
  that way because the recovery renderer has no session plan path to interpolate.
- **The load-fault branch is not behaviorally tested, and cannot be from a bound session.**
  Session Control binds the executing plugin root by runtime DIGEST, so removing or renaming
  `zensu-plan-requirements.sh` in the executing tree makes every stateful command refuse with
  `context runtime digest mismatch` before the verb runs, and a copied plugin root is refused for
  the same reason. Both shapes were tried here and both failed on the binding; the branch is
  pinned at source instead (LM1/LM2).

## Version Bumps

**Every plugin version bump MUST update `.claude-plugin/plugin.json`, the
marketplace version, AND the marketplace source `ref` in the same commit.**

The two files serve different consumers:

- `.claude-plugin/plugin.json` — manifest read by claude-code when loading the installed plugin. Defines runtime agents/skills/hooks/mcpServers.
- `.claude-plugin/marketplace.json` — catalog read by `claude plugin marketplace update <name>`. Its Zensu entry uses the official GitHub source object for `MKITConsulting/zensu-claude-code` and an immutable `v<plugin version>` ref. Both `.plugins[0].version` and `.plugins[0].source.ref` must match `plugin.json`; a mutable branch source is forbidden.

Historical: `marketplace.json` was created at `0.2.0` (commit `a0a58b2`) and never re-bumped while `plugin.json` advanced through 0.2.x → 0.3.x. Result: every release between 0.2.0 and 0.3.15 was invisible to the directory marketplace and users running `claude plugin install zensu@zensu` could not pull the new code without uninstalling + manually clearing the cache directory. Fixed in PR #31; this convention prevents recurrence.

**Releasing — automated via the `Release` workflow** (`.github/workflows/release.yml`):

1. Actions → **Release** → run with a `version_type` (`patch`/`minor`/`major`). The `prepare` job computes the next version from the latest `vX.Y.Z` tag, bumps `plugin.json` + marketplace version + marketplace `ref` + the README badge **together**, and generates a `## [X.Y.Z]` CHANGELOG section from the conventional commits since the last tag (git-cliff, `cliff.toml`). For a real run it creates the `release/vX.Y.Z` commit locally, then runs `bash tests/run-all.sh --ci` **against that exact commit** — the suite gates the tree that actually ships, never a pre-bump tree nobody releases — verifies the exact clean commit SHA plus the Session Control runtime digest, uploads deterministic SHA-bound evidence, and **only then pushes the branch** and prints a "Compare & PR" link. The suite runs once per job on purpose: two full runs inside one job exceeded the runner limit and made every release time out. Promptfoo and live-model suites are local-only and are never invoked by GitHub Actions. `dry_run: true` remains an offline version/notes preview: it creates no commit, uploads no release evidence, and pushes nothing.

   **`skip_test_gate: true` ships WITHOUT the suite, and is the one input that removes a guarantee rather than adding one.** It refuses without a non-empty `skip_reason`, and the evidence artifact then records `gate: "skipped"` plus that reason — it can never say `passed`, so a release that skipped is distinguishable forever after from one that did not. Everything else still binds: the exact-SHA pin, the clean-tree check, the runtime digest, the version/ref invariant, and the evidence upload. The decision is written into the release commit as a `Release-Test-Gate: skipped` trailer, because the `publish` job is push-triggered and `inputs.*` is empty there; the trailer is also what a reviewer reads in the release PR. **Consequence, stated rather than glossed:** any commit whose subject starts with `chore(release): bump version to` AND carries that trailer skips the publish gate, so the protected-PR review — not a machine check — is what stands between a hand-written trailer and an unverified tag. Use it for a release whose diff you have already verified another way (a counter bump, a docs-only fix), never as the default path.
2. Open the PR from that link, then review + **squash-merge** it. (CI pushes the branch but does not open the PR — the org caps the workflow token for PR creation; release/tag creation only needs the per-job `contents: write`, which works.)
3. The release commit landing on `main` is **not** plugin go-live: the updated catalog points to an as-yet unavailable tag. The `publish` job verifies the GitHub repo/ref/version invariant and rejects a pre-existing tag at any other commit, re-runs `bash tests/run-all.sh --ci` against the exact clean `${{ github.sha }}`, revalidates the runtime digest, and uploads a second deterministic SHA-bound evidence artifact. Only then does it create `vX.Y.Z` at that SHA and a **published** GitHub Release (notes = the new CHANGELOG section, source zip attached). Successful tag creation makes the source resolvable and is go-live. An exact existing tag with a missing release can be repaired idempotently after repeating the deterministic gate. Users pull it via `claude plugin marketplace update zensu`. The release notes were already reviewed in the bump PR body, so there is no separate draft-publish step.

The version/ref invariant above is machine-enforced: the gate runs `tests/run-all.sh --ci` (including the version-sync and immutable-marketplace tests) before the branch is pushed. For a manual hotfix bump, follow the invariant by hand — `plugin.json` version + marketplace version + marketplace `ref: vX.Y.Z` + README badge (same version) + a new `## [X.Y.Z] - YYYY-MM-DD` CHANGELOG section + commit subject `chore(release): bump version to X.Y.Z`.

If marketplace version or source `ref` ever lags `plugin.json` (for example, a hand bump forgot one field), fix both in the release PR before any tag is created or any user-side `claude plugin install <name>@<name>` attempt.

## Runtime Lineage (`version_type` is load-bearing)

A plugin update that lands while a session is running leaves the Session Control
record naming the installation that minted it. The running installation may
still **serve** that record when the two share a lineage —
`servesRecordedRuntime` / `runtimeLineageCompatible` in
`hooks/lib/session-control-core-v1.js`. It is the ONE implementation all five
call sites share: `resolveHookSession` and its `resolveOrphanedProjectRoot`
mirror in `hooks/lib/claude-hook-session-v1.js`, `currentClaudeSessionContext`,
and both the SessionStart-resume and SubagentStart branches of
`hooks/lib/claude-session-control-v1.js`. `relatedClaudeSessionContexts` is
deliberately excluded: it compares two records against each other, not a record
against the executing runtime. The axis:

- **same major**, and **while major is `0`, the same minor as well** — `0.17.1 ↔
  0.17.2` compatible, `0.17.x ↔ 0.18.0` not. Without the second clause "same
  major" would make `0.9.2` compatible with `0.17.2`.
- **never backwards**: the executing version must be at least the recorded one.
- the executing root must be a **sibling** of the recorded one, which is what
  keeps a `--plugin-dir` checkout from adopting an installed session's record.

**While the plugin is at major `0`, MINOR is therefore the breaking axis.** A
breaking change costs a `minor` release and a non-breaking feature is a `patch`.
Anything below forces the breaking bump, because a running session would
otherwise be served by a runtime that cannot read what it wrote:

- the context record or workflow-state **schema** (`SCHEMA_VERSION`, any field
  added, removed or retyped);
- **any strict key set** — `reviewRearm`'s `exactKeys`,
  `deferredReviewCancellation`, and every other validator that rejects an
  unknown or missing key rather than ignoring it;
- **removing or renaming a registered hook, or changing a hook's matcher**;
- the **attestation shape**, which is itself a schema two versions must agree
  on. A change to it has to ship in the release that *introduces* the policy it
  serves, never one release later.

Consequence: the `Release` workflow's `version_type` input carries meaning, not
just a number. Choosing `patch` for a change in that list ships a compatibility
claim the code cannot honour. The predicate encodes what the numbers *mean*; it
cannot verify that this policy was followed.

**The release that introduces this policy is itself a `minor`**, because it adds
`executing_plugin_root` and `executing_runtime_digest` to the attestation. It is
the last release before the policy binds, so nothing is served across it.

**Known gap 1 — the review-evidence lease is NOT lineage-relaxed.**
`hooks/lib/review-evidence-lease-v1.js` still compares its recorded
`plugin_root` strictly, so a lease minted before an upgrade is refused after it.
Because `listRecords` validates every record and propagates the first failure,
that one lease then fails every later lease operation for the session. Closing it
needs a lease-schema change — the lease record carries no `plugin_version`, so
there is nothing to judge a lineage against. It is pinned as CURRENT behavior in
`tests/structure/test-versioned-plugin-upgrade.sh` rather than left accidental,
so changing it silently fails loudly. **Adoption works around it, it does not
close it:** `discardSupersededLeases` moves every lease naming the previous
installation OUT of the records directory (into a sibling `superseded/<key>/`,
because `listRecords` fails on any non-`.json` entry, so setting one aside in
place would be strictly worse). The count is reported, never absorbed.

`docs/session-control.md` "Unbindable sessions" carries the operator-facing
account, including the pin this weakens and the two attestation fields that
state the executing runtime. `tests/session-control/session-control-core-v1.test.js`
pins the axis and the sibling rule;
`tests/structure/test-versioned-plugin-upgrade.sh` pins the end-to-end verdicts
across synthetic installs, including that serving a record never rewrites it.

## Adopting a Record Across a Lineage Break (`adoptableRecord` / `adoptContext`)

The lineage rule above judges DECLARED versions and cannot see whether the
persisted shapes actually moved. When they did not, its refusal wedges a session
the running code could read perfectly well — and every write channel is denied,
so the user cannot repair it. `adoptableRecord` / `adoptContext` in
`hooks/lib/session-control-core-v1.js` are the one explicit exit.

**The authorising axis is SCHEMA equality, not the version numbers, and that
gate closes itself.** `validateContext` already enforces the record's
`schema_version` and `validateWorkflowState` already enforces the workflow
document's `schema`, so a release that genuinely moves a persisted shape makes
one of the two unreadable and adoption declines with no new check to remember.
Do NOT replace either with an explicit version comparison — the self-closing
property is the whole design, and a hand-written check is the thing that gets
forgotten.

Seven conditions are ALL required; eight refusal reasons name exactly which one
failed (condition 6 can fail as either `executing-runtime-unidentified` or
`executing-runtime-older`):
`record-unreadable`, `plugin-data-mismatch`, `project-root-mismatch`,
`already-served`, `not-a-sibling-installation`, `executing-runtime-unidentified`,
`executing-runtime-older`, `workflow-schema-mismatch`. `plugin_data` and the
sibling bound are NOT relaxed here either — the latter is what keeps a
`--plugin-dir` checkout from adopting an installed session.

**Two invariants, both learned from the chain-recovery precedent:**

1. **No record field is ever added.** Provenance is a workflow `history` entry
   under the reserved phase `RUNTIME_ADOPTED`, protected in the same two guard
   sites as `CHAIN_RECOVERED` (`zensu-log.sh --phase` and `tdd_write_phase` /
   `_tdd_write_phase_critical`). A field would itself be the breaking bump this
   feature exists to survive, and would cost a `minor` — which would wedge every
   session then running.
2. **No bypass-ledger entry.** The ledger records gate ESCAPES so that everything
   under "Gates bypassed" is true. Adoption escapes no gate; it re-mints a
   record. Same rule, same reason, as `--chain-recover`.

The previous record is never overwritten — it is renamed to
`<key>.superseded-<recorded-version>.json` and stays readable, so "the record is
immutable" remains literally true. `created_at` is carried over.

**The gate channel is a SECOND recognized command, admitted on a DIFFERENT
argument.** `hooks/lib/zensu-doctor-invocation.js` admitted exactly one shape
because `zensu-doctor.sh` writes nothing. `zensu-session-adopt.sh` WRITES, so it
carries its own justification in its own header, and that header is what the
recognizer points at. Keep the recognized list at two; a third entry needs its
justification written down the same way, not a wave at either existing one.
Moving together: `RECOGNIZED` in the recognizer, `isRecognizedInvocation` (the
module main and `reviewer-capability-v1.js` both call it; `isDoctorInvocation`
stays the doctor-only predicate), and `zensu_doctor_allowed`'s contract comment.

**The whole feature needs the SUPERSEDED installation to still be on disk.**
`validateContext` canonicalizes `context.plugin_root` and `readContextInternal`
recomputes the digest against it, so an absent recorded root makes `readContext`
throw — and then `resolveIncompatibleRuntime` answers null, the doctor falls back
to the `unbound` row whose "no valid record" wording this work exists to remove,
and `adoptableRecord` refuses as `record-unreadable`. The diagnosis degrades to
the misleading wording exactly when the repair is impossible. Do not describe the
lineage row as covering every mid-session upgrade; it covers the ones whose
previous version was not pruned.

**Three re-encodings move with this, and none of them is checked by a test:**

- the `recorded<TAB>executing` wire format — one producer
  (`claude-hook-session-v1.js`) and five parsers (`zensu-doctor.sh`,
  `stop-chain-enforcer.sh`, `pre-bash-zensu-gate.sh`, `pre-edit-tdd-reminder.sh`,
  `pre-bash-source-write-gate.sh` / `pre-write-secret-scan.sh` share one spelling).
  Every parser reads `${V##*$'\t'}` for the executing half, which takes the LAST
  field: adding a third field silently redirects all five rather than failing.
- the version-shape rule, spelled twice for two different hazards —
  `ADOPTION_SAFE_VERSION_RE` (a version reaches a FILENAME) and
  `ZENSU_SAFE_VERSION_RE` (a version reaches a JSON string, and now also the
  doctor report). Identical alternation, deliberate hand-copy; keep them in step.
- the review-evidence store layout, hardcoded in `discardSupersededLeases` as
  `review-evidence/v1/{records,superseded}/<key>` and re-implementing the
  ownership predicate that `review-evidence-lease-v1.js` owns, plus — since the
  destination guard landed — that module's `ensurePrivateDirectory` policy and its
  `LEASE_ID_RE`. Four copied elements, not one. The stated reason is narrower than
  it looks: a core -> lease CALL would cycle (that module requires the binder,
  which requires this core), but an ENTRY-POINT seam would not, because
  `zensu-session-adopt.sh` already requires both. The real cost of the seam is
  that it moves the sweep from the core half to an eighth host obligation. If this
  function needs a fourth correction, take the seam. The source `lstat`'s ENOENT
  branch is also the silent one: it cannot tell "no lease was ever minted" from a
  layout that moved, so a layout change makes the sweep a SILENT no-op.

**Port-relevant.** The core half is `adoptableRecord` / `adoptContext` /
`discardSupersededLeases` / `executingPluginVersion` / `adoptionWorkflowStatePath`
plus `ADOPTION_REFUSALS`, in the cross-host `session-control-core-v1.js`. The host
half is SEVEN separate obligations, and a port that takes only the core delta gets
`adoptContext` with no reachable caller and keeps the wedge: the entry script, the
recognizer's `RECOGNIZED` entry, the doctor branch and row, the Stop release, the
deny scope at every gate that denies in this state, the skill, and — easy to miss
— a binder exporting a `privateRecordsDirectory` equivalent that applies the
symlink/alias/permission/ownership checks, because the entry script resolves the
records directory through it and never by hand-joining. A port that copies only
the script gets a TypeError rendered as the wrong refusal. `zensu-codex`,
`zensu-kiro` and `zensu-antigravity` were NOT included in this change.

**The Windows timeout for `test-versioned-plugin-upgrade.sh` is now UNMEASURED.**
It was raised 600000 -> 900000 when Part C added roughly five synthetic installs
and four session lifecycles, but no Windows wall clock was taken — unlike the two
suites this file records a measured figure for. Budget against a measurement
before trusting the headroom. The caveat lives here and NOT in the manifest:
`tests/run-profile.js`'s `SUITE_KEYS` rejects any key outside
`{id, runner, path, args, timeoutMs}` and throws at manifest load, which aborts
EVERY Windows shard before a single suite runs — a `note` field there is a
CI-wide outage, not documentation. Note also that shard-2's `profileTimeoutMs` is
1800000, so a run genuinely approaching 900 s surfaces as a profile abort rather
than the suite `TIMED_OUT` this ceiling exists to make visible.

Operator-facing accounts that must move with it: `docs/session-control.md`
"Unbindable sessions", the binding rows in `skills/doctor/SKILL.md`, and
`skills/adopt-session/SKILL.md`. `tests/structure/test-versioned-plugin-upgrade.sh`
Part C pins the named state, the doctor row, the Stop release, the Bash-matcher
allowance with its ordinary-command discrimination, the refusal truth table, the
end-to-end repair, and that the reserved phase cannot be minted through `--phase`.

## Autopilot Run Scope (`hooks/lib/zensu-autopilot-state.sh`)

A durable Autopilot run is scoped by TWO independent axes, and confusing them is the
mistake this section exists to prevent.

- **Who may see and drive it — the OWNER session.** The active pointer is
  `.zensu/state/autopilot-active-<sha256(ownerSessionId)>.json`, built by
  `_autopilot_active_path`. `autopilot_read_active` takes the owner and filters the
  inventory by it: another session's run is not an orphan, not a hidden run, and not a
  conflict — it is invisible.
- **What it may collide on — the WORKSPACE.** The run records `workspaceRoot`, the git
  working tree it drives. `begin` refuses when any nonterminal run in the inventory holds
  the same `workspaceRoot`, REGARDLESS of owner, because that is the resource two runs
  would actually corrupt: one branch, one commit history, one pull request.

Before this split there was one pointer per project root, so two sessions sharing a project
root serialized even when they drove different worktrees, and a run left nonterminal by a
session that no longer exists blocked the project forever.

**`read-active` and `read-workspace` are two questions, and collapsing them re-opens a real
hole.** "What is MY run" is owner-scoped: the resume hook, `plan-approved-delegate.sh`, the
three `stop-chain-enforcer.sh` sites, both `post-review-tdd-delegate.sh` sites, and
`--autopilot-status`. "Does ANY session hold this working tree" is owner-INDEPENDENT and
must stay so: `_autopilot_begin_standalone_tdd_critical`,
`_autopilot_adopt_pending_review_critical`, and both fences in
`_autopilot_deferred_contention_result`. All four call
`_autopilot_read_workspace_critical` DIRECTLY, because each is already inside the
project lease; there is deliberately no public wrapper, and one that existed
without a caller carried a second, divergent defaulting policy. Owner-scoping that second group would let a
standalone `/zensu:tdd` chain arm underneath another session's durable run in the same tree.
The team-review identity check is a THIRD shape: it resolves the owner from the RUN record
and then asks the first question, because the pointer that must still designate that run is
its owner's, not the attesting caller's.

**One resolver decides the workspace for the writer and for every gate.**
`_autopilot_session_workspace` resolves cwd → git toplevel → canonical path, and falls back
to the project root when cwd is outside it. `autopilot_begin_run` and all three occupancy
gates call it. Two different spellings would make a gate silently miss the run it exists to
see. `--autopilot-begin --workspace <path>` overrides it, but only for a tree that is either the session's own resolved tree or a directory under the project root; anything else refuses with rc 3. Accepted narrowing: a git worktree OUTSIDE the project root can no longer be declared.
`workspaceRoot` is deliberately NOT a member of any `path_indexes` list in `_autopilot_node`:
it is a comparison key rather than a path the worker opens, and it may legitimately sit
outside the project root, which `_autopilot_native_project_path` rejects by design.

**The field is accepted in BOTH key shapes on purpose.** `stateValid` admits `STATE_KEYS`
and `STATE_KEYS_WORKSPACE`, and `mayHoldWorkspace` short-circuits on an ABSENT field, so a
record minted before the upgrade holds EVERY workspace in its project — not its `projectRoot`,
which is what an earlier draft of this paragraph claimed and what the deleted `workspaceOf`
fallback would have implemented. A single strict key set would make every run minted before
the upgrade invalid, `readRunInventory` fails the FIRST invalid record, and the whole project
would then fail closed — strictly worse than the wedge this work removes.

**The occupancy comparison is CONTAINMENT, not equality, and it runs in both directions.**
The key is a git toplevel resolved from the CALLING process's cwd, and the writer and the
gates are different processes: a session that begins a run from the project root and later
reaches a gate from a worktree BELOW it produces two different keys for one branch. `contains`
answers "held" whenever either tree contains the other, which also covers the git-failure
fallback — that path yields the project root while a working resolve yields the repository
toplevel above it. Equality alone reported such a pair as free, and a standalone `/zensu:tdd`
chain then armed underneath a live durable run.

**The FORWARD direction is the one that is not solved, and concurrency makes it normal.**
`begin` writes `workspaceRoot` while still declaring `schemaVersion: 1`, so an installation
WITHOUT this change reads an unknown key at a version it claims to support and rejects the
record. Two mitigations, and the residue between them is stated rather than glossed. First, the
blast radius is bounded: `read-active` now passes its owner into `readRunInventory`, which skips
a record it can prove belongs to someone else BEFORE validating it, so one session's
unreadable record no longer fails every session in the project. Anything unattributable — a
record that will not parse at all — still fails closed, because it cannot be proven to be
someone else's. Second, `begin` and `read-workspace` deliberately pass NO owner and stay strict:
they genuinely need every record. The residue: an older installation running `begin` in a
project where a newer one is live still fails closed, and that is not tested because the suite
has no second installation to run it from. The lineage rule does not cover this — it governs
Session Control record binding, not the project-local run inventory — so a MINOR release is the
only thing standing between the two.

**The `--confirm` on `--autopilot-release` is prose-backed, not consent-backed.** It is an argv
token the model can supply to itself, exactly like `zensu-session-adopt.sh --confirm`, and the
"wait for the user to say yes" control lives in `skills/autopilot-release/SKILL.md`, not in a
gate. Say so plainly rather than describing the flag as user confirmation. What bounds the
damage MECHANICALLY is that it escapes no gate and cannot forge `DONE` — the worker only ever
applies `CANCEL`. Everything else is prose: the skill tells the model to take the run id from a
refusal, but nothing enforces that, and any nonterminal run in the project is releasable by id
from an enumerable directory. Nor is liveness checked: a run whose owner session is very much
alive is cancelled just as readily. `.zensu/state/` is already writable from inside a session by
an ungated shell redirect, so the flag is not the narrowest channel to that directory either.

**The legacy pointer is adopted only by its own owner.** `autopilot-active.json` is never
written any more. When the owner-keyed pointer is absent it is read as a fallback and honored
only if the run it references belongs to the caller; a legacy pointer owned by anyone else is
ignored, and that is precisely the unwedge. `activePointerFor` re-implements the same
resolution inside the worker for `apply` and both budget modes, which receive the state
DIRECTORY rather than a pointer path and derive the owner from the run record.

**`--autopilot-release` bypasses exactly one check.** It applies a real `CANCEL` under the
project lock with the ownership comparison skipped, and refuses a terminal run, a caller that
owns the run, and an exhausted ledger. Provenance is the derived event id (`release-<sha256>`),
NOT a payload field: `payloadValid` requires `CANCEL` to carry the empty object, so a marked
payload would make the released run unreadable to any runtime that has not taken this change.
**No bypass-ledger entry** — the ledger records gate ESCAPES so that everything under "Gates
bypassed" is true, and this escapes no gate. Same rule, same reason, as `--chain-recover`.

**Version.** The pointer layout and the run schema both move, so this is a **`minor`** release
under "Runtime Lineage (`version_type` is load-bearing)" above. The version is never set by
hand; the release pipeline owns it.

**Known gaps, accepted:**

- A refusal names the holding run but the release is a separate, user-confirmed step. It has
  to be: the run belongs to a session that may still be alive.
- **`OWNER_SESSION_MISMATCH` in `plan-approved-delegate.sh` is now unreachable, and the plan
  it used to refuse falls through to the standalone policy instead.** A foreign session that
  approves a plan carrying another run's `<!-- zensu-autopilot:<run> -->` marker no longer
  reaches the owner comparison, because the run is invisible to its owner-scoped read; it is
  asked the ordinary "run /zensu:tdd?" question. Nothing is mutated — the foreign run is not
  touched and no binding is created — so this is a lost DIAGNOSTIC, not a lost guarantee.
  Restoring it needs the marker before the read, and the marker is only resolved inside the
  payload evaluator (see "Plan-Gate Payload Sources"), which reads fields by name and must
  not be duplicated in shell. The exit-6 arm and its `BLOCK_CODE` are deliberately left in
  place rather than deleted, so a future evaluator that can answer "this marker names a run
  you do not own" has its receipt waiting. What the foreign caller now gets is NOTHING: the
  branch is skipped before any payload source is resolved, so it cannot be used as an
  existence oracle either — which is what F20/F20a, F32/F32a and F45c in
  `tests/structure/test-plan-payload-fallback.sh` pin, alongside P6 in
  `tests/structure/test-autopilot-plan-delegate.sh`. Those five cases were written against
  the refusal receipt and now assert the silence instead; F45c in particular no longer pins
  an ORDERING between the ownership and origin refusals, because neither is reachable.
- `/zensu:doctor` still carries NO Autopilot row of any kind, so a held workspace is visible
  only in the `--autopilot-begin` refusal and in `/zensu:autopilot-release`. Do not claim
  doctor visibility until that row exists.
- The `SESSION_CONTEXT_UNAVAILABLE` arm in `plan-approved-delegate.sh` is defense in depth, not
  the live path: `zensu_bind_hook_session` refuses an unresolvable session earlier, so the receipt
  a caller actually sees in that state is `RUNTIME_UNAVAILABLE`. Measured by P8a-P8c in
  `tests/structure/test-autopilot-plan-delegate.sh`, which therefore pin the fail-closed DIRECTION
  (a `PLAN_GATE_BLOCKED` receipt rather than the standalone policy) and not the specific code.
- `_autopilot_storage_safe` validates the legacy pointer by name; the owner-keyed one is
  checked at `_autopilot_begin_critical`, the only site that writes it. Reads are protected
  by `regularFile`, which rejects symlinks and hard links.

Moving together with the scope: `_autopilot_owner_key`, `_autopilot_active_path`,
`_autopilot_legacy_active_path`, `autopilot_workspace_root`, `_autopilot_session_workspace`,
`_autopilot_read_workspace_critical`, `_autopilot_rendered_dir`, `autopilot_release_run`, the `read-active` / `read-workspace` /
`begin` / `apply` / `release` / budget worker modes with their `path_indexes`,
`projectRootIndex` and `workspaceRootIndex` entries, the worker's own second re-encoding of the
pointer name (`activePointerFor`, `OWNER_POINTER_PREFIX`, `LEGACY_POINTER_NAME`), the SEVEN hook
`read-active` call sites enumerated above, the three `ACTIVE_POINTER_HINT` probes that name both
pointer spellings, `hooks/lib/zensu-log.sh` (the `--workspace` flag, the owner-aware
`--autopilot-status`, and the `--autopilot-release` verb with its derived event id),
`skills/autopilot/SKILL.md`, `skills/autopilot-release/SKILL.md`, and the plugin manifest's
skill list. Operator-facing accounts that must move with it: `README.md`'s skill table,
`docs/tdd-manager-workflow.md` §"Autopilot run scope" and the `session-start-autopilot-resume.sh`
row in `docs/configuration.md`.
`tests/structure/test-autopilot-state-machine.sh` pins the pointer, the two refusals and the
legacy fallback; `test-autopilot-adversarial-recovery.sh` X1a pins the `begin`, `read-active`,
`release` and `read-workspace` `path_indexes` literals. It does NOT pin every mode in the table
— `read-run`, `apply`, `team-review-receipt-meta` and the two budget modes are unpinned, so a
change to one of those fails behaviorally or not at all.

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

## Relaxable Bind Failures (`hooks/lib/claude-hook-session-v1.js`)

A failed bind to the immutable Session Control record denies, with exactly **two**
documented exceptions. Both mean no workflow document is reachable, so relaxing waives
nothing — and they are deliberately **two predicates, never one widened check**, because
they are different diagnoses with different remedies:

- `unregisteredSession` — no record at all (the 0.17.0 upgrade state). True only on a
  clean `ENOENT` of the records directory or the record file.
- `orphanedProjectRootSession` / `resolveOrphanedProjectRoot` — a record valid in every
  other respect whose recorded `project_root` is gone (a deleted or recycled worktree).
  It waives ONE check via `readOrphanedProjectRootContext`
  (`hooks/lib/session-control-core-v1.js`, an internal `allowMissingProjectRoot` option
  on `validateContext`) and additionally requires that path to be **absent** — `lstat`,
  never `realpath`, so a dangling symlink stays a present-but-wrong root. It then
  re-applies the plugin-root and plugin-data identity checks `resolveHookSession`
  applies, so a second disagreement is never relaxed alongside the first.
  **Amended by semver-compatible binding:** the plugin-root check there is now the
  lineage-relaxed `servesRecordedRuntime`, so a vanished project root IS relaxed
  alongside an executing root that is a declared-compatible upgrade — deliberate,
  since neither disagreement can anchor a workflow document. An INCOMPATIBLE root,
  a differing `plugin_data`, and every other disagreement stay unrelaxed. See
  "Runtime Lineage (`version_type` is load-bearing)" above.

**Every gate that relaxes one must consider the other**, and they do NOT all agree by
design — the split is the contract, so changing a predicate means re-deciding each site.
The authoritative per-gate roster is the "Unbindable sessions" table in
`docs/session-control.md`, which
carries one column per state; keep exactly one roster and do not duplicate it here. Two
properties are easy to get wrong and cost the whole feature:

- **A deny from ANY hook on a matcher wins.** `hooks.json` registers three PreToolUse
  hooks on the `Bash` matcher (`pre-bash-zensu-gate.sh`, `pre-bash-source-write-gate.sh`,
  `pre-write-secret-scan.sh`) and one on `.*` (`pre-reviewer-capability-gate.sh` via
  `reviewer-capability-v1.js`). `/zensu:doctor` runs through Bash, so it is reachable only
  if EVERY one of them allows. Both the `.*` gate and the secret-scan gate were missed in
  turn while the single-gate test stayed green and the feature silently did not work.
  `tests/structure/test-orphaned-project-root.sh` O21a therefore enumerates the Bash
  matcher from `hooks.json` and asserts every hook on it allows, so a hook added later is
  covered without editing the test.
- **Mutating tools stay denied on purpose.** `pre-edit-tdd-reminder.sh` relaxes neither
  state: nothing in either can anchor a write to a project. Its matcher is
  `Edit|Write|MultiEdit`, so `NotebookEdit` is NOT phase-gated — in a healthy session
  either, which is why the relaxation restores the pre-Session-Control capability set
  rather than widening it. Say "Edit/Write/MultiEdit", never "all mutating tools".
- **A Bash write without a project anchor denies; a read does not.** In both relaxed
  states `CLAUDE_PROJECT_DIR` is typically gone or unset — in the orphaned state it is by
  construction the deleted directory, since the record's `project_root` was minted from
  the SessionStart cwd. `pre-bash-source-write-gate.sh` therefore runs the parser's
  `BSWG_MODE=detect` channel check, which needs no anchor, and denies only commands that
  actually write. Denying unconditionally there once put the diagnostic back behind the
  defect it reports, and the healthy-anchor test fixtures hid it; `O29`/`O29a` pin both
  the deleted-root and unset-anchor shapes.

Shell wrappers live in `hooks/lib/zensu-session.sh` (`zensu_session_unregistered`,
`zensu_session_orphaned_project_root`, `..._model`, plus
`zensu_session_incompatible_runtime` / `..._model`). The orphaned wrapper **prints the
dead path on stdout** and the incompatible-runtime pair prints `recorded<TAB>executing`;
inside a PreToolUse gate stdout is the JSON decision channel, so a caller wanting the
predicate alone must discard it explicitly, and a caller wanting the value must capture
it into a variable before emitting anything.

**The third predicate is a DIAGNOSIS, never a third relaxation.** `zensu_session_incompatible_runtime`
belongs to this roster only because every gate that consults the two above must decide what
to do about it too — and the answer is the same everywhere: keep denying. A workflow document
is still reachable in that state, so relaxing would waive a live guarantee rather than a dead
one. What it changes is the MESSAGE: `zensu_emit_hook_session_deny` gained a fourth scope,
`incompatible-runtime`, taking the two versions as positional arguments. FIVE gates can deny
in that state: the four shell gates emit that scope, and `pre-reviewer-capability-gate.sh` —
the `.*` matcher, where `isRecognizedInvocation` is false for every non-Bash tool — spells the
same cause and remedy itself in JS, because the shell emitter is not reachable from it. A gate
left on the generic text tells the user to start a fresh session while its sibling says the session can
be repaired in place — two denies contradicting each other about the one bind failure that
has an in-place remedy. The Stop hook is the single exception and RELEASES, because it cannot
read the chain from an unbound session at all.

`zensu_emit_hook_session_deny` must never assert "no record" as the cause: naming the
wrong relaxable state sends a user whose worktree was deleted hunting for a record that is
sitting intact in plugin data. Same rule for the `/zensu:doctor` binding rows.

**The release claims only what an ENOENT proves.** A moved or renamed root, and an
unmounted volume, produce the same ENOENT while the workflow state survives intact
elsewhere — so the Stop release says no completion was proven, never that nothing existed
to prove. It also means the release can be induced by renaming the project root, and that
IS reachable from inside a session: `mv` carries no write channel, while `ZENSU_CHAIN` is
read from the hook's inherited environment and a per-command prefix cannot reach it — the
two are not equivalent capabilities. Accepted anyway, because the alternative wedges every
legitimately deleted worktree forever with no in-session escape. **Known open improvement:**
an induced release is currently silent — it cannot be ledgered, because the document a
bypass entry would live in is the one that became unreachable — so a detection surface (a
sidecar beside the immutable record, surfaced by `/zensu:doctor`) is still missing.

**Port-relevant.** The core half (`validateContext`'s `allowMissingProjectRoot`,
`readContextInternal`/`readOrphanedProjectRootContext`) lives in the cross-host
`session-control-core-v1.js`; the host half (binder mode, shell predicate, gate
re-decisions, doctor row) is per host. A port that takes only the core delta keeps the
worktree-deletion wedge; a port that takes neither drifts from this core.

Operator-facing accounts that must move with the predicates: the "Unbindable sessions"
table in `docs/session-control.md`, the Stop-binding section of
`docs/tdd-manager-workflow.md`, and the
binding rows in `skills/doctor/SKILL.md`.
`tests/structure/test-orphaned-project-root.sh` pins the predicate truth table, the
capability gate, every Bash-matcher hook, the Edit gate and the doctor rows;
`tests/structure/test-stop-session-binding-recovery.sh` pins the Stop halves, where B4 is
the discrimination test that a root which still EXISTS but no longer matches keeps
blocking, and B1d that a second disagreement is never relaxed alongside the first.

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
security boundary" framing to survive. `docs/gates.md` §"Source-Write Gate", the
hook-reference row and the `bashWriteGate` config row in `docs/configuration.md` point at
the tables rather than listing them, for the same reason; they are not pinned.

The `worktree`/`remove|move` literals appear three times — the `GIT_READONLY_FORMS`
entry, the `paths` guard in `gitTargets`, and the `addressed` substitution in
`decideGit`. A divergence is caught behaviorally (W144/W145/W172-W175 plus the unit
`paths` cases), not structurally; keep them in step by hand.

**The Windows comparison namespace.** Every path string enters rule (B)'s and rule
(C)'s comparison through `msysToDrive(value, isWindows)`. Windows is the only host
where the gate compares two spellings of one location. **The dividing line is stdin
against everything else**, not env against everything else: MSYS rewrites exported
variables AND the argument vector on the way into a native binary, so
`CLAUDE_PROJECT_DIR` arrives as `D:\a\proj`, while the payload cwd and every command
token — which travel over stdin, the one channel MSYS never touches — are still
spelled `/d/a/proj`. `path.resolve` then reads that leading `/` as drive-RELATIVE and
splices the whole POSIX path under the current drive (`D:\d\a\proj`). The session's
own root compares as an escape and every in-project git verb denies. **W3h pins the
stdin half of that premise**, because everything here rests on it: were stdin ever
converted too, `msysToDrive` would be normalizing an already-native path, every
assertion would stay green, and the real defect would have moved out of view. The
argv half is why the gate suite must hand a raw MSYS spelling to `node` over stdin
rather than as an argument — W121b silently skipped itself on Windows for exactly
that reason, reporting "spellings coincide" while testing nothing.
`hooks/pre-bash-source-write-gate.sh` exempts
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

## Bypass Ledger Read Contract (`tdd_bypasses`)

`tdd_bypasses` is the ONE member of the `_tdd_read_validated_state` reader family
that signals an unreadable document through its EXIT STATUS rather than an echoed
sentinel. Its siblings — `tdd_state_status`, `tdd_get_flag`, `zensu_workflow_allows`,
`tdd_phase`, `tdd_step`, `tdd_has_red_fail`, `tdd_get_counter` — all stay total and
`return 0` with a value (`invalid`, `false`, `INVALID_STATE`, `0`, …). The divergence
is deliberate: this reader's value is rendered VERBATIM into the user-facing
`Gates bypassed during this session:` line, so a sentinel would be printed as if it
were a gate name. It returns **1** for a document that does not validate and **2**
for one that is absent, because a clean ENOENT at `--tdd-begin` is the ordinary
first-arming case and must not be reported as damage.

**No rendering site consumes that status directly.** `zensu_bypass_display`, beside the
constants in `hooks/lib/zensu-tdd-phase.sh`, owns the whole ladder — including a
catch-all that fails CLOSED on an unknown status, which three hand-rolled copies
previously got backwards by testing `-eq 1` and falling silent instead. Its second
argument decides ONLY what an absent document renders: `text` for a terminus that must
disclose (`--bypass-list`, the post-review delegate), the default `empty` for a clearing
verb (`--tdd-begin`, `--tdd-reset`) and for a Stop release, where a clean ENOENT means
nothing was ever recorded. It re-raises `tdd_bypasses`' status, so `--bypass-list` still
exits **3** on a non-zero read — distinct from its pre-existing exit 2 for an unavailable
session identity. `tdd_add_bypass`'s own dedupe is the one exception: it consumes the raw
value inside a `case` word and discards the status by design. Adding a sixth rendering
site means calling the helper, never re-rolling the mapping; both message constants live
beside `ZENSU_BYPASS_GATE_ALLOWLIST` and neither sentence may be hand-copied into a
consumer.

**A chain terminus and a Stop release are both disclosure points**, because a gate escape
needs no file change to be recorded — `ZENSU_TEST_WITNESS` and `ZENSU_MCP_GATE` are both
reachable without one, so a zero-change chain is exactly where an undisclosed escape would
hide. Four release paths therefore render the line themselves on **stderr**, the operator
channel every other Stop release message already uses: `ZENSU_CHAIN=off`,
`hooks.chainEnforcer=false`, the cap release after a chain fails to converge (all three via
`zensu_render_bypass_release` in `hooks/stop-chain-enforcer.sh`), and the `--chain-done`
verb itself via `zensu_render_terminus_bypasses` in `hooks/lib/zensu-log.sh`, which covers
both the standalone and the bound spelling so either entry point discloses. A new release
path added above the routing branches needs the same call.

**Operator-facing accounts that must move with this contract:** the "Visible opt-outs
(bypass ledger)" paragraph in `docs/configuration.md`, which is the AUTHORITATIVE residual
list — the other surfaces point at it rather than restating it, because three divergent
copies is exactly the drift this rule exists to prevent; the `## Open` rendering rules in
`skills/self-review/SKILL.md`; the build-union rule in `skills/autopilot/SKILL.md` and its
`templates/autopilot-pr-body.md` third value. `tests/structure/test-bypass-ledger.sh` pins
the first three; the template is not pinned by that suite.

**What the ledger proves is narrower than it reads.** Validation is STRUCTURAL:
`validateWorkflowState` checks shape plus a self-derivable `session_id_hash`, and the
`bypasses` array carries no MAC and no monotone counter. A document edited in place
but left schema-valid still reads `valid` and renders `none` — `test-bypass-ledger.sh`'s
P5y case performs exactly that read-modify-write and expects a valid result. Closing that
needs a persisted authenticity signal, which is a workflow-state schema field and
therefore a breaking minor under the Runtime Lineage rule; it is deliberately not
paid for. Say "what a readable document recorded", never "no gate was escaped".

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

## Plan-Gate Payload Sources (`hooks/lib/plan-payload-v1.js`)

The Autopilot plan-approval gate reads the approved plan from FOUR payload sources, in
precedence order, and `plan-payload-v1.js` is the single source of truth for which:

| # | Source | Live on the current Claude Code build |
|---|--------|----------------------------------------|
| 1 | `tool_input.plan` | no |
| 2 | `tool_input.planFilePath` | no |
| 3 | `tool_response.plan` | **yes** |
| 4 | `tool_response.filePath` | **yes** |

Sources 1-2 are dead on this host and still ranked first on purpose: a host that DOES declare
those ExitPlanMode fields keeps its meaning, and an explicit caller-supplied plan must not be
overridden by the harness copy. `tests/structure/test-autopilot-plan-delegate.sh` P16 pins that
the legacy carrier still delegates identically, so keeping them costs no behavior.

**Retiring them is not a four-check edit.** In `test-plan-payload-fallback.sh` the `tool_input`
carriers are driven by every case built by `payload()`, `payload_nonstring_plan()`,
`payload_input_and_response()` and the inline F21a/F43 builders — roughly twenty checks — plus
P16. Most have a source-4 mirror already (F5→F35, F6→F36, F7→F37, F13→F40, F15→F38, F16→F39,
F17→F41); the rest would have to be re-pointed at the response carrier. The trigger is a
RE-CAPTURE, not a hunch: only a fresh capture from every supported host can show that none of
them populates `tool_input` for ExitPlanMode any more.

**Why the dead sources are dead.** The harness strips ExitPlanMode fields its schema does not
declare — a captured payload carries `tool_input == {"_targetMode":"auto"}` — and delivers the
approved plan in `tool_response`, a structured object (`plan`, `filePath`, `isAgent`,
`hasTaskTool`). Before this was understood every Autopilot run died at its single planning gate
with `INVALID_PLAN_PAYLOAD`, unfixable from the model side.

**Fields are read BY NAME, never by scanning text.** The rendered response a model sees carries
a `Your plan has been saved to: <path>` preamble, but the plan body is model-authored: mining
that text would let plan prose inject its own preamble and name the path the gate opens.
`test-plan-payload-fallback.sh` F31b (a rendered string response is never mined) and F34 (a
`saved to:` line inside the plan body never names the approved bytes) are the pins; both
discriminate through the persisted digest, because an absent decoy proves nothing.

**Everything that re-encodes this shape must move together:** the module's `SOURCES` table;
every `payload*` builder in `tests/structure/test-plan-payload-fallback.sh` — `payload`,
`payload_nonstring_plan`, `payload_response`, `payload_response_nonstring`,
`payload_response_shape`, `payload_input_and_response`, plus the inline F21a, F31c, F43 and
F11b-tool builders; the fixture-shape assertion F33a; and the whole-flow builders in
`test-autopilot-full-cycle.sh` and `test-autopilot-plan-delegate.sh` (which also keeps
`payload_input_dialect` for the legacy carrier). The committed capture
`tests/structure/fixtures/exitplanmode-posttooluse-payload.v1.json` pins the shape the gate was
BUILT AGAINST; it cannot observe live harness drift — only a fresh capture can.

**Operator-facing account that must move with the sources:** `skills/autopilot/SKILL.md`, which
names `tool_response.plan` and `tool_response.filePath` when it tells the skill where the run
marker has to travel.

`tests/structure/plan-payload-v1.test.js` (node --test, driven from
`test-plan-payload-fallback.sh` F11b) pins the table's order, liveness and label shape, the
reader's refusal codes, and the branches the shell layer cannot reach — a NUL-byte path, a
bare-string carrier, a hard link. F11d pins that every module reason maps to an exit code and
back to the identically named BLOCK_CODE, which no behavioral case can observe.

**The response also declares WHO called, and that is judged before any source is read.**
`tool_response.isAgent === true` refuses as `PLAN_RESPONSE_AGENT_ORIGIN_REJECTED`, and a
present non-boolean refuses as `PLAN_RESPONSE_ORIGIN_TYPE_REJECTED` rather than being read as
falsy — `"false"` and `0` are both truthy-adjacent spellings that would otherwise approve an
agent-originated plan by coercion. This is a POSITIVE assertion layered on Session Control's
absence-based principal check, which grants `main-v1` only to the top-level thread; it is free
to make because the harness supplies the field. Two orderings are load-bearing and pinned:
it runs AFTER the owner and stage checks, so an unauthorized caller still learns nothing about
the response shape (F45c), and BEFORE the source walk, so no payload-named path is opened for
a caller who may not approve. F45/F45a are the bites — measured against the pre-change hook,
which APPROVES both shapes — and F45b is the positive control that the same builder with
`isAgent: false` still approves. Each of the four owns a separate armed run: sharing one let an
approval in an earlier case push the run past `PLANNING`, and every later case then failed on
the transition instead of on what it was about.

**Three checks pin behavior this gate already had and never exercised**, so they pass in both
trees and are coverage, not bites: F47/F47a (a plugin missing the reader module refuses as
`RUNTIME_UNAVAILABLE` — asserted to NOT be `PLAN_EVALUATION_UNAVAILABLE`, which would claim the
payload was judged — with a restored-module positive control), F48 (the module path reaches
node through the environment, never argv, matched against a closed allowlist of line forms
because the evaluator spans ~90 lines and a line-scoped grep would miss an argv token appended
below it), and F49/F49a (a hard link refused through both carriers).

**`PLAN_STAGE_MISMATCH` (exit 7) is unreachable and deliberately left so.** The shell `case`
already filters the active document to `PLANNING|AWAIT_TDD`, and the evaluator re-reads
`state.stage` from that SAME document — there is no second source to disagree with it. The
re-check is defense in depth for a future where the two diverge; do not write a behavioral
fixture for it, there is none.

**The `openMode` seam exists to reach dead code, and must stay a MODE.** The `noFollow === 0`
branch in `readPlanFile` is what a host without `O_NOFOLLOW` runs; every POSIX host this ships
to defines the flag, so in production it never executes. `readPlanFile(path, openMode)` compares
its second argument against the string `LSTAT_PRECHECK_MODE` and never ORs it into the open
flags — a caller can only take the STRICTER path, never widen the open. The unit suite pins that
with `O_CREAT` as the discriminator: were the argument a mask, the reader would create a missing
path instead of reporting it unreadable. Measured property worth keeping: deleting EITHER of the
branch's two guards leaves the suite green, because the other still catches the link; deleting
both fails only in `plan-payload-v1.test.js`. `test-windows-portability-guards.sh` carries the
reader in its secure-open inventory — every other pin there is per-file and therefore blind to a
NEW file carrying a hardened open.

**The Windows timeout for this suite is a coverage boundary, not a formality.** At
`timeoutMs: 600000` in `tests/profiles/windows-ci.v1.json` the `plan-payload-path-transport`
step reported `TIMED_OUT` at check ~61 of 70, so F45c, F49/F49a, F48, F12 and F47/F47a never
executed on Windows while the shard still reported its earlier checks as passing. It is 900000
now, and the full 70-check suite measures **714 s** there — 79% of the new ceiling, so roughly a
quarter of the budget is left. Every check costs Windows wall clock (the old run reached F45 at
540 s of 600 s) and the tail is the expensive part: four extra armed runs plus one full
plugin-tree copy. Budget against the 714 s, not against the ceiling. If the shard starts
reporting `TIMED_OUT` again, the tail of the file has gone unverified regardless of how many
checks passed before it. Same failure mode, same remedy, as the source-write gate's own note
above.

**The digest binds the bytes that TRAVELLED.** When source 3 wins, `approvedPlanSha256` is over
the response string, not the file at source 4's path. The two agreed byte-for-byte in the
capture and F44 pins that agreement, but they are not contracted to; `approvedPlanSha256` is
only written and shape-validated, never re-derived, so a host whose response string and saved
file disagree would silently bind the transported copy.

**Port-relevant.** The module OWNS `SOURCES`; a port edits that table in its own copy of the
file rather than calling in with a different one. `resolveApprovedPlan(payload, sources)` takes
a table argument so the unit suite can drive the walk with a synthetic one, and it REFUSES an
empty or malformed supplied table instead of substituting this host's carriers — two of which
open a payload-named file. A port also carries two host-half obligations the module cannot:
render the lib DIRECTORY through `zensu-host-path.sh` (that script rejects files) before
appending the file name, and guard the loaded spelling with `-f` / `! -L` / `! -r` plus an
export-shape check, routing any load fault to the RUNTIME receipt — never to
`PLAN_EVALUATION_UNAVAILABLE`, which claims the payload was judged. The host half — WHICH carrier a host populates — must be re-decided per port;
`zensu-codex`, `zensu-kiro` and `zensu-antigravity` carry the same gate against different
harnesses and were deliberately left out of the change that introduced sources 3-4. The
host-neutral half is everything below the resolution: the single `<!-- zensu-autopilot:RUN_ID -->`
marker, run-id equality, the owner and stage checks that precede every read, and the digest.
A port that takes only the module gets the field decision; it still owns its own emission and
its own exit ladder, which stay in `hooks/plan-approved-delegate.sh`.

## Host-Refused Reviewer Spawn (`hooks/lib/reviewer-spawn-denial-v1.js`)

The Stop chain-enforcer demands a `zensu:code-reviewer` spawn. When the HOST
permission layer refuses that spawn, the call never executes — so no PreToolUse
or PostToolUse hook can see it, and without this module the enforcer repeats an
impossible instruction until its cap (`autoFixMaxRounds + 3`) releases the guard.

Ten things are coupled and must move together:

- **`DENIAL_MARKERS` are host literals**, read out of the installed Claude Code
  binary (`DENIAL_MARKERS_SOURCE_BUILD` = 2.1.240: `Permission for this action was
  denied by the Claude Code auto mode classifier.` and `Permission for this action
  has been denied.`). The build is exported and pinned against the module header,
  so the constant cannot drift away from the provenance note beside it. They are
  matched as PREFIXES because the host appends its own `Reason: ...` tail. A host
  that rewords them silently disables the diagnosis — re-verify against the
  binary, never against memory. Re-verified 2026-08-22 with `strings` over
  2.1.237, 2.1.239 and 2.1.240: byte-identical in all three, each stored WITH the
  trailing `Reason: ` the prefix rule declines to contract, and no third
  refusal-result literal exists to add. The same transcript entry also carries a
  host-native `toolDenialKind` beside `message` (observed `automode-blocked`); it
  is deliberately NOT read — an undocumented, unversioned field whose absence
  would be indistinguishable from a clean spawn — and the module header plus a
  unit case record that it was seen and declined rather than missed.
  The `kind` values are re-encoded in exactly TWO
  places outside the module: the `case` arms in `hooks/stop-chain-enforcer.sh`
  that render cause and remedy, and the closed set `reviewerDenialRows` accepts
  from a note. The hook's PROBE deliberately holds no third copy — it reads `kind`
  as a field, so a marker added to the module reaches the doctor under its real
  name with no shell edit, where the old closed set degraded it to the empty
  string and made the doctor render `unclassified` for a refusal both sides could
  already name. Adding a marker still means adding a remedy arm; without one the
  refusal renders unclassified, which is a degraded message rather than a wrong
  one, because the unknown arm is the safe arm. Reading the field is safe only
  while the value stays a `case` SELECTOR: interpolate `REVIEWER_DENIAL_KIND` into
  the reason string and module output becomes operator-visible text.
- **The CLI's one output line is a parsed contract**, not a display string:
  `status=<s> kind=<k> tool=<n> spawns=<n> denials=<n>`. The probe matches
  `status=` in first position, and reads `denials` with `${probe##* denials=}`,
  which requires THAT field to stay last. `kind` is position-independent by
  construction. Separators stay load-bearing throughout: every field is anchored
  on a leading space. The exact-line assertion in
  `tests/structure/reviewer-spawn-denial-v1.test.js` is the pin.
- **The sidecar name is re-encoded in the doctor renderer.** The hook writes
  `.zensu/state/reviewer-spawn-denied-<scv1 session key>.json`;
  `reviewerDenialRows` in `hooks/lib/zensu-doctor-report.js` matches
  `^reviewer-spawn-denied-scv1_[a-f0-9]{64}\.json$`. Rename one and doctor goes
  quiet with everything still green. T25 is the only check that drives both sides
  end to end.
- **`REVIEWER_SUBAGENT_TYPE` has a registered hand-copy, and the doctor also
  reports this refusal PROACTIVELY.** `REVIEWER_AGENT` in
  `hooks/lib/zensu-doctor-report.js` copies it rather than importing it: that
  module is required LAZILY inside `reviewerDenialRows`, so a load failure
  degrades one row, while a top-level require would take the whole report down.
  `DENIAL_RULE` in `stop-chain-enforcer.sh` carries the same identity again — and so
  do five further files. **Do not treat any enumeration of them as complete.** The
  literal lives in EIGHT files under `hooks/` (27 occurrences, measured 2026-08-23 —
  and the grep instruction below is itself one of them, which is why the occurrence
  number moves when this very paragraph is edited and the FILE count does not),
  including two functional comparisons a rename breaks silently:
  `post-review-tdd-delegate.sh`'s `SUBAGENT_TYPE` test and `claude-principal-v1.js`'s
  list entry. A census in prose goes stale the next time a site is added, which is why
  the instruction is a GREP and not a list: **before renaming this identity, run
  `grep -rn 'zensu:code-reviewer' hooks/` and change every site.** ONE pair is
  machine-checked — `test-doctor.sh` P1by pins `REVIEWER_AGENT` against the exporting
  `REVIEWER_SUBAGENT_TYPE`, the pair most likely to diverge because the require is lazy
  and nothing at load time compares them. **The other six files are NOT pinned**, in
  the same sense `WRAP` is unpinned above. Rename the agent in one place only and
  the surviving copies keep telling the user to allow a subagent name nothing
  spawns, with every check green.
  Beside the reactive row, that file's `permissionExposureRows` reads
  `$HOME/.claude/settings.json` — and ONLY that path, for the reason
  §"The model-facing reason names only `~/.claude/settings.json`" below gives — and warns before any spawn is refused.
  Its host literals carry their own provenance constant `SETTINGS_SOURCE_BUILD`:
  `permissions.{defaultMode,allow,deny,ask}`, the `auto` value, `autoMode.allow`,
  the `Agent(<name>)` rule grammar, the file layout — **and the deny -> ask ->
  allow evaluation order**, which is listed separately because its failure mode is
  the opposite of the others': a rename makes the check fall SILENT (useless), a
  REORDER leaves every row rendering and turns the deny row's "adding a
  permissions.allow rule changes nothing" into a false claim. P1bd cross-checks
  the constant against the provenance comment that enumerates them, the way
  `reviewer-spawn-denial-v1.js` cross-checks `DENIAL_MARKERS_SOURCE_BUILD` against
  its module header; P1bd1 pins the order clause. Its rows are held in step with
  `skills/doctor/SKILL.md` by P1be, the same drift pin P1qr applies to the reactive
  rows — `docs/tdd-manager-workflow.md` §"The proactive counterpart, before any
  chain wedges" is the third account and is NOT covered by that pin.
- **Every row that INSTRUCTS a settings edit carries `SELF_PERMISSION_BAR`**, and
  all five call sites consume it — the exposure row, the reactive refused-spawn row,
  the deny row, the ask row and the could-not-judge row. The two that previously
  spelled the sentence inline now consume the constant with their emitted bytes
  unchanged, which is what keeps P1be and P1qr green. A shared constant with an
  unconsumed copy beside it is worse than either honest duplication or one source,
  because it advertises a single source that does not exist; do not reintroduce one.
- **The deny-first caveat sentence is a SIX-member hand-copy class, pinned nowhere
  across its copies.** `DENY_FIRST_CAVEAT` in `hooks/lib/zensu-doctor-report.js`
  is consumed by the ask row and the exposure row; the reactive row in the SAME
  file spells its own lead-in and shares only the trailing clause; `DENIAL_REMEDY`
  in `hooks/stop-chain-enforcer.sh` is a third; `skills/doctor/SKILL.md`'s
  refused-spawn bullet is a fourth; and `unjudgeableRow` in the renderer is a
  FIFTH, which states the same deny-before-allow precedence in its own words and
  deliberately does NOT consume the constant — that row tells the reader to go and
  READ the entry, while `DENY_FIRST_CAVEAT` tells them to REMOVE a deny, so reusing
  it verbatim there would give the wrong instruction. A SIXTH member is the deny row itself,
  which says "Deny is evaluated before ask and allow" and "while it stands, adding a
  permissions.allow rule for this spawn changes nothing" in its own words and consumes only
  `SELF_PERMISSION_BAR`.
  **State the base or the count means nothing.** The six MEMBERS are: the constant itself,
  the reactive row, `DENIAL_REMEDY`, the SKILL.md refused-spawn bullet, `unjudgeableRow`, and
  the deny row. THREE of them carry the trailing clause VERBATIM — the constant, the reactive
  row and `DENIAL_REMEDY` — and a fourth, the SKILL.md bullet, carries its first half verbatim.
  That verbatim sharing is exactly what makes the three `grep -qF` pins possible; a genuine
  paraphrase could not be pinned that way. Only the deny row and `unjudgeableRow` paraphrase it — but the
  deny row is nonetheless PINNED, by its own clause: `P1bv` and `P1bm3` match
  `Deny is evaluated before ask and allow` literally. So five of the six are caught by
  something, and `unjudgeableRow` alone is the copy nothing catches; it is the one to check
  by hand after any reword. The ask row and the exposure row CONSUME the
  constant, which keeps them out of the drift class entirely — consumers, not members. The
  renderer's own comment beside the constant counts the same class as FIVE BESIDES the
  constant, which is the same six; keep both numbers and both bases, and do not "fix" one
  into the other. The criterion needs a real discriminator, not a blanket exclusion: a member
  is a remedy string EMITTED to a user, plus the one skill bullet that STANDS IN for such a
  string — the refused-spawn bullet, which relays the reactive row's remedy in its own words.
  The proactive-row bullets in `skills/doctor/SKILL.md` also restate the precedence and stay
  excluded, but state the test precisely, because two of them DO re-author a sentence: the
  could-not-judge bullet and the unreadable-entry bullet write their own remedy in their own
  words. They are excluded because each accompanies a row whose wording the model is sent to
  read, so a reword of that row is what a maintainer notices; the refused-spawn bullet is a
  member because it stands in for a string the model never sees rendered. `docs/tdd-manager-workflow.md` is
  narrative and outside the class. Without that discriminator the class grows until it stops
  being checkable, which is what an earlier wording of this paragraph did. P1be and P1qr each pin a doctor copy against
  the skill, and the routing suite pins the enforcer copy against itself — nothing
  pins the doctor and the enforcer against each other. Reword one and the others
  go stale with every check green; check them by hand, as with `WRAP` above.
- **That proactive check's PORT half is not this module's.** A port that renames
  only the literals still ships a wrong check: the branch LADDER in
  `permissionExposureLadder` encodes the deny -> ask -> allow precedence, so a host
  that orders them differently needs the ladder reordered, not the strings renamed.
  The wrapper is TWO functions, not one, and a port that copies only the outer name
  ships half of it: `permissionExposureRows` contains the throw so a fault costs one
  row instead of the whole report, and `permissionExposureRowsInner` turns the
  ladder's silence into a statement — the ✅ row when the check ran and found nothing,
  a did-not-run row when `HOME` is unset. The split exists so the row-counting seam
  sits INSIDE the try; collapsing them would put the counter outside the containment. Counting emitted rows rather than threading a flag through
  the ladder's exits is deliberate: a branch added later cannot forget to close itself
  out. A port that copies the ladder without the wrapper ships the silence back.
  A host with no per-user permission-rule file at all DROPS the check rather than
  repointing it — there is nothing to read. The accounts a port also owns are
  `skills/doctor/SKILL.md`'s `⚠️`/`✅ permissions:` bullets and its green-summary bound,
  `docs/tdd-manager-workflow.md` §"The proactive counterpart", and the bullet above.
  P1bh requires every suite that NAMES either doctor file to sandbox HOME or to
  carry an explicit `# zensu-doctor-home-exempt:` sentence — deliberately blunt,
  because its first version tried to recognise an execution and missed the one
  suite that binds the path to a variable and runs it six hundred lines later.
  The renderer reads HOME for both the user-scoped config and the settings file,
  so a suite without one is environment-dependent. P1bi separately requires every
  settings key the ladder reads to be shape-vetted, which is the coupling that
  reopens the original defect if it drifts.
  **The proactive ladder is now decision-then-text, and the two halves must move
  together**: `classifyPermissionExposure` answers WHICH verdicts hold — in emission
  order, as a LIST, so the fact that the auto-mode verdict and the `autoMode.allow`
  verdict can both hold is visible in the return value instead of asserted in prose —
  and `ROW_TEXT` is the only place a row is worded. Adding a row means adding a kind to
  both; neither half can grow a branch the other does not know about. `P1bd2` slices
  `classifyPermissionExposure` (not the ladder) to derive the deny/ask/allow order, so
  moving the decision to another function makes that pin report an underivable order
  rather than passing vacuously.
  **The check has an off-switch, and it is a boolean, never a path override**:
  `hooks.reviewerSpawnPermissionCheck` (default `true`), read from the SAME `cfgReads`
  the Config block already gathered — a second `readJson` pass would double the
  non-blocking opens the FIFO hardening exists for. It suppresses the ROW and can never
  redirect which file is opened, which is what keeps `claudeSettingsFile`'s refusal of a
  `ZDOC_`/`ZENSU_` override intact: that argument is about INJECTION and it still holds,
  while this closes the SUPPRESSION complaint it never answered. **Disabling does not
  produce silence** — it emits one ✅ row naming the flag and saying the check was
  skipped, because silence is the one verdict this check cannot qualify and hiding the
  rows under a config key would reinstate the defect the feature removed. `P1bz`/`P1bz1`
  pin both halves and `P1bz2` pins that a quoted `"false"` does not disable it.
  **The proactive ladder has no unit seam**: this renderer exports nothing and
  ends in `process.exit(0)`, so `settingsShape`, the rule predicates
  (`matchesDenyOrAskRule` and `matchesAllowRule` — deliberately TWO named predicates and
  not one boolean-flag predicate, because the flag named the input while it decided the
  trim behaviour, so no call site said which side of the asymmetry it meant — plus
  `namesReviewerSpawn`, `mentionsReviewerAgent`, `hasUnreadableEntry`), the shared
  `isVerifiedSpelling` test that every exact-match arm consults instead of re-spelling it,
  the combinator `reviewerSpawnMention` over the deny/ask pair, and the
  branch ladder are pinned only behaviorally, by shell fixtures. `reviewerSpawnMention` is
  not a further predicate — it is a reduction over two lists — but it encodes a rule neither
  the predicates nor the ladder carry: `'named'` outranks `'shaped'` ACROSS the deny and ask
  lists, and `namesReviewerSpawn` must scan its whole list rather than return at the first
  match, or the precedence silently becomes positional WITHIN a list. A port that copies
  only the predicates renders the weaker row for a list that really does name the reviewer. Two of those fixtures reach their branch through a `node --require`
  preload rather than through a settings file, because neither a short read nor a
  throw inside the check is producible from file content alone (P1bp, P1bs).
  `settingsShape` returns TWO deferred carriers, not one: each row is suppressed only
  by a malformed key its own claim depends on. Collapsing them back into one carrier
  restores the defect where a malformed `autoMode.allow` deleted the exposure row. Extracting a
  pure classifier into a `*-v1.js` module would buy one, at the cost of a lazy
  require, a degraded-row fixture and a `node --test` driver charged to a named
  Windows shard budget. Deliberately not done; recorded so it is not mistaken for
  an oversight.
- **The unit suite needs a driver.** `tests/run-all.sh` discovers only
  `tests/structure/test-*.sh`, so `tests/structure/reviewer-spawn-denial-v1.test.js`
  is invoked from `test-stop-enforcer-self-review-routing.sh` (T26, which asserts a
  case-count floor because exit 0 also accepts a file registering zero cases). A new
  `*.test.js` with no driver is never executed by the tree runner. That driver
  charges the unit suite's runtime to this shard's Windows budget
  (`tests/profiles/windows-ci.v1.json`, `stop-enforcer-self-review-routing`), where
  a `TIMED_OUT` means the tail of the file never ran. The driver therefore runs
  FIRST in that file, before any scenario: it needs only `PLUGIN_DIR` and
  `STATE_DIR`, and at the tail a timeout cost the whole unit suite — the only
  coverage the scanner's own properties have anywhere.
- **The note is only this plugin's word when a session backs it.** `reviewerDenialRows`
  requires `tdd-phase-<same key>.json` beside the note before counting it. The state
  directory is writable from inside the session, so a note judged purely on its own
  contents would let anything able to write there mint a row telling the user to widen
  `permissions.allow` for the very spawn it wants. Change the workflow-document name and
  the binding silently stops matching; `P1qq` is the pin.
- **One fixture is a real host capture, and it is the only one that can falsify the
  hand-authored envelopes.** `tests/structure/fixtures/reviewer-spawn-denied-transcript.v1.jsonl`
  is a redaction of two entries taken verbatim out of a Claude Code 2.1.237 session whose
  `zensu:code-reviewer` spawns the classifier refused: the `tool_use`/`tool_result` pair,
  `is_error`, the full refusal body and `toolDenialKind` are the original bytes; the
  prompt, ids, cwd and branch are placeholders. Every other transcript in both suites is
  written by this repo and therefore pins only what this repo BELIEVES the host emits.
  Driven at the unit layer (four cases, including a shape guard so a gutted redaction
  fails loudly) and end-to-end by T36/T36a, which sit beside scenario 7 rather than at
  the tail for the Windows-budget reason below. Like
  `fixtures/exitplanmode-posttooluse-payload.v1.json`, it CANNOT observe live harness
  drift — only a fresh capture can.

**The Windows budget for this suite is MEASURED, and the measurement is a RANGE.**
Two green runs of byte-identical suite content reported `stop-enforcer-self-review-routing`
at **985846 ms** and **1274496 ms** — a 29% spread on the same GitHub runner class, so a
single sample here says nothing about headroom. Budget against the HIGH figure: at
`timeoutMs: 1500000` in `tests/profiles/windows-ci.v1.json` the slow run consumes 85% of
its own cap. The previous ceiling of 1200000 sat BELOW that high sample and the suite
was killed by it, which is exactly the failure this range exists to prevent.
**That range no longer covers the file.** Scenario 7b (T36/T36a, the real-host capture)
added a session and a Stop after the range was taken, and the ceiling was NOT raised —
85% of cap was already the slow sample's share. Treat the remaining headroom as
UNMEASURED until a green Windows run reports a new figure; if the shard starts reporting
`TIMED_OUT`, this is the first thing to re-measure, and note that the 1800000 ms shard
budget below would surface such a run as a profile abort rather than a suite timeout.

**The shard budget is the SECOND ceiling, and it binds first.** `windows-shard-7`'s
`profileTimeoutMs` is 1800000 and every profile is pinned to that same value
(`windows-ci-contract.test.js`), which is itself pinned against the job's
`timeout-minutes: 35`. A suite therefore never receives its configured `timeoutMs` — it
receives `profileTimeoutMs` MINUS everything its shard already spent. When
`autopilot-state-machine` (554832 ms) still shared this shard, the routing suite started
with 1138363 ms and died there while its own cap read 1200000 ms, so raising the cap
alone would have changed nothing. Do NOT read a suite's `timeoutMs` as its deadline;
read the shard's remaining budget. Note also that summing a shard's `timeoutMs` values
and comparing that to `profileTimeoutMs` proves nothing — EVERY shard exceeds it by
design, because the per-suite values are individual caps and not a shared budget.

**Three conditions decide a refusal, and no one of them is sufficient.** (1) the
`tool_result` is keyed by `tool_use_id` to an `Agent`/`Task` call whose
`subagent_type` is the reviewer; (2) the host's own `is_error === true`; (3) the
result text STARTS with a marker. Keying alone was the original design and it was
wrong: for an `Agent` call the tool_result body IS the subagent's returned message,
so a reviewer that merely quotes a denial literal — reviewing this module, for
instance — was read as a refusal and the chain was abandoned with a real review in
hand. **It is a diagnostic, never a gate:** an unreadable transcript, an absent
`transcript_path`, or a missing module must leave every existing routing decision
byte-identical, which is what T19 pins.

**The only terminus the denial branch teaches is the zero-change one.** In its
STANDALONE spelling that command verifies its own claim and refuses while any file
is changed, so a chain with real changes cannot be closed there — that would claim a
review that never ran, and the branch says so. The Autopilot-BOUND spelling carries
`--outcome no-changes` into the durable receipt and performs no worktree check at
all; that is pre-existing in `zensu-log.sh` and is restated as a known gap below,
because this branch is what promotes the command to the only exit on offer. It also does NOT disclose the Stop cap count:
a number plus "stop acting" is a wait-it-out recipe. Do not "fix" a wedge here by
teaching an unqualified `--chain-done`.

**The note must never outlive the chain it describes.** Every path that releases
Stop without routing the inner chain retires it, because after such a release this
session's Stop never reaches the routing branches again and nothing else can remove
a note keyed to its session: the three terminal early exits (no active session,
implementation not complete, chain closed), both inner-guard escapes
(`ZENSU_CHAIN=off`, `hooks.chainEnforcer=false`), every release in the Autopilot
escape branch, and the BLOCKED-outer release that owns the current inner
generation — plus the cap path once the chain has converged, and the writing path
itself on a `clear` verdict. Treat that as the rule, not the list: a NEW release
path added above the routing branches needs the same call. T23/T29/T30/T31/T32 pin
the ones reachable from the routing suite. The Autopilot-escape sites need a
durable run, which that suite never builds, so their pins live in
`tests/structure/test-autopilot-stop-enforcer.sh` instead: S14 covers the
terminal-stage escape and S15 the audited one, which are different lines. The
BLOCKED-outer release remains unpinned.
An `errored` verdict retires NOTHING, deliberately: it means the module could not
tell whether the spawn was refused, and clearing on it would delete a correct
diagnosis whenever a retry died of something else.

**A converged chain must never mint a note — and must not inherit one either.**
The self-review branch retires any note first, because a refusal EARLIER in the
same session is stale the moment a spawn succeeds, and that branch never consults
the probe, so nothing below it would clear one. BOTH write sites enforce the
minting half separately. The routing site is guarded by `REVIEWER_DENIAL_ROUTED`, a
flag both arms of the routing ladder set and the self-review branch never does.
Testing the probe's STATUS there instead would test "some branch happened to consult
the probe" — true today only because one branch can, so a probe call added anywhere
above for an unrelated message would silently start minting notes on the converged
path with every check still green. The
cap-release site sits ABOVE that branch and does consult the probe, so it is guarded
by `tdd_code_review_done` by hand: a model that re-spawns the reviewer against the
self-review directive and has THAT refused would otherwise leave doctor reporting
"no review ran" for a chain that had already converged. A session that never Stops
again still cannot clear its own note, so `reviewerDenialRows` ages one out against
the same TTL `pending-review.json` uses — in BOTH directions, since a timestamp in
the future yields a negative age that never crosses the bound. T23/T27/T29 and
P1qg/P1qm/P1qn/P1qo are the pins.

**The TTL suppresses the row; `reviewer_denial_notes_reap` removes the file.** The
clear path sweeps two sets, and it is the ONE place a Stop unlinks a file owned by
another session — which is why the name is matched against the same
character-exact shape the writer asserts, never a prefix.

- **Unbound** — no `tdd-phase-<key>.json` beside it. `reviewerDenialRows` already
  refuses to count these, so removing one destroys no diagnosis anyone reads.
- **Past the TTL** — read from the same config key the doctor ages against
  (`zensu_pending_review_ttl_hours`), and `0` DISABLES it on both sides. This is
  the set that matters: the unbound check alone is nearly inert, because
  SessionStart writes a baseline workflow document for every session, so the
  session whose note outlives it still HAS one. Without the age arm the sweep
  would only ever catch a document somebody deleted by hand.

An unreadable or unparseable note is deliberately NOT reaped. The doctor reports
it as a note this plugin did not write and tells the user to delete it; unlinking
it here would silently destroy a file this plugin does not own. The doctor stays
read-only by contract — the reaping lives in the hook, under the same lease as
every other write to that directory. T35 is the pin, and it plants a LIVE
neighbour alongside the two dead files precisely because a sweep that deleted
every note it could name would satisfy a one-sided check.

**Anything spawned inside the lease must redirect stdin, not only its output.**
The keeper is a bash coprocess and its control channel is a pipe; a child that
inherits those descriptors holds the write end open after the parent closes it,
so the keeper never sees EOF and the release hangs. The reaper's node process
needs `</dev/null` for that reason alone. The failure does not look like a
deadlock from the outside — it surfaces as unrelated checks failing two scenarios
later, because the Stop that held the lease finished in a degraded state. Cheap to
prevent, expensive to diagnose.

**Both halves of the note run under the workflow document's external lease.** It
was the only artifact in `.zensu/state/` written with none, and its two halves are
an unlink and a rename, so a clear could remove a note a concurrent write had just
published. `reviewer_note_locked` wraps both. The lease is an IMPROVEMENT, never a
precondition — on failure the operation still runs unlocked, because failing to
write the note must not change the Stop decision. That fallback is only sound while
both callbacks ALWAYS return 0, which is what makes a non-zero result unambiguously
a lease failure rather than a failed operation; give either one a meaningful exit
status and a failed write starts running twice. The probe runs BEFORE the lease is
taken: it reads a host-supplied transcript with no deadline above it, and holding
this directory's lease across that read would make every other writer wait on it.
The nested clear inside the writer therefore calls the UNLOCKED spelling — the
lease is not reentrant.

**The note path is anchored on `PROJECT_ROOT`, never on `TDD_STATE_DIR`.** That
variable is a retired ambient root the repo pins as non-authoritative, and the only
reader resolves the directory from `CLAUDE_PROJECT_DIR` — honoring an override would
write the note where `/zensu:doctor` never looks and aim an unlink outside the
session-bound directory.

**Both sides of the note treat it as untrusted.** The session can write that
directory, so the writer refuses a symlink, a non-file or a hard link and lands an
`O_EXCL` temp file by rename; the reader decides shape before opening, caps the size,
and counts a note as a refusal ONLY when it parses with `schemaVersion === 1`, a
`kind` the writer itself issues, and a finite timestamp. Anything else is reported as
a note this plugin did not write — never as a refusal, because a planted empty file
would otherwise manufacture a row telling the user to widen permissions. The one
deliberate exception: a plugin root that cannot load the module cannot vet the kind,
and there the row still renders with the kind degraded to `unknown` (P1qf) — losing
the label is acceptable, losing the finding is not.

**The model-facing reason names only `~/.claude/settings.json`.** The project-local
`.claude/settings.local.json` is a path the agent itself can write, and naming it
beside the exact rule that grants the refused capability is an invitation that prose
alone would have to talk it out of. The `/zensu:doctor` row withholds it for the SAME
reason — that row is read by the model too, so "user-facing" does not make it safe.
Only the docs carry the fuller form.

**Operator-facing accounts that must move with the markers, the block reason, and
the note:** the host-refusal paragraph in `docs/tdd-manager-workflow.md`, the
refused-spawn row in `skills/doctor/SKILL.md`, and the `stop-chain-enforcer.sh` row
in `docs/configuration.md`. The PROACTIVE check has three of its own, listed here
so a maintainer navigating by this paragraph reaches them: §"The proactive
counterpart, before any chain wedges" in `docs/tdd-manager-workflow.md`, the
`⚠️`/`✅ permissions:` bullets plus the green-summary bound in `skills/doctor/SKILL.md`,
and the two bullets above.

**Port-relevant.** The PROACTIVE check has its own port half, stated in the two
bullets above and NOT covered by this paragraph: `permissionExposureRows`,
`permissionExposureRowsInner` and `SETTINGS_SOURCE_BUILD` in
`hooks/lib/zensu-doctor-report.js`, the `permissions.*` / `autoMode.allow` grammar,
the `Task` / `Task(` spellings the low-claim predicate admits WITHOUT verification
against `SETTINGS_SOURCE_BUILD`, `reviewerSpawnMention` and its cross-list precedence, the single `~/.claude/settings.json` path, and — the
two a literal-renaming port misses — the branch ladder, which encodes the
deny -> ask -> allow precedence in code rather than in a string, and `FATAL_RULE_KEYS`,
whose membership is DERIVED from that same order, so a port that reorders the ladder and
leaves the constant alone ships a wrong fatal/deferred split.

**The Config block carries its own host-coupled claim, and it is NOT the settings ladder's.**
`readJson`'s three flags — `io`, `cap`, `loaderFallback` — encode facts about THIS host's config
loader, `rd()` in `hooks/lib/zensu-config.sh`: that an open or read error makes it return `{}`,
that it has no size limit, and that it MERGES a global with a project file so a broken overlay
does not fall back to defaults. Two rows state those facts to the user verbatim. A port whose
loader caps size, aborts instead of falling back, or reads a single file would ship both
sentences as false verdicts with every check green — the same failure class
`SETTINGS_SOURCE_BUILD` exists to prevent, one block over. Re-decide the three flags against the
port's own loader, or drop the Config block's loader claims entirely.

**Known gap in the Config block, accepted and recorded.** The `soleSource` axis is present-ness,
not effectiveness: when BOTH default config files exist and both degrade to `{}`, each failure row
says "the other config source still applies" while defaults actually apply. Not a regression — the
predicate that preceded it was wrong in that case too — and self-limiting, because a row prints for
each broken file. Closing it means counting entries that are present AND not `loaderFallback`.
For the REACTIVE module below, every constant here is host-coupled: a port copies
`DENIAL_MARKERS`, `SPAWN_TOOL_NAMES` and the transcript envelope
(`message.content[]`, `tool_use`/`tool_result`, `tool_use_id`, `input.subagent_type`,
`is_error`) into its own file and re-decides them against its harness — a port that
takes only the module inherits Claude Code's literals and will silently never fire.
The host half — which payload field carries the transcript, where the note lives, and
the doctor row — is re-decided per host. `scanTranscript(path, options)` takes
`subagentType` so a host with a different reviewer name needs no fork of the walk.

**Known gaps, accepted and deliberate:**

- **The whole diagnosis is inert on an installation that predates it, and that is the
  first thing to check before suspecting the scanner.** The probe's
  `[ -f "$lib" ] && [ ! -L "$lib" ] || return 0` returns before `node` is ever invoked,
  leaving the verdict `none` and routing byte-identical — the correct fail-open
  direction for a diagnostic, and indistinguishable from "no refusal happened". The
  module first shipped in **v0.18.2**; a session on 0.18.1 or earlier gets the ordinary
  `Resume the /zensu:tdd Phase 6 review sequence` directive on every Stop until the cap
  releases, and `/zensu:doctor` stays silent because no note is ever minted. Measured
  2026-08-22: three classifier-refused `zensu:code-reviewer` spawns, seven Stop
  interceptions, zero notes — and the shipped scanner run against that same transcript
  afterwards answered `status=blocked kind=auto-mode-classifier spawns=3 denials=3`. The
  detection was never wrong; the code was not installed. Nothing surfaces the version
  skew, so diagnose it by checking whether the executing plugin root actually contains
  `hooks/lib/reviewer-spawn-denial-v1.js` before touching the marker set. T36b pins the
  guard and its position ahead of the invocation.
- The verdict has no chain-generation lower bound. After a cap release and a fresh
  `/zensu:tdd`, the newest reviewer result in the transcript is still the old refusal,
  so the branch fires again before any new spawn is attempted. The reason text handles
  it by sanctioning exactly ONE further attempt when the user says they applied the
  rule; a generation bound (an arming ordinal in `options`) is the real fix and is not
  implemented. **Why it is not a cheap fix, measured rather than assumed:** the
  transcript DOES carry a per-entry `timestamp`, but the workflow document carries
  nothing to compare it against. `_tdd_begin_session_critical` writes no history
  entry, and `history[].ts` is optional and stays EMPTY in vanilla mode, where the
  RED/GREEN FSM is never driven — so there is no reliable "when did this generation
  arm" instant to bound the scan with. Supplying one means a new workflow-state
  field, which under the runtime-lineage rule above is a schema change and therefore
  a MINOR release. That price buys the removal of a misroute which is bounded to a
  single Stop and self-corrects as soon as one spawn is attempted, which is exactly
  what the reason text already asks for. Re-decide it when a schema change lands for
  another reason and the field can travel with it.
- The zero-change terminus this branch offers is worktree-verified only in its
  STANDALONE spelling. An Autopilot-bound chain routes `--outcome no-changes` through
  `autopilot_finish_tdd_attempt`, which never reads the worktree. That is pre-existing
  — the untouched ordinary branch offers the same command — but this branch is the one
  that tells the model the spawn cannot succeed, which promotes it to the only exit on
  offer. Closing that gap belongs in `zensu-log.sh`, not here.
- A denial note is keyed to its own session, so no other session can retire it
  through the ordinary clear path. `reviewer_denial_notes_reap` is the deliberate
  exception and the only one: any Stop in that project removes a note that is
  unbound or past the TTL, which is what bounds a note whose session is gone for
  good. The row it would have rendered was already suppressed by the same TTL, so
  the sweep changes which files exist, never which findings are reported.

## Gate-Disable Prefixes (`ZENSU_*=off`) and `test-gauntlet-loop-skill.sh` G12

**Introducing a new `ZENSU_<NAME>=off` escape means editing a skill test in the same
commit.** `tests/structure/test-gauntlet-loop-skill.sh` G12 scans `skills/gauntlet-loop/`
for any gate-disable prefix, because a prompt carrier that teaches one hands the model a
hatch that lands no bypass-ledger entry. A negative scan is only as wide as its
alternation, so G12 builds its pattern from a hardcoded `ESCAPE_STEMS` list, and its
`G12a` arm re-derives the set from `hooks/`, `docs/` and this file and FAILS when the two
disagree.

That makes the coupling run in an unobvious direction: an ordinary change under `docs/`
or `hooks/` that adds — or removes the last occurrence of — such a literal turns a suite
named for the gauntlet-loop skill red, and the remedy is to edit `ESCAPE_STEMS`, not the
file you were working on. The message names both sets so the diagnosis is in the failure
itself, but nothing points at it from the side that changes.

It is not hypothetical. `ZENSU_REQUIREMENTS_GATE=off` arrived with the
plan-requirements completion gate and was caught on the next merge, by exactly this arm.

Two properties worth keeping when touching G12: the derivation carries the same quote
tolerance as the pattern it validates (the gates compare after shell quote removal, so
`ZENSU_CHAIN='off'` disables one at runtime and a bare `=off` derivation is blind to it),
and an EMPTY derivation is a FAIL rather than a skip — a swallowed `grep -r` failure used
to read as agreement while the control block still printed PASS.

## Fixture Mutation Events (`scripts/fixture-mutation-watch.js`)

The promptfoo wrapper attests `tracked_clean` for the immutable eval fixture from TWO
independent signals: a manifest comparison (`scripts/fixture-manifest.js`, also polled every
10 ms) and a filesystem-event marker. **The marker is not redundant** — it is the only thing
that catches a TRANSIENT mutation, written and restored byte-for-byte before the run ends,
which is what `test-claude-promptfoo-wrapper.sh` P13-S6 pins.

**Both watch backends now share ONE decision, `classifyFixtureEvent`.** They did not, and
the divergence was the bug: the per-directory backend gated `.git` behind a manifest delta
while the recursive one (`fs.watch(root, {recursive:true})`, FSEvents on macOS) marked any
path outright. Under load that made the wrapper attest dirty against its own `git init` +
`git add` + `git commit` seeding, which runs BEFORE the watcher starts — P13-S8 failed with
rc=3 on 8 of 8 concurrent runs and 0 of 8 idle. Three further event shapes were measured the
same way and are gated for the same reason: the watched ROOT's own basename (what libuv
reports for an event on the watched directory itself), a directory that CONTAINS a run-owned
subtree (`.zensu`, whose children the wrapper permits the run to write, coalesced upward),
and garbled names FSEvents emits under coalescing (`.git/ä`).

**The gated classes are adjudicated by the MANIFEST; ordinary fixture paths are NOT, and
that split is load-bearing.** A manifest gate on an ordinary path would destroy transient
detection outright — the manifest is equal by definition in exactly that case. Ordinary paths
are separated by the entry's own `ctimeMs`/`mtimeMs` against the watcher's start instead: a
denied write leaves the inode untouched, a restore does not, and an unreadable entry marks
(a deletion is a mutation). Do NOT "simplify" that branch onto `gateOnManifest` — it reads as
one consistent rule and silently removes the feature P13-S6 exists for. The ctime half of the
argument is POSIX only; on Windows that field is the creation time and settable, which is
acceptable solely because the `init_git` path requires `sandbox-exec`/`bwrap` and exits 69
without one.

Moving together: `RUN_OWNED` (the ancestor set is DERIVED from it, never hand-listed),
`EXCLUDED_PATHS` and `gitControlSnapshot` in `fixture-manifest.js` (what a manifest delta can
still see is what makes gating `.git` safe), and the registered-case floor in the shell
driver. `tests/structure/fixture-mutation-watch.test.js` carries the four measured shapes and
pins the single-implementation property at SOURCE level — a rule pin alone cannot catch a
SECOND copy of the rule, which is what the bug was. The suite is local-only
(`tests/profiles/promptfoo-local-only.v1.json`, and in the `excluded` list of
`windows-native-structure.v1.json`), so none of this runs in GitHub Actions.

**Known gap, measured and not closed.** Under the harness that failed 8 of 8 before the fix,
128 runs at a heavier setting produced ONE failure whose cause was not established; 224
instrumented runs at the same setting could not reproduce it. Say "the observed shapes are
closed", never "the watcher cannot false-positive".

## Session Lineage Ledger (`skills/session-trail/scripts/session-lineage-v1.mjs`)

`/zensu:session-trail` records every takeover as one edge in a **machine-wide,
multi-writer** store, and this module is the single source of truth for its schema,
its layout, its refusal table and the chain walk. It is the reason the skill has a
write channel at all — before it, `trail.mjs` had none, and SKILL.md said so.

**The store is a DIRECTORY of one record per edge, never a shared append-only file.**
Six windows write it concurrently and atomic append behaves differently on Windows
than on POSIX; an exclusive `wx` create of a uniquely named record needs no lock and
cannot interleave. `labels.json` is the one exception and lands by O_EXCL temp plus
rename — it is a read-modify-write, so **concurrent labels can still lose an update**;
the rename removes only the torn-file half of the hazard.

**Two identity routes, deliberately independent.** The account comes from the desktop
store, whose top-level directory IS the `accountUuid` (measured 2026-08-21 three ways:
`oauthAccount.accountUuid` in `~/.claude.json`, `lastKnownAccountUuid` in
`Claude/config.json`, and `ant-device-registry.json`'s key set). The window comes from
the process ancestry up to the owning `Claude.app` process. Only the macOS path is
MEASURED; the Windows and Linux candidates are probed and can win — `ccdStoreCandidates`
tries `$XDG_CONFIG_HOME/Claude` and `~/.config/Claude` there — they are UNVERIFIED, not
unreachable. Where no candidate exists the account is `null` and the ancestry still
groups by window. `ZENSU_CCD_STORE` overrides the probe list and is AUTHORITATIVE, and
`lineage --diagnose` prints every candidate with its verdict.

**The edge's `repo` comes from the HANDED-OVER work, never from the recording
process's cwd.** The documented takeover route runs from a window in a different repo,
so deriving it from the recorder filed the edge under the taker's repo and made the
default repo-scoped `lineage` render nothing where the work lives — an empty answer
indistinguishable from "no handover happened".

**Sites that move with the STORE LAYOUT** — anything that re-spells the `v1` segment
or the record shape: the module, `trail.mjs`'s wrappers, the `v1` segment quoted in
`skills/session-trail/SKILL.md`, `tests/structure/session-lineage-v1.test.js`, and the
`v1` path spelled throughout `tests/structure/test-session-trail-lineage.sh`.

**Sites that move with the module's SOURCE SHAPE** — a rename, a reformat, or a new
writer breaks these even when the layout is untouched, and they are the half that is
easy to miss because none of them mentions the schema:

- `tests/structure/test-session-trail-skill.sh` — `write_sites()` hardcodes the four
  writer function names as an awk allowlist (`ledgerWrite`, `writeEdge`,
  `ensureLedgerDir`, `writeLabels`); `T22a` asserts the module mints exactly TWO temp
  families; `T22b` asserts a floor of bare-slice session-id sites in `trail.mjs` AND
  names the `instances` row literally; the guard block pins the `JSON_EMITS` count.
- `tests/structure/test-windows-portability-guards.sh` — pins four exact source lines
  of `readBoundedFile` with `grep -cF`, so reformatting the open/fstat/size lines
  fails that suite.
- `tests/profiles/windows-ci.v1.json`, `windows-native-structure.v1.json`,
  `windows-ci-command-catalog.v1.json` and `promptfoo-local-only.v1.json` each name
  the suite path.
- `tests/structure/windows-ci-contract.test.js` and `windows-profile-contract.test.js`
  hold a suite COUNT and a command digest. Both are easy to merge wrongly: two
  branches that each add one suite both raise the count by one, so git merges it
  cleanly at the wrong value. Recompute the digest from the merged catalog rather
  than taking either side's literal.
- `package.json` — the `session-trail:coverage` script names the suite path.

**Known gaps, accepted and named:**

- **The schema partition outranks the record's own version.** `ledgerPaths` partitions
  the store by `v${LEDGER_SCHEMA_VERSION}` while `classifyEdge` ALSO judges
  `schemaVersion` inside a record. The partition wins — a v2 build reads an empty
  `v2/edges` and reports no history rather than refusing v1 records — so
  `SCHEMA_NEWER`/`SCHEMA_OLDER` are reachable only from a hand-planted record. Closing
  it means either dropping the derived segment or having `readEdges` enumerate sibling
  `v*` directories.
- **`readEdges` caps each record at 256 KiB but not the record COUNT.** The store is
  append-only, has no prune verb, and `cmdInstances` reads it on every call, so growth
  is bounded only by user behaviour. A machine that has run for a year pays that cost
  on every listing.
- **`chainRoots` rebuilds its index per walk.** It calls `walkChain(root, edges)` once
  per root and each call rebuilds `byFrom` from scratch, so the read is quadratic in
  the number of distinct chain roots. Acceptable at the six-window scale this exists
  for; it is the first thing to fix if the store ever grows a prune verb instead.
- **`ensureLedgerDir` checks then creates.** The symlink and non-directory refusals run
  against an `lstat` taken before `mkdirSync`, so a component swapped in between is not
  caught. The sibling `ensurePrivateDirectory` in `review-evidence-lease-v1.js` carries
  three further checks this one deliberately omits; the module header names them. The
  store is per-user and the window is short, which is why it is accepted rather than
  closed.
- **A reused pid renames history in the `windows` label namespace.** Splitting accounts
  from windows stopped the two key kinds colliding; it does nothing about one pid being
  reused by a different process after the first exits. Nothing reaps a `windows` entry,
  and `endpointLabel` resolves a PERSISTED endpoint's `appPid` through the CURRENT
  labels file, so a label assigned today renames a months-old handover whose `appPid`
  matches. It bites hardest where the desktop store is unreachable — there the pid is
  not the fallback route to a name, it is the only one. Qualifying the key with a
  process identity is the fix; it needs a labels-file shape change and is not paid for.
- **The module's name collides with the plugin's existing "runtime lineage" term.**
  `session-lineage-v1.mjs` is about handovers between sessions; §"Runtime Lineage
  (`version_type` is load-bearing)" above is about plugin versions serving a recorded
  session. Nothing shares code between them. The collision is in the reader's head, and
  renaming the module would cost every site in the two lists above.

**`tests/structure/test-session-trail-lineage.sh`'s Windows ceiling is MEASURED.**
It is `timeoutMs: 600000` in `tests/profiles/windows-ci.v1.json` on `windows-shard-3`,
lowered from 900000 once the figure below existed. Reserving 900000 for a suite that
measures 274 s put two 900000 caps on one shard whose whole profile budget is 1800000,
which is what starves the suites scheduled after it; 600000 still leaves 2.2x headroom
over the measurement.
First green-shard measurement, run 32598374524 on `win25-vs2026`: **273905 ms at 70
checks** — 46% of its own cap after that reduction, against **31 s on macOS** (measured 2026-08-22, idle
machine, at 66 checks). Windows is roughly 9x slower here, which is the ratio to
budget new checks against. An earlier note in this section claimed ~4 s on macOS;
that figure predated the suite roughly doubling and was what the 900000 ceiling had
originally been reasoned against.
**The shard budget binds FIRST and is the tighter of the two:** `windows-shard-3`
carries a `profileTimeoutMs` of 1800000, and that same run consumed **1213416 ms**
of it across seven suites — `deferred-reset-races` alone took 584150 ms at the same
900000 cap. The shard now carries EIGHT suites: besides those two, SIX more whose caps
sum to a further 1860000. **Recount this after every merge from `main`**, because that
is exactly how it moves — the figure read five and 1260000 until a merge brought
`autopilot-release-cli` (600000) onto the shard and this sentence was not re-derived.
The eight caps sum to 3360000 against a 1800000 profile, so a suite scheduled late
cannot receive its own ceiling — that is the ordinary state of this shard, not an
anomaly, and it is the same failure §Host-Refused Reviewer Spawn records verbatim
("read the shard's remaining budget", not the suite's `timeoutMs`). It was worse
before: this suite sat at 900000 beside `deferred-reset-races`'s 900000, half the
profile budget committed to two entries. At 1213416 of 1800000 there
is roughly 33% headroom left, and a shard abort truncates the tail of the second
suite silently. The caveat lives here and NOT in the manifest:
`tests/run-profile.js`'s `SUITE_KEYS` rejects any key outside
`{id, runner, path, args, timeoutMs}` and aborts every Windows shard at manifest load.

**Two fixture defects in that suite were invisible on POSIX and cost a whole CI
round**, and both are the MSYS/native split this file already documents for
`bash-source-write-parse.js`. Neither was a product defect — the product is native
on both hosts — but both made real checks fail for a reason unrelated to their
subject:

- **`$$` is not a pid `process.kill(pid, 0)` can see.** Under Git Bash it is an MSYS
  pid from a different namespace, so the shell's own pid never reads as live and
  every liveness-dependent check (`L8b`, `L16`, `L24`) failed on that premise rather
  than on its own. The suite now spawns a detached node helper and takes the pid
  NODE reports, which is in the namespace the product consults on every host, and
  retires it in the EXIT trap. `L0b` is the premise check that named this on the
  first Windows run instead of letting three checks fail opaquely — keep it.
- **A hand-written fixture record must carry the spelling production writes.** `L25`
  interpolated a shell path into an edge record while node's `process.cwd()` reports
  the native one, so repo scoping found nothing. Every path a shell writes into a
  fixture here goes through `hostpath` (`cygpath -m`), the same helper the path
  comparisons already used.

**The suite isolates by `--config-dir` and `$ZENSU_CCD_STORE`, deliberately not by
`$HOME`.** Its sibling `test-session-trail-verdict.sh` redirects HOME and therefore
skips itself whole on Windows, where `os.homedir()` reads `USERPROFILE`. Both suites
also unset `CLAUDE_CONFIG_DIR`, because `trail.mjs` honours it and `$HOME` is only a
fallback — with it exported, a fixture read would resolve against the developer's
real config root and a `takeover` would write a real edge there. In the lineage suite
the unset is BELT, not the mechanism: `--config-dir` already outranks the variable in
`resolveRoots`, and the unset is what keeps that true for a check added later without
the flag. Exactly ONE invocation there omits it — the L10 case, whose whole subject is
that the variable is honoured — and `L28` pins that it stays exactly one, because a
second exemption is indistinguishable from a forgotten `env -u`.

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
