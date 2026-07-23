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
For L01-L04 the wrapper never pre-seeds Session Control by calling
`SessionStart` itself. It accepts only the record created by the real Claude
process's actual `SessionStart`, verifies that it bound the installed cache root,
and proves that the installed runtime is byte-identical to the clean source
checkout at the expected Git SHA. The dedicated evidence-worker profiles L05
and L06 first register the same immutable host context through the trusted
adapter, then create only their private, bounded review-evidence leases; they do
not expose either artifact to the model. Any model-emitted line beginning with
the reserved prefix is rewritten as `[model-content] [control-attestation] ...`
before output.
Assertions parse only the wrapper-owned line.

`SessionStart` neither reads nor writes `CLAUDE_ENV_FILE`; the suite keeps any
supplied file byte-identical and rejects a runtime dependency on it. Top-level
Skill/Agent content instead receives Claude's native plugin root/data
substitution. Every stateful helper call passes only the rendered plugin-data
directory to that helper process, which validates the host-exposed
`CLAUDE_CODE_SESSION_ID` against the private record before deriving internal
selectors. That host session value is deliberately treated as non-secret and
never as a capability by itself.

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

Subagent evidence is structural and causal. Every single-child case requires
exactly one total root `Agent`/`Task` use, one later successful matching root
result, globally unique tool ids, and all child activity strictly between that
pair. The dedicated multiworker case requires exactly two independent root
spawns with distinct roles and applies the same ordered use/result envelope to
each child.
The normal L03 case spawns the plugin-scoped `zensu:zensu-plm`, derives its
marker path only from the actual injected `[zensu-host-context]`, and accepts
only one use-then-result successful `Read` of the exact wrapper-owned neutral
marker. The child receives
neither `main-v1`, plugin-root data, nor Session Control selectors. The
L04 case spawns `general-purpose`, derives its runtime digest and principal only
from injected context, performs exactly one successful `Read` of the
wrapper-owned neutral marker in an external detached Git worktree, and then
issues exactly one `Bash {command:"env"}` call whose structured capability-gate
denial is required. Seeded context, batched uses, result-before-use, duplicate
ids, extra calls, a wrong marker/command/principal, a failed Read, a generic
error, or an allowed command is rejected. The
live reviewer uses the same causal/exclusive proof. Adversarial
cases additionally require a nested tool-use event whose `parent_tool_use_id`
points to that reviewer spawn, exact attack arguments, and a matching structured
error or permission-denial result. Reviewer prose, including prose inside the
Agent result, is never evidence. The reviewer also derives a marker path only
from its injected reviewer context and performs a structured `Read`; it never
reads the Session Control record, preserving the reviewer policy. Direct hook probes belong only to the offline
contract suite and cannot satisfy a live attestation.

The model-facing main process receives no tools for main/concurrency cases and
only `Agent` for reviewer and dedicated evidence-worker cases. A dedicated
worker receives only `Read`, `Grep`, and `Glob`: the live proof requires one
successful exact-file operation with each tool, explicit path-bound denials,
and a strict raw JSON result that contains neither lease nor plugin-data
material. Adversarial runs add an ephemeral
`review-aspect` definition whose attack tools are intentionally exposed under
the same real bare identity reported by Claude Code, so the reviewer capability
hook can deny an actual invocation. Before and
after Claude, the wrapper compares the plugin runtime digest and Git-status
digest, snapshots all plugin data, and snapshots `.zensu/state`. L01-L04 plugin
data may contain only the host-created context record; L05-L06 may additionally
contain exactly one closed, wrapper-owned review-evidence lease tree. Project
state must remain unchanged until Claude exits; afterward only the
wrapper-created workflow-attestation file is allowlisted. A sealed eval-only
config disables optional prompt hooks that
normally write context-nudge state, so they cannot blur that invariant. Raw
stream and stderr evidence live in a private wrapper
directory, are sealed read-only after Claude exits, and are re-hashed before the
attestation is emitted.

## Profiles

- `npm run session-control:selfcheck` validates all Promptfoo configurations,
  the exact `0.121.18` dependency/lock, assertion attacks, wrapper spoof
  protection, host-only SessionStart creation, installed-cache provisioning,
  content-only context provenance, structured normal/reviewer subagent context,
  reviewer spawn/attack/denial evidence, root targeting,
  state/plugin-data/runtime snapshot rejection, dedicated-worker lease/result
  spoof protection, and credential failure behavior without API use.
