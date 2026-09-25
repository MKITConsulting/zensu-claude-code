---
paths:
  - "hooks/lib/zensu-log.sh"
  - "hooks/lib/zensu-edit-landing.sh"
  - "docs/multi-repo-chains-*"
  - "tests/structure/test-edit-landing-audit.sh"
  - "tests/structure/test-tdd-complete-receipt-gate.sh"
---

# Multi-Repo Stage 1 (`zensu-log.sh` terminus + `zensu-edit-landing.sh` + the doctor row)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

Stage 1 of `docs/multi-repo-chains-spec.md` §5. It ships NO multi-root capability; it
removes the SILENT GREEN a chain produced when its work landed in a repository the
anchor cannot see. Four behaviours, three files, one shared claim grammar.

**The terminus judges the receipt's VERDICT, never its existence.** The audit writes
its receipt BEFORE its own exit status, carrying `clean` as a field rather than as a
precondition for writing, so an existence-and-not-a-symlink test accepted a receipt
recording `EDIT NOT LANDED`. `_tc_receipt_verdict` in `hooks/lib/zensu-log.sh` reads it
once per completion and answers `clean` / `unclean` / `no-verdict` / `unknown-schema` /
`unreadable` / `unparseable` / `unavailable`, and everything but `clean` refuses with
that state named. **The affirmative spelling is load-bearing:** refusing only on
`clean: false` would accept a truncated, schema-drifted or hand-planted receipt that
carries no verdict at all, and `.zensu/state/` is writable from inside the session
through a shell redirect no gate covers. A missing `node` therefore refuses too (the
`unavailable` arm) rather than passing — this is one of the few load faults in that verb
that fails CLOSED, and it says so in its own wording: it is not a verdict about the
receipt's contents.

**Both accepted schema names live in FOUR places, and the pin is what holds them
together:** the writer in `zensu-edit-landing.sh`, this reader, the requirements gate's own
inline node reader a hundred lines below it in the same verb, and `RECEIPT_SCHEMAS` in
`hooks/lib/zensu-doctor-report.js`. A fifth value domain — what `log` means per schema —
is re-encoded in the last two. Adding `edit-landing-v3` means all four, and
`tests/structure/test-tdd-complete-receipt-gate.sh` SCH1 compares the four spellings so a
one-sided edit fails loudly rather than degrading one consumer silently. **The standing fix
is one OWNER**, a host-neutral module exporting the set that the doctor `require`s and both
`node -e` programs load by an env-supplied path — the transport this file already uses for
`session-control-core-v1.js`. It was not taken in the round that added the pin because the
writer's node program is the most heavily pinned code in that library; take it at the next
change that has to re-author that program anyway.

**The requirement is armed by a CLAIM, not only by a dirty tree.** `_tc_armed` is true
when the anchor's change count is non-zero OR when a claim was logged, which is what
covers the clean-orchestrator topology. The run log is located from `--plan`'s stem
(`.zensu/plans/<stem>.md` → `.zensu/logs/<stem>.log`, bounded to a regular file in a
non-symlinked logs directory), else from the claim count the receipt itself records.
**A chain that claimed nothing stays exempt**, and that exemption is not cosmetic:
hermetic chain-mechanics suites drive this verb in projects that change nothing, and
forcing them to fabricate a receipt would make the gate look enforced where there is no
claim to verify. When a channel exists but does not resolve, the verb DISCLOSES
`EDIT LANDING GATE UNRESOLVED` on stderr instead of exempting silently.

