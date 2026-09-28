#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PRE_HOOK="$PLUGIN_DIR/hooks/pre-browser-navigation-consent.sh"
POST_HOOK="$PLUGIN_DIR/hooks/post-browser-navigation-consent.sh"
MODULE="$PLUGIN_DIR/hooks/lib/verify-consent-v1.js"
FLOOR="$PLUGIN_DIR/hooks/lib/verify-navigation-floor-v1.js"
PREFILTER_LIB="$PLUGIN_DIR/hooks/lib/zensu-browser-consent-prefilter.sh"
VERSION_MODULE="$PLUGIN_DIR/hooks/lib/playwright-cli-version-v1.js"
REGISTRATION_MODULE="$PLUGIN_DIR/hooks/lib/hook-registration-v1.js"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
CONFIG_HELPER="$PLUGIN_DIR/scripts/verify-browser-config.js"
FREE_PORT="$PLUGIN_DIR/scripts/verify-free-port.js"
UNIT_FLOOR="$PLUGIN_DIR/tests/structure/verify-navigation-floor-v1.test.js"
UNIT_CONSENT="$PLUGIN_DIR/tests/structure/verify-consent-v1.test.js"
UNIT_PORT="$PLUGIN_DIR/tests/structure/verify-free-port.test.js"
UNIT_CONFIG="$PLUGIN_DIR/tests/structure/verify-browser-config.test.js"
UNIT_VERSION="$PLUGIN_DIR/tests/structure/playwright-cli-version-v1.test.js"
ESCAPE_STEMS_SUITE="$PLUGIN_DIR/tests/structure/test-gauntlet-loop-skill.sh"
TDD_PHASE_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
SETUP_MD="$PLUGIN_DIR/skills/verify-feature/rules/setup.md"
SESSION="zensu-verify-vc"
CLI="playwright-cli -s=$SESSION"
NL=$'\n'

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
unset CLAUDE_AGENT_TYPE ZENSU_VERIFY_NAVIGATION_POLICY_V1 ZENSU_VERIFY_CONSENT_MEMORY \
  ZENSU_VERIFY_PROJECT_ROOT ZENSU_VERIFY_RECIPE_FILE PLAYWRIGHT_CLI_SESSION 2>/dev/null || true
for _vc_name in $(env | sed -n 's/^\(PLAYWRIGHT_MCP_[A-Za-z0-9_]*\)=.*/\1/p;s/^\(PWTEST_[A-Za-z0-9_]*\)=.*/\1/p'); do
  unset "$_vc_name"
done

for f in "$PRE_HOOK" "$POST_HOOK" "$PREFILTER_LIB" "$MODULE" "$FLOOR" "$VERSION_MODULE" "$REGISTRATION_MODULE" \
  "$CONFIG_HELPER" "$FREE_PORT" "$UNIT_FLOOR" "$UNIT_CONSENT" "$UNIT_PORT" "$UNIT_CONFIG" "$UNIT_VERSION"; do
  [ -f "$f" ] && check "V0 file exists: ${f#"$PLUGIN_DIR"/}" PASS || check "V0 file exists: ${f#"$PLUGIN_DIR"/}" FAIL
done
[ -x "$PRE_HOOK" ] && [ -x "$POST_HOOK" ] && check "V1 both hooks are executable" PASS || check "V1 both hooks are executable" FAIL
bash -n "$PRE_HOOK" 2>/dev/null && bash -n "$POST_HOOK" 2>/dev/null && bash -n "$PREFILTER_LIB" 2>/dev/null \
  && check "V2 bash -n passes for both hooks and the prefilter library" PASS || check "V2 bash -n passes for both hooks and the prefilter library" FAIL
V2B_OK=1
for f in "$MODULE" "$FLOOR" "$VERSION_MODULE" "$REGISTRATION_MODULE" "$CONFIG_HELPER" "$FREE_PORT" \
  "$UNIT_FLOOR" "$UNIT_CONSENT" "$UNIT_PORT" "$UNIT_CONFIG" "$UNIT_VERSION"; do
  node --check "$f" >/dev/null 2>&1 || V2B_OK=0
done
[ "$V2B_OK" -eq 1 ] && check "V2b node --check passes for the four modules, both helpers and the five unit files" PASS \
  || check "V2b node --check passes for the four modules, both helpers and the five unit files" FAIL

MATCHER="$(node -e 'process.stdout.write(String(require(process.argv[1]).CONSENT_MATCHER))' "$MODULE" 2>/dev/null)"
[ "$MATCHER" = "Bash" ] && check "V3 the module's CONSENT_MATCHER is Bash" PASS \
  || check "V3 the module's CONSENT_MATCHER is Bash (got: ${MATCHER:-<none>})" FAIL
if node -e '
  const [file, matcher] = process.argv.slice(1);
  const doc = JSON.parse(require("fs").readFileSync(file, "utf8"));
  const matchers = (event, name) => (doc.hooks[event] || []).flatMap((group) => (group.hooks || [])
    .filter((hook) => String(hook.command || "").includes("/hooks/" + name)).map(() => group.matcher));
  const pre = matchers("PreToolUse", "pre-browser-navigation-consent.sh");
  const post = matchers("PostToolUse", "post-browser-navigation-consent.sh");
  if (pre.length !== 1 || post.length !== 1) process.exit(1);
  if (pre[0] !== matcher || post[0] !== matcher) process.exit(2);
  let stray = 0;
  for (const event of Object.keys(doc.hooks)) {
    if (event !== "PreToolUse") stray += matchers(event, "pre-browser-navigation-consent.sh").length;
    if (event !== "PostToolUse") stray += matchers(event, "post-browser-navigation-consent.sh").length;
  }
  process.exit(stray ? 3 : 0);
' "$HOOKS_JSON" "$MATCHER" 2>/dev/null; then
  check "V4 hooks.json registers each hook exactly once, on the module's matcher and its own event" PASS
else
  check "V4 hooks.json registers each hook exactly once, on the module's matcher and its own event" FAIL
fi
if node -e '
  const consent = require(process.argv[1]);
  const registered = consent.REGISTRATION && consent.REGISTRATION.REGISTERED;
  process.exit(typeof registered === "string" && consent.consentHookRegistered(process.argv[2]) === registered
    && consent.consentRecorderRegistered(process.argv[2]) === registered ? 0 : 1);
' "$MODULE" "$PLUGIN_DIR" 2>/dev/null; then
  check "V4b the module's own registration probes find both hooks in this plugin" PASS
else
  check "V4b the module's own registration probes find both hooks in this plugin" FAIL
fi

. "$(dirname "$0")/lib-unit-summary.sh"

# The summary parse belongs to tests/structure/lib-unit-summary.sh, whose own header records that
# this expression was hand-copied into two suites before that file existed. The floor is on the
# REGISTERED total rather than on passes, for the reason that library states: a passing floor is a
# claim about how many cases run on the host executing it, and cases skip themselves for platform
# reasons. A real failure is already non-zero from node, which the rc arm below reports.
# The floor is EQUAL to what the file registers, and the SUITE-OVERVIEW cell is compared against
# the same number, because a hand-maintained floor one below the real count hides a deleted case —
# which is exactly what the V6 floor did.
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
run_unit "V6 floor" "$UNIT_FLOOR" 14 "verify-navigation-floor-v1.test.js"
run_unit "V7 consent" "$UNIT_CONSENT" 111 "verify-consent-v1.test.js"
run_unit "V7b free-port" "$UNIT_PORT" 3 "verify-free-port.test.js"
run_unit "V7c browser-config" "$UNIT_CONFIG" 13 "verify-browser-config.test.js"
run_unit "V7d cli-version" "$UNIT_VERSION" 14 "playwright-cli-version-v1.test.js"

if grep -qF "require('./verify-navigation-floor-v1.js')" "$MODULE" \
  && grep -qF "'verify-navigation-floor-v1.js'" "$CONFIG_HELPER" \
  && ! grep -qE '^(async )?function (isLoopbackHost|isPublicAddress|classifyOrigin|normalizeRoute|parsePolicyTargets|resolveRemoteHost)\(' "$MODULE" "$CONFIG_HELPER"; then
  check "V8 the consent module and the run-config helper share the one floor module" PASS
else
  check "V8 the consent module and the run-config helper share the one floor module" FAIL
fi

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
  check "V8c neither hook spells either half of the recipe ladder" PASS
else
  check "V8c neither hook spells either half of the recipe ladder" FAIL
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

remember_tmp() {
  TMP_ROOTS="$TMP_ROOTS$1
"
}

new_project() {
  PROJ="$(mktemp -d "${TMPDIR:-/tmp}/zensu-vc.XXXXXX")" || return 1
  PROJ="$(cd "$PROJ" && pwd -P)" || return 1
  remember_tmp "$PROJ"
  export CLAUDE_PROJECT_DIR="$PROJ"
}

bash_payload() {
  node -e '
    const [event, command, sid, cwd, extra] = process.argv.slice(1);
    const body = { hook_event_name: event, tool_name: "Bash", tool_input: { command }, session_id: sid, cwd };
    if (event === "PostToolUse") body.tool_response = { stdout: "", stderr: "", interrupted: false };
    if (extra) Object.assign(body, JSON.parse(extra));
    process.stdout.write(JSON.stringify(body));
  ' "$1" "$2" "$3" "$4" "${5:-}"
}

pre_verdict() {
  local hook_out hook_status
  hook_out="$(bash_payload PreToolUse "$1" "$2" "$3" "${4:-}" | bash "$PRE_HOOK" 2>/dev/null)"
  hook_status=$?
  if [ "$hook_status" -ne 0 ]; then echo "ERROR"; return 0; fi
  printf '%s' "$hook_out" | node -e '
    let s = "";
    process.stdin.on("data", (c) => { s += c; });
    process.stdin.on("end", () => {
      s = s.trim();
      if (!s) { console.log("NONE"); return; }
      try { console.log(String(JSON.parse(s).hookSpecificOutput.permissionDecision).toUpperCase()); }
      catch (_) { console.log("UNPARSED"); }
    });'
}

pre_reason() {
  bash_payload PreToolUse "$1" "$2" "$3" "${4:-}" | bash "$PRE_HOOK" 2>/dev/null | node -e '
    let s = "";
    process.stdin.on("data", (c) => { s += c; });
    process.stdin.on("end", () => {
      try { process.stdout.write(String(JSON.parse(s.trim()).hookSpecificOutput.permissionDecisionReason)); }
      catch (_) { process.stdout.write(""); }
    });'
}

post_run() { bash_payload PostToolUse "$1" "$2" "$3" "${4:-}" | bash "$POST_HOOK" 2>&1 >/dev/null; }

memory_has() {
  node -e '
    const [file, origin, route, decidedBy] = process.argv.slice(1);
    const doc = JSON.parse(require("fs").readFileSync(file, "utf8"));
    const hits = doc.records.filter((r) => r.origin === origin && r.route === route && r.decidedBy === decidedBy);
    process.exit(doc.version === 1 && hits.length === 1 ? 0 : 1);
  ' "$MEMORY" "$1" "$2" "$3" 2>/dev/null
}

memory_count() {
  node -e '
    try { process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).records.length)); }
    catch (_) { process.stdout.write("none"); }
  ' "$MEMORY" 2>/dev/null
}

new_project || { echo "FATAL: fixture"; exit 2; }
GLOBAL_HOME="$(mktemp -d "${TMPDIR:-/tmp}/zensu-vc-home.XXXXXX")" || { echo "FATAL: fixture"; exit 2; }
remember_tmp "$GLOBAL_HOME"
export PWTEST_CLI_GLOBAL_CONFIG="$GLOBAL_HOME"
PW_MEASURED="$(node -e 'process.stdout.write(String(require(process.argv[1]).PLAYWRIGHT_CLI_SOURCE_VERSION || ""))' "$MODULE" 2>/dev/null)"
PW_STUB_BIN="$(mktemp -d "${TMPDIR:-/tmp}/zensu-vc-cli.XXXXXX")" || { echo "FATAL: fixture"; exit 2; }
remember_tmp "$PW_STUB_BIN"
mkdir -p "$PW_STUB_BIN/node_modules/@playwright/cli"
printf '#!/bin/sh\nexit 0\n' > "$PW_STUB_BIN/playwright-cli"
chmod 755 "$PW_STUB_BIN/playwright-cli"
printf '{"name":"@playwright/cli","version":"%s"}\n' "$PW_MEASURED" > "$PW_STUB_BIN/node_modules/@playwright/cli/package.json"
config_helper() {
  PATH="$PW_STUB_BIN:$PATH" node "$CONFIG_HELPER" "$@"
}
PW_STUB_READ="$(PATH="$PW_STUB_BIN:$PATH" node -e 'const v = require(process.argv[1]).installedVersion(process.env); process.stdout.write(v.source + " " + v.version)' "$PLUGIN_DIR/hooks/lib/playwright-cli-version-v1.js" 2>/dev/null)"
if [ -n "$PW_MEASURED" ] && [ "$PW_STUB_READ" = "manifest $PW_MEASURED" ]; then
  check "V12 the stub playwright-cli every run-config helper call puts first on PATH reads as the measured version ($PW_MEASURED)" PASS
else
  check "V12 the stub playwright-cli every run-config helper call puts first on PATH reads as the measured version (got: ${PW_STUB_READ:-<none>})" FAIL
fi
SID="vc-bound"
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$SID" >/dev/null 2>&1 \
  || { check "V11 session baseline" FAIL; echo "----"; echo "test-verify-consent: $PASS PASS / $FAIL FAIL"; exit 1; }
check "V11 session baseline minted a bound record" PASS
MEMORY="$PROJ/.zensu/state/verify-consent-${ZENSU_SESSION_KEY}.json"

UNRELATED_RC=0
UNRELATED_OUT="$(bash_payload PreToolUse "ls -la" "$SID" "$PROJ" | bash "$PRE_HOOK" 2>&1)" || UNRELATED_RC=$?
[ "$UNRELATED_RC" -eq 0 ] && [ -z "$UNRELATED_OUT" ] \
  && check "H1 an unrelated Bash call gets no output and exit 0 from the gate" PASS \
  || check "H1 an unrelated Bash call gets no output and exit 0 from the gate (rc=$UNRELATED_RC)" FAIL
