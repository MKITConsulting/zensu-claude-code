---
paths:
  - "hooks/pre-agent-reviewer-allow.sh"
  - "hooks/lib/reviewer-spawn-allow-v1.js"
  - "tests/structure/test-reviewer-spawn-allow.sh"
  - "tests/structure/reviewer-spawn-allow-v1.test.js"
---

# Reviewer-Spawn Grant (`hooks/pre-agent-reviewer-allow.sh` + `reviewer-spawn-allow-v1.js`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

The preventive half of the section above. That one DIAGNOSES a classifier refusal after the
spawn is already lost; this one keeps the refusal from happening, by returning
`permissionDecision: "allow"` on the `Agent|Task` matcher for Zensu's own confined reviewers.

**The mechanism is MEASURED, and the measurement is what makes the feature real.** Two headless
`--permission-mode auto` runs of one prompt in an isolated directory, against Claude Code
**2.1.245**: without the hook the debug log records `classifier_request_started … tool=Agent`;
with it there is no classifier request for `tool=Agent` at all, only
`Hook result has permissionBehavior=allow` then
`Hook approved tool use for Agent, bypassing permission prompt`. The build is recorded in
`ALLOW_BYPASS_SOURCE_BUILD` and cross-checked against the module header by the unit suite, for
the same reason `DENIAL_MARKERS_SOURCE_BUILD` exists. **Re-verify against the binary, never
against memory:** a host that reorders its pipeline turns this module into a silent no-op —
the fail-open direction, but the wedge comes back.

**A plugin cannot ship a permission rule, which is why this is a hook at all.** The plugin
component surface is `commands`, `agents`, `skills`, `hooks`, `mcpServers`, `lspServers`; there
is no `permissions` key. Do not propose one.

**THE SET IS DERIVED, NEVER SPELLED**, and that is the single most important property to keep.
It is `claude-principal-v1.js`'s `REVIEWER_TYPES` ∪ `EVIDENCE_WORKER_TYPES` — the same
classifier `SubagentStart` uses to inject `reviewer-readonly-v1` — restricted to the
plugin-scoped `zensu:` spellings. Adding a confined agent there reaches this grant with no edit
here, and CLAUDE.md's standing "grep before renaming `zensu:code-reviewer`" instruction keeps
holding. **One narrowing is deliberate and load-bearing:** `REVIEWER_TYPES` also carries the
BARE names (`code-reviewer`, …) so `--agents` fixtures and same-named PROJECT agents get the
read-only principal. Those are not our files — a project may define `code-reviewer` with
`tools: Bash`, and the principal classification is prompt-level policy while `tools:`
frontmatter is what the harness enforces. Granting a bare name would hand a project-authored
agent a classifier-free spawn. **That scope reservation is an UNVERIFIED premise** — nothing in
the tree measures whether the host reserves `zensu:` to the plugin, while the bypass itself is
measured and pinned. `zensu:zensu-plm` is excluded for the STRUCTURAL reason only: `PLM_TYPES`
is a separate classification returning `HOST` and is never fed to `pluginScoped`. Do not restate
that as "no `tools:` line" — `agents/zensu-plm.md` declares `tools: Read, Grep, Glob`, so that
reason is false and its natural repair is to widen the set.

**THE HOOK CAN ONLY GRANT OR STAY SILENT**, and every failure path is a silent `exit 0` — the
OPPOSITE of the fail-closed direction every other gate takes. A non-zero exit from a PreToolUse
hook BLOCKS the call, so a fail-closed grant hook would break every Agent spawn in the session,
including the reviewer it exists to admit. Even the inherited-plugin-root mismatch, which every
sibling hook answers with `exit 2`, reports on stderr and then declines. `A16` pins that the
hook always exits 0; do not "harden" it into a gate.

**Four conditions, all required:** main principal, a bound Session Control record,
`hooks.reviewerSpawnAutoAllow` not exactly `false`, and set membership. **The armed-chain
condition was specified and then REJECTED on discovery** — `plan-review-worker` and
`pr-review-worker` are spawned by `/zensu:plan-review` and `/zensu:pr-team-review`, neither of
which arms a TDD chain or calls `--workflow-begin`, so a chain condition would ship a grant
missing two of the five. The lease alternative was rejected too: the lease is minted by skill
prose the gate cannot verify, and this file already records that module's store layout as a
repeated drift source. What bounds the risk is CONFINEMENT, not chain state — the grant admits
a SPAWN, and the child's own tool calls are permission-checked separately.

**Three host limits, none of them a defect to be fixed by widening the grant:** a
`permissions.deny` or `permissions.ask` rule still overrides it; another hook on the same
matcher returning deny or ask outranks it (the host ranks deny > ask > allow across all hooks
on a matcher); and an SDK session supplying `canUseTool` (`requireCanUseTool`) forces the full
pipeline. Headless `-p` does NOT set that flag. The first limit is why the doctor's proactive
deny and ask rows STAY, and why the granted row still carries `DENY_FIRST_CAVEAT`.

**Disclosure is not optional, because this is a capability the plugin hands ITSELF.** Two
surfaces, deliberately unequal: the SessionStart banner line is silenceable by
`hooks.sessionBanner`, the `/zensu:doctor` row is not silenceable by the grant's own flag and
renders in BOTH states. Same reasoning as `reviewerSpawnPermissionCheck` — hiding the rows
under the config key would reinstate the defect the feature removes.

