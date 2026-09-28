---
paths:
  - "hooks/lib/plan-payload-v1.js"
  - "tests/structure/test-plan-payload-fallback.sh"
  - "tests/structure/plan-payload-v1.test.js"
---

# Plan-Gate Payload Sources (`hooks/lib/plan-payload-v1.js`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

The Autopilot plan-approval gate reads the approved plan from FOUR payload sources, in
precedence order, and `plan-payload-v1.js` is the single source of truth for which:

| # | Source | Live on the current Claude Code build |
|---|--------|----------------------------------------|
| 1 | `tool_input.plan` | no |
| 2 | `tool_input.planFilePath` | no |
| 3 | `tool_response.plan` | **yes** |
| 4 | `tool_response.filePath` | **yes** |

Sources 1-2 are dead on this host and still ranked first on purpose: a host that DOES declare
those ExitPlanMode fields keeps its meaning, and an explicit caller-supplied plan must not be
overridden by the harness copy. `tests/structure/test-autopilot-plan-delegate.sh` P16 pins that
the legacy carrier still delegates identically, so keeping them costs no behavior.

**Retiring them is not a four-check edit.** In `test-plan-payload-fallback.sh` the `tool_input`
carriers are driven by every case built by `payload()`, `payload_nonstring_plan()`,
`payload_input_and_response()` and the inline F21a/F43 builders — roughly twenty checks — plus
P16. Most have a source-4 mirror already (F5→F35, F6→F36, F7→F37, F13→F40, F15→F38, F16→F39,
F17→F41); the rest would have to be re-pointed at the response carrier. The trigger is a
RE-CAPTURE, not a hunch: only a fresh capture from every supported host can show that none of
them populates `tool_input` for ExitPlanMode any more.

**Why the dead sources are dead.** The harness strips ExitPlanMode fields its schema does not
declare — a captured payload carries `tool_input == {"_targetMode":"auto"}` — and delivers the
approved plan in `tool_response`, a structured object (`plan`, `filePath`, `isAgent`,
`hasTaskTool`). Before this was understood every Autopilot run died at its single planning gate
with `INVALID_PLAN_PAYLOAD`, unfixable from the model side.

**Fields are read BY NAME, never by scanning text.** The rendered response a model sees carries
a `Your plan has been saved to: <path>` preamble, but the plan body is model-authored: mining
that text would let plan prose inject its own preamble and name the path the gate opens.
`test-plan-payload-fallback.sh` F31b (a rendered string response is never mined) and F34 (a
`saved to:` line inside the plan body never names the approved bytes) are the pins; both
discriminate through the persisted digest, because an absent decoy proves nothing.

**Everything that re-encodes this shape must move together:** the module's `SOURCES` table;
every `payload*` builder in `tests/structure/test-plan-payload-fallback.sh` — `payload`,
`payload_nonstring_plan`, `payload_response`, `payload_response_nonstring`,
`payload_response_shape`, `payload_input_and_response`, plus the inline F21a, F31c, F43 and
F11b-tool builders; the fixture-shape assertion F33a; and the whole-flow builders in
`test-autopilot-full-cycle.sh` and `test-autopilot-plan-delegate.sh` (which also keeps
`payload_input_dialect` for the legacy carrier). The committed capture
`tests/structure/fixtures/exitplanmode-posttooluse-payload.v1.json` pins the shape the gate was
BUILT AGAINST; it cannot observe live harness drift — only a fresh capture can.

**Operator-facing account that must move with the sources:** `skills/autopilot/SKILL.md`, which
names `tool_response.plan` and `tool_response.filePath` when it tells the skill where the run
marker has to travel.

`tests/structure/plan-payload-v1.test.js` (node --test, driven from
`test-plan-payload-fallback.sh` F11b) pins the table's order, liveness and label shape, the
reader's refusal codes, and the branches the shell layer cannot reach — a NUL-byte path, a
bare-string carrier, a hard link. F11d pins that every module reason maps to an exit code and
back to the identically named BLOCK_CODE, which no behavioral case can observe.

**The response also declares WHO called, and that is judged before any source is read.**
`tool_response.isAgent === true` refuses as `PLAN_RESPONSE_AGENT_ORIGIN_REJECTED`, and a
present non-boolean refuses as `PLAN_RESPONSE_ORIGIN_TYPE_REJECTED` rather than being read as
falsy — `"false"` and `0` are both truthy-adjacent spellings that would otherwise approve an
agent-originated plan by coercion. This is a POSITIVE assertion layered on Session Control's
absence-based principal check, which grants `main-v1` only to the top-level thread; it is free
to make because the harness supplies the field. Two orderings are load-bearing and pinned:
it runs AFTER the owner and stage checks, so an unauthorized caller still learns nothing about
the response shape (F45c), and BEFORE the source walk, so no payload-named path is opened for
a caller who may not approve. F45/F45a are the bites — measured against the pre-change hook,
which APPROVES both shapes — and F45b is the positive control that the same builder with
`isAgent: false` still approves. Each of the four owns a separate armed run: sharing one let an
approval in an earlier case push the run past `PLANNING`, and every later case then failed on
the transition instead of on what it was about.

