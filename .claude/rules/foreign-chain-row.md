---
paths:
  - "hooks/lib/zensu-doctor.sh"
  - "hooks/lib/zensu-doctor-report.js"
  - "skills/doctor/**"
  - "tests/structure/test-doctor.sh"
---

# Foreign-Chain Row (`zensu-doctor.sh` + `zensu-doctor-report.js`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

A session FORK is silent: the host mints a new session id mid-conversation, carries the
whole history over and re-fires `SessionStart`, so the workflow document armed under the
old key becomes unreachable and every later `zensu-log.sh` call answers `no-session`. The
chain stops existing while the user still believes it is running. `/zensu:doctor`'s
`chain: open chain(s) not owned by this session` row is the only thing that reports it.

**FOUR halves, and a port that takes three ships a row that silently never fires.** The wrapper exports `ZDOC_SESSION_KEY` and
`ZDOC_SESSION_PROJECT_ROOT` out of its own `zensu_bind_model_session` (one tab-separated
substitution, so a single status decides the `bound` branch and a partial pair is dropped
whole); the renderer owns the predicate and its single `bound`-plus-shape guard AND the
record-anchored state directory; the chain-shape OWNER must export `INERT_SHAPES`, whose
absence withholds the row; and the operator accounts carry the diagnose-only limit. The premise is
HOST-COUPLED: a host that cannot mint a new session id mid-conversation has nothing to
diagnose here.

**The row states an OBSERVATION, never a cause, and that wording is the feature.** Nothing
available to a read-only renderer distinguishes a forked-away session from a live sibling
driving its own chain in the same project — and a live sibling is ORDINARY under this
repository's own worktree rule. An earlier draft asserted the fork as fact and prescribed
`/zensu:tdd`; that made a false claim about a running session and told the reader to arm a
competing chain. Only the WORDING changed — the row is still `WARN`, `line()` counts WARN toward
`warnCount`, and `main()` gates "all checks green" on it, so the green-summary consequence below
is still live and is listed as a gap rather than as something the reword fixed.

**The CAUSE ORDER inside that wording is itself a contract, and it was wrong once.** The row's
predicate is every open chain in this project not owned by this session and inside the TTL. The
DOMINANT member of that set is a session that ended without `--chain-done` — a closed terminal —
not a fork. An earlier wording named the fork as "the usual cause" and opened with "if those
sessions are still running, nothing is wrong here": it described the rare case and dismissed the
common one, which trains a reader to ignore the row. The abandoned chain is named FIRST, the live
sibling second, the fork third, and `P1mj1` pins that order. Note what this does NOT change: for
an abandoned chain the state really is stale, so the row is correctly a warning — demoting it to
`OK` was considered and rejected, because a row that can never affect the summary is a row people
stop reading. The green-summary cost is the price and is recorded as a gap below.

**The deletion target is SHELL-QUOTED, never filtered against a character class.** A
`DELETABLE_PATH_RE` allowlist was tried first and was wrong in BOTH directions: it excluded
`path.sep`, so on win32 no candidate could ever match and the whole pending-review cleanup was
unreachable on that host, and it excluded the space, so an ordinary `~/My Projects/...` was
refused with a message blaming the user's filesystem. `shellQuotePath` single-quotes instead,
which is total; only a CONTROL byte is still refused, because quoting makes it harmless to the
shell but not to the report line a model reads back. `deletableTarget` also walks from the
CANONICAL root (`realpathSync.native`) rather than the caller's spelling, which is what makes the
"no component of the chain is a symlink" claim TRUE rather than true-below-the-root — requiring
`root` to equal its own realpath instead would refuse every macOS session under `/var/folders`.
Its `..` test is the ANCHORED form, and it returns `{path, reason}` so the row names WHICH check
failed: an unresolvable disjunction reads as a fault in the user's filesystem. `skills/doctor/SKILL.md`
Phase 3 consumes the quoted literal verbatim and re-verifies the chain AFTER the confirmation,
because the renderer measured it before.

