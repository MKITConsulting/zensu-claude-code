#!/bin/bash
# The post-review hook reads Autopilot ownership from the immutable Session
# Control project root, never from the ambient CLAUDE_PROJECT_DIR:
#   O0 no outer run, honest ambient dir      -> the review directive is emitted (control)
#   O1 no outer run, decoy ambient dir       -> still emitted (regression pin)
#   O2 nonterminal outer run                 -> unbound claim refused, ticket kept
#   O3 the hook reads no ambient project dir -> source guard against reintroduction
# An ambient project dir outside the bound root does not bypass the ownership
# check — the path hardening rejects it (rc=2) and the hook exits silently. That
# is the defect: an exported CLAUDE_PROJECT_DIR could disable the whole
# post-review routing (auto-fix loop, self-review handoff, chain completion)
# while the review itself looked like it had run. O1 is the pin for that.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
HOOK="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
PHASE="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
AUTOPILOT="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

PASS=0
FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS + 1));
  else echo "  FAIL  $label"; FAIL=$((FAIL + 1)); fi
}

ROOT="$(mktemp -d -t zensu-outer-root-XXXXXX)"
ROOT="$(cd "$ROOT" && pwd -P)"
DECOY="$ROOT/decoy"
mkdir -p "$DECOY"
DECOY="$(cd "$DECOY" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_CONFIG="$ROOT/no-config.json"
unset CLAUDE_PLUGIN_DATA ZENSU_PROJECT_ROOT ZENSU_SESSION_CONTEXT ZENSU_SESSION_KEY \
  ZENSU_TEST_PLUGIN_DATA 2>/dev/null || true

# shellcheck disable=SC1090
source "$PHASE"
# shellcheck disable=SC1090
source "$AUTOPILOT"

MARKER='PRE-MERGED FINDINGS (fan-out)'

# Arm a standalone chain in its own project root and issue its review ticket.
ARMED_PROJECT=""
ARMED_KEY=""
ARMED_TICKET=""
arm() {
  local label="$1"
  local project="$ROOT/$label"
  mkdir -p "$project"
  project="$(cd "$project" && pwd -P)"
  export CLAUDE_PROJECT_DIR="$project"
  export ZENSU_TEST_PLUGIN_DATA="$ROOT/plugin-data-$label"
  # shellcheck disable=SC1090
  source "$BASELINE" "$label" || return 1
  bash "$LOG" --tdd-begin --session "$ZENSU_SESSION_KEY" >/dev/null 2>&1 || return 1
  bash "$LOG" --tdd-complete --session "$ZENSU_SESSION_KEY" >/dev/null 2>&1 || return 1
  ARMED_TICKET="$(bash "$LOG" --review-ticket --session "$ZENSU_SESSION_KEY" 2>/dev/null)"
  [ -n "$ARMED_TICKET" ] || return 1
  ARMED_PROJECT="$ZENSU_PROJECT_ROOT"
  ARMED_KEY="$ZENSU_SESSION_KEY"
}

# Drive the hook with an explicit ambient project dir, as an exported
# CLAUDE_PROJECT_DIR would reach it.
run_hook() {
  local ambient="$1" ticket="$2"
  SID="$CLAUDE_CODE_SESSION_ID" TICKET="$ticket" MARKER="$MARKER" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: "PostToolUse",
      tool_name: "Agent",
      tool_input: {
        subagent_type: "zensu:code-reviewer",
        prompt: `${process.env.MARKER}\nREVIEW-TICKET: ${process.env.TICKET}\nVerdict: PASS`
      },
      session_id: process.env.SID
    }));
  ' | env CLAUDE_PROJECT_DIR="$ambient" bash "$HOOK" 2>/dev/null
}

