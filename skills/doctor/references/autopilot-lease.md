# Autopilot lease rows

Read this before you relay any `autopilot lease:` row. The rows describe the Autopilot
project lease, the external process lock `_autopilot_locked_run` takes, and its recovery
sentinel. The doctor reads them through the core's read-only `inspectExternalProcessLock` and
never deletes either artifact.

- **✅ autopilot lease: free** → no lock artifact and no recovery sentinel exist, so no
  process holds the Autopilot project lease right now. Say so; a refusal that named
  `/zensu:doctor` earlier was not caused by a lease that is still held.
- **✅ autopilot lease: held right now** → a process took the lease within the last 30 s. A
  lease covers one short critical section and clears on its own; relay the owner pid,
  liveness, start identity, holder marker (Windows only) and `created_at` the row prints, and suggest running
  `/zensu:doctor` again if an Autopilot state read keeps failing. **✅ autopilot lease: a
  lease is being recovered or released right now** says the same of the recovery sentinel.
- **⚠️ autopilot lease: … is removable; the next lease acquisition reclaims it on its own** →
  the lock artifact or the recovery sentinel names an owner that no longer holds it: the
  owner pid is gone, the pid now belongs to a different process because its start identity
  no longer matches or because that process started after the record was written, or it
  carries no owner record the core can read and is past the core's 30 s bound. On Windows the
  row **pid `<pid>` no longer holds the lease** (or the recovery sentinel) says that no process
  holds the record's holder marker open any more: the holder keeps that marker file open while it
  holds the lease, so a free marker means it let the lease go: it exited, or gave it up after its
  own release failed, in which case the pid still runs. The verdict is the core's own reclaim
  rule, read through
  `inspectExternalProcessLock`. Relay the facts and the path the row prints. **Never delete
  the artifact and never offer to** — the next lease acquisition reclaims it on its own, so
  no manual removal is needed, and a removal run later can delete the lock of whichever
  process takes the lease next. Phase 3 covers `pending-review.json` alone.
- **⚠️ autopilot lease: held for … by a live lock keeper**, or **held since a created_at that
  lies in the future by a live lock keeper** → a live process that still carries the recorded
  start identity holds the lease, or, on Windows, a process still holds the record's holder
  marker open, normally the lock keeper itself. Past 30 s every other lease acquisition gives up waiting and
  its Autopilot state read fails; with a future `created_at` the hold time is unknown. The
  artifact is NOT removable. The owner record lives in the session-writable `.zensu/state`, so
  its pid and start identity are evidence, not proof: relay the row's check,
  `ps -ww -p <pid> -o args=`, which must show one of the two lock keeper shapes named in the next
  bullet but one. Relay the row's remedy for a hung run: the user ends the shell that runs
  `_tdd_locked_run` for that run together with every process under it — the pid itself under
  bash 3.2, the parent of the parent of the pid under bash 4 or later, because the node lock
  keeper runs inside a coprocess shell. That ends the run, and the lease clears. Never end the
  node lock keeper alone, which lets the next lease acquisition in while that shell still runs
  its critical section, and never its coprocess shell alone, which releases nothing. Ending a
  process is the user's decision.
- **⚠️ autopilot lease: the recovery sentinel … has been held … by pid `<pid>`, which still
  carries the recorded start identity**, or **… by pid `<pid>`, whose holder marker a process
  still holds open** (Windows) → a node process began a lease recovery or release and
  has not finished it. The sentinel is NOT removable, and while it stays every lease acquisition
  gives up. A process that holds the recovery sentinel is a node process whose command line
  names `session-control-core-v1.js`, under any bash. The owner record is evidence, not proof,
  so relay the row's check, `ps -ww -p <pid> -o args=`. If the pid is such a process and hung,
  the user may end it, and the next lease acquisition reclaims the sentinel. Ending a process is
  the user's decision.
- **⚠️ autopilot lease: held for … by pid `<pid>`, which is alive**, its future-`created_at`
  twin, or **the recovery sentinel … has been held … by pid `<pid>`, which is alive** → no
  start identity was recorded, or the recorded one cannot be read now, and nothing shows that
  the process holding that pid did not write the record: no start more than a second after the
  record was written, and on Windows no free holder marker. Every lease acquisition checks
  again, so the artifact clears as soon as that shows, or when that process releases it or
  exits. On Windows the row also says No holder marker exists for this record when a runtime
  from before holder markers, or a holder that could not create one, wrote it, and says that
  something exists at its holder marker's name that the core cannot judge, so it proves nothing
  either way, when the marker's name holds a directory, a non-empty file or a file that cannot
  be opened. The row says the doctor cannot establish whether pid `<pid>` is still the lock keeper
  or the holder of the recovery sentinel, and names what a live one looks like. For the lock:
  the node lock keeper whose command line names `session-control-core-v1.js` and this project's
  `.zensu/state` (bash 4 or later, every Windows host), or the bash process that runs a Zensu
  hook or `zensu-log.sh` (bash 3.2). For the recovery sentinel: a node process whose command
  line names `session-control-core-v1.js`, under any bash. Relay that. Only when the pid is not
  such a process is the process that took the lease or the sentinel gone, and only a removal by
  hand clears it then, because a process that took the pid within a second of the record keeps
  it while it lives: the user checks the full command line with `ps -ww -p <pid> -o args=`
  (without `-ww`, `ps` cuts the line before the arguments that carry these names), runs
  `/zensu:doctor` again, and removes the artifact only while the row still names the same pid
  and `created_at`. Never remove the artifact yourself and never call it removable.
- **⚠️ autopilot lease: the lease path holds …** or **the recovery sentinel path holds …** (a
  symbolic link, an entry that is not a regular file, or an oversized file), or **the core
  cannot read the lock artifact** (or the recovery sentinel) → the core never writes that
  there, or cannot parse what is there: every lease acquisition fails while it stays, and
  nothing reclaims it. Relay the path; the user inspects it (its permissions and content) and
  removes it by hand. The same holds when the artifact carries no owner record the core can
  read and its modification time lies in the future.
- **⚠️ autopilot lease: the lease artifact could not be resolved** → the state directory is a
  symbolic link or not a directory, or `.zensu/state/autopilot` is not a single-link regular
  file. The lease cannot be taken while that holds, and running `/zensu:doctor` again does not
  clear it; relay the cause, and the user fixes the path it names by hand.
- **⚠️ autopilot lease: not checked** → the Session Control core did not load with its lease
  inspection, or the row failed while it was rendered: a missing check, not an all-clear.
  Suggest running `/zensu:doctor` again; if the row repeats, the plugin tree is damaged and the
  user reinstalls or updates the plugin.
- **⚠️ autopilot lease: … changed while it was read**, or an artifact that carries no owner
  record the core can read and is still inside the 30 s bound → a lease is being taken,
  released or recovered right now: a missing check, not an all-clear. Suggest running
  `/zensu:doctor` again; offer no cleanup.
