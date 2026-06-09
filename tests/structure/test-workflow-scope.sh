#!/bin/bash
set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

SD="$(mktemp -d -t wfscope-XXXXXX)"
SF="$SD/state.json"

printf '{"workflowActive":true,"workflowTools":["link_test","create_revision"]}\n' > "$SF"
[ "$(zensu_workflow_allows "$SF" link_test)" = "true" ] \
  && check "A1 in-set tool -> allows true" PASS || check "A1 in-set (got '$(zensu_workflow_allows "$SF" link_test)')" FAIL

[ "$(zensu_workflow_allows "$SF" set_security_classification)" = "false" ] \
  && check "A2 out-of-set tool -> allows false" PASS || check "A2 out-of-set" FAIL

printf '{"workflowActive":false,"workflowTools":["link_test"]}\n' > "$SF"
[ "$(zensu_workflow_allows "$SF" link_test)" = "false" ] \
  && check "A3 inactive -> allows false" PASS || check "A3 inactive" FAIL

printf '{"workflowActive":true,"workflowTools":["link_test"]}\n' > "$SF"
[ "$(zensu_workflow_active "$SF")" = "true" ] \
  && check "A7 workflowActive flag set -> active true" PASS || check "A7 active flag" FAIL

[ "$(zensu_workflow_allows "$SD/missing.json" link_test)" = "false" ] \
  && check "A8 missing state file -> allows false" PASS || check "A8 missing file" FAIL

[ "$(zensu_workflow_allows "$SF" "")" = "false" ] \
  && check "A9 empty tool arg -> allows false" PASS || check "A9 empty tool" FAIL

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
LOGSH="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh"

SD2="$(mktemp -d -t wfbegin-XXXXXX)"
env CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" TDD_STATE_DIR="$SD2" bash "$LOGSH" --workflow-begin --session wfb-test --tools "link_test,create_revision" >/dev/null 2>&1
SFB="$SD2/tdd-phase-wfb-test.json"
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
rm -rf "$SD2"

SD3="$(mktemp -d -t wfclear-XXXXXX)"
env CLAUDE_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" TDD_STATE_DIR="$SD3" bash -c '
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
  tdd_workflow_begin "clr-test" "link_test,create_revision"
  tdd_clear_session "clr-test"
' 2>/dev/null
SFC="$SD3/tdd-phase-clr-test.json"
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
rm -rf "$SD3"

rm -rf "$SD"
echo "----"
echo "test-workflow-scope: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
