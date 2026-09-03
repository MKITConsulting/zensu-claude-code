#!/bin/bash
set -u

# Structure + functional test for /zensu:doctor read-only diagnostics.
# Structure pins: helper .sh (+ shebang), report .js, skill frontmatter,
# plugin.json skills[] registration, README Diagnostics section, bundled
# Playwright MCP detection. Functional
# (sandbox, node required): zensu-doctor-report.js renders a four-block table
# and ALWAYS exits 0 while correctly flagging version mismatch (❌), hooks
# wired-but-missing (❌) + disk-but-unwired (⚠️), the quoted-boolean config
# trap (⚠️, real booleans NOT flagged), validated CAS workflow documents (✅),
# malformed workflow integers (❌ / fail closed), and an expired pending-review
# marker (⚠️) vs a fresh one (✅); all-green fixture is all ✅. Read-only
# throughout.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN_DIR/hooks/lib/zensu-doctor.sh"
REPORT="$PLUGIN_DIR/hooks/lib/zensu-doctor-report.js"
SKILL_MD="$PLUGIN_DIR/skills/doctor/SKILL.md"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
README="$PLUGIN_DIR/README.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$HELPER" "$REPORT" "$SKILL_MD" "$PLUGIN_JSON" "$README"; do
  if [ ! -f "$f" ]; then
    check "P0 required file exists: $f" FAIL
    echo "----"
    echo "test-doctor: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "P0 all target files exist" PASS

# P2 — structure/doc pins (no node needed)
if head -1 "$HELPER" | grep -qF '#!/bin/bash'; then
  check "P2a helper carries a bash shebang" PASS
else
  check "P2a helper carries a bash shebang" FAIL
fi
if grep -qF 'zensu-doctor-report.js' "$HELPER"; then
  check "P2b helper delegates to the report renderer" PASS
else
  check "P2b helper delegates to the report renderer" FAIL
fi
if grep -qE '^name: doctor$' "$SKILL_MD"; then
  check "P2c skill frontmatter name is doctor" PASS
else
  check "P2c skill frontmatter name is doctor" FAIL
fi
# The root preflight moved OUT of the skill and INTO the helper, so the skill can
# emit one command that zensu-doctor-invocation.js recognizes. Both halves are
# pinned: the skill still names the standardized failure (as the fallback for a
# root so broken the helper cannot start), and the helper now carries it too.
if grep -qF 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-doctor.sh"' "$SKILL_MD" \
  && grep -qF 'CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR}" bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-doctor.sh"' "$SKILL_MD" \
  && grep -qF 'Session Control: plugin root unavailable or invalid — start a fresh Claude Code session' "$SKILL_MD" \
  && grep -qF 'Session Control: plugin root unavailable or invalid — start a fresh Claude Code session' "$HELPER" \
  && ! grep -qF 'ZENSU_CLAUDE_PLUGIN_ROOT' "$SKILL_MD"; then
  check "P2d skill validates root and renders the standardized doctor failure instead of shell-aborting" PASS
else
  check "P2d skill validates root and renders the standardized doctor failure instead of shell-aborting" FAIL
fi
# The coupling that breaks SILENTLY: the skill's command is only useful on a
# failed bind if the recognizer accepts it. Feed every fenced command the skill
# documents through the real recognizer, with the tokens Claude renders natively
# substituted, so an edit to either side that parts them fails here.
DOCTOR_RECOGNIZER="$PLUGIN_DIR/hooks/lib/zensu-doctor-invocation.js"
SKILL_CMDS="$(grep -F 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-doctor.sh"' "$SKILL_MD" | grep -v '^#')"
RECOGNIZED=0
UNRECOGNIZED=0
while IFS= read -r RAW_CMD; do
  [ -n "$RAW_CMD" ] || continue
  RENDERED="${RAW_CMD//\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN_DIR}"
  RENDERED="${RENDERED//\$\{CLAUDE_PLUGIN_DATA\}//tmp/zensu-doctor-probe-data}"
  RENDERED="${RENDERED//\$\{CLAUDE_PROJECT_DIR\}//tmp/zensu-doctor-probe-project}"
  if CMD="$RENDERED" node -e '
      process.stdout.write(JSON.stringify({
        hook_event_name: "PreToolUse",
        session_id: "doctor-skill-probe",
        tool_name: "Bash",
        tool_input: {command: process.env.CMD},
      }));
    ' | node "$DOCTOR_RECOGNIZER" >/dev/null 2>&1; then
    RECOGNIZED=$((RECOGNIZED + 1))
  else
    UNRECOGNIZED=$((UNRECOGNIZED + 1))
  fi
done <<EOF
$SKILL_CMDS
EOF
if [ "$RECOGNIZED" -ge 2 ] && [ "$UNRECOGNIZED" -eq 0 ]; then
  check "P2d1 every doctor command the skill documents is accepted by the recognizer ($RECOGNIZED forms)" PASS
else
  check "P2d1 skill documents a doctor command the recognizer refuses ($RECOGNIZED ok, $UNRECOGNIZED refused)" FAIL
fi
if grep -qF 'AskUserQuestion' "$SKILL_MD" && grep -qiF 'report-only' "$SKILL_MD"; then
  check "P2e skill gates cleanup (AskUserQuestion + report-only non-interactive)" PASS
else
  check "P2e skill gates cleanup (AskUserQuestion + report-only non-interactive)" FAIL
fi
if grep -qF '"./skills/doctor"' "$PLUGIN_JSON"; then
  check "P2f plugin.json skills[] registers ./skills/doctor" PASS
else
  check "P2f plugin.json skills[] registers ./skills/doctor" FAIL
fi
if grep -qF '### Diagnostics — `/zensu:doctor`' "$README"; then
  check "P2g README carries the Diagnostics section" PASS
else
  check "P2g README carries the Diagnostics section" FAIL
fi
# the doctor row must NOT live inside the curated Skills table (count-sync stays)
SKILLS_BLOCK="$(awk '/^### Skills \(/{f=1;next} /^### /{f=0} f' "$README")"
if printf '%s' "$SKILLS_BLOCK" | grep -qF '/zensu:doctor'; then
  check "P2h doctor kept out of the curated Skills table (count-sync unaffected)" FAIL
else
  check "P2h doctor kept out of the curated Skills table (count-sync unaffected)" PASS
fi
if grep -qF 'playwright_mcp_declared' "$HELPER" && grep -qF 'ZDOC_PLAYWRIGHT=configured' "$HELPER" && grep -qF 'command -v npm' "$HELPER"; then
  check "P2i helper validates integrity-locked Playwright MCP without executing npm" PASS
else
  check "P2i helper validates integrity-locked Playwright MCP without executing npm" FAIL
fi
if grep -qF 'Playwright MCP: valid integrity-locked plugin config + npm present' "$REPORT"; then
  check "P2j report distinguishes configured from runtime-ready Playwright MCP" PASS
else
  check "P2j report distinguishes configured from runtime-ready Playwright MCP" FAIL
fi
HOOK_ARGS_READER="$(
  find "$PLUGIN_DIR/hooks" "$PLUGIN_DIR/evals" "$PLUGIN_DIR/tests" -type f \
    \( -name '*.sh' -o -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.ts' \) \
    ! -path '*/node_modules/*' ! -path '*/results/*' -print \
    | while IFS= read -r reader; do
        if [ "$reader" != "$PLUGIN_DIR/tests/structure/test-doctor.sh" ] \
          && grep -qF 'hooks.json' "$reader" \
          && grep -qE '\.command([^[:alnum:]_]|$)' "$reader" \
          && grep -qE '\.args([^[:alnum:]_]|$)' "$reader"; then
          printf '%s\n' "${reader#$PLUGIN_DIR/}"
          break
        fi
      done
)"
if [ -z "$HOOK_ARGS_READER" ]; then
  check "P2n all hook-manifest readers parse only the documented command field" PASS
else
  check "P2n undocumented hook args tolerance remains in $HOOK_ARGS_READER" FAIL
fi

# This one runs BEFORE the sandbox exists, so it carries its own dead HOME rather
# than the exported one below. Without it this invocation opens the running
# developer's real ~/.claude/settings.json through the reviewer-spawn permission
# check, which is the whole thing the export exists to prevent.
REAL_MANIFEST="$(ZDOC_ZENSU=absent ZDOC_NODE=vTEST ZDOC_FORGE_PROVIDER=unknown ZDOC_FORGE_CLI='' ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$PLUGIN_DIR" ZENSU_CONFIG="$PLUGIN_DIR/.no-such-doctor-config" CLAUDE_PROJECT_DIR="$PLUGIN_DIR/.no-such-doctor-project" \
  HOME="$PLUGIN_DIR/.no-such-doctor-home" \
  node "$REPORT" 2>/dev/null)"
EXPECTED_HOOKS=0
for hook_script in "$PLUGIN_DIR"/hooks/*.sh; do
  [ -f "$hook_script" ] || continue
  EXPECTED_HOOKS=$((EXPECTED_HOOKS + 1))
done
case "$REAL_MANIFEST" in
  *"hooks wiring: all $EXPECTED_HOOKS hooks referenced in hooks.json exist on disk"*) check "P2o real hook manifest covers all $EXPECTED_HOOKS hook scripts" PASS ;;
  *) check "P2o real hook manifest count does not match $EXPECTED_HOOKS hook scripts on disk" FAIL ;;
esac
if grep -qF 'mcp__playwright__*' "$SKILL_MD" && grep -qF 'mcp__plugin_zensu_playwright__*' "$SKILL_MD" \
  && grep -qF 'ZDOC_PLAYWRIGHT_TOOLS=ready bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-doctor.sh"' "$SKILL_MD"; then
  check "P2l doctor skill propagates loaded MCP-tool readiness into the helper" PASS
else
  check "P2l doctor skill propagates loaded MCP-tool readiness into the helper" FAIL
fi

PHASE3_SKILL="$(sed -n '/^## Phase 3:/,/^## Response Style/p' "$SKILL_MD")"
if printf '%s\n' "$PHASE3_SKILL" | grep -qF 'Never delete, rename, rewrite, or enumerate' \
  && printf '%s\n' "$PHASE3_SKILL" | grep -qF 'zensu-log.sh --review-rearm' \
  && printf '%s\n' "$PHASE3_SKILL" | grep -qF 'Do NOT re-derive it from' \
  && printf '%s\n' "$PHASE3_SKILL" | grep -qF "expired, safe to clear: '<absolute path>'" \
  && printf '%s\n' "$PHASE3_SKILL" | grep -qF 'already SHELL-QUOTED' \
  && printf '%s\n' "$PHASE3_SKILL" | grep -qF 'PRECONDITION, not a substitute for yours' \
  && printf '%s\n' "$PHASE3_SKILL" | grep -qF 'rm -f -- <the quoted literal' \
  && ! printf '%s\n' "$PHASE3_SKILL" | awk '/^```/{inside=!inside;next} inside{print}' | grep -Eq '(^|[[:space:]])find[[:space:]]'; then
  check "P2m cleanup protects CAS documents and limits the only write to exact pending-review.json" PASS
else
  check "P2m cleanup protects CAS documents and limits the only write to exact pending-review.json" FAIL
fi

if ! command -v node >/dev/null 2>&1; then
  echo "  SKIP  node not on PATH — functional checks skipped (doc pins above ran)"
  echo "----"
  echo "test-doctor: $PASS PASS / $FAIL FAIL (functional skipped)"
  if [ "$FAIL" -gt 0 ]; then exit 1; fi
  exit 0
fi

SBOX="$(mktemp -d 2>/dev/null)" || SBOX=""
if [ -z "$SBOX" ]; then
  check "P1 sandbox creation (mktemp)" FAIL
  echo "----"
  echo "test-doctor: $PASS PASS / $FAIL FAIL"
  exit 1
fi
STATE_PROJECT="$SBOX/state-project"
STATE_DIR_CANON="$STATE_PROJECT/.zensu/state"
EMPTY_PROJECT="$SBOX/empty-project"
mkdir -p "$SBOX/plug/.claude-plugin" "$SBOX/plug/hooks" "$STATE_DIR_CANON" "$EMPTY_PROJECT"

# Sandbox HOME for the WHOLE functional half. The report resolves two things out
# of HOME — the user-scoped zensu config and the reviewer-spawn permission check's
# ~/.claude/settings.json — so without this every check below reads whatever the
# developer running the suite happens to have, and a machine with permission mode
# "auto" and no Agent allow rule fails P1e on a tree that is correct. Fixtures
# that need their own home override HOME per invocation (run_report_home).
NOHOME="$SBOX/nohome"
mkdir -p "$NOHOME"
export HOME="$NOHOME"

run_report() {
  # run_report <plugin_dir> <config|-> <project_root>  (tool facts fixed absent)
  local pd="$1" cfg="$2" project="$3"
  local cfgenv=""
  [ "$cfg" != "-" ] && cfgenv="$cfg"
  ZDOC_ZENSU=absent ZDOC_NODE="vTEST" ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$pd" ZENSU_CONFIG="$cfgenv" CLAUDE_PROJECT_DIR="$project" \
    node "$REPORT" 2>/dev/null
}

# --- all-green fixture -----------------------------------------------------
printf '{"name":"zensu","version":"1.2.3"}\n' > "$SBOX/plug/.claude-plugin/plugin.json"
printf '{"plugins":[{"name":"zensu","version":"1.2.3"}]}\n' > "$SBOX/plug/.claude-plugin/marketplace.json"
printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":"${CLAUDE_PLUGIN_ROOT}/hooks/a.sh","args":["${CLAUDE_PLUGIN_ROOT}/hooks/ghost.sh"]}]}]}}\n' > "$SBOX/plug/hooks/hooks.json"
printf '#!/bin/bash\n' > "$SBOX/plug/hooks/a.sh"
printf '{"hooks":{"reviewJudge":true,"secretScan":false}}\n' > "$SBOX/good-cfg.json"
# The rule-carrier row reports on plugin DATA, so a green fixture has to carry that
# data or the row correctly reports it missing and P1e stops being all-green. The
# real module and the real docs are copied rather than stubbed: the row's whole point
# is that it uses the same reader the hooks use, and a stub would let this suite go
# green against a parser nothing ships. The module lives under hooks/lib and ends in
# .js, so the wiring row — which reads hooks/*.sh — does not see it as unwired.
mkdir -p "$SBOX/plug/hooks/lib" "$SBOX/plug/docs"
cp "$PLUGIN_DIR/hooks/lib/rule-block-v1.js" "$SBOX/plug/hooks/lib/rule-block-v1.js"
cp "$PLUGIN_DIR/docs/best-solution-first.md" "$SBOX/plug/docs/best-solution-first.md"
cp "$PLUGIN_DIR/docs/evidence-discipline.md" "$SBOX/plug/docs/evidence-discipline.md"

OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"; RC=$?
[ "$RC" -eq 0 ] && check "P1a report exits 0 on the green fixture" PASS || check "P1a report exits 0 (rc=$RC)" FAIL
case "$OUT" in *'version sync: plugin.json and marketplace.json agree'*) check "P1b version sync ✅ when equal" PASS ;; *) check "P1b version sync ✅ when equal" FAIL ;; esac
case "$OUT" in *'hooks wiring: all 1 hooks'*) check "P1c wiring ✅ when consistent" PASS ;; *) check "P1c wiring ✅ when consistent" FAIL ;; esac
case "$OUT" in *'no quoted-boolean traps'*) check "P1d config ✅ with real booleans (reviewJudge:true/secretScan:false)" PASS ;; *) check "P1d config ✅ with real booleans" FAIL ;; esac
# all-green summary only when the tool block is green too (inject authed tools)
GREEN="$(ZDOC_ZENSU=authed ZDOC_NODE="vTEST" ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=ready ZDOC_PLAYWRIGHT=ready \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" \
  node "$REPORT" 2>/dev/null)"
case "$GREEN" in *'all checks green'*) check "P1e summary reports all green when every block is green" PASS ;; *) check "P1e summary all green (got: $GREEN)" FAIL ;; esac
case "$GREEN" in *'Playwright MCP: loaded and ready (/zensu:verify-feature and autopilot browser driver)'*) check "P1ea runtime-ready Playwright MCP renders green" PASS ;; *) check "P1ea runtime-ready Playwright MCP message (got: $GREEN)" FAIL ;; esac

# --- verify-feature consent/policy row (renderer + wrapper source) --------
verify_row() { # $1 ZDOC_VERIFY value or "" ; $2 reason
  ZDOC_ZENSU=authed ZDOC_NODE="vTEST" ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=ready ZDOC_PLAYWRIGHT=ready \
  ZDOC_VERIFY="$1" ZDOC_VERIFY_REASON="$2" \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" \
    node "$REPORT" 2>/dev/null
}
VF_POLICY="$(verify_row policy "")"
case "$VF_POLICY" in *'✅  verify-feature: environment policy active'*) check "P1va verify-feature policy state renders green" PASS ;; *) check "P1va verify-feature policy state renders green" FAIL ;; esac
VF_CONSENT="$(verify_row consent "")"
case "$VF_CONSENT" in *'✅  verify-feature: consent mode ready — no parent policy'*'all checks green'*) check "P1vb consent-with-recipe renders green and keeps the green summary" PASS ;; *) check "P1vb consent-with-recipe renders green and keeps the green summary" FAIL ;; esac
VF_NORECIPE="$(verify_row consent-no-recipe "")"
case "$VF_NORECIPE" in *'⚠️  verify-feature: consent mode ready, no runtime recipe'*'/zensu:verify-feature --setup'*'--attach=<loopback-origin>'*) check "P1vc consent-without-recipe warns and names setup and attach" PASS ;; *) check "P1vc consent-without-recipe warns and names setup and attach" FAIL ;; esac
case "$VF_NORECIPE" in *'all checks green'*) check "P1vc1 the no-recipe warning withholds the green summary" FAIL ;; *) check "P1vc1 the no-recipe warning withholds the green summary" PASS ;; esac
VF_UNAVAILABLE="$(verify_row unavailable "consent hook not registered on the navigation matcher")"
case "$VF_UNAVAILABLE" in *'❌  verify-feature: cannot start (consent hook not registered on the navigation matcher)'*) check "P1vd unavailable renders red with the wrapper's reason" PASS ;; *) check "P1vd unavailable renders red with the wrapper's reason" FAIL ;; esac
VF_ABSENT="$(verify_row "" "")"
case "$VF_ABSENT" in *'verify-feature:'*) check "P1ve an absent ZDOC_VERIFY renders no verify-feature row" FAIL ;; *) check "P1ve an absent ZDOC_VERIFY renders no verify-feature row" PASS ;; esac
if grep -qF 'ZDOC_VERIFY=policy' "$HELPER" && grep -qF 'ZDOC_VERIFY=consent-no-recipe' "$HELPER" \
  && grep -qF 'ZDOC_VERIFY=unavailable' "$HELPER" && grep -qF 'consentHookRegistered' "$HELPER" \
  && grep -qF 'ZENSU_VERIFY_NAVIGATION_POLICY_V1' "$HELPER" \
  && grep -qF 'ZDOC_SESSION_PROJECT_ROOT ZDOC_VERIFY ZDOC_VERIFY_REASON' "$HELPER"; then
  check "P1vf wrapper derives the verify state from the policy env, the registered hook and the recipe, and exports it" PASS
else
  check "P1vf wrapper derives the verify state from the policy env, the registered hook and the recipe, and exports it" FAIL
fi
VF_SKILL="$PLUGIN_DIR/skills/doctor/SKILL.md"
VF_SKILL_MISS=""
for phrase in "verify-feature: environment policy active" "verify-feature: consent mode ready" "consent mode ready, no runtime recipe" "verify-feature: cannot start"; do
  grep -qF -- "$phrase" "$VF_SKILL" || VF_SKILL_MISS="$VF_SKILL_MISS [$phrase]"
done
[ -z "$VF_SKILL_MISS" ] && check "P1vg all four verify-feature rows are documented in skills/doctor/SKILL.md" PASS \
  || check "P1vg verify-feature rows missing from skills/doctor/SKILL.md:$VF_SKILL_MISS" FAIL

# --- wrapper Playwright MCP detection (offline; npm must never execute) -----
MCP_PLUG="$SBOX/mcp-plug"
FAKE_BIN="$SBOX/fake-bin"
NPM_MARKER="$SBOX/npm-invoked"
mkdir -p "$MCP_PLUG/.claude-plugin" "$MCP_PLUG/hooks" "$MCP_PLUG/scripts" "$MCP_PLUG/mcp-runtime" "$FAKE_BIN"
printf '{"name":"zensu","version":"1.2.3","mcpServers":"./.mcp.json"}\n' > "$MCP_PLUG/.claude-plugin/plugin.json"
printf '{"plugins":[{"name":"zensu","version":"1.2.3"}]}\n' > "$MCP_PLUG/.claude-plugin/marketplace.json"
printf '{"hooks":{}}\n' > "$MCP_PLUG/hooks/hooks.json"
printf '%s\n' '{"mcpServers":{"playwright":{"type":"stdio","command":"${CLAUDE_PLUGIN_ROOT}/scripts/playwright-mcp.sh","args":["--isolated"]}}}' > "$MCP_PLUG/.mcp.json"
printf '%s\n' '{"private":true,"dependencies":{"@playwright/mcp":"0.0.75"}}' > "$MCP_PLUG/mcp-runtime/package.json"
printf '%s\n' '{"lockfileVersion":3,"packages":{"":{"dependencies":{"@playwright/mcp":"0.0.75"}},"node_modules/@playwright/mcp":{"version":"0.0.75","integrity":"sha512-fixture"}}}' > "$MCP_PLUG/mcp-runtime/package-lock.json"
printf '#!/bin/bash\nexit 0\n' > "$MCP_PLUG/scripts/playwright-mcp.sh"
chmod +x "$MCP_PLUG/scripts/playwright-mcp.sh"
cat > "$MCP_PLUG/scripts/playwright-mcp-proxy.js" <<'PROXY_FIXTURE'
'use strict';
module.exports.ALLOWED_TOOLS = [
  'browser_click', 'browser_close', 'browser_console_messages',
  'browser_drag', 'browser_fill_form', 'browser_handle_dialog', 'browser_hover',
  'browser_navigate', 'browser_network_requests', 'browser_press_key', 'browser_resize',
  'browser_select_option', 'browser_snapshot', 'browser_tabs', 'browser_take_screenshot',
  'browser_type', 'browser_wait_for'
];
PROXY_FIXTURE
ln -s "$(command -v node)" "$FAKE_BIN/node"
printf '#!/bin/bash\n: > "${FAKE_NPM_MARKER:?}"\nexit 99\n' > "$FAKE_BIN/npm"
chmod +x "$FAKE_BIN/npm"
MCP_OUT="$(PATH="$FAKE_BIN:/usr/bin:/bin" FAKE_NPM_MARKER="$NPM_MARKER" \
  ZENSU_DOCTOR_PLUGIN_DIR="$MCP_PLUG" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" \
  bash "$HELPER" 2>/dev/null)"
case "$MCP_OUT" in *'Playwright MCP: valid integrity-locked plugin config + npm present'*) check "P1eb helper executes valid MCP declaration path" PASS ;; *) check "P1eb valid MCP declaration path (got: $MCP_OUT)" FAIL ;; esac
if [ -e "$NPM_MARKER" ]; then
  check "P1ec helper never executes npm during offline detection" FAIL
else
  check "P1ec helper never executes npm during offline detection" PASS
fi
printf '%s\n' '{"mcpServers":{"playwright":{"type":"stdio","command":"npx","args":["@playwright/mcp@latest"]}}}' > "$MCP_PLUG/.mcp.json"
rm -f "$NPM_MARKER"
BAD_MCP_OUT="$(PATH="$FAKE_BIN:/usr/bin:/bin" FAKE_NPM_MARKER="$NPM_MARKER" ZDOC_PLAYWRIGHT_TOOLS=ready \
  ZENSU_DOCTOR_PLUGIN_DIR="$MCP_PLUG" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" \
  bash "$HELPER" 2>/dev/null)"; BAD_MCP_RC=$?
[ "$BAD_MCP_RC" -eq 0 ] && check "P1ed invalid MCP helper path exits 0" PASS || check "P1ed invalid MCP helper path exits 0 (rc=$BAD_MCP_RC)" FAIL
case "$BAD_MCP_OUT" in *'Playwright MCP: valid plugin config not detected'*) check "P1ef invalid/floating MCP declaration renders exact warning" PASS ;; *) check "P1ef invalid/floating MCP warning (got: $BAD_MCP_OUT)" FAIL ;; esac
if [ -e "$NPM_MARKER" ]; then
  check "P1eg invalid MCP detection still never executes npm" FAIL
else
  check "P1eg invalid MCP detection still never executes npm" PASS
fi
printf '%s\n' '{"mcpServers":{"playwright":{"type":"stdio","command":"${CLAUDE_PLUGIN_ROOT}/scripts/playwright-mcp.sh","args":["--isolated"]}}}' > "$MCP_PLUG/.mcp.json"
NO_NPM_BIN="$SBOX/no-npm-bin"
mkdir -p "$NO_NPM_BIN"
ln -s "$(command -v node)" "$NO_NPM_BIN/node"
ln -s "$(command -v dirname)" "$NO_NPM_BIN/dirname"
DECLARED_OUT="$(PATH="$NO_NPM_BIN" ZENSU_DOCTOR_PLUGIN_DIR="$MCP_PLUG" \
  ZDOC_FORGE_PROVIDER=unknown ZDOC_FORGE_CLI='' ZDOC_FORGE_STATE='' \
  ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" /bin/bash "$HELPER" 2>/dev/null)"; DECLARED_RC=$?
[ "$DECLARED_RC" -eq 0 ] && check "P1eh valid declaration/no-npm helper path exits 0" PASS || check "P1eh valid declaration/no-npm helper path exits 0 (rc=$DECLARED_RC)" FAIL
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) check "P1ei isolated no-npm PATH rendering (covered on macOS/Linux/WSL)" PASS ;;
  *) case "$DECLARED_OUT" in *'Playwright MCP: valid integrity-locked plugin config but npm is missing from PATH'*) check "P1ei valid declaration without npm renders degraded warning" PASS ;; *) check "P1ei declared/no-npm warning (got: $DECLARED_OUT)" FAIL ;; esac ;;
esac
READY_HELPER="$(ZDOC_ZENSU=authed ZDOC_NODE=vTEST ZDOC_GH=authed ZDOC_PLAYWRIGHT_TOOLS=ready \
  ZENSU_DOCTOR_PLUGIN_DIR="$MCP_PLUG" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" \
  bash "$HELPER" 2>/dev/null)"; READY_HELPER_RC=$?
[ "$READY_HELPER_RC" -eq 0 ] && case "$READY_HELPER" in *'Playwright MCP: loaded and ready'*) check "P1ej helper requires valid plugin config + loaded-tool signal for readiness" PASS ;; *) check "P1ej helper ready message (got: $READY_HELPER)" FAIL ;; esac || check "P1ej helper ready path (rc=$READY_HELPER_RC)" FAIL
PATH_ONLY="$(ZDOC_ZENSU=authed ZDOC_NODE=vTEST ZDOC_GH=authed ZDOC_PLAYWRIGHT=present \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" \
  node "$REPORT" 2>/dev/null)"
case "$PATH_ONLY" in *'PATH binary found, but /zensu:verify-feature requires loaded Playwright MCP tools'*) check "P1ee PATH-only Playwright is a warning, not false green" PASS ;; *) check "P1ee PATH-only Playwright warning (got: $PATH_ONLY)" FAIL ;; esac

# --- version mismatch ------------------------------------------------------
printf '{"plugins":[{"name":"zensu","version":"9.9.9"}]}\n' > "$SBOX/plug/.claude-plugin/marketplace.json"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"; RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *'version sync: plugin.json 1.2.3 != marketplace.json 9.9.9'*) check "P1f version mismatch ❌ (exit 0)" PASS ;; *) check "P1f version mismatch ❌ (got: $OUT)" FAIL ;; esac || check "P1f version mismatch (rc=$RC)" FAIL
printf '{"plugins":[{"name":"zensu","version":"1.2.3"}]}\n' > "$SBOX/plug/.claude-plugin/marketplace.json"

# --- hooks wiring both directions -----------------------------------------
printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":"${CLAUDE_PLUGIN_ROOT}/hooks/ghost.sh"}]}]}}\n' > "$SBOX/plug/hooks/hooks.json"
printf '#!/bin/bash\n' > "$SBOX/plug/hooks/orphan.sh"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in *'referenced but missing on disk'*ghost.sh*) check "P1g wired-but-missing ❌ names the script" PASS ;; *) check "P1g wired-but-missing ❌ (got: $OUT)" FAIL ;; esac
case "$OUT" in *'not referenced in hooks.json'*orphan.sh*) check "P1h disk-but-unwired ⚠️ names the script" PASS ;; *) check "P1h disk-but-unwired ⚠️ (got: $OUT)" FAIL ;; esac
# restore consistent wiring
printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":"${CLAUDE_PLUGIN_ROOT}/hooks/a.sh"}]}]}}\n' > "$SBOX/plug/hooks/hooks.json"
rm -f "$SBOX/plug/hooks/orphan.sh"

# --- quoted-boolean trap ---------------------------------------------------
printf '{"hooks":{"reviewJudge":"true","secretScan":false}}\n' > "$SBOX/bad-cfg.json"
OUT="$(run_report "$SBOX/plug" "$SBOX/bad-cfg.json" "$STATE_PROJECT")"; RC=$?
[ "$RC" -eq 0 ] && check "P1i report exits 0 on quoted-boolean config" PASS || check "P1i report exits 0 (rc=$RC)" FAIL
case "$OUT" in *'quoted boolean'*'hooks.reviewJudge = "true"'*) check "P1j quoted boolean ⚠️ names the dotted key" PASS ;; *) check "P1j quoted boolean ⚠️ (got: $OUT)" FAIL ;; esac
case "$OUT" in *secretScan*) check "P1k real boolean secretScan:false NOT flagged" FAIL ;; *) check "P1k real boolean secretScan:false NOT flagged" PASS ;; esac

# --- invalid JSON config ---------------------------------------------------
printf '{not json' > "$SBOX/broken-cfg.json"
OUT="$(run_report "$SBOX/plug" "$SBOX/broken-cfg.json" "$STATE_PROJECT")"; RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *'config: invalid JSON'*) check "P1l invalid config ❌ (exit 0, defaults apply)" PASS ;; *) check "P1l invalid config ❌ (got: $OUT)" FAIL ;; esac || check "P1l invalid config (rc=$RC)" FAIL

# --- validated CAS workflow state -----------------------------------------
CAS_PROJECT="$SBOX/cas-project"
CAS_ST="$CAS_PROJECT/.zensu/state"
mkdir -p "$CAS_PROJECT"
export CLAUDE_PROJECT_DIR="$CAS_PROJECT"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" doctor-valid
bash "$PLUGIN_DIR/hooks/lib/zensu-log.sh" --tdd-begin --session doctor-valid >/dev/null 2>&1
CAS_KEY="$(node "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js" session-key doctor-valid)"
CAS_FILE="$CAS_ST/tdd-phase-${CAS_KEY}.json"
# Retired sidecars are inert and must neither be counted nor interpreted.
: > "$CAS_ST/rounds-retired.json"; : > "$CAS_ST/retired.stopblocks"
OUT="$(run_report "$PLUGIN_DIR" "$SBOX/good-cfg.json" "$CAS_PROJECT")"
case "$OUT" in *'1 validated CAS workflow document(s); reviewRound/stopBlockCount/implStopCount are integrated fields'*) check "P1m valid CAS workflow document is reported with integrated counters" PASS ;; *) check "P1m valid CAS workflow state (got: $OUT)" FAIL ;; esac
case "$OUT" in *'per-session marker'*|*'1 rounds'*|*'1 stopblocks'*) check "P1ma retired sidecars are not counted as session state" FAIL ;; *) check "P1ma retired sidecars are not counted as session state" PASS ;; esac

# the chain block: shape row, truncated session key, no false alarm, exit 0
case "$OUT" in *'chain: 1 review chain(s) — scv1_'*': implementing'*) check "P1mc chain row names the shape and a truncated session key" PASS ;; *) check "P1mc chain row names the shape and a truncated session key (got: $OUT)" FAIL ;; esac
case "$OUT" in *"$CAS_KEY"*) check "P1md the full session key is never printed" FAIL ;; *) check "P1md the full session key is never printed" PASS ;; esac
case "$OUT" in *'wedged'*) check "P1me a healthy chain raises no wedge warning" FAIL ;; *) check "P1me a healthy chain raises no wedge warning" PASS ;; esac
# missing chain module: a sandbox plugin root that carries the core but not the
# classifier, so the probe never touches the tracked working tree
NOCHAIN="$SBOX/nochain"
mkdir -p "$NOCHAIN/.claude-plugin" "$NOCHAIN/hooks/lib"
printf '{"name":"zensu","version":"1.2.3"}\n' > "$NOCHAIN/.claude-plugin/plugin.json"
printf '{"plugins":[{"name":"zensu","version":"1.2.3"}]}\n' > "$NOCHAIN/.claude-plugin/marketplace.json"
printf '{"hooks":{}}\n' > "$NOCHAIN/hooks/hooks.json"
cp "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js" "$NOCHAIN/hooks/lib/session-control-core-v1.js"
cp "$PLUGIN_DIR/hooks/lib/zensu-doctor-report.js" "$NOCHAIN/hooks/lib/zensu-doctor-report.js"
OUT_NOMOD="$(ZENSU_DOCTOR_PLUGIN_DIR="$NOCHAIN" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$CAS_PROJECT" \
  node "$NOCHAIN/hooks/lib/zensu-doctor-report.js" 2>&1)"
NOMOD_RC=$?
case "$OUT_NOMOD" in
  *'chain-recovery-v1.js is unreadable'*)
    [ "$NOMOD_RC" -eq 0 ] \
      && check "P1mf a missing chain module degrades to a warning and still exits 0" PASS \
      || check "P1mf a missing chain module still exits 0 (rc=$NOMOD_RC)" FAIL ;;
  *)
    check "P1mf a missing chain module degrades to a warning (got: $OUT_NOMOD)" FAIL ;;
esac

# --- open chain not owned by this session ----------------------------------
# A forked or re-initialized Claude Code session receives a NEW session id while
# carrying its history over, so the chain armed under the old key is unreachable
# and every later helper call answers `no-session`. Nothing reported that, which
# is what this row exists for. Both fixture documents are produced by shipped
# verbs (--tdd-begin, --tdd-reset) rather than hand-written, so the rows grade
# the real classifier.
#
# `initialize-baseline.sh` exports CLAUDE_PLUGIN_DATA and CLAUDE_CODE_SESSION_ID
# besides the project dir, so all three are saved here and restored at the end of
# the block: restoring only the last would leave a session bound to a project
# nobody else in this file is looking at, for the remaining ~2000 lines.
#
# Deliberately NOT a subshell, though that would restore them for free. `check`
# increments its tallies in the shell that runs it, so a subshell would PRINT a
# FAIL and let the suite still exit 0 — measured, not hypothetical: the first
# version of this block did exactly that, reporting `0 FAIL` with two failures on
# screen. The env dance is the cheaper of the two mistakes.
STRAND_SAVED_PROJECT="${CLAUDE_PROJECT_DIR:-}"
STRAND_SAVED_DATA="${CLAUDE_PLUGIN_DATA:-}"
STRAND_SAVED_SESSION="${CLAUDE_CODE_SESSION_ID:-}"
STRAND_PROJECT="$SBOX/strand-project"
mkdir -p "$STRAND_PROJECT"
export CLAUDE_PROJECT_DIR="$STRAND_PROJECT"
# ORDER IS LOAD-BEARING: the inert document must be written FIRST, so its
# `updated_at` is OLDER than the clock below (which is pinned to the open
# document). Armed the other way round the inert entry was excluded by the
# future-stamp guard before the inert-shape filter ever ran, and P1mh passed with
# that filter deleted — measured, not hypothetical.
# shellcheck disable=SC1091
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" strand-inert
bash "$PLUGIN_DIR/hooks/lib/zensu-log.sh" --tdd-begin --session strand-inert >/dev/null 2>&1
bash "$PLUGIN_DIR/hooks/lib/zensu-log.sh" --tdd-reset --session strand-inert >/dev/null 2>&1
# shellcheck disable=SC1091
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" strand-open
bash "$PLUGIN_DIR/hooks/lib/zensu-log.sh" --tdd-begin --session strand-open >/dev/null 2>&1
STRAND_OPEN_KEY="$(node "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js" session-key strand-open)"
STRAND_INERT_KEY="$(node "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js" session-key strand-inert)"
# A third key: a session owning neither document, which is the state a fork lands in.
STRAND_FOREIGN_KEY="$(node "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js" session-key strand-observer)"
# The clock is pinned to the open document's own `updated_at`, which is what the
# renderer ages against — not to its mtime, and not to a literal. The TTL arms
# below move the clock a fixed distance from this point.
STRAND_NOW_MS="$(CLAUDE_PROJECT_DIR="$STRAND_PROJECT" node -e '
  var core = require(process.argv[1] + "/hooks/lib/session-control-core-v1.js");
  var s = core.readWorkflowState({ projectRoot: process.argv[2], sessionId: process.argv[3] });
  process.stdout.write(String(Date.parse(s.updated_at)));
' "$PLUGIN_DIR" "$STRAND_PROJECT" "$STRAND_OPEN_KEY")"
STRAND_INERT_MS="$(CLAUDE_PROJECT_DIR="$STRAND_PROJECT" node -e '
  var core = require(process.argv[1] + "/hooks/lib/session-control-core-v1.js");
  var s = core.readWorkflowState({ projectRoot: process.argv[2], sessionId: process.argv[3] });
  process.stdout.write(String(Date.parse(s.updated_at)));
' "$PLUGIN_DIR" "$STRAND_PROJECT" "$STRAND_INERT_KEY")"
# P1mh only bites while the inert document is not NEWER than the clock: the renderer
# filters inert shapes before it ages anything, so a later stamp would exclude the
# entry through the future-stamp guard instead and the filter under test would go
# untested. Arming order produces that relation; this asserts it.
if [ -n "$STRAND_INERT_MS" ] && [ "$STRAND_INERT_MS" -le "$STRAND_NOW_MS" ]; then
  check "P1mh0 the inert fixture is not newer than the clock, so P1mh tests the inert filter" PASS
else
  check "P1mh0 the inert fixture is not newer than the clock (inert=$STRAND_INERT_MS now=$STRAND_NOW_MS)" FAIL
fi
STRAND_PHRASE='open chain(s) not owned by this session'
# Every healthy render of this fixture names both documents in the shapes row.
# The absence arms below assert it BEFORE testing for absence: `strand_report`
# discards stderr and the renderer catches every throw and still exits 0, so an
# output that merely lacks the needle proves nothing on its own.
STRAND_ANCHOR='chain: 2 review chain(s)'
strand_report() {
  # $1 = ZDOC_SESSION_KEY, $2 = now in ms, $3 = ZDOC_BINDING (default bound),
  # $4 = ZDOC_SESSION_PROJECT_ROOT (default the scanned project), $5 = TTL hours
  ZDOC_ZENSU=absent ZDOC_NODE="vTEST" ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh \
  ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent ZDOC_TTL_HOURS="${5:-6}" \
  ZDOC_BINDING="${3:-bound}" ZDOC_SESSION_KEY="$1" ZDOC_NOW_MS="$2" \
  ZDOC_SESSION_PROJECT_ROOT="${4-$STRAND_PROJECT}" \
  ZENSU_DOCTOR_PLUGIN_DIR="$PLUGIN_DIR" ZENSU_CONFIG="" CLAUDE_PROJECT_DIR="$STRAND_PROJECT" \
    node "$REPORT" 2>/dev/null
}
strand_absent() {
  # $1 = check id + description, $2 = the report to grade
  case "$2" in
    *"$STRAND_ANCHOR"*) ;;
    *) check "$1 — VACUOUS: the run produced no classified report" FAIL; return ;;
  esac
  case "$2" in
    *"$STRAND_PHRASE"*) check "$1" FAIL ;;
    *) check "$1" PASS ;;
  esac
}

OUT="$(strand_report "$STRAND_FOREIGN_KEY" "$STRAND_NOW_MS")"
# The glyph is part of the contract, not decoration: `line()` counts only WARN
# toward warnCount, and main() prints "all checks green" while that count is 0.
# A row silently demoted to OK would leave every text assertion below green.
case "$OUT" in
  *"⚠️  chain: 1 $STRAND_PHRASE"*"${STRAND_OPEN_KEY:0:13}"*': implementing'*)
    check "P1mg a foreign open chain within the TTL is reported, as a warning" PASS ;;
  *) check "P1mg a foreign open chain within the TTL is reported, as a warning (got: $OUT)" FAIL ;;
esac
# The row's own severity, measured differentially. An earlier version asserted the
# absence of "all checks green", which `strand_report` makes unreachable on its own
# (it injects ZDOC_ZENSU=absent, ZDOC_FORGE_STATE=missing and ZDOC_PLAYWRIGHT=absent,
# three WARN rows), so it passed even with the row demoted to OK. Counting warnings
# with and without the row is what actually bites.
strand_warncount() {
  printf '%s' "$1" | sed -n 's/^Summary:.*[^0-9]\([0-9][0-9]*\) ⚠️.*/\1/p' | head -1
}
STRAND_W_WITH="$(strand_warncount "$OUT")"
STRAND_W_WITHOUT="$(strand_warncount "$(strand_report "$STRAND_OPEN_KEY" "$STRAND_NOW_MS")")"
if [ -n "$STRAND_W_WITH" ] && [ -n "$STRAND_W_WITHOUT" ] \
  && [ "$STRAND_W_WITH" -eq "$(( STRAND_W_WITHOUT + 1 ))" ]; then
  check "P1mg1 the row adds exactly one warning to the summary count" PASS
