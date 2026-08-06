# Session Control installed-plugin local evaluation

The local Claude Code Promptfoo profiles validate what an end user actually
runs: a plugin installed by the Claude Plugin CLI, not a source checkout passed
through `--plugin-dir`. Their side-by-side upgrade profile uses a dedicated
immutable runtime-fixture installer and makes the isolated Claude registry
select each completed old/candidate root. These profiles are local-only and
never run in GitHub Actions.

## Trust chain

1. The runner requires a clean checkout at the exact
   `ZENSU_EXPECTED_SOURCE_REVISION` Git SHA. The local release aggregate uses
   Claude Code CLI `2.1.221`; an operator may select another exact supported
   version for a side-by-side compatibility run.
2. The production marketplace entry must use the official GitHub source object
   and pin `MKITConsulting/zensu-claude-code` at the immutable `v<plugin
   version>` ref. A mutable branch source is rejected before provisioning.
3. `create-local-marketplace-fixture.js` makes a no-hardlink local clone of the
   clean source checkout, detaches it at the exact expected SHA, rechecks both
   trees for drift, and writes a separate private marketplace whose only source
   override is `./plugin`. The production marketplace inside the clone remains
   unchanged and the clone keeps the expected Git HEAD.
4. `provision-installed-plugin.sh` creates a private, isolated `HOME`, registers
   that ephemeral marketplace, installs `zensu@zensu` at user scope, and parses
   `claude plugin list --json`. It never registers the source worktree directly.
5. The install is accepted only when there is exactly one enabled user-scope
   entry, its physical `installPath` lies below the isolated Claude cache, and
   settings plus `installed_plugins.json` identify that same path and Git SHA.
6. Source and installed manifests must identify the same plugin version. Their
   Session Control runtime digests must be byte-identical; missing and additional
   runtime files both fail.
7. The wrapper launches Claude with the isolated HOME and no `--plugin-dir`.
   The real `SessionStart` must create the immutable record and bind its
   `plugin_root` to the installed cache. `source_revision` is content-addressed
   and must equal `runtime_digest`; Git SHA remains separate wrapper evidence.
   SessionStart must not read or write `CLAUDE_ENV_FILE`. Stateful model calls
   receive Claude's native installed-root/plugin-data substitutions and bind the
   host-exposed `CLAUDE_CODE_SESSION_ID` to that private record inside the helper
   process; the session value alone is never accepted as a capability.
8. The wrapper re-hashes source, installed runtime, stream, configuration, and
   state before emitting exactly one canonical control attestation. The receipt
   records the clean source SHA, source/cache roots, and both runtime digests.
9. All isolated HOME, fixture clone, cache, plugin data, evidence, and contention state is
   deleted on completion or failure.

## Behavioral proof

- The four live scenarios run a fresh main session, a real plugin-scoped
  `zensu:review-aspect`, a plugin-scoped `zensu:zensu-plm`, and a
  `general-purpose` child. The reviewer derives its marker only from injected
  `reviewer-readonly-v1` context and proves it with one structured `Read`,
  without reading the Session Control record.
- Offline and installed-plugin contract scenarios also exercise the dedicated
  `zensu:plan-review-worker` and `zensu:pr-review-worker` identities. Each has
  only `Read`, `Grep`, and `Glob`; attempts to use file mutation, task,
  messaging, nested-agent, Skill, MCP, Web, or command tools must receive the
  structured capability denial. No fallback child identity is accepted.
- Plan/PR review scenarios create a private exact-file/safe-subtree lease,
  bind each spawn's host worker id to one exact role, and collect one raw final
  JSON object with `kind` exactly `plan-review` or `pr-review`. Collection
  rejects wrong worker ids, roles, kinds, extra prose/fences/keys, malformed or
  oversized JSON, duplicate role claims, non-identical re-submissions, and
  output that was not captured through `SubagentStop` (an identical repeated
  hook delivery is idempotent). PR leases also bind the exact `core.quotePath=false`
  name-status manifest; quoted or backslash-escaped paths fail closed, and every
  inline finding must name a changed path from that manifest. Only the main
  thread materializes accepted results, and close revokes the generation on
  both success and failure.
