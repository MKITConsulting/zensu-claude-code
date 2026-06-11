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

**External pull requests are not accepted.** This repository is published as a read-only source. Forking is disabled and only maintainers of the `MKITConsulting` organization can merge changes into `main`.

If you would like to see a change, please open an issue describing the problem or feature. The maintainer team triages incoming issues and implements accepted changes internally.

Any pull request opened against this repository will be closed without review. This policy keeps the release pipeline reproducible and ensures every change is covered by the project's licensing and review process.

## Local Development Setup

You are welcome to clone and run the plugin locally for evaluation or learning purposes, subject to the [LICENSE](LICENSE):

```bash
git clone https://github.com/MKITConsulting/zensu-claude-code.git
cd zensu-claude-code
claude plugin marketplace add .
claude plugin install zensu --scope project
export ZENSU_API_KEY=zsk_...
```

## Code Standards (Internal Reference)

The following standards apply to maintainer commits:

- **No comments in code** — code should be self-explanatory
- **Conventional Commits** — use prefixes like `feat:`, `fix:`, `chore:`, `docs:`
- **Skills** — follow the existing phase-based workflow pattern (see `skills/bootstrap/SKILL.md` for reference). Include `Prerequisites` and `MCP Tools Used` sections. Add `MCP Prompts Used` if the skill uses MCP prompts.
- **Agents** — follow the structure of `agents/zensu-plm.md` (decision rules, tool references, important rules)
- **Hooks** — use `bash -c` with proper error handling and `2>/dev/null` for optional commands

## Licensing

This project is licensed under the [Functional Source License, Version 1.1, Apache 2.0 Future License](LICENSE) (FSL-1.1-Apache-2.0).

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.
