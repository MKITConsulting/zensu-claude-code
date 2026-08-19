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
#   - THREE write classes, all confined: one record for THIS session in the
#     private plugin-data store; one workflow history entry in the recorded
#     project; and any review-evidence lease naming the previous installation,
#     MOVED (never deleted) out of that session's own lease records directory
#     into a sibling `superseded/` one. The selector is broader than "names the
#     previous installation" and narrower than "everything listRecords rejects":
#     the keep-predicate is a SUPERSET of that reader's accept set, mirroring three
#     of its conjuncts, so a stale lease, one whose id disagrees with its filename,
#     a malformed record and a non-.json leftover are all moved — while an entry
#     that fails only the checks NOT mirrored (symlinked or multiply-linked,
#     non-canonical, oversized, otherwise validateRecord-invalid) and still names
#     the executing root is KEPT, and keeps wedging later lease operations. That
#     residual is documented in the core beside the predicate. Nothing else, and
#     nothing outside <plugin_data>/{session-control,review-evidence} and the
#     recorded project.
#   - What BOUNDS that write is not derivation — CLAUDE_PLUGIN_DATA is a
#     caller-supplied literal, exactly as it is for the diagnostic — it is
#     readContext: the session-hash must match, the
#     runtime digest is recomputed against the RECORDED root, and that root's
#     manifest must still declare the recorded version. Add the sibling-root
#     bound and the plugin_data equality check, and a record the caller authored
#     under a directory it controls cannot reach the write for a session it does
#     not already own. State it this way and not as "every location is derived
#     from the record": that is the stronger claim, and it is not what the code
#     enforces.
#   - It refuses unless every adoptableRecord condition holds.
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
# The binder is loaded from inside the node payload for its private-store
# constructor, so it gets the same guard the core does — zensu-session.sh applies
# it to this exact file at three sites, and a symlinked binder must not be the one
# library this write-capable script loads unchecked.
BINDER="$DIR/claude-hook-session-v1.js"
[ -f "$BINDER" ] && [ ! -L "$BINDER" ] || {
  printf '%s\n' 'zensu:adopt-session: the Session Control binder is missing or symlinked; repair the Zensu plugin installation' >&2
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
# CLAUDE_PROJECT_DIR is deliberately NOT required, and is not read at all. It was
# required once, and rendered through the host-path script, which rejects a path
# that is not a directory — so a session whose harness project dir had been
# deleted exited here, before any report, in exactly the state this command
# exists to diagnose. adoptableRecord no longer judges the caller's project root:
# the anchor is carried from the record, and every write below is bounded by
# readContext, the sibling-root check and plugin_data. The recognizer still
# ACCEPTS the assignment, because the diagnostic reads it and the two share one
# set — this script simply ignores it.

# Both crossings into native Node go through the host-path renderer, as every
# other stateful helper does, and are excluded from Git Bash's heuristic
# environment conversion so a drive spelling is not reinterpreted twice.
# shellcheck disable=SC1090
source "$DIR/zensu-session.sh" >/dev/null 2>&1 || {
  printf '%s\n' 'zensu:adopt-session: the Session Control shell library is unavailable' >&2
  exit 1
}
NATIVE_PLUGIN_ROOT="$(bash "$DIR/zensu-host-path.sh" "$PLUGIN_ROOT")" || exit 1
NATIVE_PLUGIN_DATA="$(bash "$DIR/zensu-host-path.sh" "$CLAUDE_PLUGIN_DATA")" || exit 1
MSYS_EXCL="$(zensu_msys_env_exclusions ZADOPT_PLUGIN_ROOT ZADOPT_PLUGIN_DATA)" || {
  printf '%s\n' 'zensu:adopt-session: the host-path environment library is unavailable; repair the Zensu plugin installation' >&2
  exit 1
}

cd -P -- "$DIR" || exit 1
MSYS2_ENV_CONV_EXCL="$MSYS_EXCL" \
ZADOPT_PLUGIN_ROOT="$NATIVE_PLUGIN_ROOT" \
ZADOPT_PLUGIN_DATA="$NATIVE_PLUGIN_DATA" \
ZADOPT_SESSION_ID="$CLAUDE_CODE_SESSION_ID" \
ZADOPT_CONFIRM="$CONFIRM" \
node -e '
const path = require("node:path");
const core = require("./session-control-core-v1.js");

const pluginRoot = process.env.ZADOPT_PLUGIN_ROOT;
const pluginData = process.env.ZADOPT_PLUGIN_DATA;
const sessionId = process.env.ZADOPT_SESSION_ID;
// The binder OWNS the private-store constructor, and this uses it rather than a
// hand-joined path: it additionally rejects a records directory that is a
// symlink, an alias, group- or world-accessible, or owned by another user.
// Skipping those checks would let the repair mint a record into a store that the
// very next tool call refuses for exactly those reasons — a false success, and a
// new record sitting somewhere another local user can rewrite it.
//
// Resolved INSIDE main(), never at module top level: all five of its refusal
// conditions throw, and a throw out here would escape the handler below and print
// a raw stack trace — in the one state where every other channel is already
// denied, and where those conditions are exactly the diagnosis the user needs
// stated plainly.
const privateRecordsDirectory = require("./claude-hook-session-v1.js").privateRecordsDirectory;
const buildRequest = () => ({
  recordsDir: privateRecordsDirectory(pluginData),
  sessionId,
  host: "claude",
  pluginData,
  executingPluginRoot: pluginRoot,
});

// The recorded project root is echoed into a terminal AND into the model context,
// and the strict read constrains it less than that use deserves: validateContext
// rejects only NUL, CR and LF there, while the sibling readOrphanedProjectRootContext
// rejects the whole C0-plus-DEL class for exactly this reason. So print the plain
// path when it is plain and a JSON-escaped one when it is not: an escape sequence in
// a directory name must not be able to rewrite or hide the one line that says which
// project is being taken over. The normal path is unchanged, which is what keeps the
// report greppable. Built with RegExp from a string so the pattern survives every
// layer this payload travels through as source text.
// A POSITIVE allowlist, and every non-constant field in the report goes through it.
// A deny class was the first attempt and it was wrong in both directions: it caught
// U+007F, which JSON.stringify does NOT escape, and it missed the bidi overrides and
// U+2028, which are exactly what could hide the line naming the project being taken
// over. It was also applied to two fields while provenance, the superseded filename,
// the stuck-lease names and the error messages carried the same filesystem-derived
// text raw. So: anything outside the set below is JSON-escaped AND folded to ASCII,
// because JSON.stringify alone leaves every non-ASCII code point intact. Deliberately
// no single quote in the class - this whole payload is a single-quoted shell string.
// The class admits a space and a colon, and the project line is the LAST field of
// the read-only block, so a run of spaces would let a directory name forge further
// "label : value" pairs after it — and the skill keys real behaviour off exactly
// those pairs. Nothing in an ordinary path carries a double space, so requiring one
// space at a time costs nothing and closes the forgery.
const SAFE_DISPLAY = new RegExp("^[A-Za-z0-9 _.,:;/\\\\@+~()=-]*$");
const DOUBLE_SPACE = new RegExp("  ");
const NON_ASCII = new RegExp("[\\u007f-\\uffff]", "g");
const safe = (value) => {
  const text = String(value);
  if (SAFE_DISPLAY.test(text) && !DOUBLE_SPACE.test(text)) return text;
  return JSON.stringify(text).replace(NON_ASCII, (c) =>
    "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0"));
};

