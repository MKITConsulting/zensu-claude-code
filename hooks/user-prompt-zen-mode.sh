#!/bin/bash
# UserPromptSubmit hook — zen-mode re-injection. While zen-mode resolves to active
# for the current session, this hook injects the mode contract as additionalContext
# on every prompt. A skill is loaded once and fades after a handful of turns; a
# low-capacity user is the least likely to notice that drift, so the reminder rides
# along with each prompt instead.
#
# Resolution is three-valued, most specific first:
#   1. session marker `{"active":true|false}` — the choice this session recorded,
#      through /zensu:zen-mode, hooks/lib/zensu-zen-mode.sh, or the off-branch below
#   2. hooks.zenModeDefault — the configured default, itself defaulting to TRUE
# A symlinked marker or state directory, and a marker that does not spell out an
# active mode, both resolve to OFF: unreadable state must never impose the mode on
# a user who may have just left it.
#
# Deactivation is handled HERE rather than by the model: a prompt matching the
# off-phrases writes `{"active":false}` directly, so "normal mode" still works
# after the model has drifted. It WRITES rather than deletes on purpose — under a
# true default, removing the marker would re-enable the mode the user just left.
# The marker is keyed by the resolved Session Control key, so a fresh session
# always starts from the configured default and one session's choice never leaks
# into another.
#
# The marker root comes from zensu_resolve_project_dir, the same accessor the
# writer uses. It is deliberately NOT $ZENSU_PROJECT_ROOT: Session Control records
# the host-native path, which on Git Bash is a different namespace from the MSYS
# spelling shell builtins need, so concatenating the raw root here would have the
# hook stat a path the helper never wrote.
#
# Disable the hook entirely with hooks.zenMode:false in .zensu/config.json, or
# keep it and flip the default off with hooks.zenModeDefault:false — both are
# resolved through the usual env -> project-local -> global order. Every path after
# the plugin-root identity check exits 0 — missing node, unbindable session, absent
# marker, or a non-main principal are all silent no-ops and never block the prompt.
# The identity check itself exits 2, matching every other hook in this plugin.
set -u

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
{ INPUT="$(cat)"; } 2>/dev/null
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-agent-context.sh"
zensu_hook_is_main_principal "$INPUT" UserPromptSubmit || exit 0
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
zensu_bind_hook_session "$INPUT" || exit 0
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled zenMode || exit 0
command -v node >/dev/null 2>&1 || exit 0
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-bounded-run.sh"

