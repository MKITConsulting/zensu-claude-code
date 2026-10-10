---
paths:
  - "hooks/lib/reviewer-capability-v1.js"
  - "hooks/pre-reviewer-capability-gate.sh"
  - "tests/structure/test-reviewer-capability-gate.sh"
---

# Reviewer Capability Gate: Host Report Tool (`SubagentHandback`)

Claude Code delivers a subagent's final report to its caller only through a tool call.
Read out of the 2.1.281 bundle: for every `Agent` spawn that is not a fork, when the effective
permission mode is `auto` and a host flag is on (default on), the host appends `SubagentHandback`
to the subagent's tools AFTER the `tools:` frontmatter filter. It tells the agent to call
`SubagentHandback({message})` as its last tool call, drops any final plain text, and tells the
parent "The subagent ended without delivering a report through SubagentHandback". The input
schema is `{ message: string }`; there is no recipient parameter; the host frames the text as
untrusted agent output, and the auto-mode classifier reviews it with `onBlock: "flag"`.

**The decision.** `HOST_HANDBACK_TOOL` is admitted for exactly the two read-only profiles in
`HANDBACK_PROFILES`, `reviewer-readonly-v1` and `zensu-plm-readonly-v1`:

- **Exact name.** Case-sensitive. `SendMessage`, case variants, padded names and MCP look-alikes
  stay denied, and the suite pins each.
- **Exact input shape.** One string field, `message`, and nothing else. The admission rests on
  the premise that the tool carries text to the caller and does nothing more. The shape check
  enforces that premise instead of trusting it: a host that adds a recipient, attachment or
  path parameter fails closed rather than silently widening a read-only principal.
- **No content policing.** An empty message is left to the host's own validation. A report may
  quote protected paths or `*** Update File:` lines. `protectedAccessViolation` is NOT run on
  the handback, because `pathInputs` reads a quoted patch header as a path and would deny a
  legitimate report.
- **Decided before the `cwd` is canonicalized.** The handback resolves no path. The
  unusable-cwd deny tells the principal to report to the main thread, and under the handback
  contract this tool is the only way to do that. The bind, digest and workflow revalidation
  still run first, so every bind-failure deny still wins. `pathResolutionProfile` now also
  picks the handback profile; a new principal branch lands in both uses.
- **The deny text names the channel.** Every other tool of the two profiles is denied with
  `… only Read, Grep, and Glob are allowed, plus SubagentHandback to deliver the final report`.
  A deny that lists only the read trio steers a model away from the one call that delivers its
  report. The session-control eval harness pins that exact text in four files:
  `lib/contract-provider.js`, `lib/live-evidence.js`, `tests/live-evidence-negative.test.js`
  and `tests/wrapper-selftest.sh`.
- **Nothing else widens.** `REVIEWER_READ_TOOLS` stays exactly the read trio. The suite pins it
  and `HANDBACK_PROFILES` by their source literals; those two pins are what make the deny
  total, because the gate denies every name outside the set. The suite also drives a roster of
  host tool names found as literals in the 2.1.281 bundle (`HOST_NON_READ_TOOLS`) through the
  three reviewer types in turn and expects the deny by name. The roster is a sample, not a
  proven inventory: a tool a later host adds is denied without a suite edit, and adding its
  name to the roster makes the sweep name it too.

**Not in the frontmatter.** `agents/*.md` keep `tools: Read, Grep, Glob`. The host injects
the tool itself, after the frontmatter filter. `confinedByFrontmatter` in
`reviewer-spawn-allow-v1.js` grants a classifier-free spawn only to agents whose `tools:` line
is exactly the trio, so adding the tool there would silently drop every reviewer from the
spawn grant.

**The evidence workers are excluded on purpose.** `zensu:plan-review-worker` and
`zensu:pr-review-worker` go through `toolViolation` in `review-evidence-lease-v1.js`, which keeps
its own `ALLOWED_TOOLS` trio. Their result is read from `SubagentStop`'s
`last_assistant_message` and must be one pure JSON object. A worker that handed its JSON back
and then stopped would leave that message without the JSON, and the lease generation would
void. Measured on 51 denied `pr-review-worker` transcripts: after one to four denied handback
attempts, every one ended with its pure-JSON result as final text. Admitting the tool for
workers first needs the `SubagentStop` reader to take the result from the handback.