// Every refusal names the condition that was not met, and every one of them has
// a different remedy. A generic "not adoptable" would put the user back where
// the misleading doctor row left them.
const REMEDY = {
  [core.ADOPTION_REFUSALS.RECORD_UNREADABLE]:
    "The record could not be re-verified against the installation that minted it. Its recorded project root may be gone, that installation may have been pruned from the plugin cache, the record may have been altered, or a persisted schema really did change in this release. Adoption cannot tell these apart, and in this state /zensu:doctor cannot name the directory either. Start a fresh Claude Code session.",
  [core.ADOPTION_REFUSALS.PLUGIN_DATA]:
    "The record belongs to a different plugin-data store — typically a development checkout against an installed plugin, or the reverse. That boundary is never relaxed. Start a fresh Claude Code session.",
  [core.ADOPTION_REFUSALS.ALREADY_SERVED]:
    "Nothing to adopt: this installation already serves the record. If tools are still failing, the cause is a different one — run /zensu:doctor.",
  [core.ADOPTION_REFUSALS.NOT_SIBLING]:
    "The executing installation is not a sibling of the one that minted the record, so it cannot be an upgrade of it. A --plugin-dir checkout never adopts an installed session. Start a fresh Claude Code session.",
  [core.ADOPTION_REFUSALS.EXECUTING_UNIDENTIFIED]:
    "The executing installation does not declare a usable version, so no lineage judgement is possible. Repair the plugin installation; /zensu:doctor reports plugin integrity.",
  [core.ADOPTION_REFUSALS.BACKWARDS]:
    "The executing installation is OLDER than the one that minted the record. Only a newer runtime may take over the state of an older one, never the reverse. Re-install the newer version, or start a fresh Claude Code session.",
  [core.ADOPTION_REFUSALS.WORKFLOW_SCHEMA]:
    "The workflow document of this session cannot be read by the executing runtime, which means a persisted shape really did change. This is the case adoption must refuse. Start a fresh Claude Code session.",
};

