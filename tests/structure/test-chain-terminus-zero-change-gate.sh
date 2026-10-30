#!/bin/bash
# Pins the ZERO-file-change gate on the unqualified --chain-done terminus and the
# unqualified --code-review-done mark (both without --claimed-review-ticket):
#   G1 clean worktree                -> terminus allowed (the sanctioned escape)
#   G2 modified tracked file          -> refused, chainDone stays false
#   G3 untracked non-ignored file     -> refused (git ls-files --others)
#   G4 ignored-only change            -> allowed (--exclude-standard)
#   G5 --claimed-review-ticket form   -> gate never fires (terminus is ticket-bound)
#   G6 --code-review-done (unqualified) -> refused on a changed tree, codeReviewDone stays false
#   G7 non-git project root           -> allowed (claim not evaluable)
#   G8 git repo without a HEAD commit -> allowed (claim not evaluable)
# The unqualified forms can only ever bind a chain in which no review ticket was
# consumed, so they are the commands that could close a chain over unreviewed
# changes. Complements test-stop-enforcer-escapes.sh (release paths) and
# test-stop-enforcer-self-review-routing.sh (block + routing).
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
TDD_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
POSTREV="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
STATE_DIR="$(mktemp -d)"; export STATE_DIR
export ZENSU_TEST_PLUGIN_DATA="$STATE_DIR/plugin-data"
export ZENSU_CONFIG="$STATE_DIR/no-such-config.json"
GIT_PROJ="$(mktemp -d)"
BARE_PROJ="$(mktemp -d)"
PLAIN_PROJ="$(mktemp -d)"
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN 2>/dev/null || true
cleanup() { rm -rf "$STATE_DIR" "$GIT_PROJ" "$BARE_PROJ" "$PLAIN_PROJ"; }
trap cleanup EXIT
# shellcheck disable=SC1090
source "$TDD_LIB"

git -C "$GIT_PROJ" init -q 2>/dev/null
git -C "$GIT_PROJ" config user.email t@t
git -C "$GIT_PROJ" config user.name t
printf '.zensu/\n.session-control-test/\n' > "$GIT_PROJ/.gitignore"
printf 'baseline\n' > "$GIT_PROJ/tracked.txt"
git -C "$GIT_PROJ" add .gitignore tracked.txt >/dev/null 2>&1
git -C "$GIT_PROJ" -c commit.gpgsign=false commit -qm baseline >/dev/null 2>&1
git -C "$BARE_PROJ" init -q 2>/dev/null

# Arm a standalone chain in $CLAUDE_PROJECT_DIR: active + implComplete, chainDone=false.
arm() {
  local sid="$1"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$sid"
  bash "$LOG" --tdd-begin --session "$sid" >/dev/null 2>&1
  bash "$LOG" --tdd-complete --session "$sid" >/dev/null 2>&1
}

GATE_PHRASE="refusing the unqualified standalone terminus"
REVIEW_GATE_PHRASE="refusing the unqualified review-convergence mark"
LISTING_PHRASE="git could not list this worktree"
READABLE_HINT="the chain state is readable"
MINTED_GATE_PHRASE="refusing to close a chain that no reviewer saw"
REOPEN_PHRASE="The chain's review is reopened"

export CLAUDE_PROJECT_DIR="$GIT_PROJ"

# --- G1 clean worktree: the sanctioned zero-change escape still closes ---
SID1="terminus-clean"
arm "$SID1"
ERR1="$STATE_DIR/g1.err"
bash "$LOG" --chain-done --session "$SID1" >/dev/null 2>"$ERR1"; RC1=$?
DONE1="$(tdd_chain_done "$(tdd_state_file "$SID1")" 2>/dev/null)"
if [ "$RC1" -eq 0 ] && [ "$DONE1" = "true" ] && [ ! -s "$ERR1" ]; then
  check "G1 clean worktree -> unqualified terminus closes the chain" PASS
else
  check "G1 clean worktree (rc=$RC1 chainDone=$DONE1 err='$(cat "$ERR1" 2>/dev/null)')" FAIL
fi

# --- G2 modified tracked file: refused, chain stays open ---
SID2="terminus-modified"
arm "$SID2"
printf 'changed\n' > "$GIT_PROJ/tracked.txt"
ERR2="$STATE_DIR/g2.err"
bash "$LOG" --chain-done --session "$SID2" >/dev/null 2>"$ERR2"; RC2=$?
DONE2="$(tdd_chain_done "$(tdd_state_file "$SID2")" 2>/dev/null)"
if [ "$RC2" -ne 0 ] && [ "$DONE2" != "true" ] && grep -qF "$GATE_PHRASE" "$ERR2"; then
  check "G2 modified tracked file -> terminus refused, chainDone stays false" PASS
else
  check "G2 modified tracked file (rc=$RC2 chainDone=$DONE2 err='$(cat "$ERR2" 2>/dev/null)')" FAIL
fi
if grep -qF "reports 1 changed file(s)" "$ERR2"; then
  check "G2a refusal names the exact changed-file count" PASS
else
  check "G2a refusal changed-file count (err='$(cat "$ERR2" 2>/dev/null)')" FAIL
fi
if grep -qF -- "--claimed-review-ticket" "$ERR2" && grep -qF "/zensu:build" "$ERR2"; then
  check "G2b refusal names both runnable continuations" PASS
else
  check "G2b refusal continuations (err='$(cat "$ERR2" 2>/dev/null)')" FAIL
fi
if grep -qF "holds no consumed review ticket" "$ERR2" && grep -qF "Do not commit, stash or revert" "$ERR2" \
  && ! grep -qF "ever consumed" "$ERR2"; then
  check "G2c refusal states the ticket state and warns against hiding the changes" PASS
else
  check "G2c refusal wording (err='$(cat "$ERR2" 2>/dev/null)')" FAIL
fi

# --- G6 --code-review-done (unqualified) is refused on a changed tree ---
ERR6="$STATE_DIR/g6.err"
bash "$LOG" --code-review-done --session "$SID2" >/dev/null 2>"$ERR6"; RC6=$?
CRD6="$(tdd_code_review_done "$(tdd_state_file "$SID2")" 2>/dev/null)"
if [ "$RC6" -eq 1 ] && [ "$CRD6" = "false" ] \
  && grep -qF "$REVIEW_GATE_PHRASE" "$ERR6" && grep -qF "reports 1 changed file(s)" "$ERR6" \
  && grep -qF -- "--review-ticket" "$ERR6" && grep -qF "Do not commit, stash or revert" "$ERR6" \
  && ! grep -qF "$GATE_PHRASE" "$ERR6" && ! grep -qF "$READABLE_HINT" "$ERR6"; then
  check "G6 --code-review-done (unqualified) refused on a changed tree, codeReviewDone stays false" PASS
