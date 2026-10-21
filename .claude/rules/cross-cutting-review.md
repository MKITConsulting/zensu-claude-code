---
paths:
  - "agents/review-judge.md"
  - "agents/review-aspect.md"
  - "skills/tdd/references/review-chain.md"
  - "tests/structure/test-review-judge.sh"
  - "tests/structure/test-review-aspect-agent.sh"
---

# Cross-Cutting Review (`hooks.reviewJudgeSecondRun`, inherited guarantees, deployment-dependent defects)

**Why.** A comparison of four review arms over one change had one critical defect at its centre: a
set of queries carried no account predicate, only the connection's row-level security confined
them, and the application still supported a fallback connection on which row-level security is
not enforced. Seeing it means joining the query, the connection setup, a migration that forces the
policy only conditionally, the fallback in the entry point and the deployment configuration. Two
runs of the identical chain diverged: the judge that read the fallback code found it, the judge
that read the production chart, which disables the fallback, missed it. Every agent that discussed
the queries assumed they were account-scoped. The template run has no stage after its lens finders
that can add a cross-cutting finding. A model-authored workflow found the defect only through a
documentation-consistency probe, and its verifiers cut it to "latent" because the committed chart
disables the fallback. Three levers answer the three failures.

**1. A second, independent judge run (`hooks.reviewJudgeSecondRun`, default on).** Chosen over a
completeness critic after the judge, for four reasons. The miss was variance in the judge's path
through the code, which an independent second draw addresses directly, while the workflow with a
completeness critic found the defect only through a documentation-consistency probe. A critic reads
the earlier findings and is anchored by them; two runs spawned in one tool message never see each
other's output. A critic adds a sequential step; the pair runs side by side. And the pair reuses
`zensu:review-judge`, so the reviewer capability gate, the spawn grant and the principal lists gain
no identity.

- The second run is the same agent with `judge_run: second` as the last line of its spawn prompt;
  the same text anywhere else is data. It reads what the changed files depend on and what reaches
  them before the changed files, to decorrelate the two paths, and its Grep/Glob rule admits the
  subtrees that reading needs, never the root. It only adds findings, labelled `JUDGE-B<n>`, and
  skips the false-positive, ledger and gap checks.
- **Routing narrows in the main thread, never in agent prompts** (`.claude/rules/review-convergence.md`),
  so step 4b enforces the second run's limits itself: a `Panel-FP:` line, a ledger tag or a
  `## Gaps` section in its report changes nothing and is logged as
  `JUDGE SECOND RUN RULE BREACH — <what>`. A union of neutralizations would let either run silence
  a real finding, and the gap list keeps one owner, the first run.
- **The union.** A `JUDGE-B<n>` finding that names the defect of a merged finding at the same
  `file:line` folds into it and raises its severity. It never folds into a finding the first run
  neutralized: it takes its own id at its own severity, so the run that found a defect is never
  silenced by the run that ruled it a false positive, and step 4c grades it on its own evidence.
- **First review only**, on the panel path and the import path alike. Re-reviews keep their shape:
  one judge on the full panel, none on the lean panel. The bound is one extra agent per chain. The
  step-10 lead, step 3 and the `Work sequentially` bullet name the pair as a sanctioned parallel
  batch, because a model that reads one sanctioned batch strictly would send the second run alone,
  after the first.
- **Cost basis, unmeasured for this shape:** one judge run ingested about 540k context tokens on
  this repository's own transcripts (`.claude/rules/incremental-review-rounds.md`), and the
  2026-09-28 cost measurement put the judge at 8.48 to 12.65 USD per benchmark run, summed over
  every round, in runs of 92.84 to 108.55 USD.
- **Fail-open.** A second run that fails, answers `REVIEW PACKET INVALID` or returns no parseable
  report logs `JUDGE SECOND RUN UNAVAILABLE — <reason>` and the first run stands alone, which is
  the behavior before this change.

