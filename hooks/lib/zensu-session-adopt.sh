#!/bin/bash
# zensu-session-adopt.sh — report on, and optionally perform, the adoption of an
# intact Session Control record by a declared-incompatible executing runtime.
#
# This is the SECOND script the PreToolUse Bash gates recognize in a bind
# failure, and it differs from the first in the one way that matters: the
# diagnostic writes nothing, and this WRITES. The widening therefore does not
# inherit /zensu:doctor's justification and needs its own, stated here because
# hooks/lib/zensu-doctor-invocation.js points at this header:
#
#   - The only write is one record for THIS session, in the private plugin-data
#     store, plus one workflow history entry in the recorded project. It cannot
#     name a path: every location is derived from the record it is adopting.
#   - It refuses unless every adoptableRecord condition holds, and those
#     conditions re-verify the record against its own recorded root — a forged
#     or hand-edited record never reaches the write.
#   - It cannot reach project source files, cannot run a build or a test, and
#     takes no argument other than the single literal `--confirm`.
#   - Without `--confirm` it is strictly read-only and answers the same question
#     the doctor row asks.
#
# What it does NOT do: relax runtimeLineageCompatible, rewrite any record (the
# superseded one is set aside under a new name and stays readable), touch the
# workflow document's decision fields, or relax plugin_data. A session whose
# persisted shapes really did change is refused, by construction — validateContext
# and validateWorkflowState enforce the two schema constants, so a real break
# makes the record or the document unreadable and adoption declines.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || {
  printf '%s\n' 'zensu:adopt-session: cannot resolve the plugin library directory' >&2
  exit 1
}
PLUGIN_ROOT="$(cd "$DIR/../.." && pwd -P)" || {
  printf '%s\n' 'zensu:adopt-session: cannot resolve the executing plugin root' >&2
  exit 1
}
CORE="$DIR/session-control-core-v1.js"
[ -f "$CORE" ] && [ ! -L "$CORE" ] || {
  printf '%s\n' 'zensu:adopt-session: the Session Control runtime is missing or symlinked; repair the Zensu plugin installation' >&2
  exit 1
}

CONFIRM=0
case "${1:-}" in
  '') ;;
  --confirm) CONFIRM=1 ;;
  *)
    printf '%s\n' 'zensu:adopt-session: the only supported argument is --confirm' >&2
    exit 2
    ;;
esac
[ "$#" -le 1 ] || {
  printf '%s\n' 'zensu:adopt-session: the only supported argument is --confirm' >&2
  exit 2
}