else
  check "G6 --code-review-done (rc=$RC6 codeReviewDone=$CRD6 err='$(cat "$ERR6" 2>/dev/null)')" FAIL
fi

# --- G5 ticket-bound terminus: gate must not fire (it fails on the ticket) ---
ERR5="$STATE_DIR/g5.err"
bash "$LOG" --chain-done --session "$SID2" --claimed-review-ticket "rt_deadbeef" \
  >/dev/null 2>"$ERR5"; RC5=$?
if [ "$RC5" -ne 0 ] && ! grep -qF "$GATE_PHRASE" "$ERR5"; then
  check "G5 --claimed-review-ticket form never reaches the gate" PASS
else
  check "G5 ticket-bound form (rc=$RC5 err='$(cat "$ERR5" 2>/dev/null)')" FAIL
fi
git -C "$GIT_PROJ" checkout -- tracked.txt >/dev/null 2>&1

# --- G3 untracked non-ignored file: refused ---
SID3="terminus-untracked"
arm "$SID3"
printf 'new\n' > "$GIT_PROJ/untracked.txt"
ERR3="$STATE_DIR/g3.err"
bash "$LOG" --chain-done --session "$SID3" >/dev/null 2>"$ERR3"; RC3=$?
DONE3="$(tdd_chain_done "$(tdd_state_file "$SID3")" 2>/dev/null)"
if [ "$RC3" -ne 0 ] && [ "$DONE3" != "true" ] && grep -qF "$GATE_PHRASE" "$ERR3"; then
  check "G3 untracked non-ignored file -> terminus refused" PASS
else
  check "G3 untracked file (rc=$RC3 chainDone=$DONE3 err='$(cat "$ERR3" 2>/dev/null)')" FAIL
fi
rm -f "$GIT_PROJ/untracked.txt"

G14_HOME="$STATE_DIR/g14-home"
G14_SAFE_HOME="$STATE_DIR/g14-safe-home"
mkdir -p "$G14_HOME" "$G14_SAFE_HOME"
printf '[safe]\n\tdirectory = *\n' > "$G14_SAFE_HOME/.gitconfig"
foreign_owner() {
  HOME="$G14_HOME" XDG_CONFIG_HOME="$G14_HOME/.config" GIT_CONFIG_NOSYSTEM=1 \
    GIT_TEST_ASSUME_DIFFERENT_OWNER=1 "$@"
}
foreign_owner_excepted() {
  HOME="$G14_SAFE_HOME" XDG_CONFIG_HOME="$G14_SAFE_HOME/.config" GIT_CONFIG_NOSYSTEM=1 \
    GIT_TEST_ASSUME_DIFFERENT_OWNER=1 "$@"
}
G14_ERR="$(foreign_owner env LC_ALL=C git -C "$GIT_PROJ" rev-parse --is-inside-work-tree 2>&1 >/dev/null)"; G14_RC=$?
if [ "$G14_RC" -ne 0 ] && printf '%s\n' "$G14_ERR" | grep -qF "dubious ownership" \
  && ! printf '%s\n' "$G14_ERR" | grep -qiF "not a git repository"; then
  check "G14-control real git refuses the fixture repository as owned by another user" PASS
else
  check "G14-control dubious-ownership refusal (rc=$G14_RC err='$G14_ERR')" FAIL
