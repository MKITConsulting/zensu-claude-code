---
paths:
  - "hooks/lib/review-ledger-v1.js"
  - "hooks/lib/review-round-scope-v1.js"
  - "hooks/post-review-tdd-delegate.sh"
  - "agents/review-aspect.md"
  - "agents/review-judge.md"
  - "agents/code-reviewer.md"
  - "skills/tdd/SKILL.md"
  - "skills/self-review/SKILL.md"
  - "skills/reset-review-limit/SKILL.md"
  - "docs/review-severity.md"
  - "tests/structure/review-ledger-v1.test.js"
  - "tests/structure/test-review-convergence.sh"
  - "evals/config-gate/test-review-convergence-directive.sh"
  - "hooks/lib/zensu-log.sh"
  - "tests/structure/test-artifact-redaction.sh"
---

# Review Convergence (`review-ledger-v1.js` + `hooks.reviewConvergence`)

The `/zensu:tdd` auto-fix loop used to re-review with a full mandate until a round had no
routable finding. Measured over 471 real chains: a mean of 3.3 review rounds, 39% needing four
or more, and in rounds two and later 51% of the rounds were suggestions-only while 5% carried a
CRITICAL finding. The loop did not converge because nothing bounded what a LATE round may route.

**Routing narrows in the main thread, never in agent prompts.** The post-review hook never
reads the reviewer's findings (`tool_response`), and a repo persona may ignore any tag an agent
prompt asks for. The classification therefore runs where `Panel-FP` and `[Unverified — do not
fix]` already run: in the main thread, after the verification gate, as a third annotation with
the same mechanics — `[Deferred — do not fix]`, set to SUGGESTION, exempt from routing in every
severity mode. The aspects keep their full, independent mandate; only the judge receives the
ledger, because the judge is the arbiter that already rules false positives. It rules a re-raised
neutralized entry or an undone fix `Panel-FP: ledger <id>`, tags a fix that did not hold
`[NOT FIXED] <id>`, and names a panel finding that re-raises an open entry
`[STILL OPEN] <id> covers <panel-id>`, so that finding keeps its earlier id instead of being
ledgered twice. The `covers` form exists because the judge never repeats a panel finding; a
covers line is a meta-verdict like `Panel-FP:` and takes no id of its own. A re-raise the judge
rates CRITICAL is never ruled `Panel-FP: ledger <id>`: it is judged fresh on current source
evidence, because a recorded decision must not silence a blocker.

**What a re-review routes.** CRITICAL always. IMPORTANT only when the judge raised it, when the
judge tagged it `[NOT FIXED]` directly or through a `[NOT FIXED] <id> covers <panel-id>` line, or
when its cited lines are code this fix pass edited. The judge clause exists because the judge
alone reads the ledger, so its findings already account for what earlier rounds decided.
Everything else is deferred and ledgered right away: `parked` when it is IMPORTANT, `deferred`
otherwise.

**FAIL-OPEN IS THE CONTRACT.** The classification runs only for a re-review launched from the
post-review directive AND only when `review-round-scope-v1.js` and `review-ledger-v1.js` both
answer `status=ok`. Any other answer routes that review exactly as before and logs
`CONVERGENCE UNAVAILABLE — <reason>`. The Stop-hook resume directive is deliberately unchanged,
so a resumed review also routes as before. The routing read answers `degraded` on a malformed
`FINDING LEDGER` line (an anchor carrying a backtick, `$(` or `${` included), more than
`MAX_ENTRIES` entries, an unreadable or out-of-root log, an earlier-round registration of a new
id, and a registration that reuses a known id with another state or another anchor. The last two
are the shapes of a reset nobody marked with `REVIEW BUDGET RESET`. A `fixed` or `parked` line
for an earlier round is NOT a regression: both are transitions, `/zensu:self-review` writes the
first and a `[STILL OPEN]` re-raise the second. A repeated registration with the same state and
anchor is idempotent, because a deferred finding is ledgered at classification time. So is a
`deferred` repeat of a `parked` entry at the same anchor, which keeps it `parked`: classification
ledgers an IMPORTANT deferral `parked`, while the fix-round form can only write `deferred`. Every cause
is judged per generation: a problem before the last marker never degrades the generation after it.

