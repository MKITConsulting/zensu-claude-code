#!/bin/bash
# UserPromptSubmit + SubagentStart hook — injects the best-solution-first rule as
# hookSpecificOutput.additionalContext so every process carries it: the main thread
# on EVERY prompt, and every spawned subagent at spawn time.
#
# The `user-prompt-` prefix names the primary recurring channel; the SubagentStart
# leg is the reach extension, exactly as session-start-evidence-discipline.sh names
# only its first event while serving two.
#
# The directive text is READ AT RUN TIME from docs/best-solution-first.md (the single
# line between the zensu:best-solution-first markers) rather than duplicated here, so
# this carrier can never drift from the canonical block. docs/ is inside the Session
# Control runtime digest (manifestRuntimeEntries in hooks/lib/session-control-core-v1.js),
# so that file is tamper-evident within a session THAT IS SERVED BY THE RUNTIME WHICH
# MINTED ITS RECORD — servesRecordedRuntime lets a compatible sibling install serve a
# record it did not mint, and this hook reads from the EXECUTING root, so a lineage-served
# upgrade injects bytes no in-session digest measured. The build-time digest pin in
# tests/structure/test-best-solution-first.sh (B2f1) is what actually binds the text.
# The load additionally refuses a symlink, as session-start-evidence-discipline.sh does
# for its own policy file.
#
# Deliberately different from session-start-evidence-discipline.sh in two ways: it IS
# switchable (hooks.bestSolutionFirst, default on) because it directs how a decision is
# presented rather than asserting a correctness invariant, and it fires on the prompt
# channel rather than only at session start — a rule that fades over a long session
# fades exactly when an agent starts optimizing for the smallest disturbance.
#
# Deliberately different from user-prompt-context-nudge.sh in two ways: no de-bounce
# band (the moment an agent is about to frame a question is not observable in advance,
# so the reminder has to be resident, not periodic) and no main-principal gate — the
# rule applies to subagents too, which is the whole point of the second event.
#
# Fail-silent by construction: an unknown event, a malformed payload, a missing node,
# or an absent/symlinked/malformed/oversized block exits 0 with no output, so it can never
# block a prompt or a spawn. Note what that means for a malformed block specifically — the
# injection is DROPPED, not truncated, and nothing reports it; the build-time pins in
# tests/structure/test-best-solution-first.sh are what make that shape a hard failure.
# The plugin-root guard is the one deliberate exception: it is the sibling hooks' guard
# plus CDPATH= and -- hardening, so a mismatched inherited CLAUDE_PLUGIN_ROOT refuses
# with exit 2.
set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)" || exit 2
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _ZENSU_DECLARED_PLUGIN_ROOT="$(CDPATH= cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || {
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  }
  if [ "$_ZENSU_DECLARED_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  fi
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
ZENSU_BEST_SOLUTION_RULE_FILE="$_ZENSU_EXECUTED_PLUGIN_ROOT/docs/best-solution-first.md"
unset _ZENSU_EXECUTED_PLUGIN_ROOT _ZENSU_DECLARED_PLUGIN_ROOT

command -v node >/dev/null 2>&1 || exit 0
[ -f "$ZENSU_BEST_SOLUTION_RULE_FILE" ] && [ ! -L "$ZENSU_BEST_SOLUTION_RULE_FILE" ] || exit 0

# The library is EXECUTED, not read, so it earns at least the guard the data file gets.
ZENSU_BEST_SOLUTION_CONFIG_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
[ -f "$ZENSU_BEST_SOLUTION_CONFIG_LIB" ] && [ ! -L "$ZENSU_BEST_SOLUTION_CONFIG_LIB" ] || exit 0

# The payload is still unread on fd 0 here, so the config probe — which spawns its own
# node — takes stdin from /dev/null rather than risking the channel the emitter needs.
# shellcheck source=hooks/lib/zensu-config.sh
source "$ZENSU_BEST_SOLUTION_CONFIG_LIB" </dev/null 2>/dev/null || exit 0
zensu_hook_enabled bestSolutionFirst </dev/null || exit 0

# node reads the payload itself: buffering it through the shell and re-piping it
# would corrupt a multi-byte character that straddles a stdin chunk boundary.
ZENSU_BEST_SOLUTION_RULE_FILE="$ZENSU_BEST_SOLUTION_RULE_FILE" node -e '
  const OPEN = "<!-- zensu:best-solution-first -->";
  const CLOSE = "<!-- /zensu:best-solution-first -->";
  const MAX_BLOCK = 4000;
  const MAX_FILE = 1048576;
  try {
    const fs = require("fs");
    const payload = JSON.parse(fs.readFileSync(0, "utf8") || "{}");
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) process.exit(0);
    const event = payload.hook_event_name;
    if (event !== "UserPromptSubmit" && event !== "SubagentStart") process.exit(0);

    // Hardened open, modelled on the reader in hooks/lib/plan-payload-v1.js: lstat, then
    // open non-blocking without following a link, then fstat back against the same inode
    // before reading. The shell pre-check above narrows the swap window; this closes it.
    //
    // Two deliberate divergences from that reference, both because the path here is FIXED
    // under the executing plugin root rather than payload-named:
    //   - no nlink === 1 requirement. There it defends a caller-named path, where a hard
    //     link is how an attacker reaches a file the symlink check refuses. Here an
    //     attacker who can plant a hard link can equally rewrite the file, so the check
    //     buys nothing and would silently disable the rule on any install that
    //     materializes files by hard link (cp -al, content-addressed stores).
    //   - the read is bounded by the size fstat already reported, so a file that grows
    //     between the two calls cannot be read past what was measured. Like the
    //     reference it fills in a loop and refuses a short read rather than parsing a
    //     truncated file, which would drop the injection while looking like a refusal.
    const rulePath = process.env.ZENSU_BEST_SOLUTION_RULE_FILE;
    const pre = fs.lstatSync(rulePath);
    if (!pre.isFile()) process.exit(0);
    // Platform-gated exactly as platformNoFollow() in plan-payload-v1.js: a bare
    // `O_NOFOLLOW || 0` accepts a flag that is defined but unsupported, where openSync
    // throws and the rule silently never injects.
    const noFollow = process.platform !== "win32" && Number.isInteger(fs.constants.O_NOFOLLOW)
      ? fs.constants.O_NOFOLLOW : 0;
    const nonBlock = Number.isInteger(fs.constants.O_NONBLOCK) ? fs.constants.O_NONBLOCK : 0;
    const fd = fs.openSync(rulePath, fs.constants.O_RDONLY | noFollow | nonBlock);
    let raw;
    try {
      const post = fs.fstatSync(fd);
      if (!post.isFile() || post.dev !== pre.dev || post.ino !== pre.ino) process.exit(0);
      if (post.size > MAX_FILE) process.exit(0);
      const buf = Buffer.alloc(post.size);
      let filled = 0;
      while (filled < post.size) {
        const chunk = fs.readSync(fd, buf, filled, post.size - filled, filled);
        if (chunk < 1) break;
        filled += chunk;
      }
      // A short read would truncate the file before the marker block and drop the
      // injection while looking exactly like a correct refusal. Refuse explicitly.
      if (filled !== post.size) process.exit(0);
      raw = buf.toString("utf8");
    } finally {
      // A throwing close must not replace a successful read: without this the outer
      // catch swallows it and the injection is dropped after the bytes were already in.
      try { fs.closeSync(fd); } catch (_) {}
    }

    const lines = raw.split("\n");
    const open = lines.indexOf(OPEN);
    if (open < 0 || lines.indexOf(OPEN, open + 1) !== -1) process.exit(0);
    if (lines[open + 2] !== CLOSE) process.exit(0);
    const block = String(lines[open + 1] || "").replace(/^>\s*/, "").trim();
    // The block is injected on every prompt and at every spawn, so its size is a per-turn
    // multiplier. Refuse rather than silently ship an unbounded context tax.
    if (!block || block.length > MAX_BLOCK) process.exit(0);

    const directive = "Zensu best-solution-first — binding for every process in this "
      + "session, main thread and subagents alike. " + block;
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: event,
        additionalContext: directive
      }
    }));
  } catch (_) {}
' 2>/dev/null
exit 0
