# Worktree keep

Three advisory hooks keep a live session's app-managed worktree out of the Claude Desktop
worktree pool, and tell the session what to do when the pool took the directory anyway.

## The failure this answers

The Claude Desktop app (Code tab) keeps a pool of git worktrees under
`<repo>/.claude/worktrees/<name>`. When a session whose own worktree was reaped is opened again,
the pool re-leases a directory it believes to be free and checks that session's branch out
there — in place. The pool's free-or-taken decision only sees the sessions of the app instance
that asks, so with one app instance per account a directory that another account's session is
working in reads as free. Measured on Claude Desktop 2.2553.1 with Claude Code 2.1.275: the app
log carried `[rebindWorktree] Rebound <dir> (was leased by none) to <session> on branch <branch>`
while a live session held `<dir>`, and that session's directory changed branch under it.

The app honours one signal that is checked on disk rather than through its per-instance lease
table: a file named `.worktree-keep` in the worktree root. Its pool skips such a worktree both
as a reuse candidate and in its idle reaper. That file name is an internal constant of the
desktop app, read from the 2.2553.1 bundle; it is not documented and a later build may rename
it, which is why the branch-drift detector below exists as the safety net.

## What the plugin does

Every hook anchors on the bound session record's project root. The SessionStart and SessionEnd
halves fall back to the session's `cwd` while the record is not readable yet, which is the
ordinary state of a fresh start; the UserPromptSubmit half does NOT — an unbound session gets no
drift disclosure at all, which is listed under Limits below. A payload that names no
`.claude/worktrees` component is declined before any helper runs.

- **`session-start-worktree-keep.sh`** (SessionStart, every source). When that root
  is a linked worktree under `<repo>/.claude/worktrees/`, it writes this session's anchor
  `<worktree>/.zensu/state/worktree-anchor-<session key>.json` (the branch and head it started
  on, a liveness stamp and the idle window it was written under), puts the `.worktree-keep`
  line into the worktree's `<git common dir>/info/exclude` once so the marker never shows in
  `git status`, reconciles the marker, and sweeps the sibling worktrees of the same repository
  (bounded to 64 directories). A fresh start records the current branch. A resume or a
  compaction keeps the recorded branch and refreshes the stamp; it states a drift that is still
  in place again, because the compacted context no longer holds the first notice, and it
  discloses a new one. A drift recorded before a rebase or bisect was paused, or before a branch
  read that fails now, is stated again as recorded, naming the pause or the failed read. When a
  resume or a compaction finds no usable anchor, it rewrites the anchor and, once that write has
  landed, says once that the branch checked out now was adopted as the baseline without
  verification. Nothing is said when the branch cannot be read, or when the write is refused, as
  it is over a symlink, a hard link or a non-file at the anchor path, or a broken `.zensu/state`
  component.
