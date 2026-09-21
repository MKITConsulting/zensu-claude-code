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
  on, plus a liveness stamp), puts the `.worktree-keep` line into `<git common dir>/info/exclude`
  once so the marker never shows in `git status`, reconciles the marker, and sweeps the sibling
  worktrees of the same repository (bounded to 64 directories). A fresh start records the
  current branch; a resume or a compaction only refreshes the liveness stamp, so a drift that
  already happened stays visible.
- **`user-prompt-worktree-keep.sh`** (UserPromptSubmit). Refreshes the liveness stamp at most
  every ten minutes, reconciles the marker, and compares the worktree's current branch with the
  recorded one. On a new drift it injects one model-facing notice naming both branches, the
  current head, the likely cause and the way to continue (below). The same drift is disclosed
  once; a switch back to the recorded branch clears it.
- **`session-end-worktree-keep.sh`** (SessionEnd). Removes this session's anchor and reconciles
  the marker.

The marker's lifecycle is one rule, implemented once in `hooks/lib/worktree-keep-v1.js`: the
marker exists in a worktree exactly while at least one live anchor exists there. An anchor is
live while its stamp is younger than `hooks.worktreeKeepIdleHours` (default 72). A stale anchor
loses the marker but stays on disk until twice that window, so a takeover during the idle window
is still detected against it; only then is it reaped. A marker the plugin did not write — the
first line of its own marker is a fixed signature — is never removed. Branch names outside a plain
git ref shape are never rendered: an anchor carrying one is rejected and rewritten, and a
checked-out branch with such a name is reported as unresolved. Every git child runs with the
`GIT_DIR`-style discovery and config-injection variables removed from its environment.

## How to continue when the directory was taken

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
| `hooks.worktreeKeep` | `true` | `false` disables all three hooks; no marker, no anchor, no notice |
| `hooks.worktreeKeepIdleHours` | `72` (range `1..8760`) | Idle window after which an anchor no longer holds the marker |

## Doctor

`/zensu:doctor` renders a `worktree:` row family: not an app-managed worktree, marker present
with the live anchor count, marker missing while this session's anchor is live, a branch drift
with the recipe above, the switched-off state, and anchor files the plugin did not write.

## Limits

- The marker name is an undocumented desktop-app constant. If a later build stops honouring it,
  the marker protects nothing; the drift notice and the doctor row still report a takeover.
- Whether the desktop app delivers `SessionEnd` when it stops a session's process is unverified.
  A session that ends without it keeps its worktree out of the pool until the idle window
  elapses; the sibling sweep at every later SessionStart in the same repository clears it.
- The notice also fires once when the session switched branches itself; the text says so.
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
  than reading an unread directory as "no live session".
- The recycle case — the app moves a session to a fresh worktree while the Session Control
  record still names the old one — is a different state and is not addressed here.
- The root cause is the app's per-instance lease visibility and last-writer-wins registry
  writes; only the app can close it.
