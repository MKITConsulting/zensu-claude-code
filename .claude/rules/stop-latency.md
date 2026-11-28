---
paths:
  - "hooks/stop-chain-enforcer.sh"
  - "hooks/lib/zensu-stop-deadline.sh"
  - "hooks/lib/zensu-prompt-deadline.sh"
  - "hooks/lib/zensu-supervise.sh"
  - "hooks/lib/zensu-linked-session.sh"
  - "hooks/lib/stop-idle-probe-v1.js"
  - "hooks/lib/zensu-session.sh"
  - "hooks/lib/session-control-core-v1.js"
  - "tests/structure/test-stop-enforcer-latency.sh"
  - "tests/structure/test-linked-session-route.sh"
  - "tests/structure/test-deferred-review-claim.sh"
---

# Stop Hook Latency (`zensu-stop-deadline.sh` + `stop-idle-probe-v1.js`)

**Why the early exit and the deadline exist.** The full Stop path is expensive even for a
session with NO armed chain: it re-hashes the whole plugin runtime tree (`readContext` →
`computeRuntimeDigest`, ~5 MB) through `zensu_resolve_project_dir` calls and takes up to five
lock round trips (Autopilot read, deferred-review adoption, refusal-note clear, reconcile), so
under heavy load it runs for minutes. A Stop registration without a `timeout` gets the host
default of 600 s, and base macOS has neither `timeout` nor `gtimeout`, so nothing else bounds
it. The same Stop on the early exit spawns **4** `node` children and took **9–10 s** at load ~800.
A slow Stop hook delays every queued background-task notification of its session.

**Early exit.** After the principal check, the bind and the project-root resolution, one
`node` child (`stop-idle-probe-v1.js`) reads the session's own workflow document and lists
`.zensu/state`. It answers `idle` only when ALL of these hold, and `busy` on anything else,
including every exception:

- the document exists and passes `workflowChainSnapshot`, with no Autopilot link fields;
- the chain is inactive, or active with `implComplete` and `chainDone` both true;
- no entry matches `PENDING_WORK_ENTRY` (`autopilot-active*`, `autopilot-run*`,
  `pending-review*`, `reviewer-spawn-denied-*`);
- `.zensu` and `state` are real directories and the `STORAGE_LEAVES` pass their type check.

`idle-bypasses` is `idle` with a non-empty `bypasses` array; the hook then releases only while
`hooks.chainEnforcer` is enabled (one more `node` child). `ZENSU_CHAIN=off` skips the early exit.

**Why each clause, and the sites it mirrors.** The predicate is a mirror of what the full path
ACTS ON for an otherwise idle session; a new state file the full path acts on must join it, or
the early exit releases past it.
- `PENDING_WORK_ENTRY` mirrors the hint globs in the hook, `zensu_pending_review_file` and
  `zensu_pending_review_claim_file` in `zensu-tdd-phase.sh`, and `reviewer_denial_note_path`
  plus the reaper glob in the hook. Any denial note — any session's — sends the Stop down the
  full path, which keeps the reaper running.
- `STORAGE_LEAVES` mirrors `_autopilot_storage_safe` in `zensu-autopilot-state.sh`, whose
  refusal makes the full path block as unsafe. `autopilot-active.json` is in the pattern.
- `workflowChainSnapshot` in `session-control-core-v1.js` is the ONE owner of the Stop
  snapshot shape. `tdd_chain_snapshot` and the probe both call it, so the early exit cannot
  release a document the full path rejects as corrupt.
- `ZENSU_CHAIN=off` records a bypass for an active chain, including a done one, so it keeps the
  full path. The disabled-enforcer branch renders the ledger line, and §"Bypass Ledger Read
  Contract" requires every release path above the routing branches to disclose: the early exit
  releases only where the full path would render nothing.
- Deliberate divergence: where the full path would BLOCK only because the adoption or reconcile
  machinery could not run (lease contention, storage preparation) while none of the files it
  looks for exist, the early exit releases.

**Deadline.** The hook re-runs itself as `--zensu-stop-worker` through `zensu_supervise`, the one
process-group supervisor in `hooks/lib/zensu-supervise.sh` (§"One supervisor" below): the worker
runs in its own process group (`set -m`), with stdin, stdout and stderr in a private `mktemp -d`
directory. The watchdog is a second job in a process group of its own: at the deadline it marks the
directory and sends `SIGKILL` to the worker's group. A decision already written is forwarded and stands; otherwise
the Stop is RELEASED with a stderr notice, and the supervisor writes the same text as a
`systemMessage` because the worker's stdout file is empty. `SIGTERM`, `SIGINT` or `SIGHUP` to
the supervisor kills both groups at once.

