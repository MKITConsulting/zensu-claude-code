---
paths:
  - "hooks/lib/zensu-host-path.sh"
  - "hooks/lib/zensu-config.sh"
  - "hooks/lib/zensu-session.sh"
  - "hooks/pre-reviewer-capability-gate.sh"
  - "hooks/pre-write-secret-scan.sh"
  - "hooks/pre-edit-tdd-reminder.sh"
  - "hooks/pre-write-plugin-data-guard.sh"
  - "hooks/pre-agent-reviewer-allow.sh"
  - "hooks/post-artifact-redact.sh"
  - "hooks/lib/edit-path-class-v1.js"
  - "hooks/lib/bash-source-write-parse.js"
  - "hooks/hooks.json"
  - "hooks/lib/hook-dispatch-v1.js"
  - "hooks/lib/hook-registration-v1.js"
  - "hooks/lib/zensu-hook-dispatch.sh"
  - "hooks/checks/**"
  - "tests/structure/hook-dispatch-v1.test.js"
  - "tests/structure/test-hook-process-budget.sh"
  - "evals/session-control/lib/upgrade-hook-contract.js"
  - "evals/session-control/lib/upgrade-provider.js"
  - "tests/structure/test-secret-scan-gate.sh"
  - "tests/structure/test-msys-runtime-boundaries.sh"
---

# Hook Process Budget (`tests/structure/test-hook-process-budget.sh`)

Git Bash for Windows pays a full process creation for every hook process the host starts, every
program a hook starts and every `$(...)` subshell. Measured with the budget suite on macOS
(bash 3.2), in an armed session:

| Call | Before stage 1 | After stage 1 | After stage 2 | After stage 3 |
|---|---|---|---|---|
| Bash | 56 programs | 9 hook processes, 18 programs (8 `node`) | 2 hook processes, 0 programs | unchanged |
| Read | 11 programs | 3 hook processes, 1 program (1 `node`) | 2 hook processes, 0 programs | unchanged |
| Edit | 122 programs | 7 hook processes, 41 programs (33 `node`) | 6 hook processes, 34 programs (28 `node`) | 2 hook processes, 0 programs |
| NotebookEdit | | | 4 hook processes, 3 programs (2 `node`) | 2 hook processes, 0 programs |
| Agent | | | 4 hook processes, 11 programs (9 `node`) | 3 hook processes, 6 programs (5 `node`) |

Stage 3 was measured with the suite's armed vanilla fixture. A strict chain, a deny and a bind failure
still run the edit gate's body. `B4` holds a strict chain's count: 2 hook processes and 59 programs (40
`node`), against 6 hook processes and 62 programs (43 `node`) before stage 3. The groups left out,
measured the same way: `ExitPlanMode` 3 hook
processes and 31 programs (21 `node`), `Workflow` 3 and 2 (1 `node`), and the `Agent` row above,
whose 6 programs are `post-review-tdd-delegate.sh`. Those three fire per plan, per workflow and per
subagent rather than per ordinary tool call, and most of their work is the body itself, so folding
one saves its one hook process.

**The suite counts every hook process and every program a hook starts through `PATH`.** It
writes a shim for every executable name on the runner's `PATH`, runs every registration
`hooks.json` holds for a Bash, a Read and an Edit payload in an armed session with `PATH` set to
the shim directory alone, counts each registration it runs as one hook process (a dispatcher
registration as one `node` process), and compares the three totals with `budget()`. A program
started by an absolute path is not counted. The budgets are the measured totals, so a hook that
starts one more process fails `B3`; lower the budget when a change removes one. On Git Bash the suite skips: the budgets are calibrated on
POSIX hosts, and its counting shims, which wrap every `PATH` program by name, were never run
against Windows executables.

## The dispatcher (`hooks/lib/hook-dispatch-v1.js`)

- **Registration.** `hooks/hooks.json` registers it once for `PreToolUse` and once for
  `PostToolUse`, on the group matcher `.*`, in exec form: `"command": "node"` and `"args":
  ["${CLAUDE_PLUGIN_ROOT}/hooks/lib/hook-dispatch-v1.js", "pre"]` (or `"post"`), `"timeout": 60`,
  and `"onFailure": "block"` on `PreToolUse` only. The supported host floor, Claude Code 2.1.296,
  reads both keys: its hook schema describes `args` as exec form spawned without a shell, with
  `${CLAUDE_PLUGIN_ROOT}` substituted per element, and `onFailure: "block"` as counting a failed
  start, a timeout, an exit other than 0 or 2 or invalid output as exit 2 (read from the 2.1.296
  binary, not executed). On a host that ignored `args`, `node` would read the payload as a
  program and every gate would fail open, so never ship exec form above the supported floor.
  `onFailure` is ignored on `Stop`-like events and for async hooks; `PostToolUse` does not set it,
  so a failing post dispatcher is a non-blocking hook error and its checks fail open.
