#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PRE_HOOK="$PLUGIN_DIR/hooks/pre-browser-navigation-consent.sh"
POST_HOOK="$PLUGIN_DIR/hooks/post-browser-navigation-consent.sh"
MODULE="$PLUGIN_DIR/hooks/lib/verify-consent-v1.js"
FLOOR="$PLUGIN_DIR/hooks/lib/verify-navigation-floor-v1.js"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
PROXY="$PLUGIN_DIR/scripts/playwright-mcp-proxy.js"
UNIT_CONSENT="$PLUGIN_DIR/tests/structure/verify-consent-v1.test.js"
UNIT_FLOOR="$PLUGIN_DIR/tests/structure/verify-navigation-floor-v1.test.js"
UNIT_PORT="$PLUGIN_DIR/tests/structure/verify-free-port.test.js"
FREE_PORT="$PLUGIN_DIR/scripts/verify-free-port.js"
ESCAPE_STEMS_SUITE="$PLUGIN_DIR/tests/structure/test-gauntlet-loop-skill.sh"
TDD_PHASE_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
GATES_DOC="$PLUGIN_DIR/docs/gates.md"
REPO_CONVENTIONS="$PLUGIN_DIR/CLAUDE.md"
VF_DOC="$PLUGIN_DIR/docs/verify-feature.md"
NAV="mcp__plugin_zensu_playwright__browser_navigate"
NAV_CLI="mcp__playwright__browser_navigate"
TABS="mcp__plugin_zensu_playwright__browser_tabs"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
unset CLAUDE_AGENT_TYPE ZENSU_VERIFY_NAVIGATION_POLICY_V1 ZENSU_VERIFY_CONSENT_MEMORY \
  ZENSU_VERIFY_PROJECT_ROOT ZENSU_VERIFY_RECIPE_FILE 2>/dev/null || true

for f in "$PRE_HOOK" "$POST_HOOK" "$MODULE" "$FLOOR" "$UNIT_CONSENT" "$UNIT_FLOOR" "$UNIT_PORT" "$FREE_PORT"; do
  [ -f "$f" ] && check "V0 file exists: ${f#"$PLUGIN_DIR"/}" PASS || check "V0 file exists: ${f#"$PLUGIN_DIR"/}" FAIL
done
[ -x "$PRE_HOOK" ] && [ -x "$POST_HOOK" ] && check "V1 both hooks are executable" PASS || check "V1 both hooks are executable" FAIL
bash -n "$PRE_HOOK" 2>/dev/null && bash -n "$POST_HOOK" 2>/dev/null \
  && check "V2 bash -n passes for both hooks" PASS || check "V2 bash -n passes for both hooks" FAIL

MATCHER="$(node -e 'process.stdout.write(require(process.argv[1]).CONSENT_MATCHER)' "$MODULE" 2>/dev/null)"
[ -n "$MATCHER" ] && check "V3 the module exports CONSENT_MATCHER" PASS || check "V3 the module exports CONSENT_MATCHER" FAIL
if node -e '
  const [file, matcher] = process.argv.slice(1);
  const doc = JSON.parse(require("fs").readFileSync(file, "utf8"));
  const find = (list, name) => (list || []).filter((g) => (g.hooks || []).some((h) => (h.command || "").includes(name)));
  const pre = find(doc.hooks.PreToolUse, "pre-browser-navigation-consent.sh");
  const post = find(doc.hooks.PostToolUse, "post-browser-navigation-consent.sh");
  if (pre.length !== 1 || post.length !== 1) process.exit(1);
  if (pre[0].matcher !== matcher || post[0].matcher !== matcher) process.exit(2);
  const wrong = find(doc.hooks.PostToolUse, "pre-browser-navigation-consent.sh").length
    + find(doc.hooks.PreToolUse, "post-browser-navigation-consent.sh").length;
  process.exit(wrong ? 3 : 0);
' "$HOOKS_JSON" "$MATCHER" 2>/dev/null; then
  check "V4 hooks.json registers the pair on the module's matcher, each on its own event" PASS
else
  check "V4 hooks.json registers the pair on the module's matcher, each on its own event" FAIL
fi
for name in "$NAV" "$NAV_CLI" "$TABS" "mcp__playwright__browser_tabs"; do
  node -e 'process.exit(new RegExp("^" + process.argv[1] + "$").test(process.argv[2]) ? 0 : 1)' "$MATCHER" "$name" \
    && check "V5 matcher covers $name" PASS || check "V5 matcher covers $name" FAIL
done
node -e 'process.exit(new RegExp("^" + process.argv[1] + "$").test(process.argv[2]) ? 1 : 0)' "$MATCHER" "mcp__plugin_zensu_playwright__browser_snapshot" \
  && check "V5-control matcher leaves browser_snapshot alone" PASS || check "V5-control matcher leaves browser_snapshot alone" FAIL

. "$(dirname "$0")/lib-unit-summary.sh"