UNRELATED_POST_RC=0
UNRELATED_POST_OUT="$(bash_payload PostToolUse "ls -la" "$SID" "$PROJ" | bash "$POST_HOOK" 2>&1)" || UNRELATED_POST_RC=$?
[ "$UNRELATED_POST_RC" -eq 0 ] && [ -z "$UNRELATED_POST_OUT" ] \
  && check "H1b an unrelated Bash call gets no output and exit 0 from the recorder" PASS \
  || check "H1b an unrelated Bash call gets no output and exit 0 from the recorder (rc=$UNRELATED_POST_RC)" FAIL

EVAL_REASON="$(pre_reason "$CLI eval \"document.cookie\"" "$SID" "$PROJ")"
case "$EVAL_REASON" in
  *"command 'eval' is not available in a /zensu:verify-feature browser session"*) EVAL_NAMED=1 ;;
  *) EVAL_NAMED=0 ;;
esac
[ "$(pre_verdict "$CLI eval \"document.cookie\"" "$SID" "$PROJ")" = "DENY" ] && [ "$EVAL_NAMED" -eq 1 ] \
  && check "H2 eval on a zensu-verify session is denied, naming the command" PASS \
  || check "H2 eval on a zensu-verify session is denied, naming the command" FAIL
[ "$(pre_verdict "npx @playwright/cli -s=$SESSION eval 1" "$SID" "$PROJ")" = "DENY" ] \
  && check "H2b the npx @playwright/cli spelling is gated the same way" PASS \
  || check "H2b the npx @playwright/cli spelling is gated the same way" FAIL
ESCAPED_PAYLOAD="$(bash_payload PreToolUse "npx @playwright/cli -s=$SESSION eval 1" "$SID" "$PROJ" | sed 's|@playwright/cli|@playwright\\/cli|g')"
case "$ESCAPED_PAYLOAD" in
  *'@playwright/cli'*|*'playwright-cli'*) ESCAPED_ONLY=0 ;;
  *'@playwright\/cli'*) ESCAPED_ONLY=1 ;;
  *) ESCAPED_ONLY=0 ;;
esac
[ "$ESCAPED_ONLY" -eq 1 ] \
  && check "H2c-control the payload names the package only with a JSON-escaped slash" PASS \
  || check "H2c-control the payload names the package only with a JSON-escaped slash" FAIL
ESCAPED_OUT="$(printf '%s' "$ESCAPED_PAYLOAD" | bash "$PRE_HOOK" 2>/dev/null)"
case "$ESCAPED_OUT" in
  *'"permissionDecision":"deny"'*) check "H2c a payload that escapes the slash in @playwright/cli still reaches the gate" PASS ;;
  *) check "H2c a payload that escapes the slash in @playwright/cli still reaches the gate" FAIL ;;
esac
TRUNC_RC=0
TRUNC_OUT="$(printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$CLI goto http://127.0.0.1:4200/" | bash "$PRE_HOOK" 2>/dev/null)" || TRUNC_RC=$?
case "$TRUNC_OUT" in
  *'"permissionDecision":"deny"'*'hook-payload-unreadable'*) TRUNC_DENY=1 ;;
  *) TRUNC_DENY=0 ;;
esac
[ "$TRUNC_RC" -eq 0 ] && [ "$TRUNC_DENY" -eq 1 ] \
  && check "H2d a truncated payload that names playwright-cli is denied as unreadable" PASS \
  || check "H2d a truncated payload that names playwright-cli is denied as unreadable (rc=$TRUNC_RC)" FAIL

CR=$'\r'
BS2='\\'
DIFF_LABELS=()
DIFF_COMMANDS=()
DIFF_ENVS=()
diff_add() { DIFF_LABELS+=("$1"); DIFF_COMMANDS+=("$2"); DIFF_ENVS+=("${3:-}"); }
for _vc_case in "H16 quote-split CLI name|playwright-cl''i -s=$SESSION eval 1" \
  "H16b CLI name in another letter case|Playwright-cli -s=$SESSION eval 1" \
  "H16c here-string body|bash <<< '$CLI eval 1'" \
  "H16d navigating call with a co-rider|$CLI goto http://127.0.0.1:4200/ && curl -s http://127.0.0.1:9/" \
  "H16e package launcher on a read-only command|npx @playwright/cli -s=$SESSION snapshot" \
  "H16f session name in another letter case|playwright-cli -s=ZENSU-VERIFY-VC eval 1" \
  "H16g line continuation inside the CLI name|playwright-\\${NL}cli -s=$SESSION eval 1" \
  "H16h line continuation inside the session name|playwright-cli -s zensu-verify\\${NL}-vc eval 1" \
  "H16i session option the parser does not resolve|playwright-cli -S $SESSION eval 1" \
  "H16j escaped backslash before n inside the session under eval|eval \"playwright-cli -s ze${BS2}nsu-verify-vc run-code 1\"" \
  "H16k escaped backslash before n inside the session under bash -c|bash -c \"playwright-cli -s ze${BS2}nsu-verify-vc eval 1\"" \
  "H16l CRLF line continuation inside the CLI name|playwright-\\${CR}${NL}cli -s=$SESSION eval 1" \
  "H16m two line continuations inside the session name|playwright-cli -s zensu-verify\\${NL}\\${NL}-vc eval 1" \
  "H16n double-quote split of the CLI name|playwright-cl\"\"i -s=$SESSION eval 1" \
  "H16o backslash split of the CLI name|playwright-cl\\i -s=$SESSION eval 1" \
  "H16p double-quote split of the session name|playwright-cli -s=zensu-ver\"\"ify-vc eval 1"; do
  _vc_label="${_vc_case%%|*}"
  _vc_command="${_vc_case#*|}"
  _vc_verdict="$(pre_verdict "$_vc_command" "$SID" "$PROJ")"
  [ "$_vc_verdict" = "DENY" ] \
    && check "$_vc_label is denied through the real pre hook" PASS \
    || check "$_vc_label is denied through the real pre hook" FAIL
  diff_add "${_vc_label%% *}" "$_vc_command"
done
diff_add "admitted-plain" "$CLI snapshot"
diff_add "admitted-quote-split-cli" "playwright-cl''i -s=$SESSION snapshot"
diff_add "admitted-quote-split-session" "playwright-cli -s=zensu-ver\"\"ify-vc snapshot"
diff_add "admitted-continued-cli" "playwright-\\${NL}cli -s=$SESSION snapshot"
diff_add "admitted-literal-redirect" "$CLI snapshot > $PROJ/zv-diff.txt"
diff_add "asked-first-navigation" "$CLI goto http://127.0.0.1:4390/diff"
diff_add "admitted-session-variable" "playwright-cli snapshot" "$SESSION"
diff_add "asked-session-variable" "playwright-cli goto http://127.0.0.1:4391/" "$SESSION"
[ "$(pre_verdict "playwright-cl''i -s=$SESSION snapshot" "$SID" "$PROJ")" = "NONE" ] \
  && [ "$(pre_verdict "$CLI goto http://127.0.0.1:4390/diff" "$SID" "$PROJ")" = "ASK" ] \
  && [ "$(PLAYWRIGHT_CLI_SESSION="$SESSION" pre_verdict "playwright-cli goto http://127.0.0.1:4391/" "$SID" "$PROJ")" = "ASK" ] \
  && check "H16-diff-control the corpus carries marked spellings the real hook admits and asks for, directly and through the session variable" PASS \
  || check "H16-diff-control the corpus carries marked spellings the real hook admits and asks for, directly and through the session variable" FAIL
DIFF_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zensu-consent-diff.XXXXXX")"
remember_tmp "$DIFF_ROOT"
DIFF_ROOT="$(cd "$DIFF_ROOT" && pwd -P)"
cp -R "$PLUGIN_DIR/hooks" "$DIFF_ROOT/"
rm -f "$DIFF_ROOT/hooks/lib/verify-consent-v1.js"
diff_passes() {
  case "$(bash_payload PreToolUse "$1" "$SID" "$PROJ" \
    | PLAYWRIGHT_CLI_SESSION="$2" CLAUDE_PLUGIN_ROOT="$DIFF_ROOT" bash "$DIFF_ROOT/hooks/pre-browser-navigation-consent.sh" 2>/dev/null)" in
    *'decision module absent or symlinked'*) printf 1 ;;
    *) printf 0 ;;
  esac
}
diff_marked() {
  node -e 'const m = require(process.argv[1]).commandMarkers(process.argv[2], { PLAYWRIGHT_CLI_SESSION: process.argv[3] }); process.stdout.write(m.cli && m.session ? "1" : "0")' "$MODULE" "$1" "$2" 2>/dev/null
}
[ "$(diff_passes "playwright-cli -s=other-session snapshot" "")" = "0" ] && [ "$(diff_passes "$CLI snapshot" "")" = "1" ] \
  && check "H16-diff-control2 the module-absent copy tells a call its prefilter drops from one that reaches the module" PASS \
  || check "H16-diff-control2 the module-absent copy tells a call its prefilter drops from one that reaches the module" FAIL
DIFF_MISSES=""
_vc_i=0
while [ "$_vc_i" -lt "${#DIFF_COMMANDS[@]}" ]; do
  _vc_marked="$(diff_marked "${DIFF_COMMANDS[$_vc_i]}" "${DIFF_ENVS[$_vc_i]}")"
  if [ "$_vc_marked" != "1" ]; then
    DIFF_MISSES="$DIFF_MISSES ${DIFF_LABELS[$_vc_i]}(unmarked)"
  elif [ "$(diff_passes "${DIFF_COMMANDS[$_vc_i]}" "${DIFF_ENVS[$_vc_i]}")" != "1" ]; then
    DIFF_MISSES="$DIFF_MISSES ${DIFF_LABELS[$_vc_i]}"
  fi
  _vc_i=$((_vc_i + 1))
done
[ "${#DIFF_COMMANDS[@]}" -ge 24 ] && [ -z "$DIFF_MISSES" ] \
  && check "H16-diff every marked spelling in the corpus (${#DIFF_COMMANDS[@]}) passes the prefilter of a module-absent copy, admitted and asked ones included" PASS \
  || check "H16-diff every marked spelling in the corpus (${#DIFF_COMMANDS[@]}) passes the prefilter of a module-absent copy, admitted and asked ones included (misses:${DIFF_MISSES})" FAIL

[ -f "$PREFILTER_LIB" ] && [ "$(grep -c 'LC_ALL=C tr -d' "$PREFILTER_LIB")" = "1" ] && [ "$(grep -c 'LC_ALL=C sed' "$PREFILTER_LIB")" = "1" ] \
  && grep -q '_zensu_scan=.*LC_ALL=C sed .*| LC_ALL=C tr -d' "$PREFILTER_LIB" \
  && check "H17 the prefilter library joins continuations with one LC_ALL=C sed pass, then strips with one LC_ALL=C tr -d pass" PASS \
  || check "H17 the prefilter library joins continuations with one LC_ALL=C sed pass, then strips with one LC_ALL=C tr -d pass" FAIL
H17D_OK=1
for _vc_hook in "$PRE_HOOK" "$POST_HOOK"; do
  grep -qF 'source "$(dirname "$0")/lib/zensu-browser-consent-prefilter.sh"' "$_vc_hook" || H17D_OK=0
  grep -qF 'zensu_browser_consent_marked "$INPUT"' "$_vc_hook" || H17D_OK=0
  if grep -q 'nocasematch\|_zensu_pair\|PLAYWRIGHT_CLI_SESSION' "$_vc_hook"; then H17D_OK=0; fi
  [ "$(grep -c 'LC_ALL=C sed\|LC_ALL=C tr -d' "$_vc_hook")" = "1" ] || H17D_OK=0
  grep 'LC_ALL=C sed\|LC_ALL=C tr -d' "$_vc_hook" | grep -q '^ *_zensu_scan=' || H17D_OK=0
done
[ "$H17D_OK" -eq 1 ] \
  && check "H17d both hooks source the one prefilter library, carry no copy of its two-marker test, and scan only in the library-unavailable fallback" PASS \
  || check "H17d both hooks source the one prefilter library, carry no copy of its two-marker test, and scan only in the library-unavailable fallback" FAIL
PRE_BLOCK="$(cat "$PREFILTER_LIB" 2>/dev/null)"
CLI_MARKER_LIST="$(node -e 'const m = require(process.argv[1]); process.stdout.write(m.CLI_MARKERS.concat(m.SESSION_PREFIX).join("\n"))' "$MODULE" 2>/dev/null)"
SESSION_ENV_NAME="$(node -e 'process.stdout.write(require(process.argv[1]).SESSION_ENV)' "$MODULE" 2>/dev/null)"
H17E_OK=1
[ -n "$CLI_MARKER_LIST" ] || H17E_OK=0
[ -n "$SESSION_ENV_NAME" ] && printf '%s\n' "$PRE_BLOCK" | grep -qF -- "\${${SESSION_ENV_NAME}:-}" || H17E_OK=0
while IFS= read -r _vc_marker; do
  [ -n "$_vc_marker" ] || continue
  printf '%s\n' "$PRE_BLOCK" | grep -qF -- "*${_vc_marker}*" || H17E_OK=0
done <<EOF
$CLI_MARKER_LIST
EOF
[ "$H17E_OK" -eq 1 ] \
  && check "H17e the prefilter names every CLI marker, the session prefix and the session variable the module derives" PASS \
  || check "H17e the prefilter names every CLI marker, the session prefix and the session variable the module derives" FAIL
NOLIB_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zensu-consent-nolib.XXXXXX")"
remember_tmp "$NOLIB_ROOT"
NOLIB_ROOT="$(cd "$NOLIB_ROOT" && pwd -P)"
cp -R "$PLUGIN_DIR/hooks" "$NOLIB_ROOT/"
rm -f "$NOLIB_ROOT/hooks/lib/zensu-browser-consent-prefilter.sh"
nolib_run() {
  bash_payload "$2" "$3" "$SID" "$PROJ" | CLAUDE_PLUGIN_ROOT="$NOLIB_ROOT" bash "$NOLIB_ROOT/hooks/$1"
}
case "$(nolib_run pre-browser-navigation-consent.sh PreToolUse "$CLI snapshot" 2>/dev/null)" in
  *'"permissionDecision":"deny"'*'prefilter library unavailable'*) check "H17g without the prefilter library the pre hook denies a call that names playwright-cli" PASS ;;
  *) check "H17g without the prefilter library the pre hook denies a call that names playwright-cli" FAIL ;;