- **The check registry** is `DISPATCHED_CHECKS` in `hooks/lib/hook-registration-v1.js`: one frozen
  `{ event, name, matcher, script, body, failure }` per check, in the order the nine registrations
  had, the capability check first. `matcher` is the original host matcher string, evaluated with
  `hostMatcherCovers`, so a `Bash|PowerShell` check never runs for `Read` and an
  `Edit|Write|MultiEdit` check never runs for `NotebookEdit`, which an unanchored regular expression
  would select. `script` names the entry point under `hooks/`, `body` the old hook body under
  `hooks/checks/` (`null` for the capability, redact, data-guard and spawn-grant checks, which run
  in-process only), and `failure` the policy. A hook that had several registrations has one entry
  per original group, under its own `name` and with the same `script`, `body` and `failure`
  (`secret-scan`, `secret-scan-write`, `secret-scan-notebook`), and its entry point dispatches the
  first of them. The registry is one key set: a further key is a strict-key-set change.
- **Sequential, one budget.** Checks run one after another inside one 55 s budget under the
  60 s registration timeout; a delegated body gets the rest of that budget, at least 1 s. This
  removes the sibling race of separate hook processes and costs a slow check's time to the
  checks behind it.
- **Failure policy per check.** The capability check, the source-write gate and the browser
  consent gate on a marked call fail closed: exit 2 with the check's message. The CLI gate, the
  secret scan, the work-order checks, the redact sweep, the consent recorder, the data guard and the
  edit gate fail open with a stderr line, as the separate hooks did: a host treated their crash or
  timeout as a non-blocking error. The edit gate's own fail-closed decisions are denies of its body,
  not this policy. The spawn grant fails silent.
- **The edit gate allows in-process and decides nothing else** (`editGateAllows`). It answers true
  only for a child principal, another tool, a bound session with a valid document and no active
  chain, or an active vanilla chain and a target that `editPathClass` does not class as state. A
  strict chain, a bind failure, a missing or invalid document, a missing shell library,
  `ZENSU_TDD_GATE=off`, an unrenderable path and any exception run `hooks/checks/pre-edit-tdd-reminder.sh`,
  so every deny and the bypass ledger stay the body's. `hooks/lib/edit-path-class-v1.js` is the one path
  classifier: the body runs it as a program and the dispatcher requires it. Both hand it the workflow
  document, so a declared code root's `.zensu/state` classes as state on both paths
  (`.claude/rules/multi-repo-code-roots.md`). `D1` in the budget suite
  compares the body and the check byte for byte over the states it drives.
- **The data guard's caller directory.** A full dispatcher run anchors a relative target at
  its own working directory, and only an `--only` run reads `ZENSU_GUARD_CALLER_CWD`, which the wrapper
  exports unconditionally before its `cd -P`. `G47` pins that an inherited value decides nothing.
- **Aggregation like the host.** deny > defer > ask > allow; the reasons of the winning decision
  join in registry order; `additionalContext` joins in registry order, capped at 10,000
  characters with the capability check's text first; `systemMessage`, `decision: "block"`,
  `continue: false` and `suppressOutput` are all kept. A single output passes through unchanged.
- **Hybrid execution.** Fast paths run in-process; a rare input delegates to the check's bash
  body with the raw payload on stdin, the original environment and the hook's working directory.
  On win32 the body runs under Git Bash, found through `SHELL`, `CLAUDE_CODE_GIT_BASH_PATH`, the
  Program Files installs and the directory of `git`; without one, the check fails by its policy.
- **Pre-check copies.** `secretScanSkipsBash` is a hand copy of the shell pre-check in
  `hooks/checks/pre-write-secret-scan.sh` (§"Secret-scan pre-check"). `consentMarked` decides
  whether a consent body runs and must mark every payload the prefilter library marks
  (`.claude/rules/browser-consent-gate.md`). The unit file holds both.
- **Entry points stay.** Each old `hooks/<name>.sh` is a wrapper that runs
  `hook-dispatch-v1.js <pre|post> --only <check>` through `hooks/lib/zensu-hook-dispatch.sh`,
  which runs the named check whatever its matcher and reproduces the old hook's output and exit
  status. Without `node` a wrapper with a body runs it directly, as the old hook behaved, the
  capability wrapper refuses with exit 2 and names `node`, the redact and data-guard wrappers write
  their stderr notes and allow, and the spawn-grant wrapper exits 0 without a word. The capability wrapper keeps the guarded capture
  (`zensu_hook_dispatch_guarded`), so a dispatcher that cannot start still refuses with exit 2
  and a one-line reason.