// Wrapped in a function because `node -e` evaluates at module top level, where a
// bare `return` is a syntax error — and a syntax error here would surface as a
// crashed helper rather than as the refusal it was meant to print.
function main() {
  let request;
  try {
    request = buildRequest();
  } catch (error) {
    process.stdout.write("Zensu session adoption — NOT adoptable (private-record-store-unsafe)\n\n");
    process.stdout.write("The private Session Control record store could not be opened safely: "
      + safe(error && error.message ? error.message : "unknown") + "\n");
    process.stdout.write("It is missing, aliased, or has unsafe permissions or ownership. Repair the store\n");
    process.stdout.write("or start a fresh Claude Code session; adoption cannot mint a record into it.\n");
    process.exitCode = 1;
    return;
  }
  const verdict = core.adoptableRecord(request);
  if (!verdict.ok) {
    process.stdout.write("Zensu session adoption — NOT adoptable (" + safe(verdict.reason) + ")\n\n");
    process.stdout.write((REMEDY[verdict.reason] || "No remedy is known for this refusal. Start a fresh Claude Code session.") + "\n");
    process.exitCode = 1;
    return;
  }

  if (process.env.ZADOPT_CONFIRM !== "1") {
    process.stdout.write("Zensu session adoption — ADOPTABLE\n\n");
    process.stdout.write("  record minted by : " + safe(verdict.recorded) + "\n");
    process.stdout.write("  executing        : " + safe(verdict.executing) + "\n");
    process.stdout.write("  project          : " + safe(verdict.context.project_root) + "\n\n");
    process.stdout.write("The record is intact and this installation can take it over in place.\n");
    process.stdout.write("Nothing has been changed. Run the same command with --confirm to adopt.\n");
    return;
  }

  const adopted = core.adoptContext(request);
  process.stdout.write("Zensu session adoption — ADOPTED\n\n");
  process.stdout.write("  record minted by : " + safe(adopted.recorded) + "\n");
  process.stdout.write("  now served by    : " + safe(adopted.executing) + "\n");
  // The anchor the session is bound to from here on. It is carried from the
  // record, never from where this command was invoked, and naming it is the one
  // place the user learns which project that actually is.
  process.stdout.write("  project          : " + safe(adopted.projectRoot) + "\n");
  process.stdout.write("  superseded record: " + safe(adopted.supersededFile) + "\n");
  process.stdout.write("  provenance       : " + safe(adopted.provenance) + "\n");
  process.stdout.write("  leases set aside : " + adopted.leasesDiscarded + "\n");
  process.stdout.write("  leases stuck     : " + adopted.leasesFailed.length + "\n\n");
  process.stdout.write("This session is bound again from the next tool call onward — no restart is needed.\n");
  if (adopted.provenance === "no-workflow-document") {
    process.stdout.write("\nNOTE: this session had no workflow document, so there was nothing to record the\n");
    process.stdout.write("takeover in. That is a normal state, not a fault.\n");
  } else if (adopted.provenance !== "recorded") {
    process.stdout.write("\nWARNING: the adoption succeeded but its provenance entry could not be written.\n");
    process.stdout.write("The takeover is real and unrecorded in the workflow history; report this rather than repeating it.\n");
  }
  if (adopted.leasesDiscarded > 0) {
    process.stdout.write("\nNOTE: " + adopted.leasesDiscarded + " review-evidence lease(s) were set aside because they name the previous\n");
    process.stdout.write("installation. Any review evidence they reserved has to be gathered again.\n");
  }
  if (adopted.leasesUnsafe) {
    // Names the directory that actually failed. Both cases stop the sweep, but they
    // sit in different places and mean different things: a refused DESTINATION is
    // the shared superseded/ directory, which the sweep only ever writes to — a
    // planted link there is an active tamper signal, and pointing the operator at
    // the records directory the sweep had just read successfully left it
    // uninvestigated.
    if (adopted.leasesUnsafeScope === "destination") {
      process.stdout.write("\nWARNING: the review-evidence SUPERSEDED directory could not be opened safely,\n");
      process.stdout.write("so no lease was set aside. It is <plugin_data>/review-evidence/v1/superseded/<session key>,\n");
      process.stdout.write("and it is a directory this plugin only writes to. Two causes produce this: an entry\n");
      process.stdout.write("there that is not a plain directory you own — which is a tamper signal — or an\n");
      process.stdout.write("ordinary I/O failure such as a full or read-only store. Look before repeating this.\n");
    } else if (adopted.leasesUnsafeScope === "source") {
      process.stdout.write("\nWARNING: the review-evidence lease RECORDS directory of this session could not be\n");
      process.stdout.write("opened safely, so no lease was inspected or set aside. Same two causes as above: an\n");
      process.stdout.write("entry that is not a plain directory you own, or an I/O failure. If any lease there\n");
      process.stdout.write("names the previous installation, review-evidence operations keep failing until it is\n");
      process.stdout.write("moved out by hand.\n");
    } else {
      // Neither scope: a core that still reports the old bare boolean. Naming one
      // directory here would re-create the misdirection this branch exists to fix,
      // so say what is known and name both candidates.
      process.stdout.write("\nWARNING: the review-evidence lease store could not be opened safely, so no lease was\n");
      process.stdout.write("inspected or set aside. This runtime did not report which directory it refused —\n");
      process.stdout.write("check both <plugin_data>/review-evidence/v1/records/<session key> and .../superseded/<session key>.\n");
    }
  }
  if (adopted.leasesFailed.length > 0) {
    process.stdout.write("\nWARNING: " + adopted.leasesFailed.length + " review-evidence lease(s) could NOT be set aside: " + adopted.leasesFailed.map(safe).join(", ") + "\n");
    process.stdout.write("They still name the previous installation, and because every lease read validates the\n");
    process.stdout.write("whole set, review-evidence operations will keep failing for this session until they are\n");
    process.stdout.write("moved out of the records directory by hand. The adoption itself is complete.\n");
  }
}

try {
  main();
} catch (error) {
  process.stderr.write("zensu:adopt-session: " + safe(error && error.message ? error.message : "unknown failure") + "\n");
  process.exitCode = 1;
}
'