**The doctor coupling has a sharp edge that cost ten green checks once.** A row that warns
whenever the decision module cannot be loaded fires on every plugin root that PREDATES this
feature, which is most doctor fixtures. The rule is asymmetric: an absent HOOK means the
feature is not installed — silent, and the ordinary exposure rows already give that reader the
right advice; hook present but module missing IS worth a row, because the hook then declines
silently while the banner says a grant is in force. `reviewerSpawnGrantRows` RETURNS the
resolved grant state and `configBlock` threads it into `permissionExposureRows`, because the
auto-mode advice is only correct when the grant is not already covering the spawn it
recommends a rule for. That thread introduced `ROW_LEVEL`, a THIRD map beside
`classifyPermissionExposure` and `ROW_TEXT` — the two-map rule in the section above now has an
exception, and a kind missing from `ROW_LEVEL` is a warning.

**Version.** The hook can GRANT, so it is NOT the advisory shape the hook-inventory exemption
covers under "Runtime Lineage (`version_type` is load-bearing)" — it changes the capability set
of every session an older runtime is still serving, exactly as a matcher change does. This is a
**`minor`** release. The config key alone would have been a `patch`; the hook is what decides it.

Moving together: `hooks/pre-agent-reviewer-allow.sh`, `hooks/lib/reviewer-spawn-allow-v1.js`,
the `Agent|Task` entry in `hooks/hooks.json`, `reviewerSpawnAutoAllowDisabled` /
`reviewerSpawnHookWired` / `reviewerSpawnGrantRows` / `ROW_LEVEL` / the
`auto-exposure-granted` verdict AND the `grantActive` conjunct on the `automode-prose` branch
in `hooks/lib/zensu-doctor-report.js`, `zensu_hook_enabled_strict` in
`hooks/lib/zensu-config.sh`, the banner line in `hooks/session-start-banner.sh`, and the
`reviewerSpawnAutoAllow` entry in `config.example.json` — that file is advertised as carrying
every flag and five sibling suites pin their own there. **The tool-name domain is a THIRD
coupling:** `SPAWN_TOOL_NAMES` is imported from `reviewer-spawn-denial-v1.js` and re-encoded as
the `hooks.json` matcher, so a member added in that module without widening the matcher leaves
the grant inert for that tool with every check green.
Operator-facing accounts: `docs/gates.md` §"Reviewer-Spawn Grant", the hook row and the
`reviewerSpawnAutoAllow` row in `docs/configuration.md` — plus, in that SAME file, the
`### Hooks (N)` header, the prose count and its `#hooks-N` link, and separately the
`configuration.md#hooks-N` cross-link in `docs/architecture.md`. `test-readme-hook-count-sync`
H2 turns red on the header count and H3 on any inconsistent reference; `docs/architecture.md`
was outside H3's file list until this change added it, so that cross-link was the one
occurrence nothing scanned, `docs/tdd-manager-workflow.md` §"The preventive layer", and the
reviewer-spawn bullets in `skills/doctor/SKILL.md` — do not restate a COUNT here, because the
next row added invalidates it; `A24` in `test-reviewer-spawn-allow.sh` is what holds the roster
against the renderer, and its phrase list is the thing to extend when a row is added.
**Bullet ORDER in that skill is load-bearing:** `P1bx`
resolves the FIRST `- **⚠️ permissions:` bullet and requires the deny-first clause in it, so a
new warning bullet placed above the exposure one fails that pin while naming the wrong drift.

**Known gaps, accepted and named:**

- **Only the plugin's own reviewers are covered.** Every other subagent type in the session is
  still classifier-subject, so a refusal there still reaches the reactive diagnosis above. The
  memory of this repo records the refusal as intermittent for EVERY subagent type; this feature
  narrows the blast radius, it does not remove the classifier.
- **The measurement is one host, one build, two runs.** It was taken with a throwaway `probe`
  agent rather than `zensu:code-reviewer`, and the classifier would have allowed that spawn
  anyway — what the runs prove is that the classifier is not CONSULTED, which is the claim that
  matters. No end-to-end run against a genuinely refused reviewer spawn exists.
- **Windows is unverified.** `tests/structure/test-reviewer-spawn-allow.sh` is deliberately NOT
  in `tests/profiles/windows-ci.v1.json`: every shard there is already close to its
  `profileTimeoutMs`, and adding a suite has to be paid for by moving another one off. Say
  "unverified", never "covered".
- **No ports.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not included. A port
  owns BOTH halves: the module's derived set and its own host's answer to whether a hook allow
  precedes that host's permission layer at all — which is a measurement, not an assumption.
- **`reviewerSpawnGrantRows` both renders and returns**, so the grant state the exposure check
  consumes is a side effect of a render call and the ORDER of the two calls in `configBlock` is
  load-bearing. Reversing them yields `grantActive === undefined` and restores the wrong
  auto-mode advice. The sibling check in the same file models the alternative
  (`classifyPermissionExposure` decides, `ROW_TEXT` words), and splitting this one the same way
  is the standing fix. Left as is deliberately: the split would touch the one function three
  review findings had just corrected.
- **`ROW_LEVEL` could travel inside the verdict.** `classifyPermissionExposure` already returns
  per-verdict objects, so a `level` field would delete the third map and restore the two-map
  rule stated above it. A missing entry defaults to WARN, which is the safe direction, so this
  is design cost rather than a defect.
- **The banner is a WEAKER check than the doctor, by design and by wording.** It tests the flag
  and the two files; it does NOT verify registration or that the decision module loads. Its text
  names `/zensu:doctor` as the authoritative check for exactly that reason. A shared
  installed-ness predicate — a `--grant-state` mode on the decider that both surfaces call —
  is the uncompromised answer and is not implemented.
- **One review finding was REFUTED, recorded so it is not "fixed" later.** A round-2 reviewer
  reported that nothing derives the confinement check from the grant set, having grepped the
  shell suite only. `tests/structure/reviewer-spawn-allow-v1.test.js` does exactly that: it maps
  each member to `agents/<name>.md` and requires the exact read trio, so widening
  `REVIEWER_TYPES` with an unconfined agent fails there.