- Lease adversarial cases cover broad/ancestor roots, symlink aliases, path
  replacement, and TOCTOU drift between create and use. Creation snapshots the
  canonical identity and content metadata of exact files and roots; every
  leased `Read`/`Grep`/`Glob` call must revalidate that snapshot and fail closed
  after drift. Reviewed repository instructions, diffs, overlays, source text,
  and refinement context are treated as untrusted data and cannot widen the
  capability or output contract.
- L03 proves the PLM's neutral-context handoff: `zensu:zensu-plm` derives the
  project root, runtime digest, and `host-profile-v1` principal only from its
  actual injected context, then performs exactly one causal use-then-result
  successful `Read` of the
  wrapper-owned neutral marker. Its agent definition and the capability gate
  both restrict it to `Read`, `Grep`, and `Glob`; it receives neither `main-v1`
  nor Session Control selectors.
- Every other neutral `host-profile-v1` child is denied all shell/command tool
  aliases before command contents are considered. This is a capability rule,
  not a token denylist: `env`, expansion, obfuscated protected paths/helpers,
  and nested interpreters cannot regain command execution. Non-command host
  tools remain available subject to the child definition and the remaining
  protected-path and mutating-Zensu checks.
- Reviewer, PLM, and neutral `Grep`/`Glob` calls must name a concrete safe
  subtree. The gate denies both protected roots and ancestors that could
  recursively expose them, uses canonical `cwd` when a traversal path is
  omitted, and rejects escaping path filters while leaving Grep content regexes
  unrestricted.
- Neutral file mutations deny the complete canonical installed-plugin and
  private plugin-data trees. Existing path segments are canonicalized for
  case-insensitive filesystems; symlink and dangling-symlink aliases resolve to
  the protected target; existing multiply linked mutation targets fail closed.
  Ordinary project files and external review reports with one link remain
  available.
- L04 proves that the neutral profile is not a blanket tool denial. A
  `general-purpose` `host-profile-v1` child derives its runtime digest and
  principal only from injected context, performs exactly one successful `Read`
  of a wrapper-owned marker in an external detached review worktree, and then
  makes exactly one `Bash {command:"env"}` probe. The real capability gate must
  return its exact structured command-denial reason. Extra calls, seeded
  context, wrong marker/principal/command, reordered results, a failed Read, or
  a successful command all fail evidence validation. Agent/Task availability
  remains governed by the child's frontmatter and Claude host permissions; the
  plugin gate adds no separate nesting restriction.
- The all-tool `PreToolUse` boundary treats canonical `cwd` as trusted host
  location metadata, not as a session authenticator, and resolves relative tool
  paths against the current directory even after `CwdChanged`. Session identity
  remains bound by the session id plus its private plugin-data record, while the
  record's immutable `project_root` remains the workflow-state anchor.
- Fresh `startup`/`clear` events create a record only for their stable project;
  cross-project reuse is rejected. `resume`/`compact` require that record and
  preserve both its project anchor and baseline CAS bytes after `CwdChanged`.
  The Autopilot recovery sibling likewise reads continuation state only from the
  record-bound project and stays silent when the binding is missing.