- **Neither group is the host's, and that is what keeps the bound.** A hook shares the Claude
  Code CLI's process group, and the host can reap that group. When the
  supervisor dies that way, the watchdog outlives it, kills the worker at the deadline and
  removes the directory. Every kill names a job leader's own group (`kill -- -<leader>`), and the
  bare pid only where the job led no group of its own when it started; nothing here may ever use
  `kill 0`, which from a shared group
  would kill the host.
- Worker output goes to files, never to the host's pipes, so a surviving grandchild cannot hold
  them open. A kill mid-lease is safe: `artifactIsStale` treats a dead owner as stale at once.

- **Release, not block, on expiry.** Blocking loops an overloaded session: each retry costs a
  turn plus another full deadline, and the stop-budget counter that bounds block loops lives in
  the path that did not finish. It also follows this hook's rule for "could not evaluate, no
  corruption seen": release, and say no completion was proven.
- **Bounds.** Default 45 s; `ZENSU_STOP_DEADLINE_SECONDS` clamps to 10–75 s; host `timeout` 90 s.
  `L19` pins host ≥ ceiling + 10 and ≤ 120. 45 s, not 30 s, because an armed Stop is slow on
  Windows: the routing suite's single-Stop checks took 19.0–19.9 s each on the Windows runner
  (green run 36556263889, session setup included), and a deadline near that figure would
  silently stop enforcing there. The floor keeps a lowered value above an ordinary macOS or
  Linux armed Stop.
- **A kill can land inside an adopting bind.** All three supervised workers bind with automatic
  adoption opted in (`.claude/rules/automatic-adoption.md`), so a deadline kill can fall
  between the adoption's copy to the superseded name and its record swap, or inside the copy.
  The window is one file copy and one rename. The next bind that adopts completes the
  interrupted adoption (`.claude/rules/automatic-adoption.md` §"Interrupted adoptions"). A kill
  after the swap leaves a served record without its `RUNTIME_ADOPTED` entry and lease sweep, the
  residual that section names.

**One supervisor (`hooks/lib/zensu-supervise.sh`).** Three callers bound a child with the same
process-group shape: this hook, the prompt library (`hooks/lib/zensu-prompt-deadline.sh`), which
supervises `hooks/user-prompt-tdd-reminder.sh` and `hooks/user-prompt-zen-mode.sh`
(`.claude/rules/session-delivery-route.md` §"The reminder's time budget",
`.claude/rules/prompt-origin.md` §"Process budget"), and the lineage read inside the reminder
(`_zensu_linked_session_answer` in `hooks/lib/zensu-linked-session.sh`). One owner holds that
shape, and each caller hands it the two things that differ: its bound and its deadline action.

- **What the owner holds.** `zensu_supervise_files PREFIX INPUT` makes the private `mktemp -d`
  directory with the worker's stdin and names it in `ZENSU_SUPERVISE_WORK`.
  `zensu_supervise ACTION SECONDS WORK COMMAND...` starts COMMAND as the background job under
  `set -m`, so it leads a process group of its own, with its stdio in WORK's files, or inherited
  when WORK is empty. It starts the watchdog in a group of its own, which sleeps SECONDS, marks the
  deadline in WORK, kills the worker and removes WORK once the supervisor is gone. It waits for the
  worker with stderr discarded, kills the watchdog's group, and holds the TERM, INT and HUP abort
  traps (143, 130, 129) and the EXIT cleanup while it runs. A worker that finished in time is
  forwarded through `zensu_supervise_forward`, which returns 0 only when it forwarded stdout, and
  keeps its status. At the deadline, which is WORK's marker, or exit status 137 without WORK, the
  owner calls `ACTION WORK` instead and returns the action's status.
- **The directory's names.** The owner writes `in`, `out`, `err` and `deadline` in WORK, and only
  the owner reads `out` and `err`: an action asks `zensu_supervise_forward`. The prompt library adds
  its own names in the same directory (`done`, `classified`, `fact-<name>`) and its worker checks
  `in`, so a rename of `in` or `deadline` touches `hooks/lib/zensu-prompt-deadline.sh` too.