# The summary parse belongs to tests/structure/lib-unit-summary.sh, whose own header records that
# this expression was hand-copied into two suites before that file existed. The floor is on the
# REGISTERED total rather than on passes, for the reason that library states: a passing floor is a
# claim about how many cases run on the host executing it, and cases skip themselves for platform
# reasons. A real failure is already non-zero from node, which the rc arm below reports.
# The floor is EQUAL to what the file registers, and the SUITE-OVERVIEW cell is compared against
# the same number, because a hand-maintained floor one below the real count hides a deleted case —
# which is exactly what the V6 floor did. The sibling suite already derives both this way for the
# proxy unit file; this is the same rule applied to the three files this suite drives.
run_unit() { # $1 label  $2 file  $3 registered floor  $4 SUITE-OVERVIEW row key
  local out rc registered cell
  out="$(node --test --test-reporter=tap "$2" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && check "$1 unit suite passes" PASS || check "$1 unit suite passes (rc=$rc)" FAIL
  if unit_cases_registered_floor_text "$out" "$3"; then
    check "$1-floor at least $3 unit cases registered ($(unit_cases_report_text "$out"))" PASS
  else
    check "$1-floor at least $3 unit cases registered ($(unit_cases_report_text "$out"))" FAIL
  fi
  registered="$(printf '%s\n' "$out" | sed -n 's/^# tests \([0-9][0-9]*\)$/\1/p' | head -1)"
  if [ -n "$registered" ] && [ "$3" = "$registered" ]; then
    check "$1-exact the floor equals what the file registers (floor=$3 registered=$registered)" PASS
  else
    check "$1-exact the floor equals what the file registers (floor=$3 registered=${registered:-<none>})" FAIL
  fi
  cell="$(sed -n "s/^| \`$4\` | \([0-9][0-9]*\) |.*/\1/p" "$PLUGIN_DIR/tests/SUITE-OVERVIEW.md" | head -1)"
  if [ -n "$registered" ] && [ "$cell" = "$registered" ]; then
    check "$1-overview the SUITE-OVERVIEW Blocks cell equals it too (cell=$cell)" PASS
  else
    check "$1-overview the SUITE-OVERVIEW Blocks cell equals it too (cell=${cell:-<none>} registered=${registered:-<none>})" FAIL
  fi
}
run_unit "V6 floor" "$UNIT_FLOOR" 7 "verify-navigation-floor-v1.test.js"
run_unit "V7 consent" "$UNIT_CONSENT" 39 "verify-consent-v1.test.js"
run_unit "V7b free-port" "$UNIT_PORT" 3 "verify-free-port.test.js"

grep -qF 'verify-navigation-floor-v1.js' "$PROXY" && ! grep -qE '^function isLoopbackHost' "$PROXY" \
  && grep -qF "require('./verify-navigation-floor-v1.js')" "$MODULE" \
  && check "V8 broker and consent module share the one floor module" PASS \
  || check "V8 broker and consent module share the one floor module" FAIL

if ! grep -qF 'ZENSU_VERIFY_DECLARED_ROUTES' "$MODULE"; then
  check "V8b the decision module takes its declared routes only from the guarded recipe read" PASS
else
  check "V8b the decision module takes its declared routes only from the guarded recipe read" FAIL
fi
if grep -qF 'ZENSU_VERIFY_PROJECT_ROOT' "$MODULE" && grep -qF 'resolveRecipeFile' "$MODULE" \
  && grep -qF "'runtime.yaml', 'autopilot.yaml'" "$MODULE"; then
  check "V8b-control the module resolves the recipe itself from the project root, in one place" PASS
else
  check "V8b-control the module resolves the recipe itself from the project root, in one place" FAIL
fi
if [ -r "$PRE_HOOK" ] && [ -r "$POST_HOOK" ] \
  && ! grep -qE 'runtime\.yaml|autopilot\.yaml' "$PRE_HOOK" \
  && ! grep -qE 'runtime\.yaml|autopilot\.yaml' "$POST_HOOK"; then
  check "V8c neither hook spells either half of the recipe ladder any more" PASS
else
  check "V8c neither hook spells either half of the recipe ladder any more" FAIL
fi
FLAG_RE='zensu_hook_enabled|ZENSU_[A-Z_]+=.?off'
CONTROL_FILE="$(mktemp "${TMPDIR:-/tmp}/zensu-vc-control.XXXXXX")" || exit 1
printf 'ZENSU_BROWSER_CONSENT=off\nzensu_hook_enabled browserConsent\nBROWSER_CONSENT\nVERIFY_CONSENT\n' >"$CONTROL_FILE"
if grep -qE "$FLAG_RE" "$CONTROL_FILE" && grep -qF 'BROWSER_CONSENT' "$CONTROL_FILE" \
  && grep -qF 'VERIFY_CONSENT' "$CONTROL_FILE"; then
  check "V8a positive control: the V9/V10 patterns match a file that carries them" PASS
else
  check "V8a positive control: the V9/V10 patterns match a file that carries them" FAIL
fi
V9_READABLE=1
for _vc_file in "$PRE_HOOK" "$POST_HOOK" "$MODULE"; do
  [ -r "$_vc_file" ] || V9_READABLE=0
done
if [ "$V9_READABLE" -eq 1 ] && ! grep -qE "$FLAG_RE" "$PRE_HOOK" "$POST_HOOK" "$MODULE"; then
  check "V9 the pair reads no config flag and teaches no gate-disable prefix" PASS
else
  check "V9 the pair reads no config flag and teaches no gate-disable prefix" FAIL
fi
if [ -r "$ESCAPE_STEMS_SUITE" ] && [ -r "$TDD_PHASE_LIB" ] \
  && ! grep -qF 'BROWSER_CONSENT' "$ESCAPE_STEMS_SUITE" && ! grep -qF 'VERIFY_CONSENT' "$TDD_PHASE_LIB"; then
  check "V10 ESCAPE_STEMS and the bypass allowlist carry no consent entry" PASS
else
  check "V10 ESCAPE_STEMS and the bypass allowlist carry no consent entry" FAIL
fi
rm -f "$CONTROL_FILE"

TMP_ROOTS=""
cleanup() {
  local d
  while IFS= read -r d; do [ -n "$d" ] && rm -rf -- "$d"; done <<< "$TMP_ROOTS"
}
trap cleanup EXIT

payload() { # $1 event  $2 tool  $3 url-or-empty  $4 session  $5 cwd  [$6 response-json]
  node -e '
    const [event, tool, url, sid, cwd, response] = process.argv.slice(1);
    const input = url ? { url } : {};
    if (/browser_tabs$/.test(tool) && url) input.action = "new";
    const body = { hook_event_name: event, tool_name: tool, tool_input: input, session_id: sid, cwd };
    if (response) body.tool_response = JSON.parse(response);
    process.stdout.write(JSON.stringify(body));
  ' "$1" "$2" "$3" "$4" "$5" "${6:-}"
}
pre_verdict() { # tool url session cwd -> ALLOW | ASK | DENY | ERROR
  local hook_out hook_status
  hook_out="$(payload PreToolUse "$1" "$2" "$3" "$4" | bash "$PRE_HOOK" 2>/dev/null)"
  hook_status=$?
  if [ "$hook_status" -ne 0 ]; then echo "ERROR"; return 0; fi
  printf '%s' "$hook_out" | node -e '
    let s = "";
    process.stdin.on("data", (c) => { s += c; });
    process.stdin.on("end", () => {
      s = s.trim();
      if (!s) { console.log("ALLOW"); return; }
      try { console.log(String(JSON.parse(s).hookSpecificOutput.permissionDecision).toUpperCase()); }
      catch (_) { console.log("UNPARSED"); }
    });'
}
pre_reason() { payload PreToolUse "$1" "$2" "$3" "$4" | bash "$PRE_HOOK" 2>/dev/null; }
post_run() { payload PostToolUse "$1" "$2" "$3" "$4" "${5:-}" | bash "$POST_HOOK" 2>&1 >/dev/null; }

new_project() {
  PROJ="$(mktemp -d "${TMPDIR:-/tmp}/zensu-vc.XXXXXX")" || return 1
  PROJ="$(cd "$PROJ" && pwd -P)" || return 1
  TMP_ROOTS="$TMP_ROOTS$PROJ
"
  export CLAUDE_PROJECT_DIR="$PROJ"
}

new_project || { echo "FATAL: fixture"; exit 2; }
SID="vc-bound"
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$SID" >/dev/null 2>&1 \
  || { check "V11 session baseline" FAIL; echo "----"; echo "test-verify-consent: $PASS PASS / $FAIL FAIL"; exit 1; }
check "V11 session baseline minted a bound record" PASS
MEMORY="$PROJ/.zensu/state/verify-consent-${ZENSU_SESSION_KEY}.json"

[ "$(pre_verdict "$NAV" "http://127.0.0.1:4200/login" "$SID" "$PROJ")" = "ASK" ] \
  && check "V12 first navigation to a new loopback origin asks" PASS \
  || check "V12 first navigation to a new loopback origin asks" FAIL
REASON="$(pre_reason "$NAV" "http://127.0.0.1:4200/login" "$SID" "$PROJ")"
case "$REASON" in
  *'http://127.0.0.1:4200'*'/login'*'may then open, read and interact with (click, type, submit forms on) any page on http://127.0.0.1:4200'*'Consent is per origin, never per route.'*) check "V13 the prompt names origin, route and the origin-wide consequence" PASS ;;
  *) check "V13 the prompt names origin, route and the origin-wide consequence" FAIL ;;
esac
[ ! -e "$MEMORY" ] && check "V14 asking writes no memory" PASS || check "V14 asking writes no memory" FAIL

for url in "http://localhost:4200/" "http://10.0.0.5/" "https://192.168.1.10/" "http://user:pw@127.0.0.1:4200/" "http://127.0.0.1:4200/?t=1" "http://127.0.0.1:4200/#x"; do
  [ "$(pre_verdict "$NAV" "$url" "$SID" "$PROJ")" = "DENY" ] \
    && check "V15 floor denies $url" PASS || check "V15 floor denies $url" FAIL
done
[ "$(pre_verdict "mcp__plugin_zensu_playwright__browser_snapshot" "" "$SID" "$PROJ")" = "ALLOW" ] \
  && check "V16 a non-navigating browser tool passes silently" PASS \
  || check "V16 a non-navigating browser tool passes silently" FAIL
[ "$(pre_verdict "$TABS" "" "$SID" "$PROJ")" = "ALLOW" ] \
  && check "V16b a tabs call that opens no url passes silently" PASS \
  || check "V16b a tabs call that opens no url passes silently" FAIL

post_run "$NAV" "http://127.0.0.1:4200/login" "$SID" "$PROJ" >/dev/null
[ -f "$MEMORY" ] && node -e '
  const doc = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const r = doc.records;
  process.exit(doc.version === 1 && r.length === 1 && r[0].origin === "http://127.0.0.1:4200" && r[0].route === "/login" && r[0].decidedBy === "asked" ? 0 : 1);
' "$MEMORY" 2>/dev/null \
  && check "V17 an executed navigation is recorded as (origin, route, prompt) in the session memory" PASS \
  || check "V17 an executed navigation is recorded as (origin, route, prompt) in the session memory" FAIL
[ "$(pre_verdict "$NAV" "http://127.0.0.1:4200/login" "$SID" "$PROJ")" = "ALLOW" ] \
  && check "V18 the remembered (origin, route) now passes silently" PASS \
  || check "V18 the remembered (origin, route) now passes silently" FAIL
[ "$(pre_verdict "$NAV_CLI" "http://127.0.0.1:4200/login" "$SID" "$PROJ")" = "ALLOW" ] \
  && check "V18b the CLI tool spelling shares the same memory" PASS \
  || check "V18b the CLI tool spelling shares the same memory" FAIL
[ "$(pre_verdict "$NAV" "http://127.0.0.1:4200/admin" "$SID" "$PROJ")" = "ALLOW" ] \
  && check "V19 a route the recipe never declared passes on the approved origin" PASS \
  || check "V19 a route the recipe never declared passes on the approved origin" FAIL
[ "$(pre_verdict "$NAV" "http://127.0.0.1:4201/login" "$SID" "$PROJ")" = "ASK" ] \
  && check "V20 a second loopback origin asks" PASS || check "V20 a second loopback origin asks" FAIL
[ "$(pre_verdict "$NAV" "https://app.example.com/" "$SID" "$PROJ")" = "DENY" ] \
  && check "V21 a remote target is refused in consent mode" PASS \
  || check "V21 a remote target is refused in consent mode" FAIL
case "$(pre_reason "$NAV" "https://app.example.com/" "$SID" "$PROJ")" in
  *'parent-environment navigation policy'*) check "V21b the remote refusal names the policy the target needs" PASS ;;
  *) check "V21b the remote refusal names the policy the target needs" FAIL ;;
esac

post_run "$NAV" "http://127.0.0.1:4200/rejected" "$SID" "$PROJ" '{"isError":true,"content":[{"type":"text","text":"Zensu browser broker rejected the operation: navigation target origin is not approved"}]}' >/dev/null
node -e 'process.exit(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).records.length === 1 ? 0 : 1)' "$MEMORY" 2>/dev/null \
  && check "V22 a navigation the broker rejected is not remembered" PASS \
  || check "V22 a navigation the broker rejected is not remembered" FAIL
post_run "$NAV" "http://localhost:4200/" "$SID" "$PROJ" >/dev/null
node -e 'process.exit(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).records.length === 1 ? 0 : 1)' "$MEMORY" 2>/dev/null \
  && check "V23 a floor-refused target is never remembered" PASS \
  || check "V23 a floor-refused target is never remembered" FAIL

printf '%s\n' 'version: 1' 'validate:' '  driver: browser' '  evidenceSafety:' '    contractVersion: 1' '    mode: declared-safe' '    routes: ["/", "/login", "/inventory"]' '    dataClassification: synthetic' '    containsPersonalData: false' '    containsSecrets: false' > "$PROJ/.zensu/autopilot.yaml"
[ "$(pre_verdict "$NAV" "http://127.0.0.1:4200/inventory" "$SID" "$PROJ")" = "ALLOW" ] \
  && check "V24 an approved origin admits a route no earlier navigation used" PASS \
  || check "V24 an approved origin admits a route no earlier navigation used" FAIL
post_run "$NAV" "http://127.0.0.1:4200/inventory" "$SID" "$PROJ" >/dev/null
node -e '
  const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).records;
  const last = r[r.length - 1];
  const keys = Object.keys(last).sort().join(",");
  process.exit(last.route === "/inventory" && keys === "at,decidedBy,origin,route" ? 0 : 1);
' "$MEMORY" 2>/dev/null \
  && check "V24a a record carries no route set, so a later recipe cannot launder a route into it" PASS \
  || check "V24a a record carries no route set, so a later recipe cannot launder a route into it" FAIL
[ "$(pre_verdict "$NAV" "http://127.0.0.1:4200/login" "$SID" "$PROJ")" = "ALLOW" ] \
  && check "V24b a sibling route on the approved origin passes silently" PASS \
  || check "V24b a sibling route on the approved origin passes silently" FAIL
[ "$(pre_verdict "$NAV" "http://127.0.0.1:4203/inventory" "$SID" "$PROJ")" = "ASK" ] \
  && check "V24-control a declared route on an UNapproved origin still asks" PASS \
  || check "V24-control a declared route on an UNapproved origin still asks" FAIL
printf '%s\n' 'version: 1' 'validate:' '  evidenceSafety:' '    routes: ["/settings"]' > "$PROJ/.zensu/runtime.yaml"
[ "$(pre_verdict "$NAV" "http://127.0.0.1:4200/settings" "$SID" "$PROJ")" = "ALLOW" ] \
  && check "V25 widening the recipe changes nothing for an origin already approved" PASS \
  || check "V25 widening the recipe changes nothing for an origin already approved" FAIL
V25_PROMPT="$(pre_reason "$NAV" "http://127.0.0.1:4204/settings" "$SID" "$PROJ")"
case "$V25_PROMPT" in
  *'synthetic-safe: /settings.'*) check "V25a runtime.yaml outranks autopilot.yaml for the routes the prompt shows" PASS ;;
  *) check "V25a runtime.yaml outranks autopilot.yaml for the routes the prompt shows" FAIL ;;
esac
case "$V25_PROMPT" in
  *'Consent is per origin, never per route.'*) check "V25b the prompt states the grant the broker actually makes" PASS ;;
  *) check "V25b the prompt states the grant the broker actually makes" FAIL ;;
esac
[ "$(pre_verdict "$NAV" "http://127.0.0.1:4200/" "$SID" "$PROJ")" = "ALLOW" ] \
  && check "V26pre the root route on the approved origin passes without a prompt" PASS \
  || check "V26pre the root route on the approved origin passes without a prompt" FAIL
post_run "$NAV" "http://127.0.0.1:4200/" "$SID" "$PROJ" >/dev/null
node -e '
  const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).records;
  const hit = r.filter((e) => e.origin === "http://127.0.0.1:4200" && e.route === "/");
  process.exit(hit.length === 1 && hit[0].decidedBy === "remembered" ? 0 : 1);
' "$MEMORY" 2>/dev/null \
  && check "V26 a silently allowed navigation is recorded with decidedBy remembered" PASS \
  || check "V26 a silently allowed navigation is recorded with decidedBy remembered" FAIL

VALID_POLICY='{"version":1,"mode":"local","targets":[{"origin":"http://127.0.0.1:4300","routes":["/"],"evidenceMode":"declared-safe"}]}'
[ "$(ZENSU_VERIFY_NAVIGATION_POLICY_V1="$VALID_POLICY" pre_verdict "$NAV" "http://127.0.0.1:4300/" "$SID" "$PROJ")" = "ALLOW" ] \
  && check "V27 with a policy the broker accepts the gate stays silent and leaves enforcement to the broker" PASS \
  || check "V27 with a policy the broker accepts the gate stays silent and leaves enforcement to the broker" FAIL
[ "$(ZENSU_VERIFY_NAVIGATION_POLICY_V1="$VALID_POLICY" pre_verdict "$NAV" "http://localhost:4200/" "$SID" "$PROJ")" = "DENY" ] \
  && check "V27a the floor still refuses a hostname target in policy mode" PASS \
  || check "V27a the floor still refuses a hostname target in policy mode" FAIL
[ "$(ZENSU_VERIFY_NAVIGATION_POLICY_V1='{"version":1}' pre_verdict "$NAV" "http://127.0.0.1:4301/" "$SID" "$PROJ")" = "ASK" ] \
  && check "V27b a policy value the broker would refuse leaves the gate armed" PASS \
  || check "V27b a policy value the broker would refuse leaves the gate armed" FAIL

ROOT_MISMATCH_RC=0
payload PreToolUse "$NAV" "http://127.0.0.1:4200/" "$SID" "$PROJ" > "$PROJ/mismatch-payload.json"
CLAUDE_PLUGIN_ROOT="$PROJ" bash "$PRE_HOOK" < "$PROJ/mismatch-payload.json" >/dev/null 2>&1 || ROOT_MISMATCH_RC=$?
[ "$ROOT_MISMATCH_RC" -eq 2 ] && check "V28 an inherited plugin root that does not match refuses with exit 2" PASS \
  || check "V28 an inherited plugin root that does not match refuses with exit 2 (rc=$ROOT_MISMATCH_RC)" FAIL
[ "$(CLAUDE_PLUGIN_ROOT="$PROJ" pre_verdict "$NAV" "http://127.0.0.1:4200/" "$SID" "$PROJ")" = "ERROR" ] \
  && check "V28a the harness reports an aborted hook as ERROR rather than as a silent allow" PASS \
  || check "V28a the harness reports an aborted hook as ERROR rather than as a silent allow" FAIL

# AC-007: a stdin read that FAILS, and one that yields nothing, must both deny. The `|| true`
# discarded cat's status, so an EIO or an early-closed stdin produced an empty payload and the
# module's non-navigation allow — a silent fail-open on the one layer that asks a human.
# The discriminating shape is a plugin root with NO decision module: the wrapper must decide the
# read failure itself, ahead of the node/module ladder, so the reason names the actual cause. A
# directory on fd 0 fails the read deterministically and cannot hang the way a closed fd can.
STDIN_FAIL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zensu-consent-stdin.XXXXXX")"
NOMOD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zensu-consent-nomod.XXXXXX")"
mkdir -p "$NOMOD_ROOT/hooks/lib"
cp "$PLUGIN_DIR/hooks/pre-browser-navigation-consent.sh" "$NOMOD_ROOT/hooks/"
STDIN_FAIL_OUT="$(CLAUDE_PLUGIN_ROOT="$NOMOD_ROOT" bash "$NOMOD_ROOT/hooks/pre-browser-navigation-consent.sh" 2>/dev/null < "$STDIN_FAIL_DIR")"
case "$STDIN_FAIL_OUT" in *'"permissionDecision":"deny"'*) FAILREAD_DENY=1 ;; *) FAILREAD_DENY=0 ;; esac
case "$STDIN_FAIL_OUT" in *'hook payload unreadable'*) FAILREAD_CAUSE=1 ;; *) FAILREAD_CAUSE=0 ;; esac
[ "$FAILREAD_DENY" -eq 1 ] && [ "$FAILREAD_CAUSE" -eq 1 ] \
  && check "V31 a failed stdin read is denied by the wrapper itself, naming the payload" PASS \
  || check "V31 a failed stdin read is denied by the wrapper itself, naming the payload" FAIL
# AC-010: the pre hook has four refusal arms and only the exit-2 one was covered. These drive
# the two that decide whether a broken installation denies or silently allows, and they assert
# the REASON rather than the verdict, so the arms stay distinguishable from each other. The
# third, "node unavailable", is structurally unreachable here — this suite exits near the top
# when node is absent — and is left to the source pin below.
NOMOD_DENY="$(payload PreToolUse "$NAV" "http://127.0.0.1:4200/" "$SID" "$PROJ" \
  | CLAUDE_PLUGIN_ROOT="$NOMOD_ROOT" bash "$NOMOD_ROOT/hooks/pre-browser-navigation-consent.sh" 2>/dev/null)"
case "$NOMOD_DENY" in
  *'"permissionDecision":"deny"'*'decision module absent or symlinked'*)
    check "V31d a plugin root with no decision module denies, naming the module" PASS ;;
  *) check "V31d a plugin root with no decision module denies, naming the module" FAIL ;;
esac
BADMOD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zensu-consent-badmod.XXXXXX")"
mkdir -p "$BADMOD_ROOT/hooks/lib"
cp "$PLUGIN_DIR/hooks/pre-browser-navigation-consent.sh" "$BADMOD_ROOT/hooks/"
printf 'throw new Error("module load fault");\n' > "$BADMOD_ROOT/hooks/lib/verify-consent-v1.js"
BADMOD_DENY="$(payload PreToolUse "$NAV" "http://127.0.0.1:4200/" "$SID" "$PROJ" \
  | CLAUDE_PLUGIN_ROOT="$BADMOD_ROOT" bash "$BADMOD_ROOT/hooks/pre-browser-navigation-consent.sh" 2>/dev/null)"
case "$BADMOD_DENY" in
  *'"permissionDecision":"deny"'*)
    check "V31e a decision module that will not load denies rather than allowing" PASS ;;
  *) check "V31e a decision module that will not load denies rather than allowing" FAIL ;;
esac
rm -rf "$BADMOD_ROOT"
# AC-011: post_run routes stderr onto stdout and every call site discarded it, so the
# recorder's exit status was read by nothing — a hook that crashed before reading the payload
# satisfied the record-count assertions just as well as one that worked. This reads both.
NOMODP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zensu-consent-nomodp.XXXXXX")"
mkdir -p "$NOMODP_ROOT/hooks/lib"
cp "$PLUGIN_DIR/hooks/post-browser-navigation-consent.sh" "$NOMODP_ROOT/hooks/"
POST_SKIP_RC=0
POST_SKIP_OUT="$(payload PostToolUse "$NAV" "http://127.0.0.1:4200/" "$SID" "$PROJ" \
  | CLAUDE_PLUGIN_ROOT="$NOMODP_ROOT" bash "$NOMODP_ROOT/hooks/post-browser-navigation-consent.sh" 2>&1 >/dev/null)" \
  || POST_SKIP_RC=$?
case "$POST_SKIP_OUT" in
  *'consent memory not written (decision module absent or symlinked)'*) POST_SKIP_NAMED=1 ;;
  *) POST_SKIP_NAMED=0 ;;
esac
[ "$POST_SKIP_RC" -eq 0 ] && [ "$POST_SKIP_NAMED" -eq 1 ] \
  && check "V32b a recorder skip exits 0 and names its cause" PASS \
  || check "V32b a recorder skip exits 0 and names its cause (rc=$POST_SKIP_RC named=$POST_SKIP_NAMED)" FAIL
rm -rf "$NOMODP_ROOT"
rm -rf "$NOMOD_ROOT" "$STDIN_FAIL_DIR"
# AC-008: the recorder is documented as never blocking, and exit 2 from a PostToolUse hook IS
# the blocking status. Its three plugin-root arms sat above skip() and could not use it.
POST_MISMATCH_RC=0
CLAUDE_PLUGIN_ROOT="$PROJ" bash "$POST_HOOK" </dev/null >/dev/null 2>&1 || POST_MISMATCH_RC=$?
[ "$POST_MISMATCH_RC" -eq 0 ] \
  && check "V32 the recorder never blocks: an inherited plugin-root mismatch exits 0" PASS \
  || check "V32 the recorder never blocks: an inherited plugin-root mismatch exits 0 (rc=$POST_MISMATCH_RC)" FAIL
POST_MISMATCH_ERR="$(CLAUDE_PLUGIN_ROOT="$PROJ" bash "$POST_HOOK" </dev/null 2>&1 >/dev/null)"
case "$POST_MISMATCH_ERR" in *'CLAUDE_PLUGIN_ROOT'*) MISMATCH_SAID=1 ;; *) MISMATCH_SAID=0 ;; esac
[ "$MISMATCH_SAID" -eq 1 ] \
  && check "V32a the non-blocking mismatch still names its cause on stderr" PASS \
  || check "V32a the non-blocking mismatch still names its cause on stderr" FAIL

STDIN_EMPTY_OUT="$(printf '' | bash "$PRE_HOOK" 2>/dev/null)"
case "$STDIN_EMPTY_OUT" in *'"permissionDecision":"deny"'*) EMPTY_OK=1 ;; *) EMPTY_OK=0 ;; esac
[ "$EMPTY_OK" -eq 1 ] \
  && check "V31a an empty payload denies rather than reading as a non-navigation" PASS \
  || check "V31a an empty payload denies rather than reading as a non-navigation" FAIL

STDERR_UNBOUND="$(payload PreToolUse "$NAV" "http://127.0.0.1:4200/x" "no-such-session" "$PROJ" | bash "$PRE_HOOK" 2>&1 >/dev/null)"
# The hook's own line and the module's are pinned separately: both carry the phrase "no bound
# session", so a shared needle stopped discriminating and deleting either left the other's check
# green. The module's line is the one that says the navigation cannot complete at all.
case "$STDERR_UNBOUND" in
  *'this session cannot complete a consent-mode navigation'*) check "V29c the module discloses that an unbound session cannot finish the navigation" PASS ;;
  *) check "V29c the module discloses that an unbound session cannot finish the navigation" FAIL ;;
esac
[ "$(pre_verdict "$NAV" "http://127.0.0.1:4200/x" "no-such-session" "$PROJ")" = "ASK" ] \
  && case "$STDERR_UNBOUND" in *'nothing is remembered'*) true ;; *) false ;; esac \
  && check "V29 an unbound session still asks, enforces the floor and says it remembers nothing" PASS \
  || check "V29 an unbound session still asks, enforces the floor and says it remembers nothing" FAIL
[ "$(pre_verdict "$NAV" "http://localhost:4200/" "no-such-session" "$PROJ")" = "DENY" ] \
  && check "V29b the floor holds without a bound session" PASS || check "V29b the floor holds without a bound session" FAIL
BEFORE="$(ls "$PROJ/.zensu/state" | sort | tr '\n' ' ')"
post_run "$NAV" "http://127.0.0.1:4200/x" "no-such-session" "$PROJ" >/dev/null
AFTER="$(ls "$PROJ/.zensu/state" | sort | tr '\n' ' ')"
[ "$BEFORE" = "$AFTER" ] && check "V30 an unbound post hook writes nothing" PASS || check "V30 an unbound post hook writes nothing" FAIL

SKILL_MD="$PLUGIN_DIR/skills/verify-feature/SKILL.md"
SETUP_MD="$PLUGIN_DIR/skills/verify-feature/rules/setup.md"
BROWSER_MD="$PLUGIN_DIR/skills/verify-feature/rules/browser-verification.md"
ZENSU_MD="$PLUGIN_DIR/skills/verify-feature/rules/zensu-monorepo.md"
ADAPTER="$PLUGIN_DIR/skills/verify-feature/scripts/zensu-monorepo-runtime.sh"
if grep -qF '**Consent mode (no parent policy).**' "$SKILL_MD" \
  && grep -qF 'pre-browser-navigation-consent.sh' "$SKILL_MD" \
  && grep -qF 'A remote target is refused in consent mode' "$SKILL_MD" \
  && grep -qF 'verify-consent-<session-key>.json' "$SKILL_MD" \
  && grep -qF 'never answer it on their behalf' "$SKILL_MD"; then
  check "V31s SKILL.md states consent mode, its hook, its loopback bound and the user-owned prompt" PASS
else
  check "V31s SKILL.md states consent mode, its hook, its loopback bound and the user-owned prompt" FAIL
fi
SKILL_POLICY_SITES="$(grep -cF 'In POLICY mode' "$SKILL_MD" || true)"
if [ "${SKILL_POLICY_SITES:-0}" -ge 2 ] && grep -qF 'In CONSENT mode** there is' "$SKILL_MD" \
  && grep -qF 'a run-specific loopback port is the EXPECTED' "$SKILL_MD" \
  && grep -qF 'ACCEPTED-CANDIDATE branch' "$SKILL_MD" && grep -qF 'MONOREPO-ADAPTER branch' "$SKILL_MD"; then
  check "V31b SKILL.md scopes the policy requirement, the port criterion and the port source by mode at both sites ($SKILL_POLICY_SITES)" PASS
else
  check "V31b SKILL.md scopes the policy requirement, the port criterion and the port source by mode at both sites ($SKILL_POLICY_SITES)" FAIL
fi
if ! grep -qF 'with the current session and requires a discovery run' "$SKILL_MD" \
  && ! grep -qF 'unapproved parent' "$SKILL_MD" \
  && grep -qF 'incompatible with that session' "$SKILL_MD"; then
  check "V31c the two unscoped sentences that terminated every consent-mode run are gone" PASS
else
  check "V31c the two unscoped sentences that terminated every consent-mode run are gone" FAIL
fi
if grep -qF -- '`--attach=<origin>`' "$SKILL_MD" && grep -qF -- '`--setup`' "$SKILL_MD" \
  && grep -qF -- '`--print-policy`' "$SKILL_MD" \
  && grep -qF 'else `.zensu/runtime.yaml`, else `.zensu/autopilot.yaml`' "$SKILL_MD" \
  && grep -qF 'No runtime recipe found. Set one up now?' "$SKILL_MD" \
  && grep -qF 'scripts/verify-free-port.js" --from 5173' "$SKILL_MD"; then
  check "V32s SKILL.md carries attach, setup, print-policy, the recipe order, the setup offer and the free-port helper" PASS
else
  check "V32s SKILL.md carries attach, setup, print-policy, the recipe order, the setup offer and the free-port helper" FAIL
fi
if grep -qF '### Attach mode' "$SKILL_MD" && grep -qF 'worktree identity proven' "$SKILL_MD" \
  && grep -qF 'attached runtime, identity unproven' "$SKILL_MD" \
  && grep -qF 'never stop, signal, or restart the attached process' "$SKILL_MD" \
  && grep -qF -- '- **Consent:**' "$SKILL_MD" && grep -qF '`asked`' "$SKILL_MD" \
  && grep -qF '`remembered`' "$SKILL_MD" && grep -qF '`policy-mode`' "$SKILL_MD"; then
  check "V33 SKILL.md attach mode proves identity by process cwd and the report carries a Consent block" PASS
else
  check "V33 SKILL.md attach mode proves identity by process cwd and the report carries a Consent block" FAIL
fi
if [ -f "$SETUP_MD" ] && grep -qF '# Guided runtime setup' "$SETUP_MD" \
  && grep -qF 'git ls-files' "$SETUP_MD" && grep -qF 'from <repo-root-relative file>' "$SETUP_MD" \
  && grep -qF 'Ask exactly one `AskUserQuestion`' "$SETUP_MD" \
  && grep -qF '.zensu/runtime.yaml' "$SETUP_MD" \
  && grep -qF -- '--print-policy' "$SETUP_MD" && grep -qF 'never commit unasked' "$SETUP_MD" \
  && grep -qF 'project-level settings files are not the place' "$SETUP_MD"; then
  check "V34 rules/setup.md is evidence-driven, single-question, writes runtime.yaml and renders the policy" PASS
else
  check "V34 rules/setup.md is evidence-driven, single-question, writes runtime.yaml and renders the policy" FAIL
fi
if [ -r "$SETUP_MD" ] && grep -qF 'evidenceSafety' "$SETUP_MD" && ! grep -qF 'portEnv' "$SETUP_MD"; then
  check "V34a the template carries no key the adapter and the autopilot contract never read" PASS
else
  check "V34a the template carries no key the adapter and the autopilot contract never read" FAIL
fi
if [ -r "$SETUP_MD" ] && grep -qF 'evidenceSafety' "$SETUP_MD"; then
  check "V34a-control the negative scan above ran against a readable template that carries the key it keeps" PASS
else
  check "V34a-control the negative scan above ran against a readable template that carries the key it keeps" FAIL
fi
# V34b executes the round trip V34 only greps: the policy template SHIPPED in rules/setup.md
# is extracted, filled with a port and a route, and fed to the launcher's own --check-policy.
POLICY_TEMPLATE="$(node -e '
  const text = require("fs").readFileSync(process.argv[1], "utf8");
  const m = text.match(/\{"version":1,"mode":"local","targets":\[[^\n]*?\}\]\}/);
  process.stdout.write(m ? m[0] : "");
' "$SETUP_MD" 2>/dev/null)"
if [ -n "$POLICY_TEMPLATE" ]; then
  check "V34b-control the policy template is extractable from rules/setup.md" PASS
else
  check "V34b-control the policy template is extractable from rules/setup.md" FAIL
fi
RENDERED_POLICY="$(printf '%s' "$POLICY_TEMPLATE" | sed -e 's|<port>|45173|' -e 's|\[<declared routes>\]|["/"]|')"
case "$RENDERED_POLICY" in
  *'<port>'*|*'<declared routes>'*|'') check "V34b-control2 every placeholder in the template was substituted" FAIL ;;
  *) check "V34b-control2 every placeholder in the template was substituted" PASS ;;
esac
if [ -n "$RENDERED_POLICY" ] && ZENSU_VERIFY_NAVIGATION_POLICY_V1="$RENDERED_POLICY" node "$PROXY" --check-policy local 'http://127.0.0.1:45173' '/' declared-safe >/dev/null 2>&1; then
  check "V34b the policy rules/setup.md renders is accepted by the launcher it tells the model to run" PASS
else
  check "V34b the policy rules/setup.md renders is accepted by the launcher it tells the model to run" FAIL
fi
if [ -z "$RENDERED_POLICY" ] || ZENSU_VERIFY_NAVIGATION_POLICY_V1="$RENDERED_POLICY" node "$PROXY" --check-policy local 'http://127.0.0.1:45173' '/admin' declared-safe >/dev/null 2>&1; then
  check "V34b-neg an undeclared route is refused against that same rendered policy" FAIL
else
  check "V34b-neg an undeclared route is refused against that same rendered policy" PASS
fi
if grep -qF 'In consent mode (the preflight printed `consent`)' "$BROWSER_MD" \
  && grep -qF 'never try another spelling of the same target to avoid the prompt' "$BROWSER_MD" \
  && grep -qF 'Without a parent policy the broker runs in consent mode' "$ZENSU_MD" \
  && grep -qF 'zensu-planned-origin' "$ZENSU_MD" \
  && grep -qF 'scripts/verify-free-port.js' "$ADAPTER" && grep -qF 'PLANNED_ORIGIN_FILE' "$ADAPTER"; then
  check "V35 both rule files and the adapter describe the consent-mode origin path" PASS
else
  check "V35 both rule files and the adapter describe the consent-mode origin path" FAIL
fi

# V36 closes the finding this whole marker exists for: consent mode is entered from a FILE
# READ in the broker's own tree, so registration is a claim and not a fact about the running
# session. The gate must leave positive evidence that it EXECUTED for the origin it just
# decided, or the broker has nothing to distinguish a session whose hooks ran from one whose
# hooks are switched off host-side.
evidence_path() { # $1 origin -> the marker path the gate would write for it
  node -e '
    const consent = require(process.argv[1]);
    const path = require("node:path");
    process.stdout.write(consent.evidencePathFor(
      path.join(consent.evidenceDirFor(process.argv[2]), `verify-consent-${process.argv[3]}.json`),
      process.argv[4],
    ));
  ' "$MODULE" "$PROJ" "$ZENSU_SESSION_KEY" "$1" 2>/dev/null
}
evidence_clear() { rm -f "$PROJ"/.zensu/state/verify-consent-exec-*.json; }
EVIDENCE="$(evidence_path 'http://127.0.0.1:4291')"
evidence_clear
pre_verdict "$NAV" "http://127.0.0.1:4291/dash" "$SID" "$PROJ" >/dev/null
# The reader takes the project ANCHOR, not only the directory: it is what the containment walk is
# checked against, and a call that supplies none is refused rather than answered.
if [ -f "$EVIDENCE" ] && node -e '
  const { executionEvidencePresent } = require(process.argv[1]);
  process.exit(executionEvidencePresent(process.argv[2], process.argv[3], { projectRoot: process.argv[4] }) === true ? 0 : 1);
' "$MODULE" "$PROJ/.zensu/state" "http://127.0.0.1:4291" "$PROJ" 2>/dev/null; then
  check "V36 a decided loopback navigation leaves in-session execution evidence for its origin" PASS
else
  check "V36 a decided loopback navigation leaves in-session execution evidence for its origin" FAIL
fi
# The marker is ORIGIN-bound, so evidence for one origin can never launder a second one in. The
# ANCHOR is passed for the reason V36 states: an anchorless read refuses unconditionally, so
# without it this check answered false for every input and could not fail. A positive control
# runs first, or "refused" and "refused for the right reason" read the same.
if node -e '
  const { executionEvidencePresent } = require(process.argv[1]);
  const opts = { projectRoot: process.argv[4] };
  const decided = executionEvidencePresent(process.argv[2], process.argv[5], opts) === true;
  const other = executionEvidencePresent(process.argv[2], process.argv[3], opts) === true;
  process.exit(decided && !other ? 0 : 1);
' "$MODULE" "$PROJ/.zensu/state" "http://127.0.0.1:4292" "$PROJ" "http://127.0.0.1:4291" 2>/dev/null; then
  check "V36a the marker names only the decided origin" PASS
else
  check "V36a the marker names only the decided origin" FAIL
fi
# A navigation the floor REFUSES never reaches the broker, so leaving evidence for it would
# record an execution that granted nothing and widen what a later self-approval may accept.
evidence_clear
pre_verdict "$NAV" "https://app.example.com/" "$SID" "$PROJ" >/dev/null
[ -z "$(ls -A "$PROJ"/.zensu/state/verify-consent-exec-*.json 2>/dev/null)" ] \
  && check "V36b a floor-denied navigation leaves no execution evidence" PASS \
  || check "V36b a floor-denied navigation leaves no execution evidence" FAIL
# An already-remembered origin still records the execution: the broker checks the marker on
# every first approval of an origin in its own process, which a memory hit does not skip. The
# origin has to be one the MEMORY carries, or this is byte-identical to V36's ask arm and the
# allow/MEMORY_HIT branch of the write condition has no executed case at all — conjoining on the
# verdict is what makes that failure visible rather than silent.
evidence_clear
EVIDENCE_REMEMBERED="$(evidence_path 'http://127.0.0.1:4200')"
if [ "$(pre_verdict "$NAV" "http://127.0.0.1:4200/again" "$SID" "$PROJ")" = "ALLOW" ] && [ -f "$EVIDENCE_REMEMBERED" ]; then
  check "V36c a remembered origin records its execution too" PASS
else
  check "V36c a remembered origin records its execution too" FAIL
fi
# An ASK records `asked`, not `allowed`: with a constant on the writer's side every check on the
# allowed path still passed, so the two arms are asserted separately.
evidence_clear
pre_verdict "$NAV" "http://127.0.0.1:4295/first" "$SID" "$PROJ" >/dev/null
if node -e '
  const j = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  process.exit(j.verdict === "asked" ? 0 : 1);
' "$(evidence_path 'http://127.0.0.1:4295')" 2>/dev/null; then
  check "V36f a first navigation records the asked verdict" PASS
else
  check "V36f a first navigation records the asked verdict" FAIL
fi
evidence_clear
pre_verdict "$NAV" "http://127.0.0.1:4200/again" "$SID" "$PROJ" >/dev/null
# The verdict travels with the marker, so the broker and the doctor can tell an execution that
# CLEARED the origin from one that only asked about it.
if node -e '
  const c = require(process.argv[1]);
  const j = JSON.parse(require("node:fs").readFileSync(process.argv[2], "utf8"));
  process.exit(j.verdict === "allowed" ? 0 : 1);
' "$MODULE" "$EVIDENCE_REMEMBERED" 2>/dev/null; then
  check "V36d the marker records the verdict the gate reached" PASS
else
  check "V36d the marker records the verdict the gate reached" FAIL
fi
# Two origins decided before either is approved coexist, where one file per session made the
# second rename over the first and the earlier origin was then refused.
evidence_clear
pre_verdict "$NAV" "http://127.0.0.1:4293/a" "$SID" "$PROJ" >/dev/null
pre_verdict "$NAV" "http://127.0.0.1:4294/b" "$SID" "$PROJ" >/dev/null
if [ -f "$(evidence_path 'http://127.0.0.1:4293')" ] && [ -f "$(evidence_path 'http://127.0.0.1:4294')" ]; then
  check "V36e two decided origins keep separate markers" PASS
else
  check "V36e two decided origins keep separate markers" FAIL
fi
# POLICY mode decides nothing about the target: `decide` returns allow with reason `policy-mode`
# and delegates the target test to the broker, so a marker minted there asserts a clearance no
# gate gave. The broker's granting read carries no session key, so a consent-mode broker in the
# same project would then self-approve that origin inside the window with no prompt at all.
evidence_clear
ZENSU_VERIFY_NAVIGATION_POLICY_V1="$VALID_POLICY" pre_verdict "$NAV" "http://127.0.0.1:4296/x" "$SID" "$PROJ" >/dev/null
[ -z "$(ls -A "$PROJ"/.zensu/state/verify-consent-exec-*.json 2>/dev/null)" ] \
  && check "V36g policy mode records no execution evidence for a target it never judged" PASS \
  || check "V36g policy mode records no execution evidence for a target it never judged" FAIL
evidence_clear

# --- the operator account may not outrun what the code does ---
# `liveEvidenceOrigins` breaks early ONLY on a wantOrigin MATCH, and `consentEvidenceState` runs
# that walk TWICE on a miss — once for the present probe and once for the widened expiry probe —
# so a refusal, which is exactly the miss case, carries up to two budgets of windows on the
# broker's side too. "the broker's own read carries one" was a comparison that reversed the
# finding it was drawn to state.
for f in "$GATES_DOC" "$REPO_CONVENTIONS"; do
  [ -f "$f" ] || check "V40 carrier exists: ${f#"$PLUGIN_DIR"/}" FAIL
done
grep -qF -- "the broker's own read carries one" "$GATES_DOC" \
  && check "V40 the gates account still compares the sweep against a one-window broker read" FAIL \
  || check "V40 the gates account makes no one-window claim about the broker's own read" PASS
grep -qF -- "lstat\`-then-read windows" "$GATES_DOC" \
  && check "V40-control the window-count bound is still stated at all" PASS \
  || check "V40-control the window-count bound is still stated at all" FAIL
grep -qF -- "rather than one on the broker's read" "$REPO_CONVENTIONS" \
  && check "V40a the repo conventions carry the same reversed comparison" FAIL \
  || check "V40a the repo conventions carry no reversed comparison" PASS

# The reap is clocked on MAX_EVIDENCE_REAP_AGE_MS, which is strictly wider than the reader's own
# window — and the broker's expiry probe reads with no window at all. So a marker past the reap
# age is removed while that reader would still honour it, which is the one input the `expired`
# diagnosis needs. An account that names only the five-minute window states neither.
grep -qF -- 'no reader in ANY session could honour' "$GATES_DOC" \
  && check "V40b the reap bound still claims no reader could honour what it removes" FAIL \
  || check "V40b the reap bound claims only what the grace horizon allows" PASS
grep -qF -- 'MAX_EVIDENCE_REAP_AGE_MS' "$GATES_DOC" \
  && check "V40c the operator account names the reap horizon, not only the read window" PASS \
  || check "V40c the operator account names the reap horizon, not only the read window" FAIL

# The emitting surface tells an unbindable session it cannot complete a consent-mode navigation.
# The fault-direction paragraph said the opposite: floor plus prompt, nothing remembered.
grep -qF -- 'nothing is remembered, and the hook says so on stderr' "$GATES_DOC" \
  && check "V40d the fault-direction paragraph carries the retired unbindable account" FAIL \
  || check "V40d the fault-direction paragraph matches what the hook emits" PASS
grep -qF -- 'cannot complete a consent-mode navigation' "$GATES_DOC" \
  && check "V40d-control it states the consequence the emitting surface states" PASS \
  || check "V40d-control it states the consequence the emitting surface states" FAIL

# --- the troubleshooting row may not promise what the refusal it is keyed on does not carry ---
# That row is keyed on the `absent` refusal, and `consentRefusalFor` interpolates its anchor for
# `truncated` and `unread` ONLY. The doctor row it points at is also a DIFFERENT read: session
# scoped and all origins, against the broker's project-scoped this-origin one.
grep -qF -- "the broker's own refusal names the tree it read" "$VF_DOC" \
  && check "V41 the absent-keyed row promises an anchor that refusal does not carry" FAIL \
  || check "V41 the absent-keyed row promises only what its own refusal carries" PASS
grep -qF -- 'no in-session evidence that the Zensu consent gate ran for this origin' "$VF_DOC" \
  && check "V41-control the row it is about is still there" PASS \
  || check "V41-control the row it is about is still there" FAIL

# A port works from the roster, not from the paragraph. Four owners this feature created were
# absent from the core half, and `evidenceStillHonourable` and `liveEvidenceOrigins` — both ON
# that list — call `evidenceBodyLive` with `MAX_EVIDENCE_REAP_AGE_MS`, so a port copying exactly
# the list gets a ReferenceError on its first marker read.
if node -e '
  const fs = require("fs");
  const t = fs.readFileSync(process.argv[1], "utf8");
  const i = t.indexOf("the core half is\n  `STATE_SEGMENTS`");
  const j = t.indexOf("the host half is FIVE obligations", i);
  if (i < 0 || j < 0) process.exit(2);
  const slice = t.slice(i, j);
  const owed = ["MAX_EVIDENCE_REAP_AGE_MS", "evidenceBodyLive", "EXECUTION_VERDICTS", "classifyExecution", "recordingStream"];
  const missing = owed.filter((n) => !slice.includes("`" + n + "`"));
  if (missing.length) { console.error("missing: " + missing.join(", ")); process.exit(1); }
' "$REPO_CONVENTIONS" 2>/dev/null; then
  check "V41a the port core half names every owner this feature created" PASS
else
  check "V41a the port core half names every owner this feature created" FAIL
fi
grep -qF -- 'has no code hand-copy' "$REPO_CONVENTIONS" \
  && check "V41b the EVIDENCE_NAME_PREFIX census still claims no code hand-copy" FAIL \
  || check "V41b the EVIDENCE_NAME_PREFIX census counts what a grep finds" PASS

echo "----"
echo "test-verify-consent: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