else
  check "P1mg1 the row adds exactly one warning to the summary count (with=$STRAND_W_WITH without=$STRAND_W_WITHOUT)" FAIL
fi
case "$OUT" in
  *"$STRAND_PHRASE"*"${STRAND_INERT_KEY:0:13}"*)
    check "P1mh an inert (no-session) foreign chain is never named" FAIL ;;
  *) check "P1mh an inert (no-session) foreign chain is never named" PASS ;;
esac
case "$OUT" in
  *"$STRAND_OPEN_KEY"*) check "P1mi the row never prints a full session key" FAIL ;;
  *) check "P1mi the row never prints a full session key" PASS ;;
esac
# The row must not assert a fork: it cannot tell a forked-away session from a
# live sibling, and this repository mandates worktree workflows where live
# siblings are ordinary. It states the observation and makes the remedy
# conditional on the reader establishing which cause applies.
case "$OUT" in
  *'cannot be moved to this key'*'Check whether the owning session is still running before acting'*)
    check "P1mj the row states the observation and a conditional remedy" PASS ;;
  *) check "P1mj the row states the observation and a conditional remedy (got: $OUT)" FAIL ;;
esac
# The CAUSE ORDER is the contract, not decoration. The predicate is dominated by a
# session that ended without --chain-done, so naming the fork first and opening with
# "nothing is wrong here" described the rare case and dismissed the common one.
case "$OUT" in
  *'Usually a session that ended without /zensu:tdd --chain-done'*'It can also be a'*'live sibling'*'or a FORK'*)
    check "P1mj1 the row names the abandoned chain before the fork" PASS ;;
  *) check "P1mj1 the row names the abandoned chain before the fork (got: $OUT)" FAIL ;;
esac

strand_absent "P1mk this session's OWN open chain is never reported" \
  "$(strand_report "$STRAND_OPEN_KEY" "$STRAND_NOW_MS")"
strand_absent "P1ml with no current session key the row is absent" \
  "$(strand_report "" "$STRAND_NOW_MS")"
# A malformed injected key must not be TREATED as the current key: every chain
# would then read as foreign and the row would accuse the session of stranding
# its own work.
strand_absent "P1mm a malformed current session key never enables the row" \
  "$(strand_report "scv1_not-a-key" "$STRAND_NOW_MS")"
# The wrapper states the key is empty for every verdict but `bound`. That block
# is skipped whenever a caller supplies ZDOC_BINDING, so the reader enforces it:
# without this the report could print the ❌ no-record row and, below it, a row
# keyed on a session key it had just said does not exist.
strand_absent "P1mm1 a well-formed key under a non-bound verdict never enables the row" \
  "$(strand_report "$STRAND_FOREIGN_KEY" "$STRAND_NOW_MS" unbound)"
# Every WRITER anchors the state directory on the record's project root, so the
# whole Session state block must read there too. Pointing the record anchor at an
# empty directory has to move the block, not merely change one row: if it still
# read CLAUDE_PROJECT_DIR the two strand documents would still be classified.
OUT_ELSEWHERE="$(strand_report "$STRAND_FOREIGN_KEY" "$STRAND_NOW_MS" bound "$SBOX/some-other-root")"
case "$OUT_ELSEWHERE" in
  *"$STRAND_ANCHOR"*) check "P1mm2 the state block follows the record anchor, not CLAUDE_PROJECT_DIR" FAIL ;;
  *'no CAS workflow documents yet'*|*'does not exist yet'*)
    check "P1mm2 the state block follows the record anchor, not CLAUDE_PROJECT_DIR" PASS ;;
  *) check "P1mm2 the state block follows the record anchor (got: $OUT_ELSEWHERE)" FAIL ;;
esac
# With no recorded anchor there is nothing better than the caller's value, so the
# block falls back to it rather than going blind.
OUT_FALLBACK="$(strand_report "$STRAND_FOREIGN_KEY" "$STRAND_NOW_MS" bound "")"
case "$OUT_FALLBACK" in
  *"$STRAND_ANCHOR"*"$STRAND_PHRASE"*)
    check "P1mm3 an absent record anchor falls back to CLAUDE_PROJECT_DIR" PASS ;;
  *) check "P1mm3 an absent record anchor falls back to CLAUDE_PROJECT_DIR (got: $OUT_FALLBACK)" FAIL ;;
esac
# Both halves of the row's contract DISCLOSE when they cannot run. The wrapper half
# — a bound verdict whose session key never arrived — used to withhold the row in
# silence while the rest of the report looked healthy, which is exactly the verdict
# a diagnostic may not give. Reachable through the shipped wrapper whenever one of
# its shape guards drops the pair.
OUT_NOKEY="$(strand_report "" "$STRAND_NOW_MS" bound "$STRAND_PROJECT")"
case "$OUT_NOKEY" in
  *'the session key did not reach this report'*'missing check, not an all-clear'*)
    check "P1mm5 a bound verdict with no session key discloses instead of falling silent" PASS ;;
  *) check "P1mm5 a bound verdict with no session key discloses instead of falling silent (got: $OUT_NOKEY)" FAIL ;;
esac
# ...and it still withholds the row itself; disclosure is not permission to guess.
strand_absent "P1mm6 the disclosure never renders the row it could not compute" "$OUT_NOKEY"
# The fallback is bound-only: a recorded anchor supplied under any other verdict
# is not the record speaking, so it must not redirect where the doctor looks.
OUT_UNBOUND_ROOT="$(strand_report "$STRAND_FOREIGN_KEY" "$STRAND_NOW_MS" unbound "$SBOX/some-other-root")"
case "$OUT_UNBOUND_ROOT" in
  *"$STRAND_ANCHOR"*) check "P1mm4 a recorded anchor under a non-bound verdict never redirects the scan" PASS ;;
  *) check "P1mm4 a recorded anchor under a non-bound verdict never redirects the scan (got: $OUT_UNBOUND_ROOT)" FAIL ;;
esac
# A non-ENOENT errno on the state directory must not render as health. ENOTDIR is
# the arm reachable without a privileged principal: a regular file where the state
# directory belongs. P1t chmods that directory to 0500, which leaves it READABLE, so
# it lands on the write-access row instead and never reaches this branch.
NOTDIR_PROJECT="$SBOX/notdir-project"; mkdir -p "$NOTDIR_PROJECT/.zensu"
: > "$NOTDIR_PROJECT/.zensu/state"
OUT_NOTDIR="$(strand_report "$STRAND_FOREIGN_KEY" "$STRAND_NOW_MS" bound "$NOTDIR_PROJECT")"
case "$OUT_NOTDIR" in
  *'could not be read'*'missing check, not an all-clear'*)
    check "P1mn0 a non-ENOENT state-directory errno is disclosed, not reported as health" PASS ;;
  *) check "P1mn0 a non-ENOENT state-directory errno is disclosed, not reported as health (got: $OUT_NOTDIR)" FAIL ;;
esac
strand_absent "P1mn a foreign open chain past the TTL is not reported" \
  "$(strand_report "$STRAND_FOREIGN_KEY" "$(( STRAND_NOW_MS + 100 * 3600 * 1000 ))")"
# Bounded in both directions: a document dated in the FUTURE yields a negative
# age that a one-sided `<= ttl` never crosses, so it would render forever.
strand_absent "P1mo a future-dated document does not render the row forever" \
  "$(strand_report "$STRAND_FOREIGN_KEY" "$(( STRAND_NOW_MS - 100 * 3600 * 1000 ))")"

# `0` DISABLES the bound everywhere else this key is read (docs/configuration.md,
# and reviewerDenialRows in the same renderer). A predicate that merely compared
# against 0 would silently delete the whole row instead.
OUT_TTL0="$(strand_report "$STRAND_FOREIGN_KEY" "$(( STRAND_NOW_MS + 100 * 3600 * 1000 ))" bound "$STRAND_PROJECT" 0)"
case "$OUT_TTL0" in
  *"1 $STRAND_PHRASE"*"${STRAND_OPEN_KEY:0:13}"*)
    check "P1mq a TTL of 0 disables the age bound rather than the whole row" PASS ;;
  *) check "P1mq a TTL of 0 disables the age bound rather than the whole row (got: $OUT_TTL0)" FAIL ;;
esac
case "$OUT_TTL0" in
  *'touched within 0h'*) check "P1mq1 a disabled bound is not advertised as a 0h window" FAIL ;;
  *) check "P1mq1 a disabled bound is not advertised as a 0h window" PASS ;;
esac
# The POSITIVE half. Without it the whole ternary could be deleted and every check
# here would stay green: P1mg matches `*` between the phrase and the key, which
# swallows the clause whether or not it is there, and P1mq/P1mq2 match the phrase
# alone. The row states the window it is bounded by; that is contract, not garnish.
case "$OUT" in
  *"$STRAND_PHRASE, touched within 6h"*)
    check "P1mq1a an armed bound IS advertised as its window" PASS ;;
  *) check "P1mq1a an armed bound IS advertised as its window (got: $OUT)" FAIL ;;
esac
# At `0` the row claims no window, so a FUTURE stamp is not out of one. Only a stamp
# that cannot be read at all may still exclude an entry there.
OUT_TTL0_FUTURE="$(strand_report "$STRAND_FOREIGN_KEY" "$(( STRAND_NOW_MS - 100 * 3600 * 1000 ))" bound "$STRAND_PROJECT" 0)"
case "$OUT_TTL0_FUTURE" in
  *"1 $STRAND_PHRASE"*"${STRAND_OPEN_KEY:0:13}"*)
    check "P1mq2 a disabled bound does not exclude a future-dated document" PASS ;;
  *) check "P1mq2 a disabled bound does not exclude a future-dated document (got: $OUT_TTL0_FUTURE)" FAIL ;;
esac

# FR-004: the doctor is read-only, and this is the one block pointing the
# renderer at a live state directory built by shipped verbs.
STRAND_BEFORE="$(cd "$STRAND_PROJECT/.zensu/state" && for f in *; do printf '%s:%s:%s\n' "$f" "$(wc -c <"$f")" "$(node -e 'process.stdout.write(String(require("fs").statSync(process.argv[1]).mtimeMs))' "$f")"; done)"
strand_report "$STRAND_FOREIGN_KEY" "$STRAND_NOW_MS" >/dev/null
STRAND_AFTER="$(cd "$STRAND_PROJECT/.zensu/state" && for f in *; do printf '%s:%s:%s\n' "$f" "$(wc -c <"$f")" "$(node -e 'process.stdout.write(String(require("fs").statSync(process.argv[1]).mtimeMs))' "$f")"; done)"
case "$STRAND_BEFORE" in
  *"tdd-phase-${STRAND_OPEN_KEY}.json"*"tdd-phase-${STRAND_INERT_KEY}.json"*|*"tdd-phase-${STRAND_INERT_KEY}.json"*"tdd-phase-${STRAND_OPEN_KEY}.json"*)
    check "P1mr1 the read-only snapshot named both workflow documents" PASS ;;
  *) check "P1mr1 the read-only snapshot named both workflow documents" FAIL ;;
esac
if [ -n "$STRAND_BEFORE" ] && [ "$STRAND_BEFORE" = "$STRAND_AFTER" ]; then
  check "P1mr a report run leaves every workflow document byte- and mtime-identical" PASS
else
  check "P1mr a report run leaves every workflow document byte- and mtime-identical" FAIL
fi
export CLAUDE_PROJECT_DIR="$STRAND_SAVED_PROJECT"
export CLAUDE_PLUGIN_DATA="$STRAND_SAVED_DATA"
export CLAUDE_CODE_SESSION_ID="$STRAND_SAVED_SESSION"
# `initialize-baseline.sh` also binds these five through `zensu_bind_model_session`.
# Latent rather than live today — the later real-wrapper runs unset them first — but
# leaving them bound to a project nobody else here looks at is a trap, not a saving.
unset ZENSU_CLAUDE_PLUGIN_ROOT ZENSU_SESSION_KEY ZENSU_SESSION_CONTEXT \
  ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT

# The wrapper half is pinned AT SOURCE, and the reason is measured rather than
# assumed. An earlier version of this note claimed a real bind needs a live host
# session; that is FALSE and was disproved here. Against the `strand-open` baseline
# above, `zensu_bind_model_session` returns 0 from a plain child process and yields
# both the scv1_ key and the project root, and the wrapper's exact substitution
# body — source, bind, four shape guards, tab-joined printf — reproduces that with
# rc=0 and a correct pair when run inline.
#
# What could NOT be made to work is the wrapper END TO END: `bash "$HELPER"` with
# that same environment still reports `binding: this session has no valid Session
# Control record`. The cause is NOT the comment inside the substitution (removing it
# changes nothing, measured) and NOT the shape guards (each exits 0, which would
# still yield `bound`). It was not established, so the end-to-end check was removed
# rather than left failing or weakened until it passed.
#
# CONSEQUENCE, stated so nobody reads the greps as more than they are: the branch
# that PRODUCES the pair, and that decides ZDOC_BINDING for EVERY session, has no
# executed coverage. A grep sees the `|| exit 0` literal; it cannot see the
# composite exit status, the TAB split, or the pair reaching the renderer.
# The structural pin must therefore cover the shape-failure DIRECTION, not only the
# shape — flipping `|| exit 0` to `|| exit 1` makes the elif fail, so a genuinely
# bound session is reported `unbound`, and a pattern that stopped at the regex would
# still match.
if grep -qF 'elif ZDOC_SESSION_PAIR="$(' "$HELPER" \
  && grep -qE 'ZENSU_SESSION_KEY:-\}" =~ \^scv1_\[a-f0-9\]\{64\}\$ \]\] \|\| exit 0' "$HELPER" \
  && grep -qE '\[ -d "\$\{ZENSU_PROJECT_ROOT:-\}" \] \|\| exit 0' "$HELPER" \
  && grep -qF 'case "${ZENSU_PROJECT_ROOT:-}" in *[[:cntrl:]]*) exit 0' "$HELPER" \
  && grep -qE '^export ZDOC_ZENSU' "$HELPER" \
  && grep -qF 'ZDOC_SESSION_KEY ZDOC_SESSION_PROJECT_ROOT' "$HELPER"; then
  check "P1mp the wrapper shape-guards the bound pair, drops on failure, and exports it" PASS
else
  check "P1mp the wrapper shape-guards the bound pair, drops on failure, and exports it" FAIL
fi
# Neither value may be `:=`-seeded: an inherited one would survive the `unknown`
# and `unavailable` branches, which set a verdict and never reach the bind.
STRAND_CLEAR_ORDER="$(awk '
  /^ZDOC_SESSION_KEY=""/ && !k { k = NR }
  /^ZDOC_SESSION_PROJECT_ROOT=""/ && !r { r = NR }
  /^if \[ -z "\$\{ZDOC_BINDING:-\}" \]; then/ && !g { g = NR }
  END { print (k && r && g && k < g && r < g) ? "ok" : "bad" }' "$HELPER")"
if [ "$STRAND_CLEAR_ORDER" = ok ] \
  && ! grep -qF 'ZDOC_SESSION_KEY="${ZDOC_SESSION_KEY:-}"' "$HELPER" \
  && ! grep -qF 'ZDOC_SESSION_PROJECT_ROOT="${ZDOC_SESSION_PROJECT_ROOT:-}"' "$HELPER"; then
  check "P1mp1 the session pair is cleared unconditionally, never :=-seeded" PASS
else
  check "P1mp1 the session pair is cleared unconditionally, never :=-seeded" FAIL
fi

# I7's behavioural half is unreachable from a structure suite: driving a chain to
# `chain-closed` needs a real reviewer spawn to consume the review ticket, which
# no test can perform. The rename risk it names is closed at the root instead —
# both inert literals must still be shapes the OWNER mints.
#
# The membership test drives `classifyChain` and reads the shape it RETURNS. An
# earlier version compared against the `NEXT_COMMAND` lookup table instead, which
# reproduced the exact blindness this export was created to remove: renaming what
# `chainShape` returns while leaving the table key in place kept the check green
# while a genuinely closed foreign chain rendered as an open one. A consumer-side
# table is not the producer.
STRAND_VOCAB="$(node -e '
  var chain = require(process.argv[1] + "/hooks/lib/chain-recovery-v1.js");
  var want = ["no-session", "chain-closed"];
  var got = chain.INERT_SHAPES;
  var verdict;
  if (!Array.isArray(got)) {
    verdict = "NOT-EXPORTED";
  } else {
    var missing = want.filter(function (s) { return got.indexOf(s) === -1; });
    var minted = {};
    [
      { active: false },
      { active: true, implComplete: true, chainDone: true },
    ].forEach(function (doc) {
      try { minted[chain.chainShape(doc)] = true; } catch (e) { /* shape not derivable */ }
    });
    var unminted = got.filter(function (s) { return !minted[s]; });
    if (missing.length) verdict = "MISSING-FROM-INERT:" + missing.join(",");
    else if (unminted.length) verdict = "NOT-RETURNED-BY-CLASSIFY:" + unminted.join(",");
    else verdict = "ok";
  }
  process.stdout.write(verdict);
' "$PLUGIN_DIR")"
[ "$STRAND_VOCAB" = ok ] \
  && check "P1ms the owner exports INERT_SHAPES holding both shapes it mints" PASS \
  || check "P1ms the owner exports INERT_SHAPES holding both shapes it mints ($STRAND_VOCAB)" FAIL
