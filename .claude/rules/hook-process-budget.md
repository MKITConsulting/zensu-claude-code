---
paths:
  - "hooks/lib/zensu-host-path.sh"
  - "hooks/lib/zensu-config.sh"
  - "hooks/lib/zensu-session.sh"
  - "hooks/pre-reviewer-capability-gate.sh"
  - "hooks/pre-write-secret-scan.sh"
  - "hooks/lib/bash-source-write-parse.js"
  - "hooks/hooks.json"
  - "tests/structure/test-hook-process-budget.sh"
  - "tests/structure/test-secret-scan-gate.sh"
  - "tests/structure/test-msys-runtime-boundaries.sh"
---

# Hook Process Budget (`tests/structure/test-hook-process-budget.sh`)

Git Bash for Windows pays a full process creation for every program a hook starts and for every
`$(...)` subshell. Measured with the budget suite on macOS (bash 3.2) and on Linux (bash 5.2),
the hooks around one Bash call started 56 programs before this change and start 18 now, 8 of
them `node`; a Read call went from 11 to 1, an Edit call from 122 to 41 (33 `node`).

**The suite counts every program a hook starts through `PATH`.** It writes a shim for every
executable name on the runner's `PATH`, runs every registration `hooks.json` holds for a Bash, a
Read and an Edit payload in an armed session with `PATH` set to the shim directory alone, and
compares the totals with `budget()`. A program started by an absolute path is not counted. The
budgets are the measured totals, so a hook that starts one more program fails `B3`; lower the
budget when a change removes one. On Git Bash the suite skips: the budgets are calibrated on
POSIX hosts, and its counting shims, which wrap every `PATH` program by name, were never run
against Windows executables.

## `zensu_host_path`

- `hooks/lib/zensu-host-path.sh` is a library and a script. Sourced, it defines
  `zensu_host_path`; executed, it keeps its command-line contract (one directory argument, exit 2
  on a refusal), which skills, other hooks and tests still use.
- The function changes directory, so it refuses a call at a shell's top level (`BASH_SUBSHELL`
  0). Call it only as `"$(zensu_host_path "$dir")"`.
- MSYS is detected from `OSTYPE`, as `_zensu_config_native_path` in `zensu-config.sh` already
  did, not from `uname`. A drive spelling such as `/c/x` becomes `C:/x` in shell, the rule
  `msysDrivePrefix` in `claude-path-v1.js` applies, and is accepted only when `cd -P` of the result
  lands on the same canonical directory. Every other path, an MSYS mount such as `/tmp` included,
  goes through `cygpath -am` and the round-trip checks as before.
- The `cygpath` refusal checks in `tests/structure/test-msys-runtime-boundaries.sh` source the file
  and stub `_zensu_host_path_drive` to decline, so they reach that branch whatever spelling the
  host gives a temporary directory. A fixture with a drive spelling takes the fast path, which runs
  no `cygpath` and accepts it; a plain `/tmp` fixture failed this check on the Windows runner of run
  40851239372. The same stub drives one real `cygpath -am` render on Git Bash. A rename of
  `_zensu_host_path_drive` needs the same rename there.
- Each loader unsets the three function names before it sources the file, because bash imports
  exported functions from the environment, and fails closed when `zensu_host_path` is undefined
  afterwards: the capability gate exits 2, `zensu-tdd-phase.sh` returns 2 and `zensu-session.sh`
  installs a stub that refuses.

## Config pre-check (`_zensu_config_key_unset`)

`zensu_hook_enabled` and `zensu_hook_opted_in` answer in shell when `ZENSU_CONFIG` is unset and
no candidate file of `cfg()` names the key. Parsed JSON can carry the key only if the text holds
`"<key>"` literally or a backslash escape, so a file holding neither yields the default. A file
that is not a readable regular file, or reads empty while non-empty, goes to node. `C1` in the
budget suite holds the answers equal to the node reader over every config state it builds, a
unicode-escaped key among them, and `C2` holds that the decided states start no `node`.
`zensu_hook_enabled_strict` and the bounded getters are unchanged.