# ONE node process for both things this hook needs from outside the shell: the
# prompt text and the chain-progress anchor of rule 6. They were two spawns for
# one round — prompt extraction has always run here, and the anchor added a
# second — on a hook that fires on EVERY prompt of every zen-mode session, which
# is the one channel this repository documents as unbounded. The anchor is only
# ever needed once the mode has already resolved to ACTIVE, which is decided
# above this call, so folding it in costs nothing and saves a process.
#
# Output contract: the anchor token on the FIRST line, then the prompt verbatim.
# The token is a closed vocabulary with no newline in it, which is what makes the
# first line unambiguous even for a multi-line prompt.
#
# THE ANCHOR. Rule 6 used to ask the model to invent step names, so it rendered
# for ad-hoc work with no Zensu process behind it. The position now comes from
# this session's own CAS workflow document, classified by the OWNER's exported
# classifier (`chain-recovery-v1.js`) — never from a hand-copied stage table; see
# the header of `zen-anchor-v1.js` for why that is not the coupling CLAUDE.md
# forbids. `readWorkflowState` takes the `scv1_` session KEY as its `sessionId`,
# which is how `zensu-doctor-report.js` already calls it, and `ZENSU_PROJECT_ROOT`
# is the host-native spelling node needs rather than the shell-namespace
# `ZEN_ROOT` the marker paths above are built from.
#
# THE BLOCKING CLASS IS CLOSED AT THE SHARED READER, and this `lstat` is now
# belt rather than the boundary. `.zensu/state/` is writable from inside the
# session and no gate covers it while the chain is inactive, so a `mkfifo` at the
# workflow document's path is reachable from in-session. `readRegularFileSnapshot`
# opens `O_RDONLY|O_NOFOLLOW|O_NONBLOCK` and then `fstat`s for `isFile()`, so the
# open on a FIFO returns immediately and the descriptor check rejects it. POSIX
# gives the flag no effect on a REGULAR file, so no legitimate caller changed,
# and the class is closed for EVERY caller of that reader rather than narrowed
# for this one.
#
# The `lstat` STAYS for a second job it also does, stated below, and as defence
# in depth: it and the open are two syscalls against a path the session can
# write, so it never was a boundary on its own.
#
# The `timeout` on the `hooks.json` registration is the outer bound and its cost
# is worth naming: it kills the WHOLE hook, so a turn that hits it loses the
# entire directive rather than just the anchor — the off-phrase branch below is
# not reached either. Whether this host still delivers the prompt in that case,
# and whether it kills the process group or only the direct child, is
# UNVERIFIED; nothing here measured it.
#
# The document path is built from the OWNER's `WORKFLOW_STATE_SEGMENTS` and
# `WORKFLOW_STATE_PREFIX`, not re-spelled here, so a layout change moves the
# guard with the reader rather than leaving it checking a path nobody opens. It
# also SUBSUMES an `existsSync` guard an EARLIER SPELLING OF THIS BRANCH carried
# — never anything that shipped, and the distinction matters because a reader who
# takes it for shipped history will go looking for a commit that does not exist.
# That guard existed
# because `readWorkflowState` reaches `ensureDescendantDirectory`, which CREATES
# the missing components, so a per-prompt hook would otherwise mkdir
# `<project>/.zensu/state` in any project that has none. An `lstat` on the
# document throws before any of that runs, so one check does both jobs.
#
# EVERY module is verified before ANY of them is required. Verifying and
# requiring one at a time was the first spelling and did not hold the property it
# claimed: `zen-anchor-v1.js` requires `chain-recovery-v1.js` at top level, so
# the sibling was loaded and executed by the FIRST require — before its own
# `lstat` could refuse it. A guard that runs after the file has executed is not a
# guard.
#
# `node` runs with its cwd INSIDE `hooks/lib` and resolves the modules from
# there — the first of the two module-transport mechanisms this repository
# sanctions (`tests/structure/test-msys-special-plugin-module-boundaries.sh`).
# The second, exporting the directory in an environment variable, needs a
# `zensu-host-path.sh` render to be correct on Git Bash, and that is a second
# process on the hottest path in the plugin. A raw shell-namespace directory
# handed to native `node` is NEITHER mechanism and fails silently there, which is
# what an earlier spelling did.
#
# The regex below is a DELIBERATE second spelling of the module's own token
# grammar. It is the reason a swapped module cannot both produce a bad token and
# bless it: this text lives in the hook, not in the file being distrusted.
#
# EVERY fault answers `none`, which the directive renders as no anchor at all: an
# absent, unreadable, foreign or unclassifiable document, a document that is not
# a regular file, a module that will not load or has been replaced, a `node` that
# runs and fails. A missing anchor costs a line of presentation; a wrong one
# misreports where the session stands.
#
# EVERY FAULT ALSO DISCLOSES, under a named class, on stderr. `none` is what a
# session with no chain armed legitimately renders, so without a disclosure a
# corrupt document, an unloadable module and a dead child were byte-identical to
# ordinary healthy output on every channel — and a silent failure is a lie. An
# ABSENT document is deliberately NOT a fault: it is the ordinary state of every
# project that has never armed a chain, and disclosing it would put a line on
# every prompt of every non-Zensu session. A `node` that is ABSENT is NOT in that
# list and is a different outcome: `zensu_bind_hook_session` above already
# requires one, so the hook exits before this point and injects nothing at all.
zen_prompt_and_anchor() {
  (
    # EXIT NON-ZERO, not 0. An unreachable `hooks/lib` used to leave the subshell
    # with status 0 and no output, which is byte-identical to success on every
    # channel; the parent now reads this status and discloses.
    cd -P -- "${CLAUDE_PLUGIN_ROOT}/hooks/lib" 2>/dev/null || exit 1
    # THE CHILD IS BOUNDED BY THE SHARED LADDER, not by a hand-copied one. It
    # reads outside this process, which is the criterion `zensu_run_bounded`
    # states for the two Stop-path children it already serves, and a hand copy is
    # exactly how the `gtimeout` arm once reached one of two ladders and not the
    # other. the ladder runs a COMMAND, so the assignments reach the
    # child through the EXPORTED environment rather than as a prefix written in
    # front of it. An earlier wording here prescribed `env`, which is the very
    # argv-leaking shape the block below forbids: an `env NAME=value node ...`
    # spelling puts the verbatim user prompt into env's own argument vector.
    # Z41 fails on it, so a maintainer following the retired sentence turned the
    # suite red.
    #
    # STATE THE BOUND: the ladder falls through to an UNBOUNDED arm when neither
    # `timeout` nor `gtimeout` exists, and on base macOS neither does, so this
    # is a deadline where the host supplies one and nothing where it does not.
    #
    # AND STATE THE COST CORRECTLY. A killed child returns nothing, and an empty
    # capture normalises to `none`, so that turn loses the ANCHOR and the
    # off-phrase branch, which reads an empty prompt and cannot see `zen off`.
    # The directive itself is still emitted. Only the registration timeout costs
    # the whole injection, because it kills the hook rather than the child. An
    # earlier wording here claimed the child did both, and three carriers copied
    # it. The parent-side disclosure below exists because a killed child cannot
    # write its own line, not because the directive is lost.
    # NEITHER ARGV NOR THE ENVIRONMENT carries the payload. Both were tried and
    # both were wrong for the same value, and the two rejections are different.
    # An assignment written after a command word is an ordinary ARGUMENT to that
    # command, so the first spelling put the raw payload, which carries the
    # verbatim user prompt, and the session key into an ARGUMENT VECTOR, where
    # on Linux /proc/<pid>/cmdline is world-readable and the watchdog holds the
    # whole line for as long as the child runs. Exporting fixed that and left a
    # smaller one: an environment is captured by process-listing, crash-reporting
    # and telemetry tooling that does not capture stdin, `execve` caps a single
    # environment string so an oversized prompt makes the exec FAIL, and MSYS
    # rewrites exported variables on the way into a native binary while stdin is
    # the one channel it never touches. So the payload is PIPED, which is what
    # both sibling consumers of this same payload already do; see
    # `zensu-agent-context.sh` and `zensu-session.sh`. The two remaining exports
    # carry no user content: a project root and a session key.
    export ZEN_ANCHOR_ROOT="${ZENSU_PROJECT_ROOT:-}" ZEN_ANCHOR_KEY="$ZENSU_SESSION_KEY"
    printf '%s' "$INPUT" | zensu_run_bounded \
    node -e '
    const path = require("path");
    const fs = require("fs");
    let prompt = "";
    // A SEPARATE variable, because `fault` below is overwritten on every healthy
    // anchor path, so a class set here would be silently cleared. A lost prompt
    // is the one fault that costs the user the `zen off` escape, so it is never
    // folded into the state the anchor keeps. NOTE: no apostrophe may appear in
    // this program at all, single-quoted as it is on the shell command line.
    let payloadFault = "";
    try {
      const j = JSON.parse(fs.readFileSync(0, "utf8") || "{}");
      if (typeof j.prompt === "string") prompt = j.prompt;
      else payloadFault = "prompt field";
    } catch (_) { prompt = ""; payloadFault = "payload"; }
    let anchor = "none";
    let fault = "";
    try {
      const root = process.env.ZEN_ANCHOR_ROOT || "";
      const key = process.env.ZEN_ANCHOR_KEY || "";
      if (!root || !key) {
        fault = "no session anchor";
      } else {
        const names = ["chain-recovery-v1.js", "zen-anchor-v1.js", "session-control-core-v1.js"];
        const resolved = names.map(function (n) { return path.resolve(n); });
        fault = "modules";
        resolved.forEach(function (p) {
          if (!fs.lstatSync(p).isFile()) throw new Error("not a regular file: " + p);
        });
        const chain = require(resolved[0]);
        const mod = require(resolved[1]);
        const core = require(resolved[2]);
        const dir = core.WORKFLOW_STATE_SEGMENTS
          .reduce(function (parent, segment) { return path.join(parent, segment); }, root);
        const doc = path.join(dir, core.WORKFLOW_STATE_PREFIX + core.sessionKey(key) + ".json");
        fault = "workflow document";
        let st = null;
        try {
          st = fs.lstatSync(doc);
        } catch (e) {
          st = null;
          if (e && e.code === "ENOENT") fault = "";
        }
        if (st) {
          if (!st.isFile()) throw new Error("workflow document is not a regular file");
          const state = core.readWorkflowState({ projectRoot: root, sessionId: key });
          // THE LABEL MOVES OFF THE DOCUMENT once the document has been read.
          // Everything below this line is a call INTO hooks/lib, so leaving the
          // label at "workflow document" sent an operator to .zensu/state/ for a
          // fault in the plugin tree. A stub module whose export is missing
          // passes the lstat guard, throws a TypeError here, and was disclosed
          // as a corrupt document. The classes exist to draw exactly that line.
          fault = "anchor render";
          const report = chain.classifyChain(state);
          const token = mod.anchorToken(report.shape);
          fault = "";
          if (/^(?:none|Zensu:(?: [\u2713\u25B6\u00B7\u2717][a-z][a-z-]*)+)$/.test(token)) {
            anchor = token;
          } else {
            fault = "token rejected";
          }
        }
      }
    } catch (_) { anchor = "none"; if (!fault) fault = "internal"; }
    // STDOUT FIRST, and in its OWN try. The prompt carries the only in-band
    // escape from the mode, and the diagnostic must never be able to cost it: a
    // stderr write that throws would otherwise skip the stdout write entirely,
    // the child would still exit 0, and the parent would read an empty capture.
    try {
      process.stdout.write(anchor + "\n" + prompt);
    } catch (_) { /* a failed write cannot be reported on the channel that failed */ }
    try {
      // TWO LEAD-INS, because the two carriers report different losses and one
      // sentence asserted the wrong one. `fault` costs the ANCHOR, which is a
      // line of presentation. `payloadFault` costs the PROMPT, and with it the
      // only in-band way out of the mode: the off-phrase branch reads an empty
      // string and cannot see `zen off`. Announcing that as an unavailable
      // anchor told the user the one thing that was still working.
      if (fault) {
        process.stderr.write("zensu: zen-mode anchor unavailable (" + fault + ")\n");
      }
      if (payloadFault) {
        process.stderr.write(
          "zensu: zen-mode prompt unavailable (" + payloadFault + ") - `zen off` cannot be seen this turn; "
          + "run hooks/lib/zensu-zen-mode.sh --off to leave the mode out of band\n");
      }
    } catch (_) { /* the diagnostic is best effort and never blocks the contract */ }
  '
  )
}