fi
if [ "$(foreign_owner_excepted git -C "$GIT_PROJ" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]; then
  check "G14-control a safe.directory exception in the same HOME clears the refusal" PASS
else
  check "G14-control a safe.directory exception in the same HOME clears the refusal" FAIL
fi
SID14A="unqualified-dubious-owner"
arm "$SID14A"
SF14A="$(tdd_state_file "$SID14A")"
ERR14B="$STATE_DIR/g14b.err"
foreign_owner bash "$LOG" --code-review-done --session "$SID14A" >/dev/null 2>"$ERR14B"; RC14B=$?
CRD14B="$(tdd_code_review_done "$SF14A" 2>/dev/null)"
if [ "$RC14B" -eq 1 ] && [ "$CRD14B" = "false" ] && grep -qF "$REVIEW_GATE_PHRASE" "$ERR14B" \
  && grep -qF "$LISTING_PHRASE" "$ERR14B" && ! grep -qF "changed file(s)" "$ERR14B"; then
  check "G14b a safe.directory refusal refuses the unqualified review mark on a clean tree" PASS
else
  check "G14b dubious owner on --code-review-done (rc=$RC14B codeReviewDone=$CRD14B err='$(cat "$ERR14B" 2>/dev/null)')" FAIL
fi
ERR14A="$STATE_DIR/g14a.err"
foreign_owner bash "$LOG" --chain-done --session "$SID14A" >/dev/null 2>"$ERR14A"; RC14A=$?
DONE14A="$(tdd_chain_done "$SF14A" 2>/dev/null)"
if [ "$RC14A" -eq 1 ] && [ "$DONE14A" = "false" ] && grep -qF "$GATE_PHRASE" "$ERR14A" \
  && grep -qF "$LISTING_PHRASE" "$ERR14A" && ! grep -qF "changed file(s)" "$ERR14A"; then
  check "G14a a safe.directory refusal refuses the unqualified terminus on a clean tree" PASS
else
  check "G14a dubious owner on --chain-done (rc=$RC14A chainDone=$DONE14A err='$(cat "$ERR14A" 2>/dev/null)')" FAIL
fi
ERR14C="$STATE_DIR/g14c.err"
foreign_owner_excepted bash "$LOG" --chain-done --session "$SID14A" >/dev/null 2>"$ERR14C"; RC14C=$?
DONE14C="$(tdd_chain_done "$SF14A" 2>/dev/null)"
if [ "$RC14C" -eq 0 ] && [ "$DONE14C" = "true" ]; then
  check "G14c the same clean-tree chain closes once a safe.directory exception clears the refusal" PASS
else
  check "G14c excepted owner on --chain-done (rc=$RC14C chainDone=$DONE14C err='$(cat "$ERR14C" 2>/dev/null)')" FAIL
fi
WORK_TREE_PROBE='process.stdout.write(String(require(process.argv[1]).workTree(process.argv[2]).applicable))'
G14D_REFUSED="$(foreign_owner node -e "$WORK_TREE_PROBE" "$PLUGIN_DIR/hooks/lib/evidence-run-v1.js" "$GIT_PROJ" 2>/dev/null)"
G14D_OUTSIDE="$(node -e "$WORK_TREE_PROBE" "$PLUGIN_DIR/hooks/lib/evidence-run-v1.js" "$PLAIN_PROJ" 2>/dev/null)"
if [ "$G14D_REFUSED" = "null" ] && [ "$G14D_OUTSIDE" = "false" ]; then
  check "G14d the full-suite gate reads the same refusal as unavailable and a root outside git as not applicable" PASS
else
  check "G14d evidence-runner workTree parity (refused='$G14D_REFUSED' outside='$G14D_OUTSIDE')" FAIL
fi

G15_BIN="$STATE_DIR/g15-bin"
mkdir -p "$G15_BIN"
cat > "$G15_BIN/git" <<'STUB'
#!/bin/bash
seen=""
for arg in "$@"; do
  case "$arg" in
    (rev-parse) seen="${seen}r" ;;
    (--verify) seen="${seen}v" ;;
    (HEAD) seen="${seen}h" ;;
  esac
done
case "$seen" in
  (rvh) echo "fatal: stub git refuses to resolve HEAD" >&2; exit 128 ;;
esac
exec "$G15_REAL_GIT" "$@"
STUB
chmod +x "$G15_BIN/git"
G15_REAL_GIT="$(command -v git)"; export G15_REAL_GIT
G15_INSIDE="$("$G15_BIN/git" -C "$GIT_PROJ" rev-parse --is-inside-work-tree 2>/dev/null)"
"$G15_BIN/git" -C "$GIT_PROJ" rev-parse --verify --quiet HEAD >/dev/null 2>&1; G15_HEAD_RC=$?
if [ "$G15_INSIDE" = "true" ] && [ "$G15_HEAD_RC" -eq 128 ] \
  && git -C "$GIT_PROJ" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  check "G15-control the stub git fails only the HEAD probe, with a git error rather than a missing revision" PASS
else
  check "G15-control stub HEAD probe (inside='$G15_INSIDE' head_rc=$G15_HEAD_RC)" FAIL
fi
SID15A="unqualified-head-probe-error"
arm "$SID15A"
SF15A="$(tdd_state_file "$SID15A")"
ERR15B="$STATE_DIR/g15b.err"
PATH="$G15_BIN:$PATH" bash "$LOG" --code-review-done --session "$SID15A" >/dev/null 2>"$ERR15B"; RC15B=$?
CRD15B="$(tdd_code_review_done "$SF15A" 2>/dev/null)"
if [ "$RC15B" -eq 1 ] && [ "$CRD15B" = "false" ] && grep -qF "$REVIEW_GATE_PHRASE" "$ERR15B" \
  && grep -qF "$LISTING_PHRASE" "$ERR15B" && ! grep -qF "changed file(s)" "$ERR15B"; then
  check "G15b a HEAD probe that git aborts refuses the unqualified review mark" PASS
else
  check "G15b HEAD probe error on --code-review-done (rc=$RC15B codeReviewDone=$CRD15B err='$(cat "$ERR15B" 2>/dev/null)')" FAIL
fi
ERR15A="$STATE_DIR/g15a.err"
PATH="$G15_BIN:$PATH" bash "$LOG" --chain-done --session "$SID15A" >/dev/null 2>"$ERR15A"; RC15A=$?
DONE15A="$(tdd_chain_done "$SF15A" 2>/dev/null)"
if [ "$RC15A" -eq 1 ] && [ "$DONE15A" = "false" ] && grep -qF "$GATE_PHRASE" "$ERR15A" \
  && grep -qF "$LISTING_PHRASE" "$ERR15A" && ! grep -qF "changed file(s)" "$ERR15A"; then
  check "G15a a HEAD probe that git aborts refuses the unqualified terminus" PASS
else
  check "G15a HEAD probe error on --chain-done (rc=$RC15A chainDone=$DONE15A err='$(cat "$ERR15A" 2>/dev/null)')" FAIL
fi

# --- G4 ignored-only change: allowed ---
SID4="terminus-ignored"
arm "$SID4"
mkdir -p "$GIT_PROJ/.zensu"
printf 'scratch\n' > "$GIT_PROJ/.zensu/scratch.txt"
ERR4="$STATE_DIR/g4.err"
bash "$LOG" --chain-done --session "$SID4" >/dev/null 2>"$ERR4"; RC4=$?
DONE4="$(tdd_chain_done "$(tdd_state_file "$SID4")" 2>/dev/null)"
if [ "$RC4" -eq 0 ] && [ "$DONE4" = "true" ]; then
  check "G4 gitignored-only change -> terminus allowed" PASS
else
  check "G4 ignored-only change (rc=$RC4 chainDone=$DONE4 err='$(cat "$ERR4" 2>/dev/null)')" FAIL
fi

SID9="review-mark-clean"
arm "$SID9"
ERR9="$STATE_DIR/g9.err"
bash "$LOG" --code-review-done --session "$SID9" >/dev/null 2>"$ERR9"; RC9=$?
CRD9="$(tdd_code_review_done "$(tdd_state_file "$SID9")" 2>/dev/null)"
if [ "$RC9" -eq 0 ] && [ "$CRD9" = "true" ] && [ ! -s "$ERR9" ]; then
  check "G9 clean worktree -> unqualified --code-review-done marks the review" PASS
else
  check "G9 clean worktree --code-review-done (rc=$RC9 codeReviewDone=$CRD9 err='$(cat "$ERR9" 2>/dev/null)')" FAIL
fi
printf 'changed\n' > "$GIT_PROJ/tracked.txt"
ERR9C="$STATE_DIR/g9c.err"
bash "$LOG" --chain-done --session "$SID9" >/dev/null 2>"$ERR9C"; RC9C=$?
DONE9C="$(tdd_chain_done "$(tdd_state_file "$SID9")" 2>/dev/null)"
if [ "$RC9C" -eq 1 ] && [ "$DONE9C" = "false" ] && grep -qF "$GATE_PHRASE" "$ERR9C" \
  && grep -qF "reports 1 changed file(s)" "$ERR9C"; then
  check "G9c a review mark taken on a clean tree does not open the terminus on a changed one" PASS
else
  check "G9c terminus after a clean-tree mark (rc=$RC9C chainDone=$DONE9C err='$(cat "$ERR9C" 2>/dev/null)')" FAIL
fi
git -C "$GIT_PROJ" checkout -- tracked.txt >/dev/null 2>&1

SID14="minted-ticket-changed"
arm "$SID14"
SF14="$(tdd_state_file "$SID14")"
bash "$LOG" --code-review-done --session "$SID14" >/dev/null 2>&1
STOP14="$(SID_VALUE="$SID14" node -e '
  process.stdout.write(JSON.stringify({ hook_event_name: "Stop", session_id: process.env.SID_VALUE }));
' | bash "$STOP" 2>/dev/null)"
REASON14="$(printf '%s' "$STOP14" | node -e '
  let s = ""; process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      if (j.decision === "block" && typeof j.reason === "string") process.stdout.write(j.reason);
    } catch (_) {}
  });
