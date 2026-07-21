---
name: verify-feature
description: >
  [Zensu] Live-verify an already-built feature against either the current local git
  worktree or a deployed preview. Discovers the changed behavior, builds a risk-ranked
  P0/P1/P2 scenario matrix, boots an isolated local runtime from a checked-in recipe (or
  the bundled Zensu monorepo adapter), drives the real UI through the pinned Playwright MCP,
  and reports DOM/data, visual, console, and network evidence. Remote mode clearly
  distinguishes deployed code from unpushed worktree changes and keeps authentication
  credential-blind through visible manual login only.
  Does not fix code or write committed tests. Use when the user asks to verify/test a
  worktree, test a feature live, run an end-to-end smoke check, validate a preview, or
  invokes /zensu:verify-feature.
---

# /zensu:verify-feature

Prove that an **already-built** feature works in a real running application, once, with
evidence. The target is either the current worktree (`local`) or an already-deployed URL
(`remote`). This workflow reports what it observes; it never patches the feature and never
turns the run into a committed regression suite.

> `/zensu:verify-feature` is a live proof. `/zensu:cover` writes durable tests.
> `/zensu:autopilot` owns the larger idea-to-PR build and repair loop.

## Arguments

Slash form: `/zensu:verify-feature [<feature>] [--flag=value ...]`.

| Arg | Required | Default | Notes |
|---|---|---|---|
| `<feature>` | no | current diff | Behavior to verify. Free text, a route, or acceptance criteria are valid. |
| `--mode=local\|remote` | no | `local` | `local` must execute code from this worktree; `remote` executes deployed code. |
| `--route=<path>` | no | derive | Initial route. Derive only when the changed router or supplied criteria make it unambiguous. |
| `--base-url=<url>` | remote only | config | Preview/staging URL. Never silently default to production. |
| `--base=<branch>` | no | repository default branch | Base used to ground the scenario matrix in the change. |
| `--config=<path>` | no | `.zensu/autopilot.yaml` | Reuse the project runtime/auth recipe when present. |

Ask one batched question for missing information that cannot be derived safely. In
particular, ask for the remote base URL and for genuinely ambiguous acceptance criteria.

## Non-negotiable boundaries

- **Report only.** Do not edit application code, alter tracked tests, commit, push, or fix a
  defect. A failed verification is useful evidence. Offer `/zensu:tdd` or
  `/zensu:cover` afterward when appropriate.
- **One feature, complete matrix.** Stay within the requested behavior, but exercise every
  P0 and P1 scenario the changed code exposes. Do not reduce verification to one happy path.
- **Explicit scope stays bounded.** When the caller says the supplied acceptance criteria are
  complete, treat them as the feature boundary. Inspect the diff only for evidence and gaps
  needed by those criteria; do not invent unrelated responsive, idempotence, error-path, or
  other matrix rows unless the changed code makes them necessary to the stated behavior or a
  safety-critical adjacent path.
- **Real interfaces.** Exercise the user-visible UI and its real backend. Never invoke
  `browser_evaluate`; it is intentionally absent from the Zensu broker because even read-only
  page code can inspect authenticated data or bypass evidence controls.
- **Credential-blind.** Never receive, read, print, paste, or interpolate a real password,
  token, cookie, API key, or storage-state content. The bundled Zensu MCP broker omits all
  cookie/storage/session getters and setters because they expose credential material. Do
  not accept an auth artifact path or run a storage-state login script; use visible manual
  browser login or report the authenticated coverage as PARTIAL.
- **Safe writes.** Local throwaway fixture creation is allowed. Remote destructive or
  externally visible actions (delete, send, publish, pay, invite) require explicit user
  confirmation even when they are part of a scenario.
- **Owned teardown only.** Stop only processes, containers, and temporary files created by
  this run. Never use broad `pkill`, shared container names, or cleanup outside the run dir.

## Phase 0 — Resolve scope and target

0. If the supplied arguments select `remote`, validate the supplied base URL entirely
   in-memory before invoking any other tool. A URL with userinfo, query, fragment, or unsafe
   plaintext transport stops immediately with a sanitized PARTIAL report. On rejection, name
   only the generic policy class, such as `query-bearing remote target rejected`; do not echo,
   transform, or report the scheme, hostname, port, path, query key, query value, fragment, or
   userinfo. Record the target only as `remote target rejected before resolution`. Do not inspect Git,
   read files, start a runtime, authenticate, or navigate after that rejection.
1. Resolve the git root and current branch. Record whether the worktree is dirty.
2. Resolve the repository default branch, then inspect both committed and uncommitted work:
   the merge-base diff through `HEAD`, plus `git diff` and `git diff --cached`.
3. Read the changed components, routes, handlers, and nearby tests. Extract user-visible
   conditions, variants, validation, empty/loading/error paths, roles, and side effects.