esac
[ -z "$(nolib_run pre-browser-navigation-consent.sh PreToolUse 'ls -la' 2>/dev/null)" ] \
  && check "H17g1 without the prefilter library an unrelated call passes the pre hook silently" PASS \
  || check "H17g1 without the prefilter library an unrelated call passes the pre hook silently" FAIL
NOLIB_POST_ERR="$(nolib_run post-browser-navigation-consent.sh PostToolUse "$CLI goto http://127.0.0.1:4200/nolib" 2>&1 >/dev/null)"
NOLIB_POST_RC=$?
[ "$NOLIB_POST_RC" -eq 0 ] && case "$NOLIB_POST_ERR" in *'browser consent memory not written (prefilter library unavailable)'*) true ;; *) false ;; esac \
  && check "H17g2 without the prefilter library the recorder skips, exits 0 and names the cause" PASS \
  || check "H17g2 without the prefilter library the recorder skips, exits 0 and names the cause (rc=$NOLIB_POST_RC)" FAIL
NOLIB_QUOTED="pla''ywright-cli -s=zensu-ver''ify-nolib snapshot"
case "$(nolib_run pre-browser-navigation-consent.sh PreToolUse "$NOLIB_QUOTED" 2>/dev/null)" in
  *'"permissionDecision":"deny"'*'prefilter library unavailable'*) check "H17g3 without the prefilter library a quote-split spelling of both markers is still denied" PASS ;;
  *) check "H17g3 without the prefilter library a quote-split spelling of both markers is still denied" FAIL ;;
esac
NOLIB_JOINED="play\\${NL}wright-cli -s=zensu-ver\\${NL}ify-nolib snapshot"
case "$(nolib_run pre-browser-navigation-consent.sh PreToolUse "$NOLIB_JOINED" 2>/dev/null)" in
  *'"permissionDecision":"deny"'*'prefilter library unavailable'*) check "H17g4 without the prefilter library a line-continuation spelling of both markers is still denied" PASS ;;
  *) check "H17g4 without the prefilter library a line-continuation spelling of both markers is still denied" FAIL ;;
esac

BASH_BIN="$(command -v bash)"
NONODE_BIN="$(mktemp -d "${TMPDIR:-/tmp}/zensu-consent-nonode.XXXXXX")"
remember_tmp "$NONODE_BIN"
for _vc_tool in cat sed tr dirname; do
  ln -s "$(command -v "$_vc_tool")" "$NONODE_BIN/$_vc_tool"
done
if env PATH="$NONODE_BIN" "$BASH_BIN" -c 'command -v node' >/dev/null 2>&1; then
  check "H17a-control the stripped PATH hides node" FAIL
else
  check "H17a-control the stripped PATH hides node" PASS
fi
CWD_ONLY="$PROJ/playwright-cli-notes"
mkdir -p "$CWD_ONLY"
CWD_ONLY_RC=0
CWD_ONLY_OUT="$(bash_payload PreToolUse "ls -la" "$SID" "$CWD_ONLY" | env PATH="$NONODE_BIN" "$BASH_BIN" "$PRE_HOOK" 2>&1)" \
  || CWD_ONLY_RC=$?
[ "$CWD_ONLY_RC" -eq 0 ] && [ -z "$CWD_ONLY_OUT" ] \
  && check "H17a a payload naming playwright-cli only in its cwd exits 0 before node is needed" PASS \
  || check "H17a a payload naming playwright-cli only in its cwd exits 0 before node is needed (rc=$CWD_ONLY_RC)" FAIL
NONODE_PRE="$(bash_payload PreToolUse "$CLI snapshot" "$SID" "$PROJ" | env PATH="$NONODE_BIN" "$BASH_BIN" "$PRE_HOOK" 2>/dev/null)"
case "$NONODE_PRE" in
  *'"permissionDecision":"deny"'*'node unavailable'*) check "H17b without node the pre hook denies a marked call" PASS ;;
  *) check "H17b without node the pre hook denies a marked call" FAIL ;;
esac
NONODE_POST_RC=0
NONODE_POST_ERR="$(bash_payload PostToolUse "$CLI snapshot" "$SID" "$PROJ" | env PATH="$NONODE_BIN" "$BASH_BIN" "$POST_HOOK" 2>&1 >/dev/null)" \
  || NONODE_POST_RC=$?
case "$NONODE_POST_ERR" in
  *'consent memory not written (node unavailable)'*) NONODE_POST_NAMED=1 ;;
  *) NONODE_POST_NAMED=0 ;;
esac
[ "$NONODE_POST_RC" -eq 0 ] && [ "$NONODE_POST_NAMED" -eq 1 ] \
  && check "H17c without node the recorder skips, exits 0 and names the cause" PASS \
  || check "H17c without node the recorder skips, exits 0 and names the cause (rc=$NONODE_POST_RC)" FAIL

NOSED_BIN="$(mktemp -d "${TMPDIR:-/tmp}/zensu-consent-nosed.XXXXXX")"
remember_tmp "$NOSED_BIN"
printf '#!/bin/sh\nexit 127\n' > "$NOSED_BIN/sed"
chmod +x "$NOSED_BIN/sed"
NOSED_PRE="$(bash_payload PreToolUse "$CLI eval 1" "$SID" "$PROJ" | env PATH="$NOSED_BIN:$PATH" "$BASH_BIN" "$PRE_HOOK" 2>/dev/null)"
case "$NOSED_PRE" in
  *'"permissionDecision":"deny"'*'eval'*) check "H17f with sed failing the pre hook falls back to the raw payload and still judges a marked call" PASS ;;
  *) check "H17f with sed failing the pre hook falls back to the raw payload and still judges a marked call" FAIL ;;
esac
JOINED_PAYLOAD="$(bash_payload PreToolUse "playwright-\\"$'\n'"cli -s=$SESSION eval 1" "$SID" "$PROJ")"
JOINED_WITH_SED="$(printf '%s' "$JOINED_PAYLOAD" | "$BASH_BIN" "$PRE_HOOK" 2>/dev/null)"
JOINED_WITHOUT_SED="$(printf '%s' "$JOINED_PAYLOAD" | env PATH="$NOSED_BIN:$PATH" "$BASH_BIN" "$PRE_HOOK" 2>/dev/null)"
case "$JOINED_WITH_SED" in
  *'"permissionDecision":"deny"'*'eval'*) JOINED_MARKED=1 ;;
  *) JOINED_MARKED=0 ;;
esac
[ "$JOINED_MARKED" -eq 1 ] && [ -z "$JOINED_WITHOUT_SED" ] \
  && check "H17f2-control the failing sed shadows the hooks' sed: a payload only the sed join marks is denied with a working sed and passes silently with the failing one" PASS \
  || check "H17f2-control the failing sed shadows the hooks' sed: a payload only the sed join marks is denied with a working sed and passes silently with the failing one" FAIL
NOSED_ESCAPED="$(printf '%s' "$ESCAPED_PAYLOAD" | env PATH="$NOSED_BIN:$PATH" "$BASH_BIN" "$PRE_HOOK" 2>/dev/null)"
case "$NOSED_ESCAPED" in
  *'"permissionDecision":"deny"'*) check "H17f2 with sed failing a payload naming the package only with a JSON-escaped slash still reaches the gate" PASS ;;
  *) check "H17f2 with sed failing a payload naming the package only with a JSON-escaped slash still reaches the gate" FAIL ;;
esac

DOCTOR_NAMED_DIR="$PROJ/playwright-cli/zensu-verify-notes"
mkdir -p "$DOCTOR_NAMED_DIR"
DOCTOR_CMD="CLAUDE_PROJECT_DIR=$DOCTOR_NAMED_DIR bash $PLUGIN_DIR/hooks/lib/zensu-doctor.sh"
ADOPT_CMD="CLAUDE_PLUGIN_DATA=$DOCTOR_NAMED_DIR bash $PLUGIN_DIR/hooks/lib/zensu-session-adopt.sh --confirm"
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    check "H18 the recognized /zensu:doctor and adoption commands pass the consent pre hook SKIPPED (the recognizer refuses on win32)" PASS
    ;;
  *)
    [ "$(HOME="$GLOBAL_HOME" pre_verdict "$DOCTOR_CMD" "$SID" "$PROJ")" = "NONE" ] \
      && check "H18 the recognized /zensu:doctor command passes although its project path names both markers" PASS \
      || check "H18 the recognized /zensu:doctor command passes although its project path names both markers" FAIL
    [ "$(HOME="$GLOBAL_HOME" pre_verdict "$ADOPT_CMD" "$SID" "$PROJ")" = "NONE" ] \
      && check "H18a the recognized adoption command passes although its data path names both markers" PASS \
      || check "H18a the recognized adoption command passes although its data path names both markers" FAIL
    [ "$(HOME="$GLOBAL_HOME" pre_verdict "$DOCTOR_CMD" "$SID" "$PROJ" '{"agent_id":"agent-1","agent_type":"general-purpose"}')" = "DENY" ] \
      && check "H18b-control the same doctor command from a subagent is still judged and denied" PASS \
      || check "H18b-control the same doctor command from a subagent is still judged and denied" FAIL
    [ "$(HOME="$GLOBAL_HOME" pre_verdict "$DOCTOR_CMD; true" "$SID" "$PROJ")" = "DENY" ] \
      && check "H18c-control a doctor command with a co-rider is not recognized and is denied" PASS \
      || check "H18c-control a doctor command with a co-rider is not recognized and is denied" FAIL
    ORDER_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zensu-consent-order.XXXXXX")"
    remember_tmp "$ORDER_ROOT"
    ORDER_ROOT="$(cd "$ORDER_ROOT" && pwd -P)"
    cp -R "$PLUGIN_DIR/hooks" "$ORDER_ROOT/"
    rm -f "$ORDER_ROOT/hooks/lib/verify-consent-v1.js"
    order_pre() {
      bash_payload PreToolUse "$1" "$SID" "$PROJ" \
        | HOME="$GLOBAL_HOME" CLAUDE_PLUGIN_ROOT="$ORDER_ROOT" bash "$ORDER_ROOT/hooks/pre-browser-navigation-consent.sh" 2>/dev/null
    }
    [ -z "$(order_pre "CLAUDE_PROJECT_DIR=$DOCTOR_NAMED_DIR bash $ORDER_ROOT/hooks/lib/zensu-doctor.sh")" ] \
      && check "H18d the doctor allowance runs before the module-absent arm" PASS \
      || check "H18d the doctor allowance runs before the module-absent arm" FAIL
    case "$(order_pre "$CLI goto http://127.0.0.1:4200/")" in
      *'"permissionDecision":"deny"'*'decision module absent or symlinked'*)
        check "H18d-control in the same tree a gated call is denied for the absent module" PASS ;;
      *) check "H18d-control in the same tree a gated call is denied for the absent module" FAIL ;;
    esac
    nolib_pre() {
      bash_payload PreToolUse "$1" "$SID" "$PROJ" \
        | HOME="$GLOBAL_HOME" CLAUDE_PLUGIN_ROOT="$NOLIB_ROOT" bash "$NOLIB_ROOT/hooks/pre-browser-navigation-consent.sh" 2>/dev/null
    }
    [ -z "$(nolib_pre "CLAUDE_PROJECT_DIR=$DOCTOR_NAMED_DIR bash $NOLIB_ROOT/hooks/lib/zensu-doctor.sh")" ] \
      && check "H18e the doctor allowance runs before the prefilter-library-unavailable arm" PASS \
      || check "H18e the doctor allowance runs before the prefilter-library-unavailable arm" FAIL
    case "$(nolib_pre "$CLI goto http://127.0.0.1:4200/")" in
      *'"permissionDecision":"deny"'*'prefilter library unavailable'*)
        check "H18e-control in the same tree a gated call is denied for the missing prefilter library" PASS ;;
      *) check "H18e-control in the same tree a gated call is denied for the missing prefilter library" FAIL ;;
    esac
    ;;
esac

[ "$(pre_verdict "$CLI goto http://127.0.0.1:4200/login" "$SID" "$PROJ")" = "ASK" ] \
  && check "H3 the first navigation to a loopback origin asks" PASS \
  || check "H3 the first navigation to a loopback origin asks" FAIL
FIRST_REASON="$(pre_reason "$CLI goto http://127.0.0.1:4200/login" "$SID" "$PROJ")"
case "$FIRST_REASON" in
  *"The playwright-cli browser session $SESSION is about to reach http://127.0.0.1:4200 (local loopback)."*'any page on it'*'Consent is per origin, never per route.'*)
    check "H3a the prompt names the session, the origin and the per-origin grant" PASS ;;
  *) check "H3a the prompt names the session, the origin and the per-origin grant" FAIL ;;
esac
[ ! -e "$MEMORY" ] && check "H4 asking writes no memory" PASS || check "H4 asking writes no memory" FAIL

POST_RC=0
POST_ERR="$(post_run "$CLI goto http://127.0.0.1:4200/login" "$SID" "$PROJ")" || POST_RC=$?
[ "$POST_RC" -eq 0 ] && [ -z "$POST_ERR" ] && memory_has "http://127.0.0.1:4200" "/login" "asked" \
  && check "H5 the recorder writes the approved navigation as asked for the bound session" PASS \
  || check "H5 the recorder writes the approved navigation as asked for the bound session (rc=$POST_RC err=$POST_ERR)" FAIL
if node -e '
  const doc = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const keys = doc.records.map((r) => Object.keys(r).sort().join(","));
  process.exit(keys.length === 1 && keys[0] === "at,decidedBy,origin,route" ? 0 : 1);
' "$MEMORY" 2>/dev/null; then
  check "H5a a record carries origin, route, decidedBy and at, and nothing else" PASS
else
  check "H5a a record carries origin, route, decidedBy and at, and nothing else" FAIL
