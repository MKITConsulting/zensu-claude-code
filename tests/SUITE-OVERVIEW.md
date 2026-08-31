# zensu-claude-code — Full Test Suite Overview

Static inventory of every test suite in this repository: what exists, what each layer
covers, and how the layers are wired into CI.

Derived by reading `tests/run-all.sh`, `tests/profiles/promptfoo-local-only.v1.json`,
`tests/profiles/windows-ci.v1.json`, `.github/workflows/*.yml`, and each suite's own
source — not from an executed run. Assertion counts are approximations derived from
each suite's `check()` / `run()` / `expect()` call sites.

**The structure-suite count is owned by `tests/profiles/promptfoo-local-only.v1.json`,
not by this file.** `run-all.sh` compares that manifest against the actual directory
listing before any suite runs and refuses to execute at all when they disagree — so a
new suite file and its manifest entry must land in the same commit, or every mode,
including both release jobs, aborts rather than skipping one suite. §1 and §2 below are
reconciled to that manifest (147 = 140 + 7, re-derived from the JSON rather than incremented:
`ciStructureTests` holds 140 entries, `localStructureTests` 7, and `ls tests/structure/test-*.sh`
returns 147). **§3 is NOT fully reconciled to it**, and the residual is stated rather than
asserted away: its eleven CI group headers sum to 139 against 140 CI-classified suites, so one CI
suite appears in no §3 group. `main` recorded that suite as `test-session-trail-lineage.sh`; this
merge did not re-derive the NAME, because §3 lists suites in prose rather than by filename and a
wrong name in a group is worse than none. The gap predates both the plugin-data guard, filed under
§"Bash gates, witness & secrets", and the reviewer-spawn grant, filed under §"Review chain &
findings". §7's profile table was re-derived from `tests/profiles/windows-ci.v1.json` rather than
described, so its eight shard ids and their membership are the JSON's own, and the entry total
is **43**.

**Section 4's own header numeral was DROPPED rather than corrected**, so exactly one place
owns the unit-file count and a header can no longer contradict it. It had said 24 while the
count above said 26; both were then stale again within one merge, because the directory had
moved to 27. The rowless files are enumerated ONCE, in the closing note under section 4's
table — deliberately not repeated here, since a second copy of that list is the drift this
document exists to prevent. Recorded rather than quietly reconciled: an audited count that
disagrees with its own table is the failure shape, and an earlier revision of this very
paragraph said "two files" while naming one, which is the same failure one level down.

**Nothing machine-checks any of this.** The reconciliation above is a hand audit performed
at this commit, not an invariant: the next suite added without touching §3 silently breaks
it again, and no test will say so. Re-derive rather than trust when the numbers matter.

**Windows coverage of `test-artifact-redaction.sh` is deliberately
STRUCTURAL-ONLY.** The suite is in `ciStructureTests`, so POSIX `run-all.sh --ci`
runs it, but it has no entry in `tests/profiles/windows-ci.v1.json` and therefore
never executes on a Windows shard. That is a decision, not an oversight: its
Windows wall clock is unmeasured, every shard is already budgeted against
`profileTimeoutMs`, and a suite receives the shard's REMAINING budget rather than
its own cap — so an unmeasured addition risks killing the tail of a shard rather
than adding coverage. Of the module's three Windows-only code paths, exactly one has a Windows pin:
`platformNoFollow`, in `test-windows-portability-guards.sh`, which IS in the
profile. The `\Users\<seg>` residual rule and the `msysSpelling` inverse are
driven only by the host-independent R11c inside this suite, so on Windows they are
exercised NOWHERE — stated plainly rather than left implied by a broader claim. Re-decide this if a Windows wall clock
is ever measured for the suite.

## 1. Totals

