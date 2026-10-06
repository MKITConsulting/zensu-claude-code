# zensu-claude-code Repo Conventions

This file holds only the rules that apply to every change in this repository.
Subsystem notes live in `.claude/rules/`, one file per subsystem. Each rule file
declares `paths:` frontmatter, so Claude Code loads it only when a matching file is
read. When a task touches a subsystem without opening its files, open the rule file
from the index at the end of this file.

A pointer elsewhere in the tree that reads `CLAUDE.md §"<title>"` refers to the rule
file listed under that title in the index.

## Keeping This File Small

- Keep this file under 200 lines. Put subsystem knowledge into the matching rule
  file under `.claude/rules/`, or add a new rule file with `paths:` frontmatter.
  A rule file without `paths:` loads into every session, so never omit it.
- Record decisions, bounds and coupled sites. Do not record review-round history or
  corrections of earlier wordings: `git log` holds that.
- Never add a test that reads `CLAUDE.md` or a file under `.claude/rules/`. They are
  guidance for agents, not a contract. Pin behavior in code and in `docs/`.

## Language

**English only.** All code, comments, docs, commit messages, plan files, prompts,
fixture content and pattern alternations must be in English, and so must every
artifact the plugin emits. Consuming repositories commit `.zensu/plans/` and
`.zensu/logs/` and may publish them.

Two narrow carve-outs admit non-English text, and only as match literals: verbatim
user-utterance literals in hook directives (for example `'kein tdd'`), and eval
grader alternations matched against model prose whose language the product does not
control. Details: `.claude/rules/language.md`.

## Version Bumps

**Every plugin version bump MUST update `.claude-plugin/plugin.json`, the
marketplace version, AND the marketplace source `ref` in the same commit.**

The two files serve different consumers:

- `.claude-plugin/plugin.json` — manifest read by claude-code when loading the installed plugin. Defines runtime agents/skills/hooks/mcpServers.
- `.claude-plugin/marketplace.json` — catalog read by `claude plugin marketplace update <name>`. Its Zensu entry uses the official GitHub source object for `MKITConsulting/zensu-claude-code` and an immutable `v<plugin version>` ref. Both `.plugins[0].version` and `.plugins[0].source.ref` must match `plugin.json`; a mutable branch source is forbidden.

Historical: `marketplace.json` was created at `0.2.0` (commit `a0a58b2`) and never re-bumped while `plugin.json` advanced through 0.2.x → 0.3.x. Result: every release between 0.2.0 and 0.3.15 was invisible to the directory marketplace and users running `claude plugin install zensu@zensu` could not pull the new code without uninstalling + manually clearing the cache directory. Fixed in PR #31; this convention prevents recurrence.

**Releasing — automated via the `Release` workflow** (`.github/workflows/release.yml`):