4. Normalize the requested feature, route(s), and acceptance criteria. If criteria were not
   supplied, derive concrete assertions from the diff and state them before execution.
5. Record the target identity in the eventual report:
   - local: worktree path, branch, and `HEAD` SHA;
   - remote: only after validation succeeds, the sanitized credential-free base URL and any
     deployment/commit identifier visible from the preview.

For a remote target, validate the URL **before echoing, navigating, or authenticating**:

- require an absolute URL with no username/password userinfo;
- reject query strings and fragments (including signed-preview/token parameters); never copy
  a rejected URL into output;
- require non-loopback `https://` in remote mode. Loopback targets belong to local mode;
- only after every validation rule succeeds, retain the credential-free origin plus normalized
  path for navigation and reporting. Retain no component of a rejected URL.

For remote authentication targets, derive `ZENSU_APP_ORIGIN` from the sanitized navigation
URL origin; never trust a recipe value independently. A configured `auth.appOrigin` must
exactly equal that derived origin or the run stops with PARTIAL before auth. Validate a
configured `auth.baseUrl` independently with the same mode-specific URL rules before use: it
must be an absolute origin with no userinfo, query, or fragment. In remote mode it must be
non-loopback HTTPS; the exact loopback exception applies only in local mode. When that auth
origin differs from the application origin, accept it
only when the selected checked-in recipe explicitly associates the auth origin with the same
selected deployment/environment and the available deployment identity verifies that
association; otherwise stop with PARTIAL before auth. Never print or report a rejected
authentication or application URL.

If preview access itself requires a secret-bearing URL, require a credential-free entry URL
plus visible browser login. Do not accept the signed URL in chat.

For a `remote` URL that passed validation, print this warning before any subsequent tool call:

> Remote mode verifies the code deployed at `<base-url>`, not unpushed or undeployed files
> in this worktree. Use local mode unless this branch is deployed to that URL.

Do not imply that a remote PASS proves the worktree diff unless the deployment identity is
confirmed.

Before any browser call, require the plugin's version-1 navigation broker declared by
`validate.navigationBroker` and configured in Claude's parent environment as
`ZENSU_VERIFY_NAVIGATION_POLICY_V1`. Run
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/playwright-mcp.sh" --check-policy <local|remote> "<validated-origin>" "<exact-page-route>" declared-safe`
as a standalone preflight for every route. The parent JSON must bind each exact page route to
its validated origin with the `declared-safe` mode described in the config contract. Contract
v1 intentionally supports no redaction-driver mode: protected or sensitive coverage that is
not proven safe stops with PARTIAL. The broker exposes an exact tool allowlist, owns the isolated browser
context, and intercepts every request before continuation. It allows only configured origins;
every navigation/redirect is rechecked for userinfo, query, and fragment. Remote mode accepts
only non-loopback HTTPS, rejects RFC1918, CGNAT, link-local/metadata, loopback, documentation,
multicast/reserved, IPv4-mapped IPv6, ULA, and non-global IPv6 addresses, rejects mixed public
and non-public DNS answers, and pins each hostname to an approved public address in Chromium to
prevent DNS rebinding. Local mode accepts literal loopback-IP origins only. Raw Playwright navigation
followed by a final-URL check is too late. A missing, invalid, mismatched, or unapproved parent
policy stops before browser use with PARTIAL; never try to configure it from a child Bash call.

## Phase 1 — Build the evidence matrix (mandatory)

Create the matrix before opening the browser. Every row names the route and setup, precise
steps, DOM/data assertion, visual assertion, expected network effect, and priority.

| Scenario | Route + setup | Steps | DOM/data | Visual | Network | Pri |
|---|---|---|---|---|---|---|
| ... | ... | ... | ... | ... | ... | P0/P1/P2 |

Enumerate these dimensions from the changed code:

- primary happy path;
- each changed state, toggle, tab, filter, sort, or variant;
- 0 / 1 / many and relevant min/max or date boundaries;
- empty, loading, validation, unauthorized, and failed-request states that can be produced
  safely through real interfaces;
- responsive, keyboard/accessibility, permissions, and theme behavior when touched.

The list above is a discovery checklist, not permission to expand an explicitly complete
feature scope. For a clean synthetic fixture with complete supplied criteria, create only rows
that prove those criteria. Extra exploratory checks must never introduce evidence failures that
change the verdict for out-of-scope behavior.

For a non-trivial feature, fan out **read-only scenario discovery** across happy paths,
states/variants, edges, error/loading, and cross-cutting behavior when an Agent/Task tool is
available. Merge and deduplicate the results in the main thread. If agent fan-out is not
available, enumerate the same dimensions in-thread and say so. Run one completeness-critic
pass: “Which condition or branch in the diff still has no scenario?” Add every real gap.