- `npm run session-control:contract` runs 67 offline contract/tamper scenarios through Promptfoo. The original 40 retain real `SessionStart --agent` classification for plugin-scoped and exact bare reviewers, unknown agents, and PLM; scoped and bare PLM read-only boundaries with safe-subtree traversal positives plus root/implicit-cwd ancestor denials; native per-call main-helper binding without exported private selectors or `CLAUDE_ENV_FILE` mutation and with foreign/derived session rejection; a generic review-worker contract that denies every command-tool alias plus environment-enumeration, obfuscated workflow/helper strings, selectors, direct binders, and protected traversal ancestors while preserving ordinary non-command tools in safe subtrees; missing/tampered private-record denial; and deleted post-activation project CAS state denial at the first PreToolUse call. The additional 27 execute the dedicated evidence-worker contract against the real adapter, hooks, capability gate, and lease helper: exact `Read`/`Grep`/`Glob`, all other tools denied, path containment and alias attacks, lease sealing/expiry/revocation/binding, prompt injection, concurrent workers, strict `SubagentStop`, idempotent replay, collect-before-finalize denial, full-snapshot finalization, deterministic finalize/collect/close, manifest drift, sensitive/special files, and PR name-status plus changed-production coverage-set edge cases.
- `npm run session-control:upgrade` runs the real supported side-by-side
  lifecycle on macOS or Linux. It requires `v0.16.1` to resolve to exact commit
  `3e4f4ab4c1ea5c075effb743ae00af6f915ddb82` and proves that commit is an
  ancestor of the candidate SHA. It keeps one old-runtime stream
  alive for three turns around a concurrent fresh candidate process, and
  validates the fresh process's `Read`, harmless `Bash`, all matching
  `PreToolUse` hooks, exact `zensu-zensu` plugin-data record, and baseline.
  Every Read fixture contains an opaque response token that is deliberately
  absent from the prompt; the structured Read result and terminal response
  must both carry that token, so prose-only model compliance cannot satisfy
  the lifecycle proof.
  Claude runs with `--permission-mode dontAsk`, only `Read,Bash` exposed, four
  exact absolute fixture-file `Read(//...)` rules, and the one harmless
  `Bash(printf ...)` preapproval. Because Claude also auto-approves built-in
  read-only shell commands, a harness-owned `PreToolUse(Bash)` guard rejects
  every non-canonical Bash input before execution; the Bash sandbox is mandatory
  and cannot be disabled per call. The provider never bypasses permissions. The
  offline selfcheck runs a 19-row fake-provider Promptfoo matrix: one full
  positive lifecycle plus 18 fail-closed cases covering wrong roots, hook
  failures, missing/extra records, a missing guard, crashes, runtime mutation,
  wrong sessions, malformed lifecycle markers, marker races, and adversarial
  diagnostic values. Failure output contains only allowlisted categories,
  counts, byte lengths, and hashes; child-controlled structural strings and
  runtime entry names are never printed. The error allowlist is process-local
  and cannot be forged by attaching a public property to a thrown Error.
  Windows runs this deterministic matrix but is not claimed as real-host
  lifecycle coverage.
- `npm run session-control:live` creates six fresh Claude sessions: main,
  structurally proven `zensu:review-aspect`, and structurally proven normal
  `zensu:zensu-plm`, plus `general-purpose` reading a marker from an external
  detached worktree, plus one dedicated plan-review evidence worker and one
  two-worker plan-review flow. PLM remains neutral and read-only. The generic child then
  proves its exact `env` command is denied by `host-profile-v1`; neutral command
  execution is never attested as successful. Each dedicated worker proves the
  leased exact `Read`/`Grep`/`Glob` surface, structured denial of non-leased or
  root/implicit paths, strict role-bound JSON completion, private finalization
  and collection, closure, and deterministic recollection after its work
  directory is removed.
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

Authoritative Linux upgrade evidence runs on Ubuntu 24.04. Before Claude starts,
the nightly and both release gates install and verify `bubblewrap` plus `socat`,
apply Claude's documented `bwrap` AppArmor profile when unprivileged user
namespaces are restricted, and execute basic and network-namespace sandbox
probes. Any missing dependency, unexpected AppArmor state, or failed probe
stops the paid gate.