**The claim grammar has ONE owner.** `zensu-edit-landing.sh` already extracted
`IMPL completed — files:` / `WIRED — files:` claims for grading; `--inventory` reports
the same extraction read-only — `claimed-files=<n>` plus one `foreign-root<TAB><root>` line per
distinct non-anchor root — without a change set, a verdict or a receipt. Its two
consumers are the terminus (for `_tc_armed`) and the doctor row. **The wire format is a
parsed contract:** the terminus reads `claimed-files=` with `sed -n 's/^claimed-files=//p'` and the
doctor splits on the first TAB and matches the literal `foreign-root`.
**The key is `claimed-files=` and NOT `claims`, because the receipt carries a field of
that name holding a DIFFERENT quantity** — this one counts named FILES, the receipt's own
`claims` counts claim ENTRIES, and an earlier revision of this section named both `claims`,
which is the conflation the rename removed.
**The grammar is ANCHORED.** A claim is `<label> <marker>` at the start of the message,
after an optional bracketed timestamp prefix. The label runs to the first marker, holds at
most `CLAIM_LABEL_TOKEN_BUDGET` (5) tokens and no `'`, `"` or `|`, and an empty label
grades as step `(none)`. The two `files:` markers take an em dash, an en dash or a plain
hyphen — the `[—–-]` class `review-round-scope-v1.js` admits — written as three LITERALS,
never as a bracket class: a multibyte bracket expression matches single bytes under
`LC_ALL=C`, where the em dash itself would stop matching (`X33f`). A narrower match gives a
hyphenated IMPL claim no verdict at all and misreads a hyphenated WIRED claim as a bare
entry; the census below holds 9 such lines in 4 logs. Accepting them grades MORE lines, so
re-running the audit over the same log after an in-lineage upgrade can turn a clean receipt
unclean — the audit doing its job, with no receipt or wire-format change, hence `patch`.
The `WIRED (verified, no change)` exemption carries no dash and is unchanged. A bare
`<step> WIRED` still needs ONE step token, because the bare word is a weak signal. The
budget is measured: across 1,462 local run logs (2026-09-24),
9,667 claim lines had the contract shape and 296 did not, and 272 of those are multi-word
labels such as `Step 3`, `FIX ROUND 2` or an unbracketed ISO timestamp — a one-token rule
dropped them, silently in every log that also held a contract-shaped claim. A line that
only mentions a marker — a `PRECONDITION DRIFT` note, the `TDD COMPLETE — … 1 WIRED`
tally, a correction note quoting `'IMPL completed — files:'` — is not a claim, and neither
is a line opening with one of the audit's own verdict heads (`EDIT LANDED`,
`EDIT NOT LANDED`, `EDIT LANDING AUDIT`, `PENDING PREDICATE`, `UNVERIFIED`,
`RECEIPT REFUSED`). That exclusion is what keeps step 5b b) safe: it copies every
non-`EDIT LANDED` verdict line back into the run log, and an extractor that re-grades a
copy grows `unverified` every round. Matching a marker anywhere in the line would also let
a claim's own commentary quoting `WIRED (verified, no change)` exempt the claim, a silent
green. **Bounds:** short prose of at most five tokens that names a marker unquoted still
grades as a claim, and a claim written after a verdict sentence or a ` | ` on the same line
is not recognized (about a dozen lines in the same census; those opening `<step> WIRED`
still surface as bare-WIRED `UNVERIFIED`). Backticks stay legal in a label because `X19a`
pins a backtick step id reaching the screened emit, and the census holds no
backtick-quoted marker. `review-round-scope-v1.js` anchors its `CLAIM` regex at the same
position; `X29`–`X33` in `tests/structure/test-edit-landing-audit.sh` pin the grammar.
**`claimed-files=` deliberately counts LESS than the audit's own `CLAIM_COUNT`:** a bare
`<step> WIRED` entry with no `files:` list is a claim to the GRADER (reported
`UNVERIFIED`) and is NOT one here: it names no file, and arming the terminus on it would
wedge a zero-change chain whose audit can then only ever report it again. An empty file
list and a `WIRED (verified, no change)` line count as claims in neither.

**An absolute claim is judged by where it RESOLVES.** `absolute_claim_verdict`
canonicalizes the claim's nearest existing ancestor before comparing it with the audited
root, so a macOS `/var` spelling of the anchor is in-root rather than foreign; a genuinely
foreign claim is reported `UNVERIFIED (foreign root)` and NAMES the root, found by walking
up for a `.git` entry — a filesystem walk, never a `git` invocation inside a repository
this session does not own. It counts as `UNVERIFIED`, so the receipt shape and the
`EDIT LANDING AUDIT —` tally line are unchanged and no receipt field was added.

