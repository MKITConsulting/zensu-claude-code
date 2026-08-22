#!/bin/bash
# SessionStart + SubagentStart hook — injects the plugin-wide evidence-discipline
# rule as hookSpecificOutput.additionalContext so every process carries it: the
# main thread and every spawned subagent alike.
#
# The directive text is READ AT RUN TIME from docs/evidence-discipline.md (the
# single line between the zensu:evidence-discipline markers) rather than
# duplicated here, so this carrier can never drift from the canonical block the
# agents and skills quote. docs/ is inside the Session Control runtime digest
# (manifestRuntimeEntries in hooks/lib/session-control-core-v1.js), so that file
# is tamper-evident within a session THAT IS SERVED BY THE RUNTIME WHICH MINTED
# ITS RECORD — readContextInternal measures the RECORDED plugin root while this
# hook reads from the EXECUTING one, and servesRecordedRuntime deliberately lets a
# compatible sibling install serve a record it did not mint, so a lineage-served
# upgrade injects bytes no in-session digest measured. What binds this text across
# that case is the build-time pinning in tests/structure/test-evidence-discipline.sh:
# the block's own phrases plus the requirement that every agent and every skill
# carries it verbatim. The load additionally refuses a symlink, as
# review-evidence-subagent-start.sh and -stop.sh do for their policy file, and the
# reader below re-checks the inode it actually opened.
#
# Deliberately different from session-start-primer.sh in three ways: it reads no
# config (no opt-out flag, in particular NOT hooks.sessionBanner), it has no
# fresh-start filter (it also fires on resume/compact, where the rule would
# otherwise be lost with the compacted context), and it applies to every
# principal rather than only main-v1.
#
# Fail-silent by construction: an unknown event, a malformed payload, a missing
# node, or a rule file that is absent, symlinked, swapped between the pre-check and
# the open, oversized in FILE or in BLOCK, short-read or malformed exits 0 with no
# output, so it can never block a prompt or a spawn. Note what that means for an
# unswitchable rule: the injection is DROPPED, not truncated, and nothing reports it —
# the build-time pins in tests/structure/test-evidence-discipline.sh are what make that
# a hard failure. The plugin-root guard is the one deliberate
# exception: it is the sibling hooks' guard plus CDPATH= and -- hardening, so a
# mismatched inherited CLAUDE_PLUGIN_ROOT still refuses with exit 2.
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
ZENSU_EVIDENCE_RULE_FILE="$_ZENSU_EXECUTED_PLUGIN_ROOT/docs/evidence-discipline.md"
unset _ZENSU_EXECUTED_PLUGIN_ROOT _ZENSU_DECLARED_PLUGIN_ROOT

command -v node >/dev/null 2>&1 || exit 0
[ -f "$ZENSU_EVIDENCE_RULE_FILE" ] && [ ! -L "$ZENSU_EVIDENCE_RULE_FILE" ] || exit 0

# node reads the payload itself: buffering it through the shell and re-piping it
# would corrupt a multi-byte character that straddles a stdin chunk boundary.
ZENSU_EVIDENCE_RULE_FILE="$ZENSU_EVIDENCE_RULE_FILE" node -e '
  const OPEN = "<!-- zensu:evidence-discipline -->";
  const CLOSE = "<!-- /zensu:evidence-discipline -->";
  const MAX_BLOCK = 4000;
  const MAX_FILE = 1048576;
  try {
    const fs = require("fs");
    const payload = JSON.parse(fs.readFileSync(0, "utf8") || "{}");
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) process.exit(0);
    const event = payload.hook_event_name;
    if (event !== "SessionStart" && event !== "SubagentStart") process.exit(0);

    // Hardened open, modelled on the reader in hooks/lib/plan-payload-v1.js and shared
    // verbatim with hooks/user-prompt-best-solution-first.sh: lstat, then open
    // non-blocking without following a link, then fstat back against the same inode
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
    const rulePath = process.env.ZENSU_EVIDENCE_RULE_FILE;
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
    // MAX_FILE caps the FILE; without this the same file, well under that ceiling, can
    // still carry one enormous marker line — and this carrier injects it into every
    // session and every subagent as a directive that cannot be switched off. Shared
    // value with the sibling carrier user-prompt-best-solution-first.sh, and three checks
    // bind them: H4e in tests/structure/test-evidence-discipline.sh (which fails first),
    // B2h in tests/structure/test-best-solution-first.sh, and the cross-carrier equality in
    // tests/structure/test-windows-portability-guards.sh. Raising it here means re-arguing
    // the bound on the sibling too, not following it.
    if (!block || block.length > MAX_BLOCK) process.exit(0);

    const directive = "Zensu evidence discipline — binding for every process in this "
      + "session, main thread and subagents alike, and not switchable off. " + block;
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: event,
        additionalContext: directive
      }
    }));
  } catch (_) {}
' 2>/dev/null
exit 0
