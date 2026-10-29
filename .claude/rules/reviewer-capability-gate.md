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
  `… only Read, Grep, and Glob are allowed, plus SubagentHandback or StructuredOutput to deliver the final report`.
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
- **The workflow result tool, `StructuredOutput`.** A Claude Code workflow gives an agent it
  spawns with a result schema the host tool `StructuredOutput` and hands that tool's input to
  the workflow script as the agent's result; an agent that never calls it counts as failed.
  Measured on 2026-10-11: a `zensu:review-aspect` agent spawned by a workflow with a schema was
  offered the tool, this gate denied it as outside the read trio, and the run failed.
  `WORKFLOW_RESULT_TOOL` is therefore admitted for the two `HANDBACK_PROFILES` beside the
  handback, before the `cwd` is resolved. Its input is the script's own schema, so no field set
  is checked and no path rule applies; the premise is that the tool returns data to the script
  that spawned the agent and does nothing else. The review template
  `templates/workflows/zensu-review-v1.js` rests on it: its finders and refuters run as
  `zensu:review-aspect` under `reviewer-readonly-v1`. The tool left the `HOST_NON_READ_TOOLS`
  roster; case variants and look-alike MCP names stay denied, and the evidence workers stay on
  their lease trio. **Version: `patch`** — the gate denies strictly less.

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

**Neutral children** (`host-profile-v1`) may use every tool except what reaches Zensu's own
state or runs commands outside `Bash`. Decided on 2026-10-24 after the newcomer audit of 0.27.0 (D5-01, D6-01, D7-02): the tool
ALLOWLIST that confined neutral children protected at accident level only, because `Bash` was
already granted behind a guard that is not a sandbox, while it silently took browser,
context-mode, desktop and every other MCP tool from users who had installed them. The allowlist
(`HOST_PROFILE_TOOLS`, `HOST_PROFILE_MCP_READ_TOOLS`, `hostProfileAllowance`,
`MCP_COMMAND_SEGMENT_RE`) is gone; do not reintroduce it.

`hostProfileToolViolation` and `neutralViolation` still deny, for every tool:

- protected Session Control and workflow paths and `.zensu/`, directly, and for `Grep` and
  `Glob` through a traversal root above them;
- a write below the installed plugin or its private data, an edit of a Zensu config layer, and a
  mutation of a multiply linked file, for the file-mutation tools and every tool the gate does
  not know (`mayWrite`);
- a Zensu MCP mutation (`/^mcp__.*zensu/i` without a `ZENSU_MCP_READ_RE` segment);
- the five `COMMAND_TOOLS` aliases other than `Bash`, which G8 pins, with `COMMAND_TOOL_DENY`,
  the search remedy and the main-thread tail;
- `PowerShell` (`POWERSHELL_TOOL`), because the accident guard reads Bash only; the deny names
  Bash as the way out. A PowerShell guard is a separate proposal;
- a `Monitor` call that is not a pure `ws` stream (`isMonitorStream`), and a tool the gate does
  not know whose name marks it as running commands or code (`runsCommands`), because no Zensu
  command gate sees a command run through either (§"Commands outside `Bash`").

**Known tools.** `KNOWN_TOOLS` is the former allowlist plus `Bash`, the legacy `Task` spawn tool
and the two Context7 documentation tools, and `knownTool` adds the Zensu MCP read tools. For
every other tool the gate cannot tell a read from a write, so:

- a path input that resolves inside the installed plugin, its private data or a config layer is
  denied as if it were a write (`unknownTool` in `neutralViolation`);
- any input string that names Zensu state is denied through `shellGuard.inputMention`, the
  guard's text rules (`textMention`: a protected form, a `.zensu` segment, `/proc/<pid>/environ`)
  without its shell parse. That keeps `.zensu` out of a browser or context-mode search call,
  which the allowlist used to deny outright. It also refuses a GitHub comment that merely
  mentions `.zensu/plans`; that false positive is the Bash guard's own, and it is still less than
  the old outright deny;
- an input string that is, as a whole, one of the guard's `protectedParents` (a parent directory
  of the private data, the installed plugin or the session record, below `HOME` and outside the
  project's own parents) is denied through `parentMention`, the rule the Bash guard applies to a
  path word, because a listing there shows Zensu state. Prose that merely names such a directory
  passes;
- a path input that is a multiply linked file is denied like a mutation of one.

A known tool keeps exactly its old checks, so no input the allowlist admitted is denied now.

**Commands outside `Bash`.** Every Zensu command gate (the CLI write gate, the source-write
gate, the secret scan, the browser consent gate) is registered on `Bash|PowerShell`, and the
work-order gate reads `Bash` alone, so a command run through any other tool reaches none of them.
A `Monitor` call is therefore admitted only as a `ws` stream: `isMonitorStream` fails closed on
an input that carries a `command` or no `ws`. A tool the gate does not know whose name marks it
as running commands or code is denied by name: `runsCommands` splits the last segment of the
name into words, camelCase included, and matches `COMMAND_NAME_WORDS` or a leading `run`. Both
denies name `Bash` as the way out only while `grantRefusal` holds the grant (`bashRemedy`).
`isShellCall` stays Bash-only for G8 and the unit test. Covering `Monitor` in the shell matchers
and judging an MCP command tool by its input would let both run behind the gates; that is a
matcher change, a `minor`, and a separate proposal.