- **The read is bounded.** Bash reads a file one byte per system call here, so the pre-check
  reads at most `_ZENSU_CONFIG_PRECHECK_BYTES` (16384) bytes and sends a longer file to node.
  Measured on macOS bash 3.2: a 4 MB file took 1.43 s unbounded and 0.00 s bounded, and 16384
  bytes take about 5 ms. The bound only decides who answers, never the answer: `C1` holds a key
  that lies past it, and `C2` holds that a file longer than the bound starts `node`.
- **The candidate list is a copy of `cfg()`'s.** The loop names `$HOME/.zensu/config.json` and
  `$CLAUDE_PROJECT_DIR/.zensu/config.json`, and returns early on a set `ZENSU_CONFIG`. `C3` runs
  `cfg()` from `_ZENSU_CFG_JS` with a recording `fs` in five environment shapes, plants the key in
  each file it reads, and requires the pre-check to defer every time. A file `cfg()` starts to
  read must join the loop in the same change. An empty `HOME` is not driven: both readers then
  read `/.zensu/config.json`, which no fixture can plant.

## Secret-scan pre-check

`pre-write-secret-scan.sh` still binds first. For a payload whose only unescaped `"tool_name"` is
`"Bash"`, it exits before the scanner when the raw payload holds none of `>`, `<<`, `tee`,
`of=`, `\u`, or `sed` followed later by `-i`. That token list is a superset of what
`detectChannels` in `bash-source-write-parse.js` can report, and it is a COPY: a channel added to
`detectChannels` must add its token here in the same change, or the scanner never sees that
channel. `F13b` in `tests/structure/test-secret-scan-gate.sh` reads every label the
`detectChannels` body adds, requires a row for it in `channel_row` that the parser reports under
that label, and drives each row, a `\u003e`
redirect and a duplicated `tool_name` through the hook. A new channel without a row, or one whose
token the pre-check lacks, fails there. `zensu-tdd-phase.sh` is sourced only to record a bypass.

## Not taken here

- Hooks keep reading stdin with `cat`: `read -d ''` keeps a trailing newline that `$(cat)`
  strips, and it reads a pipe one byte per system call.
- The browser consent prefilter keeps its `sed | tr` pass (`.claude/rules/browser-consent-gate.md`).
- `post-artifact-redact.sh` still starts four `node` processes per call, and
  `pre-edit-tdd-reminder.sh` starts 25 for one Edit in an armed session.
- One dispatcher process per event changes hook registrations and is a `minor`.
- Every hook registered on `PreToolUse` or `PostToolUse`, and every library such a hook
  sources, finds its own directory without starting `dirname`. `zensu-autopilot-state.sh`
  keeps one only in the default it uses when `CLAUDE_PLUGIN_ROOT` is unset, which no hook
  reaches. Hooks on the other events (`SessionStart`, `UserPromptSubmit`, `Stop`,
  `SubagentStart`, `SubagentStop`, `SessionEnd`) keep `dirname`, because they run once per
  session, prompt, turn or subagent, not once per tool call. `S1` in the budget suite follows
  every `source` of the tool-call hooks, a variable resolved through its assignment in the same file,
  and fails on a `dirname` of `$0` or `BASH_SOURCE` in any file it reaches, or on a source it
  cannot follow; `S1b` requires the same scan to flag `hooks/stop-work-order.sh`.
- A `dirname` of a state or marker path is not a hook finding its own directory, so it
  stays, for example in `pre-edit-tdd-reminder.sh`, `post-review-tdd-delegate.sh`,
  `zensu-config.sh` and `zensu-tdd-phase.sh`.

**Version: `patch`.** No schema field, strict key set, hook registration, matcher, config key or
attestation moves, and every allow and deny for a tool-call payload is unchanged. Two failure
modes change, both toward fewer denies: the capability gate no longer needs a writable `TMPDIR`,
so an unwritable one no longer denies every tool call (pinned in
`tests/structure/test-reviewer-capability-gate.sh`), and the host-path helper no longer runs
`uname`, so a missing or failing `uname` no longer makes it refuse
(`tests/structure/test-msys-runtime-boundaries.sh` retired that case).

**Known gaps:** Windows is unmeasured: the suite skips on Git Bash, and the blocking Windows
shards have no room for it. A single-letter directory at the MSYS installation root, which a
drive letter can shadow, is not told apart from that drive by the drive fast path.