1. Actions → **Release** → run with a `version_type` (`patch`/`minor`/`major`). The `prepare-commit` job computes the next version from the latest `vX.Y.Z` tag, bumps `plugin.json` + marketplace version + marketplace `ref` + the README badge **together**, and generates a `## [X.Y.Z]` CHANGELOG section from the conventional commits since the last tag (git-cliff, `cliff.toml`). For a real run `prepare-commit` creates the `release/vX.Y.Z` commit locally and hands it on as a git bundle, `prepare-suite` runs `bash tests/run-all.sh --ci` **against that exact commit** as five parallel `--shard=I/N` legs — the suite gates the tree that actually ships, never a pre-bump tree nobody releases — and `prepare` verifies the exact clean commit SHA plus the Session Control runtime digest, uploads deterministic SHA-bound evidence, and **only then pushes the branch** and prints a "Compare & PR" link. The suite runs sharded, like the PR pipeline, because one serial run outgrew the jobs' 120-minute limit: release runs 36348615675 and 37293682279 were cancelled there. Promptfoo and live-model suites are local-only and are never invoked by GitHub Actions. `dry_run: true` remains an offline version/notes preview: it creates no commit, uploads no release evidence, and pushes nothing.

   **`skip_test_gate: true` ships WITHOUT the suite, and is the one input that removes a guarantee rather than adding one.** It refuses a `skip_reason` that is empty, spans more than one line, or starts or ends with whitespace, in `prepare-commit` and in a `publish`-mode retry's `publish-plan` alike, because the reason travels as one `Release-Test-Gate-Reason:` line that `publish-plan` reads back verbatim; a push-triggered `publish-plan` in turn refuses a release commit that carries the skip trailer without a reason, while a `publish`-mode retry ignores such a trailer with a notice and lets its own `skip_test_gate` decide; when a retry dispatches a reason other than the commit's, the commit's reviewed one is recorded. The evidence artifact then records `gate: "skipped"` plus that reason — it can never say `passed`, so a release that skipped is distinguishable forever after from one that did not. Everything else still binds: the exact-SHA pin, the clean-tree check, the runtime digest, the version/ref invariant, and the evidence upload. The decision is written into the release commit as a `Release-Test-Gate: skipped` trailer, because the publish stage is push-triggered and `inputs.*` is empty there; the trailer is also what a reviewer reads in the release PR. **Consequence, stated rather than glossed:** any commit whose subject starts with `chore(release): bump version to` AND carries that trailer skips the publish gate, so the protected-PR review — not a machine check — is what stands between a hand-written trailer and an unverified tag. Use it for a release whose diff you have already verified another way (a counter bump, a docs-only fix), never as the default path.

   **Dispatcher-controlled values never reach a shell through `${{ }}`.** Every `inputs.*` value enters a `run:` script only through a step `env:` mapping and a quoted variable (`"$SKIP_REASON"`), and the dispatched ref only through the runner's `"$GITHUB_REF"`. GitHub pastes an expanded expression into the script text before bash parses it, so a quote, a backtick or `$(...)` in that text becomes code. A job output is no exception: `publish-plan` hands the skip reason on as `gate_reason`, so every `needs.*` value also enters a script only through `env:`. `tests/structure/test-workflow-dispatch-inputs.sh` fails on any `inputs`, `env` or `needs` reference inside a `run:` block of any workflow, and on any `github` reference there other than a dotted `sha`, `event_name`, `repository` or `server_url` — index syntax, whole-context dumps such as `toJSON(github)` and any letter case included. That allowlist is `TRUSTED_GITHUB_MEMBERS` in `tests/structure/workflow-dispatch-inputs.test.js`; a member joins it only when neither a dispatcher nor a pull-request author can choose its value.
2. Open the PR from that link, then review + **squash-merge** it. (CI pushes the branch but does not open the PR — the org caps the workflow token for PR creation; release/tag creation only needs the per-job `contents: write`, which works.)
3. The release commit landing on `main` is **not** plugin go-live: the updated catalog points to an as-yet unavailable tag. `publish-plan` verifies the GitHub repo/ref/version invariant and rejects a pre-existing tag at any other commit before it decides the gate, so a doomed publication fails before any shard starts. `publish-suite` re-runs the sharded suite against the exact clean `${{ github.sha }}`, and `publish` repeats both checks, revalidates the runtime digest, and uploads a second deterministic SHA-bound evidence artifact. Only then does it create `vX.Y.Z` at that SHA and a **published** GitHub Release (notes = the new CHANGELOG section, source zip attached). Successful tag creation makes the source resolvable and is go-live. An exact existing tag with a missing release can be repaired idempotently after repeating the deterministic gate. Users pull it via `claude plugin marketplace update zensu`. The release notes were already reviewed in the bump PR body, so there is no separate draft-publish step.

The version/ref invariant above is machine-enforced: the gate runs `tests/run-all.sh --ci` in shards (including the version-sync and immutable-marketplace tests) before the branch is pushed. For a manual hotfix bump, follow the invariant by hand — `plugin.json` version + marketplace version + marketplace `ref: vX.Y.Z` + README badge (same version) + a new `## [X.Y.Z] - YYYY-MM-DD` CHANGELOG section + commit subject `chore(release): bump version to X.Y.Z`.

If marketplace version or source `ref` ever lags `plugin.json` (for example, a hand bump forgot one field), fix both in the release PR before any tag is created or any user-side `claude plugin install <name>@<name>` attempt.

## Runtime Lineage and `version_type`

A running session may be served by a newer installation of the same lineage: same
major, and while the major is `0` also the same minor, never backwards, and a sibling
install root. So **while the plugin is at major `0`, MINOR is the breaking axis**: a
breaking change costs a `minor` release, and a non-breaking feature is a `patch`.

Breaking, and therefore `minor`:

- a change to the context record or workflow-state schema (a field added, removed or retyped);
- a change to a strict key set (a validator that rejects an unknown or missing key);
- removing or renaming a registered hook, or changing a hook's matcher;
- adding a hook that can return a `permissionDecision` of any kind;
- a change to the attestation shape.

