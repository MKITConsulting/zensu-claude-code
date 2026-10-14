---
paths:
  - "hooks/lib/powershell-command-v1.js"
  - "hooks/lib/shell-tool-coverage-v1.js"
  - "hooks/lib/hook-registration-v1.js"
  - "hooks/hooks.json"
  - "hooks/pre-bash-zensu-gate.sh"
  - "hooks/lib/bash-source-write-parse.js"
  - "hooks/lib/secret-scan-decide.js"
  - "hooks/pre-write-secret-scan.sh"
  - "hooks/lib/verify-consent-v1.js"
  - "hooks/post-artifact-redact.sh"
  - "hooks/lib/work-order-v1.js"
  - "harness/launcher.js"
  - "hooks/session-start-banner.sh"
  - "hooks/lib/zensu-doctor-report.js"
  - "tests/structure/powershell-command-v1.test.js"
  - "tests/structure/test-powershell-tool-coverage.sh"
  - "tests/structure/test-session-start-banner.sh"
  - "tests/structure/test-doctor.sh"
---

# PowerShell Tool Coverage (`hooks/lib/powershell-command-v1.js` + `shell-tool-coverage-v1.js`)

Claude Code has two shell tools, `Bash` and `PowerShell`. Both shell groups of `hooks/hooks.json`
match `Bash|PowerShell`, so every hook that reads a shell command also sees a PowerShell command.
Each one judges PowerShell text where the judgment is exact and refuses what it cannot judge. **No
gate lets PowerShell text it cannot judge pass in silence**; a refusal tells the main thread to use
the Bash tool (or Edit and Write) and a subagent to report to the main thread.

## When the host runs the PowerShell tool

Read from the Claude Code 2.1.296 binary, not from a documented contract, so re-read it when the
host changes:

- The tool input carries `command` (plus `timeout`, `description`, `run_in_background` and
  `dangerouslyDisableSandbox`), the field set of the Bash tool, and hooks run under Git Bash.
- `CLAUDE_CODE_USE_POWERSHELL_TOOL` goes through the host's tri-state reader: `1`, `true`, `yes`
  or `on` is true, `0`, `false`, `no` or `off` is false, each trimmed and in any letter case, and
  every other value counts as unset.
- Off Windows the tool runs only when the value is true. On Windows a set value decides; with Git
  Bash a remotely fetched flag decides (`tengu_cobalt_ridge` in 2.1.296), which the docs describe
  as on by default for claude.ai and Console accounts.

`powershellToolState` copies that reading into `on`, `off`, `default` (win32, unset or
unrecognized) and `absent`; `TRUTHY` and `FALSY` are a hand copy of the host's lists.

## The analyzer

`hooks/lib/powershell-command-v1.js` has no dependencies and never throws at a caller: `analyze()`
returns `fault` for an unterminated construct, an unbalanced group, a text over `MAX_TEXT_LENGTH`,
and nesting past `MAX_DEPTH` or `MAX_RECORDS`. It over-reports command positions, resolves the
built-in aliases through `ALIASES` (the union of Windows PowerShell 5.1 and PowerShell 7), and
normalizes names through `normalizeCommandName`. Every argument is literal or not; a word built at
run time keeps its literal `prefix`, and `literals` holds every decoded string, so a name check
also sees a backtick or `u{}` spelling. `joinConcatenations` joins a `+` between two string
literals before the name checks, so `"zen" + "su"` and a protected name split across literals
are seen. A word keeps its `verbatim` spelling beside the dash-normalized `value`, because
PowerShell hands a Unicode dash to a native program unchanged. The name checks run once over all
spellings joined by line breaks, never once per literal: per literal, a 1 MiB command of 520,000
words took 1040 ms in `controlVerdict`, and joined it takes about 120 ms on the development Mac.
Three verdicts:

- `zensuInvocations` for the CLI gate: each literal `zensu` call with its verbatim words, a word
  built at run time as `OPAQUE_ARGUMENT` (NUL). It answers `unjudged`, never "no call", when the text names
  `zensu` and holds a dynamic call target, a launcher, a definition, an unsafe method call, a
  fault, or a nested shell it cannot read.
- `controlVerdict` for the Session Control check: any spelling of a `CONTROL_BINDINGS` name or of
  the env file, an Environment provider write under a dynamic name, a move into `env:`, a
  `New-PSDrive` on that provider, `SetEnvironmentVariable` with a dynamic name, code built at run
  time (`Invoke-Expression`, `[scriptblock]::Create`, `InvokeScript`, `ExpandString`, `Add-Type`),
  a process environment change, a `ProcessStartInfo`, and a fault.
- `readOnlyVerdict` for rules (A), (B) and (C): only `READ_ONLY_COMMANDS`, `SAFE_METHODS`,
  `.ForEach` and `.Where` with a script block, redirections to `$null`, and assignments to plain
  variables. A property or element assignment is refused, because a setter such as
  `.IsReadOnly` or `.LastWriteTime` changes the file. A missing alias causes a false deny, never
  an allow.

Nested shells are judged by how they read code. A PowerShell host reads `-Command`,
`-EncodedCommand` (always refused), `-File` and standard input (refused); `pwsh` reads its first
positional argument as a script file, `powershell` as a command; an option in
`POWERSHELL_VALUE_OPTIONS` takes its value. A POSIX shell reads `-c` code, a script file or
standard input (refused); an option name built at run time is refused. Code built at run time is
refused in either. `STRICT_RUNNERS` (`cmd`, `env`, `sudo`, `doas`, `gsudo`, `runas`, `wsl`)
refuse any argument built at run time, because their arguments are a command line or an
assignment. Other wrappers are judged through the shell they start. `Start-Process` judges only a
literal shell and then refuses any argument built at run time; `Process.Start` with a literal
shell is refused.