**FOUR kinds, and every consumer must handle all four.** `absolute_claim_verdict` answers
`in-root`, `foreign`, `unrooted` or `undetermined`, the last carrying exhaustion of
`CLAIM_ANCESTOR_BUDGET` (64 ancestors) — a DISTINCT status from "walked to the top and found
nothing", because collapsing the two graded such a claim IN-ROOT on the audit path and silently
SHORTENED the `--inventory` foreign-root list on the other. `INV_CLAIM_BUDGET` (2000) caps the
inventory loop the same way. Both dispatches — `normalize_claim`'s and the `--inventory` `case`
— ENUMERATE the known-silent kinds and REFUSE the residual, which is the part to keep: a naive
catch-all faults on every ordinary in-root claim and makes `--inventory` exit 2 on every normal
chain. The product of the two budgets is NOT bounded (roughly 10^5 spawns at the maximum) and
the watchdog above the child has no deadline on a host without `timeout`, so a shared
total-probe counter is the standing fix and is not taken.

**`claimRootSafeNames` consumes the OWNER's display rules, and there are THREE render
bounds rather than one.** The row echoes a filesystem path a model is asked to relay, which is
the same question the autopilot rows answer for a run id, so it applies `forgesReportRow`
beside the control-byte and backtick tests — a `label : value` pair, a double space, a
separator-adjacent modifier letter, a Default_Ignorable code point and an orphan combining
mark are none of them control bytes — and the ANCHOR passes through the same predicate, not
a weaker inline one. `AUTOPILOT_RENDER_MAX` is the doctor's; `CLAIM_ROOT_RENDER_MAX` in
`zensu-edit-landing.sh` and `_TC_STEM_RENDER_MAX` in `zensu-log.sh` are the two shell ones,
and BOTH were bare `200` literals until the round that named them — which is strictly worse
than the `CLAIM_`-prefixed twin this paragraph used to record removing, because the
`grep -nE 'AUTOPILOT_|autopilot[A-Z]|createHash'` recipe §"Autopilot Run Scope" prescribes
cannot see either spelling. **The three screens are a SUBSET of the doctor's, never parity**,
and saying "the same set" was wrong in both directions: `forgesReportRow` consults SEVEN
rules, `render_claim_root` and `_tc_render_stem` carry FOUR each, and the three named Unicode
row-forgery classes need a JS regex that a POSIX shell `case` cannot express. **Both shell
screens are LOCALE-PINNED** (`local LC_ALL=C`) and repair a UTF-8 sequence the byte cut
splits: `${#v}` and `${v:0:N}` count and cut characters under a UTF-8 locale and BYTES under
C, and `[[:cntrl:]]` matches the C1 range under an ISO8859 one, so unpinned they did
different things on the same input and a non-interactive shell with no `LANG` took the byte
branch. §"Marker-Block Carriers" records the same class for the two marker hooks and resolves
it by measuring through `node`, which is not available on a path that runs per emitted line.
**Every claim-derived value at every emit is screened, not only the three UNVERIFIED arms** —
step 5b b) tells the model to copy every non-`EDIT LANDED` line VERBATIM into the run log, the
report and the CHAIN-END SUMMARY, so the unscreened emits were the most-carried ones, and the
bare-`WIRED` arm interpolated the ENTIRE raw log line.

**The doctor row spawns the library rather than re-implementing it.**
`claimTopologyRow` resolves this session's receipt (`readNoteJson`, the hardened reader
the denial notes already use), resolves its `log` inside the project's own
`.zensu/logs/`, and `spawnSync`s `bash zensu-edit-landing.sh --inventory` with a 5 s
timeout. That is the ONLY subprocess in that renderer, and it is deliberate: the
alternative was a second copy of the claim grammar in JS. The row WARNS when the
library is absent from the plugin tree — `pluginDir()` resolves to the renderer's OWN tree,
so a row that is executing at all proves the feature IS installed and an absent command is a
damaged one — with silence there gated on the `ZENSU_DOCTOR_PLUGIN_DIR` fixture override
rather than on the errno, as the gap bullet below records. It also WARNS when the command was there and
did not complete — a check that did not run must never read as an all-clear. `/zensu:doctor`
refuses on win32 by design, so `bash` is available wherever this row can render at all.