[ -n "${ZENSU_SESSION_KEY:-}" ] || exit 0
ZEN_ROOT="$(zensu_resolve_project_dir)" || exit 0
[ -n "$ZEN_ROOT" ] || exit 0

ZEN_STATE_DIR="$ZEN_ROOT/.zensu/state"
MARKER="$ZEN_STATE_DIR/zen-mode-${ZENSU_SESSION_KEY}.json"

# Resolve before the prompt is ever read, so a session whose mode is off keeps
# paying nothing for prompt extraction.
# A PRESENT-BUT-NOT-REGULAR marker resolves to OFF, and that arm is not tidiness.
# Without it a FIFO planted here is neither a symlink nor a regular file, so both
# tests above are false and control falls through to the CONFIGURED DEFAULT, which
# ships TRUE — so unreadable state IMPOSED the mode, which is the exact opposite of
# what the header above this file promises. Worse, it then reached the off-phrase
# write below, and a shell redirect opens a FIFO with no reader BLOCKING: the one
# in-band way out of the mode wedged the session on a path the user cannot see.
# That is the same blocking class this change closed at the shared reader, one
# marker over. `-e` is what distinguishes a present non-regular file from an absent
# one; the `-L` arm above already took every symlink, including a dangling one.
# EVERY COMPONENT is tested, not only the leaf. `[ -L "$ZEN_ROOT/.zensu/state" ]`
# resolves THROUGH a symlinked `.zensu`, so testing the state directory alone
# left the component above it free to redirect the whole subtree.
if [ -L "$ZEN_ROOT/.zensu" ] || [ -L "$ZEN_STATE_DIR" ] || [ -L "$MARKER" ]; then
  exit 0