| Layer | Count | Runs where |
|---|---|---|
| `tests/structure/test-*.sh` (deterministic shell) | **146** — 139 CI-blocking + 7 Promptfoo local-only | `run-all.sh` (all modes) |
| *(reconciliation)* | a `--ci` run reports **139 structure suites + 5 offline evals = 144 executed**; the 7 Promptfoo local-only suites are skipped as `LOCAL` and never counted, which is the whole 146 − 139 gap | — |
| `tests/structure/*.test.js` (`node --test` units) | **28 files** | invoked *by* parent `.sh` suites |
| Offline eval suites (`ciOfflineSuites`) | **5** | `run-all.sh` |
| Live `claude --print` E2E suites | **7** | `run-all.sh --live` / `--self-check` |
| Windows contract profiles | **8** (`windows-shard-1`…`-8`, 43 suite entries) | `ci.yml` matrix, `run-profile.js` |
| Windows safety shards | scheduled/manual matrix | `windows-safety.yml` |
| Approx. assertions in structure layer | **~4,200** (~3,740 in the CI set) | — |

## 2. Run modes (`tests/run-all.sh`)

| Mode | Selects | API cost |
|---|---|---|
| *(no arg)* | all 146 structure suites + 5 offline evals | none |
| `--ci` | 139 CI structure suites (7 Promptfoo ones skipped as `LOCAL`) + 5 offline evals with `ciArgs` | none |
| `--self-check` | deterministic + the 7 live suites' skeleton mode | none |
| `--live` | deterministic + 7 live suites with fixture setup | **yes** |

Exit 0 only if `FAIL=0 && HANG=0 && BLOCKED=0`.

Runner-level guarantees (themselves pinned by `test-run-all-preflight-watchdog.sh` and
`test-run-all-required-offline-suites.sh`):

- **Preflight classification gate** — the manifest's `ciStructureTests` ∪
  `localStructureTests` must exactly equal the real directory listing, duplicate-free,
  and every `ciOfflineSuites` path must exist. Otherwise the run refuses to start.
  A new structure test that nobody classified fails the run rather than being skipped.
- **Per-suite watchdog** — `ZENSU_SUITE_TIMEOUT` (default 3600 s), portable pid poll
  (no GNU `timeout` on macOS). A suite that never returns is reported `HANG`, not `FAIL`.
- **Output to a file, never a command substitution** — so a suite leaving a background
  child alive cannot silently wedge the whole runner.
- **`BLOCK` state** — suites needing npm devDependencies (`node_modules` absent) are
  reported as *blocked, not run*, and still fail the overall result. No silent skip.
- **Offline inventory count check** — executed suite count must equal the manifest count.

## 3. Deterministic structure suites — grouped by what they cover

### Session Control & workflow state (14)
`orphaned-project-root` · `session-control-claude` · `session-control-core` ·
`session-control-sandbox-hook-integration` · `session-id-v1` ·
`session-start-banner` · `state-verb-diagnostics` · `tdd-log-path-anchor` ·
`tdd-no-flock-external-lease` · `tdd-state-corruption-fail-closed` ·
`tdd-state-path-safety` · `versioned-plugin-upgrade` · `workflow-scope` ·
`zensu-runtime-controller`

Covers the canonical CAS workflow document, immutable session binding, the shared
Bash-3.2-compatible external process lease, symlinked-ancestor / non-regular-leaf
rejection, fail-closed behavior on an unreadable state file, diagnostics on failed
state verbs, and the SessionStart banner. `session-control-claude` alone carries ~140
assertions.

### TDD engine & phase gate (17)
`edit-landing-audit` · `evidence-discipline` · `impl-stop-counter` ·
`pre-edit-hook-mirror` ·
`pretool-config-prompts` · `requirements-table-gate` ·
`smoke-main-thread-chain` · `tdd-begin-chain-reset` ·
`tdd-complete-receipt-gate` · `tdd-full-cycle` · `tdd-manager-patches` ·
`tdd-mode-toggle` · `tdd-protocol-prominence` · `tdd-reminder-hook` ·
`tdd-skill-review-fanout` ·
`tdd-skill-self-review-handoff` · `tdd-vanilla-mode`

Covers arming (`--tdd-begin`), the PreToolUse edit phase-gate, the RED→GREEN→IMPL
lifecycle walked hermetically end to end (`tdd-full-cycle`), vanilla mode
(`hooks.tddImplementation=false` — no RED/GREEN ceremony but audits + review chain
retained), the mode precedence at the freeze point (`tdd-mode-toggle` — session
choice > `--tdd-mode` caller default > config > vanilla, plus the fail-safe that an
unreadable marker forces nothing), the two preconditions `--tdd-complete` refuses on —
the edit-landing receipt and the plan's `## Requirements` table that `/zensu:converge`
anchors on — and the 5-agent review fan-out wiring in `skills/tdd/SKILL.md`.