- **One registration reader.** `registration()`, `hookEntries` and `registeredHooks` in
  `hook-registration-v1.js` expand a dispatcher entry into one virtual
  `bash "${CLAUDE_PLUGIN_ROOT}/hooks/<script>"` entry per check, carrying the check's matcher, so the
  consent readiness probe, the doctor's wiring row, `shell-tool-coverage-v1.js` and the suites that
  enumerate hooks keep their answers. `dispatcherEvent` recognizes only the canonical exec form.
- **The evaluator reads the registry as data.** `evals/session-control/lib/upgrade-hook-contract.js`
  loads `DISPATCHED_CHECKS` in a `vm` context whose `require` throws, validates every entry's key
  set and order, accepts a dispatcher entry only in its canonical exec form on the `.*` group,
  attests the dispatcher, the registry, every entry point and every body, and reports
  `observedHookProcesses` (`hook-dispatch-v1.js:pre` for a dispatched event). The live provider
  traces the dispatcher through its own `node` shim, contains it in the same Bubblewrap profile as
  a Bash hook and counts processes, not scripts. `test-doctor.sh` P2n exempts both readers of
  exec-form `args`.

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

For a bound session the dispatcher decides a Bash payload in-process through
`secretScanSkipsBash`; the shell copy below runs in `hooks/checks/pre-write-secret-scan.sh` when
the dispatcher delegates (no binding) or `node` is missing. Both copies carry the same token list,
and a channel added to `detectChannels` adds its token to both. The body still binds first. For a payload whose only unescaped `"tool_name"` is
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
- `ExitPlanMode`, `Workflow` and the `Agent|Task` PostToolUse delegate keep their registrations, for
  the reason under the table above.
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

**Version: stage 3 is `minor`.** It removes seven registrations and changes the matchers the host
evaluates for the edit, notebook and spawn groups, and the data-guard, edit-gate and grant
decisions now run in a process whose fault blocks the call. Every allow, deny, ask and context for
a tool-call payload is meant to be unchanged. Failure modes that change:

- the checks share one 55 s budget. An edit-gate body that runs past what is left of it fails open
  with a stderr line, so a strict-chain deny is lost where the separate hook still had its own 60 s,
  and the secret scan behind it runs with at least 1 s. Only a strict chain, a deny or a bind failure
  starts that body;
- the in-process checks have no deadline of their own. A hang in the data guard's walk, the secret
  scan or the workflow read reaches the 60 s registration timeout, which `onFailure: "block"` turns
  into a refusal of the call, where the separate hook's timeout let the call through;
- on win32 the edit-gate body needs the Git Bash lookup of the delegates. Without one it fails open.

**Version: stage 2 is `minor`.** It removes nine registrations, adds a decision-capable hook on
`.*` and changes the matchers the host evaluates, each a breaking change under
`.claude/rules/runtime-lineage.md`. Every allow and deny for a tool-call payload is meant to be
unchanged; the failure modes that change are a missing `node`, which the host now reports as a
failed start of the dispatcher, and a dispatcher fault, which blocks every `PreToolUse` call.

**Stage 1 was `patch`.** No schema field, strict key set, hook registration, matcher, config key or
attestation moved, and every allow and deny for a tool-call payload was unchanged. Two failure
modes changed, both toward fewer denies: the capability gate no longer needs a writable `TMPDIR`,
so an unwritable one no longer denies every tool call (pinned in
`tests/structure/test-reviewer-capability-gate.sh`), and the host-path helper no longer runs
`uname`, so a missing or failing `uname` no longer makes it refuse
(`tests/structure/test-msys-runtime-boundaries.sh` retired that case).

**Known gaps:** The spawn grant's `spawnGrantLibrariesPresent` and the two line-break refusals are hand
copies of what the old shell path did through `source`, `zensu_msys_env_exclusions` and
`_zensu_config_native_path`; `C1d`, `D5c` and the unit case hold them. Windows is unmeasured: the suite skips on Git Bash, and the blocking Windows
shards have no room for it, so the Git Bash lookup of the delegates has run only in unit form.
Stage 3 started before the stage 2 release and before a green Windows Safety run on the dispatcher.
On win32 a target spelled with a leading slash or backslash runs the edit gate's body, because only
`cygpath` can render an MSYS mount.
The live upgrade eval was not run for stage 2: it needs a real Claude Code, credentials and
Linux Bubblewrap. Its `node` shim and process counts ran in the local provider selftest in test
mode, and the contained dispatcher runs in the CI sandbox job's integration test. Wall time is
unmeasured: sequential checks can take longer than the slowest of nine parallel hooks when
several delegate. A single-letter directory at the MSYS installation root, which a
drive letter can shadow, is not told apart from that drive by the drive fast path.
