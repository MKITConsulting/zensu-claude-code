<p align="center">
  <a href="https://zensu.dev"><img src="assets/zensu-logo.svg" alt="Zensu" width="120"></a>
</p>

# Zensu Plugin for Claude Code

[![License: FSL-1.1-Apache-2.0](https://img.shields.io/badge/License-FSL--1.1--Apache--2.0-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.17.3-green.svg)](CHANGELOG.md)

**Turn an idea into a reviewed pull request — without babysitting the agent.**

Zensu plans the feature with you, implements it, and then puts the result
through a review panel that has to cite real file and line numbers for every
finding. What ships is tracked as a feature, not as a pile of commits, so your
product people can see progress without opening a terminal.

Any language, any stack. Nothing to configure, and no account needed to start.

## What you get

- **A plan you approve first.** Claude Code plans; Zensu asks once whether to
  run the guided workflow. You stay in the loop exactly once, not every turn.
- **A review that cannot be skipped.** Five specialist reviewers run in
  parallel, an independent judge checks their blind spots, and a Stop hook makes
  sure the chain actually finished before the turn ends.
- **Findings you can trust.** Every finding is graded against the real source
  before anyone acts on it. What does not hold up is marked, not silently fixed.
- **Guardrails around the agent.** Gates stop it from writing into a sibling
  checkout, committing a secret, or mutating tracked product data outside a
  workflow. Each one has a documented escape hatch.
- **Features, not commits.** Security profiles, user journeys, tiers, and
  release readiness live in a dashboard instead of in your head.

## Install

Requires Claude Code **2.1.211** or newer.

```bash
claude plugin marketplace add MKITConsulting/zensu-claude-code
claude plugin install zensu --scope project
```

Update later with:

```bash
claude plugin marketplace update zensu
claude plugin update zensu@zensu
```

Optional, for feature tracking: install the CLI with
`curl -fsSL https://zensu.dev/install.sh | sh` and run `zensu auth login`.

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
whether to run the guided workflow with its review chain.

## What's included

### Skills (22)

> The count is the workflow skills in this table. The read-only diagnostics skill is documented separately in **Diagnostics** below and is intentionally kept out of this table (23 skills are registered in `plugin.json`).

| Skill | What it does |
|-------|--------------|
| `/zensu:bootstrap` | Turn a vision document into tracked features, journeys, security profiles, and tiers |
| `/zensu:ghost-scan` | Scan an existing repo, discover undocumented features, and import them |
| `/zensu:implement` | Implement a tracked feature end to end, with artifact linking and revision tracking |
| `/zensu:tdd` | The guided implementation workflow: build, then the mandatory review chain and auto-fix loop |
| `/zensu:autopilot` | Idea → validated pull request, unattended after one planning gate. Never merges or deploys |
| `/zensu:pilot` | The guided counterpart to autopilot: probes a feature's real state and offers the next step |
| `/zensu:cover` | Backfill durable tests at the right level (unit → integration → E2E) for existing code |
| `/zensu:verify-feature` | Drive the real UI in a browser and report what actually happened. Report-only |
| `/zensu:plan-review` | Have a tailored reviewer team revalidate a plan *before* any code is written |
| `/zensu:pr-team-review` | Multi-agent review of an existing GitHub or GitLab PR, published as one consolidated review |
| `/zensu:pr-fix-findings` | Work through every unresolved review thread on a PR and resolve it |
| `/zensu:security-review` | Classification, OWASP analysis, STRIDE threat model, release-gate check |
| `/zensu:converge` | Audit the code against the plan and flow real changes back into the spec |
| `/zensu:docs` | Write code-grounded feature documentation that honestly clears the docs release gate |
| `/zensu:wargame` | Map a hard task move by move so a cheaper model can execute it blind |
| `/zensu:self-review` | The terminal self-reflection stage that closes the review chain |
| `/zensu:pulse` | Developer journal — privacy-first tracking of your coding sessions |
| `/zensu:zen-mode` | Low-noise responses for working at reduced capacity. On by default |
| `/zensu:setup` | Interactive first-run configuration |
| `/zensu:reset-review-limit` | Grant the current review chain another auto-fix budget |
| `/zensu:recover-chain` | Repair the one review-chain state no other command can leave |
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
network: `/zensu:tdd`, the five-aspect review with its auto-fix loop, and the
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

It does **not** transmit source code or file contents — only paths. Error
messages are excluded unless `freetext_logging` is explicitly enabled for Pulse.
Pulse sessions are retained for 90 days by default.

### Self-hosting

Point the CLI at your own deployment with the `--api-url` flag, the
`ZENSU_API_URL` environment variable, or `zensu auth login` against your host:

```bash
export ZENSU_API_URL=https://api.example.internal
```

The plugin `.mcp.json` contains only the local Playwright driver used for live
verification; it has no Zensu API or hosted-MCP endpoint to redirect. If you
operate under GDPR, CCPA, or similar regulations, self-hosting keeps the data
under your control.

## Requirements

Claude Code 2.1.211 or newer on macOS or Linux. Hooks need a POSIX shell —
Windows users need WSL or Git Bash; native `cmd.exe` and PowerShell are not
supported.

## Documentation

| Document | What is in it |
|----------|---------------|
| [Architecture](docs/architecture.md) | The three layers, the workflow diagram, evidence discipline, typical flows |
| [Review chain](docs/review-chain.md) | The reviewer agents, custom repo personas, skill overlays, templates |
| [Gates](docs/gates.md) | The write gates, the secret scan, and the TDD phase gate |
| [Session control](docs/session-control.md) | Subagent safety, the security boundary, unbindable sessions |
| [Configuration](docs/configuration.md) | Every hook, every flag, merge order, environment variables |
| [Operations](docs/operations.md) | Upgrade path, platform support, troubleshooting |
| [TDD workflow](docs/tdd-manager-workflow.md) | The full per-step reference for the implementation workflow |
| [Evidence discipline](docs/evidence-discipline.md) | The one rule underneath everything else |

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