elif [ -e "$MARKER" ] && [ ! -f "$MARKER" ]; then
  exit 0
elif [ -f "$MARKER" ]; then
  grep -q '"active"[[:space:]]*:[[:space:]]*true' "$MARKER" 2>/dev/null || exit 0
elif { [ -d "$ZEN_ROOT/.zensu" ] && [ ! -x "$ZEN_ROOT/.zensu" ]; } \
  || { [ -d "$ZEN_STATE_DIR" ] && [ ! -x "$ZEN_STATE_DIR" ]; }; then
  # A NON-TRAVERSABLE state directory is not an absent marker. Every test above
  # uses lstat or stat, all of them fail with EACCES, and the fall-through then
  # BOTH COMPONENTS are tested, exactly as the symlink arm above tests both. The
  # first spelling covered the leaf only, so an unsearchable `.zensu` made every
  # test in the ladder - including this arm`s own `[ -d ]` - fail for EACCES, and
  # control reached the default again. The leaf-only arm could not fire in the
  # very case that reaches it from one component up.
  # took the configured default, which ships TRUE - so a marker recording
  # `{"active":false}` was ignored and the mode was re-imposed on every prompt.
  # The ladder already knows the right answer one arm up: an unreadable MARKER
  # resolves OFF. Only the unreadable DIRECTORY fell the wrong way, against the
  # invariant the header of this file states.
  exit 0
else
  zensu_zen_mode_default_on || exit 0
fi

# THE PARENT IS THE GUARANTOR of the disclosure, because it is the only layer
# that observes every outcome. The child owns the classes `Z46_DECLARED` enumerates, but its writer
# runs INSIDE the child: a watchdog kill and an unreachable `hooks/lib` produce
# no line at all, and "a dead child" is precisely the case the disclosure was
# written for. These two arms close that hole.
#
# THE LINE IS NOT LATCHED, and the latch was REMOVED rather than hardened. A
# persisted band file under `.zensu/state/` bought one thing, a repeated line
# suppressed, and cost three: a bare `cat` on a session-writable path, in the
# parent, outside the watchdog, where `[ -L ]` does not exclude a FIFO, which is
# the blocking class this very change closed at the shared reader; a truncating
# `>` that a hard link turns into a destroy of whatever it points at; and a
# guessable value a co-tenant could pre-seed to suppress the first disclosure of
# a class. Hardening it means an `O_NOFOLLOW|O_NONBLOCK` open, an `nlink` check,
# an `O_EXCL` temp and a rename, for a diagnostic line. So the repetition is
# ACCEPTED and named: while a fault persists the line prints once per prompt.
# That is the same cost this repository already accepts for the Autopilot fence
# disclosure, and it is bounded by fixing the underlying state.
#
# THE FALLBACK EXISTS BECAUSE THE MERGE HAS A COST. One child computes both
# fields so the hottest path in the plugin pays one spawn, but that put the
# PROMPT — the mode's only in-band escape — behind a filesystem read it never
# needed. A stall on the workflow document, or a watchdog kill, destroyed the
# prompt half along with the anchor, and `zen off` then did nothing for that
# turn. This second child loads no module and opens no path: it reads the
# payload out of the environment and prints the prompt field, nothing else. It
# runs ONLY when the merged child already failed, so the healthy path is
# unchanged.
#
# IT DOES NOT `cd` INTO hooks/lib. An unreachable `hooks/lib` is one of the two
# outcomes the first child`s non-zero status signals, so inheriting that
# precondition would kill the fallback for the very reason it exists. This
# program requires no module and opens no path: it reads fd 0 and prints the
# prompt field.
zen_prompt_only() {
  (
    printf '%s' "$INPUT" | zensu_run_bounded \
    node -e '
    try {
      const j = JSON.parse(require("fs").readFileSync(0, "utf8") || "{}");
      if (typeof j.prompt === "string") process.stdout.write(j.prompt);
    } catch (_) { /* nothing to recover; the caller keeps its empty prompt */ }
  '
  )
}

