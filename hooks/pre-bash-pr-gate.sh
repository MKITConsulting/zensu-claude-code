#!/bin/bash
# pre-bash-pr-gate.sh — optional PreToolUse(Bash) PR-create gate (hooks.prGate,
# DEFAULT OFF — runs only on an explicit true; ships off to be promoted once
# field-proven). The Stop chain guarantees a review ran in the session — this
# gate additionally guarantees the PR is opened FROM the reviewed commit:
# --chain-done records the working checkout's HEAD in
# .zensu/state/review-pass-<sid>, and a PR-creating command (gh pr create,
# gh api POST to a /pulls endpoint, glab mr create) is DENIED while no marker
# matches the current HEAD — "review, then one more quick commit, then PR"
# becomes visible instead of silent. Bypass with ZENSU_PR_GATE=off (env or
# inline prefix; recorded in the bypass ledger while a session is active).
# Reads and non-PR commands are never gated; node/git absence fails open.
set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"

command -v node >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null || true)"

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"

zensu_pr_gate_enabled || exit 0

[ -z "$INPUT" ] && exit 0

CMD="$(PAYLOAD="$INPUT" node -e '
  try {
    const j = JSON.parse(process.env.PAYLOAD || "{}");
    const c = j.tool_input && typeof j.tool_input.command === "string" ? j.tool_input.command : "";
    process.stdout.write(c);
  } catch (_) { process.stdout.write(""); }
' 2>/dev/null)"
[ -z "$CMD" ] && exit 0

IS_PR=0
case "$CMD" in
  *"gh pr create"*|*"glab mr create"*) IS_PR=1 ;;
esac
if [ "$IS_PR" -eq 0 ]; then
  case "$CMD" in
    *"gh api"*pulls*)
      if printf '%s' "$CMD" | grep -qE '/pulls["'"'"']?([[:space:]]|$)'; then
        if printf '%s' "$CMD" | grep -qiE '(^|[[:space:]])(-X ?|--method[= ])["'"'"']?POST' \
           || printf '%s' "$CMD" | grep -qE '(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]=]|$)'; then
          IS_PR=1
        fi
      fi
      ;;
  esac
fi
[ "$IS_PR" -eq 0 ] && exit 0

if [ "${ZENSU_PR_GATE:-}" = "off" ]; then
  tdd_record_bypass_payload "$INPUT" ZENSU_PR_GATE 2>/dev/null || true
  exit 0
fi

if printf '%s' "$CMD" | grep -qE '(^|[[:space:]])ZENSU_PR_GATE=off([[:space:]]|$)'; then
  tdd_record_bypass_payload "$INPUT" ZENSU_PR_GATE 2>/dev/null || true
  exit 0
fi

HEAD_SHA="$(git rev-parse HEAD 2>/dev/null)"
[ -z "$HEAD_SHA" ] && HEAD_SHA="$(git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse HEAD 2>/dev/null)"
[ -z "$HEAD_SHA" ] && exit 0
HEAD_TREE="$(git rev-parse "HEAD^{tree}" 2>/dev/null)"
[ -z "$HEAD_TREE" ] && HEAD_TREE="$(git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse "HEAD^{tree}" 2>/dev/null)"

STATE_DIR="${TDD_STATE_DIR:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}"
for m in "$STATE_DIR"/review-pass-*; do
  [ -f "$m" ] || continue
  [ -L "$m" ] && continue
  FIRST="$(head -1 "$m" 2>/dev/null)"
  if [ "$FIRST" = "$HEAD_SHA" ]; then
    exit 0
  fi
  if [ -n "${HEAD_TREE:-}" ] && grep -qE "^tree(-tracked)?: ${HEAD_TREE}\$" "$m" 2>/dev/null; then
    exit 0
  fi
done

HEAD_SHA="$HEAD_SHA" node -e '
  const sha = process.env.HEAD_SHA || "(unknown)";
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason:
        "PR-create gate (hooks.prGate): no review-pass marker matches HEAD " + sha + " (neither by commit nor by reviewed-tree digest). " +
        "The review chain records the reviewed commit at --chain-done; committing after the " +
        "review and then opening a PR would ship unreviewed changes invisibly. Fix: re-run the " +
        "review chain over the new commits (a /zensu:tdd fix round or /zensu:pr-team-review), " +
        "or deliberately bypass with an inline ZENSU_PR_GATE=off prefix — the bypass is " +
        "recorded in the bypass ledger."
    }
  }));
'
echo
exit 0