# A plugin root whose owner module loads but exports an unusable INERT_SHAPES.
# `[]` is the cheapest shape: inertShapes() answers null for an empty array.
BADINERT="$SBOX/badinert"
mkdir -p "$BADINERT/.claude-plugin" "$BADINERT/hooks/lib"
printf '{"name":"zensu","version":"1.2.3"}\n' > "$BADINERT/.claude-plugin/plugin.json"
printf '{"plugins":[{"name":"zensu","version":"1.2.3"}]}\n' > "$BADINERT/.claude-plugin/marketplace.json"
printf '{"hooks":{}}\n' > "$BADINERT/hooks/hooks.json"
cp "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js" "$BADINERT/hooks/lib/"
cp "$PLUGIN_DIR/hooks/lib/zensu-doctor-report.js" "$BADINERT/hooks/lib/"
sed "s/^const INERT_SHAPES = .*/const INERT_SHAPES = Object.freeze([]);/" \
  "$PLUGIN_DIR/hooks/lib/chain-recovery-v1.js" > "$BADINERT/hooks/lib/chain-recovery-v1.js"
OUT_BADINERT="$(ZDOC_ZENSU=absent ZDOC_NODE=vTEST ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh \
  ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent ZDOC_TTL_HOURS=6 ZDOC_BINDING=bound \
  ZDOC_SESSION_KEY="$STRAND_FOREIGN_KEY" ZDOC_NOW_MS="$STRAND_NOW_MS" \
  ZDOC_SESSION_PROJECT_ROOT="$STRAND_PROJECT" \
  ZENSU_DOCTOR_PLUGIN_DIR="$BADINERT" ZENSU_CONFIG="" CLAUDE_PROJECT_DIR="$STRAND_PROJECT" \
  node "$BADINERT/hooks/lib/zensu-doctor-report.js" 2>/dev/null)"
case "$OUT_BADINERT" in
  *'exports no usable inert-shape set'*'missing check, not an all-clear'*)
    check "P1ms3 an unusable inert-shape export is disclosed, not withheld silently" PASS ;;
  *) check "P1ms3 an unusable inert-shape export is disclosed, not withheld silently (got: $OUT_BADINERT)" FAIL ;;
esac
case "$OUT_BADINERT" in
  *"$STRAND_PHRASE"*) check "P1ms4 an unusable inert-shape export never renders the row itself" FAIL ;;
  *) check "P1ms4 an unusable inert-shape export never renders the row itself" PASS ;;
esac

if grep -vE '^[[:space:]]*//' "$REPORT" | grep -qF 'chain.INERT_SHAPES' \
  && ! grep -vE '^[[:space:]]*//' "$REPORT" | grep -qE "'no-session'|\"no-session\"" \
  && ! grep -vE '^[[:space:]]*//' "$REPORT" | grep -qE "'chain-closed'|\"chain-closed\""; then
  check "P1ms1 the renderer consumes the owner's inert set and keeps no private copy" PASS
else
  check "P1ms1 the renderer consumes the owner's inert set and keeps no private copy" FAIL
fi
# A wedged or dead-end chain carries its own remedy row. The foreign-open push
# must come BELOW those early returns, or one truncated key is named twice with
# contradictory instructions.
STRAND_ORDER="$(awk '
  /if \(report\.deadEnd\)/ && !d { d = NR }
  /if \(report\.wedged\)/ && !w { w = NR }
  /^ *return;/ { r[NR] = 1 }
  /foreignOpen\.push/ && !p { p = NR }
  END {
    if (!d || !w || !p) { print "missing"; exit }
    if (!(d < w && w < p)) { print "order"; exit }
    for (i = d; i < w; i++) if (r[i]) rd = 1
    for (i = w; i < w + 6 && i < p; i++) if (r[i]) rw = 1
    print (rd && rw) ? "ok" : "no-return"
  }' "$REPORT")"
[ "$STRAND_ORDER" = ok ] \
  && check "P1ms2 both early returns stand between the shape branches and the push" PASS \
  || check "P1ms2 both early returns stand between the shape branches and the push ($STRAND_ORDER)" FAIL

# FR-005: the row's wording is a three-way hand copy (renderer, skill, docs).
# Every other row family in this suite is pinned on both sides; so is this one.
STRAND_DOC_OK=1
for phrase in 'open chain(s) not owned by this session' 'cannot be moved to this key'; do
  grep -qF -- "$phrase" "$REPORT" || STRAND_DOC_OK=0
done
grep -qF -- 'open chain(s) not owned by this session' "$SKILL_MD" || STRAND_DOC_OK=0
grep -qF -- 'open chain(s) not owned by this session' "$PLUGIN_DIR/docs/session-control.md" || STRAND_DOC_OK=0
[ "$STRAND_DOC_OK" -eq 1 ] \
  && check "P1mt the row wording is emitted AND documented in the skill and the docs" PASS \
  || check "P1mt the row wording is emitted AND documented in the skill and the docs" FAIL
# The diagnose-only limit is the one claim a reader must not lose: without it the
# remedy reads as "there is a way to move the chain", and there is not.
if grep -qF 'cannot be moved' "$SKILL_MD" \
  && grep -qF 'does not apply — it repairs a lineage' "$SKILL_MD" \
  && grep -qF 'cannot be moved' "$PLUGIN_DIR/docs/session-control.md"; then
  check "P1mt1 both operator documents carry the diagnose-only limit" PASS
else
  check "P1mt1 both operator documents carry the diagnose-only limit" FAIL
fi
# Same three-way hand copy for the parked-at-implementing row: renderer, skill,
# docs. Without this, rewording one carrier goes stale in silence.
PARKED_DOC_OK=1
grep -qF -- 'turns at `implementing`' "$REPORT" || PARKED_DOC_OK=0
grep -qF -- 'turns at `implementing`' "$SKILL_MD" || PARKED_DOC_OK=0
grep -qF -- 'Implementing-phase turn counter' "$PLUGIN_DIR/docs/tdd-manager-workflow.md" \
  || PARKED_DOC_OK=0
[ "$PARKED_DOC_OK" -eq 1 ] \
  && check "P1mt2 the implementing-turns row wording is emitted AND documented in the skill and the docs" PASS \
  || check "P1mt2 the implementing-turns row wording is emitted AND documented in the skill and the docs" FAIL
# The CAVEAT half, which nothing pinned. The row's NAME was held three ways while the clause
# that carries the refusal — the half AC-013 turns on — could be deleted from either carrier
# with every suite green, leaving the model relaying the row without the obligation to carry
# it. Both carriers are required, and the control proves each file was read.
P1MT4_R="$(grep -cF 'refused-spawn row below' "$REPORT" || true)"
P1MT4_S="$(grep -cF 'refused-spawn row below' "$SKILL_MD" || true)"
if [ "$P1MT4_R" -ge 1 ] && [ "$P1MT4_S" -ge 1 ]; then
  check "P1mt4 the caveat is present in the renderer AND documented in the skill" PASS
else
  check "P1mt4 the caveat is present in the renderer AND documented in the skill (renderer=$P1MT4_R skill=$P1MT4_S)" FAIL
fi
# P1mt5 — the row's OPENING clause, compared rather than described. The scoping correction
# reached the renderer and the Stop branch and missed the skill, which is the carrier a model
# relays; the unqualified form is a false statement about review coverage, because a flow like
# /zensu:cover spawns a reviewer without arming a chain. Extracted from the renderer and
# required in the skill, normalised for case and line wrapping the way C39 does.
# The pattern carries a `[a-z ]*` segment and the extracted side is lowercased, matching
# C39. A fixed whole-phrase needle tracked no reword at all: any change to the sentence
# emptied the extraction and failed P1mt5pre instead of comparing the NEW wording against
# the skill, which is the drift this pin exists to catch.
P1MT5_PHRASE="$(grep -o 'the review chain has[a-z ]*asked for a reviewer' "$REPORT" | head -1 | tr 'A-Z' 'a-z')"
[ -n "$P1MT5_PHRASE" ] \
  && check "P1mt5pre the row's scoped opening was located in the renderer, so the comparison is not vacuous" PASS \
  || check "P1mt5pre the row's scoped opening was located in the renderer, so the comparison is not vacuous" FAIL
P1MT5_OK=0
if [ -n "$P1MT5_PHRASE" ] && [ -r "$SKILL_MD" ]; then
  tr -s '[:space:]' ' ' < "$SKILL_MD" | tr 'A-Z' 'a-z' | grep -qF "$P1MT5_PHRASE" && P1MT5_OK=1
fi
[ "$P1MT5_OK" = "1" ] \
  && check "P1mt5 the skill carries the row's scoped opening, not the unqualified form" PASS \
  || check "P1mt5 the skill carries the row's scoped opening, not the unqualified form" FAIL
# The one claim a reader must not lose here is the NEGATIVE one: this row must
# never teach the zero-change terminus, which from shape `implementing` is the
# unqualified no-ticket terminus. Pin it on both carriers.
# EXTRACTED, not windowed. `-A 8` was written when the row was eight lines long; the
# statement runs from its `line(WARN,` to the `parkedImpl` append, and the refusal
# caveat added between them sat OUTSIDE the window — so a `--chain-done` introduced
# there would have passed. The slice is taken between the two anchors.
#
# The END anchor was `truncatedList(parkedImpl))` and moved when `parkedImpl` stopped
# being a one-element array. Note what that cost: the emptiness control PASSED, because
# a stale end anchor does not empty the slice — it runs it to end of file, which swept in
# a `--chain-done` from an unrelated row and turned the negative assertion red. So the
# control guards the START anchor only; a stale END anchor fails loudly here instead,
# and both directions are the reason this is a slice rather than a window.
P1MT3_ROW="$(awk '/line\(WARN, .chain: this session owns a chain/{f=1} f{print} f&&/\+ parkedImpl\);/{exit}' "$REPORT")"
if [ -z "$P1MT3_ROW" ]; then
  check "P1mt3pre the implementing-turns row statement was located, so the scan is not vacuous" FAIL
else
  check "P1mt3pre the implementing-turns row statement was located, so the scan is not vacuous" PASS
fi
if ! printf '%s\n' "$P1MT3_ROW" | grep -qF -- '--chain-done' \
  && [ -n "$P1MT3_ROW" ] \
  && grep -qF 'Never offer the' "$SKILL_MD"; then
  check "P1mt3 the implementing-turns row never offers the zero-change terminus" PASS
else
  check "P1mt3 the implementing-turns row never offers the zero-change terminus" FAIL
fi

export CLAUDE_PROJECT_DIR="$CAS_PROJECT"

node -e '
  const fs=require("fs"), p=process.argv[1], j=JSON.parse(fs.readFileSync(p,"utf8"));
  j.reviewRound="7"; fs.writeFileSync(p, JSON.stringify(j));
' "$CAS_FILE"
OUT="$(run_report "$PLUGIN_DIR" "$SBOX/good-cfg.json" "$CAS_PROJECT")"
case "$OUT" in *'1 invalid CAS workflow document(s) — hooks fail closed'*"$(basename "$CAS_FILE")"*) check "P1mb malformed integrated integer is a fail-closed doctor error" PASS ;; *) check "P1mb malformed integrated integer fail-closed (got: $OUT)" FAIL ;; esac

# expired vs fresh pending-review.json
: > "$STATE_DIR_CANON/pending-review.json"
touch -t 202001010000 "$STATE_DIR_CANON/pending-review.json" 2>/dev/null
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
# The path is emitted SHELL-QUOTED and from the CANONICAL root, so the skill can
# use it verbatim and the "no symlinked component" claim covers the root itself.
# On macOS `mktemp -d` yields a path under /var/folders, and /var is a symlink to
# /private/var — so the expectation has to be the resolved spelling, not $SBOX.
STATE_DIR_REAL="$(cd -P -- "$STATE_DIR_CANON" && pwd -P)"
case "$OUT" in *'pending-review.json is'*'old (TTL'*"expired, safe to clear: '$STATE_DIR_REAL/pending-review.json'"*) check "P1n expired pending-review ⚠️ names the exact file it measured, shell-quoted" PASS ;; *) check "P1n expired pending-review ⚠️ names the exact file it measured, shell-quoted (got: $OUT)" FAIL ;; esac
: > "$STATE_DIR_CANON/pending-review.json"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in *'pending-review.json present and within'*) check "P1o fresh pending-review ✅" PASS ;; *) check "P1o fresh pending-review ✅ (got: $OUT)" FAIL ;; esac

# `0` DISABLES the guard everywhere else it is read. This row did not honour that,
# so every present marker read as expired — harmless until the row began naming a
# deletion target the skill acts on, at which point it offered a LIVE claim for
# removal.
: > "$STATE_DIR_CANON/pending-review.json"
touch -t 202001010000 "$STATE_DIR_CANON/pending-review.json" 2>/dev/null
OUT_TTL0PR="$(ZDOC_TTL_HOURS=0 run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT_TTL0PR" in
  *'its TTL guard is disabled'*) check "P1o1 a TTL of 0 disables the pending-review guard instead of expiring every marker" PASS ;;
  *) check "P1o1 a TTL of 0 disables the pending-review guard instead of expiring every marker (got: $OUT_TTL0PR)" FAIL ;;
esac
# Anchored, for the reason `strand_absent` exists: run_report discards stderr and the
# renderer exits 0 on any throw, so a bare absence check passes over a report that
# never rendered. Require the pending-review verdict itself before grading absence.
case "$OUT_TTL0PR" in
  *'pending-review.json'*) ;;
  *) check "P1o2 a disabled guard never offers a deletion target — VACUOUS: no pending-review verdict rendered" FAIL ;;
esac
case "$OUT_TTL0PR" in
  *'pending-review.json'*'safe to clear'*) check "P1o2 a disabled guard never offers a deletion target" FAIL ;;
  *'pending-review.json'*) check "P1o2 a disabled guard never offers a deletion target" PASS ;;
  *) ;;
esac

# The printed path is a deletion target the skill hands to `rm`. A symlinked
# component would point that outside the project, and `statSync` follows symlinks.
SYM_PROJECT="$SBOX/sym-project"; mkdir -p "$SYM_PROJECT/.zensu" "$SBOX/sym-real"
ln -s "$SBOX/sym-real" "$SYM_PROJECT/.zensu/state" 2>/dev/null
: > "$SBOX/sym-real/pending-review.json"
touch -t 202001010000 "$SBOX/sym-real/pending-review.json" 2>/dev/null
OUT_SYM="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$SYM_PROJECT")"
case "$OUT_SYM" in
  *'expired'*'The path is withheld'*) check "P1o3 a symlinked state directory withholds the deletion target" PASS ;;
  *'expired, safe to clear'*) check "P1o3 a symlinked state directory withholds the deletion target (offered it)" FAIL ;;
  *) check "P1o3 a symlinked state directory withholds the deletion target (got: $OUT_SYM)" FAIL ;;
esac

# A shell-active character is now OFFERED, not withheld: the value is emitted
# single-quoted, where every byte but the quote is literal. The earlier policy was
# a character allowlist, which excluded `path.sep` — so on win32 no candidate could
# ever match and the cleanup was unreachable on that host — and excluded the space,
# so an ordinary `~/My Projects/...` was refused with a message blaming the user.
DQ_PROJECT="$SBOX/dq\$(id) project"; mkdir -p "$DQ_PROJECT/.zensu/state"
: > "$DQ_PROJECT/.zensu/state/pending-review.json"
touch -t 202001010000 "$DQ_PROJECT/.zensu/state/pending-review.json" 2>/dev/null
DQ_REAL="$(cd -P -- "$DQ_PROJECT/.zensu/state" && pwd -P)"
OUT_DQ="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$DQ_PROJECT")"
case "$OUT_DQ" in
  *"expired, safe to clear: '$DQ_REAL/pending-review.json'"*) check "P1o4 a shell-active character and a space are quoted, not refused" PASS ;;
  *) check "P1o4 a shell-active character and a space are quoted, not refused (got: $OUT_DQ)" FAIL ;;
esac
# The quoting is what makes that safe, so pin the quoting itself rather than only
# the presence of the path: an unquoted emission would satisfy a bare path match.
case "$OUT_DQ" in
  *"safe to clear: '"*) check "P1o4a the offered path is single-quoted" PASS ;;
  *) check "P1o4a the offered path is single-quoted (got: $OUT_DQ)" FAIL ;;
esac

# A control byte is still refused. Quoting would make it harmless to the shell,
# but it would corrupt the report line a model reads back.
CTRL_DIR="$(printf '%s/ctrl\tproject' "$SBOX")"
if mkdir -p "$CTRL_DIR/.zensu/state" 2>/dev/null; then
  : > "$CTRL_DIR/.zensu/state/pending-review.json"
  touch -t 202001010000 "$CTRL_DIR/.zensu/state/pending-review.json" 2>/dev/null
  OUT_CTRL="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$CTRL_DIR")"
  case "$OUT_CTRL" in
    *'withheld because its path carries a control character'*) check "P1o4b a control byte in the path withholds the deletion target" PASS ;;
    *'safe to clear'*) check "P1o4b a control byte in the path withholds the deletion target (offered it)" FAIL ;;
    *) check "P1o4b a control byte in the path withholds the deletion target (got: $OUT_CTRL)" FAIL ;;
  esac
else
  check "P1o4b a control byte in the path withholds the deletion target (SKIP: filesystem refused the name)" PASS
fi

# The `nlink === 1` arm. A hard-linked marker is refused because the confirmed `rm`
# would leave the other name behind while the report claimed the file was cleared.
HL_PROJECT="$SBOX/hardlink-project"; mkdir -p "$HL_PROJECT/.zensu/state"
: > "$HL_PROJECT/.zensu/state/pending-review.json"
if ln "$HL_PROJECT/.zensu/state/pending-review.json" "$SBOX/hardlink-twin" 2>/dev/null; then
  touch -t 202001010000 "$HL_PROJECT/.zensu/state/pending-review.json" 2>/dev/null
  OUT_HL="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$HL_PROJECT")"
  case "$OUT_HL" in
    *'withheld because it has more than one hard link'*) check "P1o5 a hard-linked marker withholds the deletion target" PASS ;;
    *'safe to clear'*) check "P1o5 a hard-linked marker withholds the deletion target (offered it)" FAIL ;;
    *) check "P1o5 a hard-linked marker withholds the deletion target (got: $OUT_HL)" FAIL ;;
  esac
else
  check "P1o5 a hard-linked marker withholds the deletion target (SKIP: filesystem has no hard links)" PASS
fi

# The marker's OWN `ts` decides its age, matching `_tdd_pending_file_stale`. Reading
# the mtime alone let this row call a marker expired that the Stop enforcer still
# treats as live. The file is BACKDATED and carries a fresh `ts`: mtime alone says
# expired, `ts` says fresh, so only the correct reader renders the fresh row.
TS_PROJECT="$SBOX/ts-project"; mkdir -p "$TS_PROJECT/.zensu/state"
printf '{"ts":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TS_PROJECT/.zensu/state/pending-review.json"
touch -t 202001010000 "$TS_PROJECT/.zensu/state/pending-review.json" 2>/dev/null
OUT_TS="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$TS_PROJECT")"
case "$OUT_TS" in
  *'pending-review.json present and within'*) check "P1o6 the marker's own ts outranks the filesystem mtime" PASS ;;
  *) check "P1o6 the marker's own ts outranks the filesystem mtime (got: $OUT_TS)" FAIL ;;
esac
# The fallback still works: no `ts` at all, and the backdated mtime decides.
NOTS_PROJECT="$SBOX/nots-project"; mkdir -p "$NOTS_PROJECT/.zensu/state"
printf '{}' > "$NOTS_PROJECT/.zensu/state/pending-review.json"
touch -t 202001010000 "$NOTS_PROJECT/.zensu/state/pending-review.json" 2>/dev/null
OUT_NOTS="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$NOTS_PROJECT")"
case "$OUT_NOTS" in
  *'expired'*) check "P1o6a a marker without ts still ages on the filesystem mtime" PASS ;;
  *) check "P1o6a a marker without ts still ages on the filesystem mtime (got: $OUT_NOTS)" FAIL ;;
esac

# --- host-refused reviewer spawn note --------------------------------------
# Only the Stop chain-enforcer can see the refusal (it reads the transcript this
# diagnostic never gets), so the note it leaves is the sole way doctor can name
# the cause. An unreadable note must still be counted, never silently dropped.
# The renderer takes the accepted kinds from the module that writes them, so the
# sandbox plugin root needs it; a root without it is exercised at P1qf.
mkdir -p "$SBOX/plug/hooks/lib"
cp "$PLUGIN_DIR/hooks/lib/reviewer-spawn-denial-v1.js" "$SBOX/plug/hooks/lib/reviewer-spawn-denial-v1.js"
DENY_KEY_A="scv1_$(printf '%064d' 0)"
DENY_KEY_B="scv1_$(printf '%063d' 0)a"
NOTE_A="$STATE_DIR_CANON/reviewer-spawn-denied-${DENY_KEY_A}.json"
NOTE_B="$STATE_DIR_CANON/reviewer-spawn-denied-${DENY_KEY_B}.json"
NOW_MS="$(node -e 'process.stdout.write(String(Date.now()))')"
note_json() { printf '{"schemaVersion":%s,"kind":"%s","subagentType":"zensu:code-reviewer","detectedAtMs":%s}\n' "$1" "$2" "${3:-$NOW_MS}"; }
# A note counts only when a workflow document for the SAME session sits beside
# it. Without that binding the note stands entirely on its own contents — and
# this directory is writable from inside the session, so anything able to write
# here could mint a row telling the user to widen permissions for the very spawn
# it wants. Every fixture below plants the sibling; the unbound case is pinned on
# its own at P1qq.
deny_session_doc() { : > "$STATE_DIR_CANON/tdd-phase-$1.json"; }
deny_session_doc "$DENY_KEY_A"
deny_session_doc "$DENY_KEY_B"
note_json 1 auto-mode-classifier > "$NOTE_A"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in
  *'1 session(s) where the host permission layer refused the zensu:code-reviewer spawn (auto-mode-classifier×1)'*)
    case "$OUT" in
      *'"Agent(zensu:code-reviewer)"'*) check "P1q refused reviewer spawn is reported with its remedy rule" PASS ;;
      *) check "P1q refused reviewer spawn names the remedy rule (got: $OUT)" FAIL ;;
    esac ;;
  *) check "P1q refused reviewer spawn ⚠️ (got: $OUT)" FAIL ;;
esac
# A file this plugin did not write must never be counted as a refusal: an empty
# planted note would otherwise manufacture a row telling the user to widen
# permissions. It is reported separately instead.
printf 'not json\n' > "$NOTE_B"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in
  *'1 session(s) where the host permission layer refused'*'1 reviewer-spawn note(s) this plugin did not write'*)
    check "P1qa an unreadable note is reported separately, never as a refusal" PASS ;;
  *) check "P1qa unreadable note is not a refusal (got: $OUT)" FAIL ;;
esac
note_json 1 permission-denied > "$NOTE_B"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in *'auto-mode-classifier×1, permission-denied×1'*) check "P1qc the second host kind renders as its own kind" PASS ;; *) check "P1qc second host kind (got: $OUT)" FAIL ;; esac
# The note sits in a directory the session itself can write, so its `kind` is
# untrusted: a value outside the writer's own closed set is rejected, and the
# tally is prototype-free so such a key can never become the count.
note_json 1 constructor > "$NOTE_B"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in
  *'native code'*|*'constructor×'*) check "P1qd a kind outside the closed set is rejected, not rendered (got: $OUT)" FAIL ;;
  *'auto-mode-classifier×1)'*'1 reviewer-spawn note(s) this plugin did not write'*) check "P1qd a kind outside the closed set is rejected, not rendered" PASS ;;
  *) check "P1qd a kind outside the closed set is rejected, not rendered (got: $OUT)" FAIL ;;
esac
# The writer emits an EMPTY kind for a refusal whose form it could not classify.
# Rejecting it would tell the user to delete the note describing a refusal the
# block reason had just named correctly.
note_json 1 '' > "$NOTE_B"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in
  *'2 session(s) where the host permission layer refused'*'auto-mode-classifier×1, unclassified×1'*) check "P1ql an unclassified kind keeps its row, labelled rather than rejected" PASS ;;
  *) check "P1ql unclassified kind keeps its row (got: $OUT)" FAIL ;;
esac
note_json 2 auto-mode-classifier > "$NOTE_B"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in *'1 reviewer-spawn note(s) this plugin did not write'*) check "P1qe a note from an unknown schema version is not read as v1" PASS ;; *) check "P1qe unknown schema version (got: $OUT)" FAIL ;; esac
# The enforcer retires its own note, but a session that never Stops again cannot
# — so an old note must age out instead of warning forever.
note_json 1 auto-mode-classifier 1 > "$NOTE_B"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in *'1 reviewer-spawn refusal note(s) older than'*'safe to delete'*) check "P1qg a note older than the TTL ages out instead of warning forever" PASS ;; *) check "P1qg stale note ages out (got: $OUT)" FAIL ;; esac
# A TTL of 0 DISABLES the age-out (docs/configuration.md). Reading it as
# "everything is instantly stale" would suppress the one actionable row.
OUT="$(ZDOC_TTL_HOURS=0 run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in
  *'older than 0h'*) check "P1qh a TTL of 0 disables the age-out rather than staling every note (got: $OUT)" FAIL ;;
  *'2 session(s) where the host permission layer refused'*) check "P1qh a TTL of 0 disables the age-out rather than staling every note" PASS ;;
  *) check "P1qh a TTL of 0 disables the age-out (got: $OUT)" FAIL ;;
esac
# The TTL comparison was one-sided: a negative age never exceeds the bound, so a
# timestamp the writer could not have produced made the note immortal and kept
# recommending a permission change for a refusal that is not current. Reachable
# without an attacker — a clock stepped backwards does it. Stale is the honest
# bucket; that row's own text already says the note describes nothing current.
note_json 1 auto-mode-classifier "$((NOW_MS + 86400000))" > "$NOTE_B"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in
  *'1 session(s) where the host permission layer refused'*'1 reviewer-spawn refusal note(s) older than'*)
    check "P1qm a timestamp in the future ages out instead of living forever" PASS ;;
  *) check "P1qm future timestamp is not immortal (got: $OUT)" FAIL ;;
esac
# The TTL was sampled only at the extremes — now and the epoch — so the bound
# itself was never exercised and a `>` flipped to `>=`, or an off-by-one-hour
# error in the division, would have stayed green. These two drive a FIXED clock
# so the cases sit exactly on and exactly past the boundary rather than racing
# the wall clock. ZDOC_NOW_MS is the override the pending-review checks below
# already rely on.
TTL_BOUND_MS=$((NOW_MS - 6 * 3600000))
note_json 1 auto-mode-classifier "$TTL_BOUND_MS" > "$NOTE_B"
OUT="$(ZDOC_NOW_MS="$NOW_MS" run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in
  *'2 session(s) where the host permission layer refused'*)
    check "P1qn a note exactly at the TTL bound is still live" PASS ;;
  *) check "P1qn note at the TTL bound stays live (got: $OUT)" FAIL ;;
esac
note_json 1 auto-mode-classifier "$((TTL_BOUND_MS - 1))" > "$NOTE_B"
OUT="$(ZDOC_NOW_MS="$NOW_MS" run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in
  *'1 reviewer-spawn refusal note(s) older than'*)
    check "P1qo one millisecond past the TTL bound ages out" PASS ;;
  *) check "P1qo one ms past the TTL bound is stale (got: $OUT)" FAIL ;;
esac
# `isFinite` would coerce a quoted timestamp into a fresh one and count a note
# the writer never wrote as a live refusal; `Number.isFinite` rejects it.
printf '{"schemaVersion":1,"kind":"auto-mode-classifier","subagentType":"zensu:code-reviewer","detectedAtMs":"%s"}\n' "$NOW_MS" > "$NOTE_B"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in
  *'1 session(s) where the host permission layer refused'*'1 reviewer-spawn note(s) this plugin did not write'*)
    check "P1qi a string timestamp is rejected, not coerced into a live refusal" PASS ;;
  *) check "P1qi string timestamp rejected (got: $OUT)" FAIL ;;
esac
# The row advertises an oversize and a hard-link refusal; both were unexercised.
head -c 5000 /dev/zero | tr '\0' 'x' > "$NOTE_B"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in *'1 reviewer-spawn note(s) this plugin did not write'*) check "P1qj an oversized note is rejected, not read" PASS ;; *) check "P1qj oversized note rejected (got: $OUT)" FAIL ;; esac
rm -f "$NOTE_B"
# Linking A to B raises nlink on BOTH, so both are refused — a note the writer
# minted is single-linked by construction.
if ln "$NOTE_A" "$NOTE_B" 2>/dev/null; then
  OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
  case "$OUT" in
    *'host permission layer refused'*) check "P1qk a hard-linked note is rejected, not counted (got: $OUT)" FAIL ;;
    *'2 reviewer-spawn note(s) this plugin did not write'*) check "P1qk a hard-linked note is rejected, not counted" PASS ;;
    *) check "P1qk hard-linked note rejected (got: $OUT)" FAIL ;;
  esac
  rm -f "$NOTE_B"
else
  check "P1qk hard links unavailable on this filesystem — skipped" PASS
fi
# The binding itself: a perfectly well-formed note whose session has no workflow document
# beside it. Every other rejection case here is malformed in some way, so without this the
# accept path rested entirely on the note's own contents — and this directory is writable
# from inside the session, which makes "widen your permissions" a row an agent could
# manufacture for itself.
# HOISTED OUT of the hard-link guard above: it needs no hard link, only a fresh note and a
# removed workflow document, and while it sat inside that guard it vanished with no signal
# on any filesystem where `ln` fails — the suite simply reported one fewer check, all green.
# Same class as the mkfifo gating this round removed elsewhere.
note_json 1 auto-mode-classifier > "$NOTE_B"
rm -f "$STATE_DIR_CANON/tdd-phase-${DENY_KEY_B}.json"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in
  *'2 session(s) where the host permission layer refused'*)
    check "P1qq a well-formed note with no matching session is counted as a refusal (got: $OUT)" FAIL ;;
  *'1 session(s) where the host permission layer refused'*'1 reviewer-spawn note(s) this plugin did not write'*)
    check "P1qq a well-formed note with no matching session is rejected, not counted" PASS ;;
  *) check "P1qq unbound note rejected (got: $OUT)" FAIL ;;