- **Every kill.** `_zensu_supervise_kill_group LEADER MODE` refuses an empty leader, `0`, `1`, a
  zero-led and a non-numeric one, so no kill can reach `kill -- -1` or the caller's own group. Right
  after the start the owner records whether the worker leads a group of its own (`kill -0 -- -<pid>`):
  in `group` mode every kill of the worker names its group only, so a watchdog that fires after the
  worker was reaped signals a process that reused the ID only when that process leads a group of
  that ID; in `pid` mode, where the job led no group, it kills the bare pid. A kill without a mode,
  which the watchdog's own kill uses, tries the group and falls back to the bare pid.
- **What it refuses.** Fewer than four arguments, and a non-empty WORK other than the directory the
  last `zensu_supervise_files` made, a symlink or a missing directory, return 1 before anything
  starts: never 2, which a Stop or prompt hook reads as blocking, and never a removal of a directory
  the owner did not make.
- **What each caller keeps.** This hook: the 10 to 75 s deadline and `_zensu_stop_deadline_action`,
  which forwards a decision already written and otherwise adds the release notice and its
  `systemMessage`. The prompt library, for the reminder and zen-mode alike: the 10 to 20 s deadline
  less the whole seconds already spent, its worker arguments and `_zensu_prompt_deadline_action`,
  which forwards a worker that marked its output delivered and otherwise runs the fallback its hook
  names (`emit_deadline_fallback`, `zen_deadline_fallback`) over the facts the worker recorded. The
  lineage read: the budget it is handed, no private directory, the resolver itself as the job, and
  `_zensu_linked_session_deadline_action`, whose 124 `zensu_linked_session_resolve` reads as
  `deferred`. An action receives only the directory; whatever else it needs travels in its library's
  globals, set right before the call (`_ZENSU_STOP_DEADLINE`, `_ZENSU_PROMPT_FALLBACK`,
  `_ZENSU_PROMPT_DEADLINE`).
- **One fix site.** A change to a kill, its Git Bash fallback, the cleanup or the abort traps is made
  once. `L28b` here fails when another file under `hooks/` turns job control on in any spelling
  (`set -m`, a `set` flag group holding `m`, `set -o monitor`) or sends a kill to a negative pid, or
  when one of the three callers stops handing `zensu_supervise` its action outside a comment. `L28c`
  pins the owner's kills, refusals, action arguments and forwarder status, and `L28d` the two
  deadline libraries when the owner is missing or a symlink.
- **No new process.** The owner starts what the copies started: the directory, the worker, the
  watchdog and its `sleep` for the two hook supervisors, and the resolver, the watchdog and its
  `sleep` for the lineage read; the mode check is the `kill` builtin. The forwarder skips `cat` for an
  empty file, so the reminder starts one `cat` fewer for a worker that printed nothing. Each library
  sources the owner from its own directory by parameter expansion, with no subshell, and only when it
  is a regular file and no symlink, as the hooks load the deadline libraries. When the owner did not
  load, the Stop hook and the reminder run unsupervised, as they do without their deadline library,
  and a budgeted lineage read answers `deferred` without starting the resolver (`L28d`, `L72d` in
  `tests/structure/test-linked-session-route.sh`).
- **Three differences from the former copies, all deliberate.** The Stop supervisor now waits on its
  worker with stderr discarded, as the reminder's did, so a deadline kill no longer adds bash's
  `line N: <pid> Killed: 9 …` job notice to this hook's stderr (measured on `/bin/bash` 3.2.57;
  `L20` and `L27` require its absence); the release notice, its `systemMessage` and the exit status
  are unchanged. The lineage read gets the abort traps: a SIGTERM, SIGINT or SIGHUP to the shell that
  supervises it stops the resolver's and the watchdog's groups at once and exits 143, 130 or 129,
  the status that signal gave the shell before, where the two groups used to run on until the budget
  (`L72c`). The reminder's deadline kills that shell with SIGKILL, which runs no trap, so a resolver
  and its watchdog still outlive a reminder deadline (`L72`, `L72b`). And a worker that led its own
  group is killed through that group alone: the bare-pid fallback the three copies always added now
  runs only in `pid` mode.
- **Bounds.** The owner holds the shell's TERM, INT, HUP and EXIT traps while it runs and clears
  them when it returns, and it leaves job control off (`set +m`) whatever the caller had, so a
  caller supervises from a shell that exits right after it, as both hook supervisors do, or from a
  subshell, as the lineage read does inside its command substitution. Moving the lineage read out of
  that substitution would let the owner clear the reminder worker's own EXIT trap
  (`zensu_prompt_delivered`). The watchdog removes the directory only once the supervisor's PID is
  gone; that PID is `BASHPID`, or `$$` on bash 3.2, which has no `BASHPID`, so a caller with a
  private directory supervises from its shell's top level. A prefix assignment on the call reaches
  the job: the lineage read passes the resolver's two variables that way, and on `/bin/bash` 3.2.57
  they reach the background job and do not outlive the call.

