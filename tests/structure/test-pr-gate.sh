#!/bin/bash
set -u

# Structure + functional test for the reviewed-at-SHA marker and the optional
# PR-create gate (hooks.prGate, DEFAULT OFF). Functional, in a sandbox git
# repo with TDD_STATE_DIR/ZENSU_CONFIG isolation: --chain-done writes
# review-pass-<sid> with the HEAD SHA as line 1; the gate stays silent by
# default; enabled it denies gh pr create / glab mr create / gh api POST
# pulls without a HEAD-matching marker, allows with one, re-denies on a stale
# marker after a new commit, honors ZENSU_PR_GATE=off (env + inline, recorded
# in the bypass ledger when a session is active), never touches non-PR
# commands, and --tdd-begin clears the marker. Structure: hooks.json wiring,
# README Hooks (15) header + prGate Opt-Out row + ledger gate list,
# config.example.json prGate:false, allowlist extended with ZENSU_PR_GATE.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/pre-bash-pr-gate.sh"
LOG_SH="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
PHASE_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
CFG_LIB="$PLUGIN_DIR/hooks/lib/zensu-config.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
README="$PLUGIN_DIR/README.md"
CFG_EXAMPLE="$PLUGIN_DIR/config.example.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$HOOK" "$LOG_SH" "$PHASE_LIB" "$CFG_LIB" "$HOOKS_JSON" "$README" "$CFG_EXAMPLE"; do
  if [ ! -f "$f" ]; then
    check "P0 required file exists: $f" FAIL
    echo "----"
    echo "test-pr-gate: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "P0 all target files exist" PASS

# P3 — wiring + docs pins (no node/git needed)
if grep -qF 'hooks/pre-bash-pr-gate.sh' "$HOOKS_JSON"; then
  check "P3a hooks.json registers the pr gate" PASS
else
  check "P3a hooks.json registers the pr gate" FAIL
fi
if grep -qF '| `pre-bash-pr-gate.sh` |' "$README"; then
  check "P3b README hooks table carries the pr-gate row (count owned by count-sync test)" PASS
else
  check "P3b README hooks table carries the pr-gate row" FAIL
fi
if grep -qF '| `pre-bash-pr-gate.sh` | PreToolUse `Bash` |' "$README" && grep -qF '**Inverted default — OFF.**' "$README"; then
  check "P3c README hook row + Opt-Out row state the inverted default" PASS
else
  check "P3c README hook row + Opt-Out row state the inverted default" FAIL
fi
if grep -qF '`ZENSU_TEST_WITNESS`, `ZENSU_PR_GATE`' "$README" && grep -qF 'closed seven-gate allowlist' "$README"; then
  check "P3d README ledger paragraph carries the seventh gate" PASS
else
  check "P3d README ledger paragraph carries the seventh gate" FAIL
fi
if grep -qF '"prGate": false' "$CFG_EXAMPLE"; then
  check "P3e config.example.json ships prGate:false" PASS
else
  check "P3e config.example.json ships prGate:false" FAIL
fi
if grep -qE '^ZENSU_BYPASS_GATE_ALLOWLIST=".* ZENSU_PR_GATE"$' "$PHASE_LIB"; then
  check "P3f bypass allowlist extended with ZENSU_PR_GATE" PASS
else
  check "P3f bypass allowlist extended with ZENSU_PR_GATE" FAIL
fi
if grep -qF 'zensu_pr_gate_enabled()' "$CFG_LIB" && grep -qF 'j.hooks.prGate===true' "$CFG_LIB"; then
  check "P3g config helper requires explicit true (default off)" PASS
else
  check "P3g config helper requires explicit true (default off)" FAIL
fi

if ! command -v node >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  echo "  SKIP  node or git not on PATH — functional checks skipped (doc pins above ran)"
  echo "----"
  echo "test-pr-gate: $PASS PASS / $FAIL FAIL (functional skipped)"
  if [ "$FAIL" -gt 0 ]; then exit 1; fi
  exit 0
fi

SBOX="$(mktemp -d 2>/dev/null)" || SBOX=""
if [ -z "$SBOX" ]; then
  check "P1 sandbox creation (mktemp)" FAIL
  echo "----"
  echo "test-pr-gate: $PASS PASS / $FAIL FAIL"
  exit 1
