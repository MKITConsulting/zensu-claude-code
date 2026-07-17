#!/bin/bash
set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SESSION_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js"
BASELINE="${CLAUDE_PLUGIN_ROOT}/tests/session-control/initialize-baseline.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

SD="$(mktemp -d -t wfscope-XXXXXX)"
SID_DIRECT="scope-direct"
PROJECT="$SD/project"
PLUGIN_DATA="$SD/plugin-data"
mkdir -p "$PROJECT" "$PLUGIN_DATA"
export CLAUDE_PLUGIN_ROOT
export CLAUDE_PROJECT_DIR="$PROJECT"
export ZENSU_TEST_PLUGIN_DATA="$PLUGIN_DATA"
# Exercise the same fresh SessionStart plus per-Bash native binding as real
# model-side workflow commands. No session selectors come from CLAUDE_ENV_FILE.
# shellcheck disable=SC1090
source "$BASELINE" "$SID_DIRECT" || exit 1
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
tdd_workflow_begin "$SID_DIRECT" "link_test,create_revision"
SF="$(tdd_state_file "$SID_DIRECT")"

[ "$(zensu_workflow_allows "$SF" link_test)" = "true" ] \
  && check "A1 in-set tool -> allows true" PASS || check "A1 in-set (got '$(zensu_workflow_allows "$SF" link_test)')" FAIL

[ "$(zensu_workflow_allows "$SF" set_security_classification)" = "false" ] \
  && check "A2 out-of-set tool -> allows false" PASS || check "A2 out-of-set" FAIL

tdd_set_flag "$SID_DIRECT" workflowActive false
[ "$(zensu_workflow_allows "$SF" link_test)" = "false" ] \
  && check "A3 inactive -> allows false" PASS || check "A3 inactive" FAIL

tdd_workflow_begin "$SID_DIRECT" "link_test"
[ "$(zensu_workflow_active "$SF")" = "true" ] \
  && check "A7 workflowActive flag set -> active true" PASS || check "A7 active flag" FAIL

MISSING="$PROJECT/.zensu/state/tdd-phase-$(node "$SESSION_CORE" session-key scope-missing).json"
[ "$(zensu_workflow_allows "$MISSING" link_test)" = "false" ] \
  && check "A8 missing state file -> allows false" PASS || check "A8 missing file" FAIL

[ "$(zensu_workflow_allows "$SF" "")" = "false" ] \
  && check "A9 empty tool arg -> allows false" PASS || check "A9 empty tool" FAIL

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
LOGSH="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh"

bash "$LOGSH" --workflow-begin --session "$SID_DIRECT" --tools "link_test,create_revision" >/dev/null 2>&1
SFB="$SF"
B1=$(STATE="$SFB" node -e '
  try {
    const j = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
    const t = Array.isArray(j.workflowTools) ? j.workflowTools : [];
    const ok = j.workflowActive === true
      && t.indexOf("link_test") >= 0 && t.indexOf("create_revision") >= 0;
    console.log(ok ? "yes" : "no");
  } catch (e) { console.log("err"); }
' 2>/dev/null)
[ "$B1" = "yes" ] && check "B1 --workflow-begin --tools writes workflowActive + workflowTools" PASS || check "B1 writer (got '$B1')" FAIL

tdd_clear_session "$SID_DIRECT"
SFC="$SF"
C1=$(STATE="$SFC" node -e '
  try {
    const j = JSON.parse(require("fs").readFileSync(process.env.STATE, "utf8"));
    const t = Array.isArray(j.workflowTools) ? j.workflowTools : [];
    console.log(t.length === 0 ? "yes" : "no");
  } catch (e) { console.log("err"); }
' 2>/dev/null)
[ "$C1" = "yes" ] && check "C1clr tdd_clear_session resets workflowTools" PASS || check "C1clr reset (got '$C1')" FAIL

[ "$(zensu_workflow_allows "$SFC" link_test)" = "false" ] \
  && check "C2clr allows false after clear" PASS || check "C2clr after clear" FAIL

rm -rf "$SD"
echo "----"
echo "test-workflow-scope: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
