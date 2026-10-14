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

- The second run is the same agent with the `judge_run: second` input. It reads what the changed
  files depend on and what reaches them before the changed files, to decorrelate the two paths,
  and it only adds findings, labelled `JUDGE-B<n>`. It never rules `Panel-FP:`, tags a ledger entry
  or writes `## Gaps`: a union of neutralizations would let either run silence a real finding, and
  the gap list keeps one owner. The main thread unions the findings after the first run's deltas,
  keeping a same-defect, same-`file:line` duplicate once at the higher severity.
- **First review only**, on the panel path and the import path alike. Re-reviews keep their shape:
  one judge on the full panel, none on the lean panel. The bound is one extra agent per chain.
- **Cost basis, unmeasured for this shape:** one judge run ingested about 540k context tokens on
  this repository's own transcripts (`.claude/rules/incremental-review-rounds.md`), and the
  2026-09-28 cost measurement put the judge at 8.48 to 12.65 USD per benchmark run, summed over
  every round, in runs of 92.84 to 108.55 USD.
- **Fail-open.** A second run that fails or answers `REVIEW PACKET INVALID` logs
  `JUDGE SECOND RUN UNAVAILABLE — <reason>` and the first run stands alone, which is the behavior
  before this change. The key is read with `zensu_hook_enabled`, so `false` restores one run.

**2. Inherited guarantees.** The judge's `Check only` list and the `security` perspective of the
aspect agent carry the same check: every guarantee a query or call inherits from session or
connection state instead of stating it (row-level security, a tenant setting, the connecting
role) gets named rather than assumed, checked under each connection mode the code still supports,
fallbacks included, and checked for its own predicate. `security` runs in both panels and in every
template run that names it, and the judge reads every change.

**3. Deployment-dependent defects.** Both agents carry the same step 6 sentence: a defect reachable
through a mode the code still supports is a finding, reported with its condition; committed
configuration that disables the mode may lower its severity but never drops it. The judge may not
rule `Panel-FP:` on that ground, and the aspect agent's verify mode keeps such a finding `real`,
which is what binds the template's refuters, because they run as `zensu:review-aspect` in verify
mode. The severity rubric block stays byte-identical; `docs/review-severity.md` explains the rule
outside the block.

**The template is unchanged.** `templates/workflows/zensu-review-v1.js` receives levers 2 and 3
through the agent definition its finders and refuters run as, and in the product the judge pair
runs after every import, so its digest and the import gate stay as they are.

**Coupled sites.** The `judge_run` input, the `Check only` bullet, step 6 and the second-run
heading and gap sentences of `agents/review-judge.md`; the `security` line, step 6 and the verify
mode sentence of `agents/review-aspect.md`; step 4b of `skills/tdd/references/review-chain.md`
(the early pointer and the closing paragraph) and the sanctioned parallel batch of the `Work
sequentially` bullet in `skills/tdd/SKILL.md`, whose body the skill text budget bounds; the
resume directive in `hooks/stop-chain-enforcer.sh`, while `hooks/post-review-tdd-delegate.sh`
never names the key because it drives re-reviews only; `config.example.json`; the
`reviewJudge` and `reviewJudgeSecondRun` rows of `docs/configuration.md`; the judge row and the
import-path gap bullet of `docs/review-chain.md`; the fan-out sentence of `docs/architecture.md`;
and the paragraph above the rubric in `docs/review-severity.md`. `P2n` to `P2p`, `P3j`, `P3k`,
`P4c`, `P5d` and `P6d` in `tests/structure/test-review-judge.sh` and `A13` to `A15` in
`tests/structure/test-review-aspect-agent.sh` pin them.

**Version: `patch`.** No context-record or workflow-state field, no strict key set (the judge's new
input is optional and the required packet fields are unchanged), no hook added, removed, renamed
or re-matched, no attestation change, and the key is read permissively.

**Known gaps.**

- The levers are agent and skill text. No live run of the changed agents exists yet; the suites
  pin the text, not the behavior, so a re-run of the comparison is the measurement.
- Two runs of one definition stay correlated; the reading-order switch decorrelates them only as
  far as the model follows it.
- "The same defect at the same `file:line`" is the main thread's judgment, like the panel merge.
- `JUDGE SECOND RUN UNAVAILABLE` is a run-log line, not a CHAIN-END SUMMARY literal.
- A template run outside the chain still has no cross-cutting stage.
- The standalone `zensu:code-reviewer` walk does not carry the two new checks.
- `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were NOT included in this change.