**One verdict, two consumers, opposite safe directions.** For routing, `degraded` means "route as
before", which is safe. For the reports it would mean "no rows", which silently drops the very
findings convergence deferred. So `/zensu:self-review` and both `## Open` renderers read with
`--report`: it lists every parseable entry under `status=partial` plus a
`FINDINGS LEDGER PARTIAL — <reason>` row, and a log that cannot be read at all adds a
`FINDINGS LEDGER UNAVAILABLE — <reason>` row. Never point the routing gate at `--report`.
The report read also treats an unmarked reset (`id-reused`, `round-regression`) as a generation
boundary, and at every boundary, marked or not, it carries each open entry forward under a
`G<g>:R<k>-F<n>` id naming the generation it came from, so a reset never hides an open finding.
Only a `fixed` line may carry that qualifier; it closes the carried entry and routing ignores it.
Both `## Open` renderers add ledger rows only while `hooks.reviewConvergence` is on: with the key
off the hook's `LEDGER_OPEN_ROWS` fragment is empty and self-review skips the ledger.

**Deferred is not dropped.** The main thread ledgers every finding it defers right after
classifying, so a review that closes the loop still hands its deferred findings on. Every
`parked` entry, every deferred IMPORTANT or CRITICAL entry and every routed-but-unfixed entry is a
candidate of the single `/zensu:self-review` fix round, which also runs in Autopilot-bound chains;
the stage re-reads each candidate's cited region before it becomes a must-fix, because the ledger
is model-authored run-log content. A `parked` or routed-unfixed candidate the region still
supports is a must-fix whatever the stage's own must-fix bar says, and stays open only for a
named blocker: the one fix round already spent, or a fix that needs a product decision. That is
the whole point of `parked`: an IMPORTANT finding a late round deferred must get its fix, just
without another full fan-out. Every open entry is a `## Open` row. With `hooks.selfReview` off there is no later stage,
so the clause keeps every IMPORTANT finding routable and defers only SUGGESTION findings.
Unverified findings are never ledgered: their anchors are graded per round and must not be
carried forward.

**Ledger text never reaches a shell unquoted.** Every ledger line reaches the log through
`zensu-log.sh append --message-stdin`, fed by a heredoc whose delimiter is quoted, never through
`--message`, whose argument the shell has already expanded before the verb sees it. The verb
refuses `--message` and `--message-stdin` together and refuses an empty stdin. The reader rejects
a shell-active anchor, and the summary it hands back has its backticks and `$(`/`${` sequences
neutralized. A plain `$` stays valid because route files such as `posts.$slug.tsx` carry one. The
log's secret scan still runs on every line, but it is a backstop, not a guarantee: a refused
ledger line is rewritten without the value, never resent with the `zensu-secret-allow` marker or
`ZENSU_SECRET_SCAN=off`.

**The severity rubric has ONE source.** `docs/review-severity.md` holds the
`zensu:review-severity` block; `agents/review-aspect.md`, `agents/review-judge.md` and
`agents/code-reviewer.md` carry it byte-identically, and `/zensu:tdd` step 3 prepends it to
repo-persona prompts at run time. It has no second carrier, so an unreadable rubric file is
logged as `PERSONA CARRIER UNAVAILABLE — review-severity: <reason>`. It deliberately has no
"pre-existing defects are at most SUGGESTION" clause, because the aspect agent also serves
`/zensu:cover` and wargame audits of existing code. Its tie-break is asymmetric on purpose: between
IMPORTANT and SUGGESTION it picks SUGGESTION unless the evidence shows the higher impact, because
an inflated IMPORTANT is what keeps a late round open; between CRITICAL and IMPORTANT it picks
CRITICAL, because a deflated blocker is the one error convergence must never make.