**The pending-review row ages on the marker's own `ts`, not on the filesystem mtime.**
`pendingReviewStamp` mirrors `_tdd_pending_file_stale` in `hooks/lib/zensu-tdd-phase.sh`, which is
the canonical staleness reader for that file. Reading the mtime alone let the doctor print
"expired, safe to clear" for a marker the Stop enforcer still treated as LIVE — the same class the
`ttl === 0` fix closed, on the other axis. Two readers of one file must not disagree about which
markers are dead. The `ts` read is size-bounded; an absent or unparseable `ts` still falls back to
the mtime, so the pre-existing behaviour survives.

**The whole Session state block is anchored on the RECORD's project root, not on
`CLAUDE_PROJECT_DIR`, and that is a fix to PRE-EXISTING rows as much as to this one.** Every
writer anchors there: `zensu-log.sh` re-exports `CLAUDE_PROJECT_DIR` from
`zensu_resolve_project_dir`, which resolves `ZENSU_PROJECT_ROOT` out of the immutable record,
before any verb body runs. The renderer read the raw harness value, so whenever the two differed
— the ordinary case for a session whose cwd is a worktree — `stateBlock` scanned a directory no
writer uses and `readWorkflowState` never opened the documents at all. `stateProjectRoot` prefers
the recorded root under a `bound` verdict and falls back to the caller's value only because a
session with no record has nothing better. **An earlier attempt COMPARED the two and withheld the
row when they disagreed; that was strictly worse** — it withheld exactly the fork-in-a-worktree
case the row exists for, and silently. Do not reintroduce the comparison.

**Two conditions withhold the row, both fail CLOSED, and BOTH now DISCLOSE.**
`currentSessionKey` requires `ZDOC_BINDING === 'bound'` beside the shape. The wrapper
states "empty for every verdict except bound" and now clears both values unconditionally
rather than `:=`-seeding them — the only two EXPORTED `ZDOC_*` that deviate from that convention,
because their meaning depends on a verdict reached further down and the `unknown` /
`unavailable` branches never reach the bind. The reader enforces it anyway, since a caller
supplying `ZDOC_BINDING` skips the whole resolution block; without that, one report could
print the ❌ no-record row and, below it, a row keyed on a session key it had just said does
not exist. The wrapper half used to withhold SILENTLY, which is the one verdict a diagnostic
may not give — it now emits its own "missing check, not an all-clear" row, and the module
half's row is no longer conjoined on `ownKey !== ''`, because that conjunction meant a tree
which broke BOTH halves printed NEITHER row. `rowArmed` names the arming rule once, above the
loop, so the filter and the two disclosures cannot drift apart. `P1mm5`/`P1mm6` pin the
wrapper half in both directions.

**Ordering is a contract.** The foreign-open push sits BELOW the wedged and dead-end early
returns. Those rows carry their own remedy, and a second row naming the same truncated key
with a contradictory instruction is worse than no row. `P1ms2` pins it with an `awk` line
comparison, because no fixture in the suite builds a wedged chain.

**Age comes from the document's `updated_at`, and there is NO mtime fallback** — `.zensu/state/`
is session-writable and a bare `touch -t` would move a document out of the window without
producing anything `validateWorkflowState` accepts. An `updated_at` that does not parse yields no age at all
and excludes the entry — a fallback would be dead code pretending to be a safety net — and, WHILE THE BOUND IS ARMED, a
stamp in the FUTURE is treated as outside the window rather than absolute-valued, so a skewed
or planted one cannot hold the row open forever. At `0` no window is claimed, so only a stamp
that cannot be read at all excludes an entry. `0`
DISABLES the bound rather than shrinking it to nothing, matching `docs/configuration.md`
and the sibling `reviewerDenialRows`; the row then drops its "touched within Nh" clause
rather than advertising a 0h window.