### Review chain & findings (27)
`chain-recover` · `chain-terminus-zero-change-gate` · `deferred-review-claim` ·
`deferred-review-fallback` · `evidence-crosscheck` · `finding-verification` ·
`pending-review-ttl` ·
`post-review-autopilot-claim` · `post-review-outer-ownership-root` ·
`post-review-self-review-handoff` · `post-review-tdd-scope` · `reset-review-limit-skill` ·
`reset-review-limit-transaction` · `review-aspect-agent` · `review-judge` ·
`review-personas` · `review-worker-evidence-lease` · `reviewer-capability-gate` ·
`reviewer-readonly-v1` · `reviewer-spawn-allow` · `self-review-flags` · `self-review-markers` · `self-review-skill` ·
`stop-enforcer-escapes` · `stop-enforcer-self-review-routing` ·
`stop-enforcer-subagent-noop` · `stop-session-binding-recovery`

The largest group. Covers the Stop-hook chain enforcer and its two-stage routing
(code-reviewer → self-review), its escape hatches and anti-deadlock budget cap, the
spawned-agent no-op, the read-only reviewer capability confinement, the finding
verification gate (findings graded against real source before they route), the
one-shot review ticket CAS and budget rearm, deferred/pending review markers plus
their TTL, `--chain-status` / `--chain-recover`, and the zero-file-change gate on the
unqualified chain terminus.

### Autopilot (16)
`autopilot-adversarial-recovery` · `autopilot-bound-payload-windows` ·
`autopilot-chain-integration` · `autopilot-delegated-skill-contract` ·
`autopilot-durable-skill` · `autopilot-full-cycle` · `autopilot-id-and-start-boundaries` ·
`autopilot-inner-termination` · `autopilot-plan-delegate` ·
`autopilot-post-review-max-rounds` · `autopilot-release-cli` · `autopilot-review-rearm` ·
`autopilot-session-resume` · `autopilot-skill` · `autopilot-state-machine` ·
`autopilot-stop-enforcer`

Covers the durable outer state machine (schema, transitions, idempotency, storage —
~132 assertions), inner-TDD ↔ outer-Autopilot linkage and crash reconciliation,
generation- and ticket-bound termination, the single planning gate, review-budget
rearm/retirement, the read-only SessionStart resume hook, and a composed full-lifecycle
walk.

### Bash gates, witness & secrets (9)
`artifact-redaction` · `bash-source-write-gate` · `bash-zensu-gate` · `bypass-ledger` ·
`plugin-data-guard` · `post-bash-witness` · `secret-scan-gate` · `skill-workflow-markers` ·
`witness-scenario-assertions`