**Version: `patch`.** Walked against §"Runtime Lineage" entry by entry: no context-record
or workflow-state schema field (the receipt is neither, and no field was added to it
either), no strict key set, no hook added, removed or renamed and no matcher changed, no
new config key (`ZENSU_EDIT_LANDING_GATE` is reused), no attestation change. The terminus
refuses MORE than before, which is a gate tightening inside one installation rather than a
capability change to a session an older runtime is serving.

**Operator-facing accounts that must move with it:** discipline patch 10 in
`docs/tdd-manager-workflow.md`, the `ZENSU_EDIT_LANDING_GATE` row in
`docs/configuration.md`, the two-refusal lead-in of `docs/gates.md`, the topology bullets
plus the frontmatter `session state` clause in `skills/doctor/SKILL.md`, Phase 6 step 5b b)
and step 10.1 in `skills/tdd/SKILL.md`, and ALL THREE multi-repo documents —
`docs/multi-repo-chains-spec.md` (its status line, the two §2 paragraphs stage 1
superseded, the §5 heading and the pin roster at the end of §10) together with
`docs/multi-repo-chains-overview.html` and `docs/multi-repo-chains-principle.html`, which
carry the same status lede and the same superseded facts in their own words. Naming the
spec alone was wrong and produced real drift: `test-multi-repo-doc-consistency.sh` X7
requires the literal `stages 2 and 3 are BLOCKED` in all three, so a status reword is a
deliberate three-file edit, and the overview's finding cards restate terminus behaviour
that §2 now marks superseded.

**The review round that followed the first draft changed five things in the
production halves, and each one is a rule rather than a tidy-up.**

**Every `git` call in the audit library runs through `_el_git`, which unsets the
discovery and config-injection variables.** `REPO_ROOT` / `REPO_CANON` decide which
absolute claims `absolute_claim_verdict` calls FOREIGN, so an ambient `GIT_DIR` or
`GIT_WORK_TREE` moves the anchor and silently empties the doctor's topology row —
and the same variables move the change UNION that decides landed versus not-landed.
`--tdd-complete` already scrubbed the same names for its own count through
`_tc_git` — fifteen as of this writing, and see §"Requirements-Table Gate" for why the
numeral is a witness rather than the contract; the library is spawned as a CHILD and
inherits the caller's environment, so it has to scrub for itself. Neither caller passes a filtered `env`, deliberately:
the scrub belongs where the `git` call is, or the next caller re-opens it.

**The receipt reader discriminates an I/O fault from a CONTENT fault.** Every `fs`
failure carries an errno `.code`; `JSON.parse` throws a `SyntaxError` that carries
none. One unconditional `catch` reported `EACCES`, `EIO` and the ENOENT race against
the shell's own `-f` test as "does not parse as an edit-landing receipt" — naming the
wrong cause AND prescribing a remedy, re-run the audit, that would hit the same
fault. The `unreadable` refusal text was widened to cover a failed read rather than
only a non-regular or oversized file.

**The retirement of the previous generation's receipt runs on the SUCCESS arm of
`--tdd-begin`, never above it.** `autopilot_begin_standalone_tdd` refuses a held
workspace and several storage and argument faults, and on that arm the PREVIOUS
generation is still the live one — so retiring first left a live chain with no
receipt and its own `--tdd-complete` then refused with "no edit-landing receipt for
this session", a cause that never happened. Nothing reads the receipt between the two
points, so the earlier position bought nothing. `Z8c` pins the offset, because a
failing begin cannot be staged from that suite.

**The library's signal traps TERMINATE.** A bash trap handler that RETURNS resumes
the script, so `trap cleanup EXIT INT TERM` over a `cleanup` ending in `return 0`
made the doctor's 5 s `spawnSync` deadline unenforceable — and worse, `cleanup`
unlinked `CLAIMS_FILE` mid-run while the log loop's next `>>` recreated it, so the
inventory then counted only the claims logged after the signal. `trap cleanup EXIT`
stays; `INT` and `TERM` get handlers that clean up and exit.