ZEN_CHILD_RC=0
ZEN_FIELDS="$(zen_prompt_and_anchor)" || ZEN_CHILD_RC=$?
ZEN_RECOVERED=""
ZEN_RECOVERY_RC=-1
ZEN_LOST_PROMPT=0
if [ "$ZEN_CHILD_RC" -ne 0 ]; then
  echo "zensu: zen-mode anchor unavailable (child failed or was bounded, status $ZEN_CHILD_RC)" >&2
  ZEN_FIELDS=""
  ZEN_LOST_PROMPT=1
elif [ -z "$ZEN_FIELDS" ]; then
  echo "zensu: zen-mode anchor unavailable (child produced nothing)" >&2
  ZEN_LOST_PROMPT=1
fi
if [ "$ZEN_LOST_PROMPT" -eq 1 ]; then
  # THE WATCHDOG BUDGET IS SPENT ONCE, NOT TWICE. Two ladders in series each
  # bound at 5 s reach the registration`s own 10 s, which kills the HOOK and
  # loses the whole directive - strictly worse than the anchor loss being
  # repaired. 124 is the status `timeout` reports for a killed command, so on
  # that one branch the recovery is skipped rather than doubling a budget that
  # has already been paid.
  case "$ZEN_CHILD_RC" in
    124|137) ;;
    *)
      ZEN_RECOVERY_RC=0
      ZEN_RECOVERED="$(zen_prompt_only 2>/dev/null)" || ZEN_RECOVERY_RC=$?
      ;;
  esac
fi
if [ "$ZEN_LOST_PROMPT" -eq 1 ] && [ -n "$ZEN_RECOVERED" ]; then
  # The anchor stays lost; only the prompt is recovered, so the token is left
  # empty and the sanitizer answers `none` for it exactly as before.
  ZEN_FIELDS="
$ZEN_RECOVERED"
elif [ "$ZEN_LOST_PROMPT" -eq 1 ]; then
  # KEYED ON THE RECOVERY, NOT ON THE FIRST CHILD`S STATUS. Both branches above
  # lose the prompt, so suppressing this on one of them told half the operators
  # nothing about the escape being gone. And an empty result is not by itself a
  # failure - a legitimately empty prompt looks the same - so the recovery`s own
  # status is what decides, with the skipped case reported as skipped.
  if [ "$ZEN_RECOVERY_RC" -lt 0 ]; then
    ZEN_WHY="recovery skipped, the watchdog budget was already spent"
  elif [ "$ZEN_RECOVERY_RC" -ne 0 ]; then
    ZEN_WHY="recovery failed, status $ZEN_RECOVERY_RC"
  else
    # DELIBERATELY VAGUE, because the recovery cannot tell these apart: an
    # unparseable payload, a missing or non-string `prompt`, and a legitimately
    # empty prompt all leave it silent at exit 0. Naming one of them would be
    # the same defect the sanitizer had with `token rejected on arrival` - a
    # cause the reader goes and investigates that never occurred.
    ZEN_WHY="the recovery read no prompt from the payload"
  fi
  echo "zensu: zen-mode prompt unavailable ($ZEN_WHY) - \`zen off\` cannot be seen this turn; run hooks/lib/zensu-zen-mode.sh --off to leave the mode out of band" >&2
fi
ZEN_ANCHOR="${ZEN_FIELDS%%$'\n'*}"
# Command substitution strips TRAILING newlines, so an empty prompt leaves the
# token alone on the whole capture and `#*\n` would hand the token back as the
# prompt. Test for the separator rather than assuming it survived.
if [ "$ZEN_ANCHOR" = "$ZEN_FIELDS" ]; then
  PROMPT=""
else
  PROMPT="${ZEN_FIELDS#*$'\n'}"
fi

ZEN_OFF=0
if [ -n "$PROMPT" ]; then
  if printf '%s' "$PROMPT" \
    | grep -qiE '(^|[^[:alnum:]])(zen[ -]?(mode )?off|stop zen|turn off zen([ -]?mode)?)([^[:alnum:]]|$)'; then
    ZEN_OFF=1
  else
    case "$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' | tr -d '[:punct:]')" in
      normalmode) ZEN_OFF=1 ;;
    esac
  fi
fi