fi
[ "$(pre_verdict "$CLI goto http://127.0.0.1:4200/login" "$SID" "$PROJ")" = "NONE" ] \
  && check "H6 the remembered origin now gets no decision" PASS \
  || check "H6 the remembered origin now gets no decision" FAIL
[ "$(pre_verdict "$CLI goto http://127.0.0.1:4200/admin" "$SID" "$PROJ")" = "NONE" ] \
  && check "H6a another route on the remembered origin gets no decision either" PASS \
  || check "H6a another route on the remembered origin gets no decision either" FAIL
post_run "$CLI goto http://127.0.0.1:4200/admin" "$SID" "$PROJ" >/dev/null
memory_has "http://127.0.0.1:4200" "/admin" "remembered" && [ "$(memory_count)" = "2" ] \
  && check "H6b a navigation on a remembered origin is recorded as remembered" PASS \
  || check "H6b a navigation on a remembered origin is recorded as remembered" FAIL
post_run "playwright-\\${NL}cli -s=$SESSION goto http://127.0.0.1:4200/joined" "$SID" "$PROJ" >/dev/null
memory_has "http://127.0.0.1:4200" "/joined" "remembered" \
  && check "H6c the recorder joins a line continuation inside the CLI name" PASS \
  || check "H6c the recorder joins a line continuation inside the CLI name" FAIL
H6D_BEFORE="$(memory_count)"
H6D_OUT="$(post_run "Playwright-cli -s=$SESSION goto http://127.0.0.1:4200/cased" "$SID" "$PROJ")"
H6D_REASON="$(pre_reason "Playwright-cli -s=$SESSION goto http://127.0.0.1:4200/cased" "$SID" "$PROJ")"
H6D_NOT_BARE="$(node -e 'process.stdout.write(String(require(process.argv[1]).REASONS.CLI_NOT_BARE || ""))' "$MODULE" 2>/dev/null)"
if [ -z "$H6D_OUT" ] && [ -n "$H6D_BEFORE" ] && [ "$(memory_count)" = "$H6D_BEFORE" ] \
  && ! memory_has "http://127.0.0.1:4200" "/cased" "remembered" \
  && [ -n "$H6D_NOT_BARE" ] && [ "${H6D_REASON#*"$H6D_NOT_BARE"}" != "$H6D_REASON" ]; then
  check "H6d the recorder records nothing and reports no fault for a CLI name in another letter case, which the gate refuses as not bare" PASS
else
  check "H6d the recorder records nothing and reports no fault for a CLI name in another letter case, which the gate refuses as not bare (recorder: ${H6D_OUT:-<silent>}; records: ${H6D_BEFORE:-?}->$(memory_count); gate: ${H6D_REASON:-<none>})" FAIL
fi
post_run "playwright-cl''i -s=$SESSION goto http://127.0.0.1:4200/split" "$SID" "$PROJ" >/dev/null
memory_has "http://127.0.0.1:4200" "/split" "remembered" \
  && check "H6e the recorder reads a quote-split CLI name" PASS \
  || check "H6e the recorder reads a quote-split CLI name" FAIL
post_run "playwright-cl\"\"i -s=$SESSION goto http://127.0.0.1:4200/dsplit" "$SID" "$PROJ" >/dev/null
memory_has "http://127.0.0.1:4200" "/dsplit" "remembered" \
  && check "H6g the recorder reads a double-quote-split CLI name" PASS \
  || check "H6g the recorder reads a double-quote-split CLI name" FAIL
PLAYWRIGHT_CLI_SESSION="$SESSION" post_run "playwright-cli goto http://127.0.0.1:4200/envonly" "$SID" "$PROJ" >/dev/null
memory_has "http://127.0.0.1:4200" "/envonly" "remembered" \
  && check "H6f the recorder reads a session named only by the environment" PASS \
  || check "H6f the recorder reads a session named only by the environment" FAIL
[ "$(pre_verdict "$CLI tab-new http://127.0.0.1:4201/" "$SID" "$PROJ")" = "ASK" ] \
  && check "H7 a second loopback origin still asks" PASS \
  || check "H7 a second loopback origin still asks" FAIL

[ "$(pre_verdict "playwright-cli -s=mine eval \"document.cookie\"" "$SID" "$PROJ")" = "NONE" ] \
  && check "H8 eval on a session that is not zensu-verify gets no decision" PASS \
  || check "H8 eval on a session that is not zensu-verify gets no decision" FAIL
[ "$(pre_verdict "playwright-cli eval \"document.cookie\"" "$SID" "$PROJ")" = "NONE" ] \
  && check "H8a eval on the default session gets no decision" PASS \
  || check "H8a eval on the default session gets no decision" FAIL
[ "$(PLAYWRIGHT_CLI_SESSION="$SESSION" pre_verdict "playwright-cli goto http://127.0.0.1:4350/" "$SID" "$PROJ")" = "ASK" ] \
  && check "H8b a zensu-verify session named by the environment is gated" PASS \
  || check "H8b a zensu-verify session named by the environment is gated" FAIL

for url in "http://localhost:4200/" "http://10.0.0.5/" "https://192.168.1.10/" "http://user:pw@127.0.0.1:4200/" \
  "http://127.0.0.1:4200/?t=1" "http://127.0.0.1:4200/#x" "file:///etc/passwd"; do
  [ "$(pre_verdict "$CLI goto $url" "$SID" "$PROJ")" = "DENY" ] \
    && check "H9 the floor denies $url" PASS || check "H9 the floor denies $url" FAIL
done
case "$(pre_reason "$CLI goto https://app.example.com/" "$SID" "$PROJ")" in
  *'parent-environment navigation policy'*) check "H9a a remote target is refused in consent mode, naming the policy it needs" PASS ;;
  *) check "H9a a remote target is refused in consent mode, naming the policy it needs" FAIL ;;
esac

SUBAGENT='{"agent_id":"agent-1","agent_type":"general-purpose"}'
case "$(pre_reason "$CLI snapshot" "$SID" "$PROJ" "$SUBAGENT")" in
  *'main-thread only'*) check "H10 a subagent is denied a zensu-verify session" PASS ;;
  *) check "H10 a subagent is denied a zensu-verify session" FAIL ;;
esac
[ "$(pre_verdict "playwright-cli -s=mine snapshot" "$SID" "$PROJ" "$SUBAGENT")" = "NONE" ] \
  && check "H10a a subagent call on another session gets no decision" PASS \
  || check "H10a a subagent call on another session gets no decision" FAIL

RUN_DIR="$PROJ/run1"
mkdir -p "$RUN_DIR"
HELPER_OUT="$(config_helper --run-dir "$RUN_DIR" --mode local --origin 'http://127.0.0.1:4310' 2>/dev/null)"
RUN_SESSION="$(printf '%s\n' "$HELPER_OUT" | sed -n 's/^session=//p')"
RUN_CONFIG="$(printf '%s\n' "$HELPER_OUT" | sed -n 's/^config=//p')"
if [ "$RUN_SESSION" = "zensu-verify-run1" ] && [ "$RUN_CONFIG" = "$RUN_DIR/playwright-cli.json" ] && [ -f "$RUN_CONFIG" ] \
  && printf '%s\n' "$HELPER_OUT" | grep -qx 'mode=consent'; then
  check "H11-control the run-config helper wrote the config, named the session and reported consent mode" PASS
else
  check "H11-control the run-config helper wrote the config, named the session and reported consent mode" FAIL
fi
OPEN_CMD="playwright-cli -s=$RUN_SESSION open --config='$RUN_CONFIG' http://127.0.0.1:4310/"
[ "$(pre_verdict "$OPEN_CMD" "$SID" "$PROJ")" = "ASK" ] \
  && check "H11 open with the helper's run config asks for its origin" PASS \
  || check "H11 open with the helper's run config asks for its origin" FAIL
case "$(pre_reason "playwright-cli -s=$RUN_SESSION open http://127.0.0.1:4310/" "$SID" "$PROJ")" in
  *'needs --config=<absolute path>'*) check "H11a open without --config is denied" PASS ;;
  *) check "H11a open without --config is denied" FAIL ;;
esac
case "$(pre_reason "playwright-cli -s=$RUN_SESSION open --config='$RUN_CONFIG' --browser=firefox http://127.0.0.1:4310/" "$SID" "$PROJ")" in
  *'--browser must name a chrome, msedge or chromium channel'*) check "H11b open with a non-Chromium browser is denied" PASS ;;
  *) check "H11b open with a non-Chromium browser is denied" FAIL ;;
esac
case "$(PLAYWRIGHT_MCP_CONFIG=/nonexistent/config.json pre_reason "$OPEN_CMD" "$SID" "$PROJ")" in
  *'the launch environment sets PLAYWRIGHT_MCP_CONFIG, which overrides the run config'*)
    check "H11c open under an ambient PLAYWRIGHT_MCP_ override is denied" PASS ;;
  *) check "H11c open under an ambient PLAYWRIGHT_MCP_ override is denied" FAIL ;;
esac
mkdir -p "$GLOBAL_HOME/.playwright"
printf '%s\n' '{"browser":{"browserName":"firefox"}}' > "$GLOBAL_HOME/.playwright/cli.config.json"
case "$(pre_reason "$OPEN_CMD" "$SID" "$PROJ")" in
  *'selects a browser other than chromium'*) check "H11d open under a global config that selects another browser is denied" PASS ;;
  *) check "H11d open under a global config that selects another browser is denied" FAIL ;;
esac
rm -f "$GLOBAL_HOME/.playwright/cli.config.json"
[ "$(pre_verdict "$OPEN_CMD" "$SID" "$PROJ")" = "ASK" ] \
  && check "H11e-control removing the global config restores the prompt" PASS \
  || check "H11e-control removing the global config restores the prompt" FAIL

printf '%s\n' 'version: 1' 'validate:' '  evidenceSafety:' '    routes: ["/", "/inventory"]' > "$PROJ/.zensu/runtime.yaml"
case "$(pre_reason "$CLI goto http://127.0.0.1:4340/inventory" "$SID" "$PROJ")" in
  *'synthetic-safe: /, /inventory.'*) check "H12 the prompt shows the routes the bound project's recipe declares" PASS ;;
  *) check "H12 the prompt shows the routes the bound project's recipe declares" FAIL ;;
esac
case "$(pre_reason "$CLI goto http://127.0.0.1:4340/inventory" "no-such-session" "$PROJ")" in
  *'synthetic-safe'*) check "H12-control an unbound session has no project root to read a recipe from" FAIL ;;
  '') check "H12-control an unbound session has no project root to read a recipe from" FAIL ;;
  *) check "H12-control an unbound session has no project root to read a recipe from" PASS ;;
esac
rm -f "$PROJ/.zensu/runtime.yaml"

VALID_POLICY='{"version":1,"mode":"local","targets":[{"origin":"http://127.0.0.1:4300","routes":["/","/login"],"evidenceMode":"declared-safe"}]}'
[ "$(ZENSU_VERIFY_NAVIGATION_POLICY_V1="$VALID_POLICY" pre_verdict "$CLI goto http://127.0.0.1:4300/login" "$SID" "$PROJ")" = "NONE" ] \
  && check "H13 policy mode admits a declared route of a policy target without a prompt" PASS \
  || check "H13 policy mode admits a declared route of a policy target without a prompt" FAIL
case "$(ZENSU_VERIFY_NAVIGATION_POLICY_V1="$VALID_POLICY" pre_reason "$CLI goto http://127.0.0.1:4300/admin" "$SID" "$PROJ")" in
  *'route is not approved for evidence by the navigation policy'*) check "H13a policy mode denies an undeclared route" PASS ;;
  *) check "H13a policy mode denies an undeclared route" FAIL ;;
esac
case "$(ZENSU_VERIFY_NAVIGATION_POLICY_V1="$VALID_POLICY" pre_reason "$CLI goto http://127.0.0.1:4200/login" "$SID" "$PROJ")" in
  *'origin is not a target of the navigation policy'*) check "H13b policy mode denies a non-target even when the consent memory remembers it" PASS ;;
  *) check "H13b policy mode denies a non-target even when the consent memory remembers it" FAIL ;;
esac
case "$(ZENSU_VERIFY_NAVIGATION_POLICY_V1='{"version":1}' pre_reason "$CLI goto http://127.0.0.1:4300/" "$SID" "$PROJ")" in
  *'the navigation policy in the launch environment is invalid'*) check "H13c an invalid policy in the environment denies rather than falling back to consent" PASS ;;
  *) check "H13c an invalid policy in the environment denies rather than falling back to consent" FAIL ;;
esac
ZENSU_VERIFY_NAVIGATION_POLICY_V1="$VALID_POLICY" post_run "$CLI goto http://127.0.0.1:4300/login" "$SID" "$PROJ" >/dev/null
memory_has "http://127.0.0.1:4300" "/login" "policy-mode" \
  && check "H13d the recorder writes a policy-mode navigation as policy-mode" PASS \
  || check "H13d the recorder writes a policy-mode navigation as policy-mode" FAIL

COUNT_BEFORE="$(memory_count)"
post_run "$CLI goto http://127.0.0.1:4360/" "$SID" "$PROJ" '{"tool_response":{"stdout":"","stderr":"","interrupted":true}}' >/dev/null
post_run "$CLI goto https://app.example.com/" "$SID" "$PROJ" >/dev/null
post_run "$CLI eval 1" "$SID" "$PROJ" >/dev/null
post_run "$CLI goto http://localhost:4200/" "$SID" "$PROJ" >/dev/null
COUNT_AFTER="$(memory_count)"
[ "$COUNT_BEFORE" = "7" ] && [ "$COUNT_AFTER" = "$COUNT_BEFORE" ] \
  && check "H14 interrupted and denied calls are never recorded" PASS \
  || check "H14 interrupted and denied calls are never recorded (before=$COUNT_BEFORE after=$COUNT_AFTER)" FAIL