**The run log is resolved on BOTH arming channels.** Gating the resolution on
`_tc_armed -eq 0` made the stem bind unreachable on the DOMINANT path — a dirty tree
— where a `clean: true` receipt describing some other run log satisfied the verdict
test unchallenged. The INVENTORY stays gated on the zero-change arm, because arming
is the only thing it is for, and it is now bounded through the shared
`zensu_run_bounded` ladder rather than spawned without a deadline while the doctor
bounds the identical call.

**`auditedRunLog` answers a TYPED result.** `{path}` resolved, `{reason}` something
is wrong with the tree, `{}` nothing to check. Collapsing the middle class into
silence made a symlinked `.zensu/logs`, an escaping `log` and a symlinked run log
read exactly like a project that never ran an audit — the same tamper class the two
disclosed branches beside it already refuse to hide. A clean `ENOENT` stays silent,
because `.zensu/logs` is gitignored and absent in most projects. The logs directory
is additionally bounded against the project root, which the leaf `lstat` cannot see:
it is blind to a RELOCATED `.zensu` component, and the sibling derived-channel reader
in `zensu-log.sh` already carried that assertion.

**The rendered stems are SCREENED and the compared stems are not.** `_tc_receipt_log`
comes out of a receipt in `<project>/.zensu/state/`, which this file records as
session-writable with no gate covering it, and its stem reaches a refusal a model
reads. Comparison uses the raw values; rendering uses a copy with no control byte, no
backtick and a bounded length — the same treatment the doctor's topology row gives a
claim root.