' 2>/dev/null)"
ZC14="$(bash "$LOG" --current-review-ticket --session "$SID14" 2>/dev/null)"
case "$ZC14" in (zc_?*) ZC14_SHAPE=zc ;; (*) ZC14_SHAPE=other ;; esac
if [ "$ZC14_SHAPE" = "zc" ] && printf '%s' "$REASON14" | grep -qF "SELF-REVIEW-TICKET: $ZC14" \
  && printf '%s' "$REASON14" | grep -qF "skill='zensu:self-review'" \
  && printf '%s' "$REASON14" | grep -qF "No reviewer ran in this chain" \
  && ! printf '%s' "$REASON14" | grep -qF "The code-reviewer chain has converged"; then
  check "G9d the Stop hook mints a zc_ self-review ticket for a clean-tree mark and says no reviewer ran" PASS
else
  check "G9d minted self-review ticket (ticket='$ZC14' reason='$REASON14')" FAIL
fi
printf 'changed\n' > "$GIT_PROJ/tracked.txt"
ERR14="$STATE_DIR/g9e.err"
bash "$LOG" --chain-done --session "$SID14" --claimed-review-ticket "$ZC14" >/dev/null 2>"$ERR14"; RC14=$?
DONE14="$(tdd_chain_done "$SF14" 2>/dev/null)"
if [ "$RC14" -eq 1 ] && [ "$DONE14" = "false" ] && grep -qF "$MINTED_GATE_PHRASE" "$ERR14" \
  && grep -qF "reports 1 changed file(s)" "$ERR14" && grep -qF "$REOPEN_PHRASE" "$ERR14" \
  && grep -qF -- "--review-ticket" "$ERR14" && grep -qF "Do not commit, stash or revert" "$ERR14" \
  && ! grep -qF "FULL SUITE" "$ERR14" && ! grep -qF "ACCEPTANCE" "$ERR14" \
  && ! grep -qF "$READABLE_HINT" "$ERR14"; then
  check "G9e the minted ticket cannot close the chain over a changed tree, and the count runs ahead of the suite gates" PASS
else
  check "G9e minted-ticket terminus on a changed tree (rc=$RC14 chainDone=$DONE14 err='$(cat "$ERR14" 2>/dev/null)')" FAIL
fi
CRD14="$(tdd_code_review_done "$SF14" 2>/dev/null)"
SRF14="$(tdd_self_review_fixed "$SF14" 2>/dev/null)"
bash "$LOG" --current-review-ticket --session "$SID14" >/dev/null 2>&1; CUR14_RC=$?
SHAPE14="$(bash "$LOG" --chain-status --session "$SID14" 2>/dev/null | node -e '
  let s = ""; process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => { try { process.stdout.write(String(JSON.parse(s).shape)); } catch (_) {} });
' 2>/dev/null)"
if [ "$CRD14" = "false" ] && [ "$SRF14" = "false" ] && [ "$CUR14_RC" -ne 0 ] \
  && [ "$SHAPE14" = "ready-for-review" ]; then
  check "G9f the refusal reopens the review: the mark and the minted ticket are withdrawn together" PASS
else
  check "G9f reopened review (codeReviewDone=$CRD14 selfReviewFixed=$SRF14 current-ticket-rc=$CUR14_RC shape=$SHAPE14)" FAIL
fi
ERR14G="$STATE_DIR/g9g.err"
bash "$LOG" --chain-done --session "$SID14" --claimed-review-ticket "$ZC14" >/dev/null 2>"$ERR14G"; RC14G=$?
DONE14G="$(tdd_chain_done "$SF14" 2>/dev/null)"
CRD14G="$(tdd_code_review_done "$SF14" 2>/dev/null)"
if [ "$RC14G" -eq 1 ] && [ "$DONE14G" = "false" ] && [ "$CRD14G" = "false" ] \
  && grep -qF "$READABLE_HINT" "$ERR14G" && ! grep -qF "$MINTED_GATE_PHRASE" "$ERR14G"; then
  check "G9g the withdrawn ticket is stale: a retry gets the state hint and changes nothing" PASS
else
  check "G9g stale minted ticket (rc=$RC14G chainDone=$DONE14G codeReviewDone=$CRD14G err='$(cat "$ERR14G" 2>/dev/null)')" FAIL
fi
RT14="$(bash "$LOG" --review-ticket --session "$SID14" 2>/dev/null)"
case "$RT14" in
  (rt_?*) check "G9h the reopened chain takes a reviewer ticket, which keeps the rt_ prefix" PASS ;;
  (*) check "G9h reviewer ticket on the reopened chain (ticket='$RT14')" FAIL ;;
esac
git -C "$GIT_PROJ" checkout -- tracked.txt >/dev/null 2>&1

SID15="minted-ticket-clean"
arm "$SID15"
SF15="$(tdd_state_file "$SID15")"
bash "$LOG" --code-review-done --session "$SID15" >/dev/null 2>&1
ZC15="$(tdd_ensure_self_review_ticket "$(zensu_resolve_session_id "$SID15" 2>/dev/null)" 2>/dev/null)"
ERR15="$STATE_DIR/g9i.err"
ZENSU_FULL_SUITE_GATE=off ZENSU_ACCEPTANCE_GATE=off \
  bash "$LOG" --chain-done --session "$SID15" --claimed-review-ticket "$ZC15" >/dev/null 2>"$ERR15"; RC15=$?
DONE15="$(tdd_chain_done "$SF15" 2>/dev/null)"
case "$ZC15" in (zc_?*) ZC15_SHAPE=zc ;; (*) ZC15_SHAPE=other ;; esac
if [ "$ZC15_SHAPE" = "zc" ] && [ "$RC15" -eq 0 ] && [ "$DONE15" = "true" ] \
  && ! grep -qF "$MINTED_GATE_PHRASE" "$ERR15"; then
  check "G9i a minted ticket still closes the chain while the tree reports no change (control for G9e)" PASS
else
  check "G9i minted ticket on a clean tree (ticket='$ZC15' rc=$RC15 chainDone=$DONE15 err='$(cat "$ERR15" 2>/dev/null)')" FAIL
fi