if [ "$ZEN_OFF" -eq 1 ]; then
  ZEN_OFF_RECORDED=0
  # THE WRITE IS HARDENED rather than a bare `> "$MARKER"`, and the reason is the
  # one this file already gives for deleting its own band file: `[ -L ]` is blind
  # to a HARD LINK, so a truncating redirect at a session-writable path is a
  # destroy primitive aimed at whatever that link points at. The arm above already
  # excludes every non-regular marker, so what is left to defend against is
  # precisely the link. It lands an `O_EXCL` temp beside the marker and renames,
  # which also removes the window where a reader sees a half-written document.
  # Cost is one `node` spawn on the OFF-PHRASE path only — never on an ordinary
  # prompt — so the hottest path pays nothing for it.
  if mkdir -p -m 700 "$ZEN_STATE_DIR" 2>/dev/null \
    && ZEN_MARKER="$MARKER" zensu_run_bounded node -e '
      const fs = require("fs");
      const target = process.env.ZEN_MARKER;
      let st = null;
      try { st = fs.lstatSync(target); } catch (e) { if (e.code !== "ENOENT") process.exit(1); }
      if (st && (!st.isFile() || st.nlink !== 1)) process.exit(1);
      // RANDOM, not the pid. Nothing reaps a temp left by a killed write, and a
      // later invocation landing on the same pid then fails the O_EXCL open and
      // reports only "COULD NOT BE DEACTIVATED" - so a pid suffix turns a one-off
      // crash into a permanent refusal of the in-band exit.
      const tmp = target + ".tmp-" + require("crypto").randomBytes(6).toString("hex");
      let fd;
      try {
        fd = fs.openSync(tmp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
        fs.writeSync(fd, "{\"active\":false}\n");
        fs.fsyncSync(fd);
      } catch (e) { try { if (fd !== undefined) fs.closeSync(fd); } catch (_) {} try { fs.unlinkSync(tmp); } catch (_) {} process.exit(1); }
      try { fs.closeSync(fd); } catch (_) {}
      try { fs.renameSync(tmp, target); } catch (e) { try { fs.unlinkSync(tmp); } catch (_) {} process.exit(1); }
    ' 2>/dev/null; then
    grep -q '"active"[[:space:]]*:[[:space:]]*true' "$MARKER" 2>/dev/null || ZEN_OFF_RECORDED=1
  fi
  if [ "$ZEN_OFF_RECORDED" -eq 0 ]; then
    cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "zen-mode COULD NOT BE DEACTIVATED: the session marker under .zensu/state/ could not be written, so the mode is still on and this hook will keep re-injecting it. Tell the user this in one plain sentence, name the .zensu/state/ directory as the place to look, and then answer their request normally. Do not silently ignore this."
  }
}
JSON
    exit 0
  fi
  cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "zen-mode is now OFF — the user asked for it. Drop the zen-mode response shape entirely and answer in your ordinary style from this response onward. Mention the switch in one short clause, then answer the request. Do not keep the recap line or the single-next-step ending unless they genuinely help this particular answer."
  }
}
JSON
  exit 0
fi

# Belt against a swapped or corrupted module, and against a truncated write. The
# node program above re-checks the token against a grammar of its own, so this is
# the THIRD reader, and it now reads BOTH the grammar and the bytes. State the
# relation honestly: on the language the grammar ACCEPTS it already subsumes the
# byte reader, because no string of `Zensu:` plus mark/step fields can carry a
# quote, a backslash or a control byte, so in production the byte arms reject
# nothing today. They are kept so that WIDENING the grammar later cannot
# silently widen what reaches the JSON string, and they are driven on their own
# table because composed behind the grammar they are otherwise ungradeable.
#
# THE GRAMMAR IS READ HERE TOO, and the reason is not redundancy with the node
# program. That reader validates the token it is about to print; this one reads
# the bytes that ARRIVED, which is a WEAKER claim than an earlier wording made
# and is worth stating exactly. That wording said this reader exists to catch a
# child killed mid-write. It catches only PART of that class: both grammars
# require one or more mark/step pairs and nothing more, so a truncation landing
# at a field boundary, or inside a step name, passes both. Only a cut inside a
# mark or straight after one is refused here. And a truncated write implies a
# non-zero child status, which the parent already answers by discarding the
# whole capture before this reader sees it. What this reader genuinely owns is
# the SWAPPED-module case plus the prefix arm the byte test alone allowed:
# `Zensu: ` followed by arbitrary prose. Do not read the truncation class as
# closed by it.
#
# It is spelled as a pure-shell field walk rather than a `grep -qE`, because
# this runs on every prompt of every zen-mode session and a subprocess here is
# the one cost this hook is careful not to pay. The mark set is matched as an
# ALTERNATION of whole strings, never as a bracket expression: the four marks
# are multi-byte, and a bracket class over them matches individual BYTES under a
# byte locale, which would accept a truncated mark and reject a valid one.
#
# The step-name class is spelled out letter by letter for the mirror reason, and
# it was MEASURED rather than assumed: written as `[a-z]` the walk accepted
# `Zensu: ✓Implement`, because a range in a `case` glob follows the collation
# order, which interleaves the cases in this locale. A range here would make the
# reader locale-dependent in exactly the way the control-byte arm below is.
zen_anchor_grammar_ok() {
  local LC_ALL=C _zag_rest _zag_field _zag_body
  [ "$1" = "none" ] && return 0
  case "$1" in 'Zensu: '*) ;; *) return 1 ;; esac
  _zag_rest="${1#Zensu:}"
  while [ -n "$_zag_rest" ]; do
    case "$_zag_rest" in ' '*) ;; *) return 1 ;; esac
    _zag_rest="${_zag_rest# }"
    case "$_zag_rest" in
      *' '*) _zag_field="${_zag_rest%% *}"; _zag_rest=" ${_zag_rest#* }" ;;
      *)     _zag_field="$_zag_rest";       _zag_rest="" ;;
    esac
    case "$_zag_field" in
      '✓'*) _zag_body="${_zag_field#✓}" ;;
      '▶'*) _zag_body="${_zag_field#▶}" ;;
      '·'*) _zag_body="${_zag_field#·}" ;;
      '✗'*) _zag_body="${_zag_field#✗}" ;;
      *) return 1 ;;
    esac
    case "$_zag_body" in [abcdefghijklmnopqrstuvwxyz]*) ;; *) return 1 ;; esac
    case "$_zag_body" in *[!abcdefghijklmnopqrstuvwxyz-]*) return 1 ;; esac
  done
  return 0
}

