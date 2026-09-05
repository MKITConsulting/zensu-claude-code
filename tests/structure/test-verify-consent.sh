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

run_unit() { # $1 label  $2 file  $3 floor
  local out pass_n
  out="$(node --test --test-reporter=tap "$2" 2>&1)"; local rc=$?
  pass_n="$(printf '%s\n' "$out" | sed -n 's/^# pass \([0-9][0-9]*\)$/\1/p')"
  [ -z "$pass_n" ] && pass_n=0
  [ "$rc" -eq 0 ] && check "$1 unit suite passes" PASS || check "$1 unit suite passes (rc=$rc)" FAIL
  [ "$pass_n" -ge "$3" ] && check "$1-floor at least $3 unit cases ran ($pass_n)" PASS \
    || check "$1-floor at least $3 unit cases ran (only $pass_n)" FAIL
}
run_unit "V6 floor" "$UNIT_FLOOR" 6
run_unit "V7 consent" "$UNIT_CONSENT" 16
run_unit "V7b free-port" "$UNIT_PORT" 3

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
  *'http://127.0.0.1:4200'*'/login'*'may then open and read any page on http://127.0.0.1:4200'*'Consent is per origin, never per route.'*) check "V13 the prompt names origin, route and the origin-wide consequence" PASS ;;
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
  process.exit(doc.version === 1 && r.length === 1 && r[0].origin === "http://127.0.0.1:4200" && r[0].route === "/login" && r[0].decidedBy === "prompt" ? 0 : 1);
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
  process.exit(hit.length === 1 && hit[0].decidedBy === "memory" ? 0 : 1);
' "$MEMORY" 2>/dev/null \
  && check "V26 a silently allowed navigation is recorded with decidedBy memory" PASS \
  || check "V26 a silently allowed navigation is recorded with decidedBy memory" FAIL

[ "$(ZENSU_VERIFY_NAVIGATION_POLICY_V1='{"version":1}' pre_verdict "$NAV" "http://localhost:4200/" "$SID" "$PROJ")" = "ALLOW" ] \
  && check "V27 with a parent policy present the gate stays silent and leaves enforcement to the broker" PASS \
  || check "V27 with a parent policy present the gate stays silent and leaves enforcement to the broker" FAIL

ROOT_MISMATCH_RC=0
payload PreToolUse "$NAV" "http://127.0.0.1:4200/" "$SID" "$PROJ" > "$PROJ/mismatch-payload.json"
CLAUDE_PLUGIN_ROOT="$PROJ" bash "$PRE_HOOK" < "$PROJ/mismatch-payload.json" >/dev/null 2>&1 || ROOT_MISMATCH_RC=$?
[ "$ROOT_MISMATCH_RC" -eq 2 ] && check "V28 an inherited plugin root that does not match refuses with exit 2" PASS \
  || check "V28 an inherited plugin root that does not match refuses with exit 2 (rc=$ROOT_MISMATCH_RC)" FAIL
[ "$(CLAUDE_PLUGIN_ROOT="$PROJ" pre_verdict "$NAV" "http://127.0.0.1:4200/" "$SID" "$PROJ")" = "ERROR" ] \
  && check "V28a the harness reports an aborted hook as ERROR rather than as a silent allow" PASS \
  || check "V28a the harness reports an aborted hook as ERROR rather than as a silent allow" FAIL

STDERR_UNBOUND="$(payload PreToolUse "$NAV" "http://127.0.0.1:4200/x" "no-such-session" "$PROJ" | bash "$PRE_HOOK" 2>&1 >/dev/null)"
[ "$(pre_verdict "$NAV" "http://127.0.0.1:4200/x" "no-such-session" "$PROJ")" = "ASK" ] \
  && case "$STDERR_UNBOUND" in *'no bound session'*) true ;; *) false ;; esac \
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
  check "V31 SKILL.md states consent mode, its hook, its loopback bound and the user-owned prompt" PASS
else
  check "V31 SKILL.md states consent mode, its hook, its loopback bound and the user-owned prompt" FAIL
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
  check "V32 SKILL.md carries attach, setup, print-policy, the recipe order, the setup offer and the free-port helper" PASS
else
  check "V32 SKILL.md carries attach, setup, print-policy, the recipe order, the setup offer and the free-port helper" FAIL
fi
if grep -qF '### Attach mode' "$SKILL_MD" && grep -qF 'worktree identity proven' "$SKILL_MD" \
  && grep -qF 'attached runtime, identity unproven' "$SKILL_MD" \
  && grep -qF 'never stop, signal, or restart the attached process' "$SKILL_MD" \
  && grep -qF -- '- **Consent:**' "$SKILL_MD" && grep -qF '`prompt`' "$SKILL_MD" && grep -qF '`policy`' "$SKILL_MD"; then
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

echo "----"
echo "test-verify-consent: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