## Per-gate disposition

| Hook | PowerShell disposition |
|---|---|
| `pre-bash-zensu-gate.sh` | Judged: reads and `--help` pass, a freelance or subagent mutation is denied as in Bash. `unjudged`, a noun or verb holding `OPAQUE_ARGUMENT`, or an analyzer that fails to load while the text names `zensu` denies. No inline escape. |
| `pre-bash-source-write-gate.sh`, control mode | `controlVerdict`, always on. |
| same, rules (A)/(B)/(C) | `readOnlyVerdict` while `hooks.bashWriteGate` is on; the deny ends with `OPT_IN_NOTE`. |
| `pre-write-secret-scan.sh` | The whole command text is scanned, with no channel filter and no inline escape. |
| `pre-browser-navigation-consent.sh` | A call carrying both consent markers is refused (`POWERSHELL_NOT_JUDGED`). |
| `post-browser-navigation-consent.sh` | Skipped (`powershell-call`), because the pre hook refused every marked call. |
| `post-artifact-redact.sh` | Parity: the sweep runs as after Bash. |
| `pre-work-order-gate.sh` | Refused in a bound work-order session; `harness/launcher.js` starts Claude with `CLAUDE_CODE_USE_POWERSHELL_TOOL=0`. |
| `post-work-order.sh` | Runs for every tool; its `zensu work ask` branch reads Bash only, which the pre gate leaves as the only shell. |
| `pre-reviewer-capability-gate.sh` | Unchanged: the allowlists deny PowerShell for every non-main principal, and the neutral grant covers `Bash` alone. |

## Steering and diagnostics

`shellCoverage(manifest)` walks the tool events through `hostMatcherCovers`, the one reader of the
host's matcher rule. With gaps, the banner warns above the `hooks.sessionBanner` gate and the
doctor's `shell tools:` row warns; without gaps, the banner prints `STEER` below the gate while the
tool may run, and the row is green only when `powershell-command-v1.js` loads and reads a probe
command. A missing analyzer turns every PowerShell command into a Session Control deny, so a
green row would be a false all-clear.

## Coupled sites

- The matcher spelling: both groups in `hooks/hooks.json`, `CONSENT_MATCHER` and `CONSENT_TOOLS`,
  B3, W4, P1, R0c, V3, the `registered_check` of `tests/e2e-source-write-gate/run.sh`, P1vl7, and
  `bashGroup` in `evals/session-control/lib/upgrade-hook-contract.js`. Matcher reads go through
  `hostMatcherCovers`; never compare the matcher string.
- The sibling loads: `bash-source-write-parse.js` requires the analyzer lazily and only for a
  PowerShell payload; `pre-bash-zensu-gate.sh` loads it through `cd -P` into its own `hooks/lib`
  with `ZPS`, which stays empty when the `cd` fails, so a project file can never load; the doctor
  report requires it. PC5a and PC5b pin the two hook loads, and P2p9 the doctor's.
- `OPAQUE_ARGUMENT` and the `__unjudged__` line between the gate's inline node and its shell side.
- The disposition table in `tests/structure/test-powershell-tool-coverage.sh`: PC3 fails for a
  hook on a shell matcher without a row, PC4 for a row whose suite lost its PowerShell case.
- `STEER`, `REMEDY` and the operator prose in `docs/gates.md` §"Shell Tools", the hook rows of
  `docs/configuration.md`, `docs/session-control.md`, `docs/verify-feature.md`,
  `docs/work-order-mode.md`, the Requirements of `README.md` and §"Platform Support" of
  `docs/operations.md`. No test compares that prose with the code.

## Tests

`tests/structure/powershell-command-v1.test.js` holds the corpus, including the inputs a read-only
red team found: property setters, `.ForEach` with a method name, literal concatenations and a
Unicode dash before `-h`. Its conformance case parses the
corpus with `[System.Management.Automation.Language.Parser]::ParseInput`, requires every
`CommandAst` name among the analyzer's commands and every `Get-Alias` entry in `ALIASES`; it is
required on win32 and skipped where no PowerShell is installed. Its driver
`tests/structure/test-powershell-tool-coverage.sh` runs on `windows-shard-3`. The per-hook
PowerShell cases are B40-B41, WP1-WP17, F8p-F8p6, V70-V70d, R7p-R7pd, PS1-PS6, the work-order
gate test and the PowerShell payloads of `test-vanished-session-cwd.sh`; the surfaces are B16 and
P2p1-P2p9.

## Known gaps

- A name or provider path built at run time from anything but string literals passes, as its
  Bash equivalent passes in Bash: a value from an earlier call (`Set-Item -Path $p`) or a
  character code (`& ([char]0x7A + 'ensu')`).
- A pure variable in the option position of a POSIX shell (`bash $flags $code`) counts as the
  script path.
- Script files, interpreter code (`node -e`, `python -c`), and an alias, function or variable an
  earlier tool call defined are not read.
- The doctor and adoption commands are recognized in Bash spelling only. In a bind failure a
  PowerShell call gets the named deny, and both stay reachable through the Bash tool.
- "Use the Bash tool" is not actionable when a user denies Bash while forcing the PowerShell tool.
- The conformance case and the analyzer's Windows behavior run only on Windows CI; no session with
  the PowerShell tool on was observed live.
- On Windows with the variable unset, a Bedrock, Vertex or Foundry session sees the banner line
  although the host keeps the tool off there.
- No ports. `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were not included.

**Version: `minor`.** Both shell matchers changed, and the gates now refuse PowerShell commands
they never saw before; a gate that refuses more changes the capability set of every session a
newer installation would serve.
