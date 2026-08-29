# Gates

Four PreToolUse gates keep an agent inside the workflow conventions, plus TWO
completion-time `--tdd-complete` refusals of the same class: the edit-landing
receipt (discipline patch 10 in [tdd-manager-workflow.md](tdd-manager-workflow.md))
and §Requirements-Table Gate below, which has its own section here. All six are
convention-nudges with a documented escape hatch, not security boundaries — see
[Session Control](session-control.md) for the part that is.

**Two commands stay reachable when the Session Control bind fails**, in every
bind failure including a record that exists and disagrees, and they are
recognized by `hooks/lib/zensu-doctor-invocation.js` rather than by any
individual gate: `/zensu:doctor`, which writes nothing, and
`/zensu:adopt-session`, whose writes are confined to the calling session's own
record, one workflow history entry, and a move of that session's stale
review-evidence leases; it carries its own justification in the header of
`hooks/lib/zensu-session-adopt.sh`. Both are matched as exact whitelisted shapes
— a closed set of assignments, one `bash <script in the executing installation>`,
and for the adoption at most the literal `--confirm`. Every hook on the `Bash`
matcher plus the all-tool capability gate must allow, because a deny from any one
of them wins. The full account is in
[Session Control](session-control.md#unbindable-sessions).

## CLI Write-Gate

The `zensu` CLI is **read-free, write-gated**. Any state-mutating command (creating or
updating features, security classifications, tiers, journeys, revisions, …) run directly
on the main thread is **denied by default** — it must run inside a skill that declared its
work, so "freelance" writes cannot bypass the dedup, user-journey, baseline-revision and
security-review conventions the skills enforce. Reads and telemetry are always allowed.

The gate is a PreToolUse(Bash) hook (`pre-bash-zensu-gate.sh`): it parses `zensu <noun> <verb>`
out of the Bash command, resolves each to its canonical tool
name via `hooks/lib/zensu-cli-map.sh`, and classifies it with the same `hooks/lib/zensu-mcp-tools.sh`
source of truth. It is a **convention-nudge, not a hard boundary** — once the CLI's OAuth token
is cached on disk an agent could `curl` the backend directly; the gate enforces the workflow
conventions, not a security control (the same role, and the same `ZENSU_MCP_GATE=off` escape, as
the MCP write-gate it replaced).

```mermaid
flowchart TD
    A["zensu CLI command<br/>(Bash, main thread)"] --> B{"Read / telemetry / --help?<br/>list / get / search / suggest verbs<br/>+ pulse, journeys health, --help …"}
    B -->|"yes"| ALLOW(["ALLOW"])
    B -->|"no — state mutation"| C{"ZENSU_MCP_GATE=off (env or inline)<br/>or hooks.mcpGate=false<br/>or localhost backend?"}
    C -->|"yes (escape hatch)"| ALLOW
    C -->|"no"| E{"Inside an active main-thread skill workflow?<br/>workflowActive = true<br/>AND tool in workflowTools (per-skill scope)"}
    E -->|"yes"| ALLOW
    E -->|"no"| DENY(["DENY<br/>run the matching skill<br/>in the interactive main thread"])

    style A fill:#4a9eff,color:#fff
    style ALLOW fill:#51cf66,color:#fff
    style DENY fill:#ff6b6b,color:#fff
```

A skill opens a **scoped** window with
`zensu-log.sh --workflow-begin --tools "<exact tool set>"`: the bypass then allows **only**
that skill's declared tools — so `/zensu:implement` cannot forge a `set_security_classification`
it never declared — and `--workflow-end` closes it again. The `--tools` list stays tool-name-keyed;
the gate maps each CLI command back to its canonical tool name to check membership. `ZENSU_MCP_GATE=off`
disables the gate for a deliberate one-off — honored both as a session env and as an **inline prefix**
(`ZENSU_MCP_GATE=off zensu …`). The gate is scoped to its threat model (a low-context agent writing to the
*real tracked product*), so it also never fires on reads or `--help`/`-h`, or on a write whose target backend
(`--api-url` flag / `ZENSU_API_URL` env) is **localhost** — a throwaway dev/test DB where the conventions are
meaningless. A structure test (`tests/structure/test-skill-workflow-markers.sh`)
fails the build if any skill runs a mutation command without the `--workflow-begin` /
`--workflow-end` markers, so a new skill cannot silently regress the contract.

## Source-Write Gate

A second PreToolUse(Bash) hook (`pre-bash-source-write-gate.sh`) protects **source files** from
raw shell writes that bypass the Edit/Write tools. The Edit/Write gate (`pre-edit-tdd-reminder.sh`)
only ever sees `Edit|Write|MultiEdit`; an agent can route around it with `printf >> file.rs`,
`cat > file.rs <<EOF`, `sed -i`, `tee`, or `dd of=` — and, worse, `cd` into a sibling/main checkout
and clobber **another session's working tree**.

The gate denies a write through one of those channels to a source-extension file when either:

- **(A) Clobber** — the target already **exists and is git-tracked** inside the project (a raw
  shell overwrite of real tracked source), or
- **(B) Escape** — the resolved path lands **outside the session root** (`CLAUDE_PROJECT_DIR`, else
  the command's cwd) — a sibling or main checkout. Relative targets resolve against a cwd that
  **tracks `cd` across the command**, so `cd ../main && printf … >> src/x.rs` is caught. (B) fires
  even for a new file, since writing fresh source into another checkout is the breach.

git reaches that same breach without naming a write target at all — `git add -A` in a shell whose
cwd drifted back to the main checkout stages *that* repo's files — so a third rule covers it:

- **(C) Git repo escape** — a **working-tree-mutating** git subcommand whose **target repository**
  lands outside the session root. The repository is read from `git -C <path>` (relative and
  cumulative, as git resolves them), `--work-tree`/`--git-dir`, an inline, `env`-wrapper or
  `export`/`declare -x` `GIT_DIR=`/`GIT_WORK_TREE=` assignment, or the same `cd`-tracking cwd as (B). The gated verbs are the `GIT_MUTATIONS` set in
  `hooks/lib/bash-source-write-parse.js`; **reads and unknown subcommands pass**, as does every
  mutation inside your own worktree, and the read-only spellings listed in `GIT_READONLY_FORMS` are exempt.
  `git worktree` is gated for `remove`/`move` only — and judged on the tree it destroys, not on
  the repository it is addressed to, so removing a scratch worktree under `/tmp` stays ungated.
  Rule (A) is never applied to the git subcommand itself.

Never denied under (A)/(B): creating a **new** file inside the project, gitignored/untracked files,
non-source extensions. **Rule (C) applies neither filter** — it judges which repository is addressed,
so `git -C ../sibling add notes.md` is denied even though `.md` is not a source extension. Never
denied under any rule: temp roots (`$TMPDIR`, `/tmp`, `/private/tmp`, `/var/folders`; override the
set with `ZENSU_BSWGATE_TEMP_DIRS`). The standalone `mv`/`cp` commands are out of scope — `git mv`
is covered by (C) when it escapes the session root. Like the CLI gate this is a
**convention-nudge, not a hard boundary** — bypass a deliberate one-off with an inline
`ZENSU_BASH_WRITE_GATE=off` (or `ZENSU_MCP_GATE=off`) prefix, or disable it via `hooks.bashWriteGate:false`.
`tests/structure/test-bash-source-write-gate.sh` pins the behavior.

**The expected *legitimate* hit of rule (C) is a cross-worktree takeover.** A session that continues
work started in a worktree its own anchor does **not contain** (see `/zensu:session-trail`) can edit
files and run tests there — on the main thread no Edit-matcher hook compares a path against the
project root, and the all-tool capability gate that does compare exempts the main principal — but its
first `git add`/`git commit` denies, because the session root is minted at SessionStart and nothing
re-anchors it. Containment is the test, so this does **not** cover a nested worktree: with
`git worktree add .claude/worktrees/<name>` every worktree sits inside the main checkout and a session
anchored there commits in all of them. The blocked shapes are a sibling worktree, another repository,
and the main checkout addressed from inside a worktree. The route is a session whose own anchor
contains that worktree — `cd -- <cwd> && claude --resume <id>` as `show` prints it, or the handoff
brief opened by an instance already running there — not the escape prefix above: the host's
permission layer commonly refuses an inline `ZENSU_BASH_WRITE_GATE=off` as well.

A plain `--resume` **re-anchors nothing**, and that is why the route works rather than a caveat
against it: `FRESH_SESSION_SOURCES` in `hooks/lib/claude-session-control-v1.js` is
`{startup, clear, fork}`, so a `resume` reuses the immutable record the target session was minted
with and inherits **that session's** anchor whatever directory you `cd` to first. The `cd` operand
decides the anchor only for a **fresh** source — `--fork-session`, or a session whose record was
pruned — and there it matters: compare the `WORKTREE` and `CWD` rows and start in `WORKTREE` if they
differ, or the forked session anchors *inside* the worktree and still cannot commit at its root.
Flow 3 of `skills/session-trail/SKILL.md` carries the routing rule and is the authority.

## Secret Scan

A third PreToolUse gate (`pre-write-secret-scan.sh`) inspects **what** is about to be written,
complementing the source-write gate's **which files**: Write `content`, Edit `new_string`,
MultiEdit `edits[].new_string`, NotebookEdit `new_source`, and — whenever the shared parser
(`detectChannels`) reports a write channel (redirect, `tee`, `sed -i`, `dd of=`, heredoc) —
the Bash command text. Payloads are matched against the curated rule set in
`hooks/lib/secret-patterns.js` (AWS, GitHub `gh[pousr]_`/`github_pat_`, Slack, Stripe
`sk_live_`/`rk_live_`, private-key PEM headers incl. PKCS#8, plus a Shannon-entropy assignment
heuristic — deliberately no naive key/password catch-all); decision logic lives in
`hooks/lib/secret-scan-decide.js`. Never denied: **file-tool** targets under a `test(s)/`, `__tests__/`,
`spec(s)/`, `testdata/`, `evals/` or `fixtures/` segment and `*.example.*` files (the path exemption does not apply to
the Bash channel — its targets are not resolved; use the marker or escape hatch there), lines
carrying the `zensu-secret-allow` marker, obvious placeholders (`EXAMPLE`, `YOUR_...`,
`{{...}}`, `${...}`), and Bash commands with an inline `ZENSU_SECRET_SCAN=off` prefix. Parser
errors **fail open** with a stderr note. Bypass with `ZENSU_SECRET_SCAN=off` (env, or inline
for Bash); disable via `hooks.secretScan:false`.
`tests/structure/test-secret-scan-gate.sh` pins the behavior.

## Reviewer-Spawn Grant

The one entry in this file that **opens** rather than closes. `pre-agent-reviewer-allow.sh` is a
PreToolUse hook on the `Agent|Task` matcher that returns `permissionDecision: "allow"` for Zensu's
own capability-confined reviewer subagents, which short-circuits the host permission pipeline
**before** the auto-mode classifier is consulted.

It exists because a classifier refusal is invisible to every other mechanism here. The spawn never
executes, so no PreToolUse or PostToolUse hook observes it, and the Stop chain-enforcer repeats an
instruction that cannot succeed until its cap releases the guard.
`hooks/lib/reviewer-spawn-denial-v1.js` diagnoses that state after the fact; this hook prevents it.

- **It can only grant or stay silent.** It never emits deny or ask, and every failure path is a
  silent `exit 0` — the opposite of the fail-closed direction the gates above take. A non-zero exit
  from a PreToolUse hook blocks the tool call, so a fail-closed grant hook would break every Agent
  spawn in the session, including the reviewer it exists to admit.
- **Four conditions, all required.** The main principal; a bound Session Control record;
  `hooks.reviewerSpawnAutoAllow` not set to exactly `false`; and membership in the confined set.
- **The set is derived, never spelled.** It is `claude-principal-v1.js`'s `REVIEWER_TYPES` plus
  `EVIDENCE_WORKER_TYPES` — the same classifier `SubagentStart` uses to inject
  `reviewer-readonly-v1` — restricted to the plugin-scoped `zensu:` names, and then filtered
  again at decision time: `confinedByFrontmatter` reads each candidate's `agents/<stem>.md`
  and keeps only those whose `tools:` line is exactly `Read`/`Grep`/`Glob`, so a member added
  to those sets for principal reasons cannot acquire a classifier-free spawn by name alone.
  Bare names (`code-reviewer`, …) are **excluded** because a project may define a same-named
  agent with `tools: Bash`.
- **What bounds the CHILD is in this tree, not an assumption about the host.**
  `hooks/pre-reviewer-capability-gate.sh` runs on the `.*` PreToolUse matcher and denies any
  tool outside the read trio for a `REVIEWER` principal, and confines its reads to the project
  root. It is fail-closed and carries no config off-switch, so it holds whether or not the host
  re-checks the child's own calls — a claim about the host would be unverified, and this one is
  checkable. Weakening `readOnlyViolation`, or giving that gate an off-switch, removes the only
  backstop this grant has.
- **The grant covers the CALL, not only the identity.** Only `tool_name` and
  `tool_input.subagent_type` are examined; every other input field travels unexamined,
  including `prompt` and `isolation: "worktree"` — and that last one is a host-performed
  filesystem action caused by the spawn itself, so it sits outside the `Read`/`Grep`/`Glob`
  confinement the frontmatter provides. Read that confinement as bounding what the CHILD may
  do, never as bounding the call.
- **Three host limits bound it**, and none is a defect to be fixed by widening the grant: a
  `permissions.deny` or `permissions.ask` rule still overrides it; another hook on the same matcher
  returning deny or ask outranks it (the host ranks deny > ask > allow); and an SDK session
  supplying `canUseTool` forces the full pipeline.
- **It is disclosed in both states.** The SessionStart banner names the grant while it is on, and a
  `/zensu:doctor` row reports it either way — that row is not silenceable by the flag. A capability
  the plugin hands itself is exactly the thing that must not be quiet.

## TDD Phase Gate

Unlike prompt-based TDD ("please write tests first"), the `/zensu:tdd` workflow **structurally prevents** violations via a PreToolUse FSM gate on Edit/Write/MultiEdit:

- **Phase declaration.** Before any edit, the main agent declares the current TDD phase through the top-level Skill command template `CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --phase <PHASE> --step <step_id>`. Claude renders both native plugin placeholders in top-level Skill/Agent content. The helper then uses the host-exposed `CLAUDE_CODE_SESSION_ID` only inside that Bash process to validate the exact immutable record and derive its internal selectors; it never trusts an ambient plugin-private selector. Valid phases: `RED_WRITE`, `RED_RUN`, `RED_FAIL`, `IMPL`, `GREEN_RUN`, `GREEN_PASS`, `REFACTOR`.
- **Gate enforcement.** The PreToolUse hook (`pre-edit-tdd-reminder.sh`) blocks edits whose declared phase violates FSM transitions. In particular, `IMPL` requires a prior `RED_FAIL` marker for the **same step** — there is no path to production code without a failing test on record.
- **State.** Phase markers persist at `.zensu/state/tdd-phase-<scv1-session-key>.json`. Every atomic mutation increments the record revision, and each step's history remains auditable from the file.
- **Activation.** Phase 0 of the skill calls `zensu-log.sh --tdd-begin`, which sets a per-session chain-state `active` flag. Given a valid SessionStart baseline, the TDD gate (and Bash witness) enforce **only** while that flag is set; a valid inactive baseline passes through. A missing, malformed, or unreadable mandatory baseline is an integrity failure and fails closed in Session Control plus the edit/Stop guards. (Pre-0.4.0 this keyed on `CLAUDE_AGENT_TYPE=zensu:tdd-manager`.) Bypass via `ZENSU_TDD_GATE=off` for legitimate non-TDD edits explicitly authorized by the user. The strict gate described above is **opt-in**: `hooks.tddImplementation` defaults to `false`, so out of the box the workflow runs in **vanilla mode** — the gate passes through and the RED→GREEN ceremony is dropped while the evidence audits and review chain stay enforced. Set `hooks.tddImplementation:true` to enforce the strict RED→GREEN gate (see the Hook Opt-Out table). Two ranks sit above that flag at `--tdd-begin`: the session choice recorded by `/zensu:tdd-mode` and, below it, the calling skill's own `--tdd-mode` default (`/zensu:pr-fix-findings` asks for `strict`) — full precedence in [Configuration](configuration.md#hook-opt-out). The second of those is **escalation-only** — `strict` is the only value it accepts, so lowering the discipline stays the session choice. Choosing vanilla through that session choice is a MODE choice, not a gate escape, so it records no bypass-ledger entry; `ZENSU_TDD_GATE=off` remains the only escape and still does.

Additional features: dependency graph for independent-step sequencing, 3-retry IMPL escalation on GREEN-fail with progressive context, completeness audit (mtime discipline + edit landing + build verification), real-time progress log at `.zensu/logs/`.

## Requirements-Table Gate

`--tdd-complete` carries two preconditions, and both are refusals rather than reminders. The
first is the Phase 6 step 5b edit-landing receipt. The second is this one: the session's TDD
plan must carry a usable `## Requirements` table.

- **Why it is a gate.** [`/zensu:converge`](../skills/converge/SKILL.md) anchors its flow-back
  audit on that table; without one it takes its documented legacy stop and reports nothing. In
  [`/zensu:autopilot`](../skills/autopilot/SKILL.md) the CONVERGE stage is the only edge into
  `OPEN_PR`, so a missing table turns a mandatory gate into a clean-looking no-op. Prose asked
  for the table and the only check was the warning-level Phase 6 step 6c, which skips silently
  when it is absent.
- **The rule**, implemented once in `hooks/lib/zensu-plan-requirements.sh`: a `## Requirements`
  heading, plus at least one `AC-###`/`FR-###` row whose Requirement cell survives removing
  every `{...}` placeholder group. A row that merely quotes braces counts; a row that is still
  the template's `{curly}` placeholder does not. Deprecated rows count — the never-recycle rule
  keeps them. The Requirement column is located from the table's header row, so a repo override
  that re-orders the columns is judged correctly. This is **stricter than converge**, not
  identical to it: converge's own check is its Phase 0 step 2 legacy stop, which keys on the
  table being *absent*, and its coverage audit EXCLUDES deprecated rows that count here. A plan
  this gate passes is not automatically one converge can audit in full.
- **Which plan.** `--plan <path>` when the skill passes it (it does), else derived from the
  edit-landing receipt's record of the run log it audited: `.zensu/logs/<stem>.log` names
  `.zensu/plans/<stem>.md`. Both channels are bounded to this session: the derived `log` must
  resolve inside the project's own `.zensu/logs/`, and an explicit `--plan` must resolve inside
  `.zensu/plans/` and carry the same stem the derivation would — so neither can be pointed at a file outside
  the project. The stale-plan half is weaker and worth stating exactly: the derived channel binds
  THIS session's receipt, and that receipt is an ordinary file the session can rewrite through a
  Bash redirect, which no gate covers — so the anchoring is only as strong as the receipt. It
  buys nothing an attacker wants anyway: a model that wanted to defeat this gate would simply
  fill the table. With no derivable stem the flag is refused rather than
  accepted on the directory bound alone — except when `ZENSU_EDIT_LANDING_GATE=off` is what
  removed the receipt, where the bound is dropped and disclosed instead (see the scope-gap
  bullet below). A `.zensu/plans` or `.zensu/logs` that is itself a symlink is refused
  rather than resolved through, and every root in the verb comes from
  `zensu_resolve_project_dir` — which is also what `CLAUDE_PROJECT_DIR` is normalized to for
  every `--*` verb before any verb body runs, so the two cannot diverge. An explicit `--plan` that
  names nothing refuses; a derived path that is not there does not, because nothing was asserted
  — but the gate then prints `REQUIREMENTS GATE UNRESOLVED` rather than passing silently, so
  "the table passed" and "no table was checked" never read the same.
- **Refusal wording is typed.** A missing or placeholder-only table refuses as a verdict about
  the plan; an unreadable path, a usage error, or a missing library refuses with "could not
  judge the plan" instead — a load fault must never be reported as a judged table.
- **Scope.** Same as the receipt gate: a resolvable git HEAD plus a non-empty change set. A
  chain that changed nothing has no plan claim to check. **Known gap, stated rather than
  implied:** a bound Autopilot chain that produced zero file changes therefore passes this gate
  untested, still travels its return stage into CONVERGE — the only edge into `OPEN_PR` — and
  converge then mtime-resolves the plan Phase 2 wrote anyway and takes its legacy stop. "The
  CONVERGE stage is the only edge into OPEN_PR" must not be read as "that edge is now covered".
- **Two further scope gaps, named rather than implied.** The change set is the WORKTREE against
  `HEAD` — there is no baseline range — so a chain that COMMITTED its work mid-run measures zero
  changes and both gates skip, silently and without even the `REQUIREMENTS GATE UNRESOLVED`
  line. The sibling edit-landing library does carry a `--baseline` range for exactly that case;
  this verb does not. And `ZENSU_EDIT_LANDING_GATE=off` leaves no receipt, so no run-log stem can
  be derived: the explicit `--plan` then keeps only its plans-directory bound and says so on
  stderr (`REQUIREMENTS GATE STEM UNCHECKED`) rather than refusing, because refusing would make
  that documented exemption unusable for the shipped invocation, which always passes `--plan`.
- **Bypass** with `ZENSU_REQUIREMENTS_GATE=off`, which is deliberately a separate switch from
  `ZENSU_EDIT_LANDING_GATE=off` — exempting a session from one must not disarm the other, and
  the two gates share one change-set computation precisely so neither inherits the other's
  switch. Both escapes are recorded in the per-session bypass ledger.

**Full workflow reference:** [docs/tdd-manager-workflow.md](tdd-manager-workflow.md) — Mermaid flow chart, per-step FSM state diagram, hook gate behavior table, environment variables contract, discipline patches 1-13, four-channel logging.