**User-visible notices (`stop_notice` + `emit_stop_notices`).** Claude Code shows the stderr of
an exit-0 Stop hook to nobody (read from the host binary; `.claude/rules/autopilot-run-scope.md`
records the measurement). Every release, cap and nudge notice of the hook goes through
`stop_notice`, which writes the line to stderr for the transcript and appends it to
`STOP_NOTICES`. The EXIT trap `emit_stop_notices` writes the collected lines as ONE
`{"systemMessage": …}` object, and only while nothing else reached stdout: a host that reads two
JSON objects parses neither, so a second object would cost the block decision itself.

- **Every stdout writer sets `DECISION_EMITTED`**: `emit_block`, the five literal emitters and the
  three inline blocks of the inner-state snapshot. `emit_block` carries the notices collected
  before it on the same object, `decision` first. A notice written after a block stays on stderr;
  the nudge, the three background-wait releases (the workflow wait, the background review wait
  and the explicit `ZENSU-AWAIT:` wait of `.claude/rules/stop-background-wait.md`) and the
  acceptance hand-off release of `.claude/rules/acceptance-verification-gate.md` already return
  on `DECISION_EMITTED`.
- **The supervisor writes only into an empty stdout.** Its deadline release becomes a
  `systemMessage` only when the worker's stdout file is empty, and a worker killed at the deadline
  never ran its trap, so the two never both write.
- **Values reach `node` on stdin**, the block reason and the notices separated by a NUL, never
  through the environment, which MSYS rewrites when a value looks like a path.
- **Not routed:** the three stderr lines that precede a block (its reason is what the user sees),
  the informational re-bind line, and the library's fence stand-down line, which would repeat at
  every turn end of a steady state.
- **Cost:** one `node` child per Stop that carries a notice and no block.
- **Pins:** `E1b`/`E3c` in `test-stop-enforcer-escapes.sh`; `L1b`, `L4`, `L20`, `L22` and `L27`
  here; `C5c`, `C27a`, `C27c`, `C28a` and the source count `C32pre` in
  `test-impl-stop-counter.sh`; `X13` in `test-external-review-hook.sh`; `BR11` in
  `test-background-review.sh`; `B4` in `test-stop-background-wait.sh`; `S3b` (the merge) and `S10`
  in `test-autopilot-stop-enforcer.sh`; the release rows and the `stop_notice` anchor of `AC-C19` in
  `test-versioned-plugin-upgrade.sh`.
- **Version: `patch`.** No hook added or re-matched and no `permissionDecision`; the decision a
  Stop emits is unchanged, and only advisory output joins stdout.

**One resolution per run (`zensu_memoize_project_dir` + the canonical-key shortcut).** Every
project-root verification (`zensu_resolve_project_dir`) is a record read plus a runtime digest
in a `node` child. Measured with a classifying `node` shim, an armed Stop without the memo and
the shortcut makes 28 verifications and 18 `session-key` calls, 17 of them on a key that is
already canonical; with them it makes one verification and no `session-key` call.

- **Session key.** `sessionKey` returns a value matching `^scv1_[a-f0-9]{64}$` unchanged, so
  `zensu_session_key_canonical` answers that one shape in shell and every other input still
  goes to the core. It is a pure-function shortcut, not a cache, and applies to every caller of
  `zensu_resolve_session_id`. The pattern lists the hex digits instead of using a range, so no
  collation can widen it. `SESSION_KEY_RE` in `session-control-core-v1.js` owns the shape;
  `L38` and `L42` hold the shell copy to it, so a drift between the two surfaces there as a
  spawn-count or output failure. The hook passes no raw id: the bind already derives
  the key from the same payload, so `zensu_resolve_session_id ""` returns the bound key.