esac
rm -f "$NOTE_B"
deny_session_doc "$DENY_KEY_B"
# A plugin root without the module must still report the refusal — losing the
# kind is acceptable, losing the row is not.
rm -f "$NOTE_B" "$SBOX/plug/hooks/lib/reviewer-spawn-denial-v1.js"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in *'1 session(s) where the host permission layer refused'*'unknown×1'*) check "P1qf a plugin root without the module still reports the refusal" PASS ;; *) check "P1qf missing module still reports the refusal (got: $OUT)" FAIL ;; esac
cp "$PLUGIN_DIR/hooks/lib/reviewer-spawn-denial-v1.js" "$SBOX/plug/hooks/lib/reviewer-spawn-denial-v1.js"
rm -f "$NOTE_A" "$NOTE_B"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in *'host permission layer refused'*) check "P1qb no note means no row" FAIL ;; *) check "P1qb no note means no row" PASS ;; esac

# The renderer and skills/doctor/SKILL.md are two hand-written accounts of the
# same three rows, and nothing tied them together: a row could be reworded and
# the skill would keep telling the model to report the old wording. Measured when
# this was written — the rejected row had already grown "no matching session"
# with no matching sentence in the skill.
#
# Each phrase is asserted on BOTH sides deliberately. Against the emitted output
# it catches this list going stale after a renderer reword, so a drift check can
# never pass by asserting a phrase nothing prints any more; against the skill it
# catches the documentation falling behind. The list is an independent third copy
# for the same reason git-repo-escape.test.js hardcodes its membership rather
# than importing the set it tests.
DENY_KEY_C="scv1_$(printf '%063d' 0)b"
NOTE_C="$STATE_DIR_CANON/reviewer-spawn-denied-${DENY_KEY_C}.json"
deny_session_doc "$DENY_KEY_C"
note_json 1 auto-mode-classifier > "$NOTE_A"
note_json 1 auto-mode-classifier 1 > "$NOTE_B"
printf 'not json\n' > "$NOTE_C"
ROWS_OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
SKILL_DOC="$PLUGIN_DIR/skills/doctor/SKILL.md"
ROW_UNEMITTED=""
ROW_DRIFT=""
while IFS= read -r row_phrase; do
  [ -n "$row_phrase" ] || continue
  case "$ROWS_OUT" in *"$row_phrase"*) ;; *) ROW_UNEMITTED="$ROW_UNEMITTED [$row_phrase]" ;; esac
  grep -qF "$row_phrase" "$SKILL_DOC" || ROW_DRIFT="$ROW_DRIFT [$row_phrase]"
done <<'ROW_PHRASES'
host permission layer refused the zensu:code-reviewer spawn
Agent(zensu:code-reviewer)
~/.claude/settings.json
reviewer-spawn refusal note(s) older than
reviewer-spawn note(s) this plugin did not write
no matching session
a deny rule outranks an allow rule
no agent may edit a settings file to widen its own permissions
ROW_PHRASES
if [ -z "$ROW_UNEMITTED" ] && [ -z "$ROW_DRIFT" ]; then
  check "P1qr every denial row phrase is both emitted and documented in the skill" PASS
else
  check "P1qr denial rows vs skill (not emitted:$ROW_UNEMITTED not documented:$ROW_DRIFT)" FAIL
fi
rm -f "$NOTE_A" "$NOTE_B" "$NOTE_C" "$STATE_DIR_CANON/tdd-phase-${DENY_KEY_C}.json"

# --- empty state dir -------------------------------------------------------
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$EMPTY_PROJECT")"
case "$OUT" in *'does not exist yet'*) check "P1p missing state dir handled read-only" PASS ;; *) check "P1p missing state dir handled (got: $OUT)" FAIL ;; esac

# --- summary escalation (❌ wins over ⚠️; ⚠️-only is "no blockers") --------
printf '{"plugins":[{"name":"zensu","version":"9.9.9"}]}\n' > "$SBOX/plug/.claude-plugin/marketplace.json"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$EMPTY_PROJECT")"
case "$OUT" in *'Summary:'*'resolve the ❌ items first'*) check "P1r summary escalates to ❌ when a red row exists" PASS ;; *) check "P1r summary ❌ (got: $OUT)" FAIL ;; esac
printf '{"plugins":[{"name":"zensu","version":"1.2.3"}]}\n' > "$SBOX/plug/.claude-plugin/marketplace.json"
# green plugin/config but absent tools (run_report injects absent) -> warn-only
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$EMPTY_PROJECT")"
case "$OUT" in *'Summary:'*'no blockers'*) check "P1s summary is warn-only (no blockers) when only ⚠️ rows exist" PASS ;; *) check "P1s summary warn-only (got: $OUT)" FAIL ;; esac

# --- state dir not writable -------------------------------------------------
# Probe whether chmod actually made the dir read-only; filesystems that ignore
# Unix mode bits (root, Windows git-bash, some network mounts) cannot simulate
# this branch, so skip the assertion there instead of failing spuriously.
RO_PROJECT="$SBOX/ro-project"; RO_ST="$RO_PROJECT/.zensu/state"
mkdir -p "$RO_ST"; : > "$RO_ST/tdd-phase-z.json"; chmod 0500 "$RO_ST" 2>/dev/null
if ( : > "$RO_ST/.wtest" ) 2>/dev/null; then
  rm -f "$RO_ST/.wtest" 2>/dev/null; chmod 0700 "$RO_ST" 2>/dev/null
  check "P1t state-not-writable ❌ (skipped: filesystem ignores mode bits)" PASS
else
  OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$RO_PROJECT")"; RC=$?
  chmod 0700 "$RO_ST" 2>/dev/null
  [ "$RC" -eq 0 ] && case "$OUT" in *'is not writable'*) check "P1t state-not-writable ❌ (exit 0)" PASS ;; *) check "P1t state-not-writable ❌ (got: $OUT)" FAIL ;; esac || check "P1t state-not-writable (rc=$RC)" FAIL
fi

# --- manifest degradation (missing / invalid / plugin not listed) ----------
mkdir -p "$SBOX/plug2/.claude-plugin" "$SBOX/plug2/hooks"
printf '{"hooks":{}}\n' > "$SBOX/plug2/hooks/hooks.json"
printf '{"plugins":[{"name":"zensu","version":"1.2.3"}]}\n' > "$SBOX/plug2/.claude-plugin/marketplace.json"
OUT="$(run_report "$SBOX/plug2" "$SBOX/good-cfg.json" "$EMPTY_PROJECT")"
case "$OUT" in *'plugin.json: missing'*) check "P1u plugin.json missing ❌" PASS ;; *) check "P1u plugin.json missing ❌ (got: $OUT)" FAIL ;; esac
printf '{"name":"zensu","version":"1.2.3"}\n' > "$SBOX/plug2/.claude-plugin/plugin.json"
rm -f "$SBOX/plug2/.claude-plugin/marketplace.json"
OUT="$(run_report "$SBOX/plug2" "$SBOX/good-cfg.json" "$EMPTY_PROJECT")"
case "$OUT" in *'marketplace.json: missing'*) check "P1v marketplace.json missing ⚠️" PASS ;; *) check "P1v marketplace.json missing ⚠️ (got: $OUT)" FAIL ;; esac
printf '{"plugins":[{"name":"other","version":"1.2.3"}]}\n' > "$SBOX/plug2/.claude-plugin/marketplace.json"
OUT="$(run_report "$SBOX/plug2" "$SBOX/good-cfg.json" "$EMPTY_PROJECT")"
case "$OUT" in *'not listed in marketplace.json'*) check "P1w plugin not listed ⚠️" PASS ;; *) check "P1w plugin not listed ⚠️ (got: $OUT)" FAIL ;; esac
printf '{"plugins":[{"name":"zensu","version":"1.2.3"}]}\n' > "$SBOX/plug2/.claude-plugin/marketplace.json"
printf '{bad json' > "$SBOX/plug2/hooks/hooks.json"
OUT="$(run_report "$SBOX/plug2" "$SBOX/good-cfg.json" "$EMPTY_PROJECT")"
case "$OUT" in *'hooks.json: invalid JSON'*) check "P1x hooks.json invalid ❌" PASS ;; *) check "P1x hooks.json invalid ❌ (got: $OUT)" FAIL ;; esac
# jsonFailure's DISCRIMINATING branch had no coverage at all: the three sites that consume
# it (plugin.json, marketplace.json, hooks.json) were only ever driven with missing or
# malformed files, where `io` is false, and the sole unreadable fixture in this suite drives
# the config site — which does not call the helper. Collapsing jsonFailure back to an
# unconditional "invalid JSON — " therefore left the whole suite green while three of four
# render sites went back to announcing a filesystem fault as a content fault.
printf '{bad json' > "$SBOX/plug2/hooks/hooks.json"
printf '{"name":"zensu","version":"1.2.3"}\n' > "$SBOX/plug2/.claude-plugin/plugin.json"
chmod 000 "$SBOX/plug2/.claude-plugin/plugin.json" 2>/dev/null || true
if [ -r "$SBOX/plug2/.claude-plugin/plugin.json" ]; then
  check "P1x1 SKIPPED — this principal can read a chmod 000 file, EACCES not producible" PASS
  check "P1x2 SKIPPED — same principal limitation" PASS
  check "P1x3 SKIPPED — same principal limitation" PASS
else
  UNREAD_PLUG_OUT="$(run_report "$SBOX/plug2" "$SBOX/good-cfg.json" "$EMPTY_PROJECT")"
  # Anchored by hand rather than through absent_row_out: that helper and $ANCHOR are both
  # defined several hundred lines BELOW this block, and calling it here made the check
  # vanish silently — bash reports command-not-found on stderr and no check is emitted at
  # all. A bare absence assertion is exactly what this round is removing, so the render
  # proof is spelled out instead: the sibling row that must still be there.
  case "$UNREAD_PLUG_OUT" in
    *'plugin.json: invalid JSON'*)
      check "P1x1 an unreadable plugin.json must not be announced as invalid JSON" FAIL ;;
    *'hooks.json:'*)
      check "P1x1 an unreadable plugin.json is not announced as invalid JSON" PASS ;;
    *) check "P1x1 (report never rendered — no Plugin integrity row in output)" FAIL ;;
  esac
  # Positive control: the finding survives the reword and still names the operation.
  case "$UNREAD_PLUG_OUT" in *'plugin.json: unreadable ('*)
    check "P1x2 an unreadable plugin.json is still reported, with its operation" PASS ;;
    *) check "P1x2 unreadable plugin.json lost its row (got: $UNREAD_PLUG_OUT)" FAIL ;; esac
  # Discrimination: the sibling site whose file is merely malformed keeps the content wording.
  case "$UNREAD_PLUG_OUT" in *'hooks.json: invalid JSON'*)
    check "P1x3 a malformed sibling still renders the content wording" PASS ;;
    *) check "P1x3 the malformed sibling lost its content wording" FAIL ;; esac
fi
chmod 644 "$SBOX/plug2/.claude-plugin/plugin.json" 2>/dev/null || true
printf '{"hooks":{}}\n' > "$SBOX/plug2/hooks/hooks.json"

# --- config-absent (defaults apply) ---------------------------------------
OUT="$(ZDOC_ZENSU=absent ZDOC_NODE=vT ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" HOME="$SBOX/nohome" CLAUDE_PROJECT_DIR="$SBOX/noproj" \
  node "$REPORT" 2>/dev/null)"
case "$OUT" in *'no config file present'*) check "P1y config-absent falls back to defaults ✅" PASS ;; *) check "P1y config-absent (got: $OUT)" FAIL ;; esac

# --- Session Control binding row ------------------------------------------
# The stateful-tool denial points the user at /zensu:doctor, so a session that
# cannot bind must say so instead of rendering an otherwise-green table.
run_report_binding() {
  ZDOC_ZENSU=absent ZDOC_NODE=vT ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" ZDOC_BINDING="$1" \
  ZDOC_BINDING_PROJECT_ROOT="${2:-}" \
    node "$REPORT" 2>/dev/null
}
OUT="$(run_report_binding bound)"
case "$OUT" in *'binding: this session has a valid Session Control record'*) check "P1ac bound session renders a ✅ binding row" PASS ;; *) check "P1ac bound session binding row (got: $OUT)" FAIL ;; esac
OUT="$(run_report_binding unbound)"
case "$OUT" in *'every stateful Zensu tool fails closed'*) check "P1ad unbound session renders a ❌ binding row" PASS ;; *) check "P1ad unbound session binding row (got: $OUT)" FAIL ;; esac
# A record whose recorded project root is gone is NOT the no-record state and
# must not be reported as one. Both sub-branches matter: with a path it renders
# the parenthesised directory the user has to re-create, and with the path
# unavailable it must still classify rather than fall back to a generic row.
OUT="$(run_report_binding orphaned-project-root /gone/worktree)"
case "$OUT" in
  *'the project root recorded for this session no longer exists (/gone/worktree)'*)
    case "$OUT" in
      *'has no valid Session Control record'*)
        check "P1ad1 orphaned root binding row (also claims no record: $OUT)" FAIL ;;
      *) check "P1ad1 an orphaned project root renders its own ❌ row naming the dead path" PASS ;;
    esac ;;
  *) check "P1ad1 orphaned root binding row (got: $OUT)" FAIL ;;
esac
OUT="$(run_report_binding orphaned-project-root)"
case "$OUT" in
  *'the project root recorded for this session no longer exists'*)
    case "$OUT" in
      *'no longer exists ('*) check "P1ad2 orphaned row without a path (stray parenthesis: $OUT)" FAIL ;;
      *) check "P1ad2 the orphaned row still classifies when the path is unavailable" PASS ;;
    esac ;;
  *) check "P1ad2 orphaned row without a path (got: $OUT)" FAIL ;;
esac
OUT="$(run_report_binding unavailable)"
case "$OUT" in *'zensu-session.sh is missing or symlinked'*) check "P1ae unavailable binder renders a ❌ binding row" PASS ;; *) check "P1ae unavailable binder binding row (got: $OUT)" FAIL ;; esac
OUT="$(run_report_binding unknown)"
case "$OUT" in *'binding:'*) check "P1af unknown binding stays silent instead of guessing" FAIL ;; *) check "P1af unknown binding stays silent instead of guessing" PASS ;; esac
OUT="$(run_report "$SBOX/plug" - "$EMPTY_PROJECT")"
case "$OUT" in *'binding:'*) check "P1ag an unset ZDOC_BINDING renders no binding row" FAIL ;; *) check "P1ag an unset ZDOC_BINDING renders no binding row" PASS ;; esac
if grep -qF 'zensu_bind_model_session' "$HELPER" && grep -qF 'ZDOC_BINDING=unknown' "$HELPER" \
  && grep -qF 'ZDOC_BINDING=unbound' "$HELPER"; then
  check "P1ah helper derives the binding row from the real model-side bind" PASS
else
  check "P1ah helper derives the binding row from the real model-side bind" FAIL
fi
if [ "$(grep -cF 'CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}"' "$SKILL_MD")" -ge 2 ]; then
  check "P1ai doctor skill passes CLAUDE_PLUGIN_DATA on every helper branch" PASS
else
  check "P1ai doctor skill passes CLAUDE_PLUGIN_DATA on every helper branch" FAIL
fi

# --- nested quoted boolean + __proto__ guard -------------------------------
printf '{"hooks":{"nested":{"flag":"true"}},"__proto__":{"x":"true"}}\n' > "$SBOX/nested-cfg.json"
OUT="$(run_report "$SBOX/plug" "$SBOX/nested-cfg.json" "$EMPTY_PROJECT")"
case "$OUT" in *'hooks.nested.flag = "true"'*) check "P1z nested quoted boolean ⚠️ (recursion)" PASS ;; *) check "P1z nested quoted boolean (got: $OUT)" FAIL ;; esac
case "$OUT" in *'__proto__'*) check "P1aa __proto__ key not reported (pollution guard)" FAIL ;; *) check "P1aa __proto__ key not reported (pollution guard)" PASS ;; esac

# --- reviewer-spawn permission exposure (proactive) -------------------------
# reviewerDenialRows is REACTIVE — it counts refusal notes the Stop enforcer
# already wrote, so it can only speak after a chain has wedged. These rows read
# the settings that DECIDE the refusal and report the exposure beforehand. The
# whole feature is bounded to ONE path, ~/.claude/settings.json: the
# project-local spelling sits inside the session root and is a path the agent
# itself could write, so naming it beside the rule that grants the refused
# capability would be an invitation (same reason stop-chain-enforcer.sh gives).
settings_home() { # settings_home <name> <settings.json body> -> echoes the home
  local h="$SBOX/home-$1"
  mkdir -p "$h/.claude" || return 1
  printf '%s\n' "$2" > "$h/.claude/settings.json" || return 1
  printf '%s' "$h"
}
# Always pass a CONCRETE config path. `run_report`'s `-` form leaves ZENSU_CONFIG
# empty, which makes configFiles() fall through to HOME — so with `-` this one
# variable would select both the settings file under test AND the zensu config.
run_report_home() { # run_report_home <home>
  ( HOME="$1"; run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$EMPTY_PROJECT" )
}
# Positive anchor for every ABSENCE assertion below. The renderer's outer
# `try { main(); } catch` discards the whole report and prints ONE line on any
# throw while still exiting 0, so "no permissions: row" is also what a crashed
# run looks like — and an exit-code guard cannot tell them apart. Every fixture
# here passes good-cfg.json, so this phrase must be in the output of a run that
# actually rendered. Without it these checks pass for the wrong reason.
ANCHOR='no quoted-boolean traps'
# Takes the fixture HOME, not a captured output, and runs the report itself. That
# ordering is the whole point: the anchor comes from ZENSU_CONFIG, NOT from HOME,
# so it renders even when HOME is empty — which is exactly what a failed
# `settings_home` produces, since its non-zero status is invisible inside
# `H_X="$(settings_home …)"`. Anchor plus exit status together still could not
# tell "the allow rule suppressed the row" from "the fixture was never written".
# Proving the fixture exists is the only check that can.
absent_row() { # absent_row <label> <fixture home> <needle>
  local label="$1" home="$2" needle="$3" out
  if [ -z "$home" ] || [ ! -s "$home/.claude/settings.json" ]; then
    check "$label (fixture home missing or empty: '${home:-<empty>}')" FAIL
    return
  fi
  out="$(run_report_home "$home")"
  case "$out" in
    *"$needle"*) check "$label (row present, expected absent)" FAIL ;;
    *"$ANCHOR"*) check "$label" PASS ;;
    *) check "$label (report never rendered — no anchor in output)" FAIL ;;
  esac
}
# For the three cases where the ABSENCE of a settings file is the fixture, so
# absent_row's existence check would be exactly wrong.
OK_ROW='permissions: no reviewer-spawn exposure found in ~/.claude/settings.json'
# The check now speaks on every path, so "renders no permissions row" is no longer a
# meaningful assertion — every report has one. What those checks were REALLY about is
# that no WARNING renders. This says exactly that, and requires the clean row as its own
# render anchor, so it is stronger than the `absent_row … 'permissions:'` form it
# replaces IN THAT DIMENSION: that form passed for a report that collapsed before the
# Config block. It is NOT strictly stronger — "strictly" was the earlier wording and it
# was wrong. `absent_row` opens with a fixture-existence guard and this helper carries
# none, deliberately: P1bq, P1bq1 and P1aw use an EMPTY or ABSENT settings file as the
# fixture, and a size guard would reject exactly those. The gap it leaves is narrow
# rather than open — an empty `$home` still renders the HOME-unset warning, which this
# helper fails on — but a fixture that was never written to an otherwise valid home
# would read as clean. Prefer `absent_row` where the fixture must be non-empty.
clean_row() { # clean_row <label> <fixture home>
  local label="$1" home="$2" out
  out="$(run_report_home "$home")"
  case "$out" in *'⚠️  permissions:'*)
    check "$label (a permissions warning rendered, expected none)" FAIL; return ;; esac
  case "$out" in *"$OK_ROW"*) check "$label" PASS ;;
    *) check "$label (clean row absent — the report may not have rendered at all)" FAIL ;; esac
}
clean_row_out() { # clean_row_out <label> <output>
  local label="$1" out="$2"
  case "$out" in *'⚠️  permissions:'*)
    check "$label (a permissions warning rendered, expected none)" FAIL; return ;; esac
  case "$out" in *"$OK_ROW"*) check "$label" PASS ;;
    *) check "$label (clean row absent — the report may not have rendered at all)" FAIL ;; esac
}
absent_row_out() { # absent_row_out <label> <output> <needle> [render-proof]
  local proof="${4:-$ANCHOR}"
  case "$2" in
    *"$3"*) check "$1 (row present, expected absent)" FAIL ;;
    *"$proof"*) check "$1" PASS ;;
    *) check "$1 (report never rendered — no proof '$proof' in output)" FAIL ;;
  esac
}

H_EXPOSED="$(settings_home exposed '{"permissions":{"defaultMode":"auto","allow":[]}}')"
OUT="$(run_report_home "$H_EXPOSED")"; RC=$?
EXPOSED_OUT="$OUT"
[ "$RC" -eq 0 ] && check "P1aj report still exits 0 with an exposure row" PASS || check "P1aj exposure fixture exit (rc=$RC)" FAIL
case "$OUT" in *'permission mode "auto" is set in ~/.claude/settings.json'*)
  check "P1ak auto mode without an Agent allow rule renders the exposure row" PASS ;;
  *) check "P1ak exposure row (got: $OUT)" FAIL ;; esac
case "$OUT" in *'Add "Agent(zensu:code-reviewer)" to permissions.allow in ~/.claude/settings.json yourself'*)
  check "P1al the exposure row names the exact remedy rule and the user-scoped file" PASS ;;
  *) check "P1al exposure row remedy (got: $OUT)" FAIL ;; esac
case "$OUT" in *'reports an exposure, never a prediction'*'settings sources this check does not read'*)
  check "P1am the exposure row carries both honesty qualifiers" PASS ;;
  *) check "P1am exposure row qualifiers (got: $OUT)" FAIL ;; esac

case "$OUT" in *'⚠️  permissions: permission mode "auto"'*)
  check "P1am1 the exposure row renders as ⚠️, not ❌ (the severity the skill documents)" PASS ;;
  *) check "P1am1 exposure row glyph (got: $OUT)" FAIL ;; esac

H_RULE="$(settings_home rule '{"permissions":{"defaultMode":"auto","allow":["Agent(zensu:code-reviewer)"]}}')"
clean_row "P1an the exact Agent(zensu:code-reviewer) allow rule suppresses every permissions warning" "$H_RULE"
H_BARE="$(settings_home bare '{"permissions":{"defaultMode":"auto","allow":["Agent"]}}')"
clean_row "P1ao the bare Agent allow rule suppresses the exposure row" "$H_BARE"
# The allow path exercises the SKIP, not a throw: it is called with padded=false,
# so no method is called on the element and a missing guard would just compare
# null === 'Agent'. The throw only happens on the trimming call sites, which is
# what P1ao4 below pins.
H_MIXED="$(settings_home mixed '{"permissions":{"defaultMode":"auto","allow":[null,42,{"a":1},"Agent(zensu:code-reviewer)"]}}')"
clean_row "P1ao1 non-string allow entries are skipped and the exact rule still grants" "$H_MIXED"
# Whether the host trims a rule string is UNVERIFIED against SETTINGS_SOURCE_BUILD,
# so the allow side compares untrimmed: a wrong guess there would SUPPRESS the
# warning, the direction that leaves no diagnosis. The deny/ask side trims, where
# a wrong guess only over-warns.
H_PAD="$(settings_home padded '{"permissions":{"defaultMode":"auto","allow":[" Agent(zensu:code-reviewer) "]}}')"
case "$(run_report_home "$H_PAD")" in *'permission mode "auto" is set'*)
  check "P1ao2 a whitespace-padded allow entry is not treated as a verified grant" PASS ;;
  *) check "P1ao2 padded allow entry must still warn" FAIL ;; esac
H_PAD_DENY="$(settings_home padded-deny '{"permissions":{"defaultMode":"auto","deny":[" Agent(zensu:code-reviewer) "],"allow":[]}}')"
case "$(run_report_home "$H_PAD_DENY")" in *'a permissions.deny entry'*)
  check "P1ao3 a whitespace-padded deny entry still matches (over-warning is the safe side)" PASS ;;
  *) check "P1ao3 padded deny entry must match" FAIL ;; esac
# The trimming call site is where a missing type guard THROWS. Without this the
# guard can be deleted and the whole suite stays green while the renderer
# collapses into its outer catch on any settings file with a non-string rule.
H_DENY_MIXED="$(settings_home deny-mixed '{"permissions":{"defaultMode":"auto","deny":[null,42,{"a":1},"Agent(zensu:code-reviewer)"],"allow":[]}}')"
case "$(run_report_home "$H_DENY_MIXED")" in *'a permissions.deny entry'*)
  check "P1ao4 a non-string deny entry is skipped rather than throwing on the trimming path" PASS ;;
  *) check "P1ao4 non-string deny entry collapsed the report" FAIL ;; esac
# Same hazard one predicate over: namesReviewerSpawn also calls .trim().
H_UNJ_MIXED="$(settings_home unjudge-mixed '{"permissions":{"defaultMode":"auto","deny":[null,42,"Agent(zensu:code-reviewer)*"],"allow":[]}}')"
case "$(run_report_home "$H_UNJ_MIXED")" in *'⚠️  permissions: a permissions.deny or permissions.ask entry'*'in a spelling this check has not verified'*)
  check "P1ao5 a non-string entry beside an unverified spelling does not throw" PASS ;;
  *) check "P1ao5 non-string entry collapsed the could-not-judge path" FAIL ;; esac
# An unverified spelling must NOT count as a grant: suppressing the warning is
# the failure direction that leaves the user with no diagnosis at all.
H_WILD="$(settings_home wild '{"permissions":{"defaultMode":"auto","allow":["Agent(*)","Bash"]}}')"
OUT="$(run_report_home "$H_WILD")"
case "$OUT" in *'permission mode "auto" is set'*) check "P1ap an unrecognized allow spelling still warns (never suppress on a guess)" PASS ;;
  *) check "P1ap unrecognized allow spelling (got: $OUT)" FAIL ;; esac

# deny is evaluated before ask and allow — so it is reported even WITH an allow
# rule present, and the exposure row (which is about a missing allow) stands down.
H_DENY="$(settings_home deny '{"permissions":{"defaultMode":"auto","deny":["Agent(zensu:code-reviewer)"],"allow":["Agent(zensu:code-reviewer)"]}}')"
DENY_OUT="$(run_report_home "$H_DENY")"
case "$DENY_OUT" in *'⚠️  permissions: a permissions.deny entry in ~/.claude/settings.json matches the zensu:code-reviewer spawn'*)
  check "P1aq a deny rule is reported even when an allow rule for the same spawn is present" PASS ;;
  *) check "P1aq deny row (got: $DENY_OUT)" FAIL ;; esac
case "$DENY_OUT" in *'adding a permissions.allow rule for this spawn changes nothing'*'that a refused-spawn report recommends'*)
  check "P1aq1 the deny row states it outranks the allow remedy, naming the rule rather than a row that may not print" PASS ;;
  *) check "P1aq1 deny row precedence clause (got: $DENY_OUT)" FAIL ;; esac
# P1ar needs a fixture where the deny branch's early return is the ONLY thing
# that can suppress the exposure row. With an allow rule co-present (H_DENY) the
# guard three lines further down suppresses it anyway, so deleting that return
# would leave the check green — it would pin nothing.
H_DENY_ONLY="$(settings_home deny-only '{"permissions":{"defaultMode":"auto","deny":["Agent(zensu:code-reviewer)"],"allow":[]}}')"
OUT="$(run_report_home "$H_DENY_ONLY")"
case "$OUT" in *'a permissions.deny entry'*) ;; *) check "P1ar precondition: the deny row must render (got: $OUT)" FAIL ;; esac
absent_row "P1ar the deny branch returns instead of stacking the exposure row" "$H_DENY_ONLY" 'permission mode "auto" is set'
# The renderer's comment claims deny and ask BOTH ignore the permission mode; the
# ask half is pinned by H_ASK below, and this is the deny half.
H_DENY_PLAIN="$(settings_home deny-plain '{"permissions":{"defaultMode":"default","deny":["Agent(zensu:code-reviewer)"]}}')"
case "$(run_report_home "$H_DENY_PLAIN")" in *'a permissions.deny entry'*)
  check "P1ar1 a deny rule is reported outside auto mode too" PASS ;;
  *) check "P1ar1 deny row outside auto mode" FAIL ;; esac

H_ASK="$(settings_home ask '{"permissions":{"defaultMode":"default","ask":["Agent(zensu:code-reviewer)"]}}')"
ASK_OUT="$(run_report_home "$H_ASK")"
case "$ASK_OUT" in *'⚠️  permissions: a permissions.ask entry in ~/.claude/settings.json matches the zensu:code-reviewer spawn'*)
  check "P1as an ask rule is reported regardless of the permission mode" PASS ;;
  *) check "P1as ask row outside auto mode" FAIL ;; esac
# deny is evaluated BEFORE ask; with only one rule per fixture, swapping the two
# branches would survive the whole suite.
H_BOTH="$(settings_home deny-and-ask '{"permissions":{"defaultMode":"auto","deny":["Agent(zensu:code-reviewer)"],"ask":["Agent(zensu:code-reviewer)"],"allow":[]}}')"
BOTH_OUT="$(run_report_home "$H_BOTH")"
case "$BOTH_OUT" in *'a permissions.deny entry'*) check "P1as2 deny is reported when deny and ask both match" PASS ;;
  *) check "P1as2 deny-before-ask (got: $BOTH_OUT)" FAIL ;; esac