fi
cd "$SBOX" || exit 1
git init -q -b main .
git config user.email t@t.local
git config user.name t
git config commit.gpgsign false
printf 'cfg-*.json\nst/\n' > .gitignore
git add .gitignore
git commit -q -m first
printf '{"hooks":{}}\n' > "$SBOX/cfg-off.json"
printf '{"hooks":{"prGate":true}}\n' > "$SBOX/cfg-on.json"

run_log() {
  TDD_STATE_DIR="$SBOX/st" CLAUDE_PROJECT_DIR="$SBOX" ZENSU_CONFIG="$SBOX/cfg-off.json" \
    bash "$LOG_SH" ${1+"$@"}
}
PR_PAYLOAD='{"session_id":"prfx","tool_name":"Bash","tool_input":{"command":"gh pr create --title x --body y"}}'
run_hook() {
  local payload="$1" cfg="$2"
  printf '%s' "$payload" | TDD_STATE_DIR="$SBOX/st" CLAUDE_PROJECT_DIR="$SBOX" ZENSU_CONFIG="$SBOX/$cfg" \
    bash "$HOOK" 2>/dev/null
}

# (a) --chain-done writes the marker with HEAD line 1
run_log --chain-done --session prfx >/dev/null 2>&1
HEAD1="$(git rev-parse HEAD)"
if [ "$(head -1 "$SBOX/st/review-pass-prfx" 2>/dev/null)" = "$HEAD1" ]; then
  check "P1a chain-done writes review-pass with HEAD line 1" PASS
else
  check "P1a chain-done writes review-pass with HEAD line 1" FAIL
fi
if grep -qF 'session: prfx' "$SBOX/st/review-pass-prfx" 2>/dev/null; then
  check "P1b marker carries session metadata" PASS
else
  check "P1b marker carries session metadata" FAIL
fi

# (b) gate disabled by default
OUT="$(run_hook "$PR_PAYLOAD" cfg-off.json)"
[ -z "$OUT" ] && check "P1c gate silent by default (prGate absent)" PASS || check "P1c gate silent by default (got: $OUT)" FAIL

# (d) enabled + matching marker -> allow
OUT="$(run_hook "$PR_PAYLOAD" cfg-on.json)"
[ -z "$OUT" ] && check "P1d enabled + matching marker allows" PASS || check "P1d enabled + matching marker allows (got: $OUT)" FAIL

# (e) stale marker after a commit with NEW content -> deny (an empty commit
# keeps the same tree and is deliberately allowed by the tree-digest match)
echo stale-content > stale.txt
git add stale.txt
git commit -q -m second
OUT="$(run_hook "$PR_PAYLOAD" cfg-on.json)"
case "$OUT" in
  *'"deny"'*'review-pass marker matches HEAD'*) check "P1e stale marker after new commit denies" PASS ;;
  *) check "P1e stale marker after new commit denies (got: ${OUT:-empty})" FAIL ;;
esac

# (c) enabled + no marker -> deny (fresh session id)
NO_PAYLOAD='{"session_id":"prfx","tool_name":"Bash","tool_input":{"command":"glab mr create --title x"}}'
rm -f "$SBOX"/st/review-pass-*
OUT="$(run_hook "$NO_PAYLOAD" cfg-on.json)"
case "$OUT" in
  *'"deny"'*) check "P1f enabled + no marker denies (glab mr create)" PASS ;;
  *) check "P1f enabled + no marker denies (got: ${OUT:-empty})" FAIL ;;
esac

# (h) gh api POST pulls variant
API_PAYLOAD='{"session_id":"prfx","tool_name":"Bash","tool_input":{"command":"gh api -X POST repos/o/r/pulls -f title=x"}}'
OUT="$(run_hook "$API_PAYLOAD" cfg-on.json)"
case "$OUT" in
  *'"deny"'*) check "P1g gh api POST pulls is gated" PASS ;;
  *) check "P1g gh api POST pulls is gated (got: ${OUT:-empty})" FAIL ;;
