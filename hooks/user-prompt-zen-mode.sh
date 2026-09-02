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
# THE DOCUMENT IS `lstat`ED BEFORE IT IS OPENED, and that guard is about
# BLOCKING, not tidiness. `.zensu/state/` is writable from inside the session and
# no gate covers it while the chain is inactive, so a `mkfifo` at the workflow
# document's path is reachable from in-session. `readRegularFileSnapshot` in the
# shared reader opens `O_RDONLY|O_NOFOLLOW` and only THEN `fstat`s for
# `isFile()` — there is no `O_NONBLOCK` — so the open on a FIFO never returns,
# and this hook fires on EVERY prompt. That wedges the session with no escape
# from inside: the prompt never reaches the model, and the off-phrase branch
# below is never reached either. This `lstat` refuses a FIFO, a device, a
# directory and a symlink before the shared reader can open it. The `timeout` on
# the `hooks.json` registration is belt, not the fix — a killed child returns
# nothing, which costs that turn's off-phrase detection.
#
# IT IS A NARROWING, NOT A BOUNDARY, and the difference is stated so nobody reads
# it as one. The `lstat` and the open are two syscalls against a path the session
# can write, so a writer that swaps the document between them still reaches the
# blocking open — an unbounded per-prompt wedge becomes a race the writer has to
# win on every prompt. The same open is reachable through every other caller of
# that reader; those are merely not per-prompt. The uncompromised fix is an
# unconditional `lstat` pre-check plus `O_NONBLOCK` inside the shared reader,
# which closes the class for all of them, and it is deliberately deferred: that
# module is required by every gate and the change needs its own regression pass.
#
# The document path is built from the OWNER's `WORKFLOW_STATE_SEGMENTS` and
# `WORKFLOW_STATE_PREFIX`, not re-spelled here, so a layout change moves the
# guard with the reader rather than leaving it checking a path nobody opens. It
# also SUBSUMES the `existsSync` guard this block used to carry: that one existed
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
# misreports where the session stands. A `node` that is ABSENT is NOT in that
# list and is a different outcome: `zensu_bind_hook_session` above already
# requires one, so the hook exits before this point and injects nothing at all.
zen_prompt_and_anchor() {
  (
    cd -P -- "${CLAUDE_PLUGIN_ROOT}/hooks/lib" 2>/dev/null || exit 0
    PAYLOAD="$INPUT" ZEN_ANCHOR_ROOT="${ZENSU_PROJECT_ROOT:-}" ZEN_ANCHOR_KEY="$ZENSU_SESSION_KEY" \
    node -e '
    const path = require("path");
    const fs = require("fs");
    let prompt = "";
    try {
      const j = JSON.parse(process.env.PAYLOAD || "{}");
      if (typeof j.prompt === "string") prompt = j.prompt;
    } catch (_) { prompt = ""; }
    let anchor = "none";
    try {
      const root = process.env.ZEN_ANCHOR_ROOT || "";
      const key = process.env.ZEN_ANCHOR_KEY || "";
      const names = ["chain-recovery-v1.js", "zen-anchor-v1.js", "session-control-core-v1.js"];
      const resolved = names.map(function (n) { return path.resolve(n); });
      resolved.forEach(function (p) {
        if (!fs.lstatSync(p).isFile()) throw new Error("not a regular file: " + p);
      });
      const chain = require(resolved[0]);
      const mod = require(resolved[1]);
      const core = require(resolved[2]);
      if (root && key) {
        const dir = core.WORKFLOW_STATE_SEGMENTS
          .reduce(function (parent, segment) { return path.join(parent, segment); }, root);
        const doc = path.join(dir, core.WORKFLOW_STATE_PREFIX + core.sessionKey(key) + ".json");
        if (!fs.lstatSync(doc).isFile()) throw new Error("workflow document is not a regular file");
        const report = chain.classifyChain(core.readWorkflowState({ projectRoot: root, sessionId: key }));
        const token = mod.anchorToken(report.shape);
        if (/^(?:none|Zensu:(?: [✓▶·✗][a-z][a-z-]*)+)$/.test(token)) {
          anchor = token;
        }
      }
    } catch (_) { anchor = "none"; }
    process.stdout.write(anchor + "\n" + prompt);
  ' 2>/dev/null
  )
}

[ -n "${ZENSU_SESSION_KEY:-}" ] || exit 0
ZEN_ROOT="$(zensu_resolve_project_dir)" || exit 0
[ -n "$ZEN_ROOT" ] || exit 0

ZEN_STATE_DIR="$ZEN_ROOT/.zensu/state"
MARKER="$ZEN_STATE_DIR/zen-mode-${ZENSU_SESSION_KEY}.json"

# Resolve before the prompt is ever read, so a session whose mode is off keeps
# paying nothing for prompt extraction.
if [ -L "$ZEN_STATE_DIR" ] || [ -L "$MARKER" ]; then
  exit 0
elif [ -f "$MARKER" ]; then
  grep -q '"active"[[:space:]]*:[[:space:]]*true' "$MARKER" 2>/dev/null || exit 0
else
  zensu_zen_mode_default_on || exit 0
fi

ZEN_FIELDS="$(zen_prompt_and_anchor)"
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
  if mkdir -p -m 700 "$ZEN_STATE_DIR" 2>/dev/null \
    && { printf '{"active":false}\n' > "$MARKER"; } 2>/dev/null; then
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

# Belt against a swapped or corrupted module. The node program above already
# re-checks the token against a grammar of its own, so this is the THIRD reader,
# and it is a BYTE test rather than a grammar one ON PURPOSE: what has to hold
# before the value is spliced into a JSON string is that no quote breaks the
# JSON, no backslash changes what an escape means, and no control byte lands
# inside a JSON string — a CR or a TAB would make the whole directive
# unparseable and lose it silently. The `&`, `|`, `$` and backtick arms are
# retained from the `sed` era: they cost nothing, since no producible token
# carries them, and they keep the value inert if the emission ever changes back.
#
# SAY WHAT IT DOES NOT DO. The prefix arm still accepts `Zensu: <arbitrary
# prose>` — that is deliberate, not a leftover: this reader owns the BYTES and
# the node program above owns the GRAMMAR, and it is the only grammar reader on
# this path. An earlier comment here claimed the arbitrary-prose acceptance had
# been fixed, which would invite the next reader to relax that grammar check.
# What the earlier spelling really lacked was the control-byte arm: it accepted
# every control byte but LF.
zen_anchor_sanitized() {
  case "$1" in
    none|'Zensu: '*) ;;
    *) printf 'none'; return 0 ;;
  esac
  case "$1" in
    *'"'*|*'\'*|*'&'*|*'|'*|*'$'*|*'`'*) printf 'none'; return 0 ;;
  esac
  case "$1" in
    *[[:cntrl:]]*) printf 'none'; return 0 ;;
  esac
  printf '%s' "$1"
}
ZEN_ANCHOR="$(zen_anchor_sanitized "$ZEN_ANCHOR")"

# The substitution is parameter expansion rather than `sed`, and that is a fault
# direction rather than a preference. `cat <<'JSON' | sed "…"` made the ACTIVE
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