- **One shell spelling of the key shape.** `zensu_session_key_canonical` is public and sits in
  the `export -f` list of the non-Windows arm, and `reviewer_denial_note_path` in the Stop hook
  calls it instead of keeping a test of its own, because a range form such as
  `scv1_*[!0-9a-f]*` plus 64 `?` collates. Measured on macOS `/bin/bash` 3.2.57 under
  `LC_ALL=en_US.UTF-8`: `[a-f]` matches `B` and `é`, so that range form accepts `scv1_` plus 63
  hex digits plus `B`. The doctor's
  `^reviewer-spawn-denied-scv1_[a-f0-9]{64}\.json$` in `reviewerDenialRows` and the reaper's
  `NAME` never match such a name, which is the "doctor goes quiet with everything still green"
  failure the comment in that function names. `L42b` runs the predicate under `LC_ALL=en_US.UTF-8` and requires a canonical
  control to pass and an upper-case and an accented last character to fail. It discriminates
  only in a shell whose bracket ranges collate under that locale: macOS `/bin/bash` 3.2.57 does,
  the local `bash:5` image (musl) does not, and the check's label says which case ran.
- **Every shell test of the shape calls it.** `grep -rn 'scv1_' hooks/` is the census
  (`.claude/rules/foreign-chain-row.md`). The receipt fallback in `zensu-edit-landing.sh` calls
  the predicate in a subshell (`.claude/rules/multi-repo-stage1.md` records why, together with
  the locale measurement of a range test), and the session-pair guard in
  `zensu-doctor.sh` calls it in the subshell that already sources this file. The other hits in
  shell files are file-name prefix globs such as `tdd-phase-scv1_*.json` and JavaScript regexes
  inside `node` programs, and neither collates.
- **Project root.** `zensu_memoize_project_dir` renders the root (`cd -P && pwd -P`), runs the
  full verification once, and records `(ZENSU_PROJECT_ROOT, ZENSU_SESSION_CONTEXT,
  ZENSU_SESSION_KEY, rendered root)` in the shell ARRAY `_ZENSU_PROJECT_DIR_MEMO` only when the
  verified render is the path it rendered before. An ancestor swapped between the verification
  and its render is therefore never memoized (`L52`). A later `zensu_resolve_project_dir` still
  runs every shell-side check and skips only the `node` child, and only when all three inputs
  match as spelled and the root still renders to the recorded physical path. Any mismatch falls
  through to the full verification (`L43`–`L46`, `L50`); a record that vanished or became a
  link is refused before the memo is consulted (`L47`, `L48`).
- **One verification decides.** The Stop hook's first verification IS
  `zensu_memoize_project_dir`. When it fails, the hook takes its failure branch
  directly (`L51`), so a refusal costs one verification, and a Stop
  that proceeds always holds the memo.
- **Why an array.** An environment variable becomes a scalar, which fills index 0 only, and
  bash never exports an array. The memo is accepted only when index 3 is set, so no environment
  variable can stand in for it and no child process inherits it; `L33` and `L35` pin both. Both
  bind functions unset it (`L36`, `L49`). A variable or a file that a model-side Bash command
  could set is never a pre-verified binding; `CONTROL_BINDINGS` needs no new entry for that
  reason.
- **Opt-in, four callers.** The Stop hook and `hooks/post-review-tdd-delegate.sh` call
  `zensu_memoize_project_dir`, each right after its only bind, and `_zensu_bound_work_tree_lookup`
  in `zensu-log.sh` calls it first, inside the subshell `_zensu_bound_work_tree` runs it in, so
  that memo ends with the subshell. Every other entry point verifies on every call, and
  the rest of `zensu-log.sh` is a candidate, not a caller. A further caller may memoize
  only after its last bind, and only in a process that runs no record writer. The lookup subshell
  meets both: the verb bound before it started, and it only reads the workflow document and the
  run record and writes its answers into the transport directory. Measured with a counting shim on
  an Autopilot-bound chain's `zensu-log.sh --chain-work-tree --project-dir --session`, the call the
  post-review delegate makes on every review completion of such a chain: 18 `node` children
  without the memo on macOS bash 3.2.57, ten of them root verifications, and 10 with it, two of
  them root verifications, on that host and on Linux bash 5.2.15; `C33` in
  `tests/structure/test-full-suite-ci.sh` holds the 10. The delegate meets
  both: its one bind precedes the memo, and what it writes afterwards is the workflow document's
  ticket claim and the background-review store, never the context record. Measured with the
  counting shim on one background hand-back claim through the real prompt hook: 89 `node` children
  without the memo, 35 of them root verifications, and 55 with it, one of them a root
  verification. The shipped path, which also runs `arrive` first, spawned 56 in `BR4b` on
  2026-10-27, three of them after the claim returned: the record retire, the claim-field parse
  and the emit. `BR4b` in `tests/structure/test-background-review.sh`
  pins the single verification (`.claude/rules/background-review-completion.md`).
  `hooks/user-prompt-tdd-reminder.sh` is the fourth caller. It memoizes right after its origin and
  slash-command exits, so a task notification or a bare slash command pays nothing extra. Its one
  bind comes before the memo and can re-mint the context record through automatic adoption; after
  the memo the reminder writes only `.zensu/state` markers and the prompt ledger.
  Measured with a classifying `node` shim on a linked session's first prompt: 16 `node` children,
  six of them root verifications (`tdd_state_file`, four inside `tdd_session_active`, the route
  root), before the memo and the one-read payload change, and 9 with one verification after them.
  `L59` in `tests/structure/test-linked-session-route.sh` holds both numbers
  (`.claude/rules/session-delivery-route.md` §"The reminder's time budget").