absent_row "P1as3 the ask row does not also render when deny matched first" "$H_BOTH" 'a permissions.ask entry'
# An entry that plainly names the spawn in a spelling this check never verified
# must not fall through to the exposure row's allow remedy.
H_UNJUDGE="$(settings_home unjudgeable '{"permissions":{"defaultMode":"auto","deny":["Agent(zensu:code-reviewer)*"],"allow":[]}}')"
UNJ_OUT="$(run_report_home "$H_UNJUDGE")"
case "$UNJ_OUT" in *'⚠️  permissions: a permissions.deny or permissions.ask entry'*'in a spelling this check has not verified'*)
  check "P1as4 an unverified deny spelling renders the could-not-judge row" PASS ;;
  *) check "P1as4 unjudgeable deny row (got: $UNJ_OUT)" FAIL ;; esac
absent_row "P1as5 the could-not-judge row replaces the exposure row's allow remedy" "$H_UNJUDGE" 'permission mode "auto" is set'
# The ask half of that disjunct, and the ask side of the trim split — both were
# unreachable while every ask fixture used the exact, unpadded spelling.
H_ASK_UNJ="$(settings_home ask-unjudgeable '{"permissions":{"defaultMode":"auto","ask":["Agent(zensu:code-reviewer)*"],"allow":[]}}')"
case "$(run_report_home "$H_ASK_UNJ")" in *'⚠️  permissions: a permissions.deny or permissions.ask entry'*'in a spelling this check has not verified'*)
  check "P1as6 an unverified ask spelling also renders the could-not-judge row" PASS ;;
  *) check "P1as6 unverified ask spelling" FAIL ;; esac
H_ASK_PAD="$(settings_home ask-padded '{"permissions":{"defaultMode":"auto","ask":[" Agent(zensu:code-reviewer) "],"allow":[]}}')"
case "$(run_report_home "$H_ASK_PAD")" in *'a permissions.ask entry'*)
  check "P1as7 a whitespace-padded ask entry still matches" PASS ;;
  *) check "P1as7 padded ask entry must match" FAIL ;; esac
# Both allow-ward remedies must carry the deny-first caveat, because a deny this
# check cannot see or cannot judge outranks the rule they recommend.
CAVEAT_MISS=""
for h in "$H_ASK_PAD" "$H_EXPOSED"; do
  case "$(run_report_home "$h")" in *'a deny rule outranks an allow rule, so the deny has to go first'*) ;;
    *) CAVEAT_MISS="$CAVEAT_MISS ${h##*/}" ;; esac
done
if [ -z "$CAVEAT_MISS" ]; then
  check "P1as8 the ask row and the exposure row both carry the deny-first caveat" PASS
else
  check "P1as8 allow-ward remedies missing the deny-first caveat:$CAVEAT_MISS" FAIL
fi
# R3-S8's dead-code question: a present but unrelated deny array must leave the
# exposure row standing, which is also the only fixture reaching the loop-exhausted
# return in namesReviewerSpawn.
H_DENY_OTHER="$(settings_home deny-unrelated '{"permissions":{"defaultMode":"auto","deny":["Bash(rm:*)"],"allow":[]}}')"
case "$(run_report_home "$H_DENY_OTHER")" in *'permission mode "auto" is set'*)
  check "P1as9 a deny rule that names something else leaves the exposure row standing" PASS ;;
  *) check "P1as9 unrelated deny rule suppressed the exposure row" FAIL ;; esac
# Same discrimination as P1ar, for the ask branch's own return.
H_ASK_AUTO="$(settings_home ask-auto '{"permissions":{"defaultMode":"auto","ask":["Agent(zensu:code-reviewer)"],"allow":[]}}')"
OUT="$(run_report_home "$H_ASK_AUTO")"
case "$OUT" in *'a permissions.ask entry'*) ;; *) check "P1as1 precondition: the ask row must render (got: $OUT)" FAIL ;; esac
absent_row "P1as1 the ask branch returns instead of stacking the exposure row" "$H_ASK_AUTO" 'permission mode "auto" is set'
# Every row that INSTRUCTS a settings edit carries the prohibition, not only the two
# that happened to have it. The deny row says "Remove that entry yourself", the ask row
# says "Move the rule to permissions.allow yourself" (and appends DENY_FIRST_CAVEAT,
# a second widening instruction), and the could-not-judge row says "Read the entry
# yourself before adding any permissions.allow rule". These rows are printed verbatim
# by the model, so the row text is what has to carry the bar — a skill bullet does not
# survive paraphrase. `exposure` is the positive control: it already carries the
# sentence, so a needle typo shows up as all four failing rather than as three.
SELF_BAR='no agent may edit a settings file to widen its own permissions'
BAR_MISS=""
for pair in "exposure:$H_EXPOSED" "deny:$H_DENY_ONLY" "ask:$H_ASK_AUTO" "unjudgeable:$H_UNJUDGE"; do
  case "$(run_report_home "${pair#*:}")" in *"$SELF_BAR"*) ;;
    *) BAR_MISS="$BAR_MISS ${pair%%:*}" ;; esac
done
if [ -z "$BAR_MISS" ]; then
  check "P1bj every row instructing a settings edit carries the self-permission prohibition" PASS
else
  check "P1bj rows instructing a settings edit without the self-permission prohibition:$BAR_MISS" FAIL
fi
# An `Agent(`-shaped deny/ask entry that is not one of the two verified spellings used
# to match NO predicate at all — matchesDenyOrAskRule wants an exact spelling and
# namesReviewerSpawn wants the literal agent name — so the ladder fell through: to the
# WRONG remedy in auto mode, and to complete silence in every other mode. This is a
# reachable state, not a hypothetical: `Agent(*)` is valid host grammar (the rule parser
# is /^([^(]+)\(([^)]+)\)$/, and the host's own validator names "*" as a supported glob
# while restricting ":*" to Bash prefix rules). All three fixtures must reach the
# could-not-judge row, which asserts nothing about what the entry actually does.
UNVERIFIED_ROW='in a spelling this check has not verified'
H_WILD_DENY="$(settings_home wild-deny '{"permissions":{"defaultMode":"auto","deny":["Agent(*)"],"allow":[]}}')"
case "$(run_report_home "$H_WILD_DENY")" in *"$UNVERIFIED_ROW"*)
  check "P1bk an Agent(*) deny renders the could-not-judge row instead of falling through" PASS ;;
  *) check "P1bk Agent(*) deny fell through to the exposure row or to silence" FAIL ;; esac
# The silent half, and the one that matters most: outside auto mode the exposure row is
# gated off, so before this fix NOTHING printed for a deny that blocks every run.
H_WILD_PLAIN="$(settings_home wild-deny-plain '{"permissions":{"defaultMode":"default","deny":["Agent(*)"]}}')"
case "$(run_report_home "$H_WILD_PLAIN")" in *"$UNVERIFIED_ROW"*)
  check "P1bk1 an Agent(*) deny is reported outside auto mode too" PASS ;;
  *) check "P1bk1 Agent(*) deny rendered no row outside auto mode" FAIL ;; esac
# The worst case in the feature's own terms: the user did exactly what the doctor told
# them to do and holds the recommended allow rule, while the deny still outranks it.
H_WILD_GRANT="$(settings_home wild-deny-granted '{"permissions":{"defaultMode":"auto","deny":["Agent(*)"],"allow":["Agent(zensu:code-reviewer)"]}}')"
case "$(run_report_home "$H_WILD_GRANT")" in *"$UNVERIFIED_ROW"*)
  check "P1bk2 an Agent(*) deny beside the recommended allow rule is still reported" PASS ;;
  *) check "P1bk2 Agent(*) deny silenced by the grant it outranks" FAIL ;; esac
# An `Agent(` prefix must not be treated as a VERIFIED spelling — the deny row makes a
# strong claim ("every /zensu:tdd run wedges") and must keep firing only on the two
# spellings that were checked against a live permission decision.
absent_row "P1bk3 an Agent(*) deny does not fire the loud deny row" "$H_WILD_DENY" 'Deny is evaluated before ask and allow'
# The same gap on the other tool name. `Task(zensu:code-reviewer)` already matched by
# substring while a BARE `Task` matched nothing, so the treatment of Task rules was
# inconsistent by accident rather than by decision. reviewer-spawn-denial-v1.js exports
# SPAWN_TOOL_NAMES = ['Agent','Task'], so this repo's own code treats Task as a name the
# host uses for the spawn. Low-claim row only — the permission-rule spelling of Task is
# NOT verified against the host, which is exactly why it must not reach the loud row.
H_TASK_BARE="$(settings_home task-bare '{"permissions":{"defaultMode":"auto","deny":["Task"],"allow":[]}}')"
case "$(run_report_home "$H_TASK_BARE")" in *"$UNVERIFIED_ROW"*)
  check "P1bl a bare Task deny renders the could-not-judge row" PASS ;;
  *) check "P1bl bare Task deny fell through" FAIL ;; esac
H_TASK_WILD="$(settings_home task-wild '{"permissions":{"defaultMode":"default","ask":["Task(*)"]}}')"
case "$(run_report_home "$H_TASK_WILD")" in *"$UNVERIFIED_ROW"*)
  check "P1bl1 a Task(*) ask entry renders the could-not-judge row outside auto mode" PASS ;;
  *) check "P1bl1 Task(*) ask entry rendered no row" FAIL ;; esac
absent_row "P1bl2 a bare Task deny does not fire the loud deny row" "$H_TASK_BARE" 'Deny is evaluated before ask and allow'
# Discrimination: a tool name that merely STARTS with the same letters must not match.
H_TASKY="$(settings_home tasky '{"permissions":{"defaultMode":"auto","deny":["TaskRunner(build)"],"allow":[]}}')"
absent_row "P1bl3 an unrelated tool whose name starts with Task is not matched" "$H_TASKY" "$UNVERIFIED_ROW"
# The two shape-only arms are reachable ONLY for entries that provably do NOT contain
# REVIEWER_AGENT: the loop continues on the two verified spellings and returns on any
# entry containing the name, so an entry reaching `Agent(` or `Task` names something
# else. Saying it "names zensu:code-reviewer" is then a false statement about the
# user's file, and warnCount makes the green summary unreachable for that user. Every
# other fixture in this family uses a WILDCARD, which plausibly does cover the spawn —
# so a concrete unrelated agent is the only fixture that can tell the two cases apart.
H_OTHER_AGENT="$(settings_home other-agent '{"permissions":{"defaultMode":"auto","deny":["Agent(docs-writer)"],"allow":[]}}')"
OTHER_AGENT_OUT="$(run_report_home "$H_OTHER_AGENT")"
absent_row_out "P1bl4 a deny naming a DIFFERENT agent is not reported as naming the reviewer" "$OTHER_AGENT_OUT" 'names zensu:code-reviewer'
# Positive control: the entry must still be REPORTED — the fix is the wording, not silence.
case "$OTHER_AGENT_OUT" in *"$UNVERIFIED_ROW"*)
  check "P1bl5 a deny naming a different agent still renders the could-not-judge row" PASS ;;
  *) check "P1bl5 a deny naming a different agent fell through to silence" FAIL ;; esac
# The reduction establishes 'named' > 'shaped' ACROSS the two lists, but the predicate
# RETURNS at the first matching element, so within ONE list the earlier entry wins on
# position rather than on strength. A wildcard followed by an entry that really does name
# the reviewer then renders the weaker row — the mirror image of the defect the split was
# made to fix, and the skill tells the model to relay it as "names a DIFFERENT agent".
H_MIXED_LIST="$(settings_home mixed-list '{"permissions":{"defaultMode":"auto","deny":["Agent(*)","Agent(zensu:code-reviewer-canary)"],"allow":[]}}')"
MIXED_LIST_OUT="$(run_report_home "$H_MIXED_LIST")"
case "$MIXED_LIST_OUT" in *'names zensu:code-reviewer'*)
  check "P1bl7 a list whose LATER entry names the reviewer renders the stronger row" PASS ;;
  *) check "P1bl7 position, not strength, decided the row within one list" FAIL ;; esac
# The same list read the other way round must reach the same verdict.
H_MIXED_REV="$(settings_home mixed-list-rev '{"permissions":{"defaultMode":"auto","deny":["Agent(zensu:code-reviewer-canary)","Agent(*)"],"allow":[]}}')"
case "$(run_report_home "$H_MIXED_REV")" in *'names zensu:code-reviewer'*)
  check "P1bl8 the same list in the other order reaches the same verdict" PASS ;;
  *) check "P1bl8 the verdict depends on element order" FAIL ;; esac
# Discrimination: a list with ONLY shape-only entries must still get the weaker row.
case "$(run_report_home "$H_WILD_DENY")" in *'names zensu:code-reviewer'*)
  check "P1bl9 a shape-only list must not be promoted to the stronger row" FAIL ;;
  *) check "P1bl9 a shape-only list keeps the weaker row" PASS ;; esac
# The substring arm keeps the accurate wording: this entry really does name the reviewer.
H_NAMED_ODD="$(settings_home named-odd '{"permissions":{"defaultMode":"auto","deny":["Agent(zensu:code-reviewer:extra)"],"allow":[]}}')"
case "$(run_report_home "$H_NAMED_ODD")" in *'names zensu:code-reviewer'*)
  check "P1bl6 an entry that really does name the reviewer keeps the naming wording" PASS ;;
  *) check "P1bl6 the naming wording was lost for an entry that does name the reviewer" FAIL ;; esac
# settingsShape vets deny/ask as ARRAYS but never their elements, and both predicates
# silently skip a non-string — so a deny written as a list of objects read as "no deny
# rules" and the exposure row then recommended an allow rule while an unevaluated deny
# sat in the same file. That is the confidently-WRONG remedy the fatal/deferred split
# exists to remove, still open one level deeper.
# The cause is NOT an unverified spelling — a non-string entry names nothing — so it
# gets its own lead-in and shares the row's remedy tail. Asserting the spelling phrase
# here would have pinned a sentence that is false about this input.
UNREADABLE_ROW='contains an entry this check cannot read'
H_DENY_OBJ="$(settings_home deny-object '{"permissions":{"defaultMode":"auto","deny":[{"tool":"Agent"}],"allow":[]}}')"
DENY_OBJ_OUT="$(run_report_home "$H_DENY_OBJ")"
case "$DENY_OBJ_OUT" in *"$UNREADABLE_ROW"*)
  check "P1bm a deny list of non-string entries renders the could-not-read row" PASS ;;
  *) check "P1bm non-string deny entries yielded the allow remedy" FAIL ;; esac
absent_row "P1bm1 a non-string deny entry does not reach the exposure row's allow remedy" "$H_DENY_OBJ" 'permission mode "auto" is set'
H_ASK_NULL="$(settings_home ask-null '{"permissions":{"defaultMode":"default","ask":[null,42]}}')"
case "$(run_report_home "$H_ASK_NULL")" in *"$UNREADABLE_ROW"*)
  check "P1bm2 a non-string ask entry renders the could-not-read row outside auto mode" PASS ;;
  *) check "P1bm2 non-string ask entries rendered no row" FAIL ;; esac
# The two causes must stay distinguishable: an unverified SPELLING is a string this
# check read and declined to judge, which is a different thing to tell the user.
absent_row "P1bm4 the non-string cause does not claim an unverified spelling" "$H_DENY_OBJ" "$UNVERIFIED_ROW"
absent_row "P1bm5 an unverified spelling does not claim an unreadable entry" "$H_UNJUDGE" "$UNREADABLE_ROW"
# One `deferred` carrier meant a malformed autoMode.allow suppressed the EXPOSURE row —
# the feature's primary output — although that row's claim rests on permissions.allow
# and permissions.defaultMode, neither of which was the malformed key. P1az6 pinned only
# that the shape row is PRESENT, never that the exposure row is ABSENT, so the accepted
# asymmetry was undefended. Split the carrier: each row is suppressed only by a failure
# it actually depends on.
# Own fixtures rather than H_AMA / H_DEFER_EXPOSE: those are declared several hundred
# lines BELOW this block, so reusing them here silently runs against an empty home.
H_AMA_SPLIT="$(settings_home automode-allow-split '{"permissions":{"defaultMode":"auto"},"autoMode":{"allow":"nope"}}')"
AMA_SPLIT_OUT="$(run_report_home "$H_AMA_SPLIT")"
case "$AMA_SPLIT_OUT" in *'⚠️  permissions: ~/.claude/settings.json has a shape this check cannot judge — autoMode.allow is present but not an array'*)
  check "P1bn precondition: the autoMode.allow shape row still renders" PASS ;;
  *) check "P1bn autoMode.allow shape row (got: $AMA_SPLIT_OUT)" FAIL ;; esac
case "$AMA_SPLIT_OUT" in *'permission mode "auto" is set'*)
  check "P1bn1 a malformed autoMode.allow no longer suppresses the exposure row" PASS ;;
  *) check "P1bn1 malformed autoMode.allow still deletes the exposure row" FAIL ;; esac
# The other direction must keep holding: a malformed key the exposure row DOES depend on
# still suppresses it, because the claim would be unsupported.
H_EXPOSE_DEFER="$(settings_home expose-defer-split '{"permissions":{"defaultMode":"auto","allow":{}}}')"
absent_row "P1bn2 a malformed permissions.allow still suppresses the exposure row" "$H_EXPOSE_DEFER" 'permission mode "auto" is set'
# shapeRow's sentence is a WHOLE-check claim. At the fatal site it is true and the
# ladder returns. At the two deferred sites the deny, ask, could-not-judge and
# unreadable-entry branches all ran and judged, and neither branch returns — so the
# sentence can print directly beneath a substantive finding and contradict it, and with
# both carriers malformed it prints twice. skills/doctor/SKILL.md relays it verbatim.
WHOLE_CHECK='the reviewer-spawn permission check did not run'
absent_row_out "P1bn3 a deferred carrier scopes its claim to the row it could not determine" "$AMA_SPLIT_OUT" "$WHOLE_CHECK"
# Positive control: the row must still be REPORTED, and must still say what was malformed.
# ORDER matters here: the key name must appear in the row carrying the SCOPED tail. Matching
# the key alone was a strict substring of P1bn's own needle on the same captured output, so it
# could not fail independently — and a whole-check reversion would have satisfied it too,
# because shapeRow interpolates the same `err`.
case "$AMA_SPLIT_OUT" in *'autoMode.allow is present but not an array'*'could not be determined'*)
  check "P1bn4 the malformed key is named in the row carrying the scoped tail" PASS ;;
  *) check "P1bn4 the key name and the scoped tail are not in the same row" FAIL ;; esac
# Discrimination: the FATAL site keeps the whole-check wording, because there it is true.
H_ROOT_BAD="$(settings_home shape-root-bad '[]')"
case "$(run_report_home "$H_ROOT_BAD")" in *"$WHOLE_CHECK"*)
  check "P1bn5 the fatal shape row keeps the whole-check wording" PASS ;;
  *) check "P1bn5 the fatal shape row lost the whole-check wording" FAIL ;; esac
# Both carriers malformed. Two malformed keys deserve two rows — dropping one would hide
# a real defect in the user's file — but they must not be the SAME sentence twice, which
# is what a single whole-check wording produced. Assert distinctness, not scarcity.
H_BOTH_DEFER="$(settings_home defer-both '{"permissions":{"defaultMode":"auto","allow":{}},"autoMode":{"allow":"nope"}}')"
BOTH_OUT="$(run_report_home "$H_BOTH_DEFER")"
BOTH_N="$(printf '%s\n' "$BOTH_OUT" | grep -c 'has a shape this check cannot judge')"
BOTH_U="$(printf '%s\n' "$BOTH_OUT" | grep 'has a shape this check cannot judge' | sort -u | wc -l | tr -d ' ')"
if [ "$BOTH_N" = "2" ] && [ "$BOTH_U" = "2" ]; then
  check "P1bn6 two malformed carriers render two DISTINCT shape rows (got $BOTH_N rows, $BOTH_U distinct)" PASS
else
  check "P1bn6 two malformed carriers render two DISTINCT shape rows (got $BOTH_N rows, $BOTH_U distinct)" FAIL
fi
# Silence was the DEFAULT verdict of this check and the one verdict it could not
# qualify: every carrier of the "not an all-clear" doctrine hung off a row that
# printed, so in the ordinary case the reader saw nothing and a permission check that
# had been advertised in the skill frontmatter read as "checked, and fine". A row on
# every path makes the tool structurally unable to mislead instead of merely
# instructed not to. configBlock already uses this idiom two lines below the call.
H_QUIET="$(settings_home quiet '{"permissions":{"defaultMode":"default","allow":["Bash(ls)"]}}')"
QUIET_OUT="$(run_report_home "$H_QUIET")"
case "$QUIET_OUT" in *"$OK_ROW"*)
  check "P1bo a settings file with no reviewer-relevant rule still renders a permissions row" PASS ;;
  *) check "P1bo no row rendered for a clean settings file (got: $QUIET_OUT)" FAIL ;; esac
# The row must carry its own bound, or it becomes the all-clear it exists to prevent.
case "$QUIET_OUT" in *"$OK_ROW"*'only settings source this check reads'*'without being written there'*)
  check "P1bo1 the clean row states that it reads one file and that the mode need not be written there" PASS ;;
  *) check "P1bo1 clean row is missing its bound" FAIL ;; esac
# Severity is load-bearing: a ⚠️ here would inflate warnCount and turn every healthy
# report into "resolve the warnings first".
case "$QUIET_OUT" in *"✅  $OK_ROW"*)
  check "P1bo2 the clean row renders as ✅, not as a warning" PASS ;;
  *) check "P1bo2 clean row glyph" FAIL ;; esac
# It must not stack on top of a real finding.
absent_row "P1bo3 an exposed file gets the warning, not the clean row" "$H_EXPOSED" "$OK_ROW"
absent_row "P1bo4 a denied file gets the warning, not the clean row" "$H_DENY_ONLY" "$OK_ROW"
# An unset HOME is NOT a clean result — the check could not even locate its input, and
# saying nothing there is exactly the silence-reads-as-all-clear failure.
NOHOME_OUT="$( unset HOME; ZDOC_ZENSU=absent ZDOC_NODE="vTEST" ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" node "$REPORT" 2>/dev/null )"
case "$NOHOME_OUT" in *'the reviewer-spawn permission check did not run'*)
  check "P1bo5 an unset HOME renders a did-not-run row instead of silence" PASS ;;
  *) check "P1bo5 unset HOME still renders nothing (got: $NOHOME_OUT)" FAIL ;; esac
case "$NOHOME_OUT" in *"$OK_ROW"*) check "P1bo6 an unset HOME must not claim a clean result" FAIL ;;
  *) check "P1bo6 an unset HOME does not claim a clean result" PASS ;; esac
# A short read cannot be produced by an ordinary fixture — it needs readSync to return
# fewer bytes than fstat reported. A --require preload stubs exactly that. It reaches the
# settings reader and only it: readJson uses readFileSync, and readNoteJson has no note
# to read in an empty project, so readSettingsJson owns the first readSync call.
# Without the guard the truncated prefix is parsed and the failure is blamed on the
# file's CONTENTS — the mirror of the mislabel the !shape.ok branch guards against.
# FR-005's hoist (parse OUT of the I/O try) has exactly one externally visible effect:
# a CODE-LESS throw from openSync/fstatSync/readSync now reaches the I/O fall-through and
# renders `unreadable (unknown)`, where the pre-change shared try would have blamed the
# CONTENTS. Nothing asserted that arm, so restoring the old shared try plus its
# 'unparseable JSON' fall-through left the whole suite green. This is that missing bite.
THROWLESS_PRELOAD="$SBOX/throwless-read.js"
cat > "$THROWLESS_PRELOAD" <<'PRELOAD'
const fs = require('fs');
const realOpen = fs.openSync;
const realRead = fs.readSync;
let target = -1;
// Keyed on the FILE, not on call ordinality: a stub that counts calls silently relocates
// itself the moment any earlier reader gains a readSync, and the check would then pass or
// fail for a reason unrelated to its contract.
fs.openSync = function (path, ...rest) {
  const fd = realOpen.call(fs, path, ...rest);
  // Separator-agnostic: the renderer builds this path with path.join, which is
  // backslash-separated on win32, where a POSIX-only suffix test would never arm the stub —
  // the check would then fail for a reason unrelated to its contract while its two absence
  // siblings passed having tested nothing.
  if (String(path).replace(/\\/g, '/').endsWith('.claude/settings.json')) target = fd;
  return fd;
};
fs.readSync = function (fd, ...rest) {
  if (fd === target) {
    // Release the fd before throwing, so a later openSync that recycles the same number
    // cannot inherit the injection.
    target = -1;
    // No `code` property — this is the whole point of the fixture.
    throw new Error('synthetic read failure with no errno');
  }
  return realRead.call(fs, fd, ...rest);
};
PRELOAD
THROWLESS_OUT="$( HOME="$H_EXPOSED"; export HOME; ZDOC_ZENSU=absent ZDOC_NODE="vTEST" ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" \
  node --require "$THROWLESS_PRELOAD" "$REPORT" 2>&1 )"
case "$THROWLESS_OUT" in *'unreadable (unknown)'*)
  check "P1bu a code-less read failure is reported as an I/O fault, not a content fault" PASS ;;
  *) check "P1bu code-less read failure not routed to the I/O fall-through (got: $THROWLESS_OUT)" FAIL ;; esac
absent_row_out "P1bu1 a code-less read failure is not blamed on the file contents" "$THROWLESS_OUT" 'unparseable JSON'
# The synthetic message must never reach the report — same closed-vocabulary guarantee
# the settings reader carries everywhere else.
absent_row_out "P1bu2 the raw throw message does not reach the report" "$THROWLESS_OUT" 'synthetic read failure'
# A malformed autoMode CONTAINER is still FATAL, so it suppresses the deny, ask,
# could-not-judge and exposure rows — the very swallow the fatal/deferred split removed
# one level down for autoMode.allow. The deny below is perfectly readable and says every
# run wedges; the container's shape is no reason to withhold it.
H_AM_CONTAINER="$(settings_home automode-container '{"permissions":{"defaultMode":"auto","deny":["Agent(zensu:code-reviewer)"]},"autoMode":[]}')"
AM_CONTAINER_OUT="$(run_report_home "$H_AM_CONTAINER")"
case "$AM_CONTAINER_OUT" in *'Deny is evaluated before ask and allow'*)
  check "P1bv a malformed autoMode container must not suppress the deny row" PASS ;;
  *) check "P1bv a malformed autoMode container still swallows the deny row" FAIL ;; esac
# Positive control, on a fixture where no earlier row returns. The deny row above WINS
# and returns, exactly as it does over every other row in this ladder — so demanding the
# container also be named there would be demanding a special case the design does not have.
H_AM_CONT_BARE="$(settings_home automode-container-bare '{"permissions":{"defaultMode":"auto","allow":[]},"autoMode":[]}')"
AM_CONT_BARE_OUT="$(run_report_home "$H_AM_CONT_BARE")"
case "$AM_CONT_BARE_OUT" in *'autoMode is present but not an object'*)
  check "P1bv1 the malformed autoMode container is still named when no row outranks it" PASS ;;
  *) check "P1bv1 the malformed autoMode container is no longer reported (got: $AM_CONT_BARE_OUT)" FAIL ;; esac
# ...and the exposure row, whose claim does NOT depend on autoMode, still renders beside it.
case "$AM_CONT_BARE_OUT" in *'permission mode "auto" is set'*)
  check "P1bv1a a malformed autoMode container no longer suppresses the exposure row" PASS ;;
  *) check "P1bv1a a malformed autoMode container still deletes the exposure row" FAIL ;; esac
# Discrimination: a fatal key the ladder genuinely cannot proceed without stays fatal.
# The needle was ORIGINALLY the deny row, which this fixture can never produce under ANY
# implementation — an array root has no `permissions` key, so `perms.deny` is undefined and
# matchesDenyOrAskRule's Array.isArray guard answers false whether the root check is fatal,
# demoted or absent. Unfalsifiable, therefore worthless. The clean row IS a bite: demote the
# root check and the ladder emits nothing, so the wrapper renders the ✅ row.
# The variable is also renamed — `H_ROOT_ARR` is re-assigned several hundred lines below for
# P1az3, and reusing the name here left two fixtures one reordering apart from swapping.
H_SHAPE_ROOT_ARR="$(settings_home shape-root-arr '[1,2]')"
absent_row "P1bv2 a non-object settings root is fatal, so no clean row is claimed" "$H_SHAPE_ROOT_ARR" "$OK_ROW"
# readNoteJson's own comment says a short read would land this plugin's note in the
# "did not write it" row, but the loop has no read-completeness guard after it, so the
# failure the comment describes is still reachable. Its sibling gained exactly that guard.
NOTE_GUARD_N="$(awk '/^function readNoteJson\(/,/^}$/' "$REPORT" | grep -c 'read !== st.size')"
if [ "$NOTE_GUARD_N" -ge 1 ]; then
  check "P1bv3 readNoteJson carries the read-completeness guard its comment promises" PASS
else
  check "P1bv3 readNoteJson parses a partial buffer its own comment calls a defect" FAIL
