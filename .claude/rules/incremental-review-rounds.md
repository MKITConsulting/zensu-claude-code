---
paths:
  - "hooks/lib/review-round-scope-v1.js"
  - "hooks/lib/aspect-activation-v1.js"
  - "tests/structure/test-incremental-review-rounds.sh"
  - "hooks/stop-chain-enforcer.sh"
---

# Incremental Review Rounds (`review-round-scope-v1.js` + `aspect-activation-v1.js`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

Two reductions to what the `/zensu:tdd` review fan-out READS, both gated on a permissively
read config key and both defaulting ON. They exist because the fan-out, not the round
counter, is what the chain actually costs: **measured** on this repository's own subagent
transcripts, one `zensu:review-aspect` agent ingests ~513k context tokens over ~40 internal
turns, `review-judge` ~540k and the consume `code-reviewer` ~345k, so a single full fan-out
moves roughly **3.4M** tokens and `autoFixMaxRounds: 5` multiplied that by up to five. Take
those figures as ONE measurement over six recent sessions, not a bound.

**`hooks.incrementalReviewRounds` narrows rounds 2..N to that round's OWN delta.** Round 1 is
unchanged. The delta comes from the run log the model already writes — every routed round logs
`R<n>-<step> IMPL completed — files: …` — so nothing new is persisted and no workflow-state
field moves. **The reduction is redundancy, not coverage:** an aspect agent re-reading a file
unchanged since the previous round cites the same lines and cannot raise a new finding.

**The JUDGE is excluded, and that exclusion is what makes the narrowing safe at all.**
`zensu:review-judge` always receives the full cumulative `changed_files`, because cross-cutting
drift into a file THIS round did not touch is precisely what a delta hides — it is the one
finding class a narrowed panel structurally cannot raise. Never "simplify" the judge onto the
delta; that deletes the compensating control rather than a redundancy.

**The lean panel (`hooks.reviewPanel`, default `lean`) re-reviews without the judge, by
decision.** The first review spawns `correctness`, `design` and `security` plus the judge; a fix
round's re-review spawns `correctness` alone, on the round delta while
`hooks.incrementalReviewRounds` is on, and no judge (`--panel <panel> --round <round>` of
`aspect-activation-v1.js`, step 4b of `/zensu:tdd`, and the judge clause of every delegate arm). That drops the compensating control above knowingly: with `autoFixMaxRounds: 2`
by default a chain runs up to two lean re-reviews, the last of them hands the chain to
`/zensu:self-review`, which re-reads the whole change, and the consume-mode code-reviewer still
reads the merge. With `hooks.selfReview: false` that whole-change read is gone (see the known
gaps). `reviewPanel: full` restores five perspectives and a judge on every review. Without a judge, a lean re-review routes an
IMPORTANT finding only when it cites code the fix pass edited, and the convergence clause runs
its helpers before classifying instead of before a judge pass. Coupled sites: `zensu_review_panel`
in `hooks/lib/zensu-config.sh`, `PANEL` in `hooks/post-review-tdd-delegate.sh`, `REVIEW_PANEL` and
`REVIEW_PERSPECTIVES` in `hooks/stop-chain-enforcer.sh` with T60 and T61 in
`tests/structure/test-stop-enforcer-self-review-routing.sh`, the `correctness`
and `design` checklist lines of `agents/review-aspect.md`, the `reviewPanel` row of
`docs/configuration.md`, `docs/review-chain.md`, `docs/architecture.md`, `config.example.json`,
LC3 to LC3j in `tests/structure/test-review-convergence.sh`, and LP1 to LP4 in
`evals/config-gate/test-review-convergence-directive.sh`.

**FAIL-OPEN IS THE WHOLE CONTRACT, and it has three degraded causes rather than two.**
`roundScope` answers `ok` only when it resolved a real delta; `empty` (no claims logged for the
round) and `degraded` keep the WHOLE diff. TRUNCATION at EITHER cap is a degraded cause and was
a real defect before it was one: the per-claim cap silently dropped paths, so a claim naming more
than `MAX_CLAIM_FILES` would have reported `status=ok` over a delta missing files — narrowing to
an incomplete delta skips a file the round changed, which is the exact outcome the module exists
to prevent. Its own unit suite caught it. Keep `dropped > 0 → degraded`.

**`hooks.aspectActivation` drops the built-in perspectives a change set cannot implicate**, using
the shape `persona-activation.js` already established for repo-local personas. `conventions` and
`bugs` ALWAYS spawn; `tests`/`security` are skipped only on a documentation-only change set;
`architecture` only when the change set carries no production code at all. **`security`
deliberately still runs on a tests-only change set** — fixtures carry credentials, and that is
exactly the case a "just tests" heuristic would miss. Those are the full panel's rules; the lean
panel skips only `security`, on a documentation-only change set. Empty or unclassifiable input
spawns the whole panel, so a narrowed panel is always a proven reduction rather than a guess, and the predicates
therefore ask "is EVERY file X", never "is SOME file X": one production file restores the panel.

