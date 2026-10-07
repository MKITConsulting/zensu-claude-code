# 6. Freeing a worktree — what "Archive" actually does

Read this before you advise the user to archive or remove a session.

Nothing enforces exclusivity. There is no lock file in the worktree's gitdir, and the entry in `~/.claude/sessions/` is a registration, not a claim — two agents in one worktree is a hazard, not a blocked operation. So "wait for the other session" is a judgement call, and the clean way to settle it is for the user to archive that session.

Archiving stops the session's process and by default cleans up its worktree — unless a `.worktree-keep` marker holds it, below:

- **Worktree**: usually removed. A survivor is usually dirty, because `git worktree remove` refuses one with uncommitted changes without `--force`.
- **Branch**: always survives. Committed work is never at risk; a removed worktree comes back with `git worktree add <path> <branch>`.
- **Transcript**: survives archiving. Transcripts older than 30 days are removed by the transcript retention default, archived or not.

**A `.worktree-keep` marker stops that cleanup, and this plugin writes one.** Claude Desktop's log names the reason — `[WorktreePool] <name> has .worktree-keep; leaving on disk`. The worktree-keep hooks hold that marker while any live session anchor sits in the worktree (`docs/worktree-keep.md`), and an anchor stays live until its session's SessionEnd hook ages it or 72 hours pass after its last prompt. The agent tool `delete_session` refuses a marked worktree outright, naming `.worktree-keep`. So after a takeover, whichever route it took, run `release` (`references/takeover.md` step 4) before the old session is archived or removed; once it prints its `ARCHIVE` line, nothing of this plugin holds the old worktree any more.

**The same cleanup does not spare a nested repository, and `release` refuses while one remains.** The cleanup judges the worktree by its `git status`, removes it whole, and protects only the worktrees the app created itself. A worktree of another repository nested inside — the multi-repo `.worktrees/<repo>/<branch>` layout — is usually ignored by the outer repository, so the outer tree reads as clean and the nested one goes with it. A submodule of the worktree's own repository is the one nested kind `release` admits — and only a real one: a linked worktree of a submodule's repository is refused, and the scan still looks for nested repositories inside an admitted submodule. It recognizes a repository by its `.git` entry, and a bare one by its `HEAD`, `objects` and `refs`. `release` never lifts the keep marker while a nested repository is there, but the marker does not wait for them: it holds only while a live anchor does. Move them out before that window ends.

**Archiving is also what makes continuing in someone else's worktree unsafe.** `references/takeover.md` step 3 is about a directory that exists but sits outside your anchor: you can edit, you cannot commit while the opt-in gate is on. This is the directory going away *while you work in it*. A session whose recorded project root is removed enters the orphaned-project-root state: reads still pass, but no `Edit`, `Write` or `MultiEdit` lands, nor a Bash write while the opt-in source-write gate is on, so the session cannot even repair itself. The per-hook detail is `docs/session-control.md`'s "Unbindable sessions" roster. The Stop enforcer releases rather than blocks, so the turn can still end. The escape is to re-create that exact directory (`git worktree add <dead-path> <session-branch>`, since the branch survived) or to start a fresh session. That is the one case where restoring the session's OWN path is right — you are repairing your own root, not choosing where to continue someone else's work.

**Before telling the user to archive, check `git status` in that worktree.** If it is dirty, have them commit first.

Do not take the script's `dirty` count as that check. Every git call it makes collapses *any* failure — non-zero exit, the 8 s timeout, an output-buffer overflow, git missing — into an empty result, so a worktree whose status could not be read is reported as clean. `release` is the exception: it reports an unreadable status as unknown and says so on its `ARCHIVE` line. Run `git status` in the worktree yourself before advising an archive.

Never call `archive_session` yourself on a session the user has not explicitly named, and never kill the process directly.