fi
SHORT_PRELOAD="$SBOX/short-read.js"
cat > "$SHORT_PRELOAD" <<'PRELOAD'
const fs = require('fs');
const realOpen = fs.openSync;
const realRead = fs.readSync;
let target = -1;
// Keyed on the FILE, never on call ordinality. The earlier version keyed on `calls === 1`
// and rested on an assumption about which reader owns the first readSync — an assumption
// the config reader invalidated the moment it was hardened to use a bounded read loop.
// It then short-read the CONFIG file instead, and P1bp1 failed for a reason unrelated to
// its contract. Separator-agnostic for the same reason as the sibling preload.
fs.openSync = function (path, ...rest) {
  const fd = realOpen.call(fs, path, ...rest);
  if (String(path).replace(/\\/g, '/').endsWith('.claude/settings.json')) target = fd;
  return fd;
};
fs.readSync = function (fd, buf, off, len, pos) {
  // The injection must SURVIVE the whole read of this descriptor: readSettingsJson loops
  // until the buffer is full, so releasing after the first short read would let the second
  // call finish it and no short read would ever be observed. The sibling preload can
  // release immediately only because it THROWS. Release on close instead.
  if (fd === target && len > 6) return realRead.call(fs, fd, buf, off, len - 5, pos);
  if (fd === target) return 0;
  return realRead.call(fs, fd, buf, off, len, pos);
};
const realClose = fs.closeSync;
fs.closeSync = function (fd) {
  if (fd === target) target = -1;
  return realClose.call(fs, fd);
};
PRELOAD
SHORT_OUT="$( HOME="$H_EXPOSED"; export HOME; ZDOC_ZENSU=absent ZDOC_NODE="vTEST" ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" \
  node --require "$SHORT_PRELOAD" "$REPORT" 2>/dev/null )"
case "$SHORT_OUT" in *'incomplete (short read)'*)
  check "P1bp a short read is reported as an incomplete read" PASS ;;
  *) check "P1bp short read not detected (got: $SHORT_OUT)" FAIL ;; esac
absent_row_out "P1bp1 a short read is not blamed on the file's contents" "$SHORT_OUT" 'unparseable JSON'
# The new reason is a literal like every other one — no byte of the file may ride along.
case "$SHORT_OUT" in *'permissions'*'defaultMode'*)
  check "P1bp2 the incomplete-read reason must not echo settings content" FAIL ;;
  *) check "P1bp2 the incomplete-read reason carries no settings content" PASS ;; esac
# Two shapes this reader is stricter about than the consumer it models, and each turns a
# healthy setup into a scary did-not-run row. Alarm fatigue is the real cost: all three
# permission rows share the same prefix, so a user who learns to dismiss one dismisses
# the deny row too. An empty file is a plausible artefact of an interrupted write, and a
# BOM is what a Windows editor produces — JSON.parse rejects U+FEFF, which is a spec
# property, not a guess. No rules is a FACT about the settings, not a fault.
H_EMPTY_FILE="$SBOX/home-empty-settings"; mkdir -p "$H_EMPTY_FILE/.claude"; : > "$H_EMPTY_FILE/.claude/settings.json"
clean_row "P1bq a zero-byte settings file reads as no rules, not as a broken file" "$H_EMPTY_FILE"
H_WS="$SBOX/home-ws-settings"; mkdir -p "$H_WS/.claude"; printf '  \n\t\n' > "$H_WS/.claude/settings.json"
clean_row "P1bq1 a whitespace-only settings file reads as no rules" "$H_WS"
# A BOM must not hide a real finding: the fixture below IS exposed, so the exposure row
# has to survive the byte-order mark rather than degrade to a did-not-run row.
H_BOM="$SBOX/home-bom"; mkdir -p "$H_BOM/.claude"
printf '\357\273\277%s\n' '{"permissions":{"defaultMode":"auto","allow":[]}}' > "$H_BOM/.claude/settings.json"
BOM_OUT="$(run_report_home "$H_BOM")"
case "$BOM_OUT" in *'permission mode "auto" is set'*)
  check "P1bq2 a BOM-prefixed settings file is still parsed and still reports its exposure" PASS ;;
  *) check "P1bq2 BOM-prefixed settings (got: $BOM_OUT)" FAIL ;; esac
# 'could not be read' is now emitted only for an io:true class, which this small readable
# regular file can never reach — so the old needle passed with the BOM strip deleted. The
# reachable failure is the PARSE row, which is what a dropped strip actually produces.
absent_row_out "P1bq3 a BOM is not reported as a parse failure" "$BOM_OUT" 'could not be parsed'
# Discrimination: genuinely malformed content must STILL be reported. Relaxing the parse
# for empty and BOM must not turn every parse failure into a silent clean row.
H_BAD_SHAPE="$(settings_home bad-shape '{"permissions":{')"
absent_row "P1bq4 genuinely malformed JSON is still reported, not swallowed as no rules" "$H_BAD_SHAPE" "$OK_ROW"
# The settings buffer holds credential-bearing content, and allocUnsafe was safe only
# because toString is bounded by `read` rather than by st.size — one token standing
# between uninitialised process heap and a report the doctor skill tells the model to
# print verbatim, on a path (the short-read break) that no ordinary fixture reaches.
# Behavioural checks cannot see this, so it is pinned structurally.
# Comment lines are stripped before the scan. Without that the check reads the prose
# that EXPLAINS the divergence as if it were the divergence — the same comment-scanning
# trap P1bi carries, reproduced here while writing this very check.
RSJ_SRC="$(awk '/^function readSettingsJson\(/,/^}$/' "$REPORT" | grep -v '^[[:space:]]*//')"
case "$RSJ_SRC" in
  *allocUnsafe*) check "P1br the settings buffer must not be allocated unsafely" FAIL ;;
  *'Buffer.alloc('*) check "P1br the settings buffer is zero-initialised" PASS ;;
  *) check "P1br no Buffer allocation found in readSettingsJson — the scan is vacuous" FAIL ;;
esac
# readNoteJson keeps allocUnsafe on purpose: it reads this plugin's own note in the state
# directory, not the user's credential file, and the divergence is stated in-source.
# Pinning the count makes a later tree-wide sweep a decision rather than an accident.
UNSAFE_N="$(grep -v '^[[:space:]]*//' "$REPORT" | grep -cF 'Buffer.allocUnsafe' 2>/dev/null || true)"
# The count alone cannot support the claim in the label: an allocUnsafe that MOVES into a
# third reader keeps the total at one while "it is the note reader" quietly becomes false.
# Scope it to the receiver the way the sibling P1br does, and keep the total as a separate
# assertion so a SECOND one appearing anywhere is still caught.
UNSAFE_IN_NOTE="$(awk '/^function readNoteJson\(/,/^}$/' "$REPORT" | grep -v '^[[:space:]]*//' | grep -cF 'Buffer.allocUnsafe' || true)"
if [ "$UNSAFE_N" = "1" ] && [ "$UNSAFE_IN_NOTE" = "1" ]; then
  check "P1br1 exactly one Buffer.allocUnsafe remains, and it is inside readNoteJson" PASS
else
  check "P1br1 allocUnsafe: $UNSAFE_N in the renderer, $UNSAFE_IN_NOTE inside readNoteJson, expected 1 and 1" FAIL
fi
# ~310 lines were added inside a report whose outer handler discards the ENTIRE
# four-block table on any throw, while every other risky reader in this file is
# individually contained. No reachable throw is known — this pins the CONTAINMENT, so
# that being wrong once costs one degraded row instead of the whole diagnostic, for a
# user who ran the doctor precisely because something is already broken.
# The throw is injected surgically: JSON.parse is wrapped only for the fixture carrying
# the marker key, and the proxy throws on the first property read, which happens in
# settingsShape — outside every try in the reader.
THROW_PRELOAD="$SBOX/throw-on-shape.js"
cat > "$THROW_PRELOAD" <<'PRELOAD'
const realParse = JSON.parse;
JSON.parse = function (text) {
  const value = realParse(text);
  if (typeof text === 'string' && text.indexOf('__zensu_throw_marker__') !== -1) {
    return new Proxy(value, { get() { throw new Error('injected'); } });
  }
  return value;
};
PRELOAD
H_THROW="$(settings_home throw '{"__zensu_throw_marker__":1,"permissions":{"defaultMode":"auto","allow":[]}}')"
THROW_OUT="$( HOME="$H_THROW"; export HOME; ZDOC_ZENSU=absent ZDOC_NODE="vTEST" ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" \
  node --require "$THROW_PRELOAD" "$REPORT" 2>/dev/null )"; THROW_RC=$?
[ "$THROW_RC" -eq 0 ] && check "P1bs1 a throw inside the permission check still exits 0" PASS \
  || check "P1bs1 throw inside the permission check exit (rc=$THROW_RC)" FAIL
case "$THROW_OUT" in *"$ANCHOR"*)
  check "P1bs a throw inside the permission check does not discard the rest of the report" PASS ;;
  *) check "P1bs the whole report collapsed on a throw inside the permission check" FAIL ;; esac
case "$THROW_OUT" in *'permissions: the reviewer-spawn permission check failed to run'*)
  check "P1bs2 a throw is reported as one degraded row" PASS ;;
  *) check "P1bs2 no degraded row for a throw inside the permission check" FAIL ;; esac
# The degraded row must not claim a clean result either.
case "$THROW_OUT" in *"$OK_ROW"*) check "P1bs3 a throw must not claim a clean result" FAIL ;;
  *) check "P1bs3 a throw does not claim a clean result" PASS ;; esac
# The fixture above lands its throw on the FIRST property read, which is data.permissions
# inside settingsShape — so a wrapper narrowed to that one call would keep every check
# above green while a throw raised in matchesDenyOrAskRule, namesReviewerSpawn,
# hasUnreadableEntry or mentionsReviewerAgent escaped to the outer handler and discarded
# the whole four-block report. A second injection site is what makes the family test the
# WRAPPER rather than one call inside it.
THROW_DEEP_PRELOAD="$SBOX/throw-in-predicate.js"
cat > "$THROW_DEEP_PRELOAD" <<'PRELOAD'
const realParse = JSON.parse;
JSON.parse = function (text) {
  const value = realParse(text);
  if (typeof text === 'string' && text.indexOf('__zensu_deep_marker__') !== -1) {
    // The object itself reads normally; only an ELEMENT of the deny list throws, so the
    // failure lands inside a rule predicate, well past settingsShape.
    const deny = new Proxy(value.permissions.deny, {
      get(t, k) { if (k === '0') throw new Error('injected-deep'); return t[k]; }
    });
    value.permissions.deny = deny;
  }
  return value;
};
PRELOAD
H_THROW_DEEP="$(settings_home throw-deep '{"__zensu_deep_marker__":1,"permissions":{"defaultMode":"auto","deny":["x"],"allow":[]}}')"
THROW_DEEP_OUT="$( HOME="$H_THROW_DEEP"; export HOME; ZDOC_ZENSU=absent ZDOC_NODE="vTEST" ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" \
  node --require "$THROW_DEEP_PRELOAD" "$REPORT" 2>/dev/null )"; THROW_DEEP_RC=$?
case "$THROW_DEEP_OUT" in *'CLI & tooling'*'Plugin integrity'*'Config'*'Session state'*)
  check "P1bs4 a throw inside a rule predicate still leaves all four blocks intact" PASS ;;
  *) check "P1bs4 a throw inside a rule predicate discarded the report (rc=$THROW_DEEP_RC)" FAIL ;; esac
case "$THROW_DEEP_OUT" in *'failed to run'*)
  check "P1bs5 a throw inside a rule predicate is reported as a missing check" PASS ;;
  *) check "P1bs5 a throw inside a rule predicate rendered no containment row" FAIL ;; esac
absent_row_out "P1bs6 a throw inside a rule predicate does not claim a clean result" "$THROW_DEEP_OUT" "$OK_ROW"
# The sibling reader in the SAME block still echoed the raw parser message, which embeds
# a leading slice of its input — and configFiles() honours ZENSU_CONFIG as an
# unconstrained path override, so that variable can aim this reader at any file,
# including the settings file the hardened reader exists to protect. One reader in a
# block with a closed vocabulary and one without is not a policy.
# The decoy MUST sit inside the first ten characters. V8 quotes a ten-character window
# from the start of the input — `Unexpected token 's', "sk-CFGDECO"... is not valid JSON`
# — so a marker beginning at character eleven is cut off and the check passes while the
# leak is wide open. Measured on node v23.11.0; this exact off-by-one made the first
# version of this check vacuous.
CFG_DECOY="$SBOX/decoy-cfg.json"
printf '%s\n' 'DECOYSEC1 {"hooks":{' > "$CFG_DECOY"
CFG_OUT="$(run_report "$SBOX/plug" "$CFG_DECOY" "$EMPTY_PROJECT")"
case "$CFG_OUT" in *DECOYSEC1*)
  check "P1bt a malformed config file leaks its opening bytes into the report" FAIL ;;
  *) check "P1bt no byte of a malformed config file reaches the report" PASS ;; esac
# The parser's own phrasing is the carrier, so its absence is the second half of the
# guarantee — and it is what a future revert would trip over.
absent_row_out "P1bt2 the raw parser message does not reach the report" "$CFG_OUT" 'is not valid JSON' 'config: invalid JSON in'
# Discrimination: closing the leak must not silence the finding. The row still has to
# name the file, and a path is a fact about the filesystem, not about the contents.
case "$CFG_OUT" in *'invalid JSON in'*'(the whole file is ignored, defaults apply)'*)
  check "P1bt1a a non-capped failure KEEPS the loader verdict" PASS ;;
  *) check "P1bt1a the loader verdict was dropped from the parse class" FAIL ;; esac
case "$CFG_OUT" in *'invalid JSON in'*"$CFG_DECOY"*)
  check "P1bt1 a malformed config file is still reported, by path" PASS ;;
  *) check "P1bt1 malformed config file no longer reported (got: $CFG_OUT)" FAIL ;; esac
# The FR-011 retrofit widened readJson's vocabulary to include `unreadable (<code>)`, but
# all four render sites still hard-code an `invalid JSON` lead-in — so an EACCES prints as
# "invalid JSON — unreadable (EACCES)", announcing a content fault for a file that was
# never read. That is the same cause/operation mislabel FR-003 and FR-005 removed one
# reader over, reintroduced at the RENDER layer instead of the read layer.
CFG_NOREAD="$SBOX/noread-cfg.json"
printf '%s\n' '{"hooks":{}}' > "$CFG_NOREAD"
chmod 000 "$CFG_NOREAD" 2>/dev/null || true
if [ -r "$CFG_NOREAD" ]; then
  # Running as a principal that ignores the mode bits (root, or a host without them):
  # the fixture cannot produce EACCES, so the check would be vacuous. Say so.
  check "P1bt3 SKIPPED — this principal can read a chmod 000 file, EACCES not producible" PASS
  check "P1bt4 SKIPPED — same principal limitation" PASS
  check "P1bt5 SKIPPED — same principal limitation" PASS
else
  NOREAD_OUT="$(run_report "$SBOX/plug" "$CFG_NOREAD" "$EMPTY_PROJECT")"
  case "$NOREAD_OUT" in *'invalid JSON'*'unreadable ('*)
    check "P1bt3 an unreadable config file must not be announced as invalid JSON" FAIL ;;
    *) check "P1bt3 an unreadable config file is not announced as invalid JSON" PASS ;; esac
  # Positive control: the finding must survive the reword — the file still has to be named.
  case "$NOREAD_OUT" in *'unreadable ('*"$CFG_NOREAD"*|*"$CFG_NOREAD"*'unreadable ('*)
    check "P1bt4 an unreadable config file is still reported, by path and cause" PASS ;;
    *) check "P1bt4 unreadable config file lost its row (got: $NOREAD_OUT)" FAIL ;; esac
  # The EACCES class DOES make rd() fall back — readFileSync throws and it returns {} — so
  # this is the one io class that must KEEP the loader verdict. Nothing asserted it, and
  # when the flag was briefly missing from that return the row silently dropped to the
  # weaker check-limited wording with every check still green.
  case "$NOREAD_OUT" in *'unreadable ('*'the whole file is ignored, defaults apply'*)
    check "P1bt5 an unreadable config keeps the loader verdict" PASS ;;
    *) check "P1bt5 an unreadable config lost the loader verdict (got: $NOREAD_OUT)" FAIL ;; esac
fi
chmod 644 "$CFG_NOREAD" 2>/dev/null || true
# Discrimination, and the reason this must NOT be fatal: P1ao4's fixture mixes
# non-strings with a MATCHING string, and the deny row has to keep winning there.
case "$(run_report_home "$H_DENY_MIXED")" in *'Deny is evaluated before ask and allow'*)
  check "P1bm3 a matching string still wins over non-string siblings in the same list" PASS ;;
  *) check "P1bm3 non-string vetting displaced the deny row" FAIL ;; esac

# autoMode.allow is classifier guidance in prose, not a permission rule — the
# distinction this row exists to make, because writing one there LOOKS like a fix.
# The `$defaults` sentinel and the autoMode.allow key are the shape read off
# Claude Code SETTINGS_SOURCE_BUILD (see the constant in the renderer); a host
# that renames either makes this fixture describe a shape nothing produces.
H_AM="$(settings_home automode '{"permissions":{"defaultMode":"auto","allow":[]},"autoMode":{"allow":["$defaults",null,42,{"a":1},"Zensu review chain: allow zensu:code-reviewer spawns"]}}')"
AM_OUT="$(run_report_home "$H_AM")"
case "$AM_OUT" in *'⚠️  permissions: an autoMode.allow entry in ~/.claude/settings.json mentions'*'classifier guidance in prose — it is not a permission rule'*)
  check "P1at an autoMode.allow mention is reported as NOT a grant" PASS ;;
  *) check "P1at autoMode prose row (got: $AM_OUT)" FAIL ;; esac
case "$AM_OUT" in *'permission mode "auto" is set'*) check "P1au the autoMode mention does not suppress the exposure row" PASS ;;
  *) check "P1au autoMode mention suppression (got: $AM_OUT)" FAIL ;; esac
# The negative half: without it, a predicate that always matched would tell every
# auto-mode user that their non-existent autoMode entry does not grant the spawn,
# and every check in this file would stay green.
H_AM_OTHER="$(settings_home automode-other '{"permissions":{"defaultMode":"auto","allow":[]},"autoMode":{"allow":["$defaults","Docs: allow reading vendor manuals"]}}')"
OUT="$(run_report_home "$H_AM_OTHER")"
case "$OUT" in *'permission mode "auto" is set'*) ;; *) check "P1au1 precondition: the exposure row must render (got: $OUT)" FAIL ;; esac
absent_row "P1au1 an autoMode.allow that never names the agent renders no prose row" "$H_AM_OTHER" 'classifier guidance in prose'
# The correction is about autoMode.allow alone, so it is just as true — and just
# as needed — for a user who never set auto mode. Only a real grant suppresses it.
H_AM_PLAIN="$(settings_home automode-plain '{"permissions":{"defaultMode":"default","allow":[]},"autoMode":{"allow":["$defaults",null,42,"Zensu: allow zensu:code-reviewer"]}}')"
case "$(run_report_home "$H_AM_PLAIN")" in *'classifier guidance in prose'*)
  check "P1au2 the autoMode correction renders outside auto mode too" PASS ;;
  *) check "P1au2 autoMode correction gated on auto mode" FAIL ;; esac
H_AM_GRANT="$(settings_home automode-granted '{"permissions":{"defaultMode":"auto","allow":["Agent(zensu:code-reviewer)"]},"autoMode":{"allow":["Zensu: allow zensu:code-reviewer"]}}')"
clean_row "P1au3 a real grant suppresses the autoMode correction as well" "$H_AM_GRANT"

H_PLAIN="$(settings_home plain '{"permissions":{"defaultMode":"default","allow":[]}}')"
clean_row "P1av a non-auto mode with no deny/ask renders no permissions warning" "$H_PLAIN"
H_NONE="$SBOX/home-none"; mkdir -p "$H_NONE"
OUT="$(run_report_home "$H_NONE")"; RC=$?
[ "$RC" -eq 0 ] && check "P1aw1 an absent settings file still exits 0" PASS || check "P1aw1 absent settings exit (rc=$RC)" FAIL
clean_row_out "P1aw an absent settings file renders the clean row, not a warning" "$OUT"
# AC-007's other half. Removing the !env.HOME guard does NOT drop one row — it
# throws in path.join and collapses the entire four-block table into the outer
# catch's single line, still exiting 0. The anchor is what notices that.
UNSET_OUT="$( unset HOME; ZDOC_ZENSU=absent ZDOC_NODE="vTEST" ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" node "$REPORT" 2>/dev/null )"; RC=$?
[ "$RC" -eq 0 ] && check "P1aw2a an unset HOME still exits 0" PASS || check "P1aw2a unset HOME exit (rc=$RC)" FAIL
# An unset HOME is a check that could NOT run, so it gets the did-not-run row rather
# than the clean one — claiming "no exposure found" for a file it never located would be
# the false all-clear this feature exists to remove. The row also serves as the render
# anchor the old absent-row form relied on: dropping the !env.HOME guard throws in
# path.join and collapses the whole four-block table into the outer catch's single line.
case "$UNSET_OUT" in *'HOME is not set'*'the reviewer-spawn permission check did not run'*)
  check "P1aw2 an unset HOME renders the did-not-run row and does not collapse the report" PASS ;;
  *) check "P1aw2 unset HOME did-not-run row (got: $UNSET_OUT)" FAIL ;; esac
absent_row_out "P1aw2b an unset HOME never claims a clean result" "$UNSET_OUT" "$OK_ROW"
EMPTY_OUT="$( HOME=""; export HOME; ZDOC_ZENSU=absent ZDOC_NODE="vTEST" ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" node "$REPORT" 2>/dev/null )"
case "$EMPTY_OUT" in *'HOME is not set'*'the reviewer-spawn permission check did not run'*)
  check "P1aw3 an empty HOME renders the did-not-run row and does not collapse the report" PASS ;;
  *) check "P1aw3 empty HOME did-not-run row (got: $EMPTY_OUT)" FAIL ;; esac
absent_row_out "P1aw3b an empty HOME never claims a clean result" "$EMPTY_OUT" "$OK_ROW"

# A check that could not run must say so — the one thing it must never do is
# stay silent, which reads as an all-clear.
# The failure reason is a CLOSED vocabulary. V8 embeds a leading slice of the
# input in a JSON.parse message, so passing that through would put bytes of the
# user's settings file into a report the doctor skill tells the model to print
# verbatim. The decoy has to sit at the very front, because that is the only
# position V8 quotes back.
H_BAD="$(settings_home bad 'sk-DECOYSECRET-zzz {"permissions":{')"
BAD_OUT="$(run_report_home "$H_BAD")"; RC=$?
[ "$RC" -eq 0 ] && check "P1ax invalid settings JSON still exits 0" PASS || check "P1ax invalid settings JSON exit (rc=$RC)" FAIL
case "$BAD_OUT" in *'⚠️  permissions: ~/.claude/settings.json could not be parsed'*'That is a missing check, not an all-clear'*)
  check "P1ay invalid settings JSON renders the did-not-run row, not silence" PASS ;;
  *) check "P1ay invalid settings row (got: $BAD_OUT)" FAIL ;; esac
case "$BAD_OUT" in *DECOYSECRET*) check "P1ay1 the parse failure leaks a slice of the settings file into the report" FAIL ;;
  *) check "P1ay1 no settings byte reaches the report through the failure reason" PASS ;; esac
# The sibling reader gained an `io` discriminator this round; this one did not, so its
# PARSE failure still renders under a "could not be read" lead-in — the same cause/operation
# mislabel, running in the opposite direction. skills/doctor/SKILL.md compounds it by telling
# the model that row "names a filesystem problem".
absent_row_out "P1ay2 a settings parse failure is not announced as a read failure" "$BAD_OUT" 'could not be read — unparseable JSON'
# Positive control: the finding must survive the reword, and must still name the cause.
# The cause is now carried by the LEAD-IN alone: appending the single io:false value after
# "could not be parsed" produced "could not be parsed — unparseable JSON", which says the
# same thing twice. The bound must still travel with it.
case "$BAD_OUT" in *'could not be parsed'*'That is a missing check, not an all-clear'*)
  check "P1ay3 a settings parse failure is still reported, with its cause and bound" PASS ;;
  *) check "P1ay3 the settings parse failure lost its row or its bound" FAIL ;; esac
# Discrimination: a genuine I/O failure must KEEP the read wording.
H_NOREAD="$(settings_home noread '{"permissions":{}}')"
chmod 000 "$H_NOREAD/.claude/settings.json" 2>/dev/null || true
if [ -r "$H_NOREAD/.claude/settings.json" ]; then
  check "P1ay4 SKIPPED — this principal can read a chmod 000 file, EACCES not producible" PASS
else
  case "$(run_report_home "$H_NOREAD")" in *'could not be read — unreadable ('*)
    check "P1ay4 a genuine I/O failure keeps the read wording" PASS ;;
    *) check "P1ay4 a genuine I/O failure lost the read wording" FAIL ;; esac
fi
chmod 644 "$H_NOREAD/.claude/settings.json" 2>/dev/null || true
H_DIR="$SBOX/home-dir"; mkdir -p "$H_DIR/.claude/settings.json"
OUT="$(run_report_home "$H_DIR")"; RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *'could not be read — not a regular file'*)
  check "P1az a directory at the settings path degrades to the did-not-run row" PASS ;;
  *) check "P1az non-regular settings path (got: $OUT)" FAIL ;; esac || check "P1az non-regular settings exit (rc=$RC)" FAIL
# A present key of the wrong SHAPE is a check that could not run. Without the
# Array test these two render identically to a settings file with no rules at
# all, because typeof [] === 'object'.
H_PERMS_ARR="$(settings_home perms-array '{"permissions":[],"autoMode":{}}')"
# The tail, not the shared prefix: shapeRow and deferredShapeRow are byte-identical up to
# ' — ' + err and diverge only afterwards, so a prefix-only needle cannot tell a FATAL
# suppression from a scoped one. permissions-not-an-object is fatal and must say so.
case "$(run_report_home "$H_PERMS_ARR")" in *'⚠️  permissions: ~/.claude/settings.json has a shape this check cannot judge — permissions is present but not an object'*'the reviewer-spawn permission check did not run'*)
  check "P1az1 a non-object permissions value renders the FATAL did-not-run row" PASS ;;
  *) check "P1az1 non-object permissions did not carry the fatal tail" FAIL ;; esac
H_AM_ARR="$(settings_home automode-array '{"permissions":{"defaultMode":"auto"},"autoMode":[]}')"
case "$(run_report_home "$H_AM_ARR")" in *'⚠️  permissions: ~/.claude/settings.json has a shape this check cannot judge — autoMode is present but not an object'*'could not be determined'*)
  check "P1az2 a non-object autoMode value renders the SCOPED could-not-determine row" PASS ;;
  *) check "P1az2 non-object autoMode did not reach the scoped row" FAIL ;; esac
H_ROOT_ARR="$(settings_home root-array '["nope"]')"
case "$(run_report_home "$H_ROOT_ARR")" in *'⚠️  permissions: ~/.claude/settings.json has a shape this check cannot judge — the settings root is not a JSON object'*)
  check "P1az3 a non-object settings root degrades to the did-not-run row" PASS ;;
  *) check "P1az3 non-object settings root" FAIL ;; esac
# The shape doctrine has to reach the RULE LISTS, not stop at their containers.
# Each of these used to read as "no rules": a non-array deny left the exposure row
# recommending an allow rule while an unevaluated deny key sat in the same file,
# which is a confidently WRONG remedy rather than a missing one.
for rk in allow deny ask; do
  H_RK="$(settings_home "rule-$rk" "{\"permissions\":{\"defaultMode\":\"auto\",\"$rk\":{\"Agent(zensu:code-reviewer)\":true}}}")"
  # deny and ask are FATAL and keep the whole-check tail; allow is DEFERRED and takes the
  # scoped one. Asserting only the shared prefix let all three pass under either wording.
  if [ "$rk" = "allow" ]; then rk_tail='could not be determined'; else rk_tail='the reviewer-spawn permission check did not run'; fi
  case "$(run_report_home "$H_RK")" in *"⚠️  permissions: ~/.claude/settings.json has a shape this check cannot judge — permissions.$rk is present but not an array"*"$rk_tail"*)
    check "P1az5x$rk a non-array permissions.$rk renders its own tail ($rk_tail)" PASS ;;
    *) check "P1az5x$rk non-array permissions.$rk did not carry the expected tail" FAIL ;; esac
done
# The shape check splits by CONSEQUENCE. A malformed deny or ask is FATAL — no
# allow remedy may be recommended when they cannot be read. Everything else is
# DEFERRED, so a deny that IS readable still gets its row; suppressing it over an
# unrelated malformed key dropped the highest-value row this check emits.
H_DEFER_MODE="$(settings_home defer-mode '{"permissions":{"defaultMode":7,"deny":["Agent(zensu:code-reviewer)"]}}')"
case "$(run_report_home "$H_DEFER_MODE")" in *'a permissions.deny entry'*)
  check "P1az5d a malformed defaultMode does not suppress the deny row" PASS ;;
  *) check "P1az5d deferred shape failure swallowed the deny row" FAIL ;; esac
H_DEFER_ALLOW="$(settings_home defer-allow '{"permissions":{"defaultMode":"auto","allow":{},"ask":["Agent(zensu:code-reviewer)"]}}')"
case "$(run_report_home "$H_DEFER_ALLOW")" in *'a permissions.ask entry'*)
  check "P1az5e a malformed allow does not suppress the ask row" PASS ;;
  *) check "P1az5e deferred shape failure swallowed the ask row" FAIL ;; esac
H_FATAL_DENY="$(settings_home fatal-deny '{"permissions":{"defaultMode":"auto","deny":{"x":1},"allow":[]}}')"
absent_row "P1az5f a malformed deny suppresses the exposure row too (no allow remedy may be recommended)" \
  "$H_FATAL_DENY" 'permission mode "auto" is set'
# The deferred half of the same rule. What this catches is the guard being DROPPED
# so a deferred failure falls through into the allow/exposure ladder. It does NOT
# catch the guard reverting to a bare `return` — that suppresses the exposure row
# too, so this check stays green; P1az5h is the one that sees it, by observing the
# silenced autoMode correction. Do not delete P1az5h believing this covers it.
H_DEFER_EXPOSE="$(settings_home defer-expose '{"permissions":{"defaultMode":"auto","allow":{}}}')"
absent_row "P1az5g a deferred shape failure suppresses the exposure row too" \
  "$H_DEFER_EXPOSE" 'permission mode "auto" is set'