**Neutral children** (`host-profile-v1`) get an ALLOWLIST, not a denylist. `neutralViolation`
admits a tool only when it is in `HOST_PROFILE_TOOLS`, is named in
`HOST_PROFILE_MCP_READ_TOOLS`, or is a Zensu MCP read tool (`/^mcp__.*zensu/i` plus
`ZENSU_MCP_READ_RE`, kept from before); every other tool is denied. The six-name
`COMMAND_TOOLS` denylist and the Zensu-only MCP check it replaced let every command-executing
MCP tool through (`ctx_execute`, `ctx_execute_file`, `ctx_batch_execute`, `run_in_terminal`,
`browser_run_code_unsafe`), and the host's `Monitor`, whose `command` input is a shell script,
although the comment above the check promised neutral children no command-execution tool at
all. Their handback is on the list and still passes the `cwd`
resolution first: allowed with an existing `cwd`, denied with a vanished one.

- **Sized from transcripts.** Measured on 2026-10-06 over the local subagent transcripts under
  `~/.claude/projects`, all projects: 8,159 typed neutral transcripts with 276,590 tool calls.
  The list the fix was specified with (`Read`, `Grep`, `Glob`, `Edit`, `Write`, `MultiEdit`,
  `NotebookEdit`, `WebFetch`, `WebSearch`, `ToolSearch`, `TodoWrite`, `StructuredOutput`,
  `SubagentHandback`, `AskUserQuestion`) gained `LSP` (1,315 calls in 776 transcripts), `Agent`
  (108 in 70; a child spawned by a child is classified by this same gate, and the suite pins
  the allowance), `SendMessage` (132 in 81; gauntlet-loop builders coordinate through it), the
  task-list tools `TaskCreate`, `TaskGet`, `TaskList` and `TaskUpdate` (the newer `TodoWrite`,
  pinned as kept before), `ReportFindings` (a report channel like `StructuredOutput`) and
  `apply_patch` (path-checked like the other file tools, pinned before). None of them runs
  code, and every filesystem argument of an admitted tool still goes through the path checks.
