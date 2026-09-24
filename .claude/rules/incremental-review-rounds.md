---
paths:
  - "hooks/lib/review-round-scope-v1.js"
  - "hooks/lib/aspect-activation-v1.js"
  - "tests/structure/test-incremental-review-rounds.sh"
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
exactly the case a "just tests" heuristic would miss. Empty or unclassifiable input spawns all
five, so a narrowed panel is always a proven reduction rather than a guess, and the predicates
therefore ask "is EVERY file X", never "is SOME file X": one production file restores the panel.

**Every reduction DISCLOSES.** A skipped aspect logs `ASPECT SKIPPED — <aspect> (<reason>)` and a
failing helper logs `ASPECT ACTIVATION UNAVAILABLE — <reason>` and spawns all five. A panel that
shrank silently is indistinguishable from one that was never spawned, which is the failure this
repository treats as worse than the cost it removes.

**Coupled sites that move together:** the two libs and their exports; `skills/tdd/SKILL.md`
step 3 (activation) and step 10 (delta scoping) — both edited INSIDE existing long lines because
`P3e` in `tests/structure/test-review-personas.sh` caps that file at **433 lines** and it is AT
the cap; BOTH arms of `hooks/post-review-tdd-delegate.sh`, which are verbatim-identical by
contract (`P3b` in `test-finding-verification.sh` counts `step 4c Finding Verification Gate`
exactly twice, so a one-sided edit there fails in a suite named for something else); the two
config keys in `config.example.json`; and the operator accounts in `docs/configuration.md`,
`docs/review-chain.md`, `docs/architecture.md` and `docs/tdd-manager-workflow.md`.
`tests/structure/test-incremental-review-rounds.sh` pins all of it and drives both unit files;
the manifest entry in `tests/profiles/promptfoo-local-only.v1.json` plus the counts in
`tests/SUITE-OVERVIEW.md` move with it, because `run-all.sh` refuses to execute at all when the
manifest and the directory disagree.

**DELIBERATELY NOT CHANGED: `hooks/stop-chain-enforcer.sh`'s resume directive.** It fires when a
turn ended without continuing the chain, where the round number is not established, so it keeps
prescribing the full fan-out. That is the fail-safe direction and it costs no test churn.

**Version: `patch`.** Walked against §"Runtime Lineage" entry by entry: no context-record or
workflow-state schema field (both libs are read-only and persist nothing), no strict key set, no
hook added, removed or renamed and no matcher changed, no attestation change, and no
`permissionDecision` in either direction. The two new config keys are read through the
PERMISSIVE `zensu_hook_enabled`, which that section classifies explicitly as a `patch`.

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

**Port-relevant.** The core half is both libs, which are host-neutral, zero-dependency and carry
no environment reads of their own — every anchor arrives as an option or an argument. The host
half is FOUR obligations: the two config keys and their reader, the two step directives in the
skill, the fix-round directive in the delegate hook, and the run-log claim FORMAT the delta is
derived from — a port whose rounds log their edits differently gets a helper that always answers
`empty` and therefore never narrows, which is the safe direction but buys nothing. `zensu-codex`,
`zensu-kiro` and `zensu-antigravity` were NOT included in this change.
