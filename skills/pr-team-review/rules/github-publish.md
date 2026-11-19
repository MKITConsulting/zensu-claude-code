# GitHub Publish — Reviews API Reference

How to post one consolidated review with bundled inline comments through the driver
(`$VCS`). Every gh call here runs inside a driver verb, run from `$REPO`, which pins the pull
request's own host as the other GitHub verbs do; never call gh directly for a read or a write
of the pull request.

## Endpoint

```
POST /repos/{owner}/{repo}/pulls/{pull_number}/reviews
```

Docs: <https://docs.github.com/en/rest/pulls/reviews#create-a-review-for-a-pull-request>

## Payload Shape

```json
{
  "commit_id": "<40-char head SHA>",
  "event": "COMMENT" | "REQUEST_CHANGES" | "APPROVE",
  "body": "<markdown overall body>",
  "comments": [
    {
      "path": "src/main/java/.../X.java",
      "line": 42,
      "side": "RIGHT",
      "body": "<markdown inline comment>"
    },
    {
      "path": "src/main/java/.../Y.sql",
      "start_line": 10,
      "line": 14,
      "start_side": "RIGHT",
      "side": "RIGHT",
      "body": "<multi-line range comment>"
    }
  ]
}
```

`commit_id` is a **review-level** field. It belongs at the top level of this
payload and nowhere else: an entry of `comments[]` accepts exactly `path`,
`body`, `side`, `line`, optionally `start_line` + `start_side`, and the legacy
`position` — nothing more. A per-comment `commit_id` fails the WHOLE POST with a
422 that names the GraphQL type behind the endpoint:

```text
{"message":"Unprocessable Entity","errors":["Variable $threads of type [DraftPullRequestReviewThread] was provided invalid value for 0.commitId (Field is not defined on DraftPullRequestReviewThread)"],"status":"422"}
```

The per-comment fallback near the end of this file DOES set `commit_id` on its
comment object, and is correct there: it posts to
`POST /repos/{owner}/{repo}/pulls/{n}/comments`, a different endpoint that
creates one standalone review comment and therefore carries its own head SHA.
Never copy that shape back into the reviews payload above.

## Pre-Publish Anchor Validation (MANDATORY)

GitHub 422-rejects any inline comment whose `(path, line, side)` anchor is not a
commentable line of the PR diff — and the whole review POST fails with it.
Validate EVERY inline anchor BEFORE writing the payload, using
`hooks/lib/valid-diff-lines.js` (diff on stdin; path, line, and the comment's
`side` as argv, side defaulting to `RIGHT`; prints `valid`, `remap <n>`, or
`none`):

```bash
(cd "$REPO" && bash "$VCS" --pr-diff --provider github --repo-id "$REPOID" <n>) > "$WORKDIR/_pr.diff"
[ -s "$WORKDIR/_pr.diff" ] || (cd "$REPO" && bash "$VCS" --pr-diff --provider github --repo-id "$REPOID" <n>) > "$WORKDIR/_pr.diff"
node "<absolute-plugin-root>/hooks/lib/valid-diff-lines.js" '<path>' '<line>' '<side>' < "$WORKDIR/_pr.diff"
```

`--pr-diff` prints the pull request's unified diff, or nothing at all: when gh fails, the verb
discards any partial output, prints gh's message on stderr and exits non-zero, so `_pr.diff` is
empty rather than truncated.

This validation is GitHub's. On GitLab the driver's `--post-review` runs its own anchor
preflight over every page of the merge request's diffs and turns an anchor it cannot place into
a positionless discussion with the path in its body (`rules/gitlab-publish.md`), so the skill
runs no `--pr-diff` read there, and a suggestion takes the GitLab form of the anchor condition
in § Suggested changes.

Replace `<absolute-plugin-root>` with the concrete absolute `ROOT` established
by the parent `SKILL.md`; this supporting file is loaded through `Read` and does
not receive native placeholder substitution.

