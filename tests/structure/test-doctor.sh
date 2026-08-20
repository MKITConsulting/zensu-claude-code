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
a deny rule outranks an allow rule
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
absent_row_out() { # absent_row_out <label> <output> <needle>
  case "$2" in
    *"$3"*) check "$1 (row present, expected absent)" FAIL ;;
    *"$ANCHOR"*) check "$1" PASS ;;
    *) check "$1 (report never rendered — no anchor in output)" FAIL ;;
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
absent_row "P1an the exact Agent(zensu:code-reviewer) allow rule suppresses every permissions row" \
  "$H_RULE" 'permissions:'
H_BARE="$(settings_home bare '{"permissions":{"defaultMode":"auto","allow":["Agent"]}}')"
absent_row "P1ao the bare Agent allow rule suppresses the exposure row" \
  "$H_BARE" 'permissions:'
# The allow path exercises the SKIP, not a throw: it is called with padded=false,
# so no method is called on the element and a missing guard would just compare
# null === 'Agent'. The throw only happens on the trimming call sites, which is
# what P1ao4 below pins.
H_MIXED="$(settings_home mixed '{"permissions":{"defaultMode":"auto","allow":[null,42,{"a":1},"Agent(zensu:code-reviewer)"]}}')"
absent_row "P1ao1 non-string allow entries are skipped and the exact rule still grants" \
  "$H_MIXED" 'permissions:'
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
case "$(run_report_home "$H_UNJ_MIXED")" in *'in a spelling this check has not verified'*)
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
case "$UNJ_OUT" in *'in a spelling this check has not verified'*)
  check "P1as4 an unverified deny spelling renders the could-not-judge row" PASS ;;
  *) check "P1as4 unjudgeable deny row (got: $UNJ_OUT)" FAIL ;; esac
absent_row "P1as5 the could-not-judge row replaces the exposure row's allow remedy" "$H_UNJUDGE" 'permission mode "auto" is set'
# The ask half of that disjunct, and the ask side of the trim split — both were
# unreachable while every ask fixture used the exact, unpadded spelling.
H_ASK_UNJ="$(settings_home ask-unjudgeable '{"permissions":{"defaultMode":"auto","ask":["Agent(zensu:code-reviewer)*"],"allow":[]}}')"
case "$(run_report_home "$H_ASK_UNJ")" in *'in a spelling this check has not verified'*)
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
absent_row "P1au3 a real grant suppresses the autoMode correction as well" "$H_AM_GRANT" 'permissions:'

H_PLAIN="$(settings_home plain '{"permissions":{"defaultMode":"default","allow":[]}}')"
absent_row "P1av a non-auto mode with no deny/ask renders no permissions row" \
  "$H_PLAIN" 'permissions:'
H_NONE="$SBOX/home-none"; mkdir -p "$H_NONE"
OUT="$(run_report_home "$H_NONE")"; RC=$?
[ "$RC" -eq 0 ] && check "P1aw1 an absent settings file still exits 0" PASS || check "P1aw1 absent settings exit (rc=$RC)" FAIL
absent_row_out "P1aw an absent settings file renders no permissions row" "$OUT" 'permissions:'
# AC-007's other half. Removing the !env.HOME guard does NOT drop one row — it
# throws in path.join and collapses the entire four-block table into the outer
# catch's single line, still exiting 0. The anchor is what notices that.
UNSET_OUT="$( unset HOME; ZDOC_ZENSU=absent ZDOC_NODE="vTEST" ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" node "$REPORT" 2>/dev/null )"; RC=$?
[ "$RC" -eq 0 ] && check "P1aw2a an unset HOME still exits 0" PASS || check "P1aw2a unset HOME exit (rc=$RC)" FAIL
absent_row_out "P1aw2 an unset HOME renders no permissions row and does not collapse the report" "$UNSET_OUT" 'permissions:'
EMPTY_OUT="$( HOME=""; export HOME; ZDOC_ZENSU=absent ZDOC_NODE="vTEST" ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" node "$REPORT" 2>/dev/null )"
absent_row_out "P1aw3 an empty HOME renders no permissions row and does not collapse the report" "$EMPTY_OUT" 'permissions:'

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
case "$BAD_OUT" in *'⚠️  permissions: ~/.claude/settings.json could not be read — unparseable JSON'*'That is a missing check, not an all-clear'*)
  check "P1ay invalid settings JSON renders the did-not-run row, not silence" PASS ;;
  *) check "P1ay invalid settings row (got: $BAD_OUT)" FAIL ;; esac
case "$BAD_OUT" in *DECOYSECRET*) check "P1ay1 the parse failure leaks a slice of the settings file into the report" FAIL ;;
  *) check "P1ay1 no settings byte reaches the report through the failure reason" PASS ;; esac
H_DIR="$SBOX/home-dir"; mkdir -p "$H_DIR/.claude/settings.json"
OUT="$(run_report_home "$H_DIR")"; RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *'could not be read — not a regular file'*)
  check "P1az a directory at the settings path degrades to the did-not-run row" PASS ;;
  *) check "P1az non-regular settings path (got: $OUT)" FAIL ;; esac || check "P1az non-regular settings exit (rc=$RC)" FAIL
# A present key of the wrong SHAPE is a check that could not run. Without the
# Array test these two render identically to a settings file with no rules at
# all, because typeof [] === 'object'.
H_PERMS_ARR="$(settings_home perms-array '{"permissions":[],"autoMode":{}}')"
case "$(run_report_home "$H_PERMS_ARR")" in *'has a shape this check cannot judge — permissions is present but not an object'*)
  check "P1az1 a non-object permissions value degrades to the did-not-run row" PASS ;;
  *) check "P1az1 non-object permissions" FAIL ;; esac