esac
GET_PAYLOAD='{"session_id":"prfx","tool_name":"Bash","tool_input":{"command":"gh api repos/o/r/pulls"}}'
OUT="$(run_hook "$GET_PAYLOAD" cfg-on.json)"
[ -z "$OUT" ] && check "P1h gh api GET pulls is not gated" PASS || check "P1h gh api GET pulls is not gated (got: $OUT)" FAIL

# (g) non-PR command untouched
LS_PAYLOAD='{"session_id":"prfx","tool_name":"Bash","tool_input":{"command":"ls -la"}}'
OUT="$(run_hook "$LS_PAYLOAD" cfg-on.json)"
[ -z "$OUT" ] && check "P1i non-PR commands untouched" PASS || check "P1i non-PR commands untouched (got: $OUT)" FAIL

# (f) env bypass allows + records when session active
run_log --tdd-begin --session prfx >/dev/null 2>&1
OUT="$(printf '%s' "$PR_PAYLOAD" | TDD_STATE_DIR="$SBOX/st" CLAUDE_PROJECT_DIR="$SBOX" ZENSU_CONFIG="$SBOX/cfg-on.json" ZENSU_PR_GATE=off bash "$HOOK" 2>/dev/null)"
[ -z "$OUT" ] && check "P1j ZENSU_PR_GATE=off env allows" PASS || check "P1j ZENSU_PR_GATE=off env allows (got: $OUT)" FAIL
LIST="$(run_log --bypass-list --session prfx 2>/dev/null)"
case "$LIST" in
  *ZENSU_PR_GATE*) check "P1k env bypass recorded in the ledger" PASS ;;
  *) check "P1k env bypass recorded in the ledger (got: $LIST)" FAIL ;;
esac

# inline bypass on a PR command
INLINE_PAYLOAD='{"session_id":"prfx","tool_name":"Bash","tool_input":{"command":"ZENSU_PR_GATE=off gh pr create --title x"}}'
OUT="$(run_hook "$INLINE_PAYLOAD" cfg-on.json)"
[ -z "$OUT" ] && check "P1l inline bypass allows a PR command" PASS || check "P1l inline bypass allows (got: $OUT)" FAIL

# tree-digest semantics: dirty tree reviewed -> commit freezing it matches; new content does not
echo reviewed-content > f.txt
git add f.txt
run_log --chain-done --session prfx >/dev/null 2>&1
git -c user.email=t@t -c user.name=t commit -qm freeze
OUT="$(run_hook "$PR_PAYLOAD" cfg-on.json)"
[ -z "$OUT" ] && check "P1n commit freezing the reviewed tree still matches (tree digest)" PASS || check "P1n reviewed-tree commit matches (got: $OUT)" FAIL
echo new-unreviewed >> f.txt
git add f.txt && git -c user.email=t@t -c user.name=t commit -qm extra
OUT="$(run_hook "$PR_PAYLOAD" cfg-on.json)"
case "$OUT" in
  *'"deny"'*) check "P1o commit with NEW content re-denies" PASS ;;
  *) check "P1o commit with NEW content re-denies (got: ${OUT:-empty})" FAIL ;;
esac

# untracked file at review time: digest must include it (house feature flow)
echo untracked-content > u.txt
run_log --chain-done --session prfx >/dev/null 2>&1
git add u.txt
git -c user.email=t@t -c user.name=t commit -qm freeze-untracked
OUT="$(run_hook "$PR_PAYLOAD" cfg-on.json)"
[ -z "$OUT" ] && check "P1w untracked-at-review file committed still matches (temp-index digest)" PASS || check "P1w untracked-at-review digest match (got: $OUT)" FAIL

# tracked-only commit while an unrelated untracked file stays behind
echo tracked-part > t1.txt
git add t1.txt
echo scratch > scratch-leftover.txt
run_log --chain-done --session prfx >/dev/null 2>&1
git -c user.email=t@t -c user.name=t commit -qm tracked-only
OUT="$(run_hook "$PR_PAYLOAD" cfg-on.json)"
[ -z "$OUT" ] && check "P1z staged-only commit matches via tree-tracked digest" PASS || check "P1z staged-only commit via tree-tracked (got: $OUT)" FAIL