run_hook_in() {
  local cwd="$1" ambient="$2" ticket="$3"
  SID="$CLAUDE_CODE_SESSION_ID" TICKET="$ticket" MARKER="$MARKER" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: "PostToolUse",
      tool_name: "Agent",
      tool_input: {
        subagent_type: "zensu:code-reviewer",
        prompt: `${process.env.MARKER}\nREVIEW-TICKET: ${process.env.TICKET}\nVerdict: PASS`
      },
      session_id: process.env.SID
    }));
  ' | ( cd "$cwd" && env CLAUDE_PROJECT_DIR="$ambient" bash "$HOOK" 2>/dev/null )
}

ticket_consumed() {
  FILE="$1" node -e '
    try {
      const s = JSON.parse(require("fs").readFileSync(process.env.FILE, "utf8"));
      process.exit(s.reviewTicket === "" && s.reviewRound >= 1 ? 0 : 1);
    } catch (_) { process.exit(1); }
  ' 2>/dev/null
}

# --- O0 control: no outer run at all -> the unbound claim proceeds ---
arm outer-none || { echo "O0 fixture failed" >&2; exit 1; }
OUT0="$(run_hook "$ARMED_PROJECT" "$ARMED_TICKET")"
if [ -n "$OUT0" ]; then
  check "O0 no outer run -> unbound claim proceeds and the hook routes" PASS
else
  check "O0 no outer run (no directive emitted)" FAIL
fi

# --- O1 the same routing must survive a decoy ambient project dir ---
arm outer-decoy || { echo "O1 fixture failed" >&2; exit 1; }
OUT1="$(run_hook "$DECOY" "$ARMED_TICKET")"
if [ -n "$OUT1" ]; then
  check "O1 a decoy CLAUDE_PROJECT_DIR cannot silence the post-review routing" PASS
else
  check "O1 decoy ambient dir emitted no directive" FAIL
fi

# --- O2 a nonterminal outer run still refuses the unbound claim ---
arm outer-owned || { echo "O2 fixture failed" >&2; exit 1; }
OWNED_PROJECT="$ARMED_PROJECT"
OWNED_STATE="$(tdd_state_file "$ARMED_KEY")"
# The outer run must be owned by the session under test: a run owned by
# another session is not this session's outer run and legitimately leaves
# its chain unbound.
autopilot_begin_run outer-owned-run "$ARMED_KEY" "$OWNED_PROJECT" >/dev/null 2>&1 \
  || { echo "O2 fixture: outer run could not be started" >&2; exit 1; }
OUT2="$(run_hook "$OWNED_PROJECT" "$ARMED_TICKET")"
if [ -z "$OUT2" ]; then
  check "O2 nonterminal outer run refuses the unbound claim" PASS
else
  check "O2 owned project (out='$OUT2')" FAIL
fi
if ! ticket_consumed "$OWNED_STATE"; then
  check "O2a the one-shot review ticket survives the refusal unconsumed" PASS
else
  check "O2a review ticket was consumed despite the refusal" FAIL
fi

# --- O2b a foreign nonterminal run HOLDING THIS WORKING TREE ---
# Two independent questions meet here and only the first is about ownership.
# WHOSE outer generation is this chain bound to stays owner-scoped — a foreign
# run is not this session's outer generation. But whether anyone else holds the
# TREE is owner-independent, and the arm-time gate cannot answer it for this
# moment: arming happens once, this hook runs on every qualifying PostToolUse,
# so a durable run begun in this tree afterwards sits in a window the arm-time
# gate has already left. This preflight covered that window project-wide before
# PR #256 narrowed it; O2c is the control that the narrowing is not simply undone.
arm outer-foreign || { echo "O2b fixture failed" >&2; exit 1; }
FOREIGN_PROJECT="$ARMED_PROJECT"
FOREIGN_STATE="$(tdd_state_file "$ARMED_KEY")"
autopilot_begin_run outer-foreign-run outer_foreign_other_session "$FOREIGN_PROJECT" >/dev/null 2>&1 \
  || { echo "O2b fixture: foreign outer run could not be started" >&2; exit 1; }