**Three checks pin behavior this gate already had and never exercised**, so they pass in both
trees and are coverage, not bites: F47/F47a (a plugin missing the reader module refuses as
`RUNTIME_UNAVAILABLE` — asserted to NOT be `PLAN_EVALUATION_UNAVAILABLE`, which would claim the
payload was judged — with a restored-module positive control), F48 (the module path reaches
node through the environment, never argv, matched against a closed allowlist of line forms
because the evaluator spans ~90 lines and a line-scoped grep would miss an argv token appended
below it), and F49/F49a (a hard link refused through both carriers).

**`PLAN_STAGE_MISMATCH` (exit 7) is unreachable and deliberately left so.** The shell `case`
already filters the active document to `PLANNING|AWAIT_TDD`, and the evaluator re-reads
`state.stage` from that SAME document — there is no second source to disagree with it. The
re-check is defense in depth for a future where the two diverge; do not write a behavioral
fixture for it, there is none.

**The `openMode` seam exists to reach dead code, and must stay a MODE.** The `noFollow === 0`
branch in `readPlanFile` is what a host without `O_NOFOLLOW` runs; every POSIX host this ships
to defines the flag, so in production it never executes. `readPlanFile(path, openMode)` compares
its second argument against the string `LSTAT_PRECHECK_MODE` and never ORs it into the open
flags — a caller can only take the STRICTER path, never widen the open. The unit suite pins that
with `O_CREAT` as the discriminator: were the argument a mask, the reader would create a missing
path instead of reporting it unreadable. Measured property worth keeping: deleting EITHER of the
branch's two guards leaves the suite green, because the other still catches the link; deleting
both fails only in `plan-payload-v1.test.js`. `test-windows-portability-guards.sh` carries the
reader in its secure-open inventory — every other pin there is per-file and therefore blind to a
NEW file carrying a hardened open.

**The Windows timeout for this suite is a coverage boundary, not a formality.** At
`timeoutMs: 600000` in `tests/profiles/windows-ci.v1.json` the `plan-payload-path-transport`
step reported `TIMED_OUT` at check ~61 of 70, so F45c, F49/F49a, F48, F12 and F47/F47a never
executed on Windows while the shard still reported its earlier checks as passing. It is 900000
now, and the full 70-check suite measures **714 s** there — 79% of the new ceiling, so roughly a
quarter of the budget is left. Every check costs Windows wall clock (the old run reached F45 at
540 s of 600 s) and the tail is the expensive part: four extra armed runs plus one full
plugin-tree copy. Budget against the 714 s, not against the ceiling. If the shard starts
reporting `TIMED_OUT` again, the tail of the file has gone unverified regardless of how many
checks passed before it. Same failure mode, same remedy, as the source-write gate's own note
above.

**The digest binds the bytes that TRAVELLED.** When source 3 wins, `approvedPlanSha256` is over
the response string, not the file at source 4's path. The two agreed byte-for-byte in the
capture and F44 pins that agreement, but they are not contracted to; `approvedPlanSha256` is
only written and shape-validated, never re-derived, so a host whose response string and saved
file disagree would silently bind the transported copy.

**Port-relevant.** The module OWNS `SOURCES`; a port edits that table in its own copy of the
file rather than calling in with a different one. `resolveApprovedPlan(payload, sources)` takes
a table argument so the unit suite can drive the walk with a synthetic one, and it REFUSES an
empty or malformed supplied table instead of substituting this host's carriers — two of which
open a payload-named file. A port also carries two host-half obligations the module cannot:
render the lib DIRECTORY through `zensu-host-path.sh` (that script rejects files) before
appending the file name, and guard the loaded spelling with `-f` / `! -L` / `! -r` plus an
export-shape check, routing any load fault to the RUNTIME receipt — never to
`PLAN_EVALUATION_UNAVAILABLE`, which claims the payload was judged. The host half — WHICH carrier a host populates — must be re-decided per port;
`zensu-codex`, `zensu-kiro` and `zensu-antigravity` carry the same gate against different
harnesses and were deliberately left out of the change that introduced sources 3-4. The
host-neutral half is everything below the resolution: the single `<!-- zensu-autopilot:RUN_ID -->`
marker, run-id equality, the owner and stage checks that precede every read, and the digest.
A port that takes only the module gets the field decision; it still owns its own emission and
its own exit ladder, which stay in `hooks/plan-approved-delegate.sh`.