[ "$(pre_verdict "$CLI goto http://127.0.0.1:4360/" "$SID" "$PROJ")" = "ASK" ] \
  && check "H14a an origin whose call was interrupted still asks" PASS \
  || check "H14a an origin whose call was interrupted still asks" FAIL

[ "$(pre_verdict "$CLI goto http://127.0.0.1:4200/x" "no-such-session" "$PROJ")" = "ASK" ] \
  && check "H15 an unbound session asks for an origin the bound session remembers" PASS \
  || check "H15 an unbound session asks for an origin the bound session remembers" FAIL
[ "$(pre_verdict "$CLI goto http://localhost:4200/" "no-such-session" "$PROJ")" = "DENY" ] \
  && check "H15a the floor holds without a bound session" PASS \
  || check "H15a the floor holds without a bound session" FAIL
BEFORE="$(ls -A "$PROJ/.zensu/state" | LC_ALL=C sort | tr '\n' ' ')"
UNBOUND_RC=0
UNBOUND_ERR="$(post_run "$CLI goto http://127.0.0.1:4200/x" "no-such-session" "$PROJ")" || UNBOUND_RC=$?
AFTER="$(ls -A "$PROJ/.zensu/state" | LC_ALL=C sort | tr '\n' ' ')"
case "$UNBOUND_ERR" in
  *'consent memory not written (no bound session)'*) UNBOUND_SAID=1 ;;
  *) UNBOUND_SAID=0 ;;
esac
[ "$UNBOUND_RC" -eq 0 ] && [ "$UNBOUND_SAID" -eq 1 ] && [ "$BEFORE" = "$AFTER" ] \
  && check "H15b an unbound recorder writes nothing, exits 0 and names its cause" PASS \
  || check "H15b an unbound recorder writes nothing, exits 0 and names its cause (rc=$UNBOUND_RC)" FAIL

bash_payload PreToolUse "$CLI goto http://127.0.0.1:4200/" "$SID" "$PROJ" > "$PROJ/mismatch-pre.json"
bash_payload PostToolUse "$CLI goto http://127.0.0.1:4200/" "$SID" "$PROJ" > "$PROJ/mismatch-post.json"
bash_payload PreToolUse "ls -la" "$SID" "$PROJ" > "$PROJ/unmarked-pre.json"
bash_payload PreToolUse "playwright-cli -s=mine snapshot" "$SID" "$PROJ" > "$PROJ/cli-only-pre.json"
bash_payload PostToolUse "ls -la" "$SID" "$PROJ" > "$PROJ/unmarked-post.json"
bash_payload PostToolUse "playwright-cli -s=mine snapshot" "$SID" "$PROJ" > "$PROJ/cli-only-post.json"
degraded_quiet() {
  local root="$1" hook="$2" payload="$3" out rc=0
  out="$(CLAUDE_PLUGIN_ROOT="$root" bash "$root/hooks/$hook" < "$payload" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ]
}
ROOT_MISMATCH_RC=0
CLAUDE_PLUGIN_ROOT="$PROJ" bash "$PRE_HOOK" < "$PROJ/mismatch-pre.json" >/dev/null 2>&1 || ROOT_MISMATCH_RC=$?
[ "$ROOT_MISMATCH_RC" -eq 2 ] && check "V28 an inherited plugin root that does not match refuses with exit 2" PASS \
  || check "V28 an inherited plugin root that does not match refuses with exit 2 (rc=$ROOT_MISMATCH_RC)" FAIL
[ "$(CLAUDE_PLUGIN_ROOT="$PROJ" pre_verdict "$CLI goto http://127.0.0.1:4200/" "$SID" "$PROJ")" = "ERROR" ] \
  && check "V28a the harness reports an aborted hook as ERROR rather than as no decision" PASS \
  || check "V28a the harness reports an aborted hook as ERROR rather than as no decision" FAIL

NOMOD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zensu-consent-nomod.XXXXXX")"
remember_tmp "$NOMOD_ROOT"
mkdir -p "$NOMOD_ROOT/hooks/lib"
cp "$PRE_HOOK" "$NOMOD_ROOT/hooks/"
cp "$PREFILTER_LIB" "$NOMOD_ROOT/hooks/lib/"
NOMOD_DENY="$(CLAUDE_PLUGIN_ROOT="$NOMOD_ROOT" bash "$NOMOD_ROOT/hooks/pre-browser-navigation-consent.sh" < "$PROJ/mismatch-pre.json" 2>/dev/null)"
case "$NOMOD_DENY" in
  *'"permissionDecision":"deny"'*'decision module absent or symlinked'*)
    check "V31d a plugin root with no decision module denies, naming the module" PASS ;;
  *) check "V31d a plugin root with no decision module denies, naming the module" FAIL ;;
esac
SYMMOD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zensu-consent-symmod.XXXXXX")"
remember_tmp "$SYMMOD_ROOT"
mkdir -p "$SYMMOD_ROOT/hooks/lib"
cp "$PRE_HOOK" "$SYMMOD_ROOT/hooks/"
cp "$PREFILTER_LIB" "$SYMMOD_ROOT/hooks/lib/"
ln -s "$MODULE" "$SYMMOD_ROOT/hooks/lib/verify-consent-v1.js"
SYMMOD_DENY="$(CLAUDE_PLUGIN_ROOT="$SYMMOD_ROOT" bash "$SYMMOD_ROOT/hooks/pre-browser-navigation-consent.sh" < "$PROJ/mismatch-pre.json" 2>/dev/null)"
case "$SYMMOD_DENY" in
  *'"permissionDecision":"deny"'*'decision module absent or symlinked'*)
    check "V31f a plugin root whose decision module is a symlink denies, naming the module" PASS ;;
  *) check "V31f a plugin root whose decision module is a symlink denies, naming the module" FAIL ;;
esac
BADMOD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zensu-consent-badmod.XXXXXX")"
remember_tmp "$BADMOD_ROOT"
mkdir -p "$BADMOD_ROOT/hooks/lib"
cp "$PRE_HOOK" "$BADMOD_ROOT/hooks/"
cp "$PREFILTER_LIB" "$BADMOD_ROOT/hooks/lib/"
printf 'throw new Error("module load fault");\n' > "$BADMOD_ROOT/hooks/lib/verify-consent-v1.js"
BADMOD_DENY="$(CLAUDE_PLUGIN_ROOT="$BADMOD_ROOT" bash "$BADMOD_ROOT/hooks/pre-browser-navigation-consent.sh" < "$PROJ/mismatch-pre.json" 2>/dev/null)"
case "$BADMOD_DENY" in
  *'"permissionDecision":"deny"'*'decision module failed'*)
    check "V31e a decision module that will not load denies rather than allowing" PASS ;;
  *) check "V31e a decision module that will not load denies rather than allowing" FAIL ;;
esac
DEGRADED_PRE_OK=1
for _vc_root in "$NOMOD_ROOT" "$SYMMOD_ROOT" "$BADMOD_ROOT"; do
  for _vc_payload in "$PROJ/unmarked-pre.json" "$PROJ/cli-only-pre.json"; do
    degraded_quiet "$_vc_root" pre-browser-navigation-consent.sh "$_vc_payload" || DEGRADED_PRE_OK=0
  done
done
[ "$DEGRADED_PRE_OK" -eq 1 ] \
  && check "V31g every degraded pre-hook root lets an unmarked and a CLI-only payload through silently" PASS \
  || check "V31g every degraded pre-hook root lets an unmarked and a CLI-only payload through silently" FAIL
# AC-011: post_run routes stderr onto stdout and every call site discarded it, so the
# recorder's exit status was read by nothing — a hook that crashed before reading the payload
# satisfied the record-count assertions just as well as one that worked. This reads both.
NOMODP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zensu-consent-nomodp.XXXXXX")"
remember_tmp "$NOMODP_ROOT"
mkdir -p "$NOMODP_ROOT/hooks/lib"
cp "$POST_HOOK" "$NOMODP_ROOT/hooks/"
cp "$PREFILTER_LIB" "$NOMODP_ROOT/hooks/lib/"
POST_SKIP_RC=0
POST_SKIP_OUT="$(CLAUDE_PLUGIN_ROOT="$NOMODP_ROOT" bash "$NOMODP_ROOT/hooks/post-browser-navigation-consent.sh" < "$PROJ/mismatch-post.json" 2>&1 >/dev/null)" \
  || POST_SKIP_RC=$?
case "$POST_SKIP_OUT" in
  *'consent memory not written (decision module absent or symlinked)'*) POST_SKIP_NAMED=1 ;;
  *) POST_SKIP_NAMED=0 ;;
esac
[ "$POST_SKIP_RC" -eq 0 ] && [ "$POST_SKIP_NAMED" -eq 1 ] \
  && check "V32b a recorder skip exits 0 and names its cause" PASS \
  || check "V32b a recorder skip exits 0 and names its cause (rc=$POST_SKIP_RC named=$POST_SKIP_NAMED)" FAIL
degraded_quiet "$NOMODP_ROOT" post-browser-navigation-consent.sh "$PROJ/unmarked-post.json" \
  && degraded_quiet "$NOMODP_ROOT" post-browser-navigation-consent.sh "$PROJ/cli-only-post.json" \
  && check "V32c the degraded recorder root stays silent on an unmarked and a CLI-only payload" PASS \
  || check "V32c the degraded recorder root stays silent on an unmarked and a CLI-only payload" FAIL
# AC-008: the recorder is documented as never blocking, and exit 2 from a PostToolUse hook IS
# the blocking status.
POST_MISMATCH_RC=0
POST_MISMATCH_ERR="$(CLAUDE_PLUGIN_ROOT="$PROJ" bash "$POST_HOOK" < "$PROJ/mismatch-post.json" 2>&1 >/dev/null)" || POST_MISMATCH_RC=$?
[ "$POST_MISMATCH_RC" -eq 0 ] \
  && check "V32 the recorder never blocks: an inherited plugin-root mismatch exits 0" PASS \
  || check "V32 the recorder never blocks: an inherited plugin-root mismatch exits 0 (rc=$POST_MISMATCH_RC)" FAIL
case "$POST_MISMATCH_ERR" in *'CLAUDE_PLUGIN_ROOT'*) MISMATCH_SAID=1 ;; *) MISMATCH_SAID=0 ;; esac
[ "$MISMATCH_SAID" -eq 1 ] \
  && check "V32a the non-blocking mismatch still names its cause on stderr" PASS \
  || check "V32a the non-blocking mismatch still names its cause on stderr" FAIL

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
# V34b executes the round trip: the policy template SHIPPED in rules/setup.md is extracted,
# filled with a port and a route, and fed to the run-config helper's own --check-policy.
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
CHECK_POLICY_OUT=""
if [ -n "$RENDERED_POLICY" ]; then
  CHECK_POLICY_OUT="$(ZENSU_VERIFY_NAVIGATION_POLICY_V1="$RENDERED_POLICY" config_helper --check-policy local 'http://127.0.0.1:45173' '/' declared-safe 2>/dev/null)"
fi
[ "$CHECK_POLICY_OUT" = "policy" ] \
  && check "V34b the policy rules/setup.md renders is accepted by the helper it tells the model to run" PASS \
  || check "V34b the policy rules/setup.md renders is accepted by the helper it tells the model to run (got: ${CHECK_POLICY_OUT:-<none>})" FAIL
NEG_RC=0
NEG_ERR=""
if [ -n "$RENDERED_POLICY" ]; then
  NEG_ERR="$(ZENSU_VERIFY_NAVIGATION_POLICY_V1="$RENDERED_POLICY" config_helper --check-policy local 'http://127.0.0.1:45173' '/admin' declared-safe 2>&1 >/dev/null)" || NEG_RC=$?
fi
NOT_POLICY_ROUTE_TEXT="$(node -e 'process.stdout.write(require(process.argv[1]).REASONS.NOT_POLICY_ROUTE)' "$MODULE" 2>/dev/null)"
case "$NEG_RC:$NEG_ERR" in
  1:*"$NOT_POLICY_ROUTE_TEXT"*)
    [ -n "$NOT_POLICY_ROUTE_TEXT" ] \
      && check "V34b-neg an undeclared route is refused against that same rendered policy, for the route" PASS \
      || check "V34b-neg an undeclared route is refused against that same rendered policy (no reason text)" FAIL ;;
  *) check "V34b-neg an undeclared route is refused against that same rendered policy, for the route (rc=$NEG_RC: ${NEG_ERR:-<none>})" FAIL ;;
esac
CONSENT_CHECK_OUT="$(config_helper --check-policy local 'http://127.0.0.1:45173' '/' declared-safe 2>/dev/null)"
[ "$CONSENT_CHECK_OUT" = "consent" ] \
  && check "V34c without a policy the helper reports consent mode" PASS \
  || check "V34c without a policy the helper reports consent mode (got: ${CONSENT_CHECK_OUT:-<none>})" FAIL

if command -v git >/dev/null 2>&1 && { [ -d "$PLUGIN_DIR/.git" ] || [ -f "$PLUGIN_DIR/.git" ]; }; then
  RETIRED_ALLOWED="CHANGELOG.md
docs/gates.md
docs/verify-feature-consent-spec.md
docs/verify-feature.md
tests/structure/test-promptfoo-verify-feature.sh
tests/structure/test-verify-consent.sh
tests/structure/test-verify-feature-skill.sh"
  RETIRED_FOUND="$(cd "$PLUGIN_DIR" && git ls-files -z --cached --others --exclude-standard -- . ":(exclude)CLAUDE.md" ":(exclude).claude/rules" | xargs -0 grep -lF -e 'mcp__plugin_zensu_playwright__' -e 'mcp__plugin_zensu_zensu-browser__' -e 'mcp__zensu-browser__' -e 'playwright-mcp.sh' -e 'playwright-mcp-proxy' -- 2>/dev/null | LC_ALL=C sort -u)"
  if printf '%s\n' "$RETIRED_FOUND" | grep -qxF 'tests/structure/test-verify-consent.sh'; then
    check "V45-control the tree-wide scan reaches this suite, which names every retired literal" PASS
  else
    check "V45-control the tree-wide scan reaches this suite, which names every retired literal" FAIL
  fi
  RETIRED_OUTSIDE=""
  while IFS= read -r _vc_file; do
    [ -n "$_vc_file" ] || continue
    printf '%s\n' "$RETIRED_ALLOWED" | grep -qxF -- "$_vc_file" || RETIRED_OUTSIDE="$RETIRED_OUTSIDE $_vc_file"
  done <<EOF
$RETIRED_FOUND
EOF
  if [ -z "$RETIRED_OUTSIDE" ]; then
    check "V45 no file outside the allowlist names the retired MCP broker" PASS
  else
    check "V45 no file outside the allowlist names the retired MCP broker (outside:$RETIRED_OUTSIDE)" FAIL
  fi
else
  check "V45 tree-wide retired-broker census SKIPPED (no git checkout)" PASS
fi

GATES_FLAT="$(tr '\n' ' ' < "$PLUGIN_DIR/docs/gates.md" | tr -s ' ')"
if printf '%s' "$GATES_FLAT" | grep -qF 'The PostToolUse hook never blocks: every fault, its plugin-root identity guard included, is a stderr note and exit `0`' \
  && ! printf '%s' "$GATES_FLAT" | grep -qF 'the plugin-root identity guard, which refuses with exit 2 before the hook body runs'; then
  check "V46 docs/gates.md says the recorder never blocks, its identity guard included" PASS
