# Contributing to Zensu Claude Code Plugin

Thank you for your interest in contributing! This guide will help you get started.

## Reporting Bugs

Use the [Bug Report](https://github.com/MKITConsulting/zensu-claude-code/issues/new?template=bug_report.md) issue template. Include:

- Steps to reproduce the issue
- Expected vs. actual behavior
- Your environment (OS, Claude Code version, plugin version, shell)

## Suggesting Features

Use the [Feature Request](https://github.com/MKITConsulting/zensu-claude-code/issues/new?template=feature_request.md) issue template. Describe the problem you're trying to solve and your proposed solution.

## Security Vulnerabilities

Do **not** open a public issue. Instead, email [security@zensu.dev](mailto:security@zensu.dev). See [SECURITY.md](SECURITY.md) for details.

## Pull Requests

1. Fork the repository and create a feature branch from `main`
2. Make your changes (one logical change per PR)
3. Follow the code standards below
4. Submit a PR using the pull request template

## Local Development Setup

```bash
git clone https://github.com/MKITConsulting/zensu-claude-code.git
cd zensu-claude-code
claude plugin install zensu --scope project
export ZENSU_API_KEY=zsk_...
```

## Code Standards

- **No comments in code** — code should be self-explanatory
- **Conventional Commits** — use prefixes like `feat:`, `fix:`, `chore:`, `docs:`
- **Skills** — follow the existing phase-based workflow pattern (see `skills/bootstrap/SKILL.md` for reference). Include `Prerequisites`, `MCP Tools Used`, and `MCP Prompts Used` sections.
- **Agents** — follow the structure of `agents/zensu-plm.md` (decision rules, tool references, important rules)
- **Hooks** — use `bash -c` with proper error handling and `2>/dev/null` for optional commands

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.