**Every reduction DISCLOSES.** A skipped aspect logs `ASPECT SKIPPED — <aspect> (<reason>)` and a
failing helper logs `ASPECT ACTIVATION UNAVAILABLE — <reason>` and spawns the whole panel. A panel that
shrank silently is indistinguishable from one that was never spawned, which is the failure this
repository treats as worse than the cost it removes.

**Who resolves each key, and why there.** Both keys shipped documented and in `config.example.json`
while nothing read them, so a `false` in any config changed nothing. Each is now resolved where its
decision is made, through `zensu_hook_enabled` against the Session Control record's project root:

- **`hooks.aspectActivation` belongs to `/zensu:tdd` step 3.** Every fan-out runs there, and the
  first review has no hook directive in front of it. A main-thread probe runs
  `zensu_hook_enabled aspectActivation` with `CLAUDE_PROJECT_DIR="{project_root}"`, in the anchored
  form `I11` pins and `I11c`/`I11d` run, and answers `on` or `off`; `{project_root}` is the path
  `zensu-log.sh --project-root` prints, so a project `.zensu/config.json` counts. On `off` the helper still runs, over an EMPTY change
  set: it then skips nothing for what the change set holds, while the lean panel's re-review shape,
  `correctness` alone (`re-review-lean-panel`), stays where it lives, in `aspect-activation-v1.js`.
  Skipping the helper instead was rejected: every lean re-review would have spawned all three
  perspectives, and the panel's shape would have needed a second copy in prose. Step 3 logs
  `ASPECT ACTIVATION OFF — hooks.aspectActivation`, so a documentation-only change set that kept
  `security` is explained in the run log.
- **`hooks.incrementalReviewRounds` belongs to `hooks/post-review-tdd-delegate.sh`.** Only its
  fix-round directive launches a round that narrows, and the hook already exports
  `CLAUDE_PROJECT_DIR` from `zensu_resolve_project_dir` and sources `zensu-config.sh`. It resolves
  the key once above the severity split into `ROUND_SCOPE`: the round-delta clause while the key is
  on, a clause that keeps the whole diff for the aspects and the judge alike while it is off. The
  step 10 fix-round paragraph narrows only when the directive says `hooks.incrementalReviewRounds is
  on` and never resolves the key itself, so the model has no condition left to evaluate. The
  review-convergence clause names the round-scope helper itself, through `SCOPE_HELPER_Q` beside
  `LEDGER_HELPER_Q`, because convergence still runs that helper while the key is off and
  `ROUND_SCOPE` names the file only while it is on (`I17g`, `I17h`, `I32c`).
- **The delegate also resolves `hooks.aspectActivation`**, into `ACTIVATION_INPUT`, because its
  re-review parenthetical used to prescribe the helper over the round's `changed_files`
  unconditionally, which contradicted a probe answering `off`. It now names the round's
  `changed_files` while the key is on and an empty change set while it is off, so the directive and
  step 3 name the same input.