else
  check "V46 docs/gates.md says the recorder never blocks, its identity guard included" FAIL
fi
VERIFY_DOC_FLAT="$(tr '\n' ' ' < "$PLUGIN_DIR/docs/verify-feature.md" | tr -s ' ')"
if ! printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'ignores every other Bash call' \
  && printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'a command that merely mentions both markers' \
  && printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'Grep tool'; then
  check "V47 docs/verify-feature.md states the mention-denial cost and its remedy" PASS
else
  check "V47 docs/verify-feature.md states the mention-denial cost and its remedy" FAIL
fi
if printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'That promise holds for an interactive session: how the host resolves the prompt under bypass permissions, in auto mode or in a headless run is unverified, so such a run belongs in policy mode.' \
  && printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'it is required for remote targets and for unattended runs — bypass permissions, auto mode, a headless run —' \
  && printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'Nor is it verified without a person at the prompt: how the host resolves a hook `ask` under bypass permissions, in auto mode or in a headless run was never observed, so run an unattended or bypass session in policy mode, which asks nothing.'; then
  check "V48 docs/verify-feature.md limits the prompt promise to interactive sessions and sends unattended runs to policy mode" PASS
else
  check "V48 docs/verify-feature.md limits the prompt promise to interactive sessions and sends unattended runs to policy mode" FAIL
fi
DRIFT_MISSING=""
for needle in 'The driver is user-supplied: the plugin ships no pin and no integrity check for `playwright-cli`.' \
  'a version the package declares, not a verified binary' \
  '`network.allowedOrigins`, `browser.isolated`, the `--host-resolver-rules` pins, `browser.contextOptions.serviceWorkers`' \
  'so a new environment or config channel of a later CLI is unjudged.'; do
  printf '%s' "$GATES_FLAT" | grep -qF -- "$needle" || DRIFT_MISSING="$DRIFT_MISSING [$needle]"
done
if [ -z "$DRIFT_MISSING" ]; then
  check "V49 docs/gates.md names the version-drift gap: user-supplied driver, manifest-only guard, run-config fences and channels" PASS
else
  check "V49 docs/gates.md names the version-drift gap: user-supplied driver, manifest-only guard, run-config fences and channels (missing:$DRIFT_MISSING)" FAIL
fi
if printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'a shape denial — one that objects only to how the call is spelled — is re-issued once as one plain call with single-quoted literal arguments, and any other denial leaves the affected scenario PARTIAL' \
  && ! printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'the skill reports the affected scenario PARTIAL rather than working around it'; then
  check "V50 docs/verify-feature.md separates a shape denial's one re-issue from a final denial" PASS
else
  check "V50 docs/verify-feature.md separates a shape denial's one re-issue from a final denial" FAIL
fi
if printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'A manifest that names another package or cannot be judged is reported as such, and the binary is not run. Only when no manifest exists at all does the doctor run `playwright-cli --version`, once, with stdin closed and a five-second bound that kills it on every host; the version it prints is reported as self-reported and is never taken as measured, so the run-config helper still refuses to start a run on it.' \
  && ! printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'where `timeout` or `gtimeout` exists' \
  && ! printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'with no time limit otherwise'; then
  check "V51 docs/verify-feature.md describes the doctor's version read as the version module performs it" PASS
else
  check "V51 docs/verify-feature.md describes the doctor's version read as the version module performs it" FAIL
fi
if [ "$(node -e 'process.stdout.write(String(require(process.argv[1]).VERSION_TIMEOUT_MS))' "$VERSION_MODULE" 2>/dev/null)" = "5000" ] \
  && grep -qF "killSignal: 'SIGKILL'" "$VERSION_MODULE" \
  && grep -qF "stdio: ['ignore', fd, 'ignore']" "$VERSION_MODULE"; then
  check "V51-control the version module bounds --version at five seconds with SIGKILL and closes its stdin" PASS
else
  check "V51-control the version module bounds --version at five seconds with SIGKILL and closes its stdin" FAIL
fi
if printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'is a textual gate: it judges a `playwright-cli` call on a `zensu-verify` session before it runs only when the command text names the CLI and that session' \
  && printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'never reaches it, so that call is not judged' \
  && ! printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'judges every `playwright-cli` call on a `zensu-verify` session before it runs'; then
  check "V52 docs/verify-feature.md says the gate judges the command text, not every call" PASS
else
  check "V52 docs/verify-feature.md says the gate judges the command text, not every call" FAIL
fi
CONFIG_DOC_FLAT="$(tr '\n' ' ' < "$PLUGIN_DIR/docs/configuration.md" | tr -s ' ')"
DOLLAR_DRIFT=""
printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'Outside single quotes a `$` counts as an expansion unless whitespace, the end of the command or a closing double quote follows it' \
  || DOLLAR_DRIFT="$DOLLAR_DRIFT docs/verify-feature.md"
printf '%s' "$GATES_FLAT" | grep -qF 'Outside single quotes a `$` counts as an expansion unless whitespace, the end of the command or a closing double quote follows it, so the zsh spellings' \
  || DOLLAR_DRIFT="$DOLLAR_DRIFT docs/gates.md"
printf '%s' "$CONFIG_DOC_FLAT" | grep -qF 'any `$` outside single quotes unless whitespace, the end of the command or a closing double quote follows it' \
  || DOLLAR_DRIFT="$DOLLAR_DRIFT docs/configuration.md"
for _vc_flat in "$VERIFY_DOC_FLAT" "$GATES_FLAT" "$CONFIG_DOC_FLAT"; do
  if printf '%s' "$_vc_flat" | grep -qF -e 'unless whitespace or the end of the command follows it' -e 'that whitespace or the end of the command does not follow'; then
    DOLLAR_DRIFT="$DOLLAR_DRIFT retired-wording"
  fi
done
if [ -z "$DOLLAR_DRIFT" ]; then
  check "V53 the three docs exempt a \$ before a closing double quote from the expansion rule" PASS
else
  check "V53 the three docs exempt a \$ before a closing double quote from the expansion rule (drift in:$DOLLAR_DRIFT)" FAIL
fi
DOLLAR_LEX="$(node -e '
  const lex = require(process.argv[1]).lexShell;
  const q = String.fromCharCode(39);
  const word = (command) => {
    const segments = lex(command).segments;
    return segments.length === 1 && segments[0].length === 2 ? segments[0][1] : null;
  };
  const cases = [
    ["a $ before a closing double quote", "x \"a$\"", false],
    ["a $ before whitespace", "x a$ ", false],
    ["a $ at the end", "x a$", false],
    ["a variable inside double quotes", "x \"$12\"", true],
    ["a $ before a single quote inside double quotes", "x \"a$" + q + "b\"", true],
    ["a variable inside single quotes", "x " + q + "$12" + q, false],
  ];
  const wrong = cases.filter(([, command, unexpanded]) => {
    const found = word(command);
    return !found || found.unexpanded !== unexpanded;
  }).map(([label]) => label);
  process.stdout.write(wrong.length === 0 ? "ok" : wrong.join(", "));
' "$MODULE" 2>&1)"
if [ "$DOLLAR_LEX" = "ok" ]; then
  check "V53-control the lexer keeps a \$ before a closing double quote, whitespace or the end literal, and marks the other spellings unexpanded" PASS
else
  check "V53-control the lexer keeps a \$ before a closing double quote, whitespace or the end literal, and marks the other spellings unexpanded (wrong: ${DOLLAR_LEX:-<none>})" FAIL
fi
TROUBLE_MISSING=""
for needle in '| PARTIAL before any browser call; reason starts `the browser consent gate is not ready (consent hook: …; consent recorder: …)` |' \
  '| PARTIAL before any browser call; reason says `so no run config is written; install the measured version with …` |' \
  'The manifest in the `node_modules/@playwright/cli` directory beside the `playwright-cli` found on `PATH` is read first, so a wrapper script in a directory that holds one naming the measured version is accepted.' \
  'Any other wrapper script outside the package reads as no manifest, whose reason says the binary resolves to no such manifest — unless a `package.json` sits in the directory of its resolved path or one of the three above it' \
  'put the directory npm installs `playwright-cli` into first on `PATH`, ahead of the wrapper — the reason says so only when the wrapper resolves to no manifest, and the `PATH` order has to change either way' \
  '| PARTIAL before any browser call; reason names `an empty PATH entry` or `the relative PATH entry` |' \
  'remove that entry from `PATH`, or move it behind the directory that holds `playwright-cli`'; do
  printf '%s' "$VERIFY_DOC_FLAT" | grep -qF -- "$needle" || TROUBLE_MISSING="$TROUBLE_MISSING [$needle]"
done
if printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'A wrapper script outside the package reads as no manifest'; then
  TROUBLE_MISSING="$TROUBLE_MISSING [unqualified wrapper wording]"
fi
if [ -z "$TROUBLE_MISSING" ]; then
  check "V54 docs/verify-feature.md troubleshoots the run-config helper's registration, version and PATH-entry refusals" PASS
else
  check "V54 docs/verify-feature.md troubleshoots the run-config helper's registration, version and PATH-entry refusals (missing:$TROUBLE_MISSING)" FAIL
fi
HELPER_MISSING=""
for needle in 'the browser consent gate is not ready (consent hook: ${hook}; consent recorder: ${recorder})' \
  'so no run config is written; ' \
  'install the measured version with' \
  'as a wrapper script outside the package does' \
  'put the directory npm installs it into first on PATH, ahead of any wrapper' \
  "'an empty PATH entry'" \
  'the relative PATH entry' \
  'remove that entry from PATH, or move it behind the directory that holds playwright-cli'; do
  grep -qF -- "$needle" "$CONFIG_HELPER" || HELPER_MISSING="$HELPER_MISSING [$needle]"
done
if [ -z "$HELPER_MISSING" ]; then
  check "V54-control the run-config helper still carries every reason the troubleshooting rows quote" PASS
else
  check "V54-control the run-config helper still carries every reason the troubleshooting rows quote (missing:$HELPER_MISSING)" FAIL
fi
if printf '%s' "$GATES_FLAT" | grep -qF 'a CLI named other than by its bare name — a path, another letter case or the package name `@playwright/cli`, where only `playwright-cli` (on Windows also its `.cmd`, `.exe` and `.ps1` names) lets `PATH` resolve the binary `/zensu:doctor` measured' \
  && printf '%s' "$CONFIG_DOC_FLAT" | grep -qF 'a CLI named other than by its bare `playwright-cli` (a path, another letter case or the package name)'; then
  check "V55 docs/gates.md and docs/configuration.md list the bare-name refusal" PASS
else
  check "V55 docs/gates.md and docs/configuration.md list the bare-name refusal" FAIL
fi
BARE_FACTS="$(node -e '
  const consent = require(process.argv[1]);
  const version = require(process.argv[2]);
  const posix = JSON.stringify([...version.binaryNames("linux")]);
  const windows = JSON.stringify([...version.binaryNames("win32")].sort());
  const ok = typeof consent.REASONS.CLI_NOT_BARE === "string"
    && posix === JSON.stringify(["playwright-cli"])
    && windows === JSON.stringify(["playwright-cli", "playwright-cli.cmd", "playwright-cli.exe", "playwright-cli.ps1"]);
  process.stdout.write(ok ? "ok" : "posix=" + posix + " windows=" + windows);
' "$MODULE" "$VERSION_MODULE" 2>&1)"
if [ "$BARE_FACTS" = "ok" ]; then
  check "V55-control the module refuses a non-bare CLI name and the bare set is playwright-cli, plus .cmd, .exe and .ps1 on Windows" PASS
else
  check "V55-control the module refuses a non-bare CLI name and the bare set is playwright-cli, plus .cmd, .exe and .ps1 on Windows (${BARE_FACTS:-<none>})" FAIL
fi
if printf '%s' "$GATES_FLAT" | grep -qF 'While its prefilter library loads, the PreToolUse hook fails closed on a marked call and never touches any other' \
  && printf '%s' "$GATES_FLAT" | grep -qF 'When it cannot be sourced, each hook falls back to a test of its own: a payload that names either marker alone — `playwright` or `zensu-verify`, in any letter case — is treated as marked' \
  && printf '%s' "$GATES_FLAT" | grep -qF 'denies it with `prefilter library unavailable` once the plugin-root check and the `/zensu:doctor` exemption have run'; then
  check "V56 docs/gates.md states the fallback test each hook runs when the prefilter library cannot be sourced" PASS
else
  check "V56 docs/gates.md states the fallback test each hook runs when the prefilter library cannot be sourced" FAIL
fi
NOLIB_ALONE=""
for payload in 'npm view playwright version' 'echo ZENSU-VERIFY'; do
  case "$(nolib_run pre-browser-navigation-consent.sh PreToolUse "$payload" 2>/dev/null)" in
    *'"permissionDecision":"deny"'*'prefilter library unavailable'*) ;;
    *) NOLIB_ALONE="$NOLIB_ALONE [pre: $payload]" ;;
  esac
  NOLIB_RECORDER_ERR="$(nolib_run post-browser-navigation-consent.sh PostToolUse "$payload" 2>&1 >/dev/null)"
  NOLIB_RECORDER_RC=$?
  case "$NOLIB_RECORDER_RC:$NOLIB_RECORDER_ERR" in
    0:*'browser consent memory not written (prefilter library unavailable)'*) ;;
    *) NOLIB_ALONE="$NOLIB_ALONE [post: $payload rc=$NOLIB_RECORDER_RC]" ;;
  esac
done
NOLIB_UNRELATED="$(nolib_run post-browser-navigation-consent.sh PostToolUse 'ls -la' 2>&1)"
NOLIB_UNRELATED_RC=$?
[ "$NOLIB_UNRELATED_RC" -eq 0 ] && [ -z "$NOLIB_UNRELATED" ] || NOLIB_ALONE="$NOLIB_ALONE [post: ls -la rc=$NOLIB_UNRELATED_RC]"
if [ -z "$NOLIB_ALONE" ]; then
  check "V56-control without the prefilter library the gate denies and the recorder skips a payload naming either marker alone, and the recorder stays silent on an unrelated call" PASS
