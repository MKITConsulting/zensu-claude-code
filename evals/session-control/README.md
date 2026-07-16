# Session Control Promptfoo validation

This suite validates the Claude Code Session Control v1 boundary from wrapper-owned evidence. It deliberately does not grade model prose. Every accepted result contains exactly one canonical line:

```text
[control-attestation] {"schema":"zensu.control-attestation",...}
```

The wrapper creates all 15 fields from trusted runtime artifacts: the
`system/init` session id, immutable Session Control record, resolved physical
plugin root, runtime digest, revisioned workflow state, structured host events,
isolated-fixture hashes, CLI/plugin versions, content-addressed source revision,
and process exit code. The attestation's `source_revision` always equals its
`runtime_digest`; Git identity is separate wrapper-owned provenance evidence.
The wrapper never pre-seeds Session Control by calling `SessionStart` itself.
It accepts only the record created by the real Claude process's actual
`SessionStart`, verifies that it bound the installed cache root, and proves that
the installed runtime is byte-identical to the clean source checkout at the
expected Git SHA. Any model-emitted line beginning with the reserved
prefix is rewritten as `[model-content] [control-attestation] ...` before output.
Assertions parse only the wrapper-owned line.

Every live profile provisions a fresh isolated `HOME`. From the exact clean
source SHA it creates a private no-hardlink local clone, verifies that clone's
detached HEAD and worktree, and places it below an ephemeral marketplace whose
local source is `./plugin`. The production marketplace remains pinned to its
official GitHub `v<plugin version>` ref inside both source trees. The suite then
executes the exact Claude Plugin CLI sequence `plugin marketplace add`, `plugin
install zensu@zensu --scope user`, and `plugin list --json`. Exactly one enabled,
user-scoped `zensu@zensu` entry must resolve to a physical `installPath` beneath
that HOME's Claude cache. The registry SHA, manifest version, source runtime,
installed runtime, and wrapper receipt must agree. Claude is then launched from
that isolated user registry without `--plugin-dir`; source checkout, fixture
clone, and installed cache remain distinct. All isolated fixture, HOME, cache,
stream, and barrier state is removed on exit.

Subagent evidence is structural. The normal L03 case spawns `zensu-plm` and
accepts only a nested `Bash pwd` tool/result pair whose description is the
injected `host-profile-v1` principal and whose result is the exact neutral-shell
denial. The child receives neither `main-v1` nor Session Control selectors. The
live reviewer case requires one completed
top-level `Agent`/`Task` tool-use pair for the exact Zensu reviewer. Adversarial
cases additionally require a nested tool-use event whose `parent_tool_use_id`
points to that reviewer spawn, exact attack arguments, and a matching structured
error or permission-denial result. Reviewer prose, including prose inside the
Agent result, is never evidence. The reviewer also derives a marker path only
from its injected reviewer context and performs a structured `Read`; it never
reads the Session Control record, preserving the reviewer policy. Direct hook probes belong only to the offline
contract suite and cannot satisfy a live attestation.

The model-facing main process receives no tools for main/concurrency cases and
only `Agent` for reviewer cases. Adversarial runs add an ephemeral
`review-aspect` definition whose attack tools are intentionally exposed under
the same real bare identity reported by Claude Code, so the reviewer capability
hook can deny an actual invocation. Before and
after Claude, the wrapper compares the plugin runtime digest and Git-status
digest, snapshots all plugin data, and snapshots `.zensu/state`. Plugin data may
contain only the host-created context record. Project state must remain unchanged
until Claude exits; afterward only the wrapper-created workflow-attestation file
is allowlisted. A sealed eval-only config disables optional prompt hooks that
normally write context-nudge state, so they cannot blur that invariant. Raw
stream and stderr evidence live in a private wrapper
directory, are sealed read-only after Claude exits, and are re-hashed before the
attestation is emitted.

## Profiles

- `npm run session-control:selfcheck` validates all Promptfoo configurations,
  the exact `0.121.18` dependency/lock, assertion attacks, wrapper spoof
  protection, host-only SessionStart creation, installed-cache provisioning,
  content-only context provenance, structured normal/reviewer subagent context,
  reviewer spawn/attack/denial evidence, root targeting, state/plugin-data/runtime
  snapshot rejection, and credential failure behavior without API use.
- `npm run session-control:contract` runs 37 offline contract/tamper scenarios through Promptfoo, including bare built-in reviewer identities, unknown/custom neutral identity, missing/tampered inherited-context denial, and deleted post-activation project CAS state denial at the first PreToolUse call.
- `npm run session-control:live` creates three fresh Claude sessions: main,
  structurally proven `zensu:review-aspect`, and structurally proven normal
  `zensu-plm`. The normal child must remain neutral `host-profile-v1`; its exact
  `Bash pwd` probe is accepted only when the host gate denies shell execution.
- `npm run session-control:concurrency` runs four cases at `maxConcurrency: 4`,
  repeated three times. Twelve independent processes join a dynamic barrier;
  each generation releases only after exactly four distinct, simultaneously
  live participants are ready. Post-processing requires three completed
  four-way generations, one content-addressed shared context, 12 distinct host
  session hashes, Git/source/runtime provenance in every ledger, and clean
  barrier ready/release/lock directories. Timeout, crash, duplicate identity,
  or a fifth participant fails closed.
- `npm run session-control:adversarial` probes write, workflow-state mutation,
  shell, mutating MCP/control, nested-subagent, and main-impersonation attacks.
  Every category is repeated five times and must contain the actual nested attack
  plus a real structured denial/tool-error result from the host.
- `npm run session-control:release` executes every profile and is intended only for the exact release SHA.

Live profiles require a disposable host acknowledged with `ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1`, Claude Code CLI **2.1.211**, and valid `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` credentials. They require explicit source root and expected Git SHA; the installed root is resolved only from the isolated Claude registry. Release checks for a completely clean worktree at that exact HEAD before provisioning and after the suite, including untracked runtime files. Missing credentials, a wrong/ambiguous registry root, a different SHA, a dirty checkout, runtime drift, or a mismatched `system/init` session id fails rather than skipping.

The complete trust chain and operator procedure are documented in
[`docs/session-control-release-gate.md`](../../docs/session-control-release-gate.md).

Pull requests run self-checks and the offline contract. The nightly workflow runs all live, concurrency, and adversarial profiles. A non-dry release dispatch first updates version plus immutable marketplace ref and creates the version-bump commit, then blocks its branch push until the complete suite passes against that exact clean commit SHA and SHA-bound evidence is uploaded. Merging that commit does not activate the version: publish verifies the version/ref invariant, repeats the complete gate and evidence upload against the exact `${{ github.sha }}`, and only then creates the referenced tag. That successful tag creation is go-live. Dry runs are offline previews and intentionally run neither paid live profiles nor release-evidence upload.