**A BLANK `ZDOC_TTL_HOURS` now falls back to the default rather than resolving to `0`, and
that is a behaviour change to this row as much as to the pending-review one.** `Number('')`
is `0`, which passed the `>= 0` bound, so a wrapper fault that exported an empty string
switched the window off silently — and `zensu-doctor.sh` exports the variable unconditionally
after a conditional resolve, which makes blank reachable. EVERY `ZDOC_*` window reads through
one `boundedEnvInt` — grep the calls rather than trusting a list here, as the reader's own
comment says — so absent and blank take the fallback and only an in-range
integer wins. `ownerActivityWindow` additionally reports whether the bounded reader ACCEPTED the
configured value — not merely whether one was present, which got a configured-but-rejected value
backwards — from the SAME resolution that produced the number,
because for that key the fallback asserts a protection rather than withholding a claim. `ttlHours()` has THREE call sites — this row, the pending-review verdict and
`reviewerDenialRows` — and a FOURTH consumer of the resolved value, `ownRefusalNoteLive`,
which takes it as a parameter rather than re-reading it. Word it that way: counting it as a
fourth CALL SITE double-counts the read this row already performs. That fourth consumer is
what decides whether the implementing-turns row carries its refusal caveat. `autopilotRows`
was a call site here until its owner-silence clause moved onto its own accessor,
`ownerActivityWindow()` over `ZDOC_OWNER_ACTIVITY_TTL_HOURS` and its twin
`releaseOwnerActivityWindow()` over `ZDOC_RELEASE_OWNER_ACTIVITY_TTL_HOURS`: that clause states
the exit-7 refusal each Autopilot run verb takes against its OWN window, so quoting the
pending-review window there promised a protection the destructive verb does not give. `ownRefusalNoteLive`
carries a consequence the discussion above does not otherwise cover — name it, because an
inserted sentence broke an earlier "that last one" and pointed the consequence at the
owner-activity accessor instead: at the documented `0`,
`classifyDenialNote` never returns `stale`, so a note of any age keeps qualifying that row.

**Known gaps, accepted and named:**

- **A model holding the PREVIOUS release's skill body deletes a file this report never
  examined, and no renderer-side change can prevent it.** `skills/doctor/SKILL.md` as shipped in
  **0.19.0** says to DERIVE the target: "`${CLAUDE_PROJECT_DIR}/.zensu/state`". Under the lineage
  rule a `0.19.0 → 0.19.x` update keeps the session running, so the NEW renderer measures the
  RECORD root while the model still holds that instruction — and where the two differ, which is
  exactly the worktree case this feature exists for, the confirmed `rm` removes the other tree's
  marker. Verified against the installed 0.19.0 skill, not inferred. Three larger fixes were
  considered and none closes it: quoting the path does not help (an old body never reads the
  row's path), a `--clear-pending --confirm` verb does not help (an old body does not know it
  exists), and suppressing the word "expired" would delete the finding in the one case it
  matters. What bounds the harm: the user still confirms, and the damage is one stale marker.
  What this change DOES do is make the CURRENT skill safe — it consumes the printed literal and
  re-verifies after the confirmation. Do not describe this as mitigated.
- **The branch that PRODUCES the exported pair has no executed coverage, and the reason is
  measured.** `P1mp`/`P1mp1` are source greps. An earlier note claimed a real bind needs a live
  host session; that is FALSE — against the suite's own `strand-open` baseline
  `zensu_bind_model_session` returns 0 from a plain child process, and the wrapper's exact
  substitution body reproduces the correct pair inline. What could not be made to work is
  `bash "$HELPER"` end to end, which still reports no valid record in that fixture; the cause was
  not established (it is not the in-substitution comment and not the shape guards, both measured).
  The end-to-end check was REMOVED rather than weakened until it passed. So the composite exit
  status, the TAB split and the pair reaching the renderer are unexercised — on a branch that
  decides `ZDOC_BINDING` for every session, not just this row.
- **A same-project-root sibling permanently withholds the green summary.** The row is `WARN`, so
  while another live session holds an open chain under the SAME project root and within the TTL,
  `/zensu:doctor` cannot print "all checks green". A sibling in its own worktree has its own
  `.zensu/state` and does not trigger it. `P1mg1` pins the row's contribution to the warning
  count, which is the same property from the other side.
