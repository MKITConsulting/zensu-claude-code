# Zensu Plugin for Claude Code

Product Lifecycle Manager — Features as First-Class Citizens.

## Installation

```bash
claude plugin install zensu --scope project
```

## Prerequisites

- Zensu MCP Server running (default: `http://localhost:3001/mcp`)
- `ZENSU_API_KEY` environment variable set (format: `zsk_...`)

Optionally set `ZENSU_MCP_URL` to override the default MCP server URL.

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

1. Start the Zensu backend and MCP server:
   ```bash
   cd backend && make dev   # Backend on :8080
   cd backend && make mcp   # MCP server on :3001
   ```

2. Bootstrap a new product:
   ```
   /zensu:bootstrap
   ```

3. Implement a feature:
   ```
   /zensu:implement
   ```

4. Run a security review:
   ```
   /zensu:security-review
   ```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ZENSU_MCP_URL` | `http://localhost:3001` | MCP server base URL |
| `ZENSU_API_KEY` | (required) | API key for authentication |

## License

MIT