**Quoting is load-bearing:** `<path>` comes from the PR diff — an
attacker-influenced value that may contain `$( )`, backticks, `;`, or spaces,
and double quotes do NOT neutralize `$( )`. Substitute the literals inside the
single quotes exactly as shown; if the substituted path contains a `'`,
escape it as `'\''` — or skip
validation for that comment and fold it to the body (`none` handling). If the validator prints nothing or exits non-zero, treat the verdict
as `none`. If `_pr.diff` is empty after the re-fetch above, do not derive any
verdicts from it: stop, surface the error `--pr-diff` printed to the user, and publish
body-only (fold ALL inline findings) — never loop on further fetches.

Apply the verdict per comment (each side validates against its own numbering —
`RIGHT` against new-file lines, `LEFT` against old-file lines, matching the
`line` + `side` rules table below):

- `valid` — keep the anchor unchanged.
- `remap <n>` — set `line` to `<n>` and append one note line to the comment
  body: `_(anchor remapped from line <original> — original line is not part of
  the diff)_`. The finding survives with its evidence intact. Drop any
  `suggestion` block: it would replace line `<n>`, not the line the finding is
  about. Remaps are capped at 40 lines of distance — anything farther prints
  `none` instead, because a comment 40+ lines away from its evidence is noise.
- `none` — the side has no commentable line within reach (deleted/binary/out of
  PR, or beyond the remap cap): do NOT emit an inline comment;
  fold the finding into the overall body as a body-only finding
  (`references/publish.md`). It keeps its ID and its line there, marked `· no inline comment`,
  with its full explanation in a collapsed block below. Never silently drop a
  finding.

Multi-line comments: GitHub additionally requires `start_line` and `line` in
the SAME hunk, so validate EVERY integer in `[start_line, line]` (same side);
separate hunks always leave a numbering gap, so any non-`valid` verdict inside
the range means collapse to a single-line comment on the validated `line`.
Only validated anchors may appear in the final `comments[]` array.

## Submission

Write the full payload to a file and post it with the driver's `--post-review`, the call the
standalone branch of `references/publish.md` runs:

```bash
URL="$(cd "$REPO" && bash "$VCS" --post-review --provider github --repo-id "$REPOID" <n> "$WORKDIR/_synthesis.json")"
```

The verb sends the file to the endpoint above with `--hostname <host>` and prints the review's
`html_url`, the value you return to the user. The review id is the number after
`#pullrequestreview-` in that URL.

## `line` + `side` Rules

| File `changeType` (from the worktree `git diff --name-status`, forge-agnostic) | Default `side` for new content | Notes |
|---|---|---|
| `ADDED` | `RIGHT` | Every line is in the diff; any line number valid |
| `MODIFIED` | `RIGHT` for new lines, `LEFT` for removed lines | Line must be in the diff hunk — out-of-hunk → 422 |
| `RENAMED` | `RIGHT` | Use the new path |
| `REMOVED` | `LEFT` | Use the old path |

**Multi-line comments**: provide `start_line` + `line` (both on same `side`). GitHub renders as a range.

**`position` (legacy)**: don't use unless `line`/`side` doesn't fit. `position` is the line offset within the unified diff — fragile.

## Suggested changes

An inline comment may carry one fenced block whose info string is exactly `suggestion`.
GitHub renders it as a diff with a **Commit suggestion** button. Applying it commits the
block's content to the PR branch in place of the commented line — or of every line from
`start_line` to `line`. A wrong suggestion therefore costs the author a commit. Emit one
only when every condition holds:

- The fix replaces exactly the commented lines. If it also needs a line outside the
  commented range, describe the fix in prose instead.
- The anchor validated as `valid` on side `RIGHT`. A remapped anchor, a `LEFT` anchor, and a
  body-only finding never carry a suggestion. On GitLab, where the skill validates no anchor,
  this condition reads: the anchor is one line on side `RIGHT`, so a `LEFT` anchor, a comment
  without a line and a body-only finding never carry one. The driver's preflight then places
  the anchor or degrades its discussion, and GitLab cannot apply the block of a degraded one
  (`rules/gitlab-publish.md`).