**Coupled sites that move together:** `CONVERGENCE_CLAUSE` and `IMPORTANT_RULE` in
`hooks/post-review-tdd-delegate.sh` (defined once after `LOG_COMMAND`, because the clause names
`${LOG_HELPER_Q}` and the hook runs under `set -u`, and interpolated in BOTH
severity arms right before `${FIX_DONE_PHRASE}`, so the clause is read before the fix-done
instruction — the clause must contain none of the phrases `P3b`, `I17` and `S17` count per
line, and never the literal `review-round-scope-v1.js`, which is why it says "the round-scope
helper"); the one `CONVERGENCE_ON` read that gates both the clause and the `LEDGER_OPEN_ROWS`
fragment; the `R${NEXT}-{step_id}` claim prefix in BOTH arms, which `hooks.incrementalReviewRounds`
depends on and which is therefore NOT gated on this key; the widened case (A) and the
three-annotation exception list of the suggestions arm; the `--report` ledger rows in
`COMBINED_SUMMARY_DIRECTIVE` (through `LEDGER_OPEN_ROWS`, empty with the key off, so the
rendered `## Open` sentence then equals the pre-convergence one) and in
`skills/self-review/SKILL.md` §Open (legend sentence untouched); the `--message-stdin` arm of
`zensu-log.sh append`, which every ledger write in the clause and in self-review names, pinned
by R16e–R16g in `tests/structure/test-artifact-redaction.sh`; the four byte-identical copies of the
rubric tie-break; `skills/tdd/SKILL.md` steps 3, 4, 4b and the fix-round paragraph (in-line only, the
file is capped at 433 lines); the marker in `skills/reset-review-limit/SKILL.md` and `RESET` in
`review-round-scope-v1.js`; the judge's three ledger bullets and the code reviewer's annotation
paragraph; the config key in `config.example.json`; and the operator accounts in
`docs/configuration.md`, `docs/review-chain.md`, `docs/architecture.md`,
`docs/tdd-manager-workflow.md` and the intro of `docs/review-severity.md`.
`tests/structure/test-review-convergence.sh` pins each of them and drives the unit file;
`evals/config-gate/test-review-convergence-directive.sh` renders both arms at round 1 and 2 with
the key on, both arms with it off, the `hooks.selfReview`-off variant, and the combined summary
with the key off, whose `## Open` sentence must equal the pre-convergence one.

**Version: `patch`.** No workflow-state or context-record field, no strict key set (the judge's
`findings_ledger` is optional, so no packet is rejected for lacking it), no hook added, removed
or renamed, no matcher change, and the key is read through the permissive `zensu_hook_enabled`.
`--message-stdin` is an additive `append` flag, and the ledger grammar ships for the first time
together with `parked` and the `G<g>:` qualifier, so no released reader predates either.

**Known gaps, accepted and named:**

- **The regression judgment is the main thread's reading of its own edits**, not a mechanical
  hunk diff. A misjudged IMPORTANT finding is deferred to `/zensu:self-review`, not dropped.
- **Self-review needs the chain's run-log path.** It reads the ledger of the log the chain wrote
  in this session and never resolves one by recency; when the session no longer knows the path,
  it skips the ledger and the deferred findings survive only in the buffered report blocks.
- **Self-review reads the key against `$TOP`, the hook against the Session Control record
  root.** Both resolve the same project `.zensu/config.json` for a session started at the
  repository root; a session started in a subdirectory that carries its own config can still
  see them disagree.
- **The reset marker depends on a known log path.** `/zensu:reset-review-limit` never searches
  for a log; without the path it skips the marker. An id reuse or a round regression then turns
  the routing read `degraded` and makes the report read open a new generation, but a reset stays
  undetected when every id the new reviews reuse repeats its earlier state and anchor and no new
  id carries a round below one already seen.
- **Published run logs publish the ledger.** Each line carries a finding's severity, location and
  paraphrase; a security finding's paraphrase names only its class, but the location and class of
  an open one are still disclosed wherever the run log is published.
- **The saving is unmeasured end to end.** Re-measure with the run-log heuristic that produced
  the figures above; the new `FINDING LEDGER` lines make that measurement structural.

**Port-relevant.** The lib is host-neutral and zero-dependency. The host half is the clause,
the key and its reader, the skill directives, and the `FINDING LEDGER` line format.
`zensu-codex`, `zensu-kiro` and `zensu-antigravity` were NOT included in this change.