# ...and the other half of the else-guard: the autoMode correction reads
# autoMode.allow alone, so a deferred defaultMode must NOT silence it.
H_DEFER_PROSE="$(settings_home defer-prose '{"permissions":{"defaultMode":7,"allow":[]},"autoMode":{"allow":["Zensu: allow zensu:code-reviewer"]}}')"
DP_OUT="$(run_report_home "$H_DEFER_PROSE")"
# Asserted independently, not as one ordered pattern: the claim is that both rows
# render, and an emission-order constraint would fail under a reorder with a label
# saying the correction was silenced, which would be false.
DP_MISS=""
case "$DP_OUT" in *'has a shape this check cannot judge'*) ;; *) DP_MISS="$DP_MISS [shape row]" ;; esac
case "$DP_OUT" in *'classifier guidance in prose'*) ;; *) DP_MISS="$DP_MISS [autoMode correction]" ;; esac
if [ -z "$DP_MISS" ]; then
  check "P1az5h a deferred shape failure still lets the autoMode correction through" PASS
else
  check "P1az5h deferred failure lost:$DP_MISS" FAIL
fi
# A deferred defect co-present with an unverified spelling: the could-not-judge row
# is decided first, so the ladder order between them is observable.
H_UNJ_DEFER="$(settings_home unjudge-defer '{"permissions":{"defaultMode":"auto","deny":["Agent(zensu:code-reviewer)*"],"allow":{}}}')"
case "$(run_report_home "$H_UNJ_DEFER")" in *'⚠️  permissions: a permissions.deny or permissions.ask entry'*'in a spelling this check has not verified'*)
  check "P1az5i an unverified spelling outranks a deferred shape failure" PASS ;;
  *) check "P1az5i ladder order between could-not-judge and deferred shape" FAIL ;; esac
# Which deferred defect is named, when two are present.
H_DEFER_TWO="$(settings_home defer-two '{"permissions":{"defaultMode":7,"allow":{}}}')"
case "$(run_report_home "$H_DEFER_TWO")" in *'permissions.allow is present but not an array'*)
  check "P1az5j the deferred chain names permissions.allow before defaultMode" PASS ;;
  *) check "P1az5j deferred chain order" FAIL ;; esac
SHAPE_OUT="$(run_report_home "$H_FATAL_DENY")"
H_AMA="$(settings_home automode-allow-str '{"permissions":{"defaultMode":"auto"},"autoMode":{"allow":"nope"}}')"
case "$(run_report_home "$H_AMA")" in *'⚠️  permissions: ~/.claude/settings.json has a shape this check cannot judge — autoMode.allow is present but not an array'*'could not be determined'*)
  check "P1az6 a non-array autoMode.allow renders the SCOPED could-not-determine row" PASS ;;
  *) check "P1az6 non-array autoMode.allow did not reach the scoped row" FAIL ;; esac
H_MODE_NUM="$(settings_home mode-number '{"permissions":{"defaultMode":7,"allow":[]}}')"
case "$(run_report_home "$H_MODE_NUM")" in *'⚠️  permissions: ~/.claude/settings.json has a shape this check cannot judge — permissions.defaultMode is present but not a string'*'could not be determined'*)
  check "P1az7 a non-string defaultMode renders the SCOPED could-not-determine row" PASS ;;
  *) check "P1az7 non-string defaultMode did not reach the scoped row" FAIL ;; esac
# The most common real settings file has no permissions key at all. Mutating the
# absent-key branch to plainObject() would make every one of them print a false
# did-not-run WARN, and no other fixture would notice.
H_NO_PERMS="$(settings_home no-perms '{"model":"opus","autoMode":{}}')"
clean_row "P1az8 a settings file with no permissions key renders the clean row, not a warning" "$H_NO_PERMS"
# Without a fixture only a DOWNWARD mutation of SETTINGS_MAX_BYTES would ever be
# caught; deleting the cap outright would stay green.
H_BIG="$SBOX/home-big"; mkdir -p "$H_BIG/.claude"
{ printf '{"pad":"'; head -c 1100000 /dev/zero | tr '\0' 'a'; printf '"}\n'; } > "$H_BIG/.claude/settings.json"
case "$(run_report_home "$H_BIG")" in *'could not be read — larger than 1048576 bytes'*)
  check "P1az4 a settings file over the size cap degrades to the did-not-run row" PASS ;;
  *) check "P1az4 oversized settings file" FAIL ;; esac
rm -f "$H_BIG/.claude/settings.json"
# The non-ENOENT errno arm: without a fixture, swapping its closed reason back to
# String(e.message) survives the whole suite. Root ignores mode bits, so skip
# there rather than assert something the host cannot produce.
H_ACC="$(settings_home no-access '{"permissions":{"defaultMode":"auto","allow":[]}}')"
chmod 000 "$H_ACC/.claude/settings.json" 2>/dev/null
if [ -r "$H_ACC/.claude/settings.json" ]; then
  check "P1az9 unreadable settings file — SKIP (mode bits not enforced for this user)" PASS
else
  case "$(run_report_home "$H_ACC")" in *'could not be read — unreadable (EACCES)'*)
    check "P1az9 an unreadable settings file names the errno, never the exception text" PASS ;;
    *) check "P1az9 unreadable settings file" FAIL ;; esac
fi
chmod 644 "$H_ACC/.claude/settings.json" 2>/dev/null
# The shape the O_NONBLOCK open exists for. A blocking open on a writer-less FIFO
# never returns, which would hang a renderer contracted to always exit 0 — and the
# directory fixture above can never show that.
# These four pin the two REGRESSIONS a previous fix round introduced, and they depend on
# `ln -s` and `printf` — NOT on FIFO support. They lived inside the mkfifo branch below,
# whose SKIP arm emits three checks, so on any host without FIFOs all four vanished with
# no signal at all: the suite reported fewer checks, all green. Kept OUTSIDE that branch.
# A symlinked config is ORDINARY — a dotfile manager links it routinely — and the real
# config reader (hooks/lib/zensu-config.sh's rd()) uses readFileSync, which follows links.
# The sibling settings reader declines O_NOFOLLOW for exactly this reason and P1ba pins it.
# Copying the flag here made the doctor render a ❌ for a file every hook reads fine.
CFG_REAL="$SBOX/symlink-target-cfg.json"
printf '{"hooks":{"tddImplementation":true}}\n' > "$CFG_REAL"
CFG_LINK="$SBOX/symlink-cfg.json"
rm -f "$CFG_LINK"; ln -s "$CFG_REAL" "$CFG_LINK" 2>/dev/null
if [ -L "$CFG_LINK" ]; then
  SYM_OUT="$(run_report "$SBOX/plug" "$CFG_LINK" "$EMPTY_PROJECT")"
  case "$SYM_OUT" in *'ELOOP'*|*'is unreadable'*)
    check "P1bg3 a symlinked config must be followed, not refused" FAIL ;;
    *) check "P1bg3 a symlinked config is followed, not refused" PASS ;; esac
  case "$SYM_OUT" in *'no quoted-boolean traps'*)
    check "P1bg4 a symlinked config is read and validated like its target" PASS ;;
    *) check "P1bg4 a symlinked config did not reach the valid-config row (got: $SYM_OUT)" FAIL ;; esac
else
  check "P1bg3 symlinked config — SKIP (symlinks unavailable on this host)" PASS
  check "P1bg4 symlinked config — SKIP (symlinks unavailable on this host)" PASS
fi
# A BOM-prefixed config is DISCARDED by the real loader (rd() hands the raw string with its
# BOM straight to JSON.parse), so tolerating it here would render a green row for a file
# every hook ignores. The divergence rule this file states runs the other way: fail toward
# "no rules found" UNLESS the host would reject the file too — and here it does.
CFG_BOM="$SBOX/bom-cfg.json"
# Octal, the spelling the sibling BOM fixture already uses — `printf '\xHH'` is not
# portable and a shell without it writes six literal characters, which produce the SAME
# two verdicts as a real BOM and make the pair a duplicate of P1bt1 that tests nothing.
printf '\357\273\277{"hooks":{}}\n' > "$CFG_BOM"
if [ "$(od -An -tx1 -N3 "$CFG_BOM" | tr -d ' \n')" != "efbbbf" ]; then
  check "P1bg5 BOM fixture is not BOM-prefixed — the check would be vacuous" FAIL
  check "P1bg6 BOM fixture is not BOM-prefixed — the check would be vacuous" FAIL
else
BOMCFG_OUT="$(run_report "$SBOX/plug" "$CFG_BOM" "$EMPTY_PROJECT")"
case "$BOMCFG_OUT" in *'no quoted-boolean traps'*)
  check "P1bg5 a BOM-prefixed config must not be reported as valid — the loader discards it" FAIL ;;
  *) check "P1bg5 a BOM-prefixed config is not reported as valid" PASS ;; esac
case "$BOMCFG_OUT" in *'invalid JSON in'*)
  check "P1bg6 a BOM-prefixed config is reported as invalid, matching the loader" PASS ;;
  *) check "P1bg6 a BOM-prefixed config rendered no invalid-JSON row (got: $BOMCFG_OUT)" FAIL ;; esac
fi

# The 1 MiB cap is the doctor's OWN memory bound; the loader it models has none. So for
# that one class the trailing "the whole file is ignored, defaults apply" would be a false
# statement — an oversized well-formed config is read and APPLIED by every hook. The other
# io classes do make the loader return {}, so the clause is true there.
BIG_CFG="$SBOX/big-cfg.json"
{ printf '{"_pad":"'; head -c 1100000 /dev/zero | tr '\0' 'x'; printf '"}\n'; } > "$BIG_CFG"
BIG_OUT="$(run_report "$SBOX/plug" "$BIG_CFG" "$EMPTY_PROJECT")"
# The loader MERGES a global and a project config; "defaults apply" is only true when the
# failing file is the sole source. With ZENSU_CONFIG unset and two sources present, a broken
# project overlay leaves the valid global's values in force, so that half of the clause
# overreaches. `readJson`'s own justification comment forbids exactly this.
MERGE_HOME="$SBOX/merge-home"; mkdir -p "$MERGE_HOME/.zensu"
printf '%s\n' '{"hooks":{}}' > "$MERGE_HOME/.zensu/config.json"
MERGE_PROJ="$SBOX/merge-proj"; mkdir -p "$MERGE_PROJ/.zensu"
printf '%s' '{bad json' > "$MERGE_PROJ/.zensu/config.json"
MERGE_OUT="$( HOME="$MERGE_HOME"; export HOME; ZDOC_ZENSU=absent ZDOC_NODE="vTEST" \
  ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" CLAUDE_PROJECT_DIR="$MERGE_PROJ" \
  node "$REPORT" 2>&1 )"
case "$MERGE_OUT" in *'invalid JSON in'*'defaults apply'*)
  check "P1bge a broken overlay must not claim defaults apply while a valid source remains" FAIL ;;
  *) check "P1bge a broken overlay does not claim defaults apply beside a valid source" PASS ;; esac
case "$MERGE_OUT" in *'invalid JSON in'*)
  check "P1bgf a broken overlay is still reported" PASS ;;
  *) check "P1bgf a broken overlay lost its row (got: $MERGE_OUT)" FAIL ;; esac
# The mirror case, and the one an ordinary user hits: only a PROJECT config exists and it is
# broken. `configFiles()` returns candidate PATHS, not present files, so a length-based
# soleSource is always false here and the row promises an "other config source" that does not
# exist — while defaults really do apply. Present-ness, not candidacy, decides the clause.
LONE_HOME="$SBOX/lone-home"; mkdir -p "$LONE_HOME/.zensu"
rm -f "$LONE_HOME/.zensu/config.json"
LONE_PROJ="$SBOX/lone-proj"; mkdir -p "$LONE_PROJ/.zensu"
printf '%s' '{bad json' > "$LONE_PROJ/.zensu/config.json"
LONE_OUT="$( HOME="$LONE_HOME"; export HOME; ZDOC_ZENSU=absent ZDOC_NODE="vTEST" \
  ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" CLAUDE_PROJECT_DIR="$LONE_PROJ" \
  node "$REPORT" 2>&1 )"
case "$LONE_OUT" in *'the other config source still applies'*)
  check "P1bgh a lone broken config must not promise an other source that does not exist" FAIL ;;
  *) check "P1bgh a lone broken config does not promise a nonexistent other source" PASS ;; esac
case "$LONE_OUT" in *'invalid JSON in'*'defaults apply'*)
  check "P1bgi a lone broken config says defaults apply, which is true there" PASS ;;
  *) check "P1bgi a lone broken config lost the defaults-apply verdict (got: $LONE_OUT)" FAIL ;; esac
rm -f "$BIG_CFG"
case "$BIG_OUT" in *'larger than'*'the whole file is ignored, defaults apply'*)
  check "P1bg7 an oversized config must not claim the loader ignores it" FAIL ;;
  *) check "P1bg7 an oversized config does not claim the loader ignores it" PASS ;; esac
# The cap class has its own third wording, distinct from both the loader verdict and the
# check-limited one; without this the `capped` branch was invariant under the mutation the
# round-5 finding named.
case "$BIG_OUT" in *'declined to read it'*)
  check "P1bgd an oversized config carries the cap wording" PASS ;;
  *) check "P1bgd an oversized config did not carry the cap wording (got: $BIG_OUT)" FAIL ;; esac
case "$BIG_OUT" in *'still applies it'*)
  check "P1bga an oversized config must not assert the loader applies it — it was never parsed" FAIL ;;
  *) check "P1bga an oversized config does not assert the loader applies it" PASS ;; esac
# The severity is part of the claim: a "check declined" row is a WARNING, never a blocker.
case "$BIG_OUT" in *'⚠️  config: '*'larger than'*)
  check "P1bg8 an oversized config is reported as ⚠️, not ❌" PASS ;;
  *) check "P1bg8 an oversized config rendered no ⚠️ row (got: $BIG_OUT)" FAIL ;; esac
# Discrimination: an absent config keeps its own row and is not swept into the cap class.
case "$(run_report "$SBOX/plug" "$SBOX/nonexistent-dir/cfg.json" "$EMPTY_PROJECT")" in *'no config file present'*)
  check "P1bg9 an absent config is still reported as absent, not as oversized" PASS ;;
  *) check "P1bg9 an absent config lost its row" FAIL ;; esac
H_FIFO="$SBOX/home-fifo"; mkdir -p "$H_FIFO/.claude"
if mkfifo "$H_FIFO/.claude/settings.json" 2>/dev/null && [ -p "$H_FIFO/.claude/settings.json" ]; then
  # BOUNDED on purpose. The mutation this pins — dropping O_NONBLOCK from the open
  # — makes the renderer block forever on a writer-less FIFO, and an unbounded
  # capture would turn that regression into a hang that costs every check below it
  # rather than into a FAIL. Run detached, poll to a deadline, kill and fail.
  FIFO_OUT_FILE="$SBOX/fifo-out.txt"
  ( HOME="$H_FIFO" ZDOC_ZENSU=absent ZDOC_NODE="vTEST" ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh \
    ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" \
    ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" \
    node "$REPORT" >"$FIFO_OUT_FILE" 2>/dev/null </dev/null ) &
  FIFO_PID=$!
  FIFO_WAITED=0
  # The house construct, matching tests/run-all.sh: a bare `sleep 1` is the pacer.
  # An earlier version also ran `read -t 1 _ < /dev/null`, which is INERT — reading
  # /dev/null hits EOF at once, so it never consumed its timeout and the whole
  # bound rested on a `sleep` whose failure was swallowed.
  while kill -0 "$FIFO_PID" 2>/dev/null && [ "$FIFO_WAITED" -lt 30 ]; do
    FIFO_WAITED=$((FIFO_WAITED+1))
    sleep 1
  done
  if kill -0 "$FIFO_PID" 2>/dev/null; then
    kill -9 "$FIFO_PID" 2>/dev/null; wait "$FIFO_PID" 2>/dev/null
    check "P1bg the renderer BLOCKED on a FIFO at the settings path (O_NONBLOCK lost)" FAIL
  else
    wait "$FIFO_PID" 2>/dev/null; RC=$?
    FIFO_OUT="$(cat "$FIFO_OUT_FILE" 2>/dev/null)"
    [ "$RC" -eq 0 ] && case "$FIFO_OUT" in *'could not be read — not a regular file'*)
      check "P1bg a FIFO at the settings path is reported, not blocked on" PASS ;;
      *) check "P1bg FIFO at the settings path (got: $FIFO_OUT)" FAIL ;; esac \
      || check "P1bg FIFO fixture exit (rc=$RC)" FAIL
  fi
  rm -f "$H_FIFO/.claude/settings.json"
  # The SAME hazard, one reader over, and the mutation this pins is dropping the
  # non-blocking open from readJson — which leaves it blocking and unbounded while
  # ZENSU_CONFIG can aim it at any path the caller names. The
  # module's own comment gives the reason its sibling is hardened: "open non-blocking so a
  # path swapped to a FIFO cannot hang a process contracted to always exit 0". A hang here
  # is invisible: the doctor simply never returns, and the "ALWAYS exits 0" contract in the
  # module header becomes false without any output saying so.
  CFG_FIFO="$SBOX/fifo-cfg.json"
  rm -f "$CFG_FIFO"
  # Prove the fixture. Without the [ -p ] re-check a failed mkfifo leaves ENOENT, readJson
  # answers `missing`, configBlock prints "no config file present" and exits 0 with a full
  # report — so BOTH checks below would pass having exercised nothing. This is the same
  # fixture-existence hole this round closed elsewhere.
  if ! mkfifo "$CFG_FIFO" 2>/dev/null || [ ! -p "$CFG_FIFO" ]; then
    check "P1bg1 config FIFO fixture could not be created" FAIL
    check "P1bg2 config FIFO fixture could not be created" FAIL
    check "P1bgb config FIFO fixture could not be created" FAIL
    check "P1bgc config FIFO fixture could not be created" FAIL
  else
  CFG_FIFO_OUT_FILE="$SBOX/fifo-cfg-out.txt"
  ( ZDOC_ZENSU=absent ZDOC_NODE="vTEST" ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh \
    ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" \
    ZENSU_CONFIG="$CFG_FIFO" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" \
    node "$REPORT" >"$CFG_FIFO_OUT_FILE" 2>/dev/null </dev/null ) &
  CFG_FIFO_PID=$!
  CFG_FIFO_WAITED=0
  while kill -0 "$CFG_FIFO_PID" 2>/dev/null && [ "$CFG_FIFO_WAITED" -lt 30 ]; do
    CFG_FIFO_WAITED=$((CFG_FIFO_WAITED+1))
    sleep 1
  done
  if kill -0 "$CFG_FIFO_PID" 2>/dev/null; then
    kill -9 "$CFG_FIFO_PID" 2>/dev/null; wait "$CFG_FIFO_PID" 2>/dev/null
    check "P1bg1 the renderer BLOCKED on a FIFO at the config path (readJson unhardened)" FAIL
    # Emitted on EVERY path, so a regression fails a check instead of removing one. This
    # arm is where that convention was stated and then not applied to the two checks added
    # a round later — the fifth time in this work that an arm emitted fewer checks than
    # its sibling and the loss was invisible.
    check "P1bg2 the renderer BLOCKED before the report could render" FAIL
    check "P1bgb the renderer BLOCKED before the wording could be observed" FAIL
    check "P1bgc the renderer BLOCKED before the wording could be observed" FAIL
  else
    wait "$CFG_FIFO_PID" 2>/dev/null; CFG_RC=$?
    CFG_FIFO_OUT="$(cat "$CFG_FIFO_OUT_FILE" 2>/dev/null)"
    if [ "$CFG_RC" -eq 0 ]; then
      check "P1bg1 a FIFO at the config path does not hang the renderer" PASS
    else
      check "P1bg1 FIFO config fixture exit (rc=$CFG_RC)" FAIL
    fi
    # Observe the FIFO itself, not just the report header: the header renders for a config
    # that is merely absent, which is exactly the state a failed fixture produces.
    case "$CFG_FIFO_OUT" in *'is not a regular file'*)
      check "P1bg2 the FIFO is reported as not a regular file, not blocked on" PASS ;;
      *) check "P1bg2 the FIFO was not reported (got: $CFG_FIFO_OUT)" FAIL ;; esac
    # A FIFO does NOT make the loader fall back — rd()'s blocking readFileSync would hang —
    # so this class must carry the check-limited wording, never the loader verdict.
    case "$CFG_FIFO_OUT" in *'could not read it and cannot say what the config loader gets from it'*)
      check "P1bgb a FIFO config carries the check-limited wording, not the loader verdict" PASS ;;
      *) check "P1bgb a FIFO config did not carry the check-limited wording" FAIL ;; esac
    case "$CFG_FIFO_OUT" in *'is not a regular file'*'the whole file is ignored, defaults apply'*)
      check "P1bgc a FIFO config must not claim the loader ignores it" FAIL ;;
      *) check "P1bgc a FIFO config does not claim the loader ignores it" PASS ;; esac
  fi
  fi
  rm -f "$CFG_FIFO"
else
  check "P1bg FIFO at the settings path — SKIP (mkfifo unavailable on this host)" PASS
  check "P1bg1 FIFO at the config path — SKIP (mkfifo unavailable on this host)" PASS
  check "P1bg2 FIFO at the config path — SKIP (mkfifo unavailable on this host)" PASS
  check "P1bgb config FIFO wording — SKIP (mkfifo unavailable on this host)" PASS
  check "P1bgc config FIFO wording — SKIP (mkfifo unavailable on this host)" PASS
fi
# "NEVER writes" is the module's first contract line and nothing asserted it.
if command -v shasum >/dev/null 2>&1; then HASHER="shasum"; elif command -v cksum >/dev/null 2>&1; then HASHER="cksum"; else HASHER=""; fi
# FAIL, not SKIP, unlike the three sibling capability probes beside it. "NEVER
# writes" is this module's first contract line; a host that cannot check it has
# not shown the contract holds, and quietly passing would claim it did.
# cut -f1,2 on purpose: cksum prints "<crc> <size> <name>", so field 1 alone
# discards the length. shasum's second field is empty under its double space, so
# the same cut is stable for both.
if [ -z "$HASHER" ]; then
  check "P1bf byte identity — no hasher on PATH, so the content half cannot be checked" FAIL
else
  BEFORE="$($HASHER "$H_EXPOSED/.claude/settings.json" | cut -d' ' -f1,2)"
  BEFORE_N="$(ls -a "$H_EXPOSED/.claude" | wc -l | tr -d ' ')"
  BF_OUT="$(run_report_home "$H_EXPOSED")"
  AFTER="$($HASHER "$H_EXPOSED/.claude/settings.json" | cut -d' ' -f1,2)"
  AFTER_N="$(ls -a "$H_EXPOSED/.claude" | wc -l | tr -d ' ')"
  case "$BF_OUT" in
    *"$ANCHOR"*)
      if [ "$BEFORE" = "$AFTER" ] && [ "$BEFORE_N" = "$AFTER_N" ]; then
        check "P1bf a doctor run leaves the settings file byte-identical and adds no sibling" PASS
      else
        check "P1bf doctor run mutated the settings dir (hash $BEFORE->$AFTER, entries $BEFORE_N->$AFTER_N)" FAIL
      fi ;;
    *) check "P1bf byte-identity run never rendered a report — nothing was exercised" FAIL ;;
  esac
fi

# A dotfile manager (stow, chezmoi) links this file routinely, and Claude Code
# itself follows the link — refusing to would red-flag a healthy setup.
H_LINK="$SBOX/home-link"; mkdir -p "$H_LINK/.claude"
if ln -s "$H_EXPOSED/.claude/settings.json" "$H_LINK/.claude/settings.json" 2>/dev/null \
  && [ -L "$H_LINK/.claude/settings.json" ]; then
  OUT="$(run_report_home "$H_LINK")"
  case "$OUT" in *'permission mode "auto" is set'*) check "P1ba a symlinked settings.json is followed, not rejected" PASS ;;
    *) check "P1ba symlinked settings.json (got: $OUT)" FAIL ;; esac
else
  check "P1ba symlinked settings.json — SKIP (symlink unavailable on this host)" PASS
fi

# The project-local spelling must never reach the report, under any fixture. The
# anchor conjunct matters here too: a fixture that rendered nothing cannot leak,
# so counting only the needle would let a broken loop report a clean result.
LEAK=0; UNRENDERED=0
for h in "$H_EXPOSED" "$H_DENY" "$H_DENY_ONLY" "$H_ASK" "$H_ASK_AUTO" "$H_AM" "$H_AM_OTHER" "$H_BAD" "$H_DIR" "$H_WILD" "$H_PERMS_ARR" "$H_ROOT_ARR"; do
  LEAK_OUT="$(run_report_home "$h")"
  case "$LEAK_OUT" in *settings.local.json*) LEAK=$((LEAK+1)) ;; esac
  case "$LEAK_OUT" in *"$ANCHOR"*) ;; *) UNRENDERED=$((UNRENDERED+1)) ;; esac
done
if [ "$LEAK" -eq 0 ] && [ "$UNRENDERED" -eq 0 ]; then
  check "P1bb no permissions row ever names a project-local settings path" PASS
else
  check "P1bb project-local path leaked in $LEAK fixture(s); $UNRENDERED fixture(s) never rendered" FAIL
fi
# Structural backstop for the same bound: the renderer opens ONE settings path.
if [ "$(grep -cF "settings.local" "$REPORT")" -eq 0 ] \
  && [ "$(grep -cF "'settings.json'" "$REPORT")" -eq 1 ]; then
  check "P1bc the renderer joins exactly one settings path and knows no local one" PASS
else
  check "P1bc renderer settings-path count (expected exactly 1 join, 0 local)" FAIL
fi
# The host-coupled literals carry a named build so a human can re-verify them
# instead of assuming; the sibling reviewer-spawn-denial-v1.js pins its own the
# same way. A version-shaped string is required, not merely the constant's name.
# A version-shaped literal on its own proves nothing — '0.0.0' would satisfy it.
# The sibling DENIAL_MARKERS_SOURCE_BUILD is cross-checked against its module
# header so the version cannot be edited in one place and left stale in the
# other; this does the same, against the provenance comment that enumerates the
# host-coupled surface.
SSB="$(sed -n "s/^var SETTINGS_SOURCE_BUILD = '\(.*\)';$/\1/p" "$REPORT" | head -1)"
case "$SSB" in
  [0-9]*.[0-9]*.[0-9]*)
    if grep -qF "build ($SSB)" "$REPORT"; then
      check "P1bd the host build is recorded and matches the provenance comment ($SSB)" PASS
    else
      check "P1bd host build $SSB is not named in the provenance comment" FAIL
    fi ;;
  *) check "P1bd renderer host-build provenance constant (got: '${SSB:-<absent>}')" FAIL ;;
esac
# The renderer reads HOME for BOTH the user-scoped zensu config and the settings
# file the reviewer-spawn check opens, so any suite that runs it is
# environment-dependent until it overrides HOME. The predicate is deliberately
# blunt: a suite is IN SCOPE if it names either doctor file anywhere at all.
#
# The earlier version tried to recognise an execution — filename on the same line
# as node/bash, minus a list of payload spellings — and that failed exactly where
# it mattered: test-orphaned-project-root.sh binds the path once and then runs
# `bash "$DOCTOR"` six hundred lines later, so the pin reported PASS while the
# suite really did read the developer's own settings. A recogniser cannot be
# trusted here; naming plus an EXPLICIT exemption can, because the exemption is a
# sentence somebody had to write.
#
# The HOME arm is ANCHORED. An unanchored `grep -q 'HOME='` is satisfied by
# `DOCTOR_HOME=` — the very variable a sandboxing suite defines — so deleting the
# real `HOME="$DOCTOR_HOME"` from an invocation would leave this green while the
# leak returned; it was also satisfied by `ISOLATED_HOME=` inside an unrelated
# grep needle. The excluded class contains `_`, so both are rejected while every
# real `HOME="…" cmd` prefix, `(HOME=…` and `export HOME=` still match.
#
# COMMENT LINES ARE STRIPPED FIRST, and that is not cosmetic. A leading SPACE is
# in the excluded class, so any prose occurrence of ` HOME=` satisfied the arm —
# including the very `# zensu-doctor-home-exempt:` sentence a suite writes to
# declare that it has NO sandbox. That suite then took the HOME arm and its
# exemption arm was never reached, so the sentence stating the absence of a
# sandbox was what classified the suite as having one. The arms are ordered
# HOME-then-exemption on purpose; stripping comments is what keeps that order
# from swallowing the exemption it precedes.
DOCTOR_HOMELESS=""
DOCTOR_IN_SCOPE=0
for suite in "$PLUGIN_DIR"/tests/structure/*.sh; do
  grep -qE 'zensu-doctor-report\.js|zensu-doctor\.sh' "$suite" 2>/dev/null || continue
  DOCTOR_IN_SCOPE=$((DOCTOR_IN_SCOPE+1))
  grep -vE '^[[:space:]]*#' "$suite" | grep -qE '(^|[^A-Za-z0-9_])HOME=' && continue
  grep -q '# zensu-doctor-home-exempt:' "$suite" && continue
  DOCTOR_HOMELESS="$DOCTOR_HOMELESS ${suite##*/}"
done
# A floor, because a glob that matched nothing would otherwise PASS having scanned
# zero suites — the same vacuity this file just fixed in P1bi.
if [ "$DOCTOR_IN_SCOPE" -lt 5 ]; then
  check "P1bh scanned only $DOCTOR_IN_SCOPE suites naming the doctor — the scan itself is vacuous" FAIL
elif [ -z "$DOCTOR_HOMELESS" ]; then
  check "P1bh all $DOCTOR_IN_SCOPE suites naming the doctor sandbox HOME or declare an exemption" PASS