OUT2B="$(run_hook "$FOREIGN_PROJECT" "$ARMED_TICKET")"
if [ -z "$OUT2B" ]; then
  check "O2b a foreign run holding this working tree refuses the unbound claim" PASS
else
  check "O2b foreign holder must refuse (out='$OUT2B')" FAIL
fi
if ! ticket_consumed "$FOREIGN_STATE"; then
  check "O2b1 the review ticket survives the foreign-holder refusal unconsumed" PASS
else
  check "O2b1 review ticket was consumed despite the foreign-holder refusal" FAIL
fi

# --- O2c the same foreign run holding a DIFFERENT tree of the same project ---
# The mandatory positive control. Without it, refusing every foreign run —
# which is strictly more than the occupancy question asks — would leave O2b
# green while every standalone claim in the project was blocked. Real git
# worktrees are required: two plain directories have no toplevel of their own,
# so both collapse onto the project root and the trees cannot differ.
arm outer-sibling || { echo "O2c fixture failed" >&2; exit 1; }
SIBLING_PROJECT="$ARMED_PROJECT"
SIBLING_READY=true
command -v git >/dev/null 2>&1 || SIBLING_READY=false
if [ "$SIBLING_READY" = true ]; then
  mkdir -p "$SIBLING_PROJECT/.claude/worktrees"
  git -C "$SIBLING_PROJECT" init -q >/dev/null 2>&1 || SIBLING_READY=false
  git -C "$SIBLING_PROJECT" -c user.email=t@example.invalid -c user.name=t \
    commit -q --allow-empty -m init >/dev/null 2>&1 || SIBLING_READY=false
  git -C "$SIBLING_PROJECT" worktree add -q "$SIBLING_PROJECT/.claude/worktrees/pa" -b pf-a >/dev/null 2>&1 \
    || SIBLING_READY=false
  git -C "$SIBLING_PROJECT" worktree add -q "$SIBLING_PROJECT/.claude/worktrees/pb" -b pf-b >/dev/null 2>&1 \
    || SIBLING_READY=false
fi
OUT2C=""
if [ "$SIBLING_READY" = true ]; then
  autopilot_begin_run outer-sibling-run outer_sibling_other_session "$SIBLING_PROJECT" \
    false true "$SIBLING_PROJECT/.claude/worktrees/pa" >/dev/null 2>&1 || SIBLING_READY=false
fi
if [ "$SIBLING_READY" = true ]; then
  OUT2C="$(run_hook_in "$SIBLING_PROJECT/.claude/worktrees/pb" "$SIBLING_PROJECT" "$ARMED_TICKET")"
fi
# "The claim proceeded" means the UNBOUND routing directive was emitted — the
# one that hands the terminus to --code-review-done — and not an Autopilot-bound
# one. Asserting only that some text appeared would not tell those apart.
if [ "$SIBLING_READY" != true ]; then
  check "O2c sibling-worktree fixture unavailable" FAIL
elif printf '%s' "$OUT2C" | grep -qF -- '--code-review-done' \
  && ! printf '%s' "$OUT2C" | grep -qF 'ZENSU_AUTOPILOT'; then
  check "O2c a foreign run holding a sibling tree leaves this chain unbound and permits the claim" PASS
else
  check "O2c sibling-tree claim must proceed (out='$OUT2C')" FAIL
fi

# --- O3 the hook must not read an ambient project dir anywhere ---
AMBIENT_READS="$(grep -c 'CLAUDE_PROJECT_DIR:-' "$HOOK" || true)"
RESOLVER_CALLS="$(grep -c 'zensu_resolve_project_dir' "$HOOK" || true)"
if [ "$AMBIENT_READS" -eq 0 ] && [ "$RESOLVER_CALLS" -ge 1 ]; then
  check "O3 the hook resolves its project root and reads no ambient fallback" PASS
else
  check "O3 project-root sourcing (ambient=$AMBIENT_READS resolver=$RESOLVER_CALLS)" FAIL
fi

echo "----"
echo "test-post-review-outer-ownership-root: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
