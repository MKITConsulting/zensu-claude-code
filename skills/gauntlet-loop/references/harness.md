# Running the Gauntlet in Claude Code

Read this before the first spawn. The method's whole value rests on critic
isolation and real inspection; both are harness mechanics, and both are easy to
break by accident.

> **What this file is and is not evidence for.** Every host-tool name here — `Agent`,
> `SendMessage`, `Explore`, `preview_start`, `Artifact`, `/loop`, `/effort` and the
> rest — is a property of the Claude Code harness, not of this plugin, and no suite in
> this repository pins any of them; treat them as known-unverified here and check the
> harness if one is missing. The Zensu-specific paragraphs below restate claims whose
> normative home is [SKILL.md](../SKILL.md) §"Inside the Zensu plugin"; of that
> section, `tests/structure/test-gauntlet-loop-skill.sh` G8-G11 pin four claims — the
> command-tool denial, the `main-v1`-only edit gate and witness, the out-of-protocol
> reviewer spawn, and the `ExitPlanMode` interception — and G15 pins two more, the
> non-Zensu MCP residue and the `agent_type` premise. This file is NOT unpinned:
> G16, G17 and G18 anchor exact sentences in THIS file, so an edit here fails the
> suite rather than passing silently. No count is given on purpose — nothing checks
> one, and the figure this line first carried was already stale when it shipped.
> Correct the normative statement first and this one
> with it, and expect the suite to tell you when you have touched a pinned line.

## Contents

