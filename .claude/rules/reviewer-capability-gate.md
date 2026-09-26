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

**Neutral children** (`host-profile-v1`) stay host-governed. Their handback runs through
`neutralViolation`: allowed with an existing `cwd`, denied with a vanished one. The suite pins
both as current behavior.

**Version: `patch`.** The change lifts a deny inside an existing hook and rewords a deny
reason. No schema field, persisted strict key set, hook registration, matcher, config key or
attestation moves. The tool allowlist and the input-shape check judge a live tool call, never
state another runtime wrote. It is the same class as the vanished-cwd change in this module.
A session minted by the previous patch release is served by this one and gets the fix without
`/zensu:adopt-session`.

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
