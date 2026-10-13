---
paths:
  - "hooks/lib/shell-tool-coverage-v1.js"
  - "hooks/lib/hook-registration-v1.js"
  - "hooks/hooks.json"
  - "hooks/session-start-banner.sh"
  - "hooks/lib/zensu-doctor-report.js"
  - "tests/structure/test-session-start-banner.sh"
  - "tests/structure/test-doctor.sh"
---

# PowerShell Tool Coverage (`hooks/lib/shell-tool-coverage-v1.js`)

Claude Code has two shell tools, `Bash` and `PowerShell`. Every Zensu hook that reads a shell
command is registered on the `Bash` matcher, so a command Claude runs through the PowerShell
tool skips the CLI write-gate, the Session Control check and the opt-in source-write rules, the
secret scan, the browser consent gate and artifact redaction. The work-order gate fires for every
tool, but `gateDecision` in `hooks/lib/work-order-v1.js` analyzes only `tool === 'Bash'`.

**This is the interim mitigation, and it is advisory.** The docs require
`CLAUDE_CODE_USE_POWERSHELL_TOOL=0` while the gap exists, and two surfaces warn: one SessionStart
banner line and the `shell tools:` row of `/zensu:doctor`. The durable fix widens the matchers to
`Bash|PowerShell` and gives each gate a PowerShell disposition; a matcher change is `minor`
under `.claude/rules/runtime-lineage.md`.

## When the host runs the PowerShell tool

Read from the Claude Code 2.1.296 binary, not from a documented contract, so re-read it when the
host changes:

- The variable goes through the host's tri-state reader: `1`, `true`, `yes` or `on` is true,
  `0`, `false`, `no` or `off` is false, each trimmed and in any letter case, and every other
  value counts as unset.
- Off Windows the tool runs only when the value is true.
- On Windows a set value decides. Without Git Bash the tool is on, and the host registers no Bash
  tool at all. With Git Bash a remotely fetched flag decides (`tengu_cobalt_ridge` in 2.1.296,
  default off); the docs describe it as on by default for claude.ai and Console accounts.

`powershellToolState` copies that reading into four states: `on`, `off`, `default` (win32 with
the value unset or unrecognized) and `absent`. `TRUTHY` and `FALSY` are a hand copy of the host's
lists. No hook can read the fetched flag or the account type, so `default` means the tool MAY be
active, and both surfaces say "may".

## The predicate is data-driven

`shellCoverage(manifest)` walks the `PreToolUse` and `PostToolUse` groups of `hooks/hooks.json`
through `hostMatcherCovers` in `hooks/lib/hook-registration-v1.js`, the one reader of the host's
matcher rule. A hook that fires for `Bash` (registered or unknown) is a gap unless it is
registered for `PowerShell`; an `unknown` PowerShell answer is a gap too. Answers are ranked per
event and hook file, so a hook registered in two groups counts once at its best answer. A
manifest of a shape the walk cannot read returns `null`, which both surfaces render as a missing
check, never as an all-clear.

Because the predicate reads the matchers, the warning goes quiet by itself once every such hook
also matches `PowerShell`, and it comes back for any later hook registered on `Bash` alone.

## The two surfaces

- **Banner.** The line sits ABOVE the `hooks.sessionBanner` gate, for the reason the
  reviewer-spawn line gives: it reports gates that do not fire, not noise. It stays BELOW the
  resume/compact filter, so a resumed session stays silent (`B11`). `_zensu_powershell_host`
  starts `node` only when the variable is set or `uname -s` names MINGW, MSYS or CYGWIN, so macOS
  and Linux without the variable pay nothing.
- **Doctor row.** `shellToolRow` runs at the end of `pluginBlock`. WARN when gaps exist and the
  state is `on` or `default`; OK otherwise, still naming the gaps and the state. A module that
  will not load, or a manifest the walk cannot read, renders a WARN that says it is a missing
  check. `ZDOC_POWERSHELL_TOOL` injects the state for tests; without it the row reads the
  doctor's own environment and `process.platform`.

`REMEDY` is the one spelling of the remedy both surfaces print.

## Coupled sites

The remedy and the gap description are prose in §"Shell Tools" of `docs/gates.md`, the
known-gap bullet of `docs/work-order-mode.md`, and the "Plugin integrity" bullet of
`skills/doctor/SKILL.md`, which sits on the shrink-only budget allowlist of
`tests/structure/test-skill-text-budget.sh`. The Requirements section of `README.md` and
§"Platform Support" of `docs/operations.md` state the Windows requirement in their own words;
keep them in step with `REMEDY`. No test compares that prose with the module.

## Tests

`B16`–`B16g` in `tests/structure/test-session-start-banner.sh` pin the banner: the warning with
`=1`, its place above the gate, silence on resume, silence with `=0` and with covered matchers,
the platform default, the shipped banner against the module, and the module's unit arms.
`P2p1`–`P2p8` in `tests/structure/test-doctor.sh` pin the row for every state, the covered and
unreadable manifests, a missing module, and the real `hooks.json` against the module's own count.
`tests/structure/test-msys-special-plugin-module-boundaries.sh` runs the banner from a plugin
root whose path holds a space and a quote and requires the module's own line, so a broken
`cd -P` transport fails there, on Windows CI too.

## Known gaps

- On Windows with the variable unset, a Bedrock, Vertex or Foundry session sees the warning
  although the host keeps the tool off there. Setting `=0` is still harmless.
- The predicate sees matchers, not judgments. The work-order gate's Bash-only analysis is
  invisible to it; `docs/work-order-mode.md` names that gap.
- The doctor row reads the doctor process's environment. A value set only in the `env` block
  of `~/.claude/settings.json` reaches it because the host writes those entries into the process
  environment.
- A banner whose module fails to load prints nothing, like the other banner lines. The doctor
  row is the check that reports a missing module.
- Before the `B16` family the banner suite took 16.8 s of its 180 s cap on `windows-shard-3`
  (CI run 38420101994). The family's own Windows cost is unmeasured.
- No ports. `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not included.

**Version: `patch`.** An advisory banner line and a doctor row: no hook added, removed or
re-matched, no `permissionDecision`, no schema field, no strict key set, no config key and no
attestation change.