- The lead has read the commented lines itself — in the Stage-2 read of the Finding
  Verification Gate, or in a direct `Read` of `$WORKTREE` when the gate is off — and the
  block repeats every unchanged character of those lines exactly, indentation included.
- The block is complete code: no placeholder, no ellipsis, no elided middle, and no run of
  three backticks, which would end the fence early.
- The block differs from the current lines.

Put the block after the prose explanation, never instead of it: the author has to learn why
before seeing what. GitLab spells the fence differently (`rules/gitlab-publish.md`).

## Single-Submit vs Multi-Submit

**Always single-submit**: bundle all inline comments in the `comments[]` array of ONE review. Why:
- Atomic: either all post or none.
- One notification email to PR author + reviewers (not 25).
- One entry in the PR's review history.
- Easy to revoke (one `DELETE /reviews/<id>`).

**Don't** loop over `--post-comment` (`POST …/pulls/<n>/comments`) for each inline — that creates N orphaned comments with no review wrapper.

## Idempotency and delegated reconciliation

Standalone mode keeps the existing behavior: `--post-review` submits a new review, and an
explicit standalone re-run may therefore create an additional review.

Autopilot delegation never calls that path directly. It calls the VCS driver's
`--reconcile-review` operation with the durable operation key and expected head. The driver
adds this marker to the single GitHub review body (`partCount` is always `1`):

```text
<!-- zensu-review:v1:<sha256(operationKey)>:<payloadDigest>:<headSha>:1:part=1/1 -->
```

The reconcile read exhausts every page of existing reviews before deciding. Exact marker
presence returns `present` without a POST; marker absence posts once and returns `posted`;
`reconciled` is reserved for a provider path that completed missing parts. Duplicate exact
markers, the same operation digest with a different payload/head/part count, malformed v1
markers, an OPEN/head mismatch, or incomplete pagination fail closed without posting.

The structured result has exactly
`{status,marker,headSha,partCount,postedCount,url,provider}` with `provider=github`. The caller validates the operation
digest, payload-digest shape, bound head, `partCount=1`, first-part marker, status/count
relationship, and non-empty URL before recording durable publication evidence.

### Delegated failure policy

Delegated mode fails closed on every non-zero or malformed `--reconcile-review` result.
After a fresh OPEN/bound-head guard, the only safe retry is to retry the complete `--reconcile-review` call with the same operation key, bound head, and byte-identical payload.
The delegated path must never update the bound head or payload to make a retry pass, and it must never escape to
`--post-review`, `--post-comment`, a direct review/comment POST, binary-search submission, or
the standalone fallback below. An ambiguous transport failure is reconciled by the complete
operation read-before-write path; it is never answered with a raw POST retry.
The durable owner must serialize calls for one operation; simultaneous independent writers
outside that contract are not a distributed exactly-once mode.

## Auth Pre-Check

Before any POST, the scout's `--detect` must have reported `cliReady=true`; `SKILL.md` stops
otherwise. The host check is the driver's own: a verb refuses before gh runs when the pull
request's host is neither github.com nor the host `GH_HOST` names and gh holds no login for it,
and its message names the fix, `gh auth login --hostname <host>`.

Required scopes:
- `repo` (full) for private repos
- `public_repo` for public repos only

If scopes missing: `gh auth refresh --hostname <host> -s repo`, with `<host>` the pull request's
host.

## Standalone failure modes

The remediation table and payload-adjustment retries in this section apply only to the
standalone `--post-review` path. Delegated mode follows the fail-closed policy above.