- **`user-prompt-worktree-keep.sh`** (UserPromptSubmit). Refreshes the liveness stamp at most
  every ten minutes, reconciles the marker, and compares the worktree's current branch with the
  recorded one. On a new drift it injects one model-facing notice naming both branches, the
  current head, the likely cause and the way to continue (below). The same drift is disclosed
  once per context; a switch back to the recorded branch clears it. A detached HEAD while a
  rebase or a bisect is paused (`rebase-merge`, `rebase-apply` or `BISECT_LOG` in the
  worktree's git dir) is not judged at all, and a baseline recorded during such a pause takes
  the branch the operation returns to (git's own `head-name` or `BISECT_START`), or waits until
  the operation ends when that record cannot be read. When this session's anchor is missing,
  names another worktree or holds a record the plugin can replace (unparseable, misshapen or
  oversized), the prompt rewrites it and says once that the branch was adopted without
  verification, so a takeover before that point cannot be ruled out. A symlink, a hard link or
  a non-file at the anchor path, or a broken `.zensu/state` component, is never replaced:
  nothing is recorded and no notice is given until the user removes or fixes it, which
  `/zensu:doctor` names.
- **`session-end-worktree-keep.sh`** (SessionEnd). Ages this session's anchor instead of
  deleting it: the anchor stops holding the marker at once but stays as the branch baseline
  until twice its idle window, so a takeover between the end and a later resume is still
  disclosed. An anchor it cannot validate is removed when it is a regular file, a hard link
  included; a symlink, a non-file or a broken `.zensu/state` component is left in place.

With `hooks.worktreeKeep` off, the SessionStart and SessionEnd hooks run a release pass instead:
they remove this session's anchor and every marker this plugin wrote that nothing holds any
more, in this worktree and in its siblings, and never create one. The prompt hook stays off. A
marker stays while a live anchor of another session holds it, while an anchor file this build
cannot validate sits beside it (usually the live anchor of a session on another plugin version
during an update; remove it by hand only after confirming no such session is live there), and
while the anchor directory cannot be read — a directory past its bound drains as those passes
reap the expired anchors they read; `/zensu:doctor` names which of these holds it.

The marker's lifecycle is implemented once in `hooks/lib/worktree-keep-v1.js`: the marker is
held in a worktree while at least one live anchor exists there, and also while an anchor this
build cannot validate sits beside it. An anchor is live while its stamp is younger than the idle
window it recorded (`hooks.worktreeKeepIdleHours` of the session that wrote it, default 72; the
reader's own window applies only to an anchor that recorded none), so a sweep under a shorter
window cannot release another session's marker early. An aged anchor from SessionEnd is stale at
once. A stale anchor loses the marker but stays on disk until twice its window, so a takeover
during the idle window is still detected against it; only a session in the same worktree reaps
it then, and the sibling sweep never deletes another worktree's anchor. The hooks of several
sessions can race: a reconcile that removed the marker lists the anchors again and restores the
marker when a live or an unvalidated anchor appeared in between or the second listing cannot be
read, and an anchor is read again right before it is reaped. The marker is created only after `git check-ignore` confirms git ignores it — the
exclude entry is added first when it does not — and it is published complete, through a
temporary file linked into place; on a volume without hard links the complete temporary file is
copied into place instead, again only where no marker exists yet. A marker the plugin did not write — the first line of its own
marker is a fixed signature — is never removed. Branch names outside a plain git ref shape are
never rendered: an anchor carrying one is rejected and rewritten, and a takeover onto a
checked-out branch with such a name is disclosed with the name withheld. Every git child runs
with the `GIT_DIR`-style discovery and config-injection variables removed from its environment.

## How to continue when the directory was taken

The notice cannot tell a takeover from a branch switch the session made itself, so it is worded
conditionally. If the session switched on purpose, nothing is wrong: the drift clears once the
recorded branch is checked out again, and `/clear` records the branch checked out then as a new
baseline.

Otherwise, first account for uncommitted work. Run `git status` and `git stash list` in the
taken directory: uncommitted changes there may be the displaced session's own edits or the
other session's. Do not commit, stash, reset or discard anything in that directory. Carry your
own edits into the nested worktree created below — copy the files or apply a patch there — or
ask the user when you cannot tell whose they are.

The desktop write-guard admits `Edit` and `Write` into a worktree nested inside the session's
own worktree; a sibling or temp-directory worktree is refused as `sibling_worktree`. The Zensu
Bash gates admit git inside the session's anchor. So the displaced session continues on its own
branch without leaving its directory:

```bash
git worktree add .claude/worktrees/<slug> <recorded branch>
```

If git reports the branch as checked out elsewhere, add `-b <recorded branch>-cont`.
`/zensu:session-trail` renders its own continuation recipe for the same situation and picks a
different directory name and a different branch policy; follow one of them, not both. Work and
commit in that nested worktree and push with `git push origin HEAD:<recorded branch>`. Never
switch the shared directory back: that pulls it out from under the session that took it.

If a Zensu review chain is armed in the session, close it in the shared directory first: the
chain's completion gate, its edit-landing audit and its run log are anchored on the session
record's root, which is the directory that was taken, not the nested worktree.

## Configuration

| Key | Default | Effect |
|-----|---------|--------|
| `hooks.worktreeKeep` | `true` | `false` turns the prompt hook off and stops every new marker, anchor and notice; SessionStart and SessionEnd then release this session's anchor and every marker this plugin wrote that nothing holds any more; a marker another live anchor, an anchor file this build cannot validate or an unreadable anchor directory still holds stays, and `/zensu:doctor` names the hold |
| `hooks.worktreeKeepIdleHours` | `72` (range `1..8760`) | Idle window after which an anchor no longer holds the marker; each anchor records the window it was written under and is judged by it |

## Doctor

`/zensu:doctor` renders a `worktree:` row family: not an app-managed worktree, marker present
with the live anchor count, an anchor directory that could not be read (and whether it drains),
marker missing while this session's anchor is live (naming why the plugin does not create it —
git does not ignore the marker, `info/exclude` refuses the entry, or git cannot answer — and
promising no restore while the anchor directory cannot be read), this session's anchor missing,
stale, naming another worktree (its branch is then not judged and its recorded root is never
printed) or without a branch (naming a paused rebase or bisect when one holds a detached HEAD, and
saying so when the branch read still fails), a branch drift with the recipe above (also while a
rebase or bisect paused after the drift was recorded, or while the current branch cannot be
read), a paused rebase or bisect, the switched-off state, a marker still present although
the flag is off together with what holds it, this session's own anchor when this build cannot
validate it (naming whether the next prompt replaces it, the user must remove it first, or a
component of `.zensu/state` must be fixed by hand, from the same pre-check the anchor write
applies, and promising nothing for a remedy it does not know), and anchor files of other sessions this
build cannot validate, which the row says to remove only after confirming no session on another
plugin version is live there.

## Limits

- The marker name is an undocumented desktop-app constant. If a later build stops honouring it,
  the marker protects nothing; the drift notice and the doctor row still report a takeover.
- Whether the desktop app delivers `SessionEnd` when it stops a session's process is unverified.
  A session that ends without it keeps its worktree out of the pool until the idle window
  elapses; the sibling sweep at every later SessionStart in the same repository clears it.
- The notice also fires when the session switched branches itself, once per context; the text
  says so and names the way to record a new baseline.
- A paused rebase or bisect suspends the check while HEAD is detached, whoever started it, so a
  takeover by a session that then pauses a rebase in the taken directory is reported only once
  that operation finishes; a drift recorded before the pause is stated again at a compaction or
  resume and stays visible in `/zensu:doctor`.
- The hooks engage only when the session started inside `.claude/worktrees/<name>`: a session
  that begins in the origin checkout and creates its worktree by hand is never anchored or
  marked, and whether the pool would touch such a worktree is unverified.
- An UNBOUND session gets no drift disclosure. The prompt hook reads the anchor under the
  recorded project root, so every relaxable bind failure — an unregistered session, a deleted
  worktree, an incompatible plugin lineage, a pruned installation — exits it silently. The
  marker still stands and `/zensu:doctor` still reports the state when asked.
- Every prompt of a managed-worktree session pays the session bind and one node child before
  the hook can answer; a plain-checkout session is declined by the payload pre-filter first.
  That pre-filter judges the raw payload TEXT while the hook itself anchors on the bound
  record, so the two judge different objects: a payload that stops naming a
  `.claude/worktrees` component silently skips the hook for the rest of the session even
  though the recorded root is a managed worktree. It is kept because the alternative puts a
  session bind and a node child on every prompt of every plain-checkout session; the trigger
  needs the host to stop reporting the session's own directory.
- A takeover onto a branch whose name git accepts but this plugin does not render is disclosed
  with the name withheld. Two DIFFERENT such branches read alike, so a move between them is
  not detected — the head moves, but the head alone changes on every commit and cannot carry
  the signal.
- The anchor directory is read up to a bounded number of files. Past that bound the check
  reports that it could not be performed and the marker is left exactly as it stands, rather
  than reading an unread directory as "no live session"; a reconcile in the same worktree still
  reaps the expired anchors it did read, so such a directory drains back under the bound.
- The recycle case — the app moves a session to a fresh worktree while the Session Control
  record still names the old one — is a different state and is not addressed here.
- The root cause is the app's per-instance lease visibility and last-writer-wins registry
  writes; only the app can close it.