- **What a reuse does not re-check.** The record file's content and the runtime digest are read
  once per hook run. A record or plugin tree changed WHILE one Stop runs is not seen again. The
  digest was never a defence there, because a changed tree includes the code that checks it.
  Two writers replace the record behind a session. Automatic adoption re-mints it around the
  same project root, so the memo stays right. A re-anchor (`performReanchor`) supersedes it at
  the same key and path with a NEW project root, and a Stop already running keeps answering the
  old root until it ends. What bounds that window is the re-anchor's own refusal while the
  workflow document holds open work or the session owns an open Autopilot run
  (`.claude/rules/session-reanchor.md`).
- **Coupled sites.** The suite's counting shim classifies a spawn by two literals: the inline
  `core.readContext({ recordsDir, sessionId: key })` in `zensu_resolve_project_dir` and the argv
  `session-control-core-v1.js session-key `. Rewording either turns the count checks of the
  latency suite red, and rewording the first also those of `BR4b` in
  `tests/structure/test-background-review.sh`, `Z107i` and `Z118` in
  `tests/structure/test-zen-mode.sh` and the budget block of
  `tests/structure/test-linked-session-route.sh` (`L59` and its hung-child cases), whose shims
  classify by the same literal. Three in-code rationales assume every `zensu_resolve_project_dir` call
  spawns `node`: the optional argument of `zensu_pending_review_claim_file` in
  `zensu-tdd-phase.sh`, the `zensu_pending_review_file` note in `zensu-autopilot-state.sh`, and
  the `S7t` comment in `tests/structure/test-autopilot-stop-enforcer.sh`. They hold for every
  caller that does not memoize; on the Stop path, in the post-review delegate, inside the
  work-tree lookup and in the prompt reminder the memo answers instead.
- **Port.** Host half only; `session-control-core-v1.js` is unchanged. `zensu-codex`,
  `zensu-kiro` and `zensu-antigravity` were NOT included. A port that adopts the memo must take
  the `_ZENSU_PROJECT_DIR_MEMO` unset in both bind functions with it, or a re-bind keeps a stale
  memo.
- **Rejected.** Priming the memo from the bind: `validateContext` canonicalizes the recorded
  root without comparing it, so the bind accepts a root reached through a symlinked ancestor
  that the resolver refuses. A cache file: poisonable. Memoizing `_tdd_paths_safe`: it is the
  per-operation symlink check and must see every swap.

**Lease checks inside the lock process (`hooks/lib/state-path-safety-v1.js`).** The storage walk
of `_tdd_locked_run` lives in `state-path-safety-v1.js` and runs inside the process that takes the
lease, before the acquisition and again after it, rather than as `node` children of their own
around the lease. A lease costs two children on bash 3.2 (acquire with checks, release by token)
and one on bash 4+ (the keeper); `P9` in `tests/structure/test-tdd-no-flock-external-lease.sh`
pins both counts.

- **Order of observations.** The post-acquisition walk is the last full walk before the callback.
  Between it and the callback only builtins run: the leaf re-check `_tdd_paths_leaf_safe` (`[ -L ]`,
  `-e`, `-f`, `-d`, no command substitution) and, on bash 3.2, the token read with `read` plus one
  `rm` of the token file. That `rm` stays before the callback on purpose: after the release it
  would leave the token file behind whenever the deadline kills the worker mid-callback, and the
  walk-to-use window is dominated anyway by the callback's own `node` start. `_tdd_paths_safe` is
  still never memoized.
- **Fail-closed load.** Every caller loads the module with `require` and accepts only
  `pathsSafeArgv(...) === true`, so a missing, truncated or inert module refuses.
  `_tdd_paths_safe_check` carries the module path in the environment (`PATH_SAFETY`, mechanism 2
  of `test-msys-special-plugin-module-boundaries.sh`) and the rendered anchors and operands in
  argv under `MSYS2_ARG_CONV_EXCL='*'`. The module has no CLI and reads neither `process.env` nor
  `process.argv`. The lease processes take the module path in argv beside the control core's,
  which travels the same way.
