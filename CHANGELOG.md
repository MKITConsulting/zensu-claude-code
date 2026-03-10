# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Data & Privacy disclosure in README
- SECURITY.md with responsible disclosure policy and safe harbor
- CONTRIBUTING.md with contributor guidelines
- CODE_OF_CONDUCT.md (Contributor Covenant 2.1)
- GitHub issue and PR templates
- Troubleshooting section in README
- Platform compatibility documentation
- Default agent override documentation
- Prerequisites and MCP Tools Used table to Pulse skill

### Changed
- Expanded .gitignore to prevent credential and artifact leaks
- Reformatted CHANGELOG to Keep a Changelog specification
- Improved PostToolUse hook with graceful failure handling
- Fixed SessionStart hook detached HEAD handling
- Downgraded version to 0.1.0 (pre-stable API)

## [0.1.0] - 2026-03-01

### Added
- Plugin manifest (`plugin.json`) with full metadata
- MCP server auto-configuration (`.mcp.json`)
- Agent: `zensu-plm` — Product Lifecycle Manager with domain knowledge
- Skill: `/zensu:bootstrap` — Bootstrap products from vision documents
- Skill: `/zensu:security-review` — Comprehensive security review workflow
- Skill: `/zensu:implement` — Feature implementation with artifact linking
- Skill: `/zensu:ghost-scan` — Repository scanning for undocumented features
- Skill: `/zensu:pulse` — Privacy-first developer session journal
- Hook: Post-commit `[ZEN-xxx]` feature reference detection
- Hook: Session-start pulse context preparation
- Default agent configuration (`settings.json`)

[unreleased]: https://github.com/MKITConsulting/zensu-claude-code/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/MKITConsulting/zensu-claude-code/releases/tag/v0.1.0