The upgrade profile additionally requires
`ZENSU_EXPECTED_CLAUDE_VERSION=2.1.211`,
`ZENSU_EXPECTED_SOURCE_ROOT=<clean-checkout>`, and
`ZENSU_EXPECTED_SOURCE_REVISION=<exact-HEAD>`. Its authoritative mode forwards
only an explicit API/OAuth token to Claude and uses an isolated `HOME`, config,
plugin cache/data, and both conventional and Claude-internal temporary
directories. `ZENSU_UPGRADE_EXISTING_LOGIN=1` is a macOS-only,
non-authoritative local diagnostic. macOS Claude.ai credentials live in the
Keychain identity selected by the default host config lookup, so this mode
leaves `CLAUDE_CONFIG_DIR` unset for authentication only. It disables user,
project, and local setting sources; pins each old/candidate process with its
exact session-local `--plugin-dir`; redirects plugin cache/data/temp; disables
session and prompt-history persistence; forwards only the non-secret `USER`
and `LOGNAME` Keychain account selectors; and denies Bash reads from the host
home through a mandatory fail-closed sandbox. Metadata-only canaries cover the
host settings, installed registry, and plugin cache before and after every
outcome. Claude may still update volatile startup/UI metadata in
`~/.claude.json`; that file is outside this non-authoritative invariant. This
diagnostic proves the real hooks and concurrent
process lifetime, but not the marketplace-registry transition, publishes no
evidence, and can never satisfy nightly or release gates. Linux and CI use the
authoritative explicit-credential mode.
The local `--plugin-dir` host may choose a different plugin-data identifier than
the installed marketplace id. Diagnostic validation discovers the single
Session Control record, requires its plugin-data directory to be one direct
child of the isolated plugin-data parent, and then verifies the signed context
against that exact directory. Authoritative installed-plugin evidence still
requires the canonical `zensu-zensu` marketplace id.

Claude's own direct-root `.in_use/<pid>` and `.orphaned_at` entries are the only
cache lifecycle metadata excluded from payload byte snapshots. The provider
requires a real `.in_use` directory, bounded numeric regular files, exactly the
owning process PID while that process is alive, and complete active-marker
removal after exit. It separately validates `.orphaned_at` as one regular,
non-symlink 13-digit epoch-millisecond file whose payload and `mtime` fall in
the bounded activation window, then requires an unchanged fingerprint. In the
authoritative installed-plugin path and the macOS existing-login diagnostic,
only the retired old root receives it while the active candidate remains
marker-free. Every other old/candidate runtime entry remains byte-immutable.
Claude 2.1.217 emits one `system/init` record per streamed user turn. The
provider therefore requires three matching init records for the three-turn old
session while also proving one unchanged OS process PID/session ID throughout;
it does not misinterpret the per-turn init records as process restarts.
Claude 2.1.217 may also add a `description` field to Bash tool input. The
upgrade guard accepts that single optional, bounded, control-character-free
display field while still requiring the byte-exact harmless command and
rejecting every executable/background/unsandboxed extension.

```bash
ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 \
ZENSU_EXPECTED_CLAUDE_VERSION=2.1.211 \
ZENSU_EXPECTED_SOURCE_ROOT="$PWD" \
ZENSU_EXPECTED_SOURCE_REVISION="$(git rev-parse HEAD)" \
ANTHROPIC_API_KEY='...' \
npm run session-control:upgrade
```

On macOS, to exercise only the current machine's existing Claude login, omit every
evidence-directory variable and run the explicitly non-authoritative diagnostic:

```bash
ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 \
ZENSU_UPGRADE_EXISTING_LOGIN=1 \
ZENSU_EXPECTED_CLAUDE_VERSION="$(claude --version | sed -nE '1s/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')" \
ZENSU_EXPECTED_SOURCE_ROOT="$PWD" \
ZENSU_EXPECTED_SOURCE_REVISION="$(git rev-parse HEAD)" \
npm run session-control:upgrade
```

The complete trust chain and operator procedure are documented in
[`docs/session-control-release-gate.md`](../../docs/session-control-release-gate.md).

Pull requests run self-checks and the offline contract. The nightly workflow runs the side-by-side upgrade, live, concurrency, and adversarial profiles. A non-dry release dispatch first updates version plus immutable marketplace ref and creates the version-bump commit, then blocks its branch push until the complete suite passes against that exact clean commit SHA and SHA-bound evidence is uploaded. Merging that commit does not activate the version: publish verifies the version/ref invariant, repeats the complete gate and evidence upload against the exact `${{ github.sha }}`, and only then creates the referenced tag. That successful tag creation is go-live. Dry runs are offline previews and intentionally run neither paid live profiles nor release-evidence upload.