else
  check "V56-control without the prefilter library the gate denies and the recorder skips a payload naming either marker alone, and the recorder stays silent on an unrelated call (wrong:$NOLIB_ALONE)" FAIL
fi
VERSION_GUARD_MISSING=""
for needle in "The one guard is the run-config helper's readiness check, which its \`--check-policy\` preflight and its write run both perform" \
  'The check never runs the binary, so a version the binary would print about itself counts for nothing.' \
  'It reads the `node_modules/@playwright/cli/package.json` beside the `playwright-cli` found on `PATH` first, on every platform, so a wrapper script in a directory that holds that manifest at the measured version passes: the check vouches for the manifest beside the wrapper, not for what the wrapper runs, nor for a function or alias named `playwright-cli` that the shell already has.' \
  'The check runs only when the helper runs: the gate judges `open` by the shape of the run config it names and never reads the installed version, so a run config of that shape written another way, or a `playwright-cli` installed or put ahead on `PATH` after the helper ran, runs unmeasured.' \
  'Any other wrapper script outside the package fails it' \
  'with no `package.json` in the directory of its resolved path or the three above it, it resolves to no manifest, and the refusal adds the remedy of putting the directory npm installs `playwright-cli` into first on `PATH`' \
  'when a `package.json` sits there, that manifest answers instead — as another package, or as one the check cannot judge — and the refusal names only the install command, though the `PATH` order still has to change' \
  'A `PATH` whose empty or relative entry comes before or holds `playwright-cli` is refused too'; do
  printf '%s' "$GATES_FLAT" | grep -qF -- "$needle" || VERSION_GUARD_MISSING="$VERSION_GUARD_MISSING [$needle]"
done
for retired in 'a wrapper script outside the package resolves to no manifest and is refused' 'A wrapper script outside the package therefore fails it'; do
  if printf '%s' "$GATES_FLAT" | grep -qF -- "$retired"; then
    VERSION_GUARD_MISSING="$VERSION_GUARD_MISSING [retired: $retired]"
  fi
done
if [ -z "$VERSION_GUARD_MISSING" ]; then
  check "V57 docs/gates.md says both helper entry points run the readiness check, never run the binary, and how a wrapper script and a cwd-relative PATH entry are refused" PASS
else
  check "V57 docs/gates.md says both helper entry points run the readiness check, never run the binary, and how a wrapper script and a cwd-relative PATH entry are refused (missing:$VERSION_GUARD_MISSING)" FAIL
fi
if printf '%s' "$GATES_FLAT" | grep -qF 'its `verify-feature` row checks that both hooks, the prefilter library, the decision module and the run-config helper exist, that the module is no symlink and loads, that the helper loads' \
  && printf '%s' "$GATES_FLAT" | grep -qF 'follow the host'"'"'s own matcher rule as read out of the Claude Code 2.1.280 binary, and report a matcher the host may read two ways as undetermined, never as missing' \
  && grep -qF 'hooks/lib/zensu-browser-consent-prefilter.sh' "$PLUGIN_DIR/hooks/lib/zensu-doctor.sh" \
  && grep -qF 'require("./scripts/verify-browser-config.js")' "$PLUGIN_DIR/hooks/lib/zensu-doctor.sh"; then
  check "V58 docs/gates.md names the doctor's availability checks and the host build the registration probes follow" PASS
else
  check "V58 docs/gates.md names the doctor's availability checks and the host build the registration probes follow" FAIL
fi
SPEC_DOC_FLAT="$(tr '\n' ' ' < "$PLUGIN_DIR/docs/verify-feature-consent-spec.md" | tr -s ' ')"
if printf '%s' "$GATES_FLAT" | grep -qF 'The gate is textual: they judge a `playwright-cli` call on a `zensu-verify-*` session' \
  && printf '%s' "$GATES_FLAT" | grep -qF 'when its command text names the CLI and that session, or names the CLI while the hook environment'"'"'s `PLAYWRIGHT_CLI_SESSION` names one, and while their prefilter library loads they stay out of every other Bash call' \
  && printf '%s' "$SPEC_DOC_FLAT" | grep -qF 'where it judges a `playwright-cli` call on a `zensu-verify-*` session whose command text names the CLI and the session — a textual gate —' \
  && ! printf '%s' "$GATES_FLAT" | grep -qF 'They judge every `playwright-cli` call whose session is a `zensu-verify-*` name' \
  && ! printf '%s' "$SPEC_DOC_FLAT" | grep -qF 'where it judges every `playwright-cli` call on a `zensu-verify-*` session'; then
  check "V59 docs/gates.md and the consent spec say the gate judges the command text, not every call" PASS
else
  check "V59 docs/gates.md and the consent spec say the gate judges the command text, not every call" FAIL
fi
if printf '%s' "$CONFIG_DOC_FLAT" | grep -qF 'When `hooks/lib/zensu-browser-consent-prefilter.sh` cannot be sourced it falls back to a test of its own over the whole hook payload, not only the command, and **denies** every payload that names `playwright` or `zensu-verify` in any letter case with `prefilter library unavailable`, the recognized `/zensu:doctor` and adoption commands excepted — in a project whose working directory names either word, that is every Bash call.' \
  && printf '%s' "$CONFIG_DOC_FLAT" | grep -qF 'Without the prefilter library it skips every payload that names `playwright` or `zensu-verify`, with `prefilter library unavailable`.'; then
  check "V60 both consent hook rows in docs/configuration.md state the prefilter-library fallback" PASS
else
  check "V60 both consent hook rows in docs/configuration.md state the prefilter-library fallback" FAIL
fi
if printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'Before it judges the target it runs the readiness check of the run-config helper: both consent hooks must be registered on a matcher that covers `Bash`, the `@playwright/cli` manifest of the `playwright-cli` on the `PATH` of the caller must name the measured version, and no empty or relative `PATH` entry may come before or hold that `playwright-cli`, so a run from a terminal judges the `PATH` of that terminal.' \
  && ! printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'both consent hooks must be registered on a matcher that covers `Bash`, and the `@playwright/cli` manifest' \
  && printf '%s' "$VERIFY_DOC_FLAT" | grep -qF '| `the browser consent gate is not ready (…)`, or a reason that says `so no run config is written` | the readiness check failed before the target was judged; section 5 names each cause and its fix |'; then
  check "V61 the preflight section of docs/verify-feature.md names the readiness check that runs before the target is judged" PASS
else
  check "V61 the preflight section of docs/verify-feature.md names the readiness check that runs before the target is judged" FAIL
fi
if printf '%s' "$GATES_FLAT" | grep -qF 'That test reads the whole hook payload, not only the command, so in a project whose working directory names either word every Bash call is denied until the library is restored, the recognized `/zensu:doctor` and adoption commands excepted; a call whose payload names neither word still passes silently.'; then
  check "V62 docs/gates.md says the prefilter-library fallback reads the whole payload, working directory included" PASS
else
  check "V62 docs/gates.md says the prefilter-library fallback reads the whole payload, working directory included" FAIL
fi
case "$(bash_payload PreToolUse 'ls -la' "$SID" "$PROJ/Playwright-demo" | CLAUDE_PLUGIN_ROOT="$NOLIB_ROOT" bash "$NOLIB_ROOT/hooks/pre-browser-navigation-consent.sh" 2>/dev/null)" in
  *'"permissionDecision":"deny"'*'prefilter library unavailable'*) check "V62-control without the prefilter library an unrelated call is denied when the working directory names playwright" PASS ;;
  *) check "V62-control without the prefilter library an unrelated call is denied when the working directory names playwright" FAIL ;;
esac
TEXTUAL_MISSING=""
for needle in 'A CLI name assembled at run time — an expansion inside `playwright-cli`, even one set or left empty in the same command, an ANSI-C escape inside the name such as `$'"'"'playwright\x2dcli'"'"'`, a script file, an alias under another name — never reaches it, so that call is not judged, and the literal-spelling and one-plain-call rules below never apply to it; `$'"'"'playwright-cli'"'"'`, which holds the plain name, still names the CLI to it, so a call on a `zensu-verify` session spelled that way is judged and denied as not one plain call.' \
  'A session name assembled at run time — a variable, a substitution, an ANSI-C escape or an expansion inside the `zensu-verify-` prefix — hides the call the same way, unless the hook environment'"'"'s `PLAYWRIGHT_CLI_SESSION` names a `zensu-verify-` session: then a call that spells `playwright-cli` literally is judged whatever its session, and a session that is not literal is denied.' \
  'A function or alias named `playwright-cli` that the shell already has, such as one from a startup file, is judged as the plain call its text shows, and the gate cannot see what it runs, so the denials below bind only what the command text spells.' \
  'While its prefilter library loads, the gate reaches no decision for a call on any other session whose command text names no `zensu-verify-` session' \
  '| a Bash call is denied with `Zensu browser consent gate denied the playwright-cli call:` and the reason `prefilter library unavailable`, `node unavailable`, `decision module absent or symlinked` or `decision module failed` |' \
  'Without its prefilter library the hook denies every Bash call whose payload names `playwright` or `zensu-verify`, not only browser calls; in a project whose path names either word that is every Bash call except the recognized `/zensu:doctor` and adoption commands on a POSIX host with `node`' \
  'run `/zensu:doctor` and reinstall the plugin even when its `verify-feature` row reads ready: that row names a missing prefilter library and a missing, symlinked or unloadable decision module, but it tests the library for existence only, cannot see a module that loads and then fails, and looks for `node` on the `PATH` of its own shell, stopping before that row when it finds none; for `node unavailable`, put `node` on the `PATH` of the environment that launches Claude Code'; do
  printf '%s' "$VERIFY_DOC_FLAT" | grep -qF -- "$needle" || TEXTUAL_MISSING="$TEXTUAL_MISSING [$needle]"
done
for retired in 'a variable an earlier call set' 'run `/zensu:doctor`, whose `verify-feature` row names the cause, and reinstall the plugin; for `node unavailable`' 'A name assembled at run time — an expansion inside' 'An expansion inside the `zensu-verify-` prefix hides the session the same way' 'an ANSI-C `$'"'"'…'"'"'` escape, a script file, an alias' 'a substitution, an ANSI-C escape, an expansion inside'; do
  if printf '%s' "$VERIFY_DOC_FLAT" | grep -qF -- "$retired"; then
    TEXTUAL_MISSING="$TEXTUAL_MISSING [retired: $retired]"
  fi
done
if [ -z "$TEXTUAL_MISSING" ]; then
  check "V63 docs/verify-feature.md names an expansion inside either name as unjudged and troubleshoots the gate's plugin-integrity denials" PASS
else
  check "V63 docs/verify-feature.md names an expansion inside either name as unjudged and troubleshoots the gate's plugin-integrity denials (missing:$TEXTUAL_MISSING)" FAIL
fi
RESIDUAL_MISSING=""
for needle in 'an expansion inside `playwright-cli` or inside the `zensu-verify-` prefix, even one set or left empty in the same command, an ANSI-C escape inside a name, such as `$'"'"'playwright\x2dcli'"'"'`, a script file that makes the call' \
  '`$'"'"'playwright-cli'"'"'`, which holds the plain name, still names the CLI, so a call on a `zensu-verify` session spelled that way is judged and denied as not one plain call.' \
  'While the hook environment'"'"'s `PLAYWRIGHT_CLI_SESSION` names a `zensu-verify-` session, a call that spells `playwright-cli` literally is marked whatever its session, so a session assembled at run time — a variable, a substitution, an ANSI-C escape or an expansion inside the prefix — is denied as not literal; only a CLI name assembled at run time stays unseen.' \
  'The single-call and literal-argument rules bind only a call the gate judges, so they do not narrow this and do not make the gate a boundary.' \
  'A function or alias named `playwright-cli` that the shell already has, such as one from a startup file, is judged as the plain call its text shows, and neither hook can see what it runs.'; do
  printf '%s' "$GATES_FLAT" | grep -qF -- "$needle" || RESIDUAL_MISSING="$RESIDUAL_MISSING [$needle]"
done
for retired in 'The single-call rule narrows what can be written inline' 'The one exception is an expansion inside the prefix' 'an ANSI-C `$'"'"'…'"'"'` escape, a script file that makes the call'; do
  if printf '%s' "$GATES_FLAT" | grep -qF -- "$retired"; then
    RESIDUAL_MISSING="$RESIDUAL_MISSING [retired: $retired]"
  fi
done
if [ -z "$RESIDUAL_MISSING" ]; then
  check "V64 docs/gates.md says an expansion inside either name goes unjudged and the single-call rule does not narrow that" PASS
else
  check "V64 docs/gates.md says an expansion inside either name goes unjudged and the single-call rule does not narrow that (missing:$RESIDUAL_MISSING)" FAIL
fi
EXPANSION_REASON="$(PLAYWRIGHT_CLI_SESSION="$SESSION" pre_reason 'playwright-cli -s=zensu-ver${Z}ify-vc eval 1' "$SID" "$PROJ")"
VARIABLE_REASON="$(PLAYWRIGHT_CLI_SESSION="$SESSION" pre_reason 'playwright-cli -s=$S eval 1' "$SID" "$PROJ")"
if [ "$(pre_verdict 'Z=; playwright-cl${Z}i -s='"$SESSION"' eval 1' "$SID" "$PROJ")" = "NONE" ] \
  && [ "$(pre_verdict 'playwright-cli -s=zensu-ver${Z}ify-vc eval 1' "$SID" "$PROJ")" = "NONE" ] \
  && [ "$(pre_verdict 'playwright-cli -s=$S eval 1' "$SID" "$PROJ")" = "NONE" ] \
  && [ "$(PLAYWRIGHT_CLI_SESSION="$SESSION" pre_verdict 'playwright-cli -s=zensu-ver${Z}ify-vc eval 1' "$SID" "$PROJ")" = "DENY" ] \
  && printf '%s' "$EXPANSION_REASON" | grep -qF 'must name its session literally' \
  && [ "$(PLAYWRIGHT_CLI_SESSION="$SESSION" pre_verdict 'playwright-cli -s=$S eval 1' "$SID" "$PROJ")" = "DENY" ] \
  && printf '%s' "$VARIABLE_REASON" | grep -qF 'must name its session literally' \
  && printf '%s' "$(PLAYWRIGHT_CLI_SESSION="$SESSION" pre_reason 'playwright-cli -s=$(cat s) eval 1' "$SID" "$PROJ")" | grep -qF 'must name its session literally' \
  && printf '%s' "$(PLAYWRIGHT_CLI_SESSION="$SESSION" pre_reason 'playwright-cli -s=$'"'"'\x7a'"'"'ensu-verify-vc eval 1' "$SID" "$PROJ")" | grep -qF 'must name its session literally' \
  && [ "$(PLAYWRIGHT_CLI_SESSION="$SESSION" pre_verdict 'Z=; playwright-cl${Z}i -s=$S eval 1' "$SID" "$PROJ")" = "NONE" ] \
  && [ "$(pre_verdict '$'"'"'playwright\x2dcli'"'"' -s='"$SESSION"' eval 1' "$SID" "$PROJ")" = "NONE" ] \
  && printf '%s' "$(pre_reason '$'"'"'playwright-cli'"'"' -s='"$SESSION"' eval 1' "$SID" "$PROJ")" | grep -qF 'must be exactly one plain playwright-cli call'; then
  check "V64-control a name assembled at run time reaches no decision, and while the hook environment names a zensu-verify session a literal playwright-cli call with a non-literal session is denied" PASS