H_AM_ARR="$(settings_home automode-array '{"permissions":{"defaultMode":"auto"},"autoMode":[]}')"
case "$(run_report_home "$H_AM_ARR")" in *'has a shape this check cannot judge — autoMode is present but not an object'*)
  check "P1az2 a non-object autoMode value degrades to the did-not-run row" PASS ;;
  *) check "P1az2 non-object autoMode" FAIL ;; esac
H_ROOT_ARR="$(settings_home root-array '["nope"]')"
case "$(run_report_home "$H_ROOT_ARR")" in *'has a shape this check cannot judge — the settings root is not a JSON object'*)
  check "P1az3 a non-object settings root degrades to the did-not-run row" PASS ;;
  *) check "P1az3 non-object settings root" FAIL ;; esac
# The shape doctrine has to reach the RULE LISTS, not stop at their containers.
# Each of these used to read as "no rules": a non-array deny left the exposure row
# recommending an allow rule while an unevaluated deny key sat in the same file,
# which is a confidently WRONG remedy rather than a missing one.
for rk in allow deny ask; do
  H_RK="$(settings_home "rule-$rk" "{\"permissions\":{\"defaultMode\":\"auto\",\"$rk\":{\"Agent(zensu:code-reviewer)\":true}}}")"
  case "$(run_report_home "$H_RK")" in *"has a shape this check cannot judge — permissions.$rk is present but not an array"*)
    check "P1az5x$rk a non-array permissions.$rk degrades to the did-not-run row" PASS ;;
    *) check "P1az5x$rk non-array permissions.$rk" FAIL ;; esac
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
case "$(run_report_home "$H_UNJ_DEFER")" in *'in a spelling this check has not verified'*)
  check "P1az5i an unverified spelling outranks a deferred shape failure" PASS ;;
  *) check "P1az5i ladder order between could-not-judge and deferred shape" FAIL ;; esac
# Which deferred defect is named, when two are present.
H_DEFER_TWO="$(settings_home defer-two '{"permissions":{"defaultMode":7,"allow":{}}}')"
case "$(run_report_home "$H_DEFER_TWO")" in *'permissions.allow is present but not an array'*)
  check "P1az5j the deferred chain names permissions.allow before defaultMode" PASS ;;
  *) check "P1az5j deferred chain order" FAIL ;; esac
SHAPE_OUT="$(run_report_home "$H_FATAL_DENY")"
H_AMA="$(settings_home automode-allow-str '{"permissions":{"defaultMode":"auto"},"autoMode":{"allow":"nope"}}')"
case "$(run_report_home "$H_AMA")" in *'has a shape this check cannot judge — autoMode.allow is present but not an array'*)
  check "P1az6 a non-array autoMode.allow degrades to the did-not-run row" PASS ;;
  *) check "P1az6 non-array autoMode.allow" FAIL ;; esac
H_MODE_NUM="$(settings_home mode-number '{"permissions":{"defaultMode":7,"allow":[]}}')"
case "$(run_report_home "$H_MODE_NUM")" in *'has a shape this check cannot judge — permissions.defaultMode is present but not a string'*)
  check "P1az7 a non-string defaultMode degrades to the did-not-run row" PASS ;;
  *) check "P1az7 non-string defaultMode" FAIL ;; esac
# The most common real settings file has no permissions key at all. Mutating the
# absent-key branch to plainObject() would make every one of them print a false
# did-not-run WARN, and no other fixture would notice.
H_NO_PERMS="$(settings_home no-perms '{"model":"opus","autoMode":{}}')"
absent_row "P1az8 a settings file with no permissions key renders no permissions row" \
  "$H_NO_PERMS" 'permissions:'
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
else
  check "P1bg FIFO at the settings path — SKIP (mkfifo unavailable on this host)" PASS
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
DOCTOR_HOMELESS=""
DOCTOR_IN_SCOPE=0
for suite in "$PLUGIN_DIR"/tests/structure/*.sh; do
  grep -qE 'zensu-doctor-report\.js|zensu-doctor\.sh' "$suite" 2>/dev/null || continue
  DOCTOR_IN_SCOPE=$((DOCTOR_IN_SCOPE+1))
  grep -qE '(^|[^A-Za-z0-9_])HOME=' "$suite" && continue
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
    perms.deny|perms.ask) grep -qF "FATAL_RULE_KEYS = ['deny', 'ask']" "$REPORT" || SHAPE_UNVETTED="$SHAPE_UNVETTED $k" ;;
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
# Same drift pin the denial rows already carry at P1qr, for the new rows: the
# renderer and skills/doctor/SKILL.md are two hand-written accounts, and without
# this a row could be reworded while the skill keeps naming the old wording.
# Asserted on BOTH sides — against the emitted output so this list cannot go
# stale, and against the skill so the documentation cannot fall behind. The
# output is the concatenation of seven fixture runs because the branches return
# early and no single settings file can render every row.
PERM_ROWS="$EXPOSED_OUT$DENY_OUT$ASK_OUT$AM_OUT$BAD_OUT$UNJ_OUT$SHAPE_OUT"
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
a deny rule outranks an allow rule
PERM_PHRASES
if [ -z "$PERM_UNEMITTED" ] && [ -z "$PERM_DRIFT" ]; then
  check "P1be every permission-exposure row phrase is both emitted and documented in the skill" PASS
else
  check "P1be permission rows vs skill (not emitted:$PERM_UNEMITTED not documented:$PERM_DRIFT)" FAIL
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

rm -rf "$SBOX"
echo "----"
echo "test-doctor: $PASS PASS / $FAIL FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