- **Exit codes and lines.** The bash 3.2 acquirer exits 64 when a check fails before the
  acquisition (silent return 1), 65 when the storage is unsafe after it and the lease was released
  in-process (silent return 1), and 66 when that release failed (`lock release failed`, return 1).
  The keeper writes `UNSAFE` (nothing held, silent return 1) or `UNSAFE-HELD` (callback skipped,
  normal `RELEASE`, silent return 1). The keeper releases in-process, so the win32 holder
  marker is unaffected.
- **Pins.** `P7` plants a hard-linked `.lock` (link count 2, which only the module refuses) after
  `tests/structure/fixtures/lease-acquire-entry-preload.js` proves the contender is inside
  `acquireExternalProcessLock`; `P8` plants it before any acquisition and requires that the
  acquisition never started. Removing either walk turns the matching check red on bash 3.2 and on
  bash 5.2. `tests/structure/state-path-safety-v1.test.js` covers the refusals no shell leaf test
  sees, and the canary loads the module from a plugin root with whitespace and an apostrophe.

**Further cuts on the armed path.** Each removes a process whose observation is repeated, or moves
it into an adjacent process with no filesystem change in between.

- The reviewer-note lease is skipped when the probe verdict is neither `blocked` nor `clear`,
  because the callback then does nothing. `reviewer_denial_note_acts` is the one predicate for the
  guard and the callback, and the probe stays outside the lease. A status the callback learns to
  act on must join that predicate.
- `_tdd_atomic_replace_regular` walks its source and target as the first statement of its replace
  process; exit 64 maps to return 1, every other status passes through.
- The `read-active` worker derives the owner pointer from the digest rule the writers use through
  `_autopilot_active_path`, so the Stop path spawns no hashing child.
- `zensu_hook_principal` takes an optional payload field and then prints the principal, a newline
  and that field. The Stop hook decides on the text before the first newline and reads
  `transcript_path` from the rest, so no separate `read_field` runs.
- `tdd_chain_snapshot <file> <session> stop-fields` prints the eight Stop fields from the snapshot
  process. The field order lives in two places, that projection and the two `read` lists in the
  hook. `inner_flags_ok` refuses a line whose four flags are not exactly `true` or `false`, the
  check a `JSON.parse` would give; a projection fault exits 64, which the adoption site
  maps to its own refusal.

Measured with the latency suite's counting shim (`L30`), the armed Stop spawns 29 `node`
children on macOS bash 3.2 and 26 on Linux bash 5.2 (`node:20-bookworm`). `L30` allows 32 on
bash 3.2 and 30 on bash 4+, so reverting these cuts fails it on both.

**Not taken, and why.** Handing the idle probe's chain fields to the hook is unsound as
specified, because it removes the only check that acts on a read failure at that site. Merging two Autopilot config reads and computing the terminal-stage
bit in the outer parse save nothing on a measured path. Running the project-root check inside the
pre-lock storage process and moving the dispatcher's under-lock storage check into the
`read-active` worker would each save one child on the armed path, but both change the status
mapping that separates "no run" (which relaxes the guard) from a fault (5) and need their own
review. Folding the routing re-check after the budget increment (the exact-match comparison and,
when it fails, the mismatch classifier) into the fresh snapshot process would save one more child.
Both processes read only their pipe and the hook's own expected values, but the fold turns a
parse failure there from a release into a block, a decision change that needs its own pin. The deferred-review adoption path keeps its own candidates for a later change, and folds
inside the stop-budget and handoff critical sections are not fully judged.

**Known gaps.**
- A deadline release writes no bypass-ledger entry (the write needs the lease under the load
  that caused the deadline) and renders no ledger line. It is INDUCIBLE — by loading the machine,
  or by lowering `ZENSU_STOP_DEADLINE_SECONDS` in the Claude Code environment — the same class as
  the other inducible releases this hook records.
- The armed path still spawns 29 `node` children on macOS with bash 3.2 and 26 on Linux with
  bash 5.2 (`L30`). At 1.3–1.7 s per child under load 100–150 that is about 38–50 s on bash 3.2,
  so the 45 s deadline can still release an armed Stop on a heavily loaded Mac. These counts were
  not broken down by group. The deferred-review adoption path was not re-measured.
