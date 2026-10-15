# Attach mode

Loaded when `/zensu:verify-feature` runs with `--attach=<origin>`, in place of local mode's
runtime preparation.

`--attach=<origin>` verifies an application the user already runs. The origin must pass the
same loopback rule as local mode (`http://127.0.0.1:<port>`, another loopback IP, or
`http://localhost:<port>`; never another hostname). Boot nothing, seed nothing through the
runtime, register no `down` command, and never stop, signal, or restart the attached process.

Establish identity before the matrix: resolve the listening process with
`lsof -nP -iTCP:<port> -sTCP:LISTEN -t` where `lsof` exists, read its working directory with
`lsof -a -p <pid> -d cwd -Fn`, and compare it with the physical worktree root. Report
"worktree identity proven" only on an exact match; report "attached runtime, identity unproven"
otherwise, which caps the verdict at PARTIAL because the worktree claim of local mode is then
unestablished.

Consent applies unchanged: the first navigation to the attached origin asks the user. Attach
applies to `browser` and `api` rows; a build driver always builds and launches its own copy.
