---
paths:
  - "hooks/lib/zensu-plan-requirements.sh"
  - "templates/zensu-plan.md"
  - "tests/structure/test-requirements-table-gate.sh"
  - "tests/structure/test-tdd-complete-receipt-gate.sh"
---

# Requirements-Table Gate (`hooks/lib/zensu-plan-requirements.sh`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

`--tdd-complete` refuses a chain whose plan carries no usable `## Requirements` table.
It exists because `/zensu:converge` anchors its whole flow-back audit on that table and
takes a documented LEGACY STOP without one — and in `/zensu:autopilot` the CONVERGE stage
is the ONLY edge into `OPEN_PR` (`hooks/lib/zensu-autopilot-state.sh`, `CONVERGE:CONVERGENCE_PASSED`),
so a missing table turned a machine-mandatory gate into a clean-looking no-op. Both ends
stayed green, which is why it went unnoticed: measured across the author's plan corpus,
a third of plans written after the feature shipped carried no table at all.

**The rule lives in ONE place, and it is STRICTER than converge — not identical.**
The library is the executable copy. Converge's own table rule is its **Phase 0 step 2**
legacy stop, which keys on the table being ABSENT; this library additionally refuses a
present-but-placeholder table, and the two also disagree about deprecated rows in the
opposite direction (counted here, EXCLUDED from converge's coverage audit). Say
"stricter", never "shared" or "cannot disagree": a plan this gate passes is not
automatically one converge can audit in full. The Requirement column is located from the
table's header row rather than assumed to be the second, because the repo-override contract
pins the columns and never their ORDER.

**Which plan is judged is the load-bearing decision, and BOTH channels are bounded.**
`--plan <path>` wins (the skill passes it, in both the Phase 6 spelling and the
Mandatory-command-protocol one — they must not disagree); otherwise the gate reads the
edit-landing receipt's `log` field and substitutes `.zensu/logs/<stem>.log` →
`.zensu/plans/<stem>.md`, because both artifacts are created from one
`{SESSION_TS}_build-{slug}` stem. The derivation binds the receipt's `schema` discriminator and
requires the `log` to resolve INSIDE the project's own `.zensu/logs/`; the explicit flag must
resolve inside `.zensu/plans/` and carry the same stem — and with no derivable stem the flag is
REFUSED rather than falling through to the directory bound alone, EXCEPT when
`ZENSU_EDIT_LANDING_GATE=off` is what removed the receipt. That switch is documented as
exempting a session from the receipt precondition, and no receipt means no stem, so refusing
there would make the documented exemption unusable for the shipped invocation, which always
passes `--plan`. In that one case the bound is DROPPED and DISCLOSED (`REQUIREMENTS GATE STEM
UNCHECKED` on stderr), never faked. Without those bounds the flag would
silently defeat the session anchoring the derivation exists to provide — any older plan with
one filled row would satisfy the gate — and a receipt is an ordinary file the session can
write. Every comparison canonicalizes both sides (`realpath` / `cd … && pwd -P`): on macOS a
temp root is spelled `/var/…` by the caller and `/private/var/…` by the kernel, and a raw
string compare there rejects the session's own plan. Four things must therefore move
together: the stem convention in Phase 2 of `skills/build/references/planning.md`, the receipt's `log` field and
its JSON ENCODING in `hooks/lib/zensu-edit-landing.sh`, the substitution in `zensu-log.sh`,
`templates/zensu-plan.md` — whose `{acceptance criterion — machine-checkable}` / `{functional requirement}` cells are exactly what the placeholder-stripping rule keys on, so changing that placeholder syntax makes the gate misjudge — and `{plan_file}`'s definition beside `{log_file}` in Principle 3 — which Phase 2 step 1 now
WRITES, so producer and consumer share one spelling. The receipt's `log` is JSON-ENCODED and
persisted PROJECT-ANCHORED, so the reader never has to guess a root. One of these IS pinned and
it is easy to miss: `tests/structure/test-autopilot-durable-skill.sh` D9 hardcodes the bound
`--tdd-complete` literal from the skill, so adding the flag to that spelling broke a CI suite
this session. The roster is neither fully unpinned nor fully pinned, and D9 is the pin.

**Asymmetric fail direction, deliberately.** An explicit `--plan` that names nothing REFUSES —
the caller asserted where the plan is. A DERIVED path that is not there does NOT, because
nothing was asserted — but the gate then prints `REQUIREMENTS GATE UNRESOLVED` instead of
staying quiet, because "the table passed" and "no table was checked" reading the same is the
exact failure this feature exists to remove. **Refusal wording is typed**: exits 3/4 are a
verdict about the plan, exit 2 and anything else (a missing library included) refuse with
"could not judge the plan" — the sibling rule CLAUDE.md already states for the plan-payload
gate, that a load fault must never be reported as a judged payload.

**Scoping and the switch are copied from the edit-landing receipt gate**, which sits directly
above it in the same verb: a non-empty change set, counted by the helper the unqualified terminus
uses (next paragraph). **The two SCOPES
have since diverged and "copied" is historical:** multi-repo stage 1 arms the receipt gate on a
logged CLAIM as well (see §"Multi-Repo Stage 1"), so that gate conjoins on `_tc_armed` while this
one still conjoins on `_tc_changes` alone. The zero-change chain this section records below as
ungated therefore stays ungated HERE — do not read the sibling's wider scope as covering it. The
two still share ONE
change-set computation and ONE spelling of the receipt path — the shared values carry a
verb-scoped `_tc_` prefix, not an `_el_` one, so neither reads as the other's private state, and
`tests/structure/test-tdd-complete-receipt-gate.sh` W3pre/W3 hardcode that prefix (renaming it
made W3 silently vacuous once already, which is why W3pre now checks its own anchor first) —
but they must NEVER share a switch: the computation is armed when EITHER is on, and both
`ZENSU_EDIT_LANDING_GATE` and `ZENSU_REQUIREMENTS_GATE` record a bypass-ledger entry (both were
added to `ZENSU_BYPASS_GATE_ALLOWLIST`; the ledger is what keeps everything a chain renders
under "Gates bypassed" true). **All four consumers conjoin on THEIR OWN gate's scope** — the
receipt gate and its ledger record on `_tc_armed`, this gate and its ledger record on
`_tc_changes` — because out of scope there is no decision point to short-circuit, so recording an
escape there would name a gate that never ran. Say "their own": the two scopes diverged when
stage 1 added the claim arm, and one shared "the scope" reads against the paragraph above.

**A git failure in the scope count refuses the verb; it is never read as zero changes.** The
count comes from `_zensu_unqualified_change_count`, the helper the unqualified terminus uses, so
`--tdd-complete` shares its classification (Known gaps below states it in full). `unknown` (no
`git` on PATH, a root git reports as outside a work tree, a HEAD that names no commit) maps to
zero and leaves both gates out of scope. `unavailable` (a `safe.directory` refusal, a HEAD probe
git aborts, a failed listing) refuses with exit 1 before either gate runs, and the refusal names
`git diff --name-only HEAD` as the way to see git's error. Read as zero, such a failure would take
this gate and its ledger record out of scope, and leave the receipt gate and its record armed
only by a logged claim. Two alternatives were rejected. Arming both gates on `unavailable`: the
edit-landing audit reports the same refusal as `EDIT LANDING AUDIT FAULT`, exits 2, writes no
receipt and removes an earlier one (`.claude/rules/multi-repo-stage1.md`), so the receipt gate
would refuse with "no edit-landing receipt" and name the audit, not git, as the thing to run.
Refusing whatever the
switches say: with both gates off the count decides only the two ledger records, and a ledger
record must not change a completion decision. So with BOTH `ZENSU_EDIT_LANDING_GATE=off` and
`ZENSU_REQUIREMENTS_GATE=off` the verb completes and records both escapes, reading the
undecidable count as in scope; the evidence runner records `ZENSU_FULL_SUITE_GATE=off` on an
`unavailable` tree the same way. One switch alone never reaches that arm, because the other gate
still needs its scope. All three consumers test `"$_tc_changes" != 0`, so only a zero or
`unknown` exempts, and an empty or malformed answer reads as in scope. In
`tests/structure/test-requirements-table-gate.sh`, `RG0`–`RG3` drive a real dubious-ownership
refusal, its `safe.directory` control, each single switch and the both-off ledger, and `Z3`,
`Z4`, `Z6` and `G2` pin the shared call, the `!= 0` consumers and the `unknown` mapping. In
`tests/structure/test-tdd-complete-receipt-gate.sh`, `R6`/`R6a` drive the same refusal against
the receipt gate on a changed tree, and `W2` pins the shared call. `G13` in
`tests/structure/test-chain-terminus-zero-change-gate.sh` counts the call sites. Version:
`patch`, because the verb refuses more inside one installation and no schema, key set, hook,
matcher or attestation moves.

**Every root in this verb comes from `zensu_resolve_project_dir`, and there is NO divergence to
defend against — a claim an earlier draft of this section got wrong.** `zensu-log.sh` matches
every `--*` verb at the top of the file, binds the session, and unconditionally re-exports
`CLAUDE_PROJECT_DIR="$(zensu_resolve_project_dir)"` BEFORE any verb body runs, so an inherited
`CLAUDE_PROJECT_DIR=` prefix cannot reach the gate at all. `_tc_root` therefore calls that
accessor for OWNERSHIP — the alternative was triple-`dirname` surgery over a layout
`tdd_state_file` owns, which a layout change would silently mis-root — not as a defense. Do not
reintroduce a "the two can disagree about which tree they looked at" residual; it is false. A `.zensu/plans` or `.zensu/logs` component that
is a SYMLINK is refused rather than resolved through — canonicalizing both sides and comparing
for equality would otherwise compare a link target with itself and admit a file anywhere on the
host — and the `..` test is anchored (`rel === ".." || rel.startsWith(".." + sep)`), because a
real file named `..bak.log` inside the directory is inside it.

**Ordering is a contract, not layout.** The receipt refusal must stay FIRST (a session with
neither artifact should hear about the audit it skipped, not about a plan it never reached),
and the table refusal must stay ABOVE the standalone/bound split, which is the only reason
Autopilot-bound chains are gated at all. `tests/structure/test-requirements-table-gate.sh`
B1/B2 pin both, anchored on the REFUSAL text rather than on the env var — the shared
computation names `ZENSU_REQUIREMENTS_GATE` above the receipt refusal, so the switch is the
wrong landmark. Note that source pins must match the ON-DISK bytes: the refusal spells the
section name as an escaped `` \`## Requirements\` `` inside a double-quoted echo, so a grep
written against the decoded message finds nothing.

**The `## Requirements` shape has SEVEN readers, not two**, and all five beside this library
and `/zensu:converge` are model-executed and PRESENCE-ONLY, so every one of them accepts a
placeholder-only table this library refuses: `skills/self-review/SKILL.md` twice (the per-AC
table in the chain-end summary, and the converge offer it renders), and the build skill
three times (Phase 6 step 6c's "If the plan has no `## Requirements` table (legacy plan), skip
silently" in `skills/build/references/audit.md`; the step-10 converge offer in
`references/review-chain.md`, which this thread renders when `hooks.selfReview` is disabled; and
the vanilla-mode statement in `references/modes.md` that the table and the `Covers` mapping stay
binding).
A change to what counts as a usable table has to reach all seven. An EIGHTH reader is
mechanical and shares this library's own parser: `--list` prints every recognized row with its
state (`active`, `deprecated`, `placeholder`), and `hooks/lib/acceptance-verify-v1.js` takes its
criteria from it (`.claude/rules/acceptance-verification-gate.md`). Two further containment
predicates were added by this gate — the JS one in the derived-channel reader and the shell one
in the explicit channel — which extend the hand-copied `within()` / `isInside()` family this file
already tracks. The standing fix for the JS half is TAKEN: the reader is `receiptRunLog` /
`resolveRunLog` in the built-ins-only `edit-landing-receipt-v1.js`, which `--tdd-complete` runs
through `main(['receipt-log'])` and `acceptance-verify-v1.js` requires, unit-tested in
`acceptance-verify-v1.test.js`, so the derivation and the acceptance gate resolve the plan
through one reader. An exit other than 0 (a log) or 3 (none) refuses `--tdd-complete`, because
a reader that cannot run is not a verdict about the plan.
**The two copies do not enforce the same bound**:
the JS half accepts anything that does not ESCAPE `.zensu/logs/` — including a subdirectory —
while the shell half requires exact directory equality for `.zensu/plans/`. Low impact (a looser
logs bound only changes the derived stem) but it is a divergence, not one rule in two places.
**Neither half has ever run on Windows**: `test-requirements-table-gate.sh` is not in
`tests/profiles/windows-ci.v1.json`, which is a curated set, so the derived channel's Windows
behavior is unverified in both directions — say "unverified", never "covered".

**The receipt schema moved to `edit-landing-v2`, and the reader accepts BOTH.** Holding the
discriminator at `v1` while the `log` field became project-relative was tried first and was
wrong: one schema name then covered two value domains, so the reader had to infer the writer from
a leading slash — and that inference REFUSED a perfectly readable v1 receipt on win32, which,
because the shipped skill always passes `--plan`, became a completion-blocking `exit 1` rather
than a warning. The version cost was never avoidable: under the runtime-lineage rule above a
persisted shape that moves costs a `minor` release whether or not the NAME moves, so
`version_type: minor` is required for this change either way — moving the name is simply what
buys the reader something for that price. Keep this true: `v1` is a SUPPORTED input, not a
corruption. A plugin update landing between the step 5b audit and `--tdd-complete` is explicitly
served by the lineage rule, so both branches must stay readable, and both are judged by
CONTAINMENT rather than by spelling.

Operator-facing accounts that must move with it: `docs/gates.md` §"Requirements-Table Gate",
the `ZENSU_REQUIREMENTS_GATE` and `ZENSU_EDIT_LANDING_GATE` rows plus the visible-opt-outs
enumeration in `docs/configuration.md`, and discipline patch 11 in
`docs/build-workflow.md`.

**Known gaps, accepted and named:**

- **The check is one-sided.** It proves a table EXISTS and is filled in; it cannot tell whether
  the rows describe the work actually done. A chain that copies eight plausible requirements it
  never implemented passes. Closing that is `/zensu:converge`'s job, which is what this gate
  exists to keep reachable.
- **A bound zero-change chain is not gated, and that is the edge the feature is about.** The
  scope requires a non-empty change set, but Phase 2 writes a plan unconditionally and
  `--outcome no-changes` is NOT special-cased in `zensu-autopilot-state.sh` — the run still
  travels its return stage into CONVERGE, the only edge into `OPEN_PR`, and converge
  mtime-resolves that ungated plan and legacy-stops. Do not read "CONVERGE is the only edge
  into OPEN_PR" as "that edge is now covered".
- **`ZENSU_EDIT_LANDING_GATE=off` weakens this gate too.** With no receipt there is no run-log
  stem, so an explicit `--plan` keeps only its plans-directory bound: a stale plan from an
  earlier session in the same project satisfies it. Disclosed on stderr, not silent, and the
  same switch already carries its own ledger entry.
- **The git-environment scrub is a denylist, so its numeral is a witness, not the contract.**
  The three scope `git` calls `--tdd-complete` counts through run in a subshell that unsets the
  FIFTEEN `GIT_*` variables `_tc_git` lists — discovery and config-injection levers alike, not just the
  three this paragraph used to name. **Read the numeral as a WITNESS to the last audit, never as
  the contract**: it has now been wrong at thirteen, at fourteen, and in both directions at once.
  Both lists stood at thirteen while neither set was a subset of the other — `_el_git` carried
  `GIT_PREFIX` and no `GIT_CONFIG_COUNT`, `_tc_git` the reverse — and the matching count is what
  made the parity claim read as verified. They reached fourteen agreeing with each other and
  both SHORT, because `GIT_CONFIG_PARAMETERS`, git's serialized `-c` channel, was gated by
  nothing and injected `core.excludesFile` directly; the comment calling `GIT_CONFIG_COUNT`
  "the single lever" is what kept anyone from looking for a second one. The contract is the
  PROPERTY — every channel by which discovery, the object database, the prefix or config
  reaches `git` — and `X10e` in `tests/structure/test-edit-landing-audit.sh` compares the two
  lists directly, so a one-sided addition fails loudly. State what that pin CANNOT see: two
  lists that agree and are both short, which is exactly the state fourteen was. `X10`/`X17` and
  their controls cover that instead, one behavioural injection probe per config channel, so a
  third channel needs a third probe rather than a bigger numeral. `_tc_git` sits at file scope,
  above the verb dispatch, and every change count in `zensu-log.sh` runs through it inside
  `_zensu_unqualified_change_count`, which four callers share — `--tdd-complete`, the
  `--chain-done` zero-change terminus, the unqualified `--code-review-done` mark, and the
  ticket-bound `--chain-done` when its ticket is one the Stop hook minted for a chain no reviewer
  saw (prefix `zc_`, see `.claude/rules/chain-shape-rearm-receipt.md`). `Z6` in
  `tests/structure/test-requirements-table-gate.sh` pins the file-scope definition, the verb's
  one call of the helper and the helper's three scope calls. In
  `tests/structure/test-chain-terminus-zero-change-gate.sh`, `G11` drives an inherited
  `GIT_DIR` and an excludes file injected through `GIT_CONFIG_COUNT` and through
  `GIT_CONFIG_PARAMETERS` against both unqualified verbs, `G12` and `G12c` a failed listing, and
  `G13` fails on a bare `git -C` outside comments and `_tc_git` calls and requires the helper's
  three `$CLAUDE_PROJECT_DIR` call sites plus the one `--tdd-complete` call on `_tc_root`.
- **The shared change count reads only three git answers as "not evaluable".**
  `_zensu_unqualified_change_count` prints `unknown`, which every caller reads as not evaluable,
  for a host without `git`, for a root git reports as outside a work tree (`rev-parse
  --is-inside-work-tree` printing `false`, or failing with git's own `not a git repository`),
  and for a HEAD that names no commit (`rev-parse --verify --quiet HEAD` exiting 1). Every other
  git failure prints `unavailable`, which every caller refuses: the two unqualified verbs and the
  minted-ticket terminus with their listing text, and `--tdd-complete` before either of its gates
  runs unless both are switched off (see "A git failure in the scope count refuses the verb"
  above). `unavailable` covers a `safe.directory` "dubious ownership" refusal (exit 128), a root
  that no longer exists (`cannot change to`), a HEAD probe that git aborts, and a failed listing.
  An empty root prints `unavailable` too; no caller passes one, because the bind exits 2 first
  and `--tdd-complete` refuses an empty `_tc_root` before it counts. The split is the
  one `workTree` in `hooks/lib/evidence-run-v1.js` draws between `not-applicable` and
  `unavailable` for the full-suite gate. It is copied rather than called, because `_tc_git` stays
  this file's only git entry point. The error text is matched under `LC_ALL=C`, as the runner
  does: a localized git otherwise turns a root outside git into `unavailable` (observed with git
  2.51 under `LANG=de_DE.UTF-8`). In `tests/structure/test-chain-terminus-zero-change-gate.sh`,
  `G14` drives a real dubious-ownership refusal through `GIT_TEST_ASSUME_DIFFERENT_OWNER`, which
  `_tc_git` keeps, in a HOME without git config and with `GIT_CONFIG_NOSYSTEM=1`. Its controls
  show that real git refuses the fixture and that a `safe.directory` exception in such a HOME
  clears the refusal, and `G14c` closes the same chain under that exception. `G14d` asks the
  runner's `workTree` about the same refusal and the same root outside git that `G14a`, `G14b`
  and `G7` drive through the verbs, so the two copies are held to the same answers on those
  inputs. `G15` fails only the HEAD probe through a stub `git` on PATH. An unreadable
  `packed-refs` does the same with real git (exit 128 while the work-tree probe still answers
  `true`), but a suite running as root reads the file anyway, and `chmod 000` under Git Bash is
  unverified, so that fixture would not discriminate everywhere this suite runs. `G16` runs the
  terminus on a root outside git under the first candidate locale that localizes git's message;
  its label says when no candidate did, and the check then does not discriminate. `G14` to `G16`
  drive the two unqualified verbs; the minted-ticket terminus reads the same helper, and `G12c`
  pins its `unavailable` arm.
  Bounds: git's own answer decides, so a linked worktree whose administrative directory was
  removed reads `not a git repository` and passes, as it does for the full-suite gate, and a
  corrupt branch ref makes the HEAD probe exit 1 exactly like an unborn branch, which every caller,
  `--tdd-complete` included, then reads as not evaluable.
- **A mid-run commit disarms THIS gate.** The change set is the worktree against `HEAD` with no
  baseline range, so a chain that committed its work measures zero changes and this precondition
  skips — without even the `REQUIREMENTS GATE UNRESOLVED` line, because the whole block is out of
  scope. It no longer disarms the SIBLING: since multi-repo stage 1 the receipt gate also arms on
  a logged claim, and the shipped invocation always passes `--plan`, so the committed
  generation's run log still arms it. The sibling edit-landing library carries a `--baseline` range for exactly this case;
  this verb does not.
- **The standalone `/zensu:converge` offer carries no plan path**, so the gate and the consumer
  can resolve different plans: the gate judges the receipt-derived plan, converge takes the
  newest by mtime. `/zensu:autopilot` step 2b closes this for the bound flow by passing the
  session plan explicitly; the standalone offer literal is rendered by
  `post-review-tdd-delegate.sh` and pinned in several suites, so changing it is a
  cross-file edit that has not been made.
- **A THIRD renderer of the bound `--tdd-complete` deliberately omits `--plan`:**
  `hooks/lib/chain-recovery-v1.js`'s `NEXT_COMMAND` (mirrored in `skills/recover-chain/SKILL.md`)
  renders the recovery spelling flag-free, so an unwedged chain takes the derived channel — the
  weaker one, which can end at `REQUIREMENTS GATE UNRESOLVED` when no receipt exists. It is left
  that way because the recovery renderer has no session plan path to interpolate.
- **The load-fault branch is not behaviorally tested, and cannot be from a bound session.**
  Session Control binds the executing plugin root by runtime DIGEST, so removing or renaming
  `zensu-plan-requirements.sh` in the executing tree makes every stateful command refuse with
  `context runtime digest mismatch` before the verb runs, and a copied plugin root is refused for
  the same reason. Both shapes were tried here and both failed on the binding; the branch is
  pinned at source instead (LM1/LM2).