SID10="review-ticket-consumed"
arm "$SID10"
TICKET10="$(bash "$LOG" --review-ticket --session "$SID10" 2>/dev/null)"
CTX10="$(SID_VALUE="$SID10" TICKET="$TICKET10" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: "PostToolUse",
    tool_name: "Agent",
    tool_input: {
      subagent_type: "zensu:code-reviewer",
      prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nfixture`
    },
    session_id: process.env.SID_VALUE
  }));
')"
( cd "$GIT_PROJ" && printf '%s' "$CTX10" | bash "$POSTREV" >/dev/null 2>&1 )
SF10="$(tdd_state_file "$SID10")"
if [ -n "$TICKET10" ] && node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.exit(s.reviewTicket === process.argv[2] && s.reviewTicketConsumed === true ? 0 : 1);
' "$SF10" "$TICKET10" 2>/dev/null; then
  check "G10-pre the fixture chain holds a consumed review ticket" PASS
else
  check "G10-pre consumed review ticket (ticket='$TICKET10')" FAIL
fi
printf 'changed\n' > "$GIT_PROJ/tracked.txt"
ERR10A="$STATE_DIR/g10a.err"
bash "$LOG" --chain-done --session "$SID10" >/dev/null 2>"$ERR10A"; RC10A=$?
DONE10A="$(tdd_chain_done "$SF10" 2>/dev/null)"
if [ "$RC10A" -eq 1 ] && [ "$DONE10A" = "false" ] && grep -qF "$READABLE_HINT" "$ERR10A" \
  && ! grep -qF "$GATE_PHRASE" "$ERR10A"; then
  check "G10a a reviewed chain refuses the unqualified terminus with the state hint, not the zero-change text" PASS
else
  check "G10a reviewed chain --chain-done (rc=$RC10A chainDone=$DONE10A err='$(cat "$ERR10A" 2>/dev/null)')" FAIL
fi
ERR10B="$STATE_DIR/g10b.err"
bash "$LOG" --code-review-done --session "$SID10" >/dev/null 2>"$ERR10B"; RC10B=$?
CRD10B="$(tdd_code_review_done "$SF10" 2>/dev/null)"
if [ "$RC10B" -eq 1 ] && [ "$CRD10B" = "false" ] && grep -qF "$READABLE_HINT" "$ERR10B" \
  && ! grep -qF "$REVIEW_GATE_PHRASE" "$ERR10B"; then
  check "G10b a reviewed chain refuses the unqualified review mark with the state hint, not the zero-change text" PASS
else
  check "G10b reviewed chain --code-review-done (rc=$RC10B codeReviewDone=$CRD10B err='$(cat "$ERR10B" 2>/dev/null)')" FAIL
fi
ERR10C="$STATE_DIR/g10c.err"
bash "$LOG" --code-review-done --session "$SID10" --claimed-review-ticket "$TICKET10" \
  >/dev/null 2>"$ERR10C"; RC10C=$?
CRD10C="$(tdd_code_review_done "$SF10" 2>/dev/null)"
if [ "$RC10C" -eq 0 ] && [ "$CRD10C" = "true" ]; then
  check "G10c the ticket-bound --code-review-done still converges on a changed tree" PASS
else
  check "G10c ticket-bound --code-review-done (rc=$RC10C codeReviewDone=$CRD10C err='$(cat "$ERR10C" 2>/dev/null)')" FAIL
fi
ERR10D="$STATE_DIR/g10d.err"
ZENSU_FULL_SUITE_GATE=off ZENSU_ACCEPTANCE_GATE=off \
  bash "$LOG" --chain-done --session "$SID10" --claimed-review-ticket "$TICKET10" >/dev/null 2>"$ERR10D"; RC10D=$?
DONE10D="$(tdd_chain_done "$SF10" 2>/dev/null)"
case "$TICKET10" in (rt_?*) TICKET10_SHAPE=rt ;; (*) TICKET10_SHAPE=other ;; esac
if [ "$TICKET10_SHAPE" = "rt" ] && [ "$RC10D" -eq 0 ] && [ "$DONE10D" = "true" ] \
  && ! grep -qF "$MINTED_GATE_PHRASE" "$ERR10D"; then
  check "G10d a ticket a reviewer consumed still closes the chain on a changed tree (control for G9e)" PASS
else
  check "G10d reviewed terminus on a changed tree (ticket='$TICKET10' rc=$RC10D chainDone=$DONE10D err='$(cat "$ERR10D" 2>/dev/null)')" FAIL
fi
git -C "$GIT_PROJ" checkout -- tracked.txt >/dev/null 2>&1

SID11="unqualified-env-prefix"
arm "$SID11"
SF11="$(tdd_state_file "$SID11")"
printf 'changed\n' > "$GIT_PROJ/tracked.txt"
if ! GIT_DIR="$BARE_PROJ/.git" git -C "$GIT_PROJ" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  check "G11-control an inherited GIT_DIR hides HEAD from an unscrubbed git" PASS
else
  check "G11-control an inherited GIT_DIR hides HEAD from an unscrubbed git" FAIL
fi
ERR11A="$STATE_DIR/g11a.err"
GIT_DIR="$BARE_PROJ/.git" bash "$LOG" --chain-done --session "$SID11" >/dev/null 2>"$ERR11A"; RC11A=$?
DONE11A="$(tdd_chain_done "$SF11" 2>/dev/null)"
if [ "$RC11A" -eq 1 ] && [ "$DONE11A" = "false" ] && grep -qF "$GATE_PHRASE" "$ERR11A" \
  && grep -qF "reports 1 changed file(s)" "$ERR11A"; then
  check "G11a an inherited GIT_DIR does not zero the --chain-done count" PASS
else
  check "G11a GIT_DIR prefix on --chain-done (rc=$RC11A chainDone=$DONE11A err='$(cat "$ERR11A" 2>/dev/null)')" FAIL
fi
ERR11B="$STATE_DIR/g11b.err"
GIT_DIR="$BARE_PROJ/.git" bash "$LOG" --code-review-done --session "$SID11" >/dev/null 2>"$ERR11B"; RC11B=$?
CRD11B="$(tdd_code_review_done "$SF11" 2>/dev/null)"
if [ "$RC11B" -eq 1 ] && [ "$CRD11B" = "false" ] && grep -qF "$REVIEW_GATE_PHRASE" "$ERR11B" \
  && grep -qF "reports 1 changed file(s)" "$ERR11B"; then
  check "G11b an inherited GIT_DIR does not zero the --code-review-done count" PASS
else
  check "G11b GIT_DIR prefix on --code-review-done (rc=$RC11B codeReviewDone=$CRD11B err='$(cat "$ERR11B" 2>/dev/null)')" FAIL
fi
git -C "$GIT_PROJ" checkout -- tracked.txt >/dev/null 2>&1
printf 'new\n' > "$GIT_PROJ/untracked.txt"
printf '*\n' > "$STATE_DIR/exclude-all"
if [ -z "$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.excludesFile GIT_CONFIG_VALUE_0="$STATE_DIR/exclude-all" \
  git -C "$GIT_PROJ" ls-files --others --exclude-standard 2>/dev/null)" ]; then
  check "G11-control an injected core.excludesFile empties an unscrubbed untracked listing" PASS
else
  check "G11-control an injected core.excludesFile empties an unscrubbed untracked listing" FAIL
fi
ERR11C="$STATE_DIR/g11c.err"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.excludesFile GIT_CONFIG_VALUE_0="$STATE_DIR/exclude-all" \
  bash "$LOG" --chain-done --session "$SID11" >/dev/null 2>"$ERR11C"; RC11C=$?
DONE11C="$(tdd_chain_done "$SF11" 2>/dev/null)"
if [ "$RC11C" -eq 1 ] && [ "$DONE11C" = "false" ] && grep -qF "reports 1 changed file(s)" "$ERR11C"; then
  check "G11c an injected excludes file does not hide an untracked file from --chain-done" PASS
else
  check "G11c config injection on --chain-done (rc=$RC11C chainDone=$DONE11C err='$(cat "$ERR11C" 2>/dev/null)')" FAIL
fi
ERR11D="$STATE_DIR/g11d.err"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.excludesFile GIT_CONFIG_VALUE_0="$STATE_DIR/exclude-all" \
  bash "$LOG" --code-review-done --session "$SID11" >/dev/null 2>"$ERR11D"; RC11D=$?
CRD11D="$(tdd_code_review_done "$SF11" 2>/dev/null)"
if [ "$RC11D" -eq 1 ] && [ "$CRD11D" = "false" ] && grep -qF "reports 1 changed file(s)" "$ERR11D"; then
  check "G11d an injected excludes file does not hide an untracked file from --code-review-done" PASS
else
  check "G11d config injection on --code-review-done (rc=$RC11D codeReviewDone=$CRD11D err='$(cat "$ERR11D" 2>/dev/null)')" FAIL
fi
if [ -z "$(GIT_CONFIG_PARAMETERS="'core.excludesFile=$STATE_DIR/exclude-all'" \
  git -C "$GIT_PROJ" ls-files --others --exclude-standard 2>/dev/null)" ]; then
  check "G11-control an excludes file injected through GIT_CONFIG_PARAMETERS empties an unscrubbed untracked listing" PASS
else
  check "G11-control an excludes file injected through GIT_CONFIG_PARAMETERS empties an unscrubbed untracked listing" FAIL
fi
ERR11E="$STATE_DIR/g11e.err"
GIT_CONFIG_PARAMETERS="'core.excludesFile=$STATE_DIR/exclude-all'" \
  bash "$LOG" --chain-done --session "$SID11" >/dev/null 2>"$ERR11E"; RC11E=$?
DONE11E="$(tdd_chain_done "$SF11" 2>/dev/null)"
if [ "$RC11E" -eq 1 ] && [ "$DONE11E" = "false" ] && grep -qF "reports 1 changed file(s)" "$ERR11E"; then
  check "G11e an excludes file injected through GIT_CONFIG_PARAMETERS does not hide an untracked file from --chain-done" PASS
else
  check "G11e GIT_CONFIG_PARAMETERS on --chain-done (rc=$RC11E chainDone=$DONE11E err='$(cat "$ERR11E" 2>/dev/null)')" FAIL
fi
ERR11F="$STATE_DIR/g11f.err"
GIT_CONFIG_PARAMETERS="'core.excludesFile=$STATE_DIR/exclude-all'" \
  bash "$LOG" --code-review-done --session "$SID11" >/dev/null 2>"$ERR11F"; RC11F=$?
CRD11F="$(tdd_code_review_done "$SF11" 2>/dev/null)"
if [ "$RC11F" -eq 1 ] && [ "$CRD11F" = "false" ] && grep -qF "reports 1 changed file(s)" "$ERR11F"; then
  check "G11f an excludes file injected through GIT_CONFIG_PARAMETERS does not hide an untracked file from --code-review-done" PASS
else
  check "G11f GIT_CONFIG_PARAMETERS on --code-review-done (rc=$RC11F codeReviewDone=$CRD11F err='$(cat "$ERR11F" 2>/dev/null)')" FAIL
fi
rm -f "$GIT_PROJ/untracked.txt"

cp "$GIT_PROJ/.git/index" "$STATE_DIR/index.bak"
printf 'garbage' > "$GIT_PROJ/.git/index"
if ! git -C "$GIT_PROJ" diff --name-only HEAD >/dev/null 2>&1 \
  && git -C "$GIT_PROJ" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  check "G12-control a corrupt index fails the listing while HEAD still resolves" PASS
else
  check "G12-control a corrupt index fails the listing while HEAD still resolves" FAIL
fi
ERR12A="$STATE_DIR/g12a.err"
bash "$LOG" --chain-done --session "$SID11" >/dev/null 2>"$ERR12A"; RC12A=$?
DONE12A="$(tdd_chain_done "$SF11" 2>/dev/null)"
if [ "$RC12A" -eq 1 ] && [ "$DONE12A" = "false" ] && grep -qF "$GATE_PHRASE" "$ERR12A" \
  && grep -qF "$LISTING_PHRASE" "$ERR12A" && ! grep -qF "changed file(s)" "$ERR12A"; then
  check "G12a a failed change listing refuses the unqualified terminus" PASS
else
  check "G12a failed listing on --chain-done (rc=$RC12A chainDone=$DONE12A err='$(cat "$ERR12A" 2>/dev/null)')" FAIL
fi
ERR12B="$STATE_DIR/g12b.err"
bash "$LOG" --code-review-done --session "$SID11" >/dev/null 2>"$ERR12B"; RC12B=$?
CRD12B="$(tdd_code_review_done "$SF11" 2>/dev/null)"
if [ "$RC12B" -eq 1 ] && [ "$CRD12B" = "false" ] && grep -qF "$REVIEW_GATE_PHRASE" "$ERR12B" \
  && grep -qF "$LISTING_PHRASE" "$ERR12B" && ! grep -qF "changed file(s)" "$ERR12B"; then
  check "G12b a failed change listing refuses the unqualified review mark" PASS
else
  check "G12b failed listing on --code-review-done (rc=$RC12B codeReviewDone=$CRD12B err='$(cat "$ERR12B" 2>/dev/null)')" FAIL
fi
cp "$STATE_DIR/index.bak" "$GIT_PROJ/.git/index"
SID12C="minted-ticket-unlisted"
arm "$SID12C"
SF12C="$(tdd_state_file "$SID12C")"
bash "$LOG" --code-review-done --session "$SID12C" >/dev/null 2>&1
ZC12C="$(tdd_ensure_self_review_ticket "$(zensu_resolve_session_id "$SID12C" 2>/dev/null)" 2>/dev/null)"
printf 'garbage' > "$GIT_PROJ/.git/index"
ERR12C="$STATE_DIR/g12c.err"
bash "$LOG" --chain-done --session "$SID12C" --claimed-review-ticket "$ZC12C" >/dev/null 2>"$ERR12C"; RC12C=$?
cp "$STATE_DIR/index.bak" "$GIT_PROJ/.git/index"
DONE12C="$(tdd_chain_done "$SF12C" 2>/dev/null)"
CRD12C="$(tdd_code_review_done "$SF12C" 2>/dev/null)"
if [ -n "$ZC12C" ] && [ "$RC12C" -eq 1 ] && [ "$DONE12C" = "false" ] && [ "$CRD12C" = "false" ] \
  && grep -qF "$MINTED_GATE_PHRASE" "$ERR12C" && grep -qF "$LISTING_PHRASE" "$ERR12C" \
  && grep -qF "$REOPEN_PHRASE" "$ERR12C" && ! grep -qF "changed file(s)" "$ERR12C"; then
  check "G12c a failed change listing refuses the minted ticket and reopens the review" PASS
else
  check "G12c failed listing on the minted-ticket terminus (ticket='$ZC12C' rc=$RC12C chainDone=$DONE12C codeReviewDone=$CRD12C err='$(cat "$ERR12C" 2>/dev/null)')" FAIL
fi

# --- G7 non-git project root: claim not evaluable, legacy behaviour ---
export CLAUDE_PROJECT_DIR="$PLAIN_PROJ"
SID7="terminus-no-repo"
arm "$SID7"
ERR7="$STATE_DIR/g7.err"
bash "$LOG" --chain-done --session "$SID7" >/dev/null 2>"$ERR7"; RC7=$?
DONE7="$(tdd_chain_done "$(tdd_state_file "$SID7")" 2>/dev/null)"
if [ "$RC7" -eq 0 ] && [ "$DONE7" = "true" ]; then
  check "G7 non-git project root -> terminus allowed (not evaluable)" PASS
else
  check "G7 non-git root (rc=$RC7 chainDone=$DONE7 err='$(cat "$ERR7" 2>/dev/null)')" FAIL
fi
G16_LOCALE=""
for G16_CANDIDATE in de_DE.UTF-8 fr_FR.UTF-8 es_ES.UTF-8 it_IT.UTF-8 pt_BR.UTF-8; do
  G16_MSG="$(env LC_ALL="$G16_CANDIDATE" LANG="$G16_CANDIDATE" git -C "$PLAIN_PROJ" rev-parse --is-inside-work-tree 2>&1 >/dev/null)"
  case "$G16_MSG" in
    (""|*"ot a git repository"*) ;;
    (*) G16_LOCALE="$G16_CANDIDATE"; break ;;
  esac
done
SID16="terminus-no-repo-localized"
arm "$SID16"
ERR16="$STATE_DIR/g16.err"
if [ -n "$G16_LOCALE" ]; then
  env LC_ALL="$G16_LOCALE" LANG="$G16_LOCALE" bash "$LOG" --chain-done --session "$SID16" >/dev/null 2>"$ERR16"; RC16=$?
  G16_CASE="git answered in $G16_LOCALE"
else
  bash "$LOG" --chain-done --session "$SID16" >/dev/null 2>"$ERR16"; RC16=$?
  G16_CASE="no candidate locale localized git here, so this run does not discriminate"
fi
DONE16="$(tdd_chain_done "$(tdd_state_file "$SID16")" 2>/dev/null)"
if [ "$RC16" -eq 0 ] && [ "$DONE16" = "true" ]; then
  check "G16 a localized git still reads a root outside git as not evaluable ($G16_CASE)" PASS
else
  check "G16 localized root outside git ($G16_CASE rc=$RC16 chainDone=$DONE16 err='$(cat "$ERR16" 2>/dev/null)')" FAIL
fi
SID9A="review-mark-no-repo"
arm "$SID9A"
ERR9A="$STATE_DIR/g9a.err"
bash "$LOG" --code-review-done --session "$SID9A" >/dev/null 2>"$ERR9A"; RC9A=$?
CRD9A="$(tdd_code_review_done "$(tdd_state_file "$SID9A")" 2>/dev/null)"
if [ "$RC9A" -eq 0 ] && [ "$CRD9A" = "true" ]; then
  check "G9a non-git project root -> unqualified --code-review-done allowed (not evaluable)" PASS
else
  check "G9a non-git root --code-review-done (rc=$RC9A codeReviewDone=$CRD9A err='$(cat "$ERR9A" 2>/dev/null)')" FAIL
fi
ZC9A="$(tdd_ensure_self_review_ticket "$(zensu_resolve_session_id "$SID9A" 2>/dev/null)" 2>/dev/null)"
ERR9J="$STATE_DIR/g9j.err"
bash "$LOG" --chain-done --session "$SID9A" --claimed-review-ticket "$ZC9A" >/dev/null 2>"$ERR9J"; RC9J=$?
DONE9J="$(tdd_chain_done "$(tdd_state_file "$SID9A")" 2>/dev/null)"
if [ -n "$ZC9A" ] && [ "$RC9J" -eq 0 ] && [ "$DONE9J" = "true" ]; then
  check "G9j non-git project root -> a minted ticket closes the chain (not evaluable)" PASS
else
  check "G9j non-git root minted ticket (ticket='$ZC9A' rc=$RC9J chainDone=$DONE9J err='$(cat "$ERR9J" 2>/dev/null)')" FAIL
fi

# --- G8 git repo without a HEAD commit: claim not evaluable ---
export CLAUDE_PROJECT_DIR="$BARE_PROJ"
SID8="terminus-no-head"
arm "$SID8"
ERR8="$STATE_DIR/g8.err"
bash "$LOG" --chain-done --session "$SID8" >/dev/null 2>"$ERR8"; RC8=$?
DONE8="$(tdd_chain_done "$(tdd_state_file "$SID8")" 2>/dev/null)"
if [ "$RC8" -eq 0 ] && [ "$DONE8" = "true" ]; then
  check "G8 git repo without HEAD -> terminus allowed (not evaluable)" PASS
else
  check "G8 no-HEAD repo (rc=$RC8 chainDone=$DONE8 err='$(cat "$ERR8" 2>/dev/null)')" FAIL
fi
SID9B="review-mark-no-head"
arm "$SID9B"
SF9B="$(tdd_state_file "$SID9B")"
ERR9B="$STATE_DIR/g9b.err"
bash "$LOG" --code-review-done --session "$SID9B" >/dev/null 2>"$ERR9B"; RC9B=$?
CRD9B="$(tdd_code_review_done "$SF9B" 2>/dev/null)"
if [ "$RC9B" -eq 0 ] && [ "$CRD9B" = "true" ]; then
  check "G9b git repo without HEAD -> unqualified --code-review-done allowed (not evaluable)" PASS
else
  check "G9b no-HEAD repo --code-review-done (rc=$RC9B codeReviewDone=$CRD9B err='$(cat "$ERR9B" 2>/dev/null)')" FAIL
fi

BARE_GIT_LOG="$(grep -nE '(^|[^[:alnum:]_])git[[:space:]]+-C' "$LOG" | grep -v '_tc_git' | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
HELPER_BODY="$(awk '/^_zensu_unqualified_change_count\(\) \{/,/^}/' "$LOG")"
if [ -z "$BARE_GIT_LOG" ] \
  && printf '%s\n' "$HELPER_BODY" | grep -qF '_tc_git -C "$root" diff --name-only HEAD' \
  && printf '%s\n' "$HELPER_BODY" | grep -qF '_tc_git -C "$root" ls-files --others --exclude-standard' \
  && [ "$(grep -cF '_zensu_union_change_count "$CLAUDE_PROJECT_DIR" "$session_val"' "$LOG")" -eq 3 ] \
  && [ "$(grep -cF '_zensu_union_change_count "$_tc_root" "$session_val"' "$LOG")" -eq 1 ] \
  && awk '/^_zensu_union_change_count\(\) \{/,/^}/' "$LOG" | grep -qF '_zensu_unqualified_change_count "$root" ${excluded[@]+"${excluded[@]}"}'; then
  check "G13 both unqualified verbs, the minted-ticket terminus and --tdd-complete count through one scrubbed helper and no bare git -C remains" PASS
else
  check "G13 shared scrubbed helper (bare='$BARE_GIT_LOG')" FAIL
fi

KEY9B="$(zensu_resolve_session_id "$SID9B" 2>/dev/null)"
G13B_RCS=""
tdd_mark_unclaimed_review "$KEY9B" chainDone >/dev/null 2>&1; G13B_RCS="$G13B_RCS $?"
tdd_mark_unclaimed_review "$KEY9B" codeReviewDone >/dev/null 2>&1; G13B_RCS="$G13B_RCS $?"
tdd_mark_unclaimed_review "$KEY9B" chainDone 01 >/dev/null 2>&1; G13B_RCS="$G13B_RCS $?"
tdd_mark_unclaimed_review "$KEY9B" codeReviewDone 1x >/dev/null 2>&1; G13B_RCS="$G13B_RCS $?"
tdd_mark_unclaimed_review "$KEY9B" selfReviewFixed 0 >/dev/null 2>&1; G13B_RCS="$G13B_RCS $?"
tdd_mark_unclaimed_review "$KEY9B" chainDone 3 >/dev/null 2>&1
G13B_REFUSED=$?
DONE13B="$(tdd_chain_done "$SF9B" 2>/dev/null)"
if [ -n "$KEY9B" ] && [ "$G13B_RCS" = " 1 1 1 1 1" ] && [ "$G13B_REFUSED" -eq 4 ] && [ "$DONE13B" = "false" ]; then
  check "G13b the library refuses a missing or malformed count and returns 4 for a changed tree" PASS
else
  check "G13b library count contract (key='$KEY9B' rcs='$G13B_RCS' refused=$G13B_REFUSED chainDone=$DONE13B)" FAIL
fi
tdd_mark_unclaimed_review "$KEY9B" chainDone unknown >/dev/null 2>&1
G13C_RC=$?
DONE13C="$(tdd_chain_done "$SF9B" 2>/dev/null)"
if [ "$G13C_RC" -eq 0 ] && [ "$DONE13C" = "true" ]; then
  check "G13c the library still closes the chain for an unknown count (control for G13b)" PASS
else
  check "G13c library unknown count (rc=$G13C_RC chainDone=$DONE13C)" FAIL
fi

SID13D="minted-ticket-library"
arm "$SID13D"
SF13D="$(tdd_state_file "$SID13D")"
KEY13D="$(zensu_resolve_session_id "$SID13D" 2>/dev/null)"
bash "$LOG" --code-review-done --session "$SID13D" >/dev/null 2>&1
ZC13D="$(tdd_ensure_self_review_ticket "$KEY13D" 2>/dev/null)"
G13D_RCS=""
tdd_mark_review_converged "$KEY13D" "$ZC13D" chainDone >/dev/null 2>&1; G13D_RCS="$G13D_RCS $?"
tdd_mark_review_converged "$KEY13D" "$ZC13D" chainDone 01 >/dev/null 2>&1; G13D_RCS="$G13D_RCS $?"
tdd_mark_review_converged "$KEY13D" "$ZC13D" chainDone 2x >/dev/null 2>&1; G13D_RCS="$G13D_RCS $?"
tdd_mark_review_converged "$KEY13D" "$ZC13D" selfReviewFixed 0 >/dev/null 2>&1; G13D_RCS="$G13D_RCS $?"
DONE13D="$(tdd_chain_done "$SF13D" 2>/dev/null)"
SRF13D="$(tdd_self_review_fixed "$SF13D" 2>/dev/null)"
CUR13D="$(bash "$LOG" --current-review-ticket --session "$SID13D" 2>/dev/null)"
if [ -n "$KEY13D" ] && [ -n "$ZC13D" ] && [ "$G13D_RCS" = " 1 1 1 1" ] && [ "$DONE13D" = "false" ] \
  && [ "$SRF13D" = "false" ] && [ "$CUR13D" = "$ZC13D" ]; then
  check "G13d the library refuses a minted ticket's terminus without a well-formed count and changes nothing" PASS
else
  check "G13d library minted-ticket contract (key='$KEY13D' ticket='$ZC13D' rcs='$G13D_RCS' chainDone=$DONE13D selfReviewFixed=$SRF13D current='$CUR13D')" FAIL
fi
tdd_mark_review_converged "$KEY13D" "$ZC13D" chainDone unknown >/dev/null 2>&1
G13E_RC=$?
DONE13E="$(tdd_chain_done "$SF13D" 2>/dev/null)"
if [ "$G13E_RC" -eq 0 ] && [ "$DONE13E" = "true" ]; then
  check "G13e the library closes a minted ticket's chain for an unknown count (control for G13d)" PASS
else
  check "G13e library minted ticket with an unknown count (rc=$G13E_RC chainDone=$DONE13E)" FAIL
fi

echo "----"
echo "test-chain-terminus-zero-change-gate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