else
  check "P1bh suites naming the doctor with neither a HOME override nor a '# zensu-doctor-home-exempt:' sentence:$DOCTOR_HOMELESS" FAIL
fi
# The keys settingsShape vets and the keys the ladder dereferences must stay one
# set. Stopping short of a rule list WAS the earlier defect — a `deny` written as
# an object read as "no deny rules" and the exposure row recommended an allow rule
# — so a dereference with no matching vet silently reopens it.
# Discovery is OPEN, and the `case` has a default arm. A closed alternation could
# not see a NEW dereference, which is exactly the drift this pin exists to catch;
# and with no floor an empty discovery left the loop unexecuted and the check
# PASSed having examined nothing.
SHAPE_KEYS="$(grep -oE '(perms|autoMode)\.[A-Za-z_][A-Za-z0-9_]*' "$REPORT" | sort -u)"
SHAPE_COUNT="$(printf '%s\n' "$SHAPE_KEYS" | grep -c .)"
SHAPE_UNVETTED=""
for k in $SHAPE_KEYS; do
  case "$k" in
    perms.deny|perms.ask) grep -qF "FATAL_RULE_KEYS = RULE_LADDER.slice(0, RULE_LADDER.indexOf('allow'))" "$REPORT" || SHAPE_UNVETTED="$SHAPE_UNVETTED $k" ;;
    perms.allow) grep -qF "perms.allow !== undefined && !Array.isArray(perms.allow)" "$REPORT" || SHAPE_UNVETTED="$SHAPE_UNVETTED $k" ;;
    perms.defaultMode) grep -qF "perms.defaultMode !== undefined && typeof perms.defaultMode !== 'string'" "$REPORT" || SHAPE_UNVETTED="$SHAPE_UNVETTED $k" ;;
    autoMode.allow) grep -qF "autoMode.allow !== undefined && !Array.isArray(autoMode.allow)" "$REPORT" || SHAPE_UNVETTED="$SHAPE_UNVETTED $k" ;;
    *) SHAPE_UNVETTED="$SHAPE_UNVETTED $k(unknown-key)" ;;
  esac
done
if [ "$SHAPE_COUNT" -lt 5 ]; then
  check "P1bi discovered only $SHAPE_COUNT settings keys — the scan is vacuous, not clean" FAIL
elif [ -z "$SHAPE_UNVETTED" ]; then
  check "P1bi all $SHAPE_COUNT settings keys the ladder reads are vetted by settingsShape" PASS
else
  check "P1bi settings keys read but never shape-vetted:$SHAPE_UNVETTED" FAIL
fi

# The enumeration must name the evaluation ORDER, not only the key names: a host
# that reorders deny/ask/allow leaves every row rendering and turns the deny
# row's "adding a permissions.allow rule changes nothing" into a false claim.
if grep -qF 'deny -> ask -> allow' "$REPORT"; then
  check "P1bd1 the provenance note names the deny/ask/allow evaluation order" PASS
else
  check "P1bd1 provenance note omits the evaluation order" FAIL
fi

# P1bd1 reads the COMMENT and P1bi reads the derivation; neither reads the ladder.
# That was the whole defect: FATAL_RULE_KEYS is now computed from RULE_LADDER, but
# nothing tied RULE_LADDER to the `if` sequence that actually decides the order, so
# moving `allow` ahead of `ask` — the one reordering no behavioural fixture covers,
# since P1as2/P1as3 catch only a deny<->ask swap — still left every check green while
# `ask` should have left the fatal set. This derives the order from the ladder body
# and compares it to the declared array, so the two cannot drift apart silently.
LADDER_BODY="$(sed -n '/^function classifyPermissionExposure/,/^}/p' "$REPORT")"
LADDER_SEEN="$(printf '%s\n' "$LADDER_BODY" | grep -oE 'perms\.(deny|ask|allow)\b' | sed 's/perms\.//' | awk '!seen[$0]++' | tr '\n' ' ')"
LADDER_DECL="$(grep -oE "var RULE_LADDER = \[[^]]*\]" "$REPORT" | grep -oE "'[a-z]+'" | tr -d "'" | tr '\n' ' ')"
if [ -z "$LADDER_DECL" ] || [ -z "$LADDER_SEEN" ]; then
  check "P1bd2 could not derive the ladder order (declared:'$LADDER_DECL' dereferenced:'$LADDER_SEEN') — the scan is vacuous" FAIL
elif [ "$LADDER_DECL" = "$LADDER_SEEN" ]; then
  check "P1bd2 RULE_LADDER matches the order the ladder dereferences ($LADDER_SEEN)" PASS
else
  check "P1bd2 RULE_LADDER says '$LADDER_DECL' but the ladder dereferences '$LADDER_SEEN'" FAIL
fi
# Same drift pin the denial rows already carry at P1qr, for the new rows: the
# renderer and skills/doctor/SKILL.md are two hand-written accounts, and without
# this a row could be reworded while the skill keeps naming the old wording.
# Asserted on BOTH sides — against the emitted output so this list cannot go
# stale, and against the skill so the documentation cannot fall behind. The
# output is the concatenation of every permission-row fixture above — the count is
# deliberately not written out, because a literal there went stale the moment a fixture was
# added and nothing could catch it. The concatenation is needed because the branches return
# early and no single settings file can render every row.
# Extended with the fixtures for the rows added in this change: the clean row, the
# unset-HOME did-not-run row, the incomplete-read reason, the unreadable-entry row and
# the containment row. A row whose fixture is missing here reports as "not emitted",
# which is the pin telling the truth rather than a failure to explain away.
# The CONFIG block had no renderer-to-skill drift pin at all, and this round grew it from
# one wording to three — two of which were documented nowhere. Same shape as P1be, its own
# corpus, because the config rows and the permission rows come from different fixtures.
# The DOCUMENTED side covers all four wordings unconditionally. The EMITTED side covers only
# the three whose fixtures always exist: the check-limited wording is reachable only through a
# FIFO or a short read, and gating this pin on mkfifo would make it host-dependent — the very
# hazard it exists to catch. P1bgb pins that one's emission where its fixture lives.
CFG_ROWS="$CFG_OUT$BIG_OUT$MERGE_OUT$NOREAD_OUT"
CFG_UNEMITTED=""; CFG_DRIFT=""
while IFS= read -r cfg_phrase; do
  [ -n "$cfg_phrase" ] || continue
  case "$CFG_ROWS" in *"$cfg_phrase"*) ;; *) CFG_UNEMITTED="$CFG_UNEMITTED [$cfg_phrase]" ;; esac
done <<'CFG_EMITTED'
the whole file is ignored, defaults apply
the other config source still applies
declined to read it
CFG_EMITTED
while IFS= read -r cfg_phrase; do
  [ -n "$cfg_phrase" ] || continue
  grep -qF "$cfg_phrase" "$SKILL_MD" || CFG_DRIFT="$CFG_DRIFT [$cfg_phrase]"
done <<'CFG_PHRASES'
the whole file is ignored, defaults apply
the other config source still applies
cannot say what the config loader gets from it
declined to read it
CFG_PHRASES
if [ -z "$CFG_UNEMITTED" ] && [ -z "$CFG_DRIFT" ]; then
  check "P1bgg every config-failure wording is both emitted and documented in the skill" PASS
else
  check "P1bgg config rows vs skill (not emitted:$CFG_UNEMITTED not documented:$CFG_DRIFT)" FAIL
fi
# The config off-switch. It suppresses the ROW and never the file the check opens: a
# ZDOC_/ZENSU_ path override was refused on the injection axis, and a boolean concedes
# nothing there. Two properties matter more than the suppression itself. Disabling must
# not produce SILENCE — silence is the one verdict this check cannot qualify, and hiding
# the rows under a config key would reintroduce exactly the defect the feature removed.
# And a QUOTED "false" must not disable, because every boolean in this tree is read
# strictly and the doctor's own quoted-boolean row is what explains that to the user.
CFG_PERMOFF="$SBOX/cfg-permcheck-off.json"
printf '{"hooks":{"reviewerSpawnPermissionCheck":false}}\n' > "$CFG_PERMOFF"
PERMOFF_OUT="$( HOME="$H_EXPOSED"; run_report "$SBOX/plug" "$CFG_PERMOFF" "$EMPTY_PROJECT" )"
case "$PERMOFF_OUT" in *'✅  permissions: the reviewer-spawn permission check is switched off by hooks.reviewerSpawnPermissionCheck'*'not an all-clear'*)
  check "P1bz the off-switch reports the skipped check instead of falling silent" PASS ;;
  *) check "P1bz off-switch row (got: $PERMOFF_OUT)" FAIL ;; esac
case "$PERMOFF_OUT" in *'permission mode "auto" is set'*)
  check "P1bz1 the off-switch did not suppress the exposure row" FAIL ;;
  *) check "P1bz1 the exposure row is suppressed while the check is switched off" PASS ;; esac
CFG_PERMQ="$SBOX/cfg-permcheck-quoted.json"
printf '{"hooks":{"reviewerSpawnPermissionCheck":"false"}}\n' > "$CFG_PERMQ"
case "$( HOME="$H_EXPOSED"; run_report "$SBOX/plug" "$CFG_PERMQ" "$EMPTY_PROJECT" )" in *'permission mode "auto" is set'*)
  check "P1bz2 a quoted \"false\" does not disable the check" PASS ;;
  *) check "P1bz2 a quoted \"false\" wrongly disabled the check" FAIL ;; esac
PERM_ROWS="$EXPOSED_OUT$DENY_OUT$ASK_OUT$AM_OUT$BAD_OUT$UNJ_OUT$SHAPE_OUT$QUIET_OUT$NOHOME_OUT$SHORT_OUT$THROW_OUT$DENY_OBJ_OUT$OTHER_AGENT_OUT$AMA_SPLIT_OUT$PERMOFF_OUT"
PERM_UNEMITTED=""; PERM_DRIFT=""
while IFS= read -r perm_phrase; do
  [ -n "$perm_phrase" ] || continue
  case "$PERM_ROWS" in *"$perm_phrase"*) ;; *) PERM_UNEMITTED="$PERM_UNEMITTED [$perm_phrase]" ;; esac
  grep -qF "$perm_phrase" "$SKILL_MD" || PERM_DRIFT="$PERM_DRIFT [$perm_phrase]"
done <<'PERM_PHRASES'
~/.claude/settings.json
Agent(zensu:code-reviewer)
permissions.allow
autoMode.allow
is evaluated before
classifier guidance in prose
permission mode
missing check, not an all-clear
cannot judge
Move the rule to permissions.allow
has not verified
has a shape this check cannot judge
switched off by hooks.reviewerSpawnPermissionCheck
a deny rule outranks an allow rule
no agent may edit a settings file to widen its own permissions
no reviewer-spawn exposure found
only settings source this check reads
without being written there
HOME is not set
incomplete (short read)
could not be read —
could not be parsed
contains an entry this check cannot read
failed to run
scopes the Agent or Task tool
could not be determined
missing part of the check
PERM_PHRASES
if [ -z "$PERM_UNEMITTED" ] && [ -z "$PERM_DRIFT" ]; then
  check "P1be every permission-exposure row phrase is both emitted and documented in the skill" PASS
else
  check "P1be permission rows vs skill (not emitted:$PERM_UNEMITTED not documented:$PERM_DRIFT)" FAIL
fi

# P1be asserts BOTH sides — emitted AND documented — so it can only ever pin wording
# the renderer also prints, and it matches each phrase ANYWHERE in the skill. The one
# claim that has no emitted counterpart is therefore invisible to it: the Phase 2
# preamble states that the absence of a `permissions:` row is not an all-clear, which
# is by construction about a row that did not print. Its candidate phrases
# (`~/.claude/settings.json`, `permission mode`) occur five and two times elsewhere in
# the file, so deleting that whole paragraph left P1be green.
#
# This arm pins skill-ONLY claims, and it matches a WHITESPACE-FLATTENED copy on
# purpose: the file wraps its prose, and a line-based `grep -qF` cannot see a sentence
# that spans two lines — which is why the obvious needle for this bound (`never that
# the auto-mode classifier is inactive`) matches zero times as a literal despite being
# written three times.
SKILL_FLAT="$(tr '\n' ' ' < "$SKILL_MD" | tr -s ' ')"
DOC_DRIFT=""
DOC_SEEN=0
while IFS= read -r doc_phrase; do
  [ -n "$doc_phrase" ] || continue
  DOC_SEEN=$((DOC_SEEN+1))
  case "$SKILL_FLAT" in *"$doc_phrase"*) ;; *) DOC_DRIFT="$DOC_DRIFT [$doc_phrase]" ;; esac
done <<'DOC_PHRASES'
prints on every path the check can take, so read the rows rather than their absence
DOC_PHRASES
if [ "$DOC_SEEN" -lt 1 ]; then
  check "P1bw no skill-only phrase was scanned — the arm is vacuous, not clean" FAIL
elif [ -z "$DOC_DRIFT" ]; then
  check "P1bw the skill still states the permission check's own bound ($DOC_SEEN phrase)" PASS
else
  check "P1bw skill no longer states the permission check's own bound:$DOC_DRIFT" FAIL
fi

# The deny-first clause is the one phrase TWO rows depend on, and a whole-file grep
# cannot tell which of them the skill documents. `a deny rule outranks an allow rule`
# is emitted by DENY_FIRST_CAVEAT — consumed by the PROACTIVE ask and exposure rows —
# and it used to occur exactly once in the skill: inside the REACTIVE refused-spawn
# bullet, which P1qr legitimately governs. So P1be reported "emitted and documented"
# for a caveat whose only documentation belonged to a different row, and rewording the
# reactive bullet would have failed both pins while naming the wrong drift. Each bullet
# is now asserted against the region it governs, so the two cannot stand in for each
# other. An EMPTY region is a FAIL, not a pass: a renamed bullet would otherwise make
# the arm vacuous while reading green.
skill_bullet() { # skill_bullet <literal prefix of the bullet line> -> that bullet's lines
  awk -v pfx="$1" 'index($0,pfx)==1 {f=1; print; next} f && /^- \*\*/ {exit} f {print}' "$SKILL_MD"
}
DENY_FIRST_CLAUSE='a deny rule outranks an allow rule'
PERM_BULLET="$(skill_bullet '- **⚠️ permissions:')"
STATE_BULLET="$(skill_bullet '- **⚠️ state: the host permission layer refused')"
BULLET_MISS=""
[ -n "$PERM_BULLET" ]  || BULLET_MISS="$BULLET_MISS [permissions bullet not found]"
[ -n "$STATE_BULLET" ] || BULLET_MISS="$BULLET_MISS [refused-spawn bullet not found]"
case "$PERM_BULLET" in *"$DENY_FIRST_CLAUSE"*) ;; *) BULLET_MISS="$BULLET_MISS [proactive rows]" ;; esac
case "$STATE_BULLET" in *"$DENY_FIRST_CLAUSE"*) ;; *) BULLET_MISS="$BULLET_MISS [reactive row]" ;; esac
if [ -z "$BULLET_MISS" ]; then
  check "P1bx both bullets document the deny-first caveat in their own region" PASS
else
  check "P1bx deny-first caveat missing from the region that governs it:$BULLET_MISS" FAIL
fi

# The reviewer identity is hand-copied across the hooks tree and the only defence used
# to be a by-hand check whose census named one of at least eight sites. A comment cannot
# be made reliable here, but ONE pair can be made machine-checked: this file's constant
# against the module that actually exports it. A rename that updates the exporter and
# forgets this file — the pair most likely to diverge, since the require is lazy and no
# load ever compares them — now fails here instead of silently emitting a row naming an
# agent type that no longer exists. The remaining six files stay unpinned by design; the
# source comment says so and points at the grep rather than at a list.
RA="$(sed -n "s/^var REVIEWER_AGENT = '\(.*\)';$/\1/p" "$REPORT" | head -1)"
if [ -z "$RA" ]; then
  check "P1by could not extract REVIEWER_AGENT from the renderer — the pin is vacuous, not clean" FAIL
elif grep -qF "const REVIEWER_SUBAGENT_TYPE = '$RA';" "$PLUGIN_DIR/hooks/lib/reviewer-spawn-denial-v1.js"; then
  check "P1by REVIEWER_AGENT ('$RA') matches the exporting REVIEWER_SUBAGENT_TYPE" PASS
else
  check "P1by REVIEWER_AGENT ('$RA') has drifted from REVIEWER_SUBAGENT_TYPE in reviewer-spawn-denial-v1.js" FAIL
fi

# --- TTL honored from ZDOC_TTL_HOURS (canonical getter value) --------------
# age ~3548h: default TTL 6 would call it expired; the injected max TTL 8760
# (!= 6) keeps it fresh — proving ZDOC_TTL_HOURS is the value that is honored.
TTL_PROJECT="$SBOX/ttl-project"; TTL_ST="$TTL_PROJECT/.zensu/state"
mkdir -p "$TTL_ST"; : > "$TTL_ST/pending-review.json"
touch -t 202601010000 "$TTL_ST/pending-review.json" 2>/dev/null
FAR="$(ZDOC_ZENSU=absent ZDOC_NODE=vT ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent ZDOC_TTL_HOURS=8760 ZDOC_NOW_MS=1780000000000 \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$TTL_PROJECT" node "$REPORT" 2>/dev/null)"
case "$FAR" in *'within its 8760h TTL'*) check "P4a0 TTL honored from ZDOC_TTL_HOURS (injected 8760 != default 6)" PASS ;; *) check "P4a0 TTL honored (got: $FAR)" FAIL ;; esac
NEAR="$(ZDOC_ZENSU=absent ZDOC_NODE=vT ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent ZDOC_NOW_MS=1780000000000 \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$TTL_PROJECT" node "$REPORT" 2>/dev/null)"
case "$NEAR" in *'(TTL 6h) — expired'*) check "P4a default TTL 6h (getter default) marks the same marker expired" PASS ;; *) check "P4a default TTL 6h expired (got: $NEAR)" FAIL ;; esac

# --- wrapper end-to-end (real toolchain) -----------------------------------
OUT="$(ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" CLAUDE_PROJECT_DIR="$SBOX" bash "$HELPER" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *'Zensu doctor — read-only setup diagnostics'*) check "P4b wrapper runs end-to-end and exits 0" PASS ;; *) check "P4b wrapper header (got: $OUT)" FAIL ;; esac || check "P4b wrapper exit (rc=$RC)" FAIL
if grep -qF 'zensu_pending_review_ttl_hours' "$HELPER" && grep -qF 'zensu-config.sh' "$HELPER"; then
  check "P4d wrapper resolves the TTL through the canonical getter" PASS
else
  check "P4d wrapper resolves the TTL through the canonical getter" FAIL
fi

# --- forge CLI: provider-aware (gh for GitHub, glab for GitLab) -------------
# The code-forge line is driven by the VCS driver's --detect output (ZDOC_FORGE_*),
# NOT a hard-coded gh probe — so a GitLab checkout is told about glab and never
# falsely warned that gh is missing.
forge_report() { # forge_report <provider> <cli> <state> [edition]
  ZDOC_ZENSU=absent ZDOC_NODE=vT ZDOC_PLAYWRIGHT=absent \
  ZDOC_FORGE_PROVIDER="$1" ZDOC_FORGE_CLI="$2" ZDOC_FORGE_STATE="$3" ZDOC_FORGE_EDITION="${4:-cloud}" \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" \
    node "$REPORT" 2>/dev/null
}
case "$(forge_report github gh ready)" in
  *'GitHub CLI (gh): installed and authenticated'*) check "P3a github+ready -> ✅ gh authenticated" PASS ;;
  *) check "P3a github+ready ✅ gh" FAIL ;;
esac
case "$(forge_report github gh unauthed)" in
  *'GitHub CLI (gh): installed but not authenticated'*'gh auth login'*) check "P3a2 github+unauthed -> ⚠️ gh auth login" PASS ;;
  *) check "P3a2 github+unauthed ⚠️" FAIL ;;
esac
case "$(forge_report github gh missing)" in
  *'GitHub CLI (gh): not found on PATH'*unavailable*) check "P3a3 github+missing -> ⚠️ gh not found, PR unavailable" PASS ;;
  *) check "P3a3 github+missing ⚠️" FAIL ;;
esac
case "$(forge_report github gh ready enterprise)" in
  *'GitHub (enterprise) CLI (gh): installed and authenticated'*) check "P3a4 github enterprise edition surfaced" PASS ;;
  *) check "P3a4 github enterprise edition" FAIL ;;
esac
case "$(forge_report gitlab glab ready)" in
  *'GitLab CLI (glab): installed and authenticated'*) check "P3b gitlab+ready -> ✅ glab authenticated" PASS ;;
  *) check "P3b gitlab+ready ✅ glab" FAIL ;;
esac
case "$(forge_report gitlab glab unauthed)" in
  *'GitLab CLI (glab): installed but not authenticated'*'glab auth login'*) check "P3c gitlab+unauthed -> ⚠️ glab auth login" PASS ;;
  *) check "P3c gitlab+unauthed ⚠️" FAIL ;;
esac
case "$(forge_report gitlab glab missing)" in
  *'GitLab CLI (glab): not found on PATH'*unavailable*) check "P3d gitlab+missing -> ⚠️ glab not found, PR unavailable" PASS ;;
  *) check "P3d gitlab+missing ⚠️" FAIL ;;
esac
case "$(forge_report unknown '' missing)" in
  *'no GitHub/GitLab remote detected'*) check "P3e unknown provider -> ⚠️ neutral (no false gh scare)" PASS ;;
  *) check "P3e unknown provider ⚠️ neutral" FAIL ;;
esac
case "$(forge_report gitlab glab ready selfhosted)" in
  *'GitLab (selfhosted) CLI (glab): installed and authenticated'*) check "P3f gitlab self-hosted edition surfaced" PASS ;;
  *) check "P3f gitlab self-hosted edition" FAIL ;;
esac
# defensive: provider known but CLI name empty must take the neutral branch,
# never render a bare "CLI ():" with empty parens (the !fc guard in report.js).
GH_EMPTY="$(forge_report github '' ready)"
case "$GH_EMPTY" in
  *'CLI (): '*) check "P3g empty CLI name never renders 'CLI ():'" FAIL ;;
  *'no GitHub/GitLab remote detected'*) check "P3g provider+empty-cli -> neutral (defensive !fc guard)" PASS ;;
  *) check "P3g provider+empty-cli neutral (got: $GH_EMPTY)" FAIL ;;
esac

# wrapper end-to-end: it must resolve the provider from the git remote through the
# driver's PUBLIC --detect seam, then render the matching CLI line — proving
# doctor.sh is wired to the driver, not still probing gh. ZENSU_VCS_* fakes drive
# detect; ambient ZDOC_FORGE_* are cleared so the guard cannot skip detection.
if grep -qF 'zensu-vcs.sh' "$HELPER" && grep -qF -- '--detect' "$HELPER"; then
  check "P4c wrapper resolves the forge through the driver's public --detect seam" PASS
else
  check "P4c wrapper resolves the forge through the driver's public --detect seam" FAIL
fi
GL="$(ZDOC_FORGE_PROVIDER= ZDOC_FORGE_EDITION= ZDOC_FORGE_CLI= ZDOC_FORGE_STATE= \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" CLAUDE_PROJECT_DIR="$SBOX" \
  ZENSU_VCS_REMOTE='git@gitlab.com:acme/app.git' ZENSU_VCS_TEST=1 ZENSU_VCS_FAKE_AUTH=ready \
  bash "$HELPER" 2>/dev/null)"
case "$GL" in *'GitLab CLI (glab): installed and authenticated'*) check "P4g wrapper detects a gitlab remote -> GitLab glab line" PASS ;; *) check "P4g wrapper gitlab detect (got: $GL)" FAIL ;; esac
case "$GL" in *GitHub*) check "P4h gitlab repo NOT warned about GitHub/gh (the false scare this feature removes)" FAIL ;; *) check "P4h gitlab repo NOT warned about GitHub/gh" PASS ;; esac
GHUB="$(ZDOC_FORGE_PROVIDER= ZDOC_FORGE_EDITION= ZDOC_FORGE_CLI= ZDOC_FORGE_STATE= \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" CLAUDE_PROJECT_DIR="$SBOX" \
  ZENSU_VCS_REMOTE='git@github.com:acme/app.git' ZENSU_VCS_TEST=1 ZENSU_VCS_FAKE_AUTH=ready \
  bash "$HELPER" 2>/dev/null)"
case "$GHUB" in *'GitHub CLI (gh): installed and authenticated'*) check "P4e wrapper detects a github remote -> GitHub gh line" PASS ;; *) check "P4e wrapper github detect (got: $GHUB)" FAIL ;; esac
UNK="$(ZDOC_FORGE_PROVIDER= ZDOC_FORGE_EDITION= ZDOC_FORGE_CLI= ZDOC_FORGE_STATE= \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" CLAUDE_PROJECT_DIR="$SBOX" \
  ZENSU_VCS_REMOTE= ZENSU_VCS_TEST=1 ZENSU_VCS_FAKE_AUTH=ready \
  bash "$HELPER" 2>/dev/null)"
case "$UNK" in *'no GitHub/GitLab remote detected'*) check "P4f wrapper no-remote -> neutral hint (real driver, offline)" PASS ;; *) check "P4f wrapper no-remote neutral (got: $UNK)" FAIL ;; esac

# --- rule-carrier health ---------------------------------------------------
# The row exists because both carriers fail SILENT: an absent, symlinked, oversized
# or malformed rule file exits 0 with no output, no suite runs on an installed tree,
# and the `hooks wiring` row goes green because it only looks at the script. Every
# case below therefore has to DISCRIMINATE — a row that renders unconditionally would
# reintroduce the silence it was added to remove.
case "$OUT" in *'rule carriers: best-solution-first block is intact'*'rule carriers: evidence-discipline block is intact'*)
  check "P5a both carriers report intact on the green fixture" PASS ;;
  *) check "P5a intact rows missing from the green fixture" FAIL ;; esac

RC_BROKEN="$SBOX/plug-broken"
cp -R "$SBOX/plug" "$RC_BROKEN"
node -e '
  const fs = require("fs");
  const p = process.argv[1];
  const L = fs.readFileSync(p, "utf8").split("\n");
  const i = L.indexOf("<!-- zensu:best-solution-first -->");
  if (i < 0) process.exit(1);
  L.splice(i + 2, 0, "a re-wrapped paragraph");
  fs.writeFileSync(p, L.join("\n"));
' "$RC_BROKEN/docs/best-solution-first.md" 2>/dev/null \
  && RC_BROKEN_OUT="$(run_report "$RC_BROKEN" "$SBOX/good-cfg.json" "$STATE_PROJECT")" \
  || RC_BROKEN_OUT="fixture-failed"
case "$RC_BROKEN_OUT" in *'best-solution-first is NOT injecting'*'not carry the block as exactly one line'*)
  check "P5b a re-wrapped block is reported, naming the file and the shape fault" PASS ;;
  *) check "P5b re-wrapped block not reported (got: $RC_BROKEN_OUT)" FAIL ;; esac
case "$RC_BROKEN_OUT" in *'evidence-discipline block is intact'*)
  check "P5c the sibling carrier is judged independently" PASS ;;
  *) check "P5c one broken carrier suppressed the other" FAIL ;; esac

RC_GONE="$SBOX/plug-gone"
cp -R "$SBOX/plug" "$RC_GONE"
rm -f "$RC_GONE/docs/evidence-discipline.md"
case "$(run_report "$RC_GONE" "$SBOX/good-cfg.json" "$STATE_PROJECT")" in
  *'evidence-discipline is NOT injecting'*'absent or unreadable'*)
  check "P5d an absent rule file is reported, not silently tolerated" PASS ;;
  *) check "P5d absent rule file not reported" FAIL ;; esac

# The flag state is the one fault an operator caused on purpose, so it must read as a
# WARNING about a live choice rather than as damage — and the block length proves the
# row still inspected the data instead of short-circuiting on the flag.
RC_OFFCFG="$SBOX/cfg-bsf-off.json"
printf '{"hooks":{"bestSolutionFirst":false}}\n' > "$RC_OFFCFG"
RC_OFF_OUT="$(run_report "$SBOX/plug" "$RC_OFFCFG" "$STATE_PROJECT")"
case "$RC_OFF_OUT" in *'best-solution-first block is intact'*'hooks.bestSolutionFirst is false'*)
  check "P5e a switched-off carrier is distinguished from a broken one" PASS ;;
  *) check "P5e switched-off carrier row (got: $RC_OFF_OUT)" FAIL ;; esac
case "$RC_OFF_OUT" in *'evidence-discipline block is intact'*)
  check "P5f the unswitchable carrier carries no flag clause" PASS ;;
  *) check "P5f unswitchable carrier row changed under a foreign flag" FAIL ;; esac

# A missing module must SAY the check did not run. Falling silent here would be the
# same defect one level up: an operator reading a clean report would conclude the
# carriers are healthy when nothing looked at them.
RC_NOMOD="$SBOX/plug-nomod"
cp -R "$SBOX/plug" "$RC_NOMOD"
rm -f "$RC_NOMOD/hooks/lib/rule-block-v1.js"
RC_NOMOD_OUT="$(run_report "$RC_NOMOD" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$RC_NOMOD_OUT" in *'rule-block-v1.js could not be loaded'*'was NOT checked'*)
  check "P5g a missing reader module reports an unchecked carrier rather than silence" PASS ;;
  *) check "P5g missing reader module (got: $RC_NOMOD_OUT)" FAIL ;; esac
case "$RC_NOMOD_OUT" in *'block is intact'*)
  check "P5h a missing module wrongly still claimed a carrier was intact" FAIL ;;
  *) check "P5h a missing module claims nothing about carrier health" PASS ;; esac

rm -rf "$SBOX"
echo "----"
echo "test-doctor: $PASS PASS / $FAIL FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
