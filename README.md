<p align="center">
  <a href="https://zensu.dev"><img src="assets/zensu-logo.svg" alt="Zensu" width="120"></a>
</p>

# Zensu Plugin for Claude Code

[![License: FSL-1.1-Apache-2.0](https://img.shields.io/badge/License-FSL--1.1--Apache--2.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.29.0-green.svg)](CHANGELOG.md)

**Turn an idea into a reviewed pull request — without babysitting the agent.**

Zensu plans the feature with you, implements it, and then puts the result
through a review panel that has to cite real file and line numbers for every
finding. What ships is tracked as a feature, not as a pile of commits, so your
product people can see progress without opening a terminal.

Any language, any stack. Nothing to configure, and no account needed to start.

## What you get

- **A plan you approve first.** Claude Code plans; Zensu asks which delivery route to
  take and remembers a Zensu-workflow answer for the rest of the session —
  or never, when the project sets `hooks.defaultDeliveryRoute`.
  You stay in the loop once, not every turn.
- **A review the turn waits for.** Specialist reviewers run in parallel and an
  independent judge checks their blind spots. Once the implementation is marked
  complete, a Stop hook keeps the turn from ending until the review chain
  closes. The hold is bounded; when it lets go, it writes a notice saying why.
- **Findings you can trust.** Every finding is graded against the real source
  before anyone acts on it. What does not hold up is marked, not silently fixed.
- **Guardrails around the agent.** Gates stop it from committing a secret or
  mutating tracked product data outside a workflow, and an opt-in gate keeps it
  from writing into a sibling checkout. Each one has a documented escape hatch.
- **Features, not commits.** Security profiles, user journeys, tiers, and
  release readiness live in a dashboard instead of in your head.
- **Work capture without duplicate entry.** With personal CLI OAuth and a
  compatible backend/CLI, the agent records the agreed goal and reports new
  committed results automatically. You accept the exact version through its web
  review link. This also works during direct implementation; it never treats
  stopping, merging or releasing as acceptance. See [automatic work capture](docs/ai-work-capture.md).

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

Run `/zensu:setup` for a guided first-run configuration, or `/zensu:doctor` if
something is not firing.

## Try it

**New product** — `/zensu:bootstrap` reads your vision doc and creates the
features, journeys, and tiers. Then `/zensu:implement KEY-1` builds the first one.

**Existing codebase** — `/zensu:ghost-scan` discovers what you already shipped
and imports it as tracked features.

**One feature, hands off** — `/zensu:autopilot` takes a plain-language idea to a
validated pull request: one planning gate, then plan → build → review → fix →
verify, unattended. It stops at a ready PR and never merges.

**Just this change** — describe what you want and approve the plan. Zensu asks
which delivery route to take: autopilot to a reviewed PR, the guided workflow
with its review chain, the step-by-step pilot, or implementing it directly.
Answer the route question with the Zensu workflow once: the session remembers that answer (a
direct, autopilot or pilot answer decides only that plan or request), and
`/zensu:delivery-route` or `hooks.defaultDeliveryRoute` fixes either route without asking.
A session that this one starts in Claude Desktop on the same repository takes that Zensu-workflow
answer over too.

## What's included

### Skills (31)

> The count is the workflow skills in this table. The read-only diagnostics skill is documented separately in **Diagnostics** below and is intentionally kept out of this table (32 skills are registered in `plugin.json`).

| Skill | What it does |
|-------|--------------|
| `/zensu:bootstrap` | Turn a vision document into tracked features, journeys, security profiles, and tiers |
| `/zensu:ghost-scan` | Scan an existing repo, discover undocumented features, and import them |
| `/zensu:implement` | Implement a tracked feature end to end, with artifact linking and revision tracking |
| `/zensu:tdd` | The guided implementation workflow: build, verify every acceptance criterion live, then the mandatory review chain and auto-fix loop |
| `/zensu:tdd-mode` | Switch this session between strict RED→GREEN TDD and vanilla, without editing config |
| `/zensu:delivery-route` | Fix this session's delivery route (Zensu workflow or direct) so the route question is not asked again this session |
| `/zensu:full-suite` | Run full test suites in the verified CI pull-request pipeline instead of locally, for this repository or this session; affected tests stay local |
| `/zensu:autopilot` | Idea → validated pull request, unattended after one planning gate. Never merges or deploys |
| `/zensu:pilot` | The guided counterpart to autopilot: probes a feature's real state and offers the next step |
| `/zensu:cover` | Backfill durable tests at the right level (unit → integration → E2E) for existing code |
| `/zensu:verify-feature` | Exercise the running feature and report what actually happened, for any kind of application: a web UI in a browser through `playwright-cli`, an API, a CLI, a library, a worker, infrastructure code, an iOS or Android app in a simulator or emulator, or a desktop app. Report-only. Without a launch-time policy it runs in consent mode: the permission prompt asks you once per session for each loopback origin and at every browser start for a deployed HTTPS origin, and `--setup` writes the runtime recipe with you. Inside a `/zensu:tdd` chain its `--chain` mode verifies every acceptance criterion before the chain can close. [How to run it standalone](docs/verify-feature.md) |
| `/zensu:plan-review` | Have a tailored reviewer team revalidate a plan *before* any code is written |
| `/zensu:pr-team-review` | Multi-agent review of an existing GitHub or GitLab PR, published as one consolidated review |
| `/zensu:pr-fix-findings` | Work through every unresolved review thread on a PR and resolve it |
| `/zensu:security-review` | Classification, OWASP analysis, STRIDE threat model, release-gate check |
| `/zensu:converge` | Audit the code against the plan and flow real changes back into the spec |
| `/zensu:docs` | Write code-grounded feature documentation that honestly clears the docs release gate |
| `/zensu:wargame` | Map a hard task move by move so a cheaper model can execute it blind |
| `/zensu:gauntlet-loop` | Improve an artifact against a frozen bar under two fresh critics, arbitrating disagreement |
| `/zensu:self-review` | The terminal self-reflection stage that closes the review chain |
| `/zensu:pulse` | Developer journal — privacy-first tracking of your coding sessions |
| `/zensu:session-trail` | See what your other Claude Code instances are doing, take a session over and then release the old one so it can be archived, and trace where a session was continued across windows and accounts |
| `/zensu:zen-mode` | Low-noise responses for working at reduced capacity. On by default |
| `/zensu:setup` | Interactive first-run configuration |
| `/zensu:reset-review-limit` | Grant the current review chain another auto-fix budget |
| `/zensu:recover-chain` | Repair the one review-chain state no other command can leave |
| `/zensu:adopt-session` | Report a refused automatic adoption after a plugin update landed mid-run and retry it by hand, re-create a vanished recorded project root, or move the session's anchor to a sibling worktree of the same repository (`--reanchor`) |
| `/zensu:autopilot-adopt` | Take over a durable Autopilot run whose owning session is gone |
| `/zensu:autopilot-release` | Free a working tree an abandoned Autopilot run is still holding |
| `/zensu:work` | Run one Zensu work order in a headless worker session, reporting every stage until ready_for_merge or a block |
| `/zensu:zensu-help` | Ask how Zensu or the plugin works. Read-only Q&A |

### Diagnostics — `/zensu:doctor`

A read-only health check for when something is not firing: CLI and auth, plugin
integrity, config validity (including the quoted-boolean trap, where `"true"` as
a string is silently ignored), and session state. It never writes and always
exits `0` — a red mark is a finding in the report, not a failed command.

## Configuration

Defaults are the supported configuration; you do not have to set anything. Every
hook can be turned off in `~/.zensu/config.json` (global) or
`.zensu/config.json` (per project) without forking the plugin:

```json
{
  "hooks": {
    "pulseSession": false
  }
}
```

The full flag reference, the merge order, and the hook table are in
[docs/configuration.md](docs/configuration.md). A complete file with every flag
is included as [`config.example.json`](config.example.json).

## Works without a Zensu account

The implementation workflow and the review chain need no CLI, no login, and no
network: `/zensu:tdd`, the review-aspect panel with its auto-fix loop, and the
progress log under `.zensu/logs/` all run locally.

Installing and authenticating the CLI adds the tracking layer on top — feature
status, revisions, artifact links, security findings, and release-gate
validation.

## Authentication

### OAuth Browser Login (Recommended)

No configuration needed. When you first use a Zensu tool, Claude Code opens your
browser to sign in. Tokens are cached and refreshed automatically.

### API Key (CI/CD)

For headless environments, authenticate the CLI with an API key instead — pipe
it to the token form, since a bare `zensu auth login` opens a browser and never
reads the env var:

```bash
# ZENSU_API_KEY from your CI secrets
echo "$ZENSU_API_KEY" | zensu auth login --with-token -
```

Verify with `zensu auth status`, clear with `zensu auth logout`.

## Data & privacy

The `zensu` CLI transmits **product and feature metadata** over HTTPS to
`https://api.zensu.dev`: product and feature names and descriptions, security
classifications and OWASP tags, file paths, git SHAs and branch names, vision
documents, and pulse session metadata.

It does **not** transmit source code or file contents — only paths. Pulse never
records error messages or any other free text.
Pulse sessions are retained for 90 days by default.

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
starts Claude Code: without it, Zensu refuses every tool call. Zensu's hooks are
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
| [Architecture](docs/architecture.md) | The three layers, the workflow diagram, evidence discipline, typical flows |
| [Review chain](docs/review-chain.md) | The reviewer agents, custom repo personas, skill overlays, templates |
| [Gates](docs/gates.md) | The write gates, the secret scan, the plugin-data containment guard, the browser consent gate, the TDD phase gate, and the completion-time requirements-table gate |
| [Session control](docs/session-control.md) | Subagent safety, the security boundary, unbindable sessions |
| [Configuration](docs/configuration.md) | Every hook, every flag, merge order, environment variables |
| [Operations](docs/operations.md) | Upgrade path, platform support, troubleshooting |
| [TDD workflow](docs/tdd-manager-workflow.md) | The full per-step reference for the implementation workflow |
| [Verify a feature live](docs/verify-feature.md) | Running `/zensu:verify-feature` on its own: the driver for every kind of application and what each needs, consent mode with no setup at all, local and remote, `--setup` and `--attach`, the runtime recipe, the launch-time navigation policy for sessions that cannot show the prompt |
| [Evidence discipline](docs/evidence-discipline.md) | The one rule underneath everything else |
| [Worktree keep](docs/worktree-keep.md) | Why the Claude Desktop worktree pool can take a live session's directory, the `.worktree-keep` marker that stops it, how to continue in a nested worktree when it happened anyway, and how `release` lifts the marker after a takeover |
| [Best solution first](docs/best-solution-first.md) | Why the best long-term option must be in every choice you are offered, and first |

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
