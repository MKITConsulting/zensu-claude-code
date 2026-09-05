# Verify-Feature Consent Flow and Guided Setup — Specification

Status: implemented on 2026-09-02 by the chain recorded in
`.zensu/plans/2026-09-02-2137_tdd-verify-consent.md`, with two deviations the plan's
Requirements table records under the never-recycle rule: AC-007 (a local/remote class lock)
was replaced by AC-018 — consent mode admits literal-loopback origins only, because
Chromium's DNS pins are passed at browser launch and a remote origin approved mid-session
could not be pinned; FR-003 (moving the eval's port-reservation helper) was replaced by FR-005
— a shipped `scripts/verify-free-port.js`, because the eval helper is a handoff proxy bound to
that harness. A review round then made consent PER ORIGIN rather than per route, because the prompt, the
hook and the broker had each been enforcing a different rule; the acceptance criteria below
carry the implemented rule, not the original one. §6.2's "local/remote lock", §6.7's
autopilot claim, §6.9's state table and §7 step 5 describe the original design; the
implemented behaviour is in `docs/gates.md` § Browser Consent Gate and `docs/verify-feature.md`
§ 0.

## 1. Problem

`/zensu:verify-feature` is designed as a standalone live proof, but outside the Zensu
monorepo it cannot start. A real run on 2026-09-02 in a consuming project ended with
`0/6 P0, 0/6 P1, 0/1 P2` and two blockers, both of which are preconditions the skill
enforces by contract rather than defects:

1. `ZENSU_VERIFY_NAVIGATION_POLICY_V1` was unset. The Playwright broker
   (`scripts/playwright-mcp-proxy.js`) reads that variable once, at MCP server start, from
   the environment of the process that launched Claude Code. Nothing user-facing sets it:
   the only carriers in the tree are the eval harness (`evals/verify-feature/run-eval.sh`)
   and the session-control eval wrapper, and `docs/` mentions the variable only through
   the eval wrapper. `README.md` mentions the skill once, in the skill table.
2. No runtime recipe resolved. `.zensu/autopilot.yaml` did not exist and the four Zensu
   monorepo markers were absent, so Phase 2 stopped with PARTIAL as designed.

Both blockers are structural. The policy channel was chosen because the parent
environment is the one channel the model cannot write to, and that choice costs every
end user a shell prefix, a port known before Claude starts, a literal loopback IP, and a
restart for every change. In the desktop app there is no shell prefix at all.

Measured on the maintainer's machine during the analysis (2026-09-02):

- The `env` block of `~/.claude/settings.json` IS inherited by MCP stdio servers: six
  running MCP servers spawned by Claude Code (desktop) carried all three keys of that
  block in their exec-time environment, and no shell rc file exported them. The docs
  research returned by the Claude Code guide claimed the opposite, citing shell-profile
  inheritance issues; the measurement is about the settings block, not the shell, and
  the measurement wins.
- `playwright-mcp.sh --check-policy` accepts a policy handed to a child process (exit 0),
  refuses an absent policy (`navigation policy mode does not match`), and refuses
  `localhost` (`local navigation policy accepts literal loopback-IP origins only`).

## 2. What it does

The feature makes `/zensu:verify-feature` work for every end user of the plugin, in the
CLI and in the desktop app, without an environment variable and without a restart:

- **Consent mode.** When no parent policy is present, the browser broker starts in a
  bounded consent mode instead of refusing everything. A PreToolUse hook on the broker's
  navigation tools asks the human, through the host's own permission prompt, before the
  browser opens a new origin or an undeclared route. The broker keeps a hard floor that
  no prompt can widen.
- **Guided setup.** When no runtime recipe exists, the skill offers to create one with the
  user instead of stopping. Setup detects the stack, proposes start, readiness, per-run
  port and teardown, confirms every value through `AskUserQuestion`, and writes the
  recipe into the repository where a pull request can review it.
- **Attach mode.** A user who already runs the app locally can point the skill at it
  (`--attach=<loopback-origin>`); no runtime is booted and the report states whether the
  running process could be proven to serve this worktree.
- **Diagnostics.** `/zensu:doctor` reports the verify readiness state, and the session
  banner mentions consent mode when it is the active mode.

The parent-environment policy stays supported. It remains the recommended mode for
unattended runs (`/zensu:autopilot`, CI) and for remote targets with elevated
sensitivity, because it is the only channel the model provably cannot reach.

## 3. Who it is for

- Every developer who installs the plugin in an ordinary web project (Vite, Next,
  Angular, a Go or Java backend with a dev server, a Compose stack) and wants a live proof
  of a feature without reading the autopilot configuration contract first.
- Desktop-app users, who have no shell prefix at all today.
- The plugin maintainer, who gets one place (`/zensu:doctor`) that says why a verify run
  cannot start.

## 4. Who it is NOT for

- Unattended runs. Autopilot and CI have no human to answer a prompt; they keep the
  environment policy and are out of scope for consent mode.
- Anyone who needs the origin allowlist to be a hard security boundary against a
  fully compromised model with Bash. Consent mode's per-session memory is a file the
  session can write (see §6.5); the environment policy is the answer there.
- Writing durable tests. That stays `/zensu:cover`.

## 5. Success criteria

- A fresh clone of a Vite or Angular project with no `.zensu/` directory reaches a
  driven P0 scenario after at most: one `AskUserQuestion` round in setup, one permission
  prompt for the app origin, and zero restarts of Claude Code.
- A user who already runs the app on a loopback port reaches a driven P0 scenario with
  `--attach`, one permission prompt, and no recipe.
- The report of every run names the consent decisions taken (origin, routes, who
  approved: prompt, memory, or environment policy) and whether worktree identity was
  proven.
- `/zensu:doctor` distinguishes: ready (consent), ready (policy), no recipe, broker not
  loaded, consent hook not registered.
- All existing verify-feature suites stay green, and every new hook, module and doc
  carries its own structure suite entry.

## 6. Design

### 6.1 Threat model recap, and what changes

The environment policy protects three things: the model cannot steer the isolated browser
to an origin nobody approved (prompt-injection exfiltration and reading foreign sites into
context), the browser cannot be used for SSRF into private or metadata ranges (remote
mode's DNS pinning and address-class rejection), and no protected DOM reaches the model
unless a human declared the route synthetic-safe (`evidenceSafety`).

Claude Code offers exactly two host-rendered confirmation channels a model cannot answer,
per the docs research of 2026-09-02 (sources: the Anthropic engineering post on auto
mode, the permission-modes docs, the 2.1.76 release notes, issue #41110):

- a PreToolUse hook returning `permissionDecision: "ask"`, which forces a human prompt
  even in `--permission-mode auto`; the classifier does not answer it;
- MCP elicitation (`elicitation/create`), supported for stdio servers since Claude Code
  2.1.76 in the CLI, and NOT in the desktop app (issue #41110 is open).

Neither claim has been exercised on this host inside this analysis; both are documented
behaviour and are listed as verification items in §10.

Consent mode therefore uses the hook prompt as the confirmation channel, keeps the
broker's floor as the hard boundary, and is designed so that elicitation can replace the
hook prompt in the CLI later without changing the prompt text or the recorded decisions.

### 6.2 Broker modes

`scripts/playwright-mcp-proxy.js` gains a third mode beside `policy` (environment JSON
present) and `deny` (today's behaviour when it is absent):

| Mode | Trigger at server start | Origin decision | Floor |
|---|---|---|---|
| `policy` | `ZENSU_VERIFY_NAVIGATION_POLICY_V1` parses | the policy targets, as today | as today |
| `consent` | variable absent AND the consent hook is registered in the broker's own `hooks/hooks.json` | every `browser_navigate` / `browser_tabs new` call that reaches the broker is treated as consented, because it passed the hook chain; the broker records the origin in an in-memory approved set and enforces sub-requests and redirects against that set | loopback `http`/`https` with a literal IP, or public `https` with DNS pinning and the existing address-class rejection; the first approved navigation locks the session to local or remote and a later navigation of the other class is refused |
| `deny` | variable absent AND the hook is not registered | as today | as today |

Rules that stay unchanged in every mode: the tool allowlist, `browser_evaluate` and all
storage getters absent, no credentials/query/fragment in navigation targets, screenshot
filenames broker-owned, `about:blank` only as the single initial page.

The structural registration check is the only proof the broker can obtain that the hook
exists; it cannot observe whether the host actually ran it. This is stated as a residual
in §6.5, not hidden in the table.

### 6.3 Consent hook pair

Two hooks, both on the matcher
`mcp__(plugin_zensu_)?playwright__browser_(navigate|tabs)`:

- **PreToolUse `pre-browser-navigation-consent.sh`.** Resolves the target URL from
  `tool_input.url` (or `tool_input.url` under `action: new` for `browser_tabs`). Applies
  the floor rules first and DENIES a target outside them, with the reason. Then consults
  the session consent memory (§6.4) and the declared route set of the selected recipe:
  a known origin with a declared route is ALLOWED silently; a new origin, or a route not
  declared synthetic-safe, returns `ask` with a reason that names the origin, the route,
  the mode (local/remote), and a sentence stating the grant the broker actually makes — the
  whole ORIGIN for the rest of the session, not the one page, because the broker stores
  `classified.origin` and checks no route afterwards. It never emits `allow` for a target the floor rejects, and every load
  fault DENIES: this is a gate, so the fail-closed direction is the sibling gates'
  direction, not the grant hook's.
- **PostToolUse `post-browser-navigation-consent.sh`.** Fires after a navigation the
  host executed and records `{origin, route, decidedBy, at}` in the session consent
  memory. A navigation reaching PostToolUse implies the PreToolUse verdict was `allow` or
  a human answered `ask` with yes.

The prompt text and the decision logic live in `hooks/lib/verify-consent-v1.js`, a
host-neutral module with a `decide(input, memory, recipe, options)` export and a
`node --test` driver, so the broker can call the same decision from elicitation later.

Main-principal scoping: the pair runs for every principal. A reviewer subagent never
holds the browser tools (their `tools:` frontmatter is Read/Grep/Glob), so no exemption
is needed and none is added.

No config flag switches the hook off. A consent hook the session can disable from
`.zensu/config.json` would let the model relax its own gate mid-session while the broker,
which reads the registration once at start, keeps trusting the chain. The environment
policy is the supported alternative, exactly as today. `ESCAPE_STEMS` in
`tests/structure/test-gauntlet-loop-skill.sh` therefore does not change.

### 6.4 Consent memory

`<project>/.zensu/state/verify-consent-<session-key>.json`, written only by the
PostToolUse hook under the workflow document's external lease, one record per
`(origin, route)`, plus `decidedBy: prompt | memory | policy`. A record carries no route set:
consent is granted per origin, so a route the record names is an audit line rather than an
input to any later decision. The reader validates the shape before use, refuses symlinks, hard
links and non-files, and requires each `at` to be the fixed-width UTC instant `toISOString()`
produces — a validity test would accept `"July 4, 2026"` and `"2026-02-31T00:00:00.000Z"`.
**No age bound against the Session Control record is implemented, and none is needed:** the file
NAME carries the session key, so a record predating this session cannot appear in it except by
being planted, and planting is already the residual §6.5 names. An earlier revision of this
paragraph asserted such a bound; nothing implemented it. It is per session by design: a new
session asks again, once per origin.

The report's `Consent` block renders these records verbatim, so a human reviewing the
report sees which prompts were answered.

### 6.5 Residuals, stated

- The memory file is in a directory the session can write through a Bash redirect
  (`bash-source-write-parse.js` carries no `.zensu` rule). A model that forges a record
  skips the prompt for that origin. The broker's floor bounds the damage to other
  loopback services in local mode and to public HTTPS origins in remote mode. This is why
  remote targets with elevated sensitivity keep the environment policy.
- The broker trusts hook execution. If the host runs with hooks disabled, consent mode
  accepts unconsented navigations within the floor. `/zensu:doctor` reports hook
  registration; it cannot report host-side execution.
- Elicitation would remove both residuals in the CLI (the broker asks, the approved set
  lives only in broker memory). It is deliberately not the shipped channel because the
  desktop app lacks it, and a feature that works in one surface and silently fails in the
  other is the failure this specification exists to remove.

### 6.6 Guided setup

Entry points: `/zensu:verify-feature --setup`, and the automatic offer inside Phase 2 when
no recipe resolves ("No runtime recipe found. Set one up now?"). Setup is a conversation,
not a generator: every value is proposed from evidence and confirmed, never invented.

Steps:

1. Detect the stack from tracked files only: `package.json` scripts and the lockfile,
   `vite.config.*`, `angular.json`, `next.config.*`, `Makefile` targets, `docker-compose*.yml`,
   `go.mod`, `build.gradle*`, `pom.xml`. Record the evidence file for each proposal.
2. Propose per service: `up`, `ready` (an HTTP probe on a path the code exposes, or a log
   line), `down` (scoped, verbatim, standalone), and the port variable the `up` command
   must honour. Per-run ports are reserved through the shipped
   `scripts/verify-port-reservation.js` (moved from `evals/verify-feature/`, behaviour
   unchanged) and passed as `ZENSU_VERIFY_PORT`. A command that cannot take a port
   variable is reported as "fixed port, shared resource" and the user decides whether to
   parameterize it; setup never rewrites project files.
3. Propose the evidence declaration: the page routes the changed code exposes, and the
   data classification. `synthetic` is proposed only when checked-in seed or fixture code
   is found; otherwise the user is told the route stays PARTIAL until declared.
4. One `AskUserQuestion` round with every proposal as a pre-filled answer the user edits.
5. Write `.zensu/runtime.yaml` (§6.7) and print the diff. Offer to commit; never commit
   unasked.

### 6.7 Recipe file

Canonical name `.zensu/runtime.yaml`; `.zensu/autopilot.yaml` stays accepted as an alias
and is tried second, so existing autopilot users change nothing. The schema is the
verify-sufficient subset of the autopilot contract in `skills/autopilot/rules/config.md`:

```yaml
version: 1
services:
  - name: app
    up:    "PORT=$ZENSU_VERIFY_PORT npm run dev"
    ready: "curl -fsS http://127.0.0.1:$ZENSU_VERIFY_PORT/"
    down:  "scoped — the supervisor stops the process group it started"
validate:
  driver: browser
  evidenceSafety:
    contractVersion: 1
    mode: declared-safe
    routes: ["/", "/login"]
    dataClassification: synthetic
    containsPersonalData: false
    containsSecrets: false
```

`validate.navigationBroker` is no longer required for consent mode; when present it is
honoured and the run reports `policy` as the decision source. The autopilot-only keys (`vcs`, `auth.loginScript`, sinks) remain optional in the same file.
**Unverified:** this section claimed Autopilot reads `runtime.yaml` first as well; a grep over
`skills/autopilot` finds no reference to that filename, so the shared-recipe claim is withdrawn
rather than restated.

### 6.8 Attach mode

`--attach=http://127.0.0.1:<port>` skips runtime preparation. Identity: the skill resolves
the listening process (`lsof -nP -iTCP:<port> -sTCP:LISTEN` where available) and compares
its working directory with the worktree; a match is reported as "worktree identity
proven", anything else as "attached runtime, identity unproven", which caps the verdict
at PARTIAL for local mode's worktree claim. Teardown never touches an attached process.

### 6.9 Diagnostics

`/zensu:doctor` gains one row in the tooling block:

| State | Row |
|---|---|
| policy present and valid | `✅ verify-feature: environment policy active (N origins)` |
| consent hook registered, broker loaded, recipe valid | `✅ verify-feature: consent mode ready` |
| consent hook registered, no recipe | `⚠️ verify-feature: consent mode ready, no runtime recipe — run /zensu:verify-feature --setup` |
| hook missing from hooks.json or broker not loaded | `❌ verify-feature: cannot start (reason)` |

The SessionStart banner adds one line when consent mode is active, silenceable by
`hooks.sessionBanner` like its siblings.

### 6.10 Unattended runs

`/zensu:autopilot` and CI keep `ZENSU_VERIFY_NAVIGATION_POLICY_V1`. Setup gains
`--print-policy`, which renders the policy JSON from the recipe and the reserved port
scheme so a CI job can export it without hand-writing JSON. The desktop-app route for a
policy is the `env` block of `~/.claude/settings.json`, which is measured to reach the
broker; docs describe it and warn against the project-level settings files, which the
session can write.

## 7. Build steps, decisions, defaults

1. **Decision module first.** `hooks/lib/verify-consent-v1.js` with `decide`, the floor
   predicates reused from the broker (extract `isPublicIpv4`, `isLoopbackHost` and the URL
   rules into `hooks/lib/verify-navigation-floor-v1.js` so broker and hook share one
   implementation; the broker requires it from its own root). Default: no new
   dependency, `node --test` driver, floor cases include the four measured bypass classes
   from the plugin-data guard's history (dangling symlink, lexical `..`, case variant,
   link-through-link do not apply to URLs; the URL classes are userinfo, query, fragment,
   IPv4-mapped IPv6, and `localhost`).
2. **Broker consent mode.** Extend `parsePolicy`'s absent branch: read
   `hooks/hooks.json` from the broker's own plugin root, look for the consent hook command,
   set `mode: 'consent'`; `assertAllowedUrl` consults the in-memory approved set and the
   floor in that mode; `context.route` and `routeWebSocket` enforce the same set.
   Default: the approved set is added to on `browser_navigate` and `browser_tabs new`
   only; redirects to a new origin are refused, not auto-approved, and the model has to
   navigate explicitly so the hook can prompt.
3. **Hook pair.** Template: `hooks/pre-write-plugin-data-guard.sh` for the fail-closed
   shape and the stdin lifecycle, not the grant hook. Register both in `hooks/hooks.json`.
   Default matcher spelled once in a shared constant consumed by the two hooks and pinned
   against `hooks.json` by the suite, the way G14 pins `WRITE_TOOLS`.
4. **Skill changes.** `skills/verify-feature/SKILL.md`: Phase 0 preflight accepts consent
   mode; Phase 2 resolves `runtime.yaml` then `autopilot.yaml`, offers setup, adds attach
   mode; Phase 5 adds the `Consent` block. New `skills/verify-feature/rules/setup.md`
   carries the setup conversation. Default: the monorepo adapter stays and is tried after
   the recipe files.
5. **Port reservation helper.** Move `evals/verify-feature/port-reservation.js` to
   `scripts/verify-port-reservation.js`; the eval imports it from there.
6. **Doctor and banner.** Wrapper exports the four states; renderer adds the row; skill
   doc adds the bullets; `P1`-style pins in `tests/structure/test-doctor.sh`.
7. **Docs.** `docs/verify-feature.md` (operator how-to: consent flow, setup, attach,
   policy for CI/desktop, the residuals), README docs-index row and skill-table wording,
   `docs/configuration.md` hook rows and count, `docs/gates.md` gate count and a
   §Consent Gate section, `docs/architecture.md` anchors, `docs/tdd-manager-workflow.md`
   cross-reference. Default: the residuals in §6.5 appear verbatim in `docs/gates.md`.
8. **Suites.** `tests/structure/test-verify-consent.sh` (hook pair end to end with a stub
   payload, memory shape refusals, floor denials, matcher pin), the module's
   `node --test` file driven from it, broker cases in `tests/structure/playwright-mcp-proxy.test.js`
   for the three modes, manifest entries in `tests/profiles/promptfoo-local-only.v1.json`,
   counts in `tests/SUITE-OVERVIEW.md`. Not added to `windows-ci.v1.json` (shards are at
   their ceilings); Windows stays unverified and is recorded as such.
9. **Release.** `minor`: the PreToolUse hook can `deny` and `ask`, which changes the
   capability set of every session an older runtime still serves (§"Runtime Lineage",
   the capability rule). No persisted schema moves; the consent memory is a new file, not
   a workflow-state field.

## 8. Out of scope

- Elicitation-based consent in the broker (blocked on desktop support; the module seam is
  built so it can be added without changing prompt text or memory shape).
- Renaming or restructuring the autopilot recipe beyond the alias.
- A redaction driver for non-synthetic routes (contract v1 stays `declared-safe` only).
- Ports of `zensu-codex`, `zensu-kiro` and `zensu-antigravity`; each host must re-decide
  whether a hook `ask` exists and reaches a human.
- Any change to `/zensu:cover`.

## 9. Requirements

| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | With `ZENSU_VERIFY_NAVIGATION_POLICY_V1` unset and the consent hook registered, the broker starts in `consent` mode and `browser_navigate` to `http://127.0.0.1:<port>/` succeeds after the PreToolUse hook returned `ask`. | spec §6.2 |
| AC-002 | With the variable unset and the consent hook absent from `hooks/hooks.json`, the broker starts in `deny` mode and every navigation is refused exactly as today. | spec §6.2 |
| AC-003 | In consent mode a navigation to a non-loopback `http` origin, a `localhost` hostname, a private-range `https` origin, or a target with userinfo, query or fragment is refused by both the hook (deny) and the broker (floor), independently. | spec §6.2, §6.3 |
| AC-004 | The PreToolUse hook returns `ask` for the first navigation to each new loopback origin, and `allow` for every navigation to an origin the session consent memory already holds, whatever its route. | spec §6.3 |
| AC-005 | The PostToolUse hook records exactly `(origin, route, decidedBy, at)` after an executed navigation — and no route set — and refuses to write when the memory path is a symlink, a non-file, or outside the session's project state directory. | spec §6.4 |
| AC-006 | A sub-request or redirect to an origin outside the broker's approved set is blocked in consent mode. | spec §6.2 |
| AC-007 | The first approved navigation locks the session to local or remote; a later navigation of the other class is refused with a reason naming the lock. | spec §6.2 |
| AC-008 | `/zensu:verify-feature` with no recipe and no `--attach` offers setup instead of ending PARTIAL, and a declined offer ends PARTIAL with the same missing-facts list as today. | spec §6.6 |
| AC-009 | Setup writes `.zensu/runtime.yaml` only after one `AskUserQuestion` round, every proposed value names its evidence file, and a value setup could not derive is left empty and reported rather than invented. | spec §6.6 |
| AC-010 | Phase 2 resolves `.zensu/runtime.yaml`, then `.zensu/autopilot.yaml`, then the monorepo adapter, in that order, and records which one was selected. | spec §6.7 |
| AC-011 | `--attach=<loopback-origin>` boots no runtime, runs no `down` command, and the report states "worktree identity proven" only when the listening process's working directory equals the worktree. | spec §6.8 |
| AC-012 | The report carries a `Consent` block listing every `(origin, route, decidedBy)` record of the run. | spec §6.4 |
| AC-013 | `/zensu:doctor` renders exactly one verify-feature row, and every state it can reach renders differently from the others — the shipped set is larger than §6.9's four. | spec §6.9 |
| AC-014 | `--setup --print-policy` renders a policy JSON that `playwright-mcp.sh --check-policy` accepts with exit 0 for every declared route. | spec §6.10 |
| AC-015 | The hook pair has no config off-switch; `ESCAPE_STEMS` and `ZENSU_BYPASS_GATE_ALLOWLIST` are unchanged. | spec §6.3 |
| AC-016 | `docs/configuration.md` hook count, every `#hooks-N` anchor and the `docs/gates.md` gate count match the registered hooks. | spec §7 step 7 |
| FR-001 | The floor predicates exist in exactly one module required by both the broker and the hook. | spec §7 step 1 |
| FR-002 | The consent decision and prompt text exist in exactly one module with a `node --test` driver. | spec §6.3 |
| FR-003 | The port reservation helper ships under `scripts/` and the eval imports it from there. | spec §7 step 5 |
| FR-004 | The release that ships the hook pair is a `minor`. | spec §7 step 9 |

## 10. Open items to verify before or during the build

- That a PreToolUse `ask` on an MCP tool prompts the human in the desktop app and in
  `--permission-mode auto` on this host (documented; not exercised here).
- That PostToolUse fires for plugin-namespaced MCP tools after a human-approved `ask`.
- Whether a permission rule allowing the tool suppresses a hook `ask`; the docs say the
  hook's `ask` wins, and the suite should pin the observed answer.
- The exact desktop-app spelling of the tool name (`mcp__plugin_zensu_playwright__…`) is
  confirmed by this session's tool list. The bare `mcp__playwright__…` spelling is NOT a
  CLI-versus-desktop distinction, which an earlier revision of this line claimed: measured
  2026-09-04, `.claude-plugin/plugin.json` declares `mcpServers: "./.mcp.json"` and that file
  names the server `playwright`, so the SAME file yields the plugin-scoped spelling when the
  plugin is loaded and the bare one when this repository is opened as a project. Both spellings
  stay in the matcher, and the bare arm's reach into a foreign server of the same key is
  recorded as a residual in `docs/gates.md` § Browser Consent Gate. What is still unmeasured is
  the prefix a RENAMED or `--plugin-dir` install produces; until that is taken, neither
  narrowing nor widening the matcher is supported by evidence.
- Windows wall clock for the new suite (unmeasured until a weekly Windows Safety run).