P0 is the release-blocking core and must never be capped. If time or environment limits P1
or P2, name every omitted row and the reason; omission changes the final verdict to PARTIAL
when it prevents an acceptance criterion from being proven.

## Phase 2 — Prepare the runtime

For either mode, create a collision-safe per-run directory beneath the physical git workspace
root, `$GIT_ROOT/.zensu/verify-feature-runs/<random>`, and register cleanup immediately. Reject
a symlinked `.zensu` or `verify-feature-runs` boundary. Remove only the unique leaf on cleanup.
This common `$RUN_DIR` must exist before runtime or authentication preparation.

### Local mode

Local means the application process actually uses files from the current worktree.
Set `ROOT="${CLAUDE_PLUGIN_ROOT}"` once before loading a bundled rule. Whenever
`rules/zensu-monorepo.md` says `<absolute-plugin-root>`, replace it with this
concrete absolute `ROOT`; supporting files loaded through `Read` do not receive
Claude's native placeholder substitution.

1. Inspect the explicit `--config` path or `.zensu/autopilot.yaml` as a **candidate**, using
   `../autopilot/rules/config.md`. An autopilot recipe is not automatically safe for live
   verification. Accept it only when all of these facts are explicit and internally
   consistent:
   - every service has startup and readiness commands;
   - every started resource has an explicit scoped `down` command, or remains a foreground
     child whose exact PID the run owns;
   - host ports and resource names are per-run/collision-safe inputs rather than fixed shared
     values;
   - application and authentication base URLs, fixture setup, and cleanup refer to the same
     run-specific runtime;
   - the browser base URL is either a run-specific literal or comes from a checked-in
     `validate.baseUrlCommand` executed only after readiness; its output must exactly match an
     origin already authorized in the immutable parent broker policy. Validate it again before
     navigating. A command that dynamically selects a previously unknown port is incompatible
     with the current session and requires a discovery run followed by a policy-configured restart;
   Reject fixed-port Compose stacks, shared resource names, daemonized services without
   ownership, or recipes whose teardown scope is ambiguous. Record why the candidate was
   rejected; do not execute any part of it.
2. Resolve the runtime from the first **compatible** option:
   - the accepted candidate recipe;
   - when the repository matches the Zensu monorepo markers, the bundled
     `rules/zensu-monorepo.md` adapter (including when an autopilot candidate was rejected);
   - otherwise stop with PARTIAL and list the missing startup, readiness, base URL, auth,
     fixture, isolation, and teardown facts. Never invent commands.
3. Before starting a service, register its scoped cleanup. A daemonized or shared service
   without scoped teardown is a blocker.
   Record each configured `down` command verbatim. Execute that command later as its own
   standalone Bash invocation, byte-for-byte. Do not combine it with semicolons, `&&`, pipes,
   subshells, logging, or any other cleanup; run additional run-owned cleanup separately.
4. Run readiness probes until they pass or their configured timeout expires. A sleep is not
   readiness evidence.
5. Seed only data required by the matrix, through repository-owned fixtures, typed tools, or
   the UI. Never use a hand-written raw API payload when the repository has a typed path.

### Remote mode

Use only the supplied/configured base URL. Do not boot or tear down remote infrastructure.
Keep mutations minimal and use disposable records with recognizable run-specific names. The
navigation broker from Phase 0 is mandatory for every remote route and redirect; its
absence stops before `browser_navigate` with PARTIAL.

### Authentication (both modes)

The bundled browser driver exposes no cookie, local/session-storage, or storage-state
capability. This is deliberate: the upstream `storage` capability combines state restoration
with credential getters and exporters, so enabling it would violate the credential-blind
boundary. Do not invoke `auth.loginScript`, accept `STORAGE_STATE`, add `--caps=storage`, or
try to restore browser state by another tool. A future checked-in broker may re-enable opaque
state only when it exposes a path-contained setter and hard-denies every getter/exporter.

Before authenticating or navigating to any protected route—including an initial
`browser_navigate` result that may contain a DOM snapshot—validate the selected recipe's
`validate.evidenceSafety` block using the fail-closed schema and exact-route coverage in
`../autopilot/rules/config.md`. Every route in scope must appear under the same origin target
in the immutable broker policy and be proved synthetic/pre-classified non-sensitive by
`mode: declared-safe`. If the block is absent, invalid, or
does not cover a route exactly, do not restore auth or navigate to that protected content; skip
the scenario and report PARTIAL. Final-report redaction is too late. The same boundary applies
to screenshots.

Use this order:

1. **Visible manual login:** navigate a headed browser to the login page, ask the user to
   enter credentials in that browser, and wait for confirmation. Never ask them to paste a
   credential into chat and never type it on their behalf.
2. **No safe path:** skip authenticated scenarios and report PARTIAL. Token extraction or
   `localStorage.setItem(...)` injection is forbidden, including for throwaway remote users.