**TWO standing fixes are named here rather than taken, each with its trigger.** The
receipt FILENAME is hand-derived in FIVE places — the writer, both `zensu-log.sh`
verbs, and TWO in the doctor renderer (`claimTopologyRow`'s join and
`someClaimReceiptPresent`'s `/^edit-landing-.+\.json$/`) — with no owner and no pin. The count
moved because a change ADDED a site rather than touching two, which the stated trigger below
cannot see, so extend it to fire on a new site as well; the failure is silent in the dangerous
direction, since a rename that updates the four leaves the regex matching nothing and the
no-key topology row then goes quiet and reads as a clean topology, while `SCH1` pins only the
four SCHEMA spellings; the durable answer is a `tdd_edit_landing_receipt` accessor
beside `tdd_state_file` in `zensu-tdd-phase.sh`, and the trigger is the next change
that has to touch any two of the four. And ONE artifact still has TWO readers inside
`--tdd-complete`: `_tc_receipt_verdict`'s hardened descriptor-side read, and the requirements
gate's own read a hundred lines below it, which re-parses the same session-writable file with
a window in between. **State what that second reader IS, because an earlier revision of this
paragraph described a shape that no longer exists**: it was `lstatSync` + `readFileSync` with
no `O_NOFOLLOW`/`O_NONBLOCK`, and it is now the same hardened
`openSync(O_RDONLY|O_NOFOLLOW|O_NONBLOCK)` + `fstatSync` + bounded loop the verdict reader
uses. So the residual is the double READ and its TOCTOU window, not a weaker open; the
durable answer is unchanged — have the verdict reader return the resolved,
containment-checked log and have the requirements gate take it as input. Neither was taken
inside a change set already several review rounds deep.


**Known gaps, accepted and named:**

- **A RELATIVE foreign claim is ungradeable and stays so.** `src/index.ts` from a sibling
  repository is textually identical to an anchor claim, and where the anchor holds a dirty
  file of that name it grades as LANDED — a false green INSIDE the audit, in the exact
  direction stage 1 exists to close. Only the stage 2 root label closes it; `X6` in
  `tests/structure/test-edit-landing-audit.sh` pins the current behaviour so the gap cannot
  be mistaken for detection.
- **The claim-armed scope needs a channel.** With neither `--plan` nor a receipt — the
  flag-free recovery spelling of `--tdd-complete` — a zero-change chain keeps the
  pre-stage-1 exemption, silently, because nothing identifies its run log.
- **The doctor row needs a receipt.** Before the first audit there is nothing that names
  this session's run log, so the row cannot fire; after the audit, the audit's own failure
  has already named the root. The row's value is that it persists across turns.
- **The FLAG-FREE `--tdd-complete` spelling gets no stem bind at all.** `_tc_run_log` is
  assigned only inside `[ "$seen_plan" = true ] && [ -n "$plan_val" ]`, so without `--plan` the
  `[ -n "${_tc_run_log:-}" ]` conjunct is false and the whole stem comparison is skipped — a stale
  `clean: true` receipt naming a DIFFERENT run log satisfies the gate on that path. Within one
  installation the `--tdd-begin` retirement covers it; it does NOT cover the mixed case the
  Runtime Lineage policy exists for, an older `--tdd-begin` with no retirement followed after a
  mid-session plugin update by a newer `--tdd-complete`. `chain-recovery-v1.js`'s `NEXT_COMMAND`
  renders the recovery spelling flag-free, which is exactly that spelling. The ARMING gap for the
  same channel is recorded above; this is the BIND gap beside it, and the suite does not reach it
  either — `Z6`/`Z6a` drive the no-`--plan` path for arming only and `Z7`/`Z7a` pin the stem bind
  with `--plan` passed.
- **The redactor decides which half of stage 1 is reachable.** No ordinal: this bullet carried
  "the FOURTH known gap" while sitting fifth in its own list, which is what a hand-maintained
  position always does to a list that grows.
  `zensu-log.sh append` passes every message through `zensu-artifact-redact-v1.js` and `.log` is a
  redaction bucket, so a claim naming a sibling repository under `$HOME` is rewritten to `~/...`
  BEFORE it lands in the run log. The `/*` arm in `normalize_claim` is the only entry to
  `absolute_claim_verdict`, so that claim never matches it, no `foreign-root` line is emitted and
  the doctor topology row cannot fire for the topology the spec's own worked example uses. Roots
  outside BOTH `$HOME` and the project root — `/opt`, `/srv`, a CI checkout under `/builds` —
  survive redaction and the feature works correctly on them. Say WHICH HALF is universally live,
  never that stage 1 detects cross-repository work in general. **The `<project>` direction was
  the same interaction running the OTHER way and it is now CLOSED, which is why this bullet must
  not be read as covering it.** Rule 1 of the redactor rewrites the project root to the literal
  `<project>`, so an author who spelled an in-anchor claim absolutely got `<project>/src/x.ts` in
  the run log: no leading `/`, so never `absolute_claim_verdict`; in the union under no spelling;
  and the `*/*` arm returned it verbatim — `EDIT NOT LANDED` for an edit that DID land, a
  `clean: false` receipt, a refused `--tdd-complete`, and a step 5b b) remedy (land it at the path
  the claim names) that cannot be performed. `normalize_claim` strips that placeholder now, which
  is sound HERE and only here because it denotes the root this run was handed. The `~` half stays
  a stated bound for the opposite reason: `$HOME` names any home-rooted path, including a genuine
  sibling repository, so guessing there would relabel foreign work as in-anchor. `X16`/`X16a` in
  `tests/structure/test-edit-landing-audit.sh` build their run log through the production writer
  rather than `printf` and pin both directions; every other fixture in that file writes with
  `printf`, which matches no redaction rule, which is why the suite was green against an input
  shape the production writer rarely produces. The durable fix is to un-substitute
  `<project>`/`<home>`/`~` against the same roots the redactor used, before classifying.
- **The no-bound-key topology row withholds the green summary.** It is `WARN`, and `line()`
  counts WARN toward `warnCount`, which `main()` gates "all checks green" on — so any session
  whose binding does not resolve, in a project that has ever written an edit-landing receipt,
  loses the clean summary. `someClaimReceiptPresent` cannot tell whose receipt it found, which
  is why the row says so rather than claiming it is this session's. Accepted on the same ground
  the foreign-chain, implementing-turns and consent rows accept it: a row that can never affect
  the summary is a row people stop reading.
- **The receipt publish is a check-then-write on the temp name.** `mktemp` creates it, `[ -L ]`
  tests it, and a plain `>` redirect then follows whatever is there — the shape the comment
  directly above it argues against for the FIXED name while leaving it on the random one. The
  destination is session-writable, so this is a window rather than a closed hole, and winning it
  means racing a six-character suffix. The durable fix is the `O_NOFOLLOW|O_EXCL` descriptor
  pattern `writeArtifactLine` already establishes, written by the node child that is already the
  writer. Not taken here.