- Upgrade validation installs the previous release and candidate into distinct,
  unpredictable direct children of an isolated cache parent. Each immutable
  runtime root is created at its final random path; there is no predictable
  staging-to-SemVer publication rename and no existing destination is reused.
  The isolated `installed_plugins.json` registry is the publication boundary:
  it selects exactly one completed root for the next Claude process, and the
  directory name itself grants no authority. The previous release is not just
  a mutable tag lookup:
  `v0.16.1` must resolve to exact commit
  `3e4f4ab4c1ea5c075effb743ae00af6f915ddb82`, and that commit must be an
  ancestor of the exact candidate SHA. One long-lived Claude process
  completes turns both before and after a concurrent fresh candidate process;
  all three old-process results must invoke only the previous root. The fresh
  process must invoke the candidate root, pass both `Read` and a harmless `Bash`
  probe through every matching `PreToolUse` hook, and create exactly one normal
  Session Control record below the exact `zensu-zensu` plugin-data directory.
  Each Read target holds an opaque token omitted from the prompt; both the
  structured Read result and the terminal answer must contain it. A model that
  merely repeats prompt text therefore cannot forge a successful tool proof.
  Claude uses fail-closed `dontAsk` permissions, only `Read,Bash`, exact
  absolute `Read(//...)` rules for the four fixture files, and the harmless
  `Bash(printf ...)` preapproval. A harness-owned `PreToolUse(Bash)` guard
  rejects every other Bash input before execution, including background and
  unsandboxed variants; the Bash sandbox is mandatory and fail-closed.
  Permission bypass is forbidden. Before those lifecycles, a plugin-free
  `--safe-mode` Claude canary proves the explicit API/OAuth credential from an
  isolated HOME with no tools, MCP servers, settings sources, plugin, or
  session persistence. The canary runs inside outer `bubblewrap`; Bubblewrap
  reads its encoded environment from `--args` file descriptor 3, so the
  credential is never present in the process argument vector. Operator-supplied
  Anthropic base URLs, proxies, and TLS trust overrides are forbidden. The old
  and candidate processes never receive that credential: they use a random
  dummy API key and only the evaluator-created URL for a deterministic local
  Anthropic-compatible loopback backend. Never
  overwrite an already-loaded cache root or use `/reload-plugins` as part of a
  release migration. This mirrors Claude Code's documented
  [versioned-cache and running-session behavior](https://code.claude.com/docs/en/plugins-reference#plugin-caching-and-file-resolution).
- `SessionStart` payloads carrying Claude's documented `agent_type` for
  `claude --agent` use the same fail-closed principal classifier as PreToolUse:
  exact reviewers remain read-only and every other explicit identity stays
  neutral. Only a payload with neither agent field receives `main-v1`.
- The concurrency suite starts 12 independent wrapper processes. A dynamic
  barrier forms three generations of exactly four distinct live participants;
  each generation releases only after all four are ready. Duplicate identities,
  timeout, crash, fifth-participant corruption, or residual successful-run lock,
  ready, or release artifacts fail closed.
- The adversarial suite executes six reviewer attack categories five times each
  and accepts only structured nested tool attempts plus host denials/errors.

## Commands

```bash
npm run session-control:selfcheck
npm run session-control:contract

ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 \
ZENSU_EXPECTED_CLAUDE_VERSION=2.1.221 \
ZENSU_EXPECTED_SOURCE_ROOT="$PWD" \
ZENSU_EXPECTED_SOURCE_REVISION="$(git rev-parse HEAD)" \
ANTHROPIC_API_KEY='…' \
npm run session-control:release
```

The full live profiles are intentionally credential-blind beyond forwarding an
explicit credential to their Claude process. Plugin
marketplace/install/list commands run with Claude credentials removed from
their environment. The upgrade profile has a narrower split boundary: only its
plugin-free authentication canary receives the explicit credential; version,
installation, old-runtime, and candidate-runtime processes do not. Missing
credentials, CLI drift, dirty source, registry ambiguity, runtime drift, or
incomplete host evidence fails instead of skipping.
Failure diagnostics are equally credential-blind: child-controlled tool,
event, input-key, and runtime-entry names are reduced to allowlisted
categories, bounded counts/lengths, and SHA-256 values before stderr output.
Unexpected host exceptions receive the same redacted treatment.

The authoritative upgrade gate runs only on Linux. A real invocation on macOS
or another non-Linux host fails before lifecycle execution. On Windows the
provider fails even earlier, before starting any helper or Claude process, and
the deterministic selfcheck asserts that zero-launch behavior.
Local live evidence always uses an explicit API/OAuth token for the
plugin-free canary with an isolated `HOME`, config, plugin cache/data,
`TMPDIR`/`TEMP`/`TMP`, and Claude's internal `CLAUDE_CODE_TMPDIR`.
The runtime payload-byte invariant excludes only Claude's direct-root
`.in_use/<pid>` and `.orphaned_at` lifecycle metadata. The provider validates
the active marker's directory/file shape, exactly one numeric marker while a
contained process is active, and removal after process exit. The deterministic
fake additionally checks its directly observable host PID; a real Linux
process has a different PID inside its namespace. The provider also validates
`.orphaned_at` as Claude's exact 13-digit epoch-millisecond marker, ties its
value and `mtime` to the relevant activation window, and requires its
fingerprint to remain stable. In authoritative installed-plugin mode, the
active candidate remains marker-free while only the retired old root becomes
orphaned. No other old or candidate root entry may change.
On a local Ubuntu 24.04 evaluation host, the operator first installs and
verifies Claude's required `bubblewrap` and `socat` packages. PR CI retains the
same preparation and a real nested-hook integration without a model request,
so runner-image, AppArmor, or hook-environment drift fails deterministically.
That integration passes the evaluator-bound `CLAUDE_PLUGIN_DATA` and
`CLAUDE_PROJECT_DIR` values through the real hook namespace contract. The
helper applies
[Claude's documented Linux `bwrap` AppArmor profile](https://code.claude.com/docs/en/sandboxing#set-up-linux-and-wsl2)
only when the kernel reports restricted unprivileged
user namespaces, then requires both basic and network-namespace `bwrap` probes
to succeed. It also proves that terminating an outer namespace kills a
detached, TERM-ignoring descendant and that a nested namespace can isolate PID
and network state. The old and candidate Claude processes run in outer
`bubblewrap` PID/mount namespaces over the bounded writable evaluation root.
Each plugin hook then runs in a nested
user/PID/network/mount namespace with the evaluator control and trace paths
hidden. The nested hook receives only the evaluator-bound
`CLAUDE_PLUGIN_DATA` and `CLAUDE_PROJECT_DIR` values required by its contract;
an evaluator-owned wrapper records paired hook start/end evidence outside that
nested boundary. Process-tree termination, loopback-server
shutdown, and isolated-root cleanup all have to succeed before the canonical
attestation is emitted. The live gate never falls back to an unsandboxed or
uncontained process.

Real `ZENSU_UPGRADE_EXISTING_LOGIN=1` candidate execution is forbidden and
fails closed. The only existing-login profile is a deterministic, hermetic
selftest with an exact test HOME and fake Claude CLI. Its three Promptfoo rows
cover one non-synthetic positive and two host-canary failures. It publishes no
evidence and never runs in GitHub Actions. Together with the
43-row POSIX synthetic lifecycle/tamper matrix, the selfcheck executes exactly
46 deterministic Promptfoo cases. Windows executes only the zero-launch
fail-closed contract.

## Automated release ordering

GitHub Actions never invokes Promptfoo or a live model. The `Release` workflow
has two deterministic exact-SHA gates:

1. A non-dry `prepare` run bumps the plugin version and production marketplace
   source ref together, creates the release commit locally, runs
   `bash tests/run-all.sh --ci`, verifies the exact clean commit SHA, computes
   the Session Control runtime digest, and uploads deterministic SHA-bound
   evidence before pushing the release branch.
2. Landing the reviewed release commit on `main` does **not** make the new
   plugin version live. The catalog points to an as-yet unavailable tag.
3. The `publish` job reads the repository's `immutable-releases` setting with
   the separate `IMMUTABLE_RELEASES_ADMIN_TOKEN` and requires `enabled:true`.
   It verifies marketplace version and ref, rejects a pre-existing tag at
   another SHA, reruns `bash tests/run-all.sh --ci` at the exact clean
   `${{ github.sha }}`, recomputes the runtime digest, and uploads a second
   deterministic evidence artifact.
4. Immediately before publication it rechecks Immutable Releases. Publication
   uses only the job's contents-write token: create or validate an exact-SHA
   draft, attach exactly one named asset, verify its uploaded state and SHA-256
   digest, then publish the draft. A retry accepts a published release only
   when GitHub reports `immutable:true`, the tag resolves to the exact main SHA,
   and the sole asset still matches.
5. Publishing the draft creates `v<plugin version>` at `${{ github.sha }}`.
   Tag creation makes the production marketplace source resolvable and is the
   go-live event.

`dry_run: true` remains deliberately offline: deterministic tests, version
calculation, and release-note rendering still run, but it creates no release
commit, uploads no release evidence, and pushes nothing. A dry run is a
preview, never a release authorization.
