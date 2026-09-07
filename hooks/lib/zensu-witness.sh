#!/bin/bash
# zensu-witness.sh — the payload extraction the TWO witness writers share.
#
# There are two, and the second exists because the first structurally cannot
# see a failure. `hooks/post-bash-witness.sh` runs on PostToolUse(Bash), and
# Claude Code does not deliver that event for a Bash call that did not complete
# successfully — measured with a matched pair in one live session: a command
# exiting 3 produced zero witness lines while the same command exiting 0
# produced exactly one. The hook itself has no branch on the exit status at all
# and writes a line for every payload dialect it was fed, including
# `exit_code: 3`, a bare-string `tool_response` and no `tool_response` at all,
# so the missing line is the host's, not the hook's.
#
# The consequence was one-sided evidence: `hooks/lib/zensu-evidence-crosscheck.js`
# matches a CHECKPOINT/AUDIT claim against a witness entry by EQUALITY, so a
# claim naming a command that failed could only ever read `EVIDENCE GAP`. The
# cross-check could corroborate a PASS and structurally could not corroborate a
# FAILURE — the opposite of the direction evidence discipline wants.
#
# `hooks/pre-bash-witness.sh` closes it from the one channel the host does fire
# unconditionally: PreToolUse. It records an ATTEMPT line before the command
# runs; the PostToolUse writer records the RESULT line with `tail=` when the
# call completes. An attempt with no result is therefore positive evidence that
# the call did NOT complete successfully, and the cross-check consumes it as
# such rather than as an absence.
#
# The two writers MUST redact and decode identically or the equality match
# breaks in both directions — a divergence here would turn every attempt line
# into a phantom that matches nothing. That is why the extractor lives in one
# file and is called twice, instead of being copied into the second hook. Each
# hook keeps its own plugin-root guard, principal check, session bind, bypass
# ledger and log-path spelling: those are the house pattern and are pinned per
# file (`test-bypass-ledger.sh` P3, `test-artifact-redaction.sh` R19, which
# scan BOTH writers).

# Resolve the redaction module for the extractor, or print nothing.
#
# The module path is transported through mechanism 2 of the two this repo
# accepts (tests/structure/test-msys-special-plugin-module-boundaries.sh):
# zensu-host-path.sh renders the lib DIRECTORY natively, the file name is
# appended, and the guarded result travels in an environment variable. A raw
# MSYS spelling would make `require()` fail on a Git Bash root and the fail-open
# branch would then silently stop redacting.
zensu_witness_redact_lib_path() {
  local root="${1:-}" dir path
  [ -n "$root" ] || return 0
  dir="$(bash "$root/hooks/lib/zensu-host-path.sh" "$root/hooks/lib" 2>/dev/null)" || dir=""
  [ -n "$dir" ] || return 0
  path="$dir/zensu-artifact-redact-v1.js"
  [ -f "$path" ] || return 0
  [ -L "$path" ] && return 0
  printf '%s' "$path"
}