else
  check "V64-control a name assembled at run time reaches no decision, and while the hook environment names a zensu-verify session a literal playwright-cli call with a non-literal session is denied" FAIL
fi
VERSION_MEMBERS="$(grep -oE 'cliVersion\.[A-Za-z_]+' "$MODULE" | LC_ALL=C sort -u | tr '\n' ' ')"
if [ "$VERSION_MEMBERS" = "cliVersion.BINARY_NAMES cliVersion.PACKAGE_NAME cliVersion.binaryNames " ] \
  && [ "$(grep -o 'cliVersion' "$MODULE" | wc -l | tr -d ' ')" = "4" ] \
  && [ "$(grep -c 'playwright-cli-version' "$MODULE")" = "1" ] \
  && grep -qF "const cliVersion = require('./playwright-cli-version-v1.js');" "$MODULE" \
  && ! grep -q 'playwright-cli-version' "$PRE_HOOK" "$POST_HOOK" "$PREFILTER_LIB"; then
  check "V67 the consent module takes only BINARY_NAMES, PACKAGE_NAME and binaryNames from the version module, so the gate never reads the installed version" PASS
else
  check "V67 the consent module takes only BINARY_NAMES, PACKAGE_NAME and binaryNames from the version module, so the gate never reads the installed version (members:$VERSION_MEMBERS)" FAIL
fi
HOOK_DENY_MISSING=""
for literal in 'Zensu browser consent gate denied the playwright-cli call: %s' 'deny "prefilter library unavailable"' 'deny "node unavailable"' 'deny "decision module absent or symlinked"' 'deny "decision module failed"'; do
  grep -qF -- "$literal" "$PRE_HOOK" || HOOK_DENY_MISSING="$HOOK_DENY_MISSING [$literal]"
done
if [ -z "$HOOK_DENY_MISSING" ]; then
  check "V63-control the pre hook still prints the deny prefix and the four plugin-integrity reasons the troubleshooting row quotes" PASS
else
  check "V63-control the pre hook still prints the deny prefix and the four plugin-integrity reasons the troubleshooting row quotes (missing:$HOOK_DENY_MISSING)" FAIL
fi
OPS_DOC_FLAT="$(tr '\n' ' ' < "$PLUGIN_DIR/docs/operations.md" | tr -s ' ')"
if printf '%s' "$OPS_DOC_FLAT" | grep -qF '`the browser consent gate is not ready (…)`, a reason ending in `so no run config is written; …`' \
  && printf '%s' "$OPS_DOC_FLAT" | grep -qF 'The run-config helper also refuses, in its preflight and before it writes a run config, unless both consent hooks are registered, the `@playwright/cli` manifest of that `playwright-cli` names that version and no empty or relative `PATH` entry comes before or holds it; for those refusals run `/zensu:doctor` and follow section 5 of [Verify a feature live](verify-feature.md).'; then
  check "V65 the docs/operations.md troubleshooting row names the run-config helper's readiness refusals" PASS
else
  check "V65 the docs/operations.md troubleshooting row names the run-config helper's readiness refusals" FAIL
fi
FALLBACK_GAP_MISSING=""
printf '%s' "$GATES_FLAT" | grep -qF 'Unlike the library, that test drops the JSON escapes `\n`, `\r` and `\t` without first pairing escaped backslashes, so a gated call can name neither word to it: `playw\right-cli -s=ze\nsu-verify-x eval 1`, which bash runs as `playwright-cli -s=zensu-verify-x eval 1`, passes unjudged until the library is restored, and so does a call that splits only `playwright-cli` that way while the hook environment'"'"'s `PLAYWRIGHT_CLI_SESSION` names a `zensu-verify-` session.' || FALLBACK_GAP_MISSING="$FALLBACK_GAP_MISSING [gates.md fallback gap]"
printf '%s' "$CONFIG_DOC_FLAT" | grep -qF 'That test drops the JSON escapes `\n`, `\r` and `\t` without first pairing escaped backslashes, so a call that splits each word with a backslash before `n`, `r` or `t`, such as `playw\right-cli -s=ze\nsu-verify-x`, escapes it and runs unjudged, and so does a split `playwright-cli` alone while the hook environment'"'"'s `PLAYWRIGHT_CLI_SESSION` names a `zensu-verify-` session.' || FALLBACK_GAP_MISSING="$FALLBACK_GAP_MISSING [configuration.md fallback gap]"
if printf '%s' "$GATES_FLAT" | grep -qF 'a broader test that still fails closed'; then
  FALLBACK_GAP_MISSING="$FALLBACK_GAP_MISSING [retired: a broader test that still fails closed]"
fi
if printf '%s' "$CONFIG_DOC_FLAT" | grep -qF 'falls back to a broader test'; then
  FALLBACK_GAP_MISSING="$FALLBACK_GAP_MISSING [retired: falls back to a broader test]"
fi
if printf '%s' "$GATES_FLAT" | grep -qF 'The PreToolUse hook fails closed on a marked call and, while its prefilter library loads, never touches any other'; then
  FALLBACK_GAP_MISSING="$FALLBACK_GAP_MISSING [retired: an unconditional fail-closed claim]"
fi
if [ -z "$FALLBACK_GAP_MISSING" ]; then
  check "V68 docs/gates.md and docs/configuration.md name the backslash spelling the library-unavailable fallback misses" PASS
else
  check "V68 docs/gates.md and docs/configuration.md name the backslash spelling the library-unavailable fallback misses (missing:$FALLBACK_GAP_MISSING)" FAIL
fi
OTHER_SESSION_MISSING=""
printf '%s' "$GATES_FLAT" | grep -qF 'such a call reaches no decision only when all of these hold: the command parses and stays within the 256 KiB size bound; it holds no operator (`;`, `&`, `&&`, `|`, `||`, `|&`, parentheses), no command on a further line, and no `$(…)`, `${…}`, `$((…))`, backtick or process-substitution body, heredoc, here-string or non-literal redirection target anywhere;' || OTHER_SESSION_MISSING="$OTHER_SESSION_MISSING [docs/gates.md shape conditions]"
printf '%s' "$GATES_FLAT" | grep -qF 'its one `playwright-cli` stands in command position, directly or behind a package launcher or a wrapper the gate knows (`env`, `sudo`, `doas`, `timeout`, `gtimeout`, `nohup`, `time`, `nice`, `exec`, `command`, `builtin`); the call gives at most one session argument and the command at most one `PLAYWRIGHT_CLI_SESSION` assignment; the session and every argument are literal and parse; and the command defines no `playwright-cli` function, uses no environment builtin and names no `PLAYWRIGHT_MCP_*` or `PWTEST_*` variable.' || OTHER_SESSION_MISSING="$OTHER_SESSION_MISSING [docs/gates.md call conditions]"
for doc in docs/verify-feature.md docs/configuration.md; do
  DOC_FLAT="$(tr '\n' ' ' < "$PLUGIN_DIR/$doc" | tr -s ' ')"
  printf '%s' "$DOC_FLAT" | grep -qF 'reaches no decision only when the command meets every condition that [Browser Consent Gate](gates.md#browser-consent-gate) lists for it' || OTHER_SESSION_MISSING="$OTHER_SESSION_MISSING [$doc pointer]"
done
for doc in docs/verify-feature.md docs/gates.md docs/configuration.md; do
  DOC_FLAT="$(tr '\n' ' ' < "$PLUGIN_DIR/$doc" | tr -s ' ')"
  printf '%s' "$DOC_FLAT" | grep -qiF 'every other command that names the CLI, a mere mention included, is denied' || OTHER_SESSION_MISSING="$OTHER_SESSION_MISSING [$doc mere mention]"
  printf '%s' "$DOC_FLAT" | grep -qiF 'a known wrapper, a package launcher, a CLI path or an environment assignment is refused only on a `zensu-verify` session' || OTHER_SESSION_MISSING="$OTHER_SESSION_MISSING [$doc zensu-verify-only refusals]"
  for retired in 'reaches no decision only as one plain call that names its session once' 'reaches no decision only when the command is one `playwright-cli` call that parses'; do
    if printf '%s' "$DOC_FLAT" | grep -qF -- "$retired"; then
      OTHER_SESSION_MISSING="$OTHER_SESSION_MISSING [$doc retired: $retired]"
    fi
  done
done
if [ -z "$OTHER_SESSION_MISSING" ]; then
  check "V69 the three docs list what lets a call on another session reach no decision while the hook environment names a zensu-verify session" PASS
else
  check "V69 the three docs list what lets a call on another session reach no decision while the hook environment names a zensu-verify session (missing:$OTHER_SESSION_MISSING)" FAIL
fi
OTHER_SESSION_WRONG=""
for command in 'playwright-cli -s=other-vc eval 1' 'timeout 5 playwright-cli -s=other-vc eval 1' 'sudo playwright-cli -s=other-vc eval 1' 'npx @playwright/cli -s=other-vc eval 1' '/usr/local/bin/playwright-cli -s=other-vc eval 1' 'FOO=1 playwright-cli -s=other-vc eval 1' 'PLAYWRIGHT_CLI_SESSION=a playwright-cli -s=other-vc eval 1' 'playwright-cli -s=other-vc fill e1 playwright-cli'; do
  [ "$(PLAYWRIGHT_CLI_SESSION="$SESSION" pre_verdict "$command" "$SID" "$PROJ")" = "NONE" ] || OTHER_SESSION_WRONG="$OTHER_SESSION_WRONG [not NONE: $command]"
done
for command in 'playwright-cli -s=other-vc eval 1; echo hi' 'playwright-cli -s=other-vc eval 1 &' 'timeout ${T} playwright-cli -s=other-vc eval 1' 'stdbuf -oL playwright-cli -s=other-vc eval 1' 'playwright-cli -s=other-vc open --headed=yes' 'export A=1 && playwright-cli -s=other-vc eval 1' 'playwright-cli() { :; }; playwright-cli -s=other-vc eval 1' 'playwright-cli -s=other-vc eval $X' 'PWTEST_X=1 playwright-cli -s=other-vc eval 1' 'echo 1 | xargs playwright-cli -s=other-vc eval' 'grep -r playwright-cli docs'; do
  [ "$(PLAYWRIGHT_CLI_SESSION="$SESSION" pre_verdict "$command" "$SID" "$PROJ")" = "DENY" ] || OTHER_SESSION_WRONG="$OTHER_SESSION_WRONG [not DENY: $command]"
done
if [ -z "$OTHER_SESSION_WRONG" ]; then
  check "V69-control while the hook environment names a zensu-verify session, a known wrapper, launcher, path, assignment, a second session spelling or a CLI word among the call's arguments on another session reaches no decision, and a second command, trailing operator, expansion body, unknown wrapper, parse fault, environment builtin, function, expansion, ambient name, indirection or mere mention is denied" PASS
else
  check "V69-control while the hook environment names a zensu-verify session, a known wrapper, launcher, path, assignment, a second session spelling or a CLI word among the call's arguments on another session reaches no decision, and a second command, trailing operator, expansion body, unknown wrapper, parse fault, environment builtin, function, expansion, ambient name, indirection or mere mention is denied (wrong:$OTHER_SESSION_WRONG)" FAIL
fi
SHELL_STATE_MISSING=""
printf '%s' "$CONFIG_DOC_FLAT" | grep -qF 'a `playwright-cli` function the command defines, in any letter case' || SHELL_STATE_MISSING="$SHELL_STATE_MISSING [configuration.md function]"
printf '%s' "$GATES_FLAT" | grep -qF 'a function named `playwright-cli`, in any letter case, that the command defines' || SHELL_STATE_MISSING="$SHELL_STATE_MISSING [gates.md function]"
printf '%s' "$GATES_FLAT" | grep -qF 'lets `PATH` resolve the binary `/zensu:doctor` measured, unless the shell already has a function or alias of that name, which neither hook can see' || SHELL_STATE_MISSING="$SHELL_STATE_MISSING [gates.md bare name]"
printf '%s' "$VERIFY_DOC_FLAT" | grep -qF 'and the run-config helper refuses to write a run config for any other. The gate itself never reads the installed version, so a `playwright-cli` installed or put ahead on `PATH` after the helper ran goes unmeasured, and so does a run whose run config of the right shape was written another way. The check reads the version the package manifest declares, which vouches neither for what a wrapper script runs nor for a function or alias named `playwright-cli` that the shell already has.' || SHELL_STATE_MISSING="$SHELL_STATE_MISSING [verify-feature.md install note]"
for retired in 'refuses to start a run on any other' 'a `playwright-cli` function in any letter case'; do
  if printf '%s' "$VERIFY_DOC_FLAT $CONFIG_DOC_FLAT" | grep -qF -- "$retired"; then
    SHELL_STATE_MISSING="$SHELL_STATE_MISSING [retired: $retired]"
  fi
done
if [ -z "$SHELL_STATE_MISSING" ]; then
  check "V66 the docs say a function is denied only when the command defines it, and the version is checked only when the helper runs" PASS
else
  check "V66 the docs say a function is denied only when the command defines it, and the version is checked only when the helper runs (missing:$SHELL_STATE_MISSING)" FAIL
fi

echo "----"
echo "test-verify-consent: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