**Deny texts.** Every reason starts with `DENY_PREFIX`,
`Zensu capability gate (reviewer-capability-v1) deny: `, and every `host-profile-v1` deny ends with
the switch that lifts it (`hooks.subagentShell`) or with `MAIN_THREAD_REMEDY`. The
`/zensu:doctor` `subagents:` row (`subagentBoundaryRow`, its texts in
`skills/doctor/references/coexistence.md`) states the boundary and the grant, and stays silent on
a plugin root without the capability gate.

- **Path heuristic.** `pathInputs` returns nothing for `NON_PATH_TOOLS` (`StructuredOutput`,
  `ReportFindings`, `SubagentHandback`, `AskUserQuestion`): they take no filesystem argument,
  and a `target_files` key or a quoted patch header was misread as one. Every other tool keeps
  the heuristic, MCP tools included, because a filesystem server's `read_text_file` takes a
  `path`.
- **Remedy.** The command deny and the traversal deny end with `searchRemedy`: the real,
  non-hidden subdirectories of the project root that the traversal check admits, read at deny
  time and capped at `SEARCH_EXAMPLE_LIMIT`, or a `Read` fallback when none qualifies. With
  the bare denies a subagent concluded that it could not search the tree at all.
- **Coupled sites.** `renderHostContext` in `hooks/lib/session-control-core-v1.js` names the
  boundary; `tests/structure/test-reviewer-capability-gate.sh` checks its key phrases, and
  `tests/structure/test-session-control-claude.sh` and
  `evals/session-control/tests/wrapper-selftest.sh` pin it verbatim. The prefix is pinned in the
  eval harness (`lib/contract-provider.js`, `lib/live-evidence.js`,
  `lib/evidence-worker-contract.js`, `tests/live-evidence-negative.test.js`,
  `tests/wrapper-selftest.sh`) and in the jq check of `scripts/session-control-claude-wrapper.sh`.
  C39 in `contract-provider.js` drives the admitted tools, the `Monitor` and command-tool denies,
  the mention denies and PowerShell.
  `skills/gauntlet-loop/SKILL.md` states the bound and G15 in
  `tests/structure/test-gauntlet-loop-skill.sh` pins it. `docs/multi-repo-chains-spec.md` and
  `docs/multi-repo-chains-overview.html` cite lines of this module. Operator accounts: the
  capability-gate and `subagentShell` rows of `docs/configuration.md`, the principal item and
  §"Security boundary" of `docs/session-control.md`, the reviewer-boundary paragraph and the
  custom-persona note in `docs/review-chain.md`, the two neutral-child paragraphs in
  `docs/build-workflow.md`, the neutral item in `docs/session-control-release-gate.md`,
  `skills/gauntlet-loop/references/harness.md` and `evals/session-control/README.md`.
- **Known gaps.** The mention scan reads text: a name assembled at run time and code read from a
  file pass it. The command-tool rule reads only the tool's name, so a tool that runs commands
  under an unremarkable name passes it, and a tool such as `process_image` is refused. A tool the
  gate does not know may list or search from the project root, which reaches `.zensu`, because
  denying the project root and its parents would refuse ordinary project tools. A Zensu MCP
  server registered under a name without `zensu` is not recognized, so its mutations pass as
  unknown tools; matching Zensu tool names on every server would also refuse other servers'
  tools of the same name, such as `create_wiki_page` or `create_milestone`, and is left to a
  product decision. Whether a
  subagent's `CronCreate`, `ScheduleWakeup`, `RemoteTrigger` or `TaskStop` reaches the main
  session was not measured; the gate admits all four. A path in a key the path
  heuristic does not read is judged by the mention scan alone. `SendMessage` can reach other
  local sessions, whose main thread is not confined. `zensu-codex`, `zensu-kiro` and
  `zensu-antigravity` carry their own gates and were not changed.
- **Version: `patch`.** The gate denies strictly less: every tool the allowlist admitted keeps
  its checks, and every newly admitted tool was denied outright before. The prefix and the tails
  reword denies. A bare reviewer or PLM name leaves the read-only classification unless the
  evaluation opt-in `ZENSU_SESSION_CONTROL_EVAL_BARE_IDENTITIES=1` is set, so a project agent of
  that name is gated like any neutral child, which again denies less.

**Version: `patch`.** The change lifts a deny inside an existing hook and rewords a deny
reason. No schema field, persisted strict key set, hook registration, matcher, config key or
attestation moves. The read trio and the input-shape check judge a live tool call, never
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
