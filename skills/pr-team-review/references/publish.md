# Phase D: synthesis and forge publish

Read this when `_debate.json` is written, or after Phase A.1 when a delegated retry loaded
an existing payload snapshot (`REUSE_DURABLE_PAYLOAD=true`).

Unless `REUSE_DURABLE_PAYLOAD=true`, write `$WORKDIR/_synthesis.json` as the review payload
(consumed by the driver's `--post-review` — one identical shape for both forges):

```json
{
  "commit_id": "<head-sha>",
  "event": "<verdict>",
  "body": "<markdown overall body>",
  "comments": [
    {"path": "src/...", "line": 42, "side": "RIGHT", "body": "<markdown>"}
  ]
}
```

The body is written for a reader who stops early: the verdict comes first, every finding
carries a stable ID and a link to its code, and everything secondary is collapsed. Build it
from `_debate.json` after the Finding Verification Gate and the inline cap have decided which
findings exist and which of them get an inline comment. The exact rules for IDs, permalinks,
the verdict banner, collapsing, and length are in `rules/workflow.md` Phase D.

Overall body structure (Markdown):

```
## Zensu team review

> [!caution]
> **Changes requested — <p1> blocking issue(s).**
> <2-3 sentences: what the change gets right, which F-IDs block the merge and why, and what the suggestions cluster around.>

**🔴 <p1> blocking** · **🟡 <p2> should fix** · **🔵 <p3> nits** — <k> inline comments · <r> reviewers · head [`<sha7>`](<commit-url>)

### 🔴 Blocking

**F1 · <one-line claim>** — [`<file>:<line>`](<permalink>)
<2-3 sentences: the problem, its consequence, and the fix.>
<sub><persona-id> · also <persona-ids> · <verification note></sub>

### 🟡 Should fix

**<Theme>**
- **F2** <one-line claim> — [`<file>:<line>`](<permalink>)
- **F3** <one-line claim> — [`<file>:<line>`](<permalink>)

### Naming decision   <!-- only if --conversation or DDD-strategic raised it -->
<consensus>

### Test Coverage   <!-- MANDATORY — always render, from consensus.coverage. Never omit. -->
_Source: <coverage_source> — <AI static mapping (approximate) | from report:<path> | tool-run>._ <n> changed production files — <c> covered, <p> partial, <u> uncovered.

| Covered | Partial | Uncovered | Changed prod files |
|--:|--:|--:|--:|
| <c> | <p> | <u> | <n> |

**Uncovered files** (no test exercises them):
- `path/to/File.ext` — <reason> (<P1|P2|P3>)

<!-- if none: "None — every changed production file is exercised by a test." · if no prod code: drop the table and the lists, render "N/A — no production code changed in this PR." -->

<details>
<summary><b>Uncovered paths</b> in <p> partially covered files</summary>

- `path/to/File.ext` → `functionName`, `<branch/endpoint>`

</details>

<!-- if none: render "**Uncovered paths:** none." without a details block -->

### Questions for the author
- <at most 5; omit the section when there are none>

<details>
<summary><b>🔵 <p3> nits</b> — <the topics in a few words></summary>

- **F<n> <Topic>** — <nit> ([`<file>:<line>`](<permalink>))

</details>

<details>
<summary><b><x> findings not published</b> — they did not verify against the checkout</summary>

- **[Unverified — do not fix]** [`<file>:<line>`](<permalink>) (<persona-id>, <P1|P2>): "<claim>". <what the checkout shows instead>

</details>

<details>
<summary><b>What is solid</b></summary>

- <3-7 bullets from the reviewers' positives>

</details>

<details>
<summary><b>How this review was produced</b></summary>

- **Team:** <r> reviewers — holistic core <ids>; cast for this diff <ids>; repo-custom <ids>.
- **Verdict hints:** <hint> (<persona-ids>) · <hint> (<persona-ids>).
- **Challenge round:** <what survived, what was killed, what was added>.
- **Finding verification:** <verified / unsupported / phantom counts, `off`, or `DEGRADED — <reason>`>.
- **Review state:** <posted as a comment / as request changes / as an approval> — <what that does to the merge>.

</details>

<sub>Zensu team review · work the findings with <code>/zensu:pr-fix-findings</code></sub>
```

Omit an empty severity section (the metric line already reports the zero), the naming
section when nobody raised naming, and each collapsed block that would be empty. The
banner is not always `caution`: `rules/workflow.md` Phase D maps the findings to
`caution`, `warning`, or `tip`, and adds a second `important` block for a degraded run.

**Body-only findings.** A P1 or P2 finding without an inline comment — its anchor validated
as `none`, it lost its slot to `--max-inline`, or it arrived through `overall_notes` for an
untouched file — keeps its ID and its line in the body. The line ends with
`· no inline comment` and is followed by a collapsed `<details>` block that carries the
explanation the inline comment would have carried. A P1 entry already carries its
explanation, so it needs no extra block.

Inline comment structure (Markdown), one per `comments[]` entry:

````
🔴 **Blocking** · **F1** · <category>

**<one-line claim>**

<2-3 sentences: the problem and its consequence. Link every other location as [`<file>:<line>`](<permalink>).>

**Suggested fix:** <one sentence, or a short numbered list when the fix has several steps>

```suggestion
<the exact replacement for the anchored line(s)>
```

<details>
<summary>Evidence</summary>

- [`<file>:<line>`](<permalink>) — <what that line shows>

</details>

<sub><persona-id> · also <persona-ids> · <verification note></sub>
<!-- zensu-finding:v1 id=F1 sev=P1 cat=<category-slug> head=<sha7> -->
````

A P2 comment opens with `🟡 **Should fix** · **F<n>** · <category>`; P3 findings never
become inline comments. The `suggestion` block is optional and is emitted only under the
conditions in `rules/github-publish.md` § Suggested changes (on GitLab its fence reads
`suggestion:-0+0`, `rules/gitlab-publish.md`). The `Evidence` block is optional too. The
closing marker is invisible metadata for tools: the same ID as the body, the finding's
severity, its category as a slug of lower-case letters, digits, and single hyphens
(`docs-drift`), and the short head SHA. It never spells `zensu-review:v1`, the driver's
reconcile marker, which the driver rejects inside a payload. The verification note reads
`verified against <code><sha7></code>` only for a finding the Finding Verification Gate
graded `VERIFIED`; with the gate off it reads `not verified (finding verification off)`.

**Mandatory `### Test Coverage` section.** Render it on EVERY run from `consensus.coverage` as a one-line source disclosure + a compact four-column status table (Covered / Partial / Uncovered / Changed prod files) followed by the uncovered-files bullet list (always visible) and the uncovered-paths list (collapsed, its summary names the count) — exact format in `rules/workflow.md` Phase D. A fully-covered PR shows all-zero uncovered counts and "None" under both lists; a docs-only PR drops the table and shows "N/A — no production code changed". Numbers are the AI's static diff-vs-test mapping by default (honest approximation); `--run-coverage` or an ingested report makes them measured. Never drop the section, even when the verdict is APPROVE. When `--coverage-gate` is set and uncovered production files exist, the verdict banner must reflect `REQUEST_CHANGES` and cite the uncovered files. The coverage-audit persona's own inline findings (uncovered high-risk files/paths) flow into the inline comments like any other persona's, subject to `--max-inline`.

**HARD RULE — NO MARKDOWN TABLES, one carve-out.** In the overall body and inline comments, GitHub's PR view squeezes wide tables into unreadable narrow columns (text wraps character-by-character). Use:
- a bold `F<n> · <claim>` lead-in plus 2-3 sentences for each blocking finding
- one-line bullets with a bold `F<n>` prefix, grouped under bold theme labels, for suggestions and nits
- short bullets for questions, strengths, and the method notes
- plain prose for everything else

The **sole exception** is the `### Test Coverage` status table above: four short all-numeric columns survive the squeeze because every cell is a small integer. Nothing else — no findings table, no file-path table. Inside inline comments the exception does **not** apply: no tables at all, code fences / bullet lists / bold prefixes only.

Inline findings: max `--max-inline` (default 25), sorted by path then line, P1 first. See the detected forge's publish rules — `rules/github-publish.md` (atomic `gh api` review, `line`/`side` rules per file `changeType` ADDED/MODIFIED/RENAMED, suggested changes) or `rules/gitlab-publish.md` (summary note + inline discussions, `position` object, marker idempotency, alert and suggestion spelling).

Validate every inline anchor before it enters `comments[]`, per `rules/github-publish.md` § Pre-Publish Anchor Validation (`hooks/lib/valid-diff-lines.js`: `valid` keeps the anchor, `remap` moves it with a body note and drops any suggestion block, `none` turns the finding into a body-only finding). Only validated anchors go into the payload the driver's `--post-review` publishes; on GitLab the driver additionally folds any line-less finding into a positionless thread (`rules/gitlab-publish.md`).

After a newly synthesized payload is complete, bind it durably before the first `--reconcile-review` call. The store is create-once: an identical retry returns the existing
private snapshot, while different bytes, a stale operation/head, corruption, a symlink, or
a hardlink fail closed and must persist `BLOCK(review-payload-unsafe)`. Never reconcile from
the temporary synthesis path in delegated mode.

```bash
REVIEW_PAYLOAD="$WORKDIR/_synthesis.json"
if [ "$DELEGATED" = true ] && [ "$REUSE_DURABLE_PAYLOAD" != true ]; then
  REVIEW_PAYLOAD="$(autopilot_store_team_review_payload \
    "$RUN_ID" "$OPERATION_KEY" "$BOUND_HEAD" "$REVIEW_PAYLOAD" "$BOUND_PROVIDER" "$REPO")" || {
      # Persist BLOCK(review-payload-unsafe), report it, and stop without asking.
      exit 1
    }
fi
```

In standalone mode, show the user the final body preview + inline count as a progress
record and publish at once. Do not ask for publication approval: invoking the skill on a
PR is the user's authorization to post the synthesized review. In delegated mode, record
the count as a progress update and continue without a preview question or approval gate
because the durable delegated capability already authorizes this exact operation/head-bound
payload.

Submit through the VCS driver — GitHub posts one atomic review; GitLab degrades to a summary
note + N inline discussions (`rules/gitlab-publish.md`), each marker-tagged so a re-run after
a partial failure skips already-posted threads, the verdict carried in the summary body, and
**never** auto-approving:

```bash
# Run the driver from $REPO so gh/glab resolve the correct host (esp. a self-hosted GitLab
# instance) from that repo's remote — the same reason the A.1 scout is wrapped in
# (cd "$REPO" && ...). GitLab inline positions need the MR diff refs; GitHub ignores them.
DR=""
[ "$PROVIDER" = gitlab ] && [ "$DELEGATED" != true ] && DR="$(cd "$REPO" && bash "$VCS" --diff-refs --provider "$PROVIDER" --repo-id "$REPOID" <n>)"

if [ "$DELEGATED" = true ]; then
  # Re-scout first and require OPEN + exact $BOUND_HEAD. The delegated path must never substitute the freshly fetched SHA for the capability-bound head when reconciling.
  REVIEW_RESULT="$(cd "$REPO" && bash "$VCS" --reconcile-review --provider "$PROVIDER" --repo-id "$REPOID" \
    --expected-head "$BOUND_HEAD" ${DR:+--diff-refs-json "$DR"} \
    <n> "$REVIEW_PAYLOAD" "$OPERATION_KEY")"
else
  URL="$(cd "$REPO" && bash "$VCS" --post-review --provider "$PROVIDER" --repo-id "$REPOID" \
    ${DR:+--diff-refs-json "$DR"} <n> "$WORKDIR/_synthesis.json")"
fi
```

For a delegated GitLab call, omit `--diff-refs-json`: the reconcile driver performs a
bounded readiness loop because a newly opened MR can temporarily return empty `diff_refs`.
Every attempt rechecks `OPEN` plus the immutable bound head; no review part is written until
complete lowercase base/start/head refs are available. Exhaustion blocks the run cleanly.

The delegated result must be one JSON object with exactly
`{status,marker,headSha,partCount,postedCount,url,provider}`. Require `provider == PROVIDER`
(`github` or `gitlab`) and accept only status
`present|posted|reconciled`; require `headSha == BOUND_HEAD`, `partCount >= 1`, and
`0 <= postedCount <= partCount`. `present` requires `postedCount == 0`; `posted` requires `postedCount == partCount`; and `reconciled` requires `0 < postedCount < partCount`.
GitHub requires `partCount == 1` and rejects `reconciled`. GitLab requires `partCount == 1 + comments.length`, using the exact `REVIEW_PAYLOAD` comments array (the
durable snapshot in delegated mode).
Validate the marker as
`<!-- zensu-review:v1:<sha256(operationKey)>:<64-hex-payload-digest>:<headSha>:<N>:part=1/<N> -->`,
where both head values equal the durable bound head and both `N` values equal
`partCount`. Reject missing/extra fields, malformed markers, conflicting identities,
impossible counts, a mismatched provider, or an empty `url`. Return this exact object to Autopilot; it is the only
receipt allowed to drive `TEAM_REVIEW_PUBLISHED`.

A non-zero reconcile call, malformed output, or rejected receipt blocks the delegated run.
Do not invoke `--post-review`, a direct forge POST, or a per-comment fallback. A retry first
loads the existing durable snapshot, skips reviewer/debate/synthesis work, and repeats the
complete reconcile operation with the same operation key, bound head, and byte-identical
payload after another fresh OPEN/head guard.

The durable Autopilot owner serializes this operation: never start two reconcile calls for
the same operation concurrently. The marker protocol guarantees sequential crash/retry
reconciliation; it does not claim distributed exactly-once behavior for independent
simultaneous writers that bypass the owner contract.

- **GitHub** — `URL` is the review `html_url` from the POST response; return it to the user.
  Verify with `gh api repos/<owner>/<repo>/pulls/<n>/reviews/<id>/comments | jq length`
  (should equal the inline count).
- **GitLab** — discussions post in a loop (not transactional). Report the MR URL from the
  scout metadata + the number of posted threads; a re-run reconciles via the markers.
