# Zensu Plugin for Claude Code

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.1.0-green.svg)](CHANGELOG.md)

Zensu is a Product Lifecycle Manager that treats features as first-class citizens. This plugin connects Claude Code to the Zensu platform, enabling you to track features from roadmap through release — with built-in security analysis, artifact linking, and developer session journaling.

## Installation

```bash
claude plugin install zensu --scope project
```

## Authentication

### OAuth Browser Login (Recommended)

No configuration needed. When you first use a Zensu tool, Claude Code will automatically open your browser to sign in. Tokens are cached and refreshed automatically.

### API Key (CI/CD)

For headless environments where browser login isn't available:

```bash
export ZENSU_API_KEY=zsk_...
```

Optionally set `ZENSU_MCP_URL` to override the default MCP server URL (`https://mcp.zensu.dev`).

## What's Included

### MCP Server (49 Tools)

Auto-configured connection to the Zensu MCP server providing tools for feature CRUD, security analysis, tier management, user journeys, product bootstrap, ghost scans, pulse sessions, and more.

### Agent: `zensu-plm`

Product Lifecycle Manager agent that automatically handles Zensu-related tasks. Delegates when you ask about feature tracking, security reviews, release readiness, or any product lifecycle workflow.

### Skills (5)

| Skill | Description |
|-------|-------------|
| `/zensu:bootstrap` | Bootstrap a product from a vision document — creates features, journeys, security profiles, tiers |
| `/zensu:security-review` | Comprehensive security review: classification, analysis, STRIDE threat model, review completion |
| `/zensu:implement` | Implement a feature end-to-end with artifact linking and revision tracking |
| `/zensu:ghost-scan` | Scan a repository to discover undocumented features and import them |
| `/zensu:pulse` | Developer journal — track coding sessions with privacy-first activity logging |

### Hooks

| Hook | Event | Description |
|------|-------|-------------|
| `[ZEN-xxx]` Linking | PostToolUse (Bash) | Detects feature references in git commit messages |
| Auto Pulse | SessionStart | Prepares pulse session context at startup |

## Quick Start

Typical workflow: **bootstrap** → **implement** → **security-review**

1. Bootstrap a new product:
   ```
   /zensu:bootstrap
   ```

2. Implement a feature:
   ```
   /zensu:implement
   ```

3. Run a security review:
   ```
   /zensu:security-review
   ```

4. Scan an existing repo for undocumented features:
   ```
   /zensu:ghost-scan
   ```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ZENSU_MCP_URL` | `https://mcp.zensu.dev` | MCP server base URL |
| `ZENSU_API_KEY` | — | API key for CI/CD (optional if using OAuth) |

### Default Agent

Installing this plugin sets `zensu-plm` as the default agent for the project scope via `settings.json`. The agent automatically delegates Zensu-related tasks (feature tracking, security reviews, product lifecycle workflows).

To override or disable:
- Edit `settings.json` in the plugin root to change the default agent
- Remove the `"agent"` key from `settings.json` to restore the Claude Code default

## Data & Privacy

When using this plugin, certain data is transmitted to the Zensu MCP server.

**What data is transmitted:**
- Product names, feature titles, and descriptions
- Security classifications and OWASP tags
- File paths (not file contents), git SHAs, and branch names
- Vision documents (may contain product strategy and roadmap details)
- Pulse session metadata: tool names, durations, feature IDs, file paths

**Where it goes:**
- Default: `https://mcp.zensu.dev` (all data transmitted via HTTPS)
- Override with `ZENSU_MCP_URL` to point to a self-hosted instance

**What is NOT transmitted:**
- Source code content
- File contents (only paths)
- Error messages (unless `freetext_logging` is explicitly enabled for Pulse)

**Data retention:**
- Pulse sessions: 90 days by default (configurable)

**Self-hosting:**
Set `ZENSU_MCP_URL` to your own instance to keep all data on your infrastructure.

**Regulated environments:**
If you operate under GDPR, CCPA, or similar data protection regulations, review the data transmission above and consider using a self-hosted instance to maintain full control over your data.

## Platform Support

Hooks use `bash -c` and require a POSIX-compatible shell. Supported platforms:
- macOS
- Linux

Windows users need WSL or Git Bash. Native `cmd.exe` and PowerShell are not supported for hooks.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| MCP server unreachable | Check `ZENSU_MCP_URL` value and network connectivity |
| Invalid API key | Verify `ZENSU_API_KEY` format (`zsk_...`) |
| Hook errors on Windows | Use WSL or Git Bash (see [Platform Support](#platform-support)) |
| Agent triggers on non-Zensu tasks | Override the default agent (see [Default Agent](#default-agent)) |
| OAuth login not opening | Check your default browser settings |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on reporting bugs, suggesting features, and submitting pull requests.

## Security

See [SECURITY.md](SECURITY.md) for our responsible disclosure policy.

## License

MIT
