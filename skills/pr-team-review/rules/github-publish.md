# GitHub Publish — `gh api` Reviews Reference

How to post one consolidated review with bundled inline comments via `gh api`.

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

## Pre-Publish Anchor Validation (MANDATORY)

GitHub 422-rejects any inline comment whose `(path, line, side)` anchor is not a
commentable line of the PR diff — and the whole review POST fails with it.
Validate EVERY inline anchor BEFORE writing the payload, using
`hooks/lib/valid-diff-lines.js` (diff on stdin; path, line, and the comment's
`side` as argv, side defaulting to `RIGHT`; prints `valid`, `remap <n>`, or
`none`):

```bash
gh pr diff <n> --repo <o>/<r> > "$WORKDIR/_pr.diff"
[ -s "$WORKDIR/_pr.diff" ] || gh pr diff <n> --repo <o>/<r> > "$WORKDIR/_pr.diff"
node "{ACTIVE_PLUGIN_ROOT}/hooks/lib/valid-diff-lines.js" '<path>' '<line>' '<side>' < "$WORKDIR/_pr.diff"
```

**Quoting is load-bearing:** `<path>` comes from the PR diff — an
attacker-influenced value that may contain `$( )`, backticks, `;`, or spaces,
and double quotes do NOT neutralize `$( )`. Substitute the literals inside the
single quotes exactly as shown; if a substituted value (the path here, path or
body in the fallback fence) contains a `'`, escape it as `'\''` — or skip
validation for that comment and fold it to the body (`none` handling). If the validator prints nothing or exits non-zero, treat the verdict
as `none`. If `_pr.diff` is empty after the re-fetch above, do not derive any
verdicts from it: stop, surface the `gh pr diff` error to the user, and publish
body-only (fold ALL inline findings) — never loop on further fetches.

Apply the verdict per comment (each side validates against its own numbering —
`RIGHT` against new-file lines, `LEFT` against old-file lines, matching the
`line` + `side` rules table below):

- `valid` — keep the anchor unchanged.
- `remap <n>` — set `line` to `<n>` and append one note line to the comment
  body: `_(anchor remapped from line <original> — original line is not part of
  the diff)_`. The finding survives with its evidence intact. Remaps are capped
  at 40 lines of distance — anything farther prints `none` instead, because a
  comment 40+ lines away from its evidence is noise.
- `none` — the side has no commentable line within reach (deleted/binary/out of
  PR, or beyond the remap cap): do NOT emit an inline comment; fold the finding
  into the overall review body under a `**Findings without a diff anchor**`
  list (path + intended line + text). Never silently drop a finding.

Multi-line comments: GitHub additionally requires `start_line` and `line` in
the SAME hunk, so validate EVERY integer in `[start_line, line]` (same side);
separate hunks always leave a numbering gap, so any non-`valid` verdict inside
the range means collapse to a single-line comment on the validated `line`.
Only validated anchors may appear in the final `comments[]` array.

## Submission

Write the full payload to a file, post it via `--input`:

```bash
gh api -X POST repos/<owner>/<repo>/pulls/<n>/reviews \
  --input "$WORKDIR/_synthesis.json"
```

Capture the response — `id` and `html_url` are the values you return to the user.

## `line` + `side` Rules

| File `changeType` (from the worktree `git diff --name-status`, forge-agnostic) | Default `side` for new content | Notes |
|---|---|---|
| `ADDED` | `RIGHT` | Every line is in the diff; any line number valid |
| `MODIFIED` | `RIGHT` for new lines, `LEFT` for removed lines | Line must be in the diff hunk — out-of-hunk → 422 |
| `RENAMED` | `RIGHT` | Use the new path |
| `REMOVED` | `LEFT` | Use the old path |

**Multi-line comments**: provide `start_line` + `line` (both on same `side`). GitHub renders as a range.

**`position` (legacy)**: don't use unless `line`/`side` doesn't fit. `position` is the line offset within the unified diff — fragile.