- **Anchoring, not enforcement.** The receipt and the run log are ordinary files the
  session can write, so a model that wants to defeat this can. It bounds accidents — a
  chain that genuinely worked in two repositories — rather than intent.
- **The run log handed to the inventory child is validated by NAME, and half of that is
  closable in one line.** `zensu-log.sh` tests `[ -f ]` plus `[ ! -L ]` and the doctor's
  `auditedRunLog` tests `isSymbolicLink()`, while the library they spawn opens it with a plain
  shell redirect. State the two halves separately, because they are not the same size. The
  library's own `[ -f "$LOG_FILE" ]` carries NO `! -L`, so a caller-chosen `--log` — and
  `--inventory` is a documented CLI — reaches a symlinked run log the two shipped callers would
  have refused; that divergence is a one-line fix. The residual proper is the WINDOW: the check
  and the read are ~390 lines and several subprocess spawns apart, so a swap in between is
  followed. `exec 3< "$LOG_FILE"` immediately after the check collapses the window without
  giving `O_NOFOLLOW`, which a POSIX shell cannot express. Recorded rather than closed here, and
  the reason is scope rather than impossibility — do not restate it as "a shell reader cannot do
  this", which is true of the FLAGS and false of the window.
- **`ZENSU_DOCTOR_PLUGIN_DIR` gates the absent-library silence, and that departs from this
  repository's own strongest precedent.** The argument for it holds — `pluginDir()` already
  redirects the whole tree, so gating on the override adds no capability a caller did not have —
  but the rule it departs from is one this file states repeatedly: a check that did not run must
  never be indistinguishable from one that passed, and a SUPPRESSED check emits an explicit
  switched-off row rather than silence (`hooks.reviewerSpawnPermissionCheck`,
  `implStopNudgeAfter: 0`). The uncompromised answer is a disclosed skip; it is not taken, and
  the departure is recorded HERE so the next reviewer does not have to re-derive it.
- **`ci-shard-weights.v1.json` has no entry for the grown edit-landing suite, and it must not
  get an estimated one.** That file's own note requires a real CI figure and this repository's
  rule is that a ceiling or a weight comes from a green measurement, never from an estimate. The
  obligation is therefore a FOLLOW-UP with its source named: take the number from the first green
  ubuntu-latest `--ci` run after this lands. Recorded so it does not quietly become "fixed by
  estimating" in a later round.
- **The subprocess in the renderer is a named cost, not a settled design.** `claimInventory`
  is the only `spawnSync` anywhere in `hooks/lib`, in a renderer whose pattern for every other
  dependency is a lazy guarded `require`, and it carries the audit library's two
  `git rev-parse` calls onto the doctor's path behind a 5 s timeout — SCRUBBED, both through
  `_el_git`, which is what this bullet used to get wrong while the same section said the
  opposite thirty lines above it. The residual is the subprocess and its deadline, never an
  unscrubbed environment. Rejecting a second JS copy
  of the claim grammar was right; a subprocess is not the only way to keep one owner. **The
  standing fix is a host-neutral `edit-landing-claims-v1.js`** that the shell loads from its
  `node -e` and the doctor `require`s — the shape `rule-block-v1.js` already ships for a
  cross-language carrier. It was not taken here because it re-authors the extraction loop the
  checks of `test-edit-landing-audit.sh` pin; take it with its own review. No numeral here on
  purpose — this file's own rule is that a hand-maintained count is what a driven loop cannot
  catch, and the one that stood here was stale within the change that wrote it.
- **Windows is UNVERIFIED for all four behaviours.** None of the three suites is in
  `tests/profiles/windows-ci.v1.json`; `test-edit-landing-audit.sh` and
  `test-tdd-complete-receipt-gate.sh` run on the weekly Windows Safety structure shard,
  `test-doctor.sh` runs there too, and no wall clock has been taken for the added rows.
- **No ports.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were NOT included.
