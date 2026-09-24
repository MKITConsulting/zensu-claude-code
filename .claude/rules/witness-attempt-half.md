---
paths:
  - "hooks/pre-bash-witness.sh"
  - "hooks/post-bash-witness.sh"
  - "hooks/lib/zensu-witness.sh"
  - "hooks/lib/zensu-evidence-crosscheck.js"
  - "tests/structure/test-post-bash-witness.sh"
  - "tests/structure/test-evidence-crosscheck.sh"
---

# Witness Attempt Half (`hooks/pre-bash-witness.sh` + `hooks/lib/zensu-witness.sh`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

The Phase 6 witness cross-check could corroborate a PASS and **structurally could not
corroborate a FAILURE**, and the cause is the host rather than any code in this repo.
Claude Code does not deliver `PostToolUse` for a Bash call that did not complete
successfully, so `hooks/post-bash-witness.sh` never ran for a failing command and the
witness log carried no record of it at all. Since
`hooks/lib/zensu-evidence-crosscheck.js` matches a CHECKPOINT/AUDIT claim against a
witness entry by EQUALITY, every claim naming a failing command could only ever reach
`EVIDENCE GAP` — the same verdict as a command that was never run. The evidence channel
was one-sided in exactly the direction evidence discipline cares about most.

**MEASURED, in both halves, and the two halves answer different questions.** Live, with
a chain armed: `bash -c 'echo …; exit 3'` produced zero matching witness lines while the
same command exiting 0 produced exactly one; in the wild, a structure suite exiting 1
produced no entry while four sibling suites exiting 0 immediately around it all did.
Against a fixture, the RESULT hook was fed five payload dialects — `exit_code: 3`,
`exit_code: 0`, a bare-string `tool_response`, no `tool_response` at all, and
`is_error: true` — and wrote a line for every one of them. So the hook has no branch on
the exit status and cannot be the cause; the missing line is the event never arriving.
Do not re-diagnose this as an early return in the writer. `P12-A0` in
`tests/structure/test-post-bash-witness.sh` keeps that control executed, precisely so the
next reader does not have to re-derive it.

**The fix is a SECOND writer on the one channel the host fires unconditionally.**
`hooks/pre-bash-witness.sh` runs on `PreToolUse` `Bash` and records
`BASH-ATTEMPT cmd="…"` before the command runs. An attempt with no matching completed
entry is then POSITIVE evidence rather than an absence, and the cross-check consumes it
as such:

| witness | claimed green | claimed non-pass |
|---------|---------------|------------------|
| attempt + completed | judged on the completed entry's `tail=`, unchanged | unchanged |
| attempt, no completed | `EVIDENCE CONTRADICTION` | **verified** — the direction that was unreachable |
| neither | `EVIDENCE GAP`, unchanged | `EVIDENCE GAP`, unchanged |

**Nothing about corroboration was widened to get there, and the check that proves it is
the one to keep.** A claim matching neither kind is still a gap; a log-writing command's
ATTEMPT is excluded exactly as its completed entry always was; and a witness log written
before this hook existed carries no attempt lines, so every verdict over it is
byte-identical to the previous behaviour. `P6d`, `P6f` and `P6g` in
`tests/structure/test-evidence-crosscheck.sh` are those three.

**The attempt line proves the call REACHED the Bash tool, never that it exited
non-zero**, and the wording must not be tightened. Every `PreToolUse` hook on a matcher
runs whatever any of them decides, so an attempt is recorded for a call another gate then
DENIES — and for one the user aborts. `ATTEMPT_ONLY_MARKER` therefore reads "the tool
call never completed (non-zero exit, interruption or denial)", and it is EXPORTED so no
consumer re-spells it.

**The fail-then-fix cycle is why the attempt records are not consulted once a completed
entry exists.** A command that failed, was fixed and re-ran green leaves two attempts and
one completed entry; treating the surplus attempts as evidence would report a false
contradiction on every normal red-to-green cycle. `P6e` is the pin.

**ADVISORY, and that is load-bearing rather than stylistic.** The hook writes nothing to
stdout, returns no `permissionDecision` of any kind, and always exits 0 — including on
the inherited-plugin-root mismatch every sibling answers with `exit 2`. On `PreToolUse`,
stdout is the decision channel and a non-zero exit BLOCKS the call, so a witness that
failed closed would break every Bash call in the session, starting with the ones it
exists to record.

**ONE extraction, called twice.** `hooks/lib/zensu-witness.sh` owns the redact-module
resolution and the payload decode; both hooks source it. The two writers must redact
`cmd` identically or the attempt matches neither its own completed entry nor the claim,
so this is the one place in the feature where a hand copy would lose evidence silently
rather than loudly. What each hook deliberately KEEPS is the house pattern the existing
pins scan per file: the plugin-root guard, the principal check, the session bind, the
bypass-ledger block and the log-path spelling.

**`ZENSU_TEST_WITNESS=off` governs BOTH halves**, and both record the ledger entry. The
recorder dedups per gate, so a session still lands exactly one — and recording it in the
attempt half is what keeps the ledger honest for a session in which the escape is set and
every Bash call fails, where the result half never runs at all. No new stem enters
`ESCAPE_STEMS`; the spelling already existed.