## Single-Submit vs Multi-Submit

**Always single-submit**: bundle all inline comments in the `comments[]` array of ONE review. Why:
- Atomic: either all post or none.
- One notification email to PR author + reviewers (not 25).
- One entry in the PR's review history.
- Easy to revoke (one `DELETE /reviews/<id>`).

**Don't** loop over `gh api .../pulls/comments` for each inline — that creates N orphaned comments with no review wrapper.

## Idempotency

Re-running the skill on the same PR posts an **additional** review. There's no native idempotency key. If you want to suppress duplicates, hash the synthesis body and check existing reviews before posting:

```bash
HASH=$(jq -r '.body' "$WORKDIR/_synthesis.json" | sha256sum | head -c 8)
if gh api repos/<o>/<r>/pulls/<n>/reviews | jq -e ".[] | select(.body | contains(\"$HASH\"))" > /dev/null; then
  echo "Already posted — skipping"
  exit 0
fi
# else inject HASH into body footer and post
```

Default behaviour: post without dedup, accept that re-runs create additional reviews.

## Auth Pre-Check

Before any POST:

```bash
gh auth status 2>&1 | grep -q "Logged in" || { echo "gh auth required"; exit 1; }
```

Required scopes:
- `repo` (full) for private repos
- `public_repo` for public repos only

If scopes missing: `gh auth refresh -s repo`.

## Failure Modes

| HTTP status | Cause | Fix |
|---|---|---|
| 401 | Token invalid/expired | `gh auth refresh` |
| 403 | Scope missing OR fine-grained token restriction | `gh auth refresh -s repo` |
| 404 | PR doesn't exist OR no read access | Verify PR URL + repo membership |
| 422 (line out of diff) | Inline `line` not in any diff hunk | Should not occur — anchors are pre-validated (see Pre-Publish Anchor Validation). If it still fires: refetch the diff, re-validate every anchor, retry |
| 422 (commit_id mismatch) | Head SHA changed since fetch | Re-run `git rev-parse pr-<n>-review`, update payload, retry |
| 500 / 502 | GitHub transient | Wait 30s, retry once |

Last-resort only (a 422 that survives re-validation): identify the offending comment(s) by binary search — `jq 'del(.comments[<i>])' payload.json > shrunk.json` and retry until POST succeeds — and fold whatever was removed into the overall body so no finding is lost.

## Fallback: Per-Comment Posting

If the single-submit fails for non-retryable reasons (e.g. malformed payload), fall back to:

```bash
# Overall body only
gh pr review <n> --repo <o>/<r> --comment --body-file "$WORKDIR/_body.md"

# Each inline separately — the "Quoting is load-bearing" rule applies HERE too:
# path and body are attacker-influenced, so never interpolate them into raw
# `-f key=value` strings. Build the JSON with single-quoted jq --arg values
# (escape embedded ' as '\'' per the rule above) and post via --input, using
# each comment's VALIDATED side (not a hardcoded RIGHT):
jq -n --arg path '<path>' --arg body '<markdown>' \
      --arg side '<side>' --arg sha '<sha>' --argjson line '<line>' \
      '{path: $path, line: $line, side: $side, body: $body, commit_id: $sha}' \
  > "$WORKDIR/_comment.json"
gh api -X POST repos/<o>/<r>/pulls/<n>/comments --input "$WORKDIR/_comment.json"
```

This loses atomicity but unblocks the user. Mention the fallback in the final message.

## Verification After Post

```bash
gh api repos/<o>/<r>/pulls/<n>/reviews/<id>/comments | jq length
# Should equal len(payload.comments)
gh pr view <n> --repo <o>/<r> --json reviews | jq '.reviews[-1] | {state, author: .author.login, submittedAt}'
```

Return `html_url` from the POST response to the user (format: `https://github.com/<o>/<r>/pull/<n>#pullrequestreview-<id>`).