**Coupled sites that move together:** the two libs and their exports; `skills/tdd/references/review-chain.md`
step 3 (the activation probe and its empty-input `off` arm) and the step 10 fix-round paragraph
(which follows the directive's round-scope clause); the `ACTIVATION_INPUT` and `ROUND_SCOPE`
assignments of `hooks/post-review-tdd-delegate.sh` and ALL THREE severity arms that interpolate
them, which are verbatim-identical by contract (`P3b` in `test-finding-verification.sh` counts
`step 4c Finding Verification Gate` in exactly three lines, so a one-sided edit there fails in a
suite named for something else, and `R16` in `test-review-convergence.sh` keeps both
interpolations out of the convergence clause); the two config keys in `config.example.json`; and
the operator accounts in `docs/configuration.md`, `docs/review-chain.md`, `docs/architecture.md`
and `docs/tdd-manager-workflow.md`. `tests/structure/test-incremental-review-rounds.sh` pins all of
it, runs the step 3 probe against a project config (`I11c`, `I11d`), renders the delegate with
`aspectActivation` off and with `incrementalReviewRounds` off in every severity arm (`I30` to
`I32e`) and drives both unit files;
the manifest entry in `tests/profiles/promptfoo-local-only.v1.json` plus both unit files'
entries in `tests/profiles/unit-files.v1.json` move with it, because `run-all.sh` refuses to
execute at all when either file and the directory disagree.

**Generations and the claim prefix.** A `REVIEW BUDGET RESET` line, which
`/zensu:reset-review-limit` appends after a same-chain rearm, starts a new generation:
`roundScope` counts only claims after the last marker, so restarted round numbers no longer merge
old and new `R1-` claims. The `R<n>-` claim prefix itself is prescribed by the fix-round text
of EVERY severity arm in `hooks/post-review-tdd-delegate.sh` and by the `/zensu:tdd` fix-round
paragraph, independent of `hooks.reviewConvergence`, because this key must not silently depend on
that one. A round whose claims still lack the prefix answers `empty` — the safe direction.

**DELIBERATELY NOT NARROWED: `hooks/stop-chain-enforcer.sh`'s resume directive.** It fires when a
turn ended without continuing the chain. Its routing fields do not include `reviewRound`, so it
cannot tell a first review from a fix round's re-review, and it prescribes the full fan-out: one
`zensu:review-aspect` agent per perspective of the configured panel, read with
`zensu_review_panel` from the record's project root, plus the repo-local personas of step 10.2b,
over the step 10.2 change set instead of a round delta, with the judge while `hooks.reviewJudge`
is enabled. That is the fail-safe direction for the panel and the judge: a routed lean re-review
runs `correctness` alone without the judge, while a resumed review runs the whole panel unless, on
the first review, the Phase 6.10 step 3 import the directive also names answers `ok` or `degraded`:
the imported template review then stands in for the panel, and the judge always runs.
Activation would also be unsafe on this path: a model that takes `git diff --name-only HEAD` as
the change set misses untracked files, so a change whose new code lives only in untracked files
would classify as documentation-only. The directive therefore names the step 10.2 change set and
says what that command leaves out. It names the panel's perspectives itself, and T60 and T61 pin
that list against the exports of `aspect-activation-v1.js`.

**Version: `patch`.** Walked against §"Runtime Lineage" entry by entry: no context-record or
workflow-state schema field (both libs are read-only and persist nothing), no strict key set, no
hook added, removed or renamed and no matcher changed, no attestation change, and no
`permissionDecision` in either direction. The two new config keys are read through the
PERMISSIVE `zensu_hook_enabled`, which that section classifies explicitly as a `patch`. Resolving
them later, through the step 3 probe and the delegate's two assignments, is a `patch` on the same
walk: no key was added, both reads stay permissive, and only directive text moved.

**Known gaps, accepted and named:**

- **The delta is only as complete as the model's own claims.** A round that edits a file without
  logging its `R<n>-*` IMPL claim narrows the packet past that file. The Phase 6 step 5b Edit
  Landing Audit is what surfaces an unlogged edit and the convergence branch's full-suite re-run
  is the backstop, but neither is a review of that file BY the panel in that round.
- **The activation classifier is path-shaped.** A production file living under `tests/` reads as
  a test, and a `.md` file carrying executable examples reads as documentation. The direction is
  a narrowed panel, not a wrong verdict, and `bugs`/`conventions` still run on everything.
- **The saving is UNMEASURED end to end.** The per-agent figures above are measured; what an
  actual chain saves is arithmetic over them, not an observation. Take a real figure by comparing
  subagent transcript sizes across a chain with ≥2 fix rounds before trusting a percentage.
- **No Windows measurement.** `test-incremental-review-rounds.sh` is in `ciStructureTests`, so the
  weekly Windows Safety structure shard runs it, with no wall clock taken yet. Say "unmeasured",
  never "POSIX only". It has no `tests/profiles/ci-shard-weights.v1.json` entry either, so it is
  costed at `defaultSeconds` until a real ubuntu `--ci` figure exists.
- **No `/zensu:doctor` row.** A project whose activation helper stopped loading is visible only
  in the run log's `ASPECT ACTIVATION UNAVAILABLE` line, not in a diagnostic.
- **Two reads of `aspectActivation` per fix round.** The delegate resolves it when it renders the
  directive and step 3 resolves it again at the fan-out. Both read the Session Control record's
  project root, so only a config edited between the two reads can make that round's directive and
  probe disagree.
- **`hooks.selfReview: false` leaves the lean panel without a whole-change read after the first
  review while `hooks.incrementalReviewRounds` is on.** A lean re-review then reads only its
  round's delta and runs no judge, and the stage that would re-read the whole change is switched
  off, so a fix round's drift into a file it did not touch reaches no reviewer. A project that
  switches the self-review off and still wants that read sets `hooks.incrementalReviewRounds:
  false`, which gives the `correctness` re-review the whole diff but still no judge, or
  `hooks.reviewPanel: full`, which keeps the judge, and the full cumulative change set it reads,
  on every review.

**Port-relevant.** The core half is both libs, which are host-neutral, zero-dependency and carry
no environment reads of their own — every anchor arrives as an option or an argument. The host
half is FOUR obligations: the two config keys and the places that resolve them (the step 3 probe
and the delegate's two assignments), the two step directives in the skill, the fix-round directive
in the delegate hook, and the run-log claim FORMAT the delta is
derived from — a port whose rounds log their edits differently gets a helper that always answers
`empty` and therefore never narrows, which is the safe direction but buys nothing. `zensu-codex`,
`zensu-kiro` and `zensu-antigravity` were NOT included in this change.
