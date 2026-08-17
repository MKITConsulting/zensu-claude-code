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

REAL_MANIFEST="$(ZDOC_ZENSU=absent ZDOC_NODE=vTEST ZDOC_FORGE_PROVIDER=unknown ZDOC_FORGE_CLI='' ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$PLUGIN_DIR" ZENSU_CONFIG="$PLUGIN_DIR/.no-such-doctor-config" CLAUDE_PROJECT_DIR="$PLUGIN_DIR/.no-such-doctor-project" \
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
  && printf '%s\n' "$PHASE3_SKILL" | grep -qF 'PENDING="$STATE_DIR/pending-review.json"' \
  && printf '%s\n' "$PHASE3_SKILL" | grep -qF 'rm -f -- "$PENDING"' \
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
case "$OUT" in *'1 validated CAS workflow document(s); reviewRound/stopBlockCount are integrated fields'*) check "P1m valid CAS workflow document is reported with integrated counters" PASS ;; *) check "P1m valid CAS workflow state (got: $OUT)" FAIL ;; esac
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
case "$OUT" in *'pending-review.json is'*'old (TTL'*'expired'*) check "P1n expired pending-review ⚠️" PASS ;; *) check "P1n expired pending-review ⚠️ (got: $OUT)" FAIL ;; esac
: > "$STATE_DIR_CANON/pending-review.json"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$STATE_PROJECT")"
case "$OUT" in *'pending-review.json present and within'*) check "P1o fresh pending-review ✅" PASS ;; *) check "P1o fresh pending-review ✅ (got: $OUT)" FAIL ;; esac

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
  # The binding itself: a perfectly well-formed note whose session has no
  # workflow document beside it. Every other rejection case here is malformed in
  # some way, so without this the accept path rested entirely on the note's own
  # contents — and this directory is writable from inside the session, which
  # makes "widen your permissions" a row an agent could manufacture for itself.
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
else
  check "P1qk hard links unavailable on this filesystem — skipped" PASS
fi
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

# --- TTL honored from ZDOC_TTL_HOURS (canonical getter value) --------------
# age ~3548h: default TTL 6 would call it expired; the injected max TTL 8760
# (!= 6) keeps it fresh — proving ZDOC_TTL_HOURS is the value that is honored.
TTL_PROJECT="$SBOX/ttl-project"; TTL_ST="$TTL_PROJECT/.zensu/state"
mkdir -p "$TTL_ST"; : > "$TTL_ST/pending-review.json"
touch -t 202601010000 "$TTL_ST/pending-review.json" 2>/dev/null
FAR="$(ZDOC_ZENSU=absent ZDOC_NODE=vT ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent ZDOC_TTL_HOURS=8760 ZDOC_NOW_MS=1780000000000 \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$TTL_PROJECT" node "$REPORT" 2>/dev/null)"
case "$FAR" in *'within its 8760h TTL'*) check "P1ab TTL honored from ZDOC_TTL_HOURS (injected 8760 != default 6)" PASS ;; *) check "P1ab TTL honored (got: $FAR)" FAIL ;; esac
NEAR="$(ZDOC_ZENSU=absent ZDOC_NODE=vT ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent ZDOC_NOW_MS=1780000000000 \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$TTL_PROJECT" node "$REPORT" 2>/dev/null)"
case "$NEAR" in *'(TTL 6h) — expired'*) check "P1ac default TTL 6h (getter default) marks the same marker expired" PASS ;; *) check "P1ac default TTL 6h expired (got: $NEAR)" FAIL ;; esac

# --- wrapper end-to-end (real toolchain) -----------------------------------
OUT="$(ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" CLAUDE_PROJECT_DIR="$SBOX" bash "$HELPER" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *'Zensu doctor — read-only setup diagnostics'*) check "P1ad wrapper runs end-to-end and exits 0" PASS ;; *) check "P1ad wrapper header (got: $OUT)" FAIL ;; esac || check "P1ad wrapper exit (rc=$RC)" FAIL
if grep -qF 'zensu_pending_review_ttl_hours' "$HELPER" && grep -qF 'zensu-config.sh' "$HELPER"; then
  check "P2k wrapper resolves the TTL through the canonical getter" PASS
else
  check "P2k wrapper resolves the TTL through the canonical getter" FAIL
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
  check "P2j wrapper resolves the forge through the driver's public --detect seam" PASS
else
  check "P2j wrapper resolves the forge through the driver's public --detect seam" FAIL
fi
GL="$(ZDOC_FORGE_PROVIDER= ZDOC_FORGE_EDITION= ZDOC_FORGE_CLI= ZDOC_FORGE_STATE= \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" CLAUDE_PROJECT_DIR="$SBOX" \
  ZENSU_VCS_REMOTE='git@gitlab.com:acme/app.git' ZENSU_VCS_TEST=1 ZENSU_VCS_FAKE_AUTH=ready \
  bash "$HELPER" 2>/dev/null)"
case "$GL" in *'GitLab CLI (glab): installed and authenticated'*) check "P2k wrapper detects a gitlab remote -> GitLab glab line" PASS ;; *) check "P2k wrapper gitlab detect (got: $GL)" FAIL ;; esac
case "$GL" in *GitHub*) check "P2k gitlab repo NOT warned about GitHub/gh (the false scare this feature removes)" FAIL ;; *) check "P2k gitlab repo NOT warned about GitHub/gh" PASS ;; esac
GHUB="$(ZDOC_FORGE_PROVIDER= ZDOC_FORGE_EDITION= ZDOC_FORGE_CLI= ZDOC_FORGE_STATE= \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" CLAUDE_PROJECT_DIR="$SBOX" \
  ZENSU_VCS_REMOTE='git@github.com:acme/app.git' ZENSU_VCS_TEST=1 ZENSU_VCS_FAKE_AUTH=ready \
  bash "$HELPER" 2>/dev/null)"
case "$GHUB" in *'GitHub CLI (gh): installed and authenticated'*) check "P2l wrapper detects a github remote -> GitHub gh line" PASS ;; *) check "P2l wrapper github detect (got: $GHUB)" FAIL ;; esac
UNK="$(ZDOC_FORGE_PROVIDER= ZDOC_FORGE_EDITION= ZDOC_FORGE_CLI= ZDOC_FORGE_STATE= \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" CLAUDE_PROJECT_DIR="$SBOX" \
  ZENSU_VCS_REMOTE= ZENSU_VCS_TEST=1 ZENSU_VCS_FAKE_AUTH=ready \
  bash "$HELPER" 2>/dev/null)"
case "$UNK" in *'no GitHub/GitLab remote detected'*) check "P2m wrapper no-remote -> neutral hint (real driver, offline)" PASS ;; *) check "P2m wrapper no-remote neutral (got: $UNK)" FAIL ;; esac

rm -rf "$SBOX"
echo "----"
echo "test-doctor: $PASS PASS / $FAIL FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