**2. Inherited guarantees.** The judge's `Check only` list and the `security` perspective of the
aspect agent carry the same check: every guarantee a query or call inherits from session or
connection state instead of stating it (row-level security, a tenant setting, the connecting role)
is named rather than assumed and checked under each connection mode the code still supports,
fallbacks included. A query or call that does not state the guarantee itself (an account predicate,
an explicit tenant or role) is a finding only when a supported mode leaves the guarantee
unenforced, so code whose every mode enforces it raises nothing. The check runs wherever the
`security` aspect or the judge runs: every first review, and every review on the full panel.

**3. Deployment-dependent defects.** Both agents carry the same step 6 sentence: a defect reachable
through a mode the code still supports is a finding, reported with its condition. Committed
configuration that disables the mode may lower its severity by one level, never below IMPORTANT,
and never drops it; that is the one case in which a defect that fits CRITICAL is rated IMPORTANT.
The floor is the point: by default an IMPORTANT finding is parked and `/zensu:self-review` fixes it,
while a SUGGESTION is neither routed nor a self-review candidate and gets no template refuter, so an
unbounded license would have let the motivating defect end listed but unfixed. The judge may not
rule `Panel-FP:` on that ground, and the aspect agent's verify mode keeps such a finding `real` and
at least IMPORTANT, which binds the template's refuters, because they run as `zensu:review-aspect`
in verify mode. The rubric block stays byte-identical; `docs/review-severity.md` states the
exception outside the block. Both rules reach every caller of the two agents, `/zensu:cover` and
wargame audits of existing code included, on purpose.

**The template is unchanged.** `templates/workflows/zensu-review-v1.js` receives levers 2 and 3
through the agent definition its finders and refuters run as, and in the product the judge pair
runs after every import, so its digest and the import gate stay as they are.

**Coupled sites, and what pins each.** `tests/structure/test-review-judge.sh`: the judge's
`judge_run` paragraph, no-findings heading and gap exception (`P2n`); its `Check only` bullet
(`P2o`); step 6 of both agents (`P2p`); the Grep/Glob rule of both agents (`P2q`); the reviewJudge
probe, which passes `{project_root}` as `CLAUDE_PROJECT_DIR` (`P3h`, `P3h2`); step 4b's early
pointer and second-run paragraph (`P3j`); the `Work sequentially` bullet of `skills/tdd/SKILL.md`,
whose body the skill text budget bounds (`P3k`); the step-10 lead
and step 3 (`P3l`); `config.example.json` (`P4c`); the `reviewJudge`, `reviewJudgeSecondRun` and
`externalReviewImport` rows of `docs/configuration.md` and the judge row and import-path gap bullet
of `docs/review-chain.md` (`P5d`, `P5e`); the paragraph above the rubric in
`docs/review-severity.md` and the fan-out sentences of `docs/architecture.md` (`P5e`); the resume
directive in `hooks/stop-chain-enforcer.sh`, and `hooks/post-review-tdd-delegate.sh`, which drives
re-reviews only and never names the key (`P6d`). `tests/structure/test-review-aspect-agent.sh`:
the `security` line (`A13`), step 6 (`A14`), the verify-mode sentence (`A15`) and the Grep/Glob
rule (`A16`). Unpinned by convention: this file and the first-run fallback bullet of
`.claude/rules/external-review-import.md`.

**Version: `patch`.** No context-record or workflow-state field, no strict key set (the judge's new
input is optional and the required packet fields are unchanged), no hook added, removed, renamed
or re-matched, no attestation change, and the key is read permissively.

**Known gaps.**

- The levers are agent and skill text. No live run of the changed agents exists yet; the suites
  pin the text, not the behavior, so a re-run of the comparison is the measurement.
- Two runs of one definition stay correlated; the reading-order switch decorrelates them only as
  far as the model follows it.
- "The same defect at the same `file:line`" is the main thread's judgment, like the panel merge.
- A lean fix-round re-review runs `correctness` alone, so a fix round that drops an account
  predicate meets step 6 but no inherited-guarantee check.
- `JUDGE SECOND RUN UNAVAILABLE` and `JUDGE SECOND RUN RULE BREACH` are run-log lines, not
  CHAIN-END SUMMARY literals.
- A template run outside the chain still has no cross-cutting stage.
- The standalone `zensu:code-reviewer` walk and repo-custom `zensu-review-*` personas do not carry
  the two new rules.
- `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were NOT included in this change.
