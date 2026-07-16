# GitLab Publish — VCS-driver reference

How the driver publishes one consolidated review on a **GitLab merge request**. GitLab has
no atomic review object (unlike GitHub's `pulls/:n/reviews`), so `bash "$VCS" --post-review`
degrades the single review into a **loop** (spec §7): one summary note + N inline
discussions. The driver owns the loop — the skill never calls `glab api` directly.

## What the driver does

`bash "$VCS" --post-review --provider gitlab --repo-id <ns%2Fproj> --diff-refs-json <json> <iid> <payload.json>`

consumes the **same** `_synthesis.json` payload the GitHub path uses
(`{commit_id, event, body, comments:[{path,line,side,body}]}`) and emits, in order:

1. **One summary note** — `POST projects/:id/merge_requests/:iid/notes` carrying the overall
   markdown body, prefixed with `_Verdict: <EVENT>_` (GitLab has no review `event`, so the
   verdict lives in the note text).
2. **N inline discussions** — `POST projects/:id/merge_requests/:iid/discussions`, one per
   inline finding, each with a `position` object:
   - `position[position_type]=text`
   - `position[base_sha]` / `position[start_sha]` / `position[head_sha]` — the MR diff refs
   - `side=RIGHT` → `position[new_path]` + `position[new_line]`; `side=LEFT` →
     `position[old_path]` + `position[old_line]`.

Each POST is one compact JSON object streamed to `glab api --input -`; review bodies and
positions are never command-line arguments, so valid multi-megabyte payloads cannot hit
the platform `ARG_MAX` limit during a partial retry.

For delegated Autopilot reconciliation, that payload coordinate is only the lookup key. The
driver resolves it against the fully paginated MR diff before rendering the GitLab position:
added/deleted lines carry the exact old/new path pair and their available line, while an
unchanged context line carries **both** `old_line` and `new_line`. Renames therefore use the
actual `old_path` and `new_path`, not one duplicated payload path.

## Diff refs (required for inline positions)

GitLab inline discussions need the MR's diff SHAs. Fetch them first and pass them in:

```bash
# Run from $REPO so glab resolves the correct host (self-hosted included) from its remote.
DR="$(cd "$REPO" && bash "$VCS" --diff-refs --provider gitlab --repo-id "$REPOID" <iid>)"
# → {"base_sha":"…","start_sha":"…","head_sha":"…"}  (from the MR's diff_refs)
(cd "$REPO" && bash "$VCS" --post-review --provider gitlab --repo-id "$REPOID" --diff-refs-json "$DR" <iid> "$WORKDIR/_synthesis.json")
```

If `--diff-refs-json` is omitted, the driver fetches the diff refs live from the MR (also
from `$REPO`, so the host resolves correctly).

## Position robustness (no partial posts)

GitLab rejects an inline discussion whose `position` is malformed (empty line, missing diff
SHAs). Because the summary note posts first, a mid-loop rejection would leave a **partial**
review. The driver avoids that two ways:

- **Line-less finding → general thread.** A comment with no `line` (e.g. a file-level
  coverage finding — "no test exercises `X`") is posted as a **positionless** discussion with
  the path folded into the body, instead of an invalid inline position.
- **Fail loud before posting.** If any comment *does* need an inline position but the MR's
  `base_sha`/`head_sha` came back empty, `--post-review` returns non-zero **before** posting
  the summary note — nothing is published, so the run is cleanly retryable (no partial post).
- **Delegated anchor preflight.** Before its first missing-part write, `--reconcile-review`
  fetches every page of `merge_requests/:iid/diffs` and builds the complete render plan. A
  non-zero, malformed, truncated, structurally incomplete, or numerically overflowing diff
  read fails before any write. A valid diff whose individual anchor is missing, ambiguous,
  collapsed, too large, or not safely parseable degrades that finding deterministically to a
  positionless discussion.

## Idempotency and delegated reconciliation

Standalone `--post-review` retains its existing summary-plus-discussions behavior. An
Autopilot delegation instead uses `--reconcile-review` with the durable operation key and
expected head. For `N = 1 + comments.length`, every part carries a unique full marker:

```text
<!-- zensu-review:v1:<sha256(operationKey)>:<payloadDigest>:<headSha>:<N>:part=<i>/<N> -->
```

Part 1 is the summary note; parts 2..N are the ordered inline/positionless discussions.
Before any write, the driver fetches **all** paginated MR notes and discussions. If every
expected marker is present exactly once, return `present` with `postedCount=0`. If none are
present, post the ordered parts and return `posted`. If a strict subset is present, post
only the missing parts and return `reconciled`, so a crash-retry completes without
duplicates.

New GitLab MRs may expose empty `diff_refs` briefly. Delegated reconcile therefore owns a
bounded readiness loop, rechecking `OPEN` and the bound head on every attempt, and writes no
summary/discussion until complete base/start/head refs are available. It then resolves every
payload coordinate against the current fully paginated MR diff before posting any missing
part, so context lines and renamed files use the exact GitLab position tuple.

Fail closed before posting on a duplicate marker, malformed v1 marker, the same operation
digest bound to a different payload/head/part count, an unexpected part index, incomplete
pagination, or an MR that is not OPEN at the expected head. Re-read all pages after writes
and require the complete exact marker set. The structured result has exactly
`{status,marker,headSha,partCount,postedCount,url,provider}` with `provider=gitlab`; `marker` is always the part-1 marker,
which lets Autopilot validate and persist one durable publication receipt.
Autopilot serializes one operation through its durable owner; the protocol supports
sequential crash/retry repair, not simultaneous independent writers that bypass that owner.

## Verdict / approval — never automatic

The verdict (`COMMENT` / `REQUEST_CHANGES` / `APPROVE`) is carried in the **summary note
text only**. The driver **never** calls `glab mr approve` or `glab mr merge` — approving a
merge request is a human action (spec §9 decision 3, matching the plugin's never-auto-merge
stance). `--verdict=APPROVE` still just annotates the note; it does not approve the MR.

## `id` / `iid` / project-id notes

- GitLab addresses an MR by its **`iid`** (per-project number in the URL), not the global
  `id`. The pr-url's `.../-/merge_requests/<n>` number is the `iid`.
- The project id is the **URL-encoded** `namespace/project` (`grp%2Fproj`), exactly as
  `bash "$VCS" --detect` emits in its `repo=` line — pass it verbatim as `--repo-id`.

## No markdown tables

Same hard rule as the GitHub path: no markdown tables in the summary body or inline
discussions — GitLab's diff view squeezes them unreadably. Use numbered subsections + bullet
lists with bold prefixes.

## Known limits (Phase-3 follow-ups)

- Multi-line range comments (`start_line`/`start_side`) collapse to a single-line inline
  position on GitLab (its `position[line_range]` nesting is not emitted yet). The comment
  still posts, anchored at `line`.
- The summary note returns no `html_url`; the skill reports the MR URL from the scout
  metadata plus the count of posted threads.