- A durable Autopilot Stop that reaches the stage budget spawns one more `node` child,
  `hooks/lib/review-evidence-hook-v1.js wait`, whose contract `.claude/rules/work-order-mode.md`
  owns. It runs through `zensu_run_bounded`, answers from one `lstat` when the session has no
  records directory in the review-evidence store, and otherwise binds the payload again,
  recomputing the runtime digest, before it reads the lease. `L30` drives a standalone chain and
  never reaches that path, so its cost is unmeasured. On base macOS the child has no watchdog of
  its own, only this hook's deadline; where one exists, a child that misses its 5 s under heavy
  load prints nothing, and that Stop counts against the stage budget.
- The memo and the shortcut were measured on macOS (bash 3.2.57) and on Linux (bash 5.2.15, in a
  container). Git Bash is unverified. The symlink checks `L13`, `L17d`, `L43`, `L48`, `L50`, `L51`
  and `L52` make their links through Node, never with `ln -s`, which Git Bash satisfies with a
  copy; the suite generates both helpers before `L13`. `L13`, `L17d`, `L43`, `L50`, `L51` and
  `L52` link a directory with `make_directory_symlink`: a junction on win32, a directory symlink
  elsewhere. `L13` uses it for the Autopilot sentinel too, a file leaf, because a junction needs
  no privilege, and the probe's `leafSafe` and `_tdd_paths_safe` both refuse any link before they
  look at its type. Its target does not exist: libuv's `fs__create_junction` never reads a
  junction's target, and `lstat` classifies the junction from its reparse data alone. `L48` links
  the session record, a file, which a junction cannot do. It uses `make_file_symlink`, a native
  file symlink, which Windows creates only for an elevated token or in Developer Mode, so `L48`
  keeps its skip arm. Each of the seven checks skips only when its helper fails, never on what
  `[ -L ]` reports: `L13`, `L17d` and `L50` read the helper's exit status, `L43`, `L48` and `L51`
  read exit code 5 of the memo driver, and `L52` reads the `.unlinked` marker of
  `swap-after-root.sh`. `L17d` depends on that: its state directory is moved aside before the
  link is made, and a missing state directory answers `busy` too. It removes the link with
  `rm -f`, which relies on Git Bash counting a junction as a symbolic link, as the msys2
  runtime's `check_reparse_point_target` does; if it does not, the state directory stays
  unrestored and the control `L17e` fails. The suite is excluded from the blocking Windows shards
  in `tests/profiles/windows-native-structure.v1.json` and runs in the weekly Windows Safety
  workflow through `ciStructureTests`.
- The early exit's wall time is dominated by two runtime-digest computations (bind and resolve).
- Under extreme local load a suite that drives the full Stop path can FAIL at the deadline
  instead of passing slowly; the release notice in its stderr names the cause. Measured at
  load ~740: the `hooks.chainEnforcer=false` branch needed more than 45 s.
- `test-deferred-review-claim.sh` runs EVERY Stop through the worker directly
  (`--zensu-stop-worker`, in its `stop()` helper), because it tests the claim protocol, not the
  bound; the latency suite pins the bound. The deadline is per Stop, and this suite's Stops are
  the slowest the hook makes. C1 starts 20 Stops together and took 186 s on the Windows runner
  on `main`; under the default deadline all 20 were released before any adopted the queued
  review. C7's Stops preload the owner observer into every Node child. On a slow
  `windows-shard-1` one of them was released mid-transfer (run 36724193854): the claim's lease
  was renewed, and the block decision was never written. A release whose decision was never
  written reads as `allow`, which such a check cannot tell apart from a protocol defect.
- On Git Bash the process-group kill is unverified; its fallback kills only the worker pid.

**Version: `patch`.** No schema field, no strict key set, no hook added, removed or renamed, no
matcher change, no `permissionDecision`; the knob is an environment variable, not a config key.
The per-run memo and the canonical-key shortcut persist nothing and add no hook, matcher, knob
or config key. Routing the denial-note name through `zensu_session_key_canonical` changes no
persisted shape: a canonical key yields the same file name as before. The lease checks, exit codes 64–66 and the
keeper lines are internal to `_tdd_locked_run`, and the third arguments of `tdd_chain_snapshot`
and `zensu_hook_principal` are optional, so every two-argument caller sees what it saw before.
The one supervisor is `patch` on the same walk: no schema field, strict key set, hook, matcher,
config key or attestation moves. Three in-tree libraries share one owner; the only output that
changes is a bash job notice no longer written to a released Stop's stderr, and the lineage read
now stops its resolver and watchdog on a signal it did not trap before.
