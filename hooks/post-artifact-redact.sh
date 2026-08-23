#!/bin/bash
set -u

# PostToolUse redactor for the two .zensu run artifacts consuming repos commit:
# the plan `.zensu/plans/{ts}_tdd-{slug}.md` and the narrative log
# `.zensu/logs/{ts}_tdd-{slug}.log`.
#
# `zensu-log.sh append` is the WRITER-side chokepoint and does the real work.
# This hook is the net under it, and it exists because the two artifacts are
# authored by the model, not by the plugin: the plan goes through the Write tool
# with a body this plugin never sees, and a log line can still be appended by a
# hand-rolled `printf >>` that never reaches the helper. A guarantee that holds
# only while the model follows a recipe is not a guarantee.
#
# It is a decision-free hook: every path after the plugin-root identity check
# exits 0. A PostToolUse hook cannot un-run the tool call it follows, so failing
# closed here would block a call for a defect it cannot repair. The plugin-root
# guard is the one exception, and deliberately so: an inherited
# CLAUDE_PLUGIN_ROOT that does not match the executing script means the whole
# preamble is untrustworthy, which is the same stance every other hook takes. It is NOT silent, though — a refusal that leaves an
# artifact un-redacted is written to stderr, because an oversized or hard-linked
# artifact shipping with `/Users/<name>/…` intact and nothing recording it is
# the worst outcome this hook can produce.
#
# Scope. BOTH registered matchers sweep the artifacts modified in the last
# `SWEEP_WINDOW_SECONDS`; the write matchers ADDITIONALLY redact the tool's own
# `tool_input.file_path`. Sweeping on the write matchers is not redundancy: this
# hook is main-principal only, so a SUBAGENT-written artifact is reachable only
# from a later main-thread pass, and more sampling points mean more chances to
# catch one inside its own window. It does NOT extend any deadline — the cutoff
# is the artifact's own mtime and nothing here touches it.
#
# The named path is not redundant either: `sweepTargets` filters on the bucket's
# extension, while `resolveArtifactTarget` does not, so a write to something like
# `.zensu/logs/notes.txt` is reachable only through the named path.
#
# Both the sweep's candidate set and the containment check live in
# `hooks/lib/zensu-artifact-redact-v1.js` — the module declares itself the owner
# of the artifact layout, so this hook consumes that table rather than
# re-spelling it. The mtime window bounds the WORK — which artifacts are read
# and redacted — and not the enumeration: an entry's mtime is not knowable
# without a stat, so a candidate regular file costs one syscall before the cutoff
# can reject it. An earlier revision of this header claimed the window is what
# keeps the sweep cheap in a repo holding hundreds of tracked plans, which was
# not true. What bounds the sweep is `SWEEP_MAX_TARGETS` in the module.
# Artifacts from earlier runs are out of reach on purpose, since this is a
# writer-side fix and not a history rewrite.
#
# Bounds, stated rather than implied. This net is disabled entirely while the
# session cannot bind its Session Control record — an unregistered session, or a
# record whose project root is gone — and while the caller is not the main
# principal. The first is reported on stderr; the second is not, for the reason
# given at the guard. It is also bounded by `SWEEP_MAX_TARGETS` per invocation
# and by the mtime window, so an artifact nothing touches again is not reached. There is
# deliberately NO command-text pre-filter: `printf … >> "$LOG"` carries no
# `.zensu` substring, and a net that the one spelling it exists to catch can
# evade is not a net.

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 2
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _ZENSU_DECLARED_PLUGIN_ROOT="$(cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || {
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  }
  if [ "$_ZENSU_DECLARED_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  fi
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT _ZENSU_DECLARED_PLUGIN_ROOT

INPUT="$(cat 2>/dev/null || true)"
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-agent-context.sh"
# The principal check stays SILENT on purpose. A subagent tool call is the
# ordinary outcome of a `.*`-shaped matcher, not a refusal, and a note here would
# print on every one of them. Nothing is left un-redacted by it either: an
# artifact a subagent wrote is reached by the next main-thread pass, which is
# exactly why both matchers sweep.
zensu_hook_is_main_principal "$INPUT" PostToolUse || exit 0
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
# A bind refusal is a different thing and is REPORTED. It disables this net for
# the whole session — every artifact then ships with whatever the model wrote —
# and the header above promises that a refusal leaving an artifact un-redacted
# reaches stderr. Exiting 0 in silence made that promise false in the one state
# where it matters most.
if ! zensu_bind_hook_session "$INPUT"; then
  echo "zensu: artifact redactor unavailable (session bind refused) — .zensu artifacts are not redacted for this call" >&2
  exit 0
fi

if ! command -v node >/dev/null 2>&1; then
  echo "zensu: artifact redactor unavailable (node is not on PATH)" >&2
  exit 0
fi

# Module transport, mechanism 2 of the two this repo accepts (see
# tests/structure/test-msys-special-plugin-module-boundaries.sh): render the lib
# DIRECTORY through zensu-host-path.sh — which rejects a file path — append the
# file name, guard the result, and carry it in an environment variable. Handing
# `node` a raw MSYS spelling would make `require()` fail on a Git Bash root, and
# the load-failure branch below would then silently skip every redaction.
ZENSU_REDACT_LIB_DIR="$(bash "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-host-path.sh" \
  "$CLAUDE_PLUGIN_ROOT/hooks/lib")" || ZENSU_REDACT_LIB_DIR=""
REDACT_LIB="$ZENSU_REDACT_LIB_DIR/zensu-artifact-redact-v1.js"
if [ -z "$ZENSU_REDACT_LIB_DIR" ] || [ ! -f "$REDACT_LIB" ] || [ -L "$REDACT_LIB" ]; then
  echo "zensu: artifact redactor unavailable (module path unresolvable)" >&2
  exit 0
fi

if ! PROJECT_DIR="$(zensu_resolve_project_dir)"; then
  echo "zensu: artifact redactor unavailable (no bound project)" >&2
  exit 0
fi

printf '%s' "$INPUT" | \
  ZENSU_REDACT_LIB="$REDACT_LIB" \
  ZENSU_REDACT_PROJECT="$PROJECT_DIR" \
  node -e '
  // Buffers, then one decode: `payload += chunk` decodes each chunk on its own
  // and corrupts any multi-byte character straddling a 64 KiB boundary, which a
  // Write payload routinely crosses.
  const chunks = [];
  process.stdin.on("data", (c) => { chunks.push(Buffer.from(c)); });
  process.stdin.on("end", () => {
    let mod;
    try {
      mod = require(process.env.ZENSU_REDACT_LIB);
    } catch (err) {
      process.stderr.write("zensu: artifact redactor unavailable (" + (err && err.code) + ")\n");
      return;
    }

    const project = process.env.ZENSU_REDACT_PROJECT || "";
    if (!project) return;

    let job;
    try { job = JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch (_) { return; }
    const tool = typeof job.tool_name === "string" ? job.tool_name : "";

    // The tool whitelist stays, and it does two jobs: only a write tool may name
    // a payload path, and this disjunction is the fifth independent spelling of
    // the registered matcher — the one a `NotebookEdit` added to `hooks.json`
    // would silently miss.
    const writeTool = tool === "Edit" || tool === "Write" || tool === "MultiEdit";
    if (tool !== "Bash" && !writeTool) return;

    // Always sweep; prepend the named file when the payload carries one. The
    // sweep must not be conditional on a usable `file_path` — that was the one
    // shape the subagent coverage exists for.
    const named = writeTool && job.tool_input && typeof job.tool_input.file_path === "string"
      ? job.tool_input.file_path : "";
    const swept = mod.sweepTargets(project);
    // Deduplicated on the RESOLVED path: the named file is normally in the sweep
    // set too (it was just written), and without this a refusal would be
    // reported twice: once under the caller spelling, once under the sweep one.
    const seen = new Set();
    const targets = [];
    for (const entry of named ? [{ p: named, named: true }, ...swept.map((p) => ({ p, named: false }))]
      : swept.map((p) => ({ p, named: false }))) {
      const key = require("node:path").resolve(project, entry.p);
      if (seen.has(key)) continue;
      seen.add(key);
      targets.push(entry);
    }

    for (const entry of targets) {
      const target = entry.p;
      // expectedRoot binds the destination to THIS session: the module
      // canonicalizes the artifact directory and the derived root before it
      // opens anything, so a symlinked .zensu/logs cannot carry the rewrite out
      // of the project. A path that is simply not an artifact of this project
      // is not a fault when the tool NAMED it — see the provenance check below.
      let result;
      try {
        // BOTH candidate roots, the same pair `zensu-log.sh append` and
        // `post-bash-witness.sh` pass. A sweep with a root set of its own is a
        // THIRD redactor: it can rewrite a narrative claim in a way the witness
        // entry was not, and `zensu-evidence-crosscheck.js` matches those two by
        // EQUALITY — so the divergence mints an evidence gap that no later sweep
        // can repair, because both files are already written. `redactFile` adds
        // the artifact-derived root itself, so this pair makes the sweep apply
        // the UNION of what the two writers applied.
        //
        // `expectedRoot` is deliberately NOT widened with it: that is the
        // containment bound, and it stays the record root alone.
        result = mod.redactFile(target, {
          projectRoot: [project, process.env.CLAUDE_PROJECT_DIR || ""].filter(Boolean),
          expectedRoot: project,
          base: project,
        });
      } catch (err) {
        process.stderr.write(
          "zensu: artifact redaction threw for " + target + " (" + (err && err.code) + ")\n");
        continue;
      }
      // The module owns the WHOLE reason vocabulary, partitioned explicitly.
      // Re-spelling any part of it here would make a renamed reason shout
      // "artifact left UNREDACTED" on every ordinary Write, and an implicit
      // residual class made a routine race report as the worst outcome.
      if (mod.CLEAN_REASONS.has(result.reason)) continue;
      if (mod.TRANSIENT_REASONS.has(result.reason)) continue;
      // Refused BY DESIGN, on either route and regardless of provenance: the
      // module declined to touch the file on purpose, so there is nothing to
      // report. Three sets were not a partition — `witness-artifact` fell
      // through all of them and printed "artifact left UNREDACTED" for a refusal
      // the design intends. Optional-chained so an older module that predates
      // the set degrades to the previous behaviour (a spurious line) rather than
      // throwing, which would silence the redactor for the whole call.
      if (mod.DESIGN_REFUSAL_REASONS?.has(result.reason)) continue;
      // Keyed on PROVENANCE, not on the matcher. "This path is not an artifact"
      // is an ordinary outcome for the file a write tool NAMED — that matcher
      // sees every file the model writes, and a genuine fault for a path the
      // sweep itself produced. Keying it on the tool gave the same fact two
      // different answers depending on which matcher fired.
      if (entry.named && mod.NON_ARTIFACT_REASONS.has(result.reason)) continue;
      process.stderr.write("zensu: artifact left UNREDACTED"
        + (entry.named ? "" : " (sweep)") + " — " + target + " (" + result.reason + ")\n");
    }
  });
' >/dev/null || true

exit 0