- **Named read-only MCP tools: only the two Context7 documentation tools.** They reach no
  local state. Deliberately NOT named: `ctx_search` (it reads an index other principals
  filled, a read no path check can see), the browser and preview tools (a `file://`
  navigation reads protected state, and `javascript_tool` and `browser_run_code_unsafe` run
  code), and the desktop session tools (they read other sessions' transcripts). The `mcp__`
  prefix test is case-sensitive, so `MCP__zensu__…` is not a Zensu read tool.
- **Why not the minimum fix.** Denying only MCP tools whose last segment matches
  `MCP_COMMAND_SEGMENT_RE` leaves host command tools outside `COMMAND_TOOLS` open — `Monitor`
  runs a shell command — and every MCP server whose code path has no telling name. Measured
  cost on the same transcripts: the minimum fix newly denies 24,354 calls in 1,334
  transcripts, the allowlist 32,033 calls in 1,671. The 551 transcripts only the allowlist
  affects are browser automation (134), context-mode search and indexing (229), desktop
  session tools (170), one inventory connector (42), `Skill` (18), `TaskStop` (11) and
  `Monitor` (5), with overlaps. `MCP_COMMAND_SEGMENT_RE` now only picks the deny text: a
  command-executing MCP tool gets the command deny and its remedy.
- **Path heuristic.** `pathInputs` returns nothing for `NON_PATH_TOOLS` (`StructuredOutput`,
  `ReportFindings`, `SubagentHandback`, `AskUserQuestion`): they take no filesystem argument,
  and a `target_files` key or a quoted patch header was misread as one. Every other tool keeps
  the heuristic, MCP tools included, because `ctx_execute_file` takes a `path`.
- **Remedy.** The command deny and the traversal deny end with `searchRemedy`: the real,
  non-hidden subdirectories of the project root that the traversal check admits, read at deny
  time and capped at `SEARCH_EXAMPLE_LIMIT`, or a `Read` fallback when none qualifies. With
  the bare denies a subagent concluded that it could not search the tree at all.
- **Coupled sites.** `renderHostContext` in `hooks/lib/session-control-core-v1.js` enumerates
  both sets, and `tests/structure/test-reviewer-capability-gate.sh` parses that sentence back
  and compares it with the module's exports. The same sentence is pinned in
  `tests/structure/test-session-control-claude.sh` and
  `evals/session-control/tests/wrapper-selftest.sh`. The deny texts are pinned in
  `evals/session-control/lib/contract-provider.js`; `evals/session-control/lib/live-evidence.js`
  matches the command deny by prefix. `skills/gauntlet-loop/SKILL.md` states the bound and G15
  in `tests/structure/test-gauntlet-loop-skill.sh` pins it. `docs/multi-repo-chains-spec.md`
  and `docs/multi-repo-chains-overview.html` cite lines of this module. Operator accounts of
  the allowlist: the capability-gate row in `docs/configuration.md`, the principal item and
  §"Security boundary" in `docs/session-control.md`, the reviewer-boundary paragraph and the
  custom-persona note in `docs/review-chain.md`, the two neutral-child paragraphs in
  `docs/tdd-manager-workflow.md`, the neutral item in `docs/session-control-release-gate.md`,
  and `skills/gauntlet-loop/references/harness.md`.
- **Known gaps.** `SendMessage` can reach other local sessions, whose main thread is not
  confined; that is a prompt-injection path, not a capability this gate grants. `LSP`
  `workspaceSymbol` searches the whole workspace, `.zensu` included, but only for symbols of
  source files, and `.zensu` holds JSON, logs and Markdown. A host tool added or renamed later
  is denied until the list names it, by design. `zensu-codex`, `zensu-kiro` and
  `zensu-antigravity` carry their own gates and were not changed.
- **Version: `minor`.** The hook now refuses tool calls it used to allow, so it changes the
  capability set of every session a newer installation would serve, which
  `.claude/rules/runtime-lineage.md` makes the breaking test. The earlier changes to this
  module were `patch` because they denied strictly less; this one denies strictly more.

**Version: `patch`.** The change lifts a deny inside an existing hook and rewords a deny
reason. No schema field, persisted strict key set, hook registration, matcher, config key or
attestation moves. The tool allowlist and the input-shape check judge a live tool call, never
state another runtime wrote. It is the same class as the vanished-cwd change in this module.
That classifies this change alone. Whether a running session is served after the upgrade
depends on the class of the release that carries it, which is the strictest class among all
of that release's commits — see `.claude/rules/runtime-lineage.md`.

**Re-measuring the host.** `tests/structure/test-reviewer-capability-gate.sh` reads every
Claude Code host bundle it finds: `claude` on `PATH`, and on macOS every desktop-app bundle
under `~/Library/Application Support/Claude/claude-code/`. It takes each bundle's
`// Version:` marker and, from 2.1.269 on (the oldest local build measured to carry the
name), requires the quoted literal of `HOST_HANDBACK_TOOL`. A host that renames or drops the
tool fails there, and a synthetic control proves the check can fail. CI runners carry no host
bundle, so CI prints a SKIP line; the check fails loudly only where the host is installed. On
a failure, read the new bundle for the report tool's name and input schema, then update
`HOST_HANDBACK_TOOL`, the shape check, the docs the suite scans, and this file together.

**Known gaps.**

- **The hook payload itself was not captured.** A headless probe could not run. The shape
  check rests on three observations: the host schema, the host building `tool_input` from the
  call's input, and 791 of 791 handback `tool_use` blocks in 332 local transcripts carrying
  exactly `message`. If a host adds an input key, every reviewer report is denied again. The
  host cross-check does not see that case; the deny reason in the reviewer transcript names it.
- **Only `auto` mode injects the tool.** In other modes the final plain text is delivered and
  this branch is never reached.
- **No ports.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` carry their own gates.

Operator-facing accounts that move with this decision: `docs/session-control.md` (the
`SubagentHandback` item), `docs/gates.md` §"Reviewer-Spawn Grant" and §"Vanished Working
Directory", the capability-gate row in `docs/configuration.md`, the reviewer-boundary paragraph
in `docs/review-chain.md`, the PLM row in `docs/operations.md`, and the L03 item in
`docs/session-control-release-gate.md`. The suite requires the literal in `session-control.md`,
`gates.md`, `configuration.md` and `review-chain.md`.