- [Session setup](#session-setup)
- [Spawning roles](#spawning-roles)
- [Keeping critics clean](#keeping-critics-clean)
- [Blinding an A/B comparison](#blinding-an-ab-comparison)
- [Inspecting the real artifact](#inspecting-the-real-artifact)
- [Persistence: /loop and self-pacing](#persistence-loop-and-self-pacing)
- [Watching a long run](#watching-a-long-run)
- [Workflow: deterministic fan-out](#workflow-deterministic-fan-out)
- [What Codex does that Claude Code does differently](#what-codex-does-that-claude-code-does-differently)

## Session setup

**Effort.** The method's author recommends `ultracode` for serious runs — type
`/effort` and select it. The user can also raise the session by putting the
keyword `ultracode` in a prompt; a system-reminder confirms when it is on. The
lead cannot turn it on for itself. If a run is large and effort is unset, say so
once at charter time and let the user decide; do not silently run a fleet at
default effort.

**Model.** Opus for the lead and for anything visual or creative. A critic may
run on a cheaper tier only when its job is a mechanical gate (does the test pass,
is the number under the threshold) — never for the perceptual A/B, which is the
judgment the whole loop is built around. Pass `model` per `Agent` call.

**Session hygiene.** The article recommends a clean session. Subagents start
with no conversation history regardless, but the *lead* accumulates everything,
and unrelated skills or standing workflows can quietly redefine the bar. Do not
load skills the task does not need, and re-read the charter before each
reconcile so a drifting session cannot move the bar under you.

**Repository rules still bind.** Project `CLAUDE.md`, house conventions, commit
rules, worktree rules and approval gates survive the loop. "Keep going" is
persistence toward the goal, not new authority.

## Spawning roles

Every role is an `Agent` call. Relevant parameters:

| parameter | use in this loop |
|---|---|
| `subagent_type` | `general-purpose` for builders and integrators; a read-only type for critics (see below) |
| `name` | name every agent (`builder-lighting`, `critic-1-r3`) so `SendMessage` can reach it later |
| `run_in_background` | default `true`; pass `false` when the next step genuinely cannot start without the result — which is true for Critic 1 before Critic 2 |
| `isolation: "worktree"` | give each parallel builder its own git worktree when write scopes could touch the same files; it is auto-cleaned if unchanged |
| `model` | per-call override |

Independent spawns issued in **one message** run concurrently. Sequential
dependency (Critic 2 needs Critic 1's thesis) means separate messages.

**A new `Agent` call is a fresh context. `SendMessage` continues an existing
agent with its context intact.** That distinction is the entire critic-freshness
rule: builders get `SendMessage` (they should remember their concern), critics
never do.

**The agent's final report is not shown to the user.** Whatever a critic
concludes exists only in the lead's context until the lead writes it into the
ledger and the progress artifact.

## Keeping critics clean

A critic must be read-only. `subagent_type: "Explore"` is the right seat: its grant
removes the write tools and `Agent`, so it cannot edit, publish, or spawn a
sub-fleet. State the property, not the grant list — "no write tool, no spawn, no
publish" — and always put "inspect only, change nothing" in the packet, because an
instruction is what removes intent while a grant only removes reach.

**Inside the Zensu plugin an `Explore` critic cannot run commands at all.** The
`.*` PreToolUse capability gate denies every command-execution tool to a neutral
`host-profile-v1` child, and `Explore` is one. That is a hard difference from a bare
Claude Code session, and it moves work: the lead runs the build, the tests, the dev
server and the capture, then hands the redacted output into the packet. See "Inside the
Zensu plugin" in [SKILL.md](../SKILL.md).

If the project ships a dedicated read-only reviewer agent type, prefer it. Do
not use a `general-purpose` critic — a critic that can edit will eventually fix
what it was asked to judge, and then nobody judged it.

No agent type the Zensu plugin registers is a usable gauntlet critic. The full list
and its tool grant live in [SKILL.md](../SKILL.md) — this file deliberately does not
repeat them, because a second copy of an enumeration drifts the moment one is added,
and the first version of this paragraph was already an incomplete copy on the day it
shipped. See "Inside the Zensu plugin" there for the normative statement. The
short version is the packet protocol, not the shell: no subagent here holds one, so
that cannot be what separates them from an `Explore` critic. The reviewer types
hard-refuse any spawn that is not a complete `REVIEW PACKET v1`, and
`zensu:review-aspect` accepts only its five fixed perspectives, so none of them can
be aimed at an arbitrary artifact. Use `Explore` for every critic in this loop.

The packet handed to a critic contains the goal, the frozen bar, house rules,
the candidate, the reference, redacted gate output and the inspection recipe. It
contains no builder transcript, no rationale, no "we tried X because Y", and no
hint about which way the lead is leaning.

## Blinding an A/B comparison

Concrete recipe, because "blind it when practical" is otherwise never done:

1. Copy the candidate capture and the reference capture into a scratch
   directory under neutral names — `a.png` / `b.png`, `a.md` / `b.md`.
2. Randomize which is which per round. Keep the mapping in the lead's ledger
   only.
3. Tell the critic: "Two artifacts, A and B. Pick the better one against these
   dimensions, give evidence, then name the largest gap between them." Do not
   say which is ours.
4. Reveal the mapping only after the choice is recorded.

Randomize per round, not once per run — a fixed assignment leaks the moment a
critic sees a pattern across rounds in a shared progress page.

For images, `Read` presents the file visually to the agent, so a critic can look
at real pixels rather than at a description of them.

## Inspecting the real artifact

Never grade a summary. The tools that make real inspection cheap:

- **Web / dev server:** `preview_start` with `{name}` from `.claude/launch.json`
  (or `{url}`), then `computer{action:"screenshot"}`, `read_page`,
  `read_console_messages`, `preview_logs`, `read_network_requests`. Never run a
  dev server through Bash.
- **Responsive and theme states:** `resize_window` with `preset` mobile /
  tablet / desktop and `colorScheme` light / dark. One hero screenshot is not an
  inspection.
- **iOS:** the simulator control tool — attach, launch, screenshot, drive input.
- **Code and tests:** Bash, with the exact command frozen in the charter so
  every round is comparable.
- **Files, images, PDFs, notebooks:** `Read`.

Inside the Zensu plugin every one of these that needs a shell is **lead-only** — a
subagent's command tools are denied outright. Run them yourself and
put the redacted output in the packet: the redaction rule in
[SKILL.md](../SKILL.md) is unconditional and the packet is one of the paths it
covers, because a packet is delivered to a fresh agent and a builder that receives
one can write.

Freeze the capture conditions in the charter: URL or route, viewport, theme,
seed, fixture, warm-up, time of day in the sim, everything the result depends
on. Re-capture the baseline whenever the protocol changes, and never compare
across protocols.

## Persistence: /loop and self-pacing

`/loop` is the built-in skill for repeated agent work: `/loop 5m /some-command`
runs on an interval; **omitting the interval lets the model self-pace** via
`ScheduleWakeup`, which is the right mode here — a gauntlet round takes as long
as it takes.

`/loop` is a *persistence* mechanism, not the method. Wrap the gauntlet in it
when the user wants an unattended run that survives quiet periods, and keep the
stop conditions from step 8 authoritative: the loop ends on `BAR_MET`,
`USER_STOP`, `BUDGET_STOP`, `CONVERGED_BELOW_BAR` or `BLOCKED`, never on a round
count. End a dynamic loop with `ScheduleWakeup({stop: true})`.

Do not schedule short wakeups to poll subagents — a finished subagent
re-invokes the lead on its own. Use a long fallback (1200 s+) so the run
survives a hung agent.

**There is no `/goal` command in Claude Code.** If a `/goal` or `/wargame` skill
is installed, it is a *planning* step that produces the goal contract, invariants
and evidence bar; run it before the gauntlet and feed its output into the charter
as the frozen bar. The gauntlet is the execution loop, not the planner. In this
plugin that planner is `/zensu:wargame`, which also handles `/goal` contracts. Its
four contract parts — objective and exhaustiveness, invariants to prove or break,
evidence bar, convergence loop — map onto the charter's goal, hard gates, inspection
protocol and stop conditions, and its `RECON NEEDED` flags name the assumptions the
evidence harness has to settle before the first builder pass.

## Watching a long run

The point is a page the user can open from a phone without interrupting the run.

- **`SendUserFile`** with `display: "render"` surfaces a local HTML file inline
  without publishing anything. Make this the default; reach for publication only when
  the user asked for a page they can open elsewhere. The redaction rule below is
  unconditional and applies to this channel too.
- **`Artifact`** publishes an HTML or Markdown file to a page on claude.ai and
  redeploys to the same URL when called again with the same file path. (The harness
  documents such a page as private by default; nothing in this repository verifies
  that, so do not lean on it.) That is the phone-viewable option, and it is an
  **external write**, which `SKILL.md` lists under `Prohibited without new approval:`.
  Approval is therefore NOT a single charter-time grant. Charter approval covers the
  page's existence and location only. The first publish of any newly captured class
  of evidence — a screenshot, console output, anything derived from network
  requests, or any excerpt of product source or a diff — needs a fresh confirmation
  naming that class; a later round
  republishing the same classes does not. Never reach for it mid-run on the strength
  of "keep going". Load the `artifact-design` skill before writing the
  page. The page must be self-contained — a strict CSP blocks every external host,
  so inline CSS/JS and embed images as `data:` URIs. Mind the 16 MB ceiling when
  embedding round-by-round screenshots; downscale captures or keep only the last few
  rounds inline.
- A plain `workbench.md` in a user-approved location works when nothing visual
  needs to be shown.

Update it after each round with: the ledger row, the current capture, the
critics' verdicts, the resolution, and the budget spent. Do not write progress
files into product source unless the user designated that location.

**Redaction is unconditional; its normative home is [SKILL.md](../SKILL.md).** That
rule covers packet, ledger, resolution attachment and progress page alike — this
paragraph restates it for the publishing channel and adds nothing of its own. The
evidence feeding a round comes from
`read_console_messages`, `preview_logs`, `read_network_requests` and live
screenshots — surfaces that routinely carry session cookies, bearer tokens, API keys
and the logged-in user's data. Never embed raw network-request headers or bodies.
Strip console output containing credentials. Look at each screenshot before it goes
in. And keep third-party reference captures **local** — scratch directory and critic
packet only, never embedded in a page published to an external host.

## Workflow: deterministic fan-out

The `Workflow` tool encodes the loop as a script — `pipeline()` for
per-concern chains, `parallel()` only where a stage genuinely needs all prior
results, adversarial verify stages, loop-until-dry. It fits the gauntlet's shape
well.

**It requires explicit user opt-in** (the keyword `ultracode`, ultracode on for
the session, or the user asking for a workflow / multi-agent orchestration in
their own words). Invoking this skill authorizes ordinary `Agent` fan-out; it
does not by itself authorize `Workflow`. When the opt-in is absent, run the loop
with `Agent` calls from the lead — which also keeps the lead in the reconcile
seat, where the method wants it.

Sessions may carry a workflow size guideline (reported in a system-reminder);
respect it unless the user asks for more.

## What Codex does that Claude Code does differently

| Codex | Claude Code |
|---|---|
| `fork_turns="none"` to get a clean critic | a fresh `Agent` call is already clean; `SendMessage` is the one that carries history |
| `followup_task` to hand work back | `SendMessage` to the named builder, or a fresh `Agent` call once it has finished |
| agent slots | subagents run in the background by default; concurrency is capped by the harness, and independent spawns must share one message to actually run in parallel |
| `agents/*.yaml` interface manifest | the `SKILL.md` frontmatter `name` and `description` drive model-side discovery — but a plugin-resident skill or agent additionally loads only when `.claude-plugin/plugin.json` lists its `./skills/<name>` or `./agents/<name>.md` path |
| shared filesystem discipline by convention | `isolation: "worktree"` enforces it for parallel builders |
| — | `/loop` for unattended persistence, `Artifact` for the phone-viewable progress page, `/effort` → ultracode for run quality |