Not breaking, and therefore `patch`: adding an advisory hook whose only output is
`additionalContext`, and adding a config key that is read permissively.

Never edit `hooks/`, `agents/`, `skills/`, `docs/`, `templates/` or `scripts/` while a
suite is running. The Session Control runtime digest covers those directories, so a mid-run
edit makes later binds in that suite fail far from the cause. Run suites from a
detached worktree when you need to keep working.

Full policy, exemptions and known gaps: `.claude/rules/runtime-lineage.md`.

## Shell Portability

macOS ships bash 3.2 as `/bin/bash`. Inside a command substitution `$( ... )`, write
every `case` pattern with the optional leading paren, `(pattern)`. The bare `pattern)`
form closes the substitution early on bash 3.2, and `bash -n` does not catch it.
Details: `.claude/rules/bash32-command-substitution.md`.

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

**Every plugin-opened PR body carries an Acceptance Criteria table.** The shared, repo-overridable template is `templates/pr-body.md` (resolution: `.zensu/templates/pr-body.md` at the working-tree toplevel, else `${CLAUDE_PLUGIN_ROOT}/templates/pr-body.md`). Its `## Acceptance criteria` table takes one row per stable `AC-###`/`FR-###` id read from the feature's TDD plan `## Requirements` table via `hooks/lib/zensu-plan-requirements.sh` (exit 0 = usable); when no usable table exists the template's single stub row stays in place — never ship an empty table. Both PR openers honor this: `/zensu:pilot` renders `pr-body.md`, and `/zensu:autopilot` uses its richer `autopilot-pr-body.md` variant (the same table plus the build-time bypass-ledger audit line).

## Subsystem Rules

Each entry names the section title, what it covers, and its rule file.