# The BYTE tests below are kept beside that grammar walk rather than replaced by
# it, because they own a different property: what has to hold before the value
# is spliced into a JSON string is that no quote breaks the JSON, no backslash
# changes what an escape means, and no control byte lands inside a JSON string —
# a CR or a TAB would make the whole directive unparseable and lose it silently.
# The `&`, `|`, `$` and backtick arms are retained from an earlier spelling OF
# THIS BRANCH that substituted through `sed` — again not shipped history: they cost
# nothing, since no producible token carries them, and they keep the value inert
# if the emission ever changes back. The grammar refuses all of these today;
# keeping both is what makes the refusal survive a change to either rule.
# The BYTE tests are their own reader, and the split is a TESTABILITY property
# rather than tidiness. Composed behind the grammar walk they were unreachable:
# every input a byte test refuses is refused by the grammar first, so all three
# `case` blocks could be deleted with the suite green. That is verbatim the
# defect the check driving them exists to close, so each reader is now driven on
# its own table and the composition keeps a third, thin arm.
zen_anchor_bytes_ok() {
  local LC_ALL=C
  case "$1" in
    *'"'*|*'\'*|*'&'*|*'|'*|*'$'*|*'`'*) return 1 ;;
  esac
  case "$1" in
    *[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

zen_anchor_sanitized() {
  # BOTH readers below are locale-sensitive, so the locale is pinned rather than
  # inherited. Two claims, and they do NOT rest on the same evidence.
  #
  # MEASURED: the step-name class. Written as the range `[a-z]` the walk accepted
  # `Zensu: ✓Implement`, because a `case` range follows the collation order,
  # which interleaves the cases in this locale. That is why it is enumerated.
  #
  # REASONED, NOT REPRODUCED: the `[[:cntrl:]]` arm. It is a locale class, and
  # three of the four marks carry a byte in the C1 range 0x80-0x9F, which a
  # single-byte ISO8859 locale classifies as a control character — 0x9C in ✓ and
  # ✗, 0x96 in ▶, none in ·. An earlier wording said all three carried 0x9C,
  # which is false. The suite drove a producible token under en_SG.ISO8859-1 on
  # macOS and it was NOT rejected, so this exposure has not been reproduced on
  # any host tried; the pin is defensive. That `local` on LC_ALL takes effect for
  # these `case` patterns is likewise reasoned rather than measured.
  local LC_ALL=C
  # A REJECTION HERE DISCLOSES, under its own class. Without the line this was
  # the one arm on the whole path where a rejected value produced output a
  # healthy `none` could not be told apart from — which is the property the
  # header of this file states as non-negotiable. The reachable cause is the two
  # hand-spelled grammars drifting: the node-side regex and the shell walk are
  # independent copies by design, so after a divergence this reader would answer
  # `none` on every prompt with nothing on any channel.
  # AN EMPTY VALUE IS NOT A REJECTION, and saying so was a false cause. Every
  # degraded parent path leaves this empty, so a killed child produced a second
  # line asserting a token ARRIVED and failed the grammar — sending a maintainer
  # to compare two grammars that never ran. The parent has already disclosed the
  # real cause on those paths, so this one returns quietly.
  [ -n "$1" ] || { printf 'none'; return 0; }
  zen_anchor_grammar_ok "$1" || {
    echo "zensu: zen-mode anchor unavailable (token rejected on arrival)" >&2
    printf 'none'
    return 0
  }
  zen_anchor_bytes_ok "$1" || {
    echo "zensu: zen-mode anchor unavailable (token bytes rejected on arrival)" >&2
    printf 'none'
    return 0
  }
  printf '%s' "$1"
}
ZEN_ANCHOR="$(zen_anchor_sanitized "$ZEN_ANCHOR")"

# The substitution is parameter expansion rather than `sed`, and that is a fault
# direction rather than a preference. The `sed` spelling was a DRAFT OF THIS
# BRANCH and never shipped — `main` carries no substitution here at all, because
# it carries no anchor field. In that draft `cat <<'JSON' | sed "…"` made the ACTIVE
# directive the only one of this hook's three emissions that depended on an
# external command, and nothing examined that command's exit status: a `sed`
# that was absent or errored produced an empty stdout, the model received no
# zen-mode context at all, and the unconditional `exit 0` below made that
# indistinguishable from the hook not having run. Every other fault in this file
# is routed to `none`; this one was routed to silence. The expansions below need
# no process, and the placeholder is held in a variable so it stays a literal
# pattern rather than a glob.
ZEN_BODY="$(cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "zen-mode is ACTIVE. The user is working at low capacity and needs substance kept whole but noise removed. Shape this response accordingly, writing in the user's own language: (1) Open with ONE short recap line covering what happened since their last message; omit it when nothing happened. (2) Give the result in the first sentence after that — no preamble, no announcing what is coming. (3) Stay near 8 lines and leave out caveats and history you were not asked for, and trade-offs or alternatives you were NOT asked to choose between — never the options of a decision that is actually in front of the user; when you deliberately withheld depth, close with a short offer instead. (4) Write full, short sentences. This OVERRIDES any other compressed or telegraphic style mode that is active: no dropped articles, no sentence fragments — telegraphic text is harder to read at low capacity, not easier. (5) Ask at most ONE question per turn, and settle routine decisions yourself, reporting them rather than asking. (6) Gloss unavoidable jargon in three words or fewer, show code as changed lines only, and anchor work that spans several turns with the one-line chain-progress line THIS BLOCK supplies: the ZENSU CHAIN ANCHOR line at the very end is this session's anchor, derived from the session's own Zensu workflow document and never from the plan. When it names a 'Zensu: …' line, render that line verbatim — same steps, same order, same marks — directly above the closing next step, or above the final step list when the one-next-step rule is suspended; 'Zensu:' is a fixed English prefix and not a mark, and you translate only the words around the line into the user's language. When it reads 'none', no Zensu chain is armed in this session, so render NO chain-progress anchor at all: never invent steps, never copy a canonical pipeline out of another component, and never carry an anchor over from an earlier turn, because this anchor only means anything inside a Zensu-driven development process. The marks read '✓' for a step that finished and passed, '▶' for the step running now, '·' for one not yet reached, and '✗' for one that failed or is blocked. The line is a position, not a history — an earlier failure is still reported in the prose of the turn it happened in. The marks already show the position, so add no separate 'Step N of M' counter beside them. (7) End with exactly ONE next step, never two parallel suggestions. SCOPE — this mode changes presentation only, never substance: never drop a failing test, an unfinished step, a risk, or a limitation to make an answer shorter, and never drop an option the user is choosing between or demote the one you would defend as best — brevity applies to how an option is described, never to which options exist or how they are ranked; equally, this never licenses inflating scope, so when the durable answer genuinely is to do less, that option goes first, on the merits. Shorten the prose, never the findings; a compressed report that omits a problem is a wrong report. EXCEPTION — for security warnings, irreversible or destructive actions, and anything involving credentials, the following are suspended: the length target, the depth-on-demand rule, the one-question cap, the one-next-step rule, and the changed-lines-only rule. Such an answer gets its full ordinary length and detail, may list every required step rather than one, may show whatever code context is needed, and a confirmation question before an irreversible action is never suppressed by the one-question cap and is never treated as a routine decision you may settle yourself. The full-sentence rule is NEVER suspended — a safety warning is the last place for fragments. The user leaves the mode by writing 'normal mode', 'zen off', 'zen-mode off', 'turn off zen', or 'stop zen'; if they ask to leave it in any other wording or in another language, that counts too — run the zen-mode helper's --off verb yourself (hooks/lib/zensu-zen-mode.sh in the Zensu plugin, invoked exactly as skills/zen-mode/SKILL.md renders it) and confirm in one clause. Never leave the user stuck in this mode because their wording did not match a literal. ZENSU CHAIN ANCHOR: {{ZENSU_CHAIN_ANCHOR}}"
  }
}
JSON
)"
ZEN_PLACEHOLDER='{{ZENSU_CHAIN_ANCHOR}}'
# A missing placeholder makes BOTH expansions return the whole body, which would
# emit the directive twice with the token wedged between — unparseable JSON the
# host drops, which is the routed-to-silence fault this substitution was changed
# to remove. Only a source edit can produce it and Z19b pins the placeholder, so
# the branch is a maintenance belt rather than a live path.
case "$ZEN_BODY" in
  *"$ZEN_PLACEHOLDER"*)
    printf '%s\n' "${ZEN_BODY%%"$ZEN_PLACEHOLDER"*}${ZEN_ANCHOR}${ZEN_BODY#*"$ZEN_PLACEHOLDER"}" ;;
  *)
    printf '%s\n' "$ZEN_BODY" ;;
esac
exit 0