command -v node >/dev/null 2>&1 || {
  printf '%s\n' 'zensu:adopt-session: node is not available, so Session Control cannot be read' >&2
  exit 1
}
[ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || {
  printf '%s\n' 'zensu:adopt-session: CLAUDE_CODE_SESSION_ID is unset, so this session cannot be identified' >&2
  exit 1
}
[ -n "${CLAUDE_PLUGIN_DATA:-}" ] || {
  printf '%s\n' 'zensu:adopt-session: CLAUDE_PLUGIN_DATA is unset, so the record store cannot be located' >&2
  exit 1
}
[ -n "${CLAUDE_PROJECT_DIR:-}" ] || {
  printf '%s\n' 'zensu:adopt-session: CLAUDE_PROJECT_DIR is unset, so the recorded project cannot be checked' >&2
  exit 1
}

# Both crossings into native Node go through the host-path renderer, exactly as
# every other stateful helper does, and are excluded from Git Bash's heuristic
# environment conversion so a drive spelling is not reinterpreted twice.
# shellcheck disable=SC1090
source "$DIR/zensu-session.sh" >/dev/null 2>&1 || {
  printf '%s\n' 'zensu:adopt-session: the Session Control shell library is unavailable' >&2
  exit 1
}
NATIVE_PLUGIN_ROOT="$(bash "$DIR/zensu-host-path.sh" "$PLUGIN_ROOT")" || exit 1
NATIVE_PLUGIN_DATA="$(bash "$DIR/zensu-host-path.sh" "$CLAUDE_PLUGIN_DATA")" || exit 1
NATIVE_PROJECT_DIR="$(bash "$DIR/zensu-host-path.sh" "$CLAUDE_PROJECT_DIR")" || exit 1
MSYS_EXCL="$(zensu_msys_env_exclusions ZADOPT_PLUGIN_ROOT ZADOPT_PLUGIN_DATA ZADOPT_PROJECT_DIR)" \
  || exit 1

cd -P -- "$DIR" || exit 1
MSYS2_ENV_CONV_EXCL="$MSYS_EXCL" \
ZADOPT_PLUGIN_ROOT="$NATIVE_PLUGIN_ROOT" \
ZADOPT_PLUGIN_DATA="$NATIVE_PLUGIN_DATA" \
ZADOPT_PROJECT_DIR="$NATIVE_PROJECT_DIR" \
ZADOPT_SESSION_ID="$CLAUDE_CODE_SESSION_ID" \
ZADOPT_CONFIRM="$CONFIRM" \
node -e '
const path = require("node:path");
const core = require("./session-control-core-v1.js");

const pluginRoot = process.env.ZADOPT_PLUGIN_ROOT;
const pluginData = process.env.ZADOPT_PLUGIN_DATA;
const projectRoot = process.env.ZADOPT_PROJECT_DIR;
const sessionId = process.env.ZADOPT_SESSION_ID;
const recordsDir = path.join(pluginData, "session-control", "v1", "records");
const request = {
  recordsDir,
  sessionId,
  host: "claude",
  pluginData,
  projectRoot,
  executingPluginRoot: pluginRoot,
};

// Every refusal names the condition that was not met, and every one of them has
// a different remedy. A generic "not adoptable" would put the user back where
// the misleading doctor row left them.
const REMEDY = {
  [core.ADOPTION_REFUSALS.RECORD_UNREADABLE]:
    "The record could not be re-verified against the installation that minted it. That installation may have been pruned from the plugin cache, the record may have been altered, or a persisted schema really did change in this release. Start a fresh Claude Code session.",
  [core.ADOPTION_REFUSALS.PLUGIN_DATA]:
    "The record belongs to a different plugin-data store — typically a development checkout against an installed plugin, or the reverse. That boundary is never relaxed. Start a fresh Claude Code session.",
  [core.ADOPTION_REFUSALS.PROJECT_ROOT]:
    "The recorded project root is not this directory. Run this from the project the session was started in, or start a fresh Claude Code session.",
  [core.ADOPTION_REFUSALS.ALREADY_SERVED]:
    "Nothing to adopt: this installation already serves the record. If tools are still failing, the cause is a different one — run /zensu:doctor.",
  [core.ADOPTION_REFUSALS.NOT_SIBLING]:
    "The executing installation is not a sibling of the one that minted the record, so it cannot be an upgrade of it. A --plugin-dir checkout never adopts an installed session. Start a fresh Claude Code session.",
  [core.ADOPTION_REFUSALS.EXECUTING_UNIDENTIFIED]:
    "The executing installation does not declare a usable version, so no lineage judgement is possible. Repair the plugin installation; /zensu:doctor reports plugin integrity.",
  [core.ADOPTION_REFUSALS.BACKWARDS]:
    "The executing installation is OLDER than the one that minted the record. Only a newer runtime may take over an older one's state, never the reverse. Re-install the newer version, or start a fresh Claude Code session.",
  [core.ADOPTION_REFUSALS.WORKFLOW_SCHEMA]:
    "This session's workflow document cannot be read by the executing runtime, which means a persisted shape really did change. This is the case adoption must refuse. Start a fresh Claude Code session.",
};

const verdict = core.adoptableRecord(request);
if (!verdict.ok) {
  process.stdout.write("Zensu session adoption — NOT adoptable (" + verdict.reason + ")\n\n");
  process.stdout.write((REMEDY[verdict.reason] || "No remedy is known for this refusal. Start a fresh Claude Code session.") + "\n");
  process.exitCode = 1;
  return;
}

if (process.env.ZADOPT_CONFIRM !== "1") {
  process.stdout.write("Zensu session adoption — ADOPTABLE\n\n");
  process.stdout.write("  record minted by : " + verdict.recorded + "\n");
  process.stdout.write("  executing        : " + verdict.executing + "\n");
  process.stdout.write("  project          : " + verdict.context.project_root + "\n\n");
  process.stdout.write("The record is intact and this installation can take it over in place.\n");
  process.stdout.write("Nothing has been changed. Run the same command with --confirm to adopt.\n");
  return;
}

const adopted = core.adoptContext(request);
process.stdout.write("Zensu session adoption — ADOPTED\n\n");
process.stdout.write("  record minted by : " + adopted.recorded + "\n");
process.stdout.write("  now served by    : " + adopted.executing + "\n");
process.stdout.write("  superseded record: " + adopted.supersededFile + "\n");
process.stdout.write("  provenance       : " + adopted.provenance + "\n");
process.stdout.write("  leases set aside : " + adopted.leasesDiscarded + "\n\n");
process.stdout.write("This session is bound again from the next tool call onward — no restart is needed.\n");
if (adopted.provenance !== "recorded") {
  process.stdout.write("\nWARNING: the adoption succeeded but its provenance entry could not be written.\n");
  process.stdout.write("The takeover is real and unrecorded in the workflow history; report this rather than repeating it.\n");
}
if (adopted.leasesDiscarded > 0) {
  process.stdout.write("\nNOTE: " + adopted.leasesDiscarded + " review-evidence lease(s) were set aside because they name the previous\n");
  process.stdout.write("installation. Any review evidence they reserved has to be gathered again.\n");
}
'
