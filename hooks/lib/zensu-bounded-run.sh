#!/bin/bash

# Shared watchdog ladder for hook-path child processes.
#
# THE one watchdog ladder. It serves the children that read OUTSIDE
# this process — the `git status` the turn counter runs and the transcript read the
# refused-spawn probe runs — which is the criterion, not a count. State it that way:
# CLAUDE.md records that an enumeration of the `node` children on this path was written
# as "a THIRD child" and was already short by one on the day it landed, and the two the
# lease adds carry no watchdog on ANY host and are named there as a known gap.
#
# The two it serves used to carry SEPARATE ladders, so the arm added to one was missing
# from the other — and the one left behind was the transcript read, whose own comment
# records the larger exposure. `timeout` is absent on base macOS and some Git Bash
# installs, and `gtimeout` is the name a Homebrew coreutils install puts there instead,
# so probing only the first leaves a host that DOES have a watchdog running unbounded.
#
# It RUNS the command rather than answering a prefix. A prefix was tried first and the
# two grounds recorded for it were both false: redirections written after a shell
# function name apply for the duration of that function and are inherited by the child
# it execs, so a wrapper threads nothing, and the payload stays spelled once either way.
# What the prefix form actually cost was a `# shellcheck disable=SC2086` at each site, an
# unstated dependency on `IFS` containing a space and on the words being glob-free, and
# an extra fork per call. `"$@"` has none of those.
#
# The last arm runs the command UNBOUNDED, on purpose. Making it inert without a
# watchdog was the review's preferred fix and was REJECTED on a measurement: neither
# binary exists on base macOS, so it would switch a review-integrity diagnostic off on
# the platform it was built for. Do not read `|| return 0` at either call site as the
# mitigation — it tests an exit status, so it degrades a child that RETURNS and can do
# nothing about one that hangs. C56/C56d pin that this arm stays reachable.
#
# STATE THE RESIDUAL NARROWLY, because a wider one invites over-investment. The
# block-on-open vectors are already closed inside the transcript module: it refuses a NUL
# byte, `lstat`s and requires a regular file BEFORE opening, opens `O_NOFOLLOW|O_NONBLOCK`
# and re-checks by `fstat` — so a FIFO, device or symlink at that path cannot block. What
# the unbounded arm actually leaves is a REGULAR FILE ON STALLED STORAGE, and a git status
# that hangs. Availability only, no adversary in the loop. Worth knowing beside it: the
# Stop hook's own registration in `hooks.json` carries no `timeout` key, unlike several
# sibling entries, so nothing in this repository bounds the hook either and whether the
# host applies a default is unverified.
zensu_run_bounded() {
  # `"$@"` with zero positional parameters aborts under `set -u` on bash 3.2, which is
  # macOS's /bin/bash and this script's interpreter — so a future argument-less call would
  # kill the Stop hook rather than no-op. Latent today (both call sites pass a command),
  # guarded so the property does not depend on every later caller remembering.
  # NON-ZERO, not 0. Returning success with no output would leave the transcript caller's
  # `probe` empty, which its `case` classifies as `unparseable` — a verdict the scope-sentence
  # allowlist WITHHOLDS on — where a failure leaves the initializer's `unprobed`, which is the
  # "no probe ran" state this situation actually is, and which renders.
  [ "$#" -gt 0 ] || return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 5 "$@"
  else
    "$@"
  fi
}