# zensu_witness_fields <payload> <redact-lib-path> <project-dir> <outfile>
#
# Writes five lines to <outfile>: the JSON-encoded command, the exit code (or
# `?`), the JSON-encoded stdout tail, the interrupted flag, and the raw session
# id. A PreToolUse payload carries no `tool_response`, so it yields `?`, `""`
# and `false` for the middle three — the same values the PostToolUse writer
# already records for every real Claude Code payload, whose `tool_response`
# omits `exit_code`.
#
# `cmd` is redacted for SYMMETRY, not for the witness's own publication safety.
# The witness is gitignored in THIS repository only; a consuming repo has to add
# `.zensu/state/` and `.zensu/logs/witness-*.log` itself, and until it does, this
# file publishes with the artifacts around it. So do not read what follows as
# "this file never ships" — that claim was retracted across this feature and must
# not come back here. It is redacted because the narrative log is:
# hooks/lib/zensu-evidence-crosscheck.js matches a CHECKPOINT/AUDIT claim
# against a witness entry by EQUALITY, so redacting one side only would turn
# every Phase-6 claim whose command names an absolute path into an EVIDENCE GAP
# and wedge the workflow. Both sides therefore run the same function.
#
# It runs on the RAW strings, before JSON.stringify — redacting the encoded form
# would have to reason about doubled backslashes in a Windows path. Failure is
# fail-OPEN: an unredacted witness line still records the command, while a
# missing one fails the cross-check closed.
#
# `cmd` ONLY. `tail` is deliberately left alone: nothing compares it — the
# cross-check matches on `cmd` equality — and the one thing that reads it is
# `failureMarker`, which scans for FAIL/failed/Error tokens. Redaction there is
# purely subtractive, so a failure token sitting inside an absolute path would
# vanish and an EVIDENCE CONTRADICTION would silently downgrade to `verified`.
# That is the WHOLE argument for leaving it raw, and it is a trade rather than a
# free choice: a consuming repo that has not added the two `.gitignore` lines
# publishes this file with `tail` intact. The evidence channel is judged the more
# valuable of the two, because a cross-check that silently reports `verified` for
# a failed command corrupts every later decision built on it. Do not re-derive
# this from a claim that the file never ships — that is false for a consuming
# repo, and it was retracted everywhere else in this feature.
zensu_witness_fields() {
  local payload="${1:-}" redact_lib="${2:-}" project_dir="${3:-}" outfile="${4:-}"
  [ -n "$outfile" ] || return 1
  printf '%s' "$payload" | \
    ZENSU_REDACT_LIB="$redact_lib" \
    ZENSU_REDACT_PROJECT="$project_dir" \
    node -e '
  const chunks = [];
  let redact = (v) => v;
  try {
    const mod = require(process.env.ZENSU_REDACT_LIB);
    // Both candidate roots, for the same reason `append` passes both: the two
    // writers derive the root from different authorities and must substitute
    // identically or the equality match reports an EVIDENCE GAP.
    const opts = {
      projectRoot: [
        process.env.ZENSU_REDACT_PROJECT || "",
        process.env.CLAUDE_PROJECT_DIR || "",
      ].filter(Boolean),
      // The module resolution, not a hand-copy: rule 2 is half of the
      // substitution the two writers must agree on, and zensu-log.sh append
      // calls mod.defaultHome(). A divergence here is an EVIDENCE GAP.
      home: mod.defaultHome(),
    };
    if (typeof mod.redact !== "function" || typeof mod.defaultHome !== "function") {
      throw new Error("redactor exports missing");
    }
    // The fallback must wrap the CALL, not just the load: a throw from redact
    // would otherwise reach the outer handler, which emits an empty session
    // field and drops the whole witness ENTRY — fail-CLOSED, and the opposite
    // of what the comment above promises.
    redact = (v) => { try { return mod.redact(v, opts); } catch (_) { return v; } };
  } catch (_) { /* fail open: an unredacted line beats a missing one */ }
  // Buffers, then one decode: a per-chunk decode corrupts a multi-byte character
  // that straddles a chunk boundary, and `cmd` is matched by EQUALITY.
  process.stdin.on("data", c => chunks.push(Buffer.from(c)));
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      const cmd = (j.tool_input && typeof j.tool_input.command === "string") ? redact(j.tool_input.command) : "";
      const exit = (j.tool_response && typeof j.tool_response.exit_code === "number") ? String(j.tool_response.exit_code) : "?";
      const stdout = (j.tool_response && typeof j.tool_response.stdout === "string") ? j.tool_response.stdout : "";
      const tail = stdout.slice(-200);
      const interrupted = (j.tool_response && j.tool_response.interrupted === true) ? "true" : "false";
      const session = (typeof j.session_id === "string" && j.session_id) ? j.session_id : "";
      process.stdout.write(JSON.stringify(cmd) + "\n" + exit + "\n" + JSON.stringify(tail) + "\n" + interrupted + "\n" + session + "\n");
    } catch (_) { process.stdout.write("\"\"\n?\n\"\"\nfalse\n\n"); }
  });
' > "$outfile" 2>/dev/null
}
