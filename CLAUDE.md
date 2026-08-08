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

## Approved-Plan Payload Reader (`hooks/lib/plan-payload-v1.js`)

`plan-approved-delegate.sh` is the single gate that authorizes a durable Autopilot run to
start writing code, and `plan-payload-v1.js` is the half of it that decides WHICH bytes are
the approved plan. It is write-gate code, not a utility:

- `PLAN_SOURCES` is a precedence table, and precedence is an authorization decision — the
  winning source feeds the run-marker match as well as the `approvedPlanSha256` digest, so it
  decides which run the gate opens. Order is `tool_response.plan` → `tool_response.filePath`
  → `tool_input.plan` → `tool_input.planFilePath`; a new source belongs BELOW the response
  entries, and the two `tool_input` entries are legacy. A present-but-empty response tier
  still DESCENDS to them (F52), deliberately: refusing there would invent a new way to wedge
  the one gate the response source exists to unwedge, for a payload shape nobody has measured.
  State the exposure plainly rather than overclaiming — what was measured is narrower than
  "a model cannot populate `tool_input`": the committed capture simply carried no plan field
  there. If a harness version ever forwards a model-supplied `plan` or `planFilePath`, that
  descent becomes a model-writable source. Re-check when the `ExitPlanMode` schema regains a
  plan field.
- `readPlanFile` is the only filesystem access the gate performs on payload-supplied input —
  the hook's own reads (state libraries, the module preflight, the run record) are not.
  Relaxing any of its checks (absolute path, no NUL, no UNC, `O_NOFOLLOW` with an `lstat`
  fallback and a dev/ino recheck, regular file, `nlink === 1`, non-empty, 4 MiB ceiling)
  widens what a payload can make the hook open. It accepts ANY absolute non-UNC path, so its
  authorization envelope lives entirely in the caller: a consumer must have established
  ownership, stage, tool binding and caller origin BEFORE calling `readPlanPayload` or
  `readPlanFile`. `plan-approved-delegate.sh` is the only consumer today.
  **This hardening has three un-deduplicated twins.** `hooks/lib/zensu-autopilot-state.sh`
  carries the same `process.platform !== "win32" && Number.isInteger(fs.constants.O_NOFOLLOW)`
  derivation and the same `lstat`/`fstat` identity recheck inside its bash-embedded `node -e`
  scripts, which cannot `require` this module. A change to the read hardening must be applied
  in all four places until a second requireable consumer justifies splitting the generic
  reader into its own module.
  One recorded, currently-inert exposure: `readPlanFile` distinguishes six filesystem
  conditions by code, and each becomes distinct receipt prose the model sees, so a source that
  can NAME a path turns this gate into an existence/shape oracle over arbitrary absolute
  paths. Today only the harness populates the file sources, and the refusal is reached only
  after ownership, stage, tool binding and origin. If the `ExitPlanMode` schema ever regains a
  model-writable plan field, collapse the file-shape codes to a single `PLAN_FILE_UNREADABLE`
  whenever the winning source is a `tool_input` entry — `readPlanPayload` already returns the
  winner for exactly that decision.

**Three things move together with it.** The module never calls `process.exit`; it throws a
`PlanPayloadRefusal` carrying a number. (1) `EXIT_CODES` keys are named after the very
`BLOCK_CODE` they translate into, and (2) the bash `case` in `plan-approved-delegate.sh` is the
SINGLE translation site from that number to a `BLOCK_CODE`, each of which needs (3) cause prose
in the hook's `causes` map. Adding a code without its case arm would silently route to
`PLAN_EVALUATION_UNAVAILABLE`; `test-plan-payload-fallback.sh` F10a fails the build for either
omission.

The hook keeps the payload ENVELOPE — ownership (6), stage (7), tool binding (18), caller
origin (19, 17), the run marker (4, 5) and the untyped-throw fallback (9). Be precise about
which legs are actually pinned: F11c pins `18 → 16 → {19, 17} → sources` — it never compares
19 and 17 against each other, so swapping those two leaves it green (harmless, since a boolean
`true` cannot also be a non-boolean). F20/F32 pin that the ownership refusal precedes any
source read; F11b and F11d pin only that 18 and 7 keep their own block codes, so a reordering
of 7 would leave both green. The
response-shape refusal (16) is raised inside `normalizeToolResponse`, which is why F11c
requires that call to stay a top-level statement between the binding and origin refusals, and
F51b/F51c prove behaviorally that 17 and 19 still beat an unreadable plan source.

The module path reaches Node as the `PLAN_PAYLOAD_MODULE` environment value after
`zensu-host-path.sh` translation, never as an argv token — a plugin root spelled with
whitespace or an apostrophe cannot be transported that way. That constraint originates in
`test-msys-special-plugin-module-boundaries.sh`, but that canary does NOT execute this hook —
the guard that enforces it here is F57 in `test-plan-payload-fallback.sh`. An absent or symlinked module is
refused by a preflight with the existing `RUNTIME_UNAVAILABLE` receipt (F57/F58/F58a), so a
broken plugin never reaches the evaluator.

`tests/structure/plan-payload-v1.test.js` (node --test, run from
`test-plan-payload-fallback.sh` F56) pins the source-table order, the field-typing rules, and
the path-refusal matrix. Three contracts there are easy to break by accident:

- `CONTAINERS` carries both the container names AND their `strict` drift policy, and
  `readPlanPayload` derives its map from it. Both tables are validated once at load time — a
  missing `strict`, an unknown `container`, or a `kind` other than `text`/`file` throws inside
  `require`, which fails closed as `PLAN_EVALUATION_UNAVAILABLE`. Note that the response tier
  is normalized TWICE on purpose: the hook must call `normalizeToolResponse` itself so refusal
  16 precedes 19/17 (F11c pins that), so `CONTAINERS.strict` can never refuse from today's
  call site. It is the contract for a SECOND consumer, not the effective policy site — do not
  read it as the latter, and do not delete it as dead.
- `readPlanFile`'s `noFollow` option is a MODE SELECTOR, never a flag mask: only an explicit
  `0` forces the `lstat` fallback, and anything else takes the platform default. It exists so
  that fallback can be exercised on a POSIX runner, where the kernel flag would otherwise make
  the branch dead code. Widening it back to "any integer" would let a caller skip both the
  `lstat` pre-check and the dev/ino recheck at once.
- `readPlanPayload` returns one canonical `bytes` buffer beside the decoded `plan`, and the
  only consumer digests `bytes` unconditionally (`plan-approved-delegate.sh`), so nothing
  re-encodes invalid UTF-8 and changes `approvedPlanSha256` — F23/F44 are the regressions.
  A future consumer that digested `plan` instead would reintroduce them.

One deliberate trade-off, recorded so it is not rediscovered as a defect: the module mints the
NUMBERS, not just the names, even though the consumer owns the process-exit namespace and the
sibling `chain-recovery-v1.js` returns domain vocabulary instead. It is the cheaper shape here
because `EXIT_CODES` keys ARE the `BLOCK_CODE` names, which is what makes F10a checkable in both
directions; the cost is that F10a's disjointness arm is load-bearing rather than decorative.

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