# gh api detection variants (marker removed — these pin command detection only)
rm -f "$SBOX"/st/review-pass-*
V1='{"session_id":"prfx","tool_name":"Bash","tool_input":{"command":"gh api --method POST repos/o/r/pulls -f title=x"}}'
OUT="$(run_hook "$V1" cfg-on.json)"
case "$OUT" in *'"deny"'*) check "P1p gh api --method POST pulls is gated" PASS ;; *) check "P1p gh api --method POST pulls (got: ${OUT:-empty})" FAIL ;; esac
V2='{"session_id":"prfx","tool_name":"Bash","tool_input":{"command":"gh api repos/o/r/pulls -f title=x -f head=b -f base=main"}}'
OUT="$(run_hook "$V2" cfg-on.json)"
case "$OUT" in *'"deny"'*) check "P1q gh api pulls with -f fields (implicit POST) is gated" PASS ;; *) check "P1q implicit-POST pulls (got: ${OUT:-empty})" FAIL ;; esac
V3='{"session_id":"prfx","tool_name":"Bash","tool_input":{"command":"gh api -X POST repos/o/r/pulls/123/reviews -f body=x"}}'
OUT="$(run_hook "$V3" cfg-on.json)"
[ -z "$OUT" ] && check "P1r pulls SUBRESOURCE POST (reviews) is NOT gated" PASS || check "P1r pulls subresource not gated (got: $OUT)" FAIL

# inline recording on a fresh session
run_log --tdd-begin --session prfx2 >/dev/null 2>&1
IN2='{"session_id":"prfx2","tool_name":"Bash","tool_input":{"command":"ZENSU_PR_GATE=off gh pr create --title x"}}'
OUT="$(run_hook "$IN2" cfg-on.json)"
[ -z "$OUT" ] && check "P1s inline bypass allows (fresh session)" PASS || check "P1s inline bypass allows (got: $OUT)" FAIL
L2="$(run_log --bypass-list --session prfx2 2>/dev/null)"
[ "$L2" = "ZENSU_PR_GATE" ] && check "P1t inline bypass recorded exactly once" PASS || check "P1t inline bypass recorded (got: $L2)" FAIL

# env bypass on a NON-PR command must not mint a ledger entry
run_log --tdd-begin --session prfx3 >/dev/null 2>&1
LS3='{"session_id":"prfx3","tool_name":"Bash","tool_input":{"command":"ls"}}'
OUT="$(printf '%s' "$LS3" | TDD_STATE_DIR="$SBOX/st" CLAUDE_PROJECT_DIR="$SBOX" ZENSU_CONFIG="$SBOX/cfg-on.json" ZENSU_PR_GATE=off bash "$HOOK" 2>/dev/null)"
[ -z "$OUT" ] && check "P1x env off + non-PR command stays silent" PASS || check "P1x env off + non-PR silent (got: $OUT)" FAIL
L3="$(run_log --bypass-list --session prfx3 2>/dev/null)"
[ "$L3" = "none" ] && check "P1y env off + non-PR command records nothing" PASS || check "P1y env off + non-PR records nothing (got: $L3)" FAIL

# (i) --tdd-begin clears the marker (guarded existence in between)
run_log --chain-done --session prfx >/dev/null 2>&1
if [ -f "$SBOX/st/review-pass-prfx" ]; then
  check "P1u marker exists after chain-done (pre-clear guard)" PASS
else
  check "P1u marker exists after chain-done (pre-clear guard)" FAIL
fi
run_log --tdd-begin --session prfx >/dev/null 2>&1
if [ ! -f "$SBOX/st/review-pass-prfx" ]; then
  check "P1m --tdd-begin clears the review-pass marker" PASS
else
  check "P1m --tdd-begin clears the review-pass marker" FAIL
fi
run_log --chain-done --session prfx >/dev/null 2>&1
run_log --tdd-reset --session prfx >/dev/null 2>&1
if [ ! -f "$SBOX/st/review-pass-prfx" ]; then
  check "P1v --tdd-reset clears the review-pass marker" PASS
else
  check "P1v --tdd-reset clears the review-pass marker" FAIL
fi

cd / && rm -rf "$SBOX" 2>/dev/null

echo "----"
echo "test-pr-gate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