Covers the PreToolUse(Bash) source-write gate incl. rule (C) git-repo escape
(183 probe cases + a 30-case pure unit suite), the `zensu <noun> <verb>` write gate,
the bypass ledger (gate escapes only — ~100 assertions), the post-Bash witness log
(anti-hallucination trail), the build-time guard that a skill never runs a zensu
mutation without `--workflow-begin` / `--workflow-end` markers, the secret-scan gate, the
plugin-data containment gate (117 checks; floors at the measured counts — `EXPECTED_CHECKS=114` registered, an executed-row floor of 102 tolerating all twelve skippable rows, and a POSIX host that fails on any skip representing LOST coverage: the store denied in all
three chain states with an in-project allow control each and an armed-state premise, all four
write tool names, the anchored-containment and relative-target bites, the symlink family — a
symlinked directory, a dangling leaf, and `..` after a symlink into the store, each with a
control in the other direction — a case-variant store prefix, a two-hop symlink, the deny-reason
and no-escape assertions, a payload-declared non-main principal whose premise consults
`claude-principal-v1.js` itself, a second-path-field row, six faults covered — four asserting their own reason literal and two asserting the documented
silence, the exit-2 plugin-root refusal, two source-absence checks with controls, and a
two-group matcher shape compared against the module's exported tool set), and the writer-side
redaction that keeps `.zensu/plans` and `.zensu/logs` artifacts free of
absolute developer paths (~100 assertions).

### Skill contracts (20)
`converge-skill` · `cover-skill` · `doc-generation-guidance` · `docs-skill` · `doctor` ·
`gauntlet-loop-skill` · `ghost-scan-test-detection` · `pilot-skill` · `plan-requirement-ids` · `plan-review-skill` ·
`pr-fix-findings-skill` · `pr-team-review-skill` · `session-trail-skill` ·
`session-trail-verdict` · `setup-skill` · `skill-overlays` · `templates` ·
`verify-feature-skill` · `zen-mode` · `zensu-help-skill`

Structural pins on each shipped skill's SKILL.md: required phases, marker wiring,
persona pools, stable AC-###/FR-### requirement IDs, overlays, and cross-file version
consistency. Heaviest: `pr-team-review-skill` (~121), `verify-feature-skill` (~117).

`session-trail-verdict` is the one BEHAVIOURAL suite in this group: it builds synthetic
transcripts under a synthetic `HOME` and asserts what `trail.mjs` actually decides about
taking a session over, which its structural sibling can only pin as vocabulary. It skips
loudly where `os.homedir()` does not follow `$HOME`, rather than reporting against the
developer's real sessions.

### Prompt routing & payloads (7)
`agent-context` · `best-solution-first` · `context-nudge-hook` ·
`intent-router-hook` · `plan-approved-delegate` · `plan-payload-fallback` ·
`zensu-plm-arg-guidance`

Covers the trusted-payload principal / event discriminator, the UserPromptSubmit
context-occupancy nudge, the intent router, and how the PostToolUse(ExitPlanMode)
delegate reads the approved plan (with a distinct receipt for each failure mode).

### VCS / forge integration (7)
`valid-diff-lines` · `vcs-detect` · `vcs-pr-ops` · `vcs-publish` · `vcs-reconcile` ·
`vcs-review-marker-reconcile` · `workflow-checkout-credentials`

GitHub/GitLab provider detection, PR/MR operations, review publishing, marker
reconciliation (~107), commentable-diff-line validation, credential handling.
`workflow-checkout-credentials` needs `node_modules` → `BLOCK` without `npm ci`.

### Release & repo hygiene (14)
`changelog-unreleased-resolver-entries` · `drift-assertion-or-logic` · `drift-audit-regex` ·
`file-exists-replacement` · `gitignore-zensu` · `immutable-marketplace-release` ·
`promptfoo-config-refs` · `promptfoo-local-only` · `readme-hook-count-sync` ·
`release-session-control-gate` · `run-all-preflight-watchdog` ·
`run-all-required-offline-suites` · `run-all-sharding` · `version-sync`

Enforces the `plugin.json` ↔ marketplace version ↔ marketplace `ref` ↔ README badge
invariant, the immutable-tag release rule, CHANGELOG coverage, that Promptfoo configs
only reference existing files, that Promptfoo stays local-only, and the runner's own
contract.

### Windows & portability (4)
`msys-runtime-boundaries` · `msys-special-plugin-module-boundaries` ·
`windows-ci-contract` · `windows-portability-guards`

Git-Bash/MSYS path translation boundaries, native-Node module loading from a plugin
root containing whitespace and an apostrophe, the Windows CI manifest contract, and — in
`test-windows-portability-guards.sh` — the per-file secure-open inventory plus the
marker-block-carrier contract that binds the two rule-injecting hooks to one reader, one `MAX_FILE` and one
`MAX_BLOCK`. Those three read the two hook files and sit directly beneath the per-file
secure-open pins, so the adjacency is real. A FOURTH arm in the same suite compares the two
suites' declared `REVIEW_HEADROOM` — it reads no hook and nothing platform-related, so it is a
policy invariant lodged here rather than an extension of the reader contract. The Windows-PR
constraint recorded below does NOT bind it: it has no platform dimension, so POSIX `run-all.sh`
plus the weekly Windows Safety shard cover it wherever it lives. Relocating it is an open item
WITH A CONSTRAINT: `test-evidence-discipline.sh` is the natural semantic owner but is absent
from `windows-ci.v1.json`, so moving the contract there would silently drop it from the
Windows PR shard — the exact regression the check's own comment records as having happened
once. `test-best-solution-first.sh` (windows-shard-4) is the only destination that preserves
that coverage as-is; anything else has to add the suite to `windows-ci.v1.json` in the same
commit.


### Documentation pins (4)
`multi-repo-doc-citations` · `multi-repo-doc-consistency` ·
`multi-repo-doc-contrast` · `multi-repo-doc-structure`

The three hand-written multi-repo design documents under `docs/` have no build step and
are never rendered in CI, so these four suites are the only thing that grades them:
`path:line` citations resolve to a substantive line, WCAG contrast holds across all three
palettes on both pages, the pages carry landmarks, resolved ARIA references and no
unresolvable `var()` in an SVG presentation attribute, and the three documents agree with
each other on counts, terminology, navigation and the specification's BLOCKED status.

### Promptfoo local-only (7 — skipped under `--ci`)
`claude-promptfoo-wrapper` (~101) · `promptfoo-concurrency` · `promptfoo-context-nudge-reaction` ·
`promptfoo-reset-review-limit` · `promptfoo-session-upgrade` (~206) ·
`promptfoo-verify-feature` · `promptfoo-zen-mode`

Structure gates for the Promptfoo harnesses. GitHub Actions never invokes the Promptfoo
binary; these guard the local harness contract.

## 4. `node --test` unit suites

Not run standalone — each is driven by a parent shell suite, so a JS failure surfaces as
that suite's failure.

| Unit file | Blocks | Driven by | Covers |
|---|---|---|---|
| `git-repo-escape.test.js` | 30 | `test-bash-source-write-gate.sh` | pure half of source-write rule (C): `gitTargets()` repo resolution + git mutation/option lattice |
| `evidence-crosscheck-v1.test.js` | 32 | `test-evidence-crosscheck.sh` | witness cross-check of claimed test evidence |
| `finding-verify-v1.test.js` | 26 | `test-finding-verification.sh` | finding-verification grading module |
| `profile-runner.test.js` | 23 | Windows profile suite | `run-profile.js` lifecycle, digests, deadlines |
| `chain-recovery-v1.test.js` | 21 | `test-chain-recover.sh` | chain shape lattice + rearm-receipt predicate |
| `plugin-data-guard-v1.test.js` | 37 | `test-plugin-data-guard.sh` (G38) | plugin-data containment: the separator class both ways, both resolution bounds, the truncated-walk refusal, the filesystem-root and containing-store arms, the containment export-shape arm via a copied module beside a stub parser, the cwd ranking, and the realpath fast path over targets that exist |
| `reviewer-spawn-denial-v1.test.js` | 29 | `test-stop-enforcer-self-review-routing.sh` | host-refused reviewer spawn: structural `tool_use_id` keying, the host error flag, the marker prefix, tail/line bounds, degrade-to-none |
| `plan-payload-v1.test.js` | 20 | `test-plan-payload-fallback.sh` | plan-source precedence table, hardened plan-file reader refusals, O_NOFOLLOW-unavailable fallback |
| `zensu-doctor-invocation.test.js` | 24 | `test-versioned-plugin-upgrade.sh` | `/zensu:doctor` invocation allowlist — driven from that suite, which binds it as `RECOGNIZER_UNIT` and grades it against a registered-case floor; it has no `run-all.sh` entry of its own, because discovery is `test-*.sh` only |
| `playwright-mcp-proxy.test.js` | 16 | `test-verify-feature-skill.sh` | pinned Playwright MCP proxy |
| `zen-anchor-assertions.test.js` | 7 | `test-zen-mode.sh` (Z29) | zen-mode eval GRADERS: every javascript assertion body compiled, and a pinned pass/fail vector for the two anchor scenarios plus the safety carve-out |
| `verify-feature-transcript-check.test.js` | 14 | `test-promptfoo-verify-feature.sh` | transcript assertion contract |
| `fixture-mutation-watch.test.js` | 19 | `test-claude-promptfoo-wrapper.sh` | fixture-event classification: the gated classes (`.git`, the watch root's own name, run-owned ancestors) adjudicated by the manifest, ordinary paths by touch-after-start, and that both watch backends route through one decision spelled once |
| `session-control-lineage.test.js` | 13 | `test-versioned-plugin-upgrade.sh` | runtime-lineage axis: same-major (same-minor while major is `0`), never-backwards, sibling plugin root |
| `deferred-review-claim-cases.test.js` | 11 | `test-deferred-review-claim.sh` | deferred-claim case table |
| `windows-ci-contract.test.js` | 11 | `test-windows-ci-contract.sh` | Windows CI manifest invariants |
| `windows-observation.test.js` | 11 | Windows safety | observation summarizer |
| `claude-stream-render.test.js` | 6 | `test-claude-promptfoo-wrapper.sh` | stream renderer |
| `windows-safety-shard.test.js` | 5 | Windows safety | shard partitioning (no duplication or loss) |
| `windows-profile-contract.test.js` | 4 | Windows profiles | profile contract |
| `process-supervisor.test.js` | 3 | wrapper / profile suites | bounded supervisor + process-tree teardown |
| `owned-process.test.js` | 2 | `test-claude-promptfoo-wrapper.sh` | owned-process lifecycle |
| `reviewer-spawn-allow-v1.test.js` | 18 | `test-reviewer-spawn-allow.sh` | the reviewer-spawn grant's derived agent set, its silence on every non-grant path, and the one-definition scan |

Five further files — `review-evidence-sweep-v1.test.js`, `rule-block-v1.test.js`,
`session-lineage-v1.test.js`, `worktree-advice-v1.test.js` and
`session-adopt-report-v1.test.js` — exist on disk without a row here. For FOUR of them that drift predates the reviewer-spawn
grant; `worktree-advice-v1.test.js` is different and the distinction is worth keeping —
it was added by the session-trail takeover-destination change and left rowless
deliberately, because SUITE-OVERVIEW.md itself is graded by no suite and a row here would
be one more hand-maintained copy of a count nothing checks. The unit file IS driven — by
`test-session-trail-verdict.sh`, which pins its case count exactly — so it is rowless
here, not ungraded there. Both are recorded rather than silently
absorbed. The inventory row above no longer carries a unit-file numeral at all, for the
same reason this paragraph gives: it was a hand-maintained count nothing grades, and it
went stale on its next merge.

Plus `tests/session-control/session-control-core-v1.test.js` — the Session Control core
unit suite, reached via `tests/session-control/run.sh`, which is invoked **only** by the
Windows profiles / legacy canary, **not** by `run-all.sh`.
`tests/session-control/initialize-baseline.sh` is a shared fixture helper sourced by
~8 autopilot / chain structure suites.

## 5. Offline eval suites (deterministic, in `run-all.sh`)

| Label | Path | Args (CI) | npm deps | Covers |
|---|---|---|---|---|
| `evals/config-gate (--self-check)` | `evals/config-gate/run-eval.sh` | `--self-check` | no | **54 sub-scripts**: pre-edit TDD gate matrix, auto-fix rounds (increment / convergence / reset / sanitize / session-isolation), suggestions routing on/off, config merge + helper resolution (missing / malformed / env-override / no-node), log-style rendering, plan / session / post-review gates, symlink rejection, path boundaries, README + CHANGELOG coverage |
| `evals/session-control (self-check)` | `evals/session-control/run-self-check.sh` | `--ci` | **yes** | credential-free contract, attestation, barrier, provenance, deterministic wrapper selftests; `--ci` skips Promptfoo |
| `evals/tdd-review-chain (self-check)` | `evals/tdd-review-chain/run-self-check.sh` | — | no | agent / config / version / changelog asserts, severity routing, TDD-log compliance, `.exp` expect scripts |
| `evals/reset-review-limit (self-check)` | `evals/reset-review-limit/run-self-check.sh` | `--ci` | **yes** | sealed-evidence CAS / security scenarios; `--ci` skips Promptfoo |
| `evals/tdd-manager-pretool (--self-check)` | `evals/tdd-manager-pretool/run-eval.sh` | `--self-check` | no | PreToolUse baselines / regression |

Eval directories **not** wired into `run-all.sh`: `evals/verify-feature` (advisory live
Promptfoo, needs a disposable host, deliberately excluded from `--live`),
`evals/context-nudge-reaction`, `evals/zen-mode-reaction`, `evals/plan-approval-hook`.

## 6. Live E2E suites (7 — `--live` costs API credits)

All support `--self-check` (skeleton, no API); most support `--offline` (re-assert the
last capture without re-spending).

| Suite | Covers | Assertion style |
|---|---|---|
| `tests/e2e` | `code-reviewer` anti-loop guardrails | 5 pattern files: `clean-pr`, `build-fails`, `docs-only`, `false-test-claim`, `stale-branch` |
| `tests/e2e-plm` | `zensu-plm` agent workflow + tool sequencing | 7 prompt/pattern pairs: `bootstrap`, `ghost-scan`, `implement`, `security-review`, `status-transition`, `pulse-session`, `feature-id-guard` |
| `tests/e2e-skills` | skills + reviewer agents | 6 pattern files: `zensu-help`, `plan-review`, `self-review`, `converge`, `review-aspect`, `review-judge` (last two also as `.agent` prompts) |
| `tests/e2e-tdd` | **heaviest** — full `/zensu:tdd` cycle | asserts post-run *state*, not stdout: `chainDone=true`, FSM history has `RED_FAIL` + `GREEN_PASS`/`IMPL`, real `node --test` passes in the fixture, witness log recorded the run. Default timeout 1200 s |
| `tests/e2e-context-nudge` | `user-prompt-context-nudge.sh` against a **real** session transcript | read → occupancy → threshold → `/compact` proposal; fail-open contract |
| `tests/e2e-intent-router` | `user-prompt-intent-router.sh` on a planning fixture | timeout 180 s |
| `tests/e2e-source-write-gate` | PreToolUse(Bash) source-write gate, 3 layers | `--self-check` structural / `--offline` real PreToolUse payloads against a throwaway git project / full live block check |

Live-runner hermeticity: the runners prepend a *normal-mode* directive so a personal
output-style plugin cannot compress the headings the patterns assert (override via
`ZENSU_E2E_NORMAL_PREAMBLE`). Pattern files are tolerant regex — `!` prefix = negative
assert, `# ` = comment.

## 7. Windows contract profiles (`tests/profiles/windows-ci.v1.json`)

8 bounded profiles, 43 suite entries, run as a blocking PR matrix in `ci.yml` via
`node tests/run-profile.js <profile>`. The table below is re-derived from the JSON rather
than described — the previous five-profile layout (`windows-reset-session`,
`windows-leases-routing`, `windows-native-state`, `windows-installed-core`,
`windows-native-branches`) no longer exists under any of those names.
The reviewer-spawn-allow suite is deliberately NOT among them — see CLAUDE.md §"Reviewer-Spawn
Grant", known gaps.
`tests/structure/windows-ci-contract.test.js` pins exactly these eight keys and the
43-entry total, so a shard renamed there and not here is drift this table cannot catch
on its own:

| Profile | Suites | Members |
|---|---|---|
| `windows-shard-1` | 9 | autopilot-bound-payload-windows, autopilot-state-machine, deferred-lease-refresh, deferred-review-fallback, installed-plugin-provisioner, tdd-no-flock-external-lease, upgrade-linux-sandbox-host-paths, windows-ci-metadata-contract, workflow-checkout-credentials |
| `windows-shard-2` | 8 | installed-wrapper, msys-runtime-boundaries, pre-edit-hook-mirror, reviewer-capability-gate, runtime-fixture-installer-concurrency, session-control-core, upgrade-hook-large-identity, versioned-plugin-upgrade |
| `windows-shard-3` | 7 | autopilot-release-cli, deferred-reset-races, file-exists-path-transport, msys-special-plugin-module-boundaries, session-start-banner, vcs-review-marker-reconcile, windows-profile-lifecycle-contract |
| `windows-shard-4` | 4 | best-solution-first, deferred-claim-adoption, plan-payload-path-transport, tdd-state-junction-safety |
| `windows-shard-5` | 7 | autopilot-plan-delegate, coverage-report-windows-paths, post-review-self-review-handoff, session-id-v1, session-safe-file-read, upgrade-provider-zero-launch, windows-portability-guards |
| `windows-shard-6` | 5 | bash-source-write-gate, deferred-transfer-reset, marketplace-fixture, session-control-claude, upgrade-process-windows-boundaries |
| `windows-shard-7` | 2 | review-worker-evidence-lease, stop-enforcer-self-review-routing |
| `windows-shard-8` | 1 | session-trail-lineage |

Runner guarantees: full manifest + audited command catalog validated before any child
starts; every suite bound to a validated content digest; per-suite **and** 30-minute
per-profile deadlines; a supervisor alive until the whole process tree is dead;
disposable home/temp tree; strict env allowlist (no credentials, auth homes,
interpreter preloads, or live/API modes).

The aggregate check `Deterministic suite (windows-latest)` downloads exactly those 8
reports and validates SHA / run-attempt consistency, the exact ordered suite inventory,
and a complete execution-contract digest binding manifest + catalog + runner +
supervisor + Job-Object helper + summarizer + workflow config + every referenced suite
file. Fails closed on missing, failed, timed-out, or incompletely-cleaned profiles.

## 8. CI wiring

| Workflow | Invokes |
|---|---|
| `ci.yml` | `bash tests/run-all.sh --ci` (Ubuntu, blocking) + the 8 Windows profiles via `run-profile.js` |
| `release.yml` | `bash tests/run-all.sh --ci` **twice** — once in `prepare` against the local release commit, once in `publish` against the exact `github.sha`; plus runtime-digest and clean-tree evidence |
| `windows-safety.yml` | `node tests/run-windows-safety-shard.js <kind> <shard> <total>` — scheduled weekly + manual; partitions the former Windows monolith (legacy canary + every non-Promptfoo structure test + all 3 offline eval runners) without duplication or loss, 30-minute command deadline |

The Promptfoo binary, live/model wrappers, and nightly and release Promptfoo profiles are
**never** invoked by GitHub Actions — local-only by design, machine-enforced by
`test-promptfoo-local-only.sh`.

## 9. Known gaps and caveats

- `tests/session-control/run.sh` (Session Control core unit suite) is **not** in
  `run-all.sh` — only in the Windows profiles and the legacy canary.
- 4 eval directories are not wired into any `run-all.sh` mode
  (`verify-feature`, `context-nudge-reaction`, `zen-mode-reaction`, `plan-approval-hook`).
- 2 offline eval self-checks (`session-control`, `reset-review-limit`) plus
  `test-workflow-checkout-credentials.sh` need `npm ci`; without `node_modules` they
  report `BLOCK` and the run is not green.
- The promptfoo/expect harnesses under `evals/tdd-manager/`, `evals/tdd-manager-pretool/`,
  and `evals/tdd-review-chain/` still target the pre-0.4.0 `zensu:tdd-manager` subagent
  that was removed when TDD moved to the main thread. Rewriting them to the main-thread
  `/zensu:tdd` model is pending (also noted in `tests/README.md`).

## 10. Maintaining this document

A new suite must be classified in `tests/profiles/promptfoo-local-only.v1.json` or the
preflight gate fails the whole run — that gate, not this file, is the enforcement point.
This overview is descriptive: update the group lists and totals in §1/§3 when suites are
added or removed.

## Suite-prologue re-entry guard (cross-suite convention)

`test-evidence-discipline.sh`,
`test-best-solution-first.sh` and `test-windows-portability-guards.sh` each set
`ZENSU_SUITE_PROLOGUE_ENTERED` and refuse a second pass through their own prologue. A suite
file containing a spliced copy of itself otherwise resets `PASS`/`FAIL` and reports a
plausible total; that happened for real. It is a three-way hand copy in the three suites this
convention started in — every other `tests/structure/test-*.sh` is still unguarded. Adopting
it corpus-wide is an open item; at a fourth adopter, hoist the block into a sourced helper
instead of taking another copy.