## Phase 3 — Drive and observe

Load `rules/browser-verification.md` and execute the matrix against the resolved base URL.

- Drive P0, then P1, then any affordable P2 rows.
- Reset to a known state between scenarios. Use a fresh isolated context when scenario state
  can leak; re-authenticate visibly when a fresh context is required.
- After every meaningful interaction, take a semantic snapshot before selecting the next
  action. Prefer role/name/ref-based interactions over guessed CSS selectors.
- Capture and actually inspect screenshots at the checkpoints named in the matrix.
- Console and network tool results are model-visible before report redaction. Contract v1 has
  no trusted authenticated sanitizer, so do not invoke those raw tools on authenticated
  targets; mark that evidence plane PARTIAL. Direct MCP inspection is allowed only for a proven
  unauthenticated, synthetic, secret-free target such as an isolated local fixture.
- Record expected versus observed evidence while running; do not reconstruct it from memory.

Parallel execution is allowed only when each lane has an isolated browser context, its own
fixtures, and no shared mutable state. Otherwise execute sequentially. Parallelism never
reduces the evidence requirements.

## Phase 4 — Cleanup (always)

Run cleanup on PASS, FAIL, cancellation, and setup failure:

- close the browser;
- delete the run directory without touching a sibling or out-of-scope path;
- invoke every accepted recipe's configured `down` command byte-for-byte as a standalone Bash
  call; let its lease-bound controller stop only the process groups and resources it owns;
- remove only uniquely named containers/resources created by this run;
- leave the git worktree and all user-owned services intact.

## Phase 5 — Report

Use this format:

**Verdict: PASS | FAIL | PARTIAL**

| Scenario | Pri | Expected | Observed | Evidence | Result |
|---|---|---|---|---|---|
| ... | P0 | ... | ... | screenshot / snapshot / request | ✅ / ❌ / ⏭ |

- **Target:** mode, base URL, worktree/branch/SHA or deployed identity.
- **Coverage:** `N/N P0`, `N/N P1`, `N/N P2`; name every undriven row.
- **Console:** sanitized error class and bounded message, or `clean`. Redact credentials,
  tokens, cookies, authorization data, signed/query URLs, personal data, headers, and bodies;
  never copy raw console output into the report.
- **Network:** failed, missing, 4xx, or 5xx requests with method/path/status, or `clean`.
  Strip query strings/fragments and never report headers, bodies, credentials, or personal
  data.
- **Visual:** what each screenshot actually showed about layout, clipping, overlap,
  responsiveness, styling, and legibility. “Screenshot taken” is not an observation.
- **Reproduction:** exact steps and captured signal for each failure.
- **Limitations:** environment, fixture, auth, or deployment-identity gaps.

Verdict rules:

- **PASS** only when every P0 was driven and passed, every acceptance criterion has DOM/data
  **and** visual proof, and relevant console/network evidence is clean.
- **FAIL** when a driven acceptance criterion or P0 behavior is demonstrably broken.
- **PARTIAL** when setup/auth/evidence is incomplete, a required scenario was not driven, the
  remote deployment identity is uncertain, or visual inspection is missing.

End with exactly one greppable verdict. The final non-empty line must be a bare, unfenced
plain-text line with no backticks, list marker, block quote, or text after it. For a passing run,
that final line is:

VERIFY-FEATURE-VERDICT: PASS

Use the same bare form with `FAIL` or `PARTIAL` as appropriate.

## Playwright MCP preflight

This plugin ships a pinned, lockfile-backed Playwright runtime behind a Zensu capability and
navigation broker. The broker creates an isolated context and exposes only the exact operations
listed by `scripts/playwright-mcp-proxy.js`; upstream `browser_evaluate`,
`browser_run_code_unsafe`, storage/cookie/session getters, file upload/drop, raw request-detail,
route, and configuration tools are never advertised or callable. Every MCP server start
materializes a private generation from the SRI-pinned lockfile outside the plugin root;
concurrent servers never share `node_modules`. The normal npm cache remains enabled, but a
cache miss may require network access. For every required browser operation, accept either the
direct `mcp__playwright__<operation>` name or Claude's plugin namespace
`mcp__plugin_zensu_playwright__<operation>`. If the complete operation set is absent, report
that the plugin MCP server was not loaded and ask the user to restart Claude Code after
checking the plugin installation. If the browser binary is missing, require the validated
natively rendered `${CLAUDE_PLUGIN_ROOT}` path, obtain explicit approval for the networked
browser installation, then run
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/playwright-mcp.sh" install-browser` and ask the user to
restart Claude Code so the MCP server reloads. `browser_install` is not a tool in the pinned
runtime. Do not silently replace the browser driver with ad-hoc `curl` checks; that cannot
prove the UI.