**The attempt half is scoped exactly like the result half** — main principal, bound
session, chain-state `active`. Recording attempts for an unarmed session would put lines
in a log the result half never writes to, and the cross-check would read every one of
them as a run that did not finish.

**Version: `patch`.** Walked against §"Runtime Lineage (`version_type` is load-bearing)"
entry by entry: no context-record or workflow-state schema field, no strict key set, no
hook removed or renamed and no matcher changed, no new config key, no attestation change.
Adding a hook is a `patch` UNLESS it can return a `permissionDecision`, which this one
cannot in either direction — it is the ADVISORY shape that exemption names. The witness
log gains a line KIND, but it is an ephemeral per-session artifact read only by the
cross-check in the same tree, never a persisted shape two runtimes must agree on, and the
parser accepts a log with no attempt lines unchanged.

**Coupled sites that move together:** `WITNESS_ATTEMPT_MARKER` / `WITNESS_MARKER` /
`ATTEMPT_ONLY_MARKER` in `hooks/lib/zensu-evidence-crosscheck.js` (all three EXPORTED so
the suite builds its fixtures from the producer rather than re-spelling the format); the
`kind` field `parseWitness` now stamps on every entry, whose ABSENCE means a completed
entry — a legacy log parses with no `kind` at all, so the predicate tests for `attempt`
and never for `result`, and inverting it would silently discard every pre-upgrade entry;
the `Bash` `PreToolUse` matcher in `hooks/hooks.json`; the hook count in
`docs/configuration.md` (header, prose and the `#hooks-N` anchor) plus the
`configuration.md#hooks-N` cross-link in `docs/architecture.md`; `R19` and `R32` in
`tests/structure/test-artifact-redaction.sh`, which now scan BOTH writers and the shared
library respectively; the mechanism-2 consumer list in the header of
`tests/structure/test-msys-special-plugin-module-boundaries.sh`; `P3`'s roster in
`tests/structure/test-bypass-ledger.sh`; and `adopt_hook_expected` in
`tests/structure/test-versioned-plugin-upgrade.sh`, which is the coupling that fired
in the UNOBVIOUS direction and cost a red Windows shard. AC-C04 enumerates the Bash
matcher from `hooks.json` and expects EVERY hook on it to deny the adoption command
on win32, so registering an advisory hook there reported as `unexpected:
pre-bash-witness.sh` in a suite named for plugin upgrades. The exception set now
lives in one helper both AC-C04 loops call, and every member states why it cannot
deny — a third entry needs its own sentence. Note the platform bound on verifying
this: `ADOPT_EXPECTED` is `allow` on POSIX, so on macOS every hook expects `allow`
and the regression is INVISIBLE; the helper's deny-default branch is driven
directly rather than reached through the suite.

**Operator-facing accounts that must move with it:** the `pre-bash-witness.sh` row, the
`post-bash-witness.sh` row and the `ZENSU_TEST_WITNESS` row in `docs/configuration.md`;
the four-channel table, the redaction-writer table and §"Witness channel" in
`docs/tdd-manager-workflow.md`; and `skills/tdd/SKILL.md` Phase 6 step 1 together with
the claim-format note beside it that states the witness `exit=` is always `?` — the two
sit in different steps and a reader who finds one must be told about the other.

**Known gaps, accepted and named:**

- **A denied or aborted call is indistinguishable from a failed one.** All three leave
  the same attempt-only shape, and the contradiction text says so rather than guessing.
  Narrowing it would need the host to report the outcome, which is the thing it does not
  do.
- **The doubled hook cost is real, and it is NOT confined to armed chains** — an earlier
  wording of this bullet said an unarmed session pays nothing, and that is false by simple
  reading. Both writers run the payload extraction BEFORE the activation check, because the
  session id they check activation for comes out of that extraction, so every Bash call in
  every session with a readable Session Control record now spawns one extra `bash`
  (`zensu-host-path.sh`) and one extra `node` (the extractor) whether or not a chain is
  armed. That ordering is pre-existing in the result half; the attempt half doubles it. The
  cheap fix is available and NOT taken here: `zensu_bind_hook_session` exports
  `ZENSU_SESSION_KEY`, so the attempt half could test activation off that value first and
  return before spawning anything — left alone because the final check is the authoritative
  one and reordering it is a behaviour change to a path every Bash call travels, which
  belongs in its own review. Say "unmeasured", never "free".
- **Windows is UNVERIFIED.** `test-post-bash-witness.sh` and `test-evidence-crosscheck.sh`
  are absent from `tests/profiles/windows-ci.v1.json`, whose shards this file records as
  already close to their `profileTimeoutMs`, so the new checks never run on the blocking
  Windows PR shard. Say "unverified", never "covered".
- **No `/zensu:doctor` row.** A session in which the attempt half stopped recording — an
  unregistered hook, a `hooks.json` edit — is visible only as cross-check verdicts
  reverting to `EVIDENCE GAP`, which is exactly the pre-change behaviour and therefore
  silent. `P12-A1` pins the registration at build time; nothing checks an installed tree.
- **No ports.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were NOT included.
  The premise is host-coupled in both directions: a port must re-measure whether its own
  harness fires the post-tool event for a failing command, and whether its pre-tool event
  fires unconditionally. A port that copies the hook without taking that measurement
  ships a second writer for a gap it may not have.