- **The Windows wall clock for the enlarged `test-doctor.sh` block is UNMEASURED.** The suite is
  absent from `tests/profiles/windows-ci.v1.json` and sits in the `excluded` list of
  `windows-native-structure.v1.json`, so no PR shard runs it — but the weekly Windows Safety
  structure shards do, and the foreign-chain block roughly doubled the suite's process count.
  A LOCAL run took 28 s on a loaded machine, but a loaded-local second is not an ubuntu-latest
  second; that entry now reads 12 — the previous 6 s CI figure doubled — and is labelled an
  estimate in the file's own note. Take
  the figure from the next green weekly Windows run and replace both. Say "unmeasured", never
  "cheap".
- **"No full session key is printed" scopes to THIS row, not to the block.** The
  invalid-CAS-document row prints whole `tdd-phase-scv1_<64 hex>.json` filenames, and
  deliberately: a reader told to inspect a broken document needs its name. The foreign-chain
  row truncates to 13 characters and is pinned that way; do not restate the requirement as a
  tree-wide invariant.
- **The `scv1_` shape is an untracked hand-copy family and this change added two members.**
  `SESSION_KEY_RE` exists in `session-control-core-v1.js` and is not exported, so the JS copy in
  the renderer and the bash-native one in the wrapper join a family that already spans several
  files. **A prose census goes stale the next time a site is added, so this is a GREP and not a
  list: before changing this shape, run `grep -rn 'scv1_' hooks/` and change every site.** An
  earlier revision of this bullet DID enumerate them and undercounted — the renderer already
  held four copies before this change added a fifth. Two facts a grep cannot supply: the
  unexported owner is `SESSION_KEY_RE`, and `zensu-edit-landing.sh` spells the class `[0-9a-f]`
  rather than `[a-f0-9]`, so the family had already drifted. Exporting the owner's constant is
  the standing fix.
- **A foreign chain that is WEDGED or at a DEAD END never reaches the row.** Those branches
  return first, deliberately, so one truncated key is never named twice with contradictory
  instructions — but the rows that do name it say "from the session that owns each chain",
  which is unperformable in exactly the state this feature exists to diagnose. The entries
  say "from the session that owns each chain" and nothing more. A qualifier naming the
  ownership was drafted and is NOT implemented — an earlier revision of this bullet claimed
  it shipped, which was false; grep finds the phrase only on the foreign-open row and the
  inert disclosure. The FORK is not named for them either.
- **The Config block keeps the OLD root.** `configFiles()` still builds the project overlay
  from `CLAUDE_PROJECT_DIR`, and `ZDOC_TTL_HOURS` is resolved before the bind, so where the two
  roots differ the doctor judges a `.zensu/config.json` that `zensu-log.sh` never reads. The
  TTL half is consistent with the Stop enforcer, which does not re-export the root; the config
  half is not, and is left as-is rather than widened silently.
- **The `chain-closed` half of the inert set has no behavioural fixture.** Driving a chain to
  that shape needs a real reviewer spawn to consume the review ticket, which no structure suite
  can perform. The exclusion is exercised only through `no-session`; `P1ms` covers the rename risk
  instead, by asserting that `INERT_SHAPES` is exported, holds both shapes, and that every member
  is a shape `chainShape` actually RETURNS — driven by calling it, not by membership in the
  sibling `NEXT_COMMAND` table. That earlier spelling reproduced the exact blindness this export
  was created to remove: renaming only the returned literal left the table key in place and kept
  the check green while a genuinely closed foreign chain rendered as an open one. Measured, not
  argued — the classifier-driven form catches that rename and the table-driven form does not.