| HTTP status | Cause | Fix |
|---|---|---|
| 401 | Token invalid/expired | `gh auth refresh --hostname <host>` |
| 403 | Scope missing OR fine-grained token restriction | `gh auth refresh --hostname <host> -s repo` |
| 404 | PR doesn't exist OR no read access | Verify PR URL + repo membership |
| 422 (line out of diff) | Inline `line` not in any diff hunk | Should not occur — anchors are pre-validated (see Pre-Publish Anchor Validation). If it still fires: refetch the diff, re-validate every anchor, retry |
| 422 (commit_id mismatch) | Head SHA changed since fetch | Re-run `git rev-parse pr-<n>-review`, update payload, retry |
| 422 (`commitId` not defined on `DraftPullRequestReviewThread`) | `commit_id` set on an entry of `comments[]` | Move it to the review level (see Payload Shape) — retrying the same payload can never pass |
| 500 / 502 | GitHub transient | Wait 30s, retry once |

Standalone last-resort only (a 422 that survives re-validation): identify the offending comment(s) by binary search — `jq 'del(.comments[<i>])' payload.json > shrunk.json` and retry until POST succeeds — and fold whatever was removed into the overall body as body-only findings (`SKILL.md` Phase D) so no finding is lost.

## Standalone-only fallback: Per-comment posting

If a standalone single-submit fails for non-retryable reasons (e.g. malformed payload), fall
back to two driver verbs, both run from `$REPO` so each pins the pull request's host. Both
build their request from `$WORKDIR/_synthesis.json`, the payload the submission above sent,
whose anchors are already validated: the path and the body are attacker-influenced, and this
way no part of either reaches a command line. Each post is chained to the `jq` that writes its
file, so a failed `jq` posts nothing, and both verbs refuse a missing or empty payload file
before any gh call, the host lookup included.

First the overall body alone, as a review with no inline comments:

```bash
jq '{event: "COMMENT", body: .body}' "$WORKDIR/_synthesis.json" > "$WORKDIR/_body-review.json" \
  && (cd "$REPO" && bash "$VCS" --post-review --provider github --repo-id "$REPOID" <n> "$WORKDIR/_body-review.json")
```

Then each inline separately, `<i>` being the comment's index in the payload's `comments[]`
(0, 1, …). The entry keeps its validated `path`, `line`, `side` and range fields, and the
review-level `commit_id` is added to it. `--post-comment` sends the file to
`POST /repos/{owner}/{repo}/pulls/{n}/comments` and prints the comment's `html_url`:

```bash
jq --argjson i '<i>' '.comments[$i] + {commit_id: .commit_id}' "$WORKDIR/_synthesis.json" > "$WORKDIR/_comment.json" \
  && (cd "$REPO" && bash "$VCS" --post-comment --provider github --repo-id "$REPOID" <n> "$WORKDIR/_comment.json")
```

When `_synthesis.json` is itself the malformed part, repair the file with the Write tool
first; never retype a path or a body into the command.

`commit_id` is REQUIRED on this endpoint's comment object and FORBIDDEN inside the
reviews payload's `comments[]` — the two endpoints take different shapes, so this
fence is not a template for the review payload (see Payload Shape).

This loses atomicity but unblocks the user. Mention the fallback in the final message.

## Verification After Post

Read the posted review back with `--fetch-review`, `<review-id>` being the number after
`#pullrequestreview-` in the URL `--post-review` printed:

```bash
(cd "$REPO" && bash "$VCS" --fetch-review --provider github --repo-id "$REPOID" <n> <review-id>)
```

It prints one JSON object with `id`, `state`, `author`, `submittedAt`, `url` and `comments`, the
number of the review's inline comments counted over every page. `comments` should equal the
length of the payload's `comments[]`, and `state` should match its `event`: `COMMENTED` for
`COMMENT`, `CHANGES_REQUESTED` for `REQUEST_CHANGES`, `APPROVED` for `APPROVE`.

Return the URL `--post-review` printed to the user (format: `https://<host>/<o>/<r>/pull/<n>#pullrequestreview-<id>`).