- **Language** — the English-only rule in full, and its two carve-outs for non-English match literals: `.claude/rules/language.md`
- **Artifact Path Redaction (`hooks/lib/zensu-artifact-redact-v1.js`)** — what makes committed `.zensu` plans and logs publishable: `.claude/rules/artifact-path-redaction.md`
- **TDD Mode Precedence (`hooks/lib/zensu-config.sh` + `zensu-log.sh --tdd-begin`)** — the four-rank strict/vanilla ladder: `.claude/rules/tdd-mode-precedence.md`
- **Requirements-Table Gate (`hooks/lib/zensu-plan-requirements.sh`)** — why `--tdd-complete` refuses a plan without a usable `## Requirements` table: `.claude/rules/requirements-table-gate.md`
- **Evidence Runner and Full-Suite Gate (`hooks/lib/evidence-run-v1.js` + `zensu-log.sh --evidence-run` / `--chain-done`)** — the plugin-run full suite, its tree-bound record and the terminus gate: `.claude/rules/evidence-runner.md`
- **Full Suite in CI (`ci-contract-v1.js` + `full-suite-policy-v1.js` + `/zensu:full-suite`)** — leaving a chain's full suite to the verified CI pull-request pipeline, the asymmetric ladder and the chain snapshot: `.claude/rules/full-suite-ci-deferral.md`
- **Acceptance Verification Gate (`hooks/lib/acceptance-verify-v1.js` + `zensu-log.sh --acceptance-record` / `--acceptance-status` / `--chain-done`)** — per-criterion live verification records, the receipt-anchored plan and the terminus refusal: `.claude/rules/acceptance-verification-gate.md`
- **Windows Budget for `best-solution-first`** — why a Windows shard budget, not a suite cap, binds: `.claude/rules/windows-budget-best-solution-first.md`
- **Runtime Lineage (`version_type` is load-bearing)** — the full `version_type` policy and its breaking-change list: `.claude/rules/runtime-lineage.md`
- **Adopting a Record Across a Lineage Break (`adoptableRecord` / `adoptContext`)** — `/zensu:adopt-session` and the pruned-installation state: `.claude/rules/session-adoption.md`
- **Automatic Adoption (`hooks/lib/session-auto-adopt-v1.js`)** — the hook-side adoption of a compatible-schema record across a lineage break, its opt-out and the refusal tokens its denies name: `.claude/rules/automatic-adoption.md`
- **Workflow-Baseline Repair (`workflowBaselineVerdict` / `repairWorkflowBaseline`)** — rebuilding a missing workflow document without relaxing the deny: `.claude/rules/workflow-baseline-repair.md`
- **Autopilot Run Scope (`hooks/lib/zensu-autopilot-state.sh`)** — owner versus workspace scoping, release and adoption of durable runs: `.claude/rules/autopilot-run-scope.md`
- **Owner-Scoped Active-Run Read (`autopilot_read_active_strict`)** — which callers read the owner-scoped question strictly, the read-only look on a held lease, the same separation in the Stop reconcile and the public workspace read, and the lease checks: `.claude/rules/autopilot-active-read.md`
- **CLI Command Classification (`hooks/lib/zensu-mcp-tools.sh` + `hooks/lib/zensu-cli-map.sh`)** — which `zensu` CLI verbs the write-gate treats as mutations: `.claude/rules/cli-command-classification.md`
- **Foreign-Chain Row (`zensu-doctor.sh` + `zensu-doctor-report.js`)** — the `/zensu:doctor` rows about chains and their record anchor: `.claude/rules/foreign-chain-row.md`
- **Autopilot Lease Row (`leaseRow` in `hooks/lib/zensu-doctor-report.js`)** — the read-only `/zensu:doctor` rows for the Autopilot project lease and its recovery sentinel, rendered from the core's `inspectExternalProcessLock`: `.claude/rules/autopilot-lease-row.md`
- **Implementing-Phase Turn Counter (`hooks/stop-chain-enforcer.sh` + `zensu-tdd-phase.sh`)** — the `implStopCount` nudge and the shared watchdog ladder: `.claude/rules/implementing-phase-turn-counter.md`
- **Stop Hook Latency (`hooks/lib/zensu-stop-deadline.sh` + `hooks/lib/stop-idle-probe-v1.js`)** — the early exit for a Stop with nothing to enforce, the whole-hook deadline and why it releases, and the once-per-run project-root memo and canonical-key shortcut in `hooks/lib/zensu-session.sh`: `.claude/rules/stop-latency.md`
- **Relaxable Bind Failures (`hooks/lib/claude-hook-session-v1.js`)** — the two bind failures that relax, and the vanished-cwd case that must not: `.claude/rules/relaxable-bind-failures.md`
- **Reviewer Capability Gate: Host Report Tool (`hooks/lib/reviewer-capability-v1.js`)** — why reviewers and the PLM may call `SubagentHandback`, and why the evidence workers may not: `.claude/rules/reviewer-capability-gate.md`
- **Git Mutation Tables (`hooks/lib/bash-source-write-parse.js`)** — why the Bash source-write gate is opt-in, rule (C) and its Windows namespace: `.claude/rules/git-mutation-tables.md`
- **Plugin-Data Guard (`hooks/pre-write-plugin-data-guard.sh` + `plugin-data-guard-v1.js`)** — the Edit/Write deny into `CLAUDE_PLUGIN_DATA` and its residuals: `.claude/rules/plugin-data-guard.md`
- **Bypass Ledger Read Contract (`tdd_bypasses`)** — how the "Gates bypassed" line reads the ledger: `.claude/rules/bypass-ledger-read-contract.md`
- **Status-Marker Legend (CHAIN-END SUMMARY + PR bodies)** — the four status markers in the chain-end summary and PR bodies: `.claude/rules/status-marker-legend.md`
- **Chain Shape & Rearm Receipt (`hooks/lib/chain-recovery-v1.js`)** — chain classification, the rearm receipt and `--chain-recover`: `.claude/rules/chain-shape-rearm-receipt.md`
- **Plan-Gate Payload Sources (`hooks/lib/plan-payload-v1.js`)** — where the approved plan is read from on `ExitPlanMode`: `.claude/rules/plan-gate-payload-sources.md`
- **Plan-Approval Delivery Route (`hooks/plan-approved-delegate.sh`, standalone branch)** — the four-route question after a plan is approved: `.claude/rules/plan-approval-delivery-route.md`
- **Session Delivery Route (`/zensu:delivery-route` + `hooks.defaultDeliveryRoute`)** — the session marker and config key that remember a Zensu-workflow answer or an explicit `--direct` for the session, or answer the route question without asking: `.claude/rules/session-delivery-route.md`
- **Host-Refused Reviewer Spawn (`hooks/lib/reviewer-spawn-denial-v1.js`)** — diagnosing a reviewer spawn the host refused: `.claude/rules/host-refused-reviewer-spawn.md`
- **Reviewer-Spawn Grant (`hooks/pre-agent-reviewer-allow.sh` + `reviewer-spawn-allow-v1.js`)** — the PreToolUse allow for the plugin's own read-only reviewers: `.claude/rules/reviewer-spawn-grant.md`
- **Review-Spawn Scope Sentence (`ZENSU_REVIEW_SPAWN_IN_SCOPE`)** — the sentence that answers a host rule against unrequested spawns: `.claude/rules/review-spawn-scope-sentence.md`
- **Marker-Block Carriers (`session-start-evidence-discipline.sh` + `user-prompt-best-solution-first.sh`)** — the two hooks that inject a rule from a docs marker block: `.claude/rules/marker-block-carriers.md`
- **Gate-Disable Prefixes (`ZENSU_*=off`) and `test-gauntlet-loop-skill.sh` G12** — adding a `ZENSU_*=off` escape means editing `ESCAPE_STEMS`: `.claude/rules/gate-disable-prefixes.md`
- **Fixture Mutation Events (`scripts/fixture-mutation-watch.js`)** — the promptfoo wrapper's transient-mutation detection: `.claude/rules/fixture-mutation-events.md`
- **Session Lineage Ledger (`skills/session-trail/scripts/session-lineage-v1.mjs`)** — the machine-wide takeover ledger of `/zensu:session-trail`: `.claude/rules/session-lineage-ledger.md`
- **Takeover Destination (`worktreeAdvice` in `skills/session-trail/scripts/trail.mjs`)** — where a taken-over session continues, and the carry-over recipe: `.claude/rules/takeover-destination.md`
- **Session-Trail Prompt Listing (`extractPrompts` in `skills/session-trail/scripts/trail.mjs`)** — the prompt timeline and the separate list of withdrawn prompts: `.claude/rules/session-trail-prompt-listing.md`
- **zen-mode Chain-Progress Anchor (`user-prompt-zen-mode.sh` rule 6)** — the hook-supplied progress anchor of zen-mode: `.claude/rules/zen-mode-chain-anchor.md`
- **bash 3.2 Command-Substitution Truncation (`test-bash32-portability.sh`)** — why `case` patterns inside `$( )` need the leading paren: `.claude/rules/bash32-command-substitution.md`
- **Skill Argument Placeholders (`test-skill-workflow-markers.sh` AP checks)** — why a skill body never carries `$1` or `$ARGUMENTS` in a shell snippet, and the allowlist for a skill that consumes its arguments: `.claude/rules/skill-argument-placeholders.md`
- **Skill Text Budget (`tests/structure/test-skill-text-budget.sh`)** — the body and description caps for every skill, the shrink-only allowlist, and how the host builds its skill listing: `.claude/rules/skill-text-budget.md`
- **Incremental Review Rounds (`review-round-scope-v1.js` + `aspect-activation-v1.js`)** — delta-scoped fix rounds and aspect activation: `.claude/rules/incremental-review-rounds.md`
- **Review Convergence (`review-ledger-v1.js` + `hooks.reviewConvergence`)** — the findings ledger, the shared severity rubric and round-aware routing of the auto-fix loop: `.claude/rules/review-convergence.md`
- **Multi-Repo Stage 1 (`zensu-log.sh` terminus + `zensu-edit-landing.sh` + the doctor row)** — refusing a chain whose work landed in another repository: `.claude/rules/multi-repo-stage1.md`
- **Browser Consent Gate (`hooks/lib/verify-consent-v1.js` + the two consent hooks)** — consent prompts for `/zensu:verify-feature` browser navigation: `.claude/rules/browser-consent-gate.md`
- **Worktree Keep (`hooks/lib/worktree-keep-v1.js` + three advisory hooks)** — keeping a live session's worktree out of the Claude Desktop pool, and the drift notice when it is taken anyway: `.claude/rules/worktree-keep.md`
- **Restoring a Vanished Recorded Project Root (`restoreRootVerdict` / `restoreWorkflowProjectRoot`)** — re-creating a recorded project root a removed worktree took with it: `.claude/rules/restore-vanished-project-root.md`
- **Session Re-anchor (`reanchorVerdict` / `performReanchor`)** — the verified move of a session's anchor to a sibling worktree of the same repository, and the deny texts that point at it: `.claude/rules/session-reanchor.md`
- **Deferred-Review Claim Ownership (`deferredReviewClaimHeld`)** — why the lease, not the recorded owner PID, decides who holds an adopted review, and how lock staleness rejects a reused PID on every platform: `.claude/rules/deferred-review-claim-ownership.md`
