<p align="center">
  <a href="https://zensu.dev"><img src="assets/zensu-logo.svg" alt="Zensu" width="120"></a>
</p>

# Zensu Plugin for Claude Code

[![License: FSL-1.1-Apache-2.0](https://img.shields.io/badge/License-FSL--1.1--Apache--2.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.30.1-green.svg)](CHANGELOG.md)

**Turn an idea into a reviewed pull request — without babysitting the agent.**

Zensu plans the feature with you, implements it, and then puts the result
through a review panel that has to cite real file and line numbers for every
finding. What ships is tracked as a feature, not as a pile of commits, so your
product people can see progress without opening a terminal.

Any language, any stack. The implementation workflow and the review chain need
no configuration and no account; tracking features in Zensu needs the `zensu`
CLI and a Zensu account ([which skills need what](#skills-31)).

## What you get

- **A plan you approve first.** Claude Code plans; Zensu asks which delivery route to
  take and remembers a Zensu-workflow answer for the rest of the session —
  or never, when the project sets `hooks.defaultDeliveryRoute`.
  You stay in the loop once, not every turn.
- **A review the turn waits for.** Specialist reviewers run in parallel and an
  independent judge checks their blind spots. Once the implementation is marked
  complete, a Stop hook keeps the turn from ending until the review chain
  closes. The hold is bounded; why it let go is recorded in the session
  transcript, not shown in the terminal.
- **Findings you can trust.** Every finding is graded against the real source
  before anyone acts on it. What does not hold up is marked, not silently fixed.
- **Guardrails around the agent.** Gates stop it from committing a secret or
  mutating tracked product data outside a workflow, and an opt-in gate keeps it
  from writing into a sibling checkout. Those gates have a documented escape
  hatch; the gates that protect Zensu's own state and the browser consent gate
  have none ([Configuration](#configuration)).
- **Features, not commits.** Security profiles, user journeys, tiers, and
  release readiness live in a dashboard instead of in your head.
- **Work capture without duplicate entry.** With personal CLI OAuth and a
  compatible backend/CLI, the agent records the agreed goal and reports new
  committed results automatically. You accept the exact version through its web
  review link. This also works during direct implementation; it never treats
  stopping, merging or releasing as acceptance. See [automatic work capture](docs/ai-work-capture.md).

## What Zensu changes in every session

Zensu acts in every Claude Code session where the plugin is enabled, not only
when you run one of its skills. Know these before you add it to a setup you
already rely on:

- **Subagents work from an allowlist.** Every subagent that is not one of
  Zensu's own — the built-in agents such as `Explore`, `general-purpose` and
  `Plan`, your project's agents, and agents from other plugins — may call only
  Read, Grep, Glob, Edit, Write, MultiEdit, NotebookEdit, `apply_patch`, LSP,
  WebFetch, WebSearch, ToolSearch, TodoWrite, TaskCreate, TaskGet, TaskList,
  TaskUpdate, Agent, SendMessage, AskUserQuestion and three report tools (StructuredOutput,
  ReportFindings, SubagentHandback). A subagent that reports its type, other
  than a `zensu-review-*` review persona, may also run `Bash` behind an accident
  guard; the guard prevents accidents and is not a sandbox. Every MCP tool is
  denied except the two documentation tools of the Context7 plugin
  (`mcp__plugin_context7_context7__resolve-library-id` and
  `mcp__plugin_context7_context7__query-docs`) and the read tools of a Zensu MCP
  server, and so are `Skill`, `Monitor`, `PowerShell` and every other tool not
  on the list. Subagents may not read `.zensu/`, so Grep and Glob must name a
  subdirectory: a search from the project root is refused.
  `hooks.subagentShell: false` withdraws the `Bash` grant; nothing switches the
  allowlist off. Details:
  [Session control](docs/session-control.md#claude-code-workflows-subagent-safety).
- **Four agent names are taken.** A project agent named exactly `code-reviewer`,
  `review-aspect`, `review-judge` or `zensu-plm` is treated as one of Zensu's
  read-only agents: it may call only Read, Grep and Glob, plus the report tools
  that deliver its result, whatever its own `tools:` line says.
- **Context is added to every session.** Measured from Zensu 0.29.0 session
  transcripts on 2026-10-24: about 7,500 to 7,800 characters at most session starts
  (the evidence-discipline and best-solution-first rules, an orientation primer
  and the banner), about 9,100 characters on the first prompt of a session and
  on the first prompt after `/compact` or `/clear` (about 11,200 when the prompt
  carries a planning keyword), and about 1,800 to 5,300 characters on every
  later prompt. Automatic work capture, added after 0.29.0, adds about 760
  characters to every session start. The skill listing carries Zensu's skill
  descriptions on top.
  [Architecture](docs/architecture.md#context-added-to-every-session) says how
  this was measured and breaks it down per hook.
- **zen-mode is on by default.** Replies open with a one-line recap, put the
  result first, stay near eight lines and end with one next step. Say "zen off"
  or run `/zensu:zen-mode --off` to leave it for the session; set
  `hooks.zenModeDefault: false` to make it opt-in again.
- **Claude asks which delivery route to take.** After you approve a plan, Zensu
  has Claude ask whether to use Autopilot, the Zensu workflow or Pilot, or to
  implement directly; on a direct code request it asks whether to use the Zensu
  workflow. `/zensu:delivery-route` or
  `hooks.defaultDeliveryRoute` answers it ahead of time; `hooks.autoTdd: false`
  and `hooks.tddReminder: false` switch the two questions off.
- **Work capture can report your commits to Zensu.** At every session start
  Zensu tells Claude to record an agreed implementation goal in Zensu, with or
  without the Zensu workflow, through the `ai-work` commands of the `zensu` CLI
  and your personal `zensu auth login`. Once a goal is begun, a Stop hook
  reports each new clean commit for it and returns a review link where you
  accept that exact version; nothing accepts it for you. It sends the goal's
  title (at most 160 characters), its key, a criteria version or digest and the
  commit SHA, never transcripts, prompts, diffs or file lists. Neither hook has
  a key. Without a CLI that provides `ai-work` and a personal login, capture is
  reported as unavailable and the work continues.
  [Automatic work capture](docs/ai-work-capture.md).
- **The Stop hook can hold the turn.** While a Zensu workflow chain is open and
  its implementation is marked complete, Claude cannot end its turn until the
  review chain closes. That hold is bounded (`hooks.autoFixMaxRounds` plus
  three blocked stops) and is lifted by `hooks.chainEnforcer: false` or by
  `ZENSU_CHAIN=off` in the environment Claude Code starts with. A durable
  `/zensu:autopilot` run holds the turn until the run ends or blocks;
  `hooks.autopilotEnforcer: false` or `ZENSU_AUTOPILOT=off` lifts that hold.
- **A chain closes only on proof.** By default (`evidence.fullSuiteGate` and
  `evidence.acceptanceGate` both `required`) a Zensu workflow chain closes only
  after a full test-suite run that the plugin executed itself passed on the
  current tree, and after every acceptance criterion of the plan was verified
  live. Set either key to `advisory` to report the verdict without blocking,
  or set `ZENSU_FULL_SUITE_GATE=off` or `ZENSU_ACCEPTANCE_GATE=off` for one
  closing step; those two escapes are recorded in the chain's bypass ledger.
  `/zensu:full-suite` moves the full suite to a verified CI pipeline instead.
- **`node` must be on `PATH`.** The capability gate runs on every tool call and
  needs `node`. Without it every tool call is refused with only
  `zensu: reviewer capability gate unavailable`, which does not name `node`.

## Install

Requires Claude Code **2.1.296** or newer.

```bash
claude plugin marketplace add MKITConsulting/zensu-claude-code
claude plugin install zensu --scope project
```

If the install fails with `Host key verification failed` or
`Permission denied (publickey)`, Claude Code cloned the plugin over SSH. That is
its default for GitHub plugin sources, and unlike `marketplace add` the install
step has no HTTPS fallback. Force HTTPS:

```bash
CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1 claude plugin install zensu --scope project
```

Update later with:

```bash
claude plugin marketplace update zensu
claude plugin update zensu@zensu
```

Optional, for feature tracking: install zensu-cli 0.10.0 or later with
`brew install --cask mkitconsulting/tap/zensu` (upgrade with `brew upgrade --cask zensu`),
`curl -fsSL https://zensu.dev/install.sh | sh`, or on Windows
`irm https://zensu.dev/install.ps1 | iex`, then run `zensu auth login`.

Run `/zensu:setup` to configure Zensu step by step, or `/zensu:doctor` if
something is not firing.

## Try it

The first two need no Zensu account.

**Just this change** — describe what you want and approve the plan. Zensu asks
which delivery route to take: Autopilot to a reviewed pull request, the Zensu workflow with its review chain,
Pilot for a feature already tracked in Zensu, or implementing it directly.
Answer the route question with the Zensu workflow once: the session remembers that answer (a
direct, Autopilot or Pilot answer decides only that plan or request), and
`/zensu:delivery-route` or `hooks.defaultDeliveryRoute` fixes either route without asking.

**One feature, hands off** — `/zensu:autopilot` takes a plain-language idea to a
validated pull request: one planning gate, then plan → build → review → fix →
verify, unattended. It stops at a ready PR and never merges. It needs `gh` or
`glab`, logged in.

**Existing codebase** — `/zensu:ghost-scan` discovers what you already shipped
and imports it as tracked features. Needs a Zensu account.

**New product** — `/zensu:bootstrap` reads your vision doc and creates the
features, journeys, and tiers. Then `/zensu:implement KEY-1` builds the first one.
Needs a Zensu account.

## What's included

### Skills (31)

> The count is the workflow skills in these tables. The read-only diagnostics skill is documented separately in **Diagnostics** below and is intentionally kept out of these tables (32 skills are registered in `plugin.json`).

The **Needs** column says what a skill needs beyond Claude Code: "Zensu account"
means the `zensu` CLI, logged in; `gh` or `glab` means the forge CLI of your
GitHub or GitLab repository, logged in; "—" means nothing else. Nineteen skills
make no `zensu` call at all.

#### Track features in Zensu

| Skill | What it does | Needs |
|-------|--------------|-------|
| `/zensu:bootstrap` | Turn a vision document into tracked features, journeys, security profiles, and tiers | Zensu account |
| `/zensu:ghost-scan` | Scan an existing repo, discover undocumented features, and import them | Zensu account |
| `/zensu:docs` | Write code-grounded feature documentation that honestly clears the docs release gate | Zensu account |
| `/zensu:security-review` | A tracked feature's security review: classification, OWASP analysis, STRIDE threat model, release-gate check | Zensu account |
| `/zensu:pulse` | Developer journal — privacy-first tracking of your coding sessions | Zensu account |

#### Implement

| Skill | What it does | Needs |
|-------|--------------|-------|
| `/zensu:tdd` | The Zensu workflow: implement an approved plan in the main thread, verify every acceptance criterion live, then the mandatory review chain and auto-fix loop. Despite its name it runs without RED→GREEN by default; `/zensu:tdd-mode` or `hooks.tddImplementation` switches strict TDD on | — |
| `/zensu:autopilot` | Idea → validated pull request, unattended after one planning gate. Never merges or deploys | `gh` or `glab` |
| `/zensu:implement` | Implement a tracked feature through the Zensu workflow, then link its tests, sources and docs and create a revision | Zensu account |
| `/zensu:pilot` | The guided route: probes a tracked feature's real state and offers the next step, one confirmed step at a time | Zensu account and a tracked feature; `gh` or `glab` for its pull request |
| `/zensu:cover` | Backfill durable tests at the right level (unit → integration → E2E) for existing code | — (a Zensu account only when the target is a feature id) |
| `/zensu:converge` | Audit the code against the plan and flow real changes back into the spec | — |
| `/zensu:wargame` | Map a hard task move by move so a cheaper model can execute it blind | — (reads a Zensu feature when the brief names one) |
| `/zensu:gauntlet-loop` | Improve an artifact against a frozen bar under two fresh critics, arbitrating disagreement | — |

#### Review

| Skill | What it does | Needs |
|-------|--------------|-------|
| `/zensu:plan-review` | Have a tailored reviewer team revalidate a plan *before* any code is written | — |
| `/zensu:pr-team-review` | Multi-agent review of an existing GitHub or GitLab PR, published as one consolidated review | `gh` or `glab` |
| `/zensu:pr-fix-findings` | Work through every unresolved review thread on a PR and resolve it | `gh` or `glab`; its prerequisites also ask for a logged-in `zensu` CLI, though it runs no other `zensu` command |

#### Verify

| Skill | What it does | Needs |
|-------|--------------|-------|
| `/zensu:verify-feature` | Exercise the running feature and report what actually happened, for a web UI, an API, a CLI, a library, a worker, infrastructure code, an iOS or Android app, or a desktop app. Report-only. Inside a Zensu workflow chain its `--chain` mode verifies every acceptance criterion before the chain can close. [How to run it standalone](docs/verify-feature.md) | `playwright-cli` for a web UI |
| `/zensu:full-suite` | Run full test suites in the verified CI pull-request pipeline instead of locally, for this repository or this session; affected tests stay local | A GitHub.com repository and `gh` |

#### Session switches

| Skill | What it does | Needs |
|-------|--------------|-------|
| `/zensu:tdd-mode` | Switch this session between strict RED→GREEN TDD and vanilla, without editing config | — |
| `/zensu:delivery-route` | Fix this session's delivery route (Zensu workflow or direct) so the route question is not asked again this session | — |
| `/zensu:zen-mode` | Low-noise responses for working at reduced capacity. On by default; `--off` leaves it for the session | — |

#### Setup, help and other sessions

| Skill | What it does | Needs |
|-------|--------------|-------|
| `/zensu:setup` | Interactive first-run configuration | — (a Zensu account for its optional login step) |
| `/zensu:zensu-help` | Ask how Zensu or the plugin works. Read-only Q&A | — |
| `/zensu:session-trail` | See what your other Claude Code instances are doing, take a session over and then release the old one so it can be archived, and trace where a session was continued across windows and accounts | — |

#### Recovery

| Skill | What it does | Needs |
|-------|--------------|-------|
| `/zensu:recover-chain` | Repair the one review-chain state no other command can leave | — |
| `/zensu:reset-review-limit` | Grant the current review chain another auto-fix budget | — |
| `/zensu:adopt-session` | Report a refused automatic adoption after a plugin update landed mid-run and retry it by hand, re-create a vanished recorded project root, or move the session's anchor to a sibling worktree of the same repository (`--reanchor`) | — |
| `/zensu:autopilot-adopt` | Take over a durable Autopilot run whose owning session is gone | — |
| `/zensu:autopilot-release` | Free a working tree an abandoned Autopilot run is still holding | — |

#### Internal stages

You do not start these yourself: the review chain starts the first, and a work-order
launcher starts the second.

| Skill | What it does | Needs |
|-------|--------------|-------|
| `/zensu:self-review` | The terminal self-reflection stage that closes the review chain | — |
| `/zensu:work` | Run one Zensu work order in a headless worker session, reporting every stage until ready_for_merge or a block | A Zensu work order and the session token its launcher passes |

### Diagnostics — `/zensu:doctor`

A read-only health check for when something is not firing: CLI and auth, plugin
integrity, config validity (including the quoted-boolean trap, where `"true"` as
a string is silently ignored), and session state. It never writes and always
exits `0` — a red mark is a finding in the report, not a failed command. It needs
no account; with the `zensu` CLI installed it also reports the login and the
CLI version.

### Zensu next to Claude Code built-ins

| Built-in | Zensu | Use the built-in for | Use Zensu for |
|----------|-------|----------------------|---------------|
| `/security-review` | `/zensu:security-review` | A security pass over the pending changes on your branch | A tracked feature's security profile: classification, threat model, security tests and the release gate, recorded in Zensu |
| `/code-review` | the review chain, `/zensu:pr-team-review` | A review of the current diff or a PR that you start yourself | The review chain runs by itself at the end of every Zensu workflow chain, grades each finding against the source and fixes the routed ones; `/zensu:pr-team-review` publishes one consolidated multi-agent review on an open PR |
| `/doctor` | `/zensu:doctor` | Problems with the Claude Code installation itself | A hook or gate of this plugin that is not firing, its config, its CLI login and the session's workflow state |
| `/simplify` | — | Cleanups that reuse, simplify and tidy changed code | Zensu has no counterpart; the review chain reports maintainability problems but applies no cleanups on its own |
| `/goal` | `/zensu:wargame` | Keeping Claude working until a stated condition holds | Writing the move-by-move plan, and optionally the goal contract, before such a run; it plans and executes nothing |

## Configuration

Defaults are the supported configuration; you do not have to set anything.
Flags live in `~/.zensu/config.json` (global) and `.zensu/config.json` (per
project, merged over the global file key by key):

```json
{
  "hooks": {
    "pulseSession": false
  }
}
```

Not every hook can be turned off:

| | Hooks | How |
|-|-------|-----|
| **Switched off by a config key** | The banner and primer, the pulse banner, the intent router, zen-mode, both delivery-route questions, the best-solution-first reminder (main thread only), the context nudge, the worktree-keep hooks, the Session Hub receipt, the reviewer-spawn grant, the auto-fix loop, the workflow-launch recorder, the Stop backstops, the Zensu CLI write-gate and the secret scan | A `hooks.*` key, or `context.compactionNudge`, set to `false` |
| **Off unless you opt in** | The source-write gate's checks of Bash writes | `hooks.bashWriteGate: true` |
| **Bypassed only through the environment** | The TDD phase gate | `ZENSU_TDD_GATE=off` in the environment Claude Code starts with |
| **Always on while the plugin is enabled** | Session Control and the capability gate that confines subagents (`hooks.subagentShell: false` only withdraws their `Bash`), the Session Control check inside the source-write gate, evidence discipline, the plugin-data guard, the browser consent gate and its recorder, the artifact path redactor, the prompt-ledger reset, Autopilot resume context, the review-evidence hooks, the work-order hooks (inert outside a work-order session), the background-review hand-back and both automatic work-capture hooks | Disable the plugin ([Turn Zensu off or remove it](#turn-zensu-off-or-remove-it)) |

The full flag reference, the merge order, and the hook table are in
[docs/configuration.md](docs/configuration.md). [`config.example.json`](config.example.json)
shows the flags with their default values; copying it pins every default, so
your copy stops following later default changes.

## Files Zensu writes in your repository

Nothing writes an ignore rule for you, except the `.worktree-keep` line below.

| Path | Written by | Commit it? |
|------|------------|------------|
| `.zensu/config.json` | You or `/zensu:setup` | Yes, to give every clone the same settings; it overrides each developer's global file key by key |
| `.zensu/plans/`, `.zensu/logs/*_tdd-*.log` | The Zensu workflow, one plan and one progress log per chain | Optional. Committed, they are an audit trail; absolute paths in them are redacted when they are written |
| `.zensu/state/` | Zensu's hooks, per session | Never. Add `.zensu/state/` to `.gitignore` |
| `.zensu/verify-feature-runs/` | `/zensu:verify-feature`, one directory per run, removed after a clean teardown | Never |
| `.zensu/logs/witness-*.log` | Earlier releases only | Never |
| `.zensu/runtime.yaml` (older name `.zensu/autopilot.yaml`) | `/zensu:verify-feature --setup`, after you confirm | Yes: it tells `/zensu:verify-feature` and `/zensu:autopilot` how to start your app |
| `.zensu/overlays/`, `.zensu/templates/` | You | Yes: team guidance for the review skills, and your pull request body template |
| `.worktree-keep` in a Claude Desktop worktree | The worktree-keep hooks | No; Zensu lists it in the repository's `.git/info/exclude` |

## Turn Zensu off or remove it

Zensu's own keys cannot stop the always-on hooks. To stop Zensu in one
repository, disable the plugin there: `claude plugin disable zensu@zensu --scope local`
for yourself only, or `--scope project` for everyone who uses the project's
shared Claude Code settings. `claude plugin uninstall zensu@zensu --scope project`
removes a project install (the command's default scope is `user`); Claude Code
also deletes the plugin's data directory under `~/.claude/plugins/data/`
unless you pass `--keep-data`.

What stays behind:

- `~/.zensu/`: your global `config.json` and, from older releases, the retired
  `plugin-root` locator. Delete that locator only once no Claude Code session
  from an older Zensu installation is still running.
- `.zensu/` in every project you used it in, as listed above.
- `.worktree-keep` files in the root of Claude Desktop worktrees under
  `.claude/worktrees/`, and the `.worktree-keep` line in the repository's
  `.git/info/exclude`.
- `~/.claude/zensu/` (under `CLAUDE_CONFIG_DIR` when that is set): the session
  lineage ledger of `/zensu:session-trail` and the Session Hub receipts.
- The `zensu` CLI and its stored login, which are a separate install. Run
  `zensu auth logout` before you remove the CLI.

## Zensu account and CLI

The implementation workflow and the review chain need no CLI, no login, and no
Zensu account: `/zensu:tdd`, the review-aspect panel with its auto-fix loop, and
the progress log under `.zensu/logs/` run locally, and so does every skill
marked "—" in the [skill tables](#skills-31). The `zensu` CLI and an
account add the tracking layer on top — feature status, revisions, artifact
links, security findings, and release-gate validation — through the skills
marked "Zensu account".

`zensu auth login` signs the CLI in through your browser (OAuth with PKCE) and
stores the credentials for every later command. When a `zensu` call in a
session fails with an authentication error, Claude runs `zensu auth login` and
retries; the browser step approves itself while you are signed in to Zensu on
the web.

For headless environments, authenticate the CLI with an API key instead — pipe
it to the token form, since a bare `zensu auth login` opens a browser and never
reads the env var:

```bash
# ZENSU_API_KEY from your CI secrets
echo "$ZENSU_API_KEY" | zensu auth login --with-token -
```

Verify with `zensu auth status`, clear with `zensu auth logout`. A headless
`/zensu:work` session uses the session token its launcher passes in
`ZENSU_SESSION_TOKEN` and ignores any stored login.

## Data & privacy

The `zensu` CLI sends data over HTTPS to `https://api.zensu.dev`, or to your own
host (see Self-hosting). These skills, and automatic work capture, send data
through it:

| Skill | What it sends |
|-------|---------------|
| `/zensu:bootstrap` | Product name, slug and type; **the full text of your vision or plan document**; the features, journeys, tiers and security profiles derived from it |
| `/zensu:ghost-scan` | **The repository URL** and branch; per discovered feature its slug, title, component, confidence, security classification and the paths of its source, test and doc files |
| `/zensu:implement` | **A knowledge-search query** made of the feature title and key terms; linked test and source file paths; **the documentation it writes, as whole Markdown pages** (step 6); a free-text revision summary; status updates |
| `/zensu:docs` | **The documentation it writes, as whole Markdown pages** in its default wiki mode; with `--repo-file`, the path of the file it writes into your repository instead |
| `/zensu:security-review` | Classification attributes, the security tests it links, **a free-text findings summary** and approval conditions |
| `/zensu:pulse` | HEAD SHA, branch, **the absolute path of your project root**, an optional product id and, at the end, the changed file paths |
| `/zensu:pilot` | Feature status changes and release-gate checks |
| `/zensu:work` | Stage events, heartbeats, questions and follow-ups for its work order |
| Automatic work capture, any implementation task | The goal's title (at most 160 characters), its key and a criteria version or SHA-256 digest; the commit SHA of each new clean commit for that goal. Never transcripts, prompts, diffs, file lists, credentials or token usage |

`/zensu:cover` and `/zensu:wargame` only read a feature record, and only when
you name one; `/zensu:setup` and `/zensu:doctor` run `zensu auth status` and
`zensu --version`. No skill uploads source files, but documentation and
free-text summaries can quote code, signatures and endpoints. Pulse never
records error messages or any other free text. Pulse sessions are retained for
90 days by default.

### Self-hosting

Point the CLI at your own deployment with the `--api-url` flag, the
`ZENSU_API_URL` environment variable, or `zensu auth login` against your host:

```bash
export ZENSU_API_URL=https://api.example.internal
```

The plugin ships no MCP server, so there is no Zensu API or hosted-MCP endpoint
to redirect. If you operate under GDPR, CCPA, or similar regulations,
self-hosting keeps the data under your control.

### Session Hub usage feed

The plugin carries one optional hooks module, `hooks/usage-feed.ts`, for the
Zensu Session Hub, a macOS app that shows the five-hour and weekly limits of
several Claude accounts. The module writes only while the directory
`<config root>/zensu/session-hub/v1/usage/` already exists, where the config
root is `CLAUDE_CONFIG_DIR` when that names an absolute path and `~/.claude`
otherwise. The Session Hub creates that directory; the module never creates it,
so on a machine without the Session Hub nothing is written.

While the directory exists, the module writes one file per Claude Code session,
`<session id>.json`, each time Claude Code measures the session after a response
from Claude, which happens at the end of every turn, and whenever a rate-limit
window moves. It writes nothing when a session starts and nothing while a session
is idle, so a file keeps the time of its last reading. The file holds the
record's schema version, the session id, the time of the reading, and for each
window its name (`five_hour`, `seven_day`), the percentage used and the reset
time. It holds nothing else: no prompt, response, title, path, project or
account data. Each write replaces the whole file, the file stays on your
machine, and the module sends nothing anywhere. Deleting the directory stops the
feed; only a write already under way at that moment can create it once more.

The module needs Claude Code 2.1.296 or newer and uses its early-access hooks
module API, which can change between releases. Anthropic can also switch modules
of installed plugins off at any time. The feed then writes nothing, every other
Zensu hook keeps running, and the Session Hub reads the limits from Claude's
usage popover as it does without the plugin.

## Requirements

Claude Code 2.1.296 or newer, and `node` on the `PATH` of the environment that
starts Claude Code: without it, Zensu refuses every tool call, and the refusal
names only the reviewer capability gate. Zensu's hooks are
bash scripts, which macOS and Linux run as they are. On Windows, run Claude Code
inside WSL, or install Git for Windows so that Claude Code runs the hooks through
Git Bash, whichever terminal you start `claude` from. Native Windows without Git
Bash is not supported. With Git Bash, Claude Code may run shell commands through
its PowerShell tool; Zensu's shell-command gates judge those too and refuse a
PowerShell command they cannot judge, naming the Bash tool. To keep Claude on
the Bash tool, set `CLAUDE_CODE_USE_POWERSHELL_TOOL=0` in the environment that
starts Claude Code or in the `env` block of `~/.claude/settings.json`.
[Platform Support](docs/operations.md#platform-support) has the details and the
known gaps on native Windows. `/zensu:verify-feature` and the autopilot browser
driver additionally need `playwright-cli` on `PATH`
(`npm install -g @playwright/cli@0.1.21`, the version the browser consent gate
was measured against; `brew install playwright-cli` is unpinned).

Feature tracking needs zensu-cli 0.10.0 or later: older releases print only the
first 100 ghost-scan candidates and read only the first page of wiki lists.
`zensu --version` shows the installed release, and the session banner and
`/zensu:doctor` warn about an older one without blocking anything.

## Documentation

| Document | What is in it |
|----------|---------------|
| [Architecture](docs/architecture.md) | The three layers, the workflow diagram, evidence discipline, what the plugin adds to every prompt, typical flows |
| [Review chain](docs/review-chain.md) | The reviewer agents, custom repo personas, skill overlays, templates |
| [Review severity](docs/review-severity.md) | The severity scale of the review chain and how it reads next to the scales of the PR and plan reviews |
| [Gates](docs/gates.md) | The write gates, the secret scan, the plugin-data containment guard, the browser consent gate, the TDD phase gate, and the completion-time requirements-table gate |
| [Session control](docs/session-control.md) | Subagent safety, the security boundary, unbindable sessions |
| [Configuration](docs/configuration.md) | Every hook, every flag, merge order, environment variables |
| [Operations](docs/operations.md) | Upgrade path, platform support, troubleshooting |
| [TDD workflow](docs/tdd-manager-workflow.md) | The full per-step reference for the implementation workflow |
| [Verify a feature live](docs/verify-feature.md) | Running `/zensu:verify-feature` on its own: the driver for every kind of application and what each needs, consent mode with no setup at all, local and remote, `--setup` and `--attach`, the runtime recipe, the launch-time navigation policy for sessions that cannot show the prompt |
| [Evidence discipline](docs/evidence-discipline.md) | The one rule underneath everything else |
| [Worktree keep](docs/worktree-keep.md) | Why the Claude Desktop worktree pool can take a live session's directory, the `.worktree-keep` marker that stops it, how to continue in a nested worktree when it happened anyway, and how `release` lifts the marker after a takeover |
| [Best solution first](docs/best-solution-first.md) | Why the best long-term option must be in every choice you are offered, and first |
| [Automatic work capture](docs/ai-work-capture.md) | What Claude records about an agreed goal, what the Stop hook submits, and how you accept a reported version |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

See [SECURITY.md](SECURITY.md) for our responsible disclosure policy.

## License

**Functional Source License, Version 1.1, Apache 2.0 Future License**
([FSL-1.1-Apache-2.0](LICENSE)) — source-available, and every release converts
to Apache 2.0 two years after its publication.

You may use it for any Permitted Purpose: internal use, modifications, forks,
commercial projects, client work, education, research. You may not use it for a
Competing Use — offering a product or service that substitutes for the Zensu
plugin or the Zensu SaaS while the restriction is in effect.

Full text and FAQ at [fsl.software](https://fsl.software/). For commercial-use
questions outside the Permitted Purpose, contact
[contact@zensu.dev](mailto:contact@zensu.dev).

### Third-party references

One skill cites external work as the source of a *method* rather than of any text:
`/zensu:gauntlet-loop` links to
[How to Run a Gauntlet Loop](https://somethingbig.ai/gauntlet-loop) and its prompt
generator, and to [Claude-of-Duty](https://github.com/mshumer/Claude-of-Duty), in
`skills/gauntlet-loop/SKILL.md` § Provenance and
`skills/gauntlet-loop/references/quality-bars.md` § Method sources. No code, prompt
text, or asset from those sources is vendored here — the entire third-party surface
*of those two sources* is the hyperlinks themselves. Build and test dependencies
are a separate matter and are declared in `package.json`.

## Feature context retrieval

Tracked implementation loads the linked context package through
`zensu knowledge context-pack <feature-ref> --json`, then hydrates relevant items
with `zensu knowledge get <item-id> --json` and reads referenced files from the
authorized checkout. Supplementary search uses `--json` so passages are retained.
The CLI must expose `knowledge context-pack --help`; older installations report
the missing capability instead of silently falling back. See the
[context procedure](skills/implement/references/knowledge-context.md)
for truncation, access failures and evidence handoff. These reads supplement feature,
security and design context. They do not record agent usage.