- **RESOLVED — see §"Implementing-Phase Turn Counter" below; the rest of this bullet is the
  original finding, in past tense.** An OWN chain parked at `implementing` USED TO render at
  `OK`, and that is the shape a session lands in when it DECLINES the review chain rather than
  fails it.
  `hooks/stop-chain-enforcer.sh`'s `SESSION_IMPL_COMPLETE` early return releases Stop
  unconditionally while that flag
  is not `true`, so a session that arms `--tdd-begin`, does the work and never runs
  `--tdd-complete` is never asked for a reviewer: no directive, no cap, and no bypass-ledger
  entry — the ledger records gate ESCAPES and no gate was ever reached. `chainShape` then
  answers `implementing`, which is in neither `RECOVERABLE_SHAPES` nor `DEAD_END_SHAPES`, and
  the foreign-open row excludes it by `entry.key === ownKey`. It therefore reaches ONLY the
  count row, whose severity is `unclassifiable ? WARN : OK` — so the shape IS printed and "all
  checks green" still holds beside it. Observed as a real session outcome, not constructed: a
  session whose harness prompt forbade the `Agent` tool declined the five-agent fan-out,
  withheld `--tdd-complete` for exactly that reason, and self-reviewed instead.
  **Warning on `implementing` alone is NOT the fix** — that is the shape of every chain that is
  legitimately mid-implementation, so such a row would fire throughout every normal run and be
  trained away within a day. **An AGE bound is not the fix either, and it was the first thing
  proposed here.** The foreign-open row already ages on `updated_at` against
  `zensu_pending_review_ttl_hours`, and reusing that for an OWN chain measures WALL TIME — which
  a powered-off machine, a paused session, an overnight break and a holiday all accumulate with
  nothing wrong. Such a row reports the user's calendar, not the model's behaviour, and the
  existing foreign-open row carries the same weakness rather than justifying a second copy of it.
  **COUNT TURNS, NOT TIME.** The distinguishing signal is how often this session ENDED A TURN
  while the chain was still `implementing` and the worktree still reported changed files — the
  shape of a model working alongside an undeclared gate rather than through it. A machine that
  is off counts zero, a paused session counts zero, a holiday counts zero, and only continued
  work past the open gate counts up. The mechanism already exists in this same file for the
  phase one step later: the `CAP` release in `hooks/stop-chain-enforcer.sh` counts Stop blocks
  against `autoFixMaxRounds + 3` rather than against a clock.
  **Anchor by SYMBOL here, never by line number.** Both references above once carried one
  (`:951` and `:954-956`) and both went stale in the same commit that inserted
  `zensu_impl_stop_nudge` above them — a line number in prose is a claim nothing recomputes,
  and no reader can tell a correct one from a drifted one without opening the file. What is missing is the equivalent counter
  for the implementing phase plus a workflow-state slot to hold it — which under §"Runtime
  Lineage" is a schema change and therefore a `minor`, so it should travel with a schema change
  that is landing anyway rather than buy a release of its own. The nudge must stay ADVISORY and
  never become a block: a long legitimate implementation genuinely does span many turns, so a
  false positive may cost a line of text and must never cost a wedged chain.
  **THIS IS NOW IMPLEMENTED**, and it lives in its own section — see
  §"Implementing-Phase Turn Counter" below. It is deliberately NOT written up here: the
  paragraphs that close this section (its operator accounts, its `patch` verdict) were written
  about the foreign-chain row and are still true of it, so a second feature documented inside
  this section's gap list puts two version verdicts under one heading and makes one of them
  read as false.

**Operator-facing accounts that must move with it:** `skills/doctor/SKILL.md` (the frontmatter
`session state` clause, the row bullet, and the Phase 3 cleanup, which must delete the path the
expired row PRINTED rather than re-derive one from `CLAUDE_PROJECT_DIR`) and the
immutable-parent-context bullet in `docs/session-control.md` §"Claude Code Workflows".

**Version: `patch`.** Walked against §"Runtime Lineage" entry by entry: no context-record or
workflow-state schema field, no strict key set, no hook added/removed/renamed and no matcher
changed, no new config key (the row reuses `zensu_pending_review_ttl_hours`), no attestation
change. The renderer is advisory and cannot deny, and it requires `chain-recovery-v1.js` from its
own plugin root, so no cross-version module mixing arises. Recorded here because the section also
states that PRE-EXISTING rows changed where they read, which reads like a breaking change and is
not one.

**Port-relevant.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were NOT included in this
change; each carries its own doctor against a different harness, and the fork premise has to be
re-decided per host before any of the four halves is worth porting.

`tests/structure/test-doctor.sh` P1mg–P1mt1 pin the row, its severity, the summary
interaction, the withholding guard, the record anchor and its fallback, the TTL semantics in both directions and at `0`, the
read-only contract, the wrapper source shape, and the three-way wording drift.

**The `patch` verdict above is about the foreign-chain row ALONE.** The turn counter in the
next section is a separate feature with its own verdict; do not read that paragraph as
covering it.
