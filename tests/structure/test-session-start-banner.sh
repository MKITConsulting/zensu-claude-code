#!/bin/bash
# NOT GRADED HERE: the banner's _ZENSU_ROUTE_QUESTION_LIVE guard and both delivery
# route tips are pinned by D26/D27/D29/D30 in test-plan-approved-delegate.sh, and
# the four-route IF-branch tip additionally by BNR2c in test-tdd-vanilla-mode.sh; the
# guard's fourth arm and the hooks.defaultDeliveryRoute disclosure by R14 in
# test-delivery-route.sh.
set -u

# Pins the SessionStart "Zensu active" banner + agent primer (0.4.0):
# user banner via systemMessage, agent primer via additionalContext, both gated by
# hooks.sessionBanner and firing only on fresh starts (startup/clear).

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BANNER="$PLUGIN_DIR/hooks/session-start-banner.sh"
PRIMER="$PLUGIN_DIR/hooks/session-start-primer.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

[ -f "$BANNER" ] && [ -x "$BANNER" ] && check "B1 banner hook exists + executable" PASS || check "B1 banner hook exists + executable" FAIL
[ -f "$PRIMER" ] && [ -x "$PRIMER" ] && check "B2 primer hook exists + executable" PASS || check "B2 primer hook exists + executable" FAIL

if node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const ss=(h.hooks.SessionStart||[]).flatMap(x=>x.hooks||[]).map(z=>z.command||"");
  const hasB=ss.some(c=>/session-start-banner\.sh/.test(c));
  const hasP=ss.some(c=>/session-start-primer\.sh/.test(c));
  process.exit(hasB && hasP ? 0 : 1);
' "$HOOKS_JSON" 2>/dev/null; then
  check "B3 both hooks registered in hooks.json SessionStart" PASS
else
  check "B3 both hooks registered in hooks.json SessionStart" FAIL
fi

if grep -qF 'zensu_hook_enabled sessionBanner' "$BANNER" && grep -qF 'zensu_hook_enabled sessionBanner' "$PRIMER"; then
  check "B4 both gated by hooks.sessionBanner" PASS
else
  check "B4 both gated by hooks.sessionBanner" FAIL
fi

if grep -qF 'resume|compact' "$BANNER" && grep -qF 'startup|clear' "$PRIMER" \
  && grep -qF 'j.hook_event_name!=="SessionStart"' "$PRIMER"; then
  check "B5 fresh-start filter accepts only SessionStart startup/clear" PASS
else
  check "B5 fresh-start filter accepts only SessionStart startup/clear" FAIL
fi

if grep -qF 'zensu_directive_substitute ZENSU_LOG_COMMAND "$LOG_COMMAND"' "$PRIMER" \
  && grep -qF 'source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-directive.sh"' "$PRIMER" \
  && grep -qF 'MSYS2_ENV_CONV_EXCL="$msys_env_exclusions" node -e' "$PLUGIN_DIR/hooks/lib/zensu-directive.sh"; then
  check "B5a primer preserves its pre-quoted model command across MSYS env conversion" PASS
else
  check "B5a primer preserves its pre-quoted model command across MSYS env conversion" FAIL
fi

if grep -qF '/zensu:build' "$BANNER" && grep -qF 'Zensu PLM' "$BANNER" && grep -qF 'hooks.sessionBanner=false' "$BANNER"; then
  check "B6 banner mentions Zensu PLM + /zensu:build + opt-out hint" PASS
else
  check "B6 banner mentions Zensu PLM + /zensu:build + opt-out hint" FAIL
fi
if grep -qF '/zensu:tdd-manager' "$BANNER"; then
  check "B7 banner has NO stale /zensu:tdd-manager" FAIL
else
  check "B7 banner has NO stale /zensu:tdd-manager" PASS
fi

if grep -qF 'Plan mode' "$PRIMER" && grep -qF '/zensu:build' "$PRIMER"; then
  check "B8 primer mentions Plan mode + /zensu:build" PASS
else
  check "B8 primer mentions Plan mode + /zensu:build" FAIL
fi
if grep -qF '/zensu:tdd-manager' "$PRIMER"; then
  check "B9 primer has NO stale /zensu:tdd-manager" FAIL
else
  check "B9 primer has NO stale /zensu:tdd-manager" PASS
fi

# Behavioral (hermetic: force default-enabled via a non-existent config path).
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
PRIMER_DATA_BASE="$(mktemp -d -t zensu-primer-data-XXXXXX)"
mkdir -p "$PRIMER_DATA_BASE/plugin data"
export CLAUDE_PLUGIN_DATA="$PRIMER_DATA_BASE/plugin data"
export ZENSU_CONFIG="$PLUGIN_DIR/.no-such-config-$$.json"

OUT_START="$(printf '%s' '{"source":"startup"}' | bash "$BANNER" 2>/dev/null)"
[ -n "$OUT_START" ] && check "B10 banner emits on source=startup" PASS || check "B10 banner emits on source=startup" FAIL
if printf '%s' "$OUT_START" | node -e '
  let s=""; process.stdin.on("data",c=>s+=c);
  process.stdin.on("end",()=>{ try { const j=JSON.parse(s);
    const h=j.hookSpecificOutput||{};
    const ok = typeof j.systemMessage==="string"
      && j.systemMessage.split("\n").some(l=>/^zensu: Zensu PLM v\S+ active/.test(l))
      && h.hookEventName==="SessionStart" && h.additionalContext===j.systemMessage;
    process.exit(ok?0:1); } catch(_){ process.exit(1); } });
'; then
  check "B10b banner reaches the user as systemMessage and the model as the same additionalContext" PASS
else
  check "B10b banner reaches the user as systemMessage and the model as the same additionalContext" FAIL
fi

OUT_RESUME="$(printf '%s' '{"source":"resume"}' | bash "$BANNER" 2>/dev/null)"
[ -z "$OUT_RESUME" ] && check "B11 banner silent on source=resume" PASS || check "B11 banner silent on source=resume" FAIL
OUT_CONSENT="$(printf '%s' '{"source":"startup"}' | env -u ZENSU_VERIFY_NAVIGATION_POLICY_V1 bash "$BANNER" 2>/dev/null)"
case "$OUT_CONSENT" in
  *'Browser verification'*'consent mode'*'playwright-cli'*'once per session for each loopback origin'*'at every browser start for a remote HTTPS origin'*'bypass permissions or dontAsk'*'/zensu:doctor'*) check "B11a banner names consent mode, the playwright-cli driver, the loopback and remote prompt cadence, the modes that need the policy and /zensu:doctor when no policy is set" PASS ;;
  *) check "B11a banner names consent mode, the playwright-cli driver, the loopback and remote prompt cadence, the modes that need the policy and /zensu:doctor when no policy is set" FAIL ;;
esac
OUT_POLICY="$(printf '%s' '{"source":"startup"}' | ZENSU_VERIFY_NAVIGATION_POLICY_V1='{"version":1}' bash "$BANNER" 2>/dev/null)"
case "$OUT_POLICY" in
  *'consent mode'*) check "B11b banner drops the consent line when a parent policy is present" FAIL ;;
  *) check "B11b banner drops the consent line when a parent policy is present" PASS ;;
esac
QUIET_CONFIG="$(mktemp "${TMPDIR:-/tmp}/zensu-banner-quiet.XXXXXX")" || exit 1
printf '%s\n' '{"hooks":{"sessionBanner":false}}' >"$QUIET_CONFIG"
OUT_QUIET="$(printf '%s' '{"source":"startup"}' | env -u ZENSU_VERIFY_NAVIGATION_POLICY_V1 ZENSU_CONFIG="$QUIET_CONFIG" bash "$BANNER" 2>/dev/null)"
case "$OUT_QUIET" in
  *'consent mode'*) check "B11c hooks.sessionBanner=false silences the consent line" FAIL ;;
  *) check "B11c hooks.sessionBanner=false silences the consent line" PASS ;;
esac
case "$OUT_QUIET" in
  *'Reviewer spawns'*) check "B11c-grant the reviewer-spawn grant line still survives the flag, as its own comment requires" PASS ;;
  *) check "B11c-grant the reviewer-spawn grant line still survives the flag, as its own comment requires" FAIL ;;
esac
OUT_QUIET_CONTROL="$(printf '%s' '{"source":"startup"}' | env -u ZENSU_VERIFY_NAVIGATION_POLICY_V1 bash "$BANNER" 2>/dev/null)"
case "$OUT_QUIET_CONTROL" in
  *'consent mode'*) check "B11c-control the same invocation without the flag does emit the consent line" PASS ;;
  *) check "B11c-control the same invocation without the flag does emit the consent line" FAIL ;;
esac
rm -f "$QUIET_CONFIG"

PS_BASE="$(mktemp -d -t zensu-banner-powershell-XXXXXX)"
PS_FIXTURE() {
  local name="$1" matcher="$2" root
  root="$PS_BASE/$name"
  mkdir -p "$root/hooks/lib" "$root/.claude-plugin"
  cp "$BANNER" "$root/hooks/session-start-banner.sh"
  cp "$PLUGIN_DIR/hooks/lib/zensu-config.sh" "$root/hooks/lib/zensu-config.sh"
  cp "$PLUGIN_DIR/hooks/lib/shell-tool-coverage-v1.js" "$root/hooks/lib/shell-tool-coverage-v1.js"
  cp "$PLUGIN_DIR/hooks/lib/hook-registration-v1.js" "$root/hooks/lib/hook-registration-v1.js"
  printf '{"name":"zensu","version":"9.9.9"}\n' > "$root/.claude-plugin/plugin.json"
  printf '{"hooks":{"PreToolUse":[{"matcher":"%s","hooks":[{"type":"command","command":"bash \\"${CLAUDE_PLUGIN_ROOT}/hooks/gate.sh\\""}]}]}}\n' "$matcher" > "$root/hooks/hooks.json"
  (cd "$root" && pwd -P)
}
PS_RUN() {
  local root="$1" source="$2" value="$3" config="${4:-$ZENSU_CONFIG}"
  if [ "$value" = unset ]; then
    printf '{"source":"%s"}' "$source" | env -u CLAUDE_CODE_USE_POWERSHELL_TOOL CLAUDE_PLUGIN_ROOT="$root" ZENSU_CONFIG="$config" \
      bash "$root/hooks/session-start-banner.sh" 2>/dev/null
  else
    printf '{"source":"%s"}' "$source" | CLAUDE_CODE_USE_POWERSHELL_TOOL="$value" CLAUDE_PLUGIN_ROOT="$root" ZENSU_CONFIG="$config" \
      bash "$root/hooks/session-start-banner.sh" 2>/dev/null
  fi
}
PS_GAP_ROOT="$(PS_FIXTURE bash-only Bash)"
PS_COVERED_ROOT="$(PS_FIXTURE covered 'Bash|PowerShell')"
PS_QUIET_CONFIG="$PS_BASE/quiet.json"
printf '%s\n' '{"hooks":{"sessionBanner":false}}' > "$PS_QUIET_CONFIG"
PS_ON="$(PS_RUN "$PS_GAP_ROOT" startup 1)"
case "$PS_ON" in
  *'zensu: ⚠ PowerShell tool — '*'PowerShell tool is enabled here'*'1 of Zensu'*'CLAUDE_CODE_USE_POWERSHELL_TOOL=0'*'/zensu:doctor'*) check "B16 the PowerShell tool warning names the enabled tool, the gap count, the remedy and /zensu:doctor" PASS ;;
  *) check "B16 the PowerShell tool warning names the enabled tool, the gap count, the remedy and /zensu:doctor (got: $PS_ON)" FAIL ;;
esac
case "$(PS_RUN "$PS_GAP_ROOT" startup 1 "$PS_QUIET_CONFIG")" in
  *'zensu: ⚠ PowerShell tool'*) check "B16a the PowerShell tool warning sits above the sessionBanner gate" PASS ;;
  *) check "B16a the PowerShell tool warning sits above the sessionBanner gate" FAIL ;;
esac
case "$(PS_RUN "$PS_GAP_ROOT" resume 1)" in
  *'PowerShell tool'*) check "B16b the PowerShell tool warning stays silent on source=resume" FAIL ;;
  *) check "B16b the PowerShell tool warning stays silent on source=resume" PASS ;;
esac
case "$(PS_RUN "$PS_GAP_ROOT" startup 0)" in
  *'PowerShell tool'*) check "B16c CLAUDE_CODE_USE_POWERSHELL_TOOL=0 silences the warning" FAIL ;;
  *) check "B16c CLAUDE_CODE_USE_POWERSHELL_TOOL=0 silences the warning" PASS ;;
esac
case "$(PS_RUN "$PS_COVERED_ROOT" startup 1)" in
  *'zensu: ⚠ PowerShell tool'*) check "B16d a hook registered on Bash|PowerShell raises no warning and names what to run through the Bash tool" FAIL ;;
  *'zensu: PowerShell tool — '*'judge PowerShell commands too'*'Use the Bash tool'*'hooks.bashWriteGate'*) check "B16d a hook registered on Bash|PowerShell raises no warning and names what to run through the Bash tool" PASS ;;
  *) check "B16d a hook registered on Bash|PowerShell raises no warning and names what to run through the Bash tool" FAIL ;;
esac
case "$(PS_RUN "$PS_COVERED_ROOT" startup 1 "$PS_QUIET_CONFIG")" in
  *'PowerShell tool'*) check "B16h the Bash-tool guidance sits below the sessionBanner gate" FAIL ;;
  *) check "B16h the Bash-tool guidance sits below the sessionBanner gate" PASS ;;
esac
case "$(PS_RUN "$PS_COVERED_ROOT" startup 0)" in
  *'PowerShell tool'*) check "B16h2 CLAUDE_CODE_USE_POWERSHELL_TOOL=0 silences the Bash-tool guidance" FAIL ;;
  *) check "B16h2 CLAUDE_CODE_USE_POWERSHELL_TOOL=0 silences the Bash-tool guidance" PASS ;;
esac
PS_DEFAULT="$(PS_RUN "$PS_GAP_ROOT" startup unset)"
if [ "$(node -p 'process.platform')" = "win32" ]; then
  case "$PS_DEFAULT" in
    *'zensu: ⚠ PowerShell tool — '*'on by default for claude.ai and Console accounts'*) check "B16e on Windows an unset CLAUDE_CODE_USE_POWERSHELL_TOOL warns that the tool is on by default" PASS ;;
    *) check "B16e on Windows an unset CLAUDE_CODE_USE_POWERSHELL_TOOL warns that the tool is on by default (got: $PS_DEFAULT)" FAIL ;;
  esac
else
  case "$PS_DEFAULT" in
    *'PowerShell tool'*) check "B16e off Windows an unset CLAUDE_CODE_USE_POWERSHELL_TOOL raises no warning" FAIL ;;
    *) check "B16e off Windows an unset CLAUDE_CODE_USE_POWERSHELL_TOOL raises no warning" PASS ;;
  esac
fi
PS_EXPECTED="$(node -e '
  const m = require(process.argv[1]);
  const manifest = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
  const environment = { CLAUDE_CODE_USE_POWERSHELL_TOOL: "1" };
  process.stdout.write(m.bannerLine(manifest, environment, process.platform) || m.steerLine(manifest, environment, process.platform));
' "$PLUGIN_DIR/hooks/lib/shell-tool-coverage-v1.js" "$HOOKS_JSON" 2>/dev/null)"
PS_REAL="$(printf '%s' '{"source":"startup"}' | CLAUDE_CODE_USE_POWERSHELL_TOOL=1 bash "$BANNER" 2>/dev/null | node -e '
  let s = ""; process.stdin.on("data", (c) => { s += c; });
  process.stdin.on("end", () => { try { process.stdout.write(JSON.parse(s).systemMessage); } catch (_) { process.exit(1); } });
' 2>/dev/null | grep -E '^zensu: (⚠ )?PowerShell tool' || true)"
{ [ -n "$PS_EXPECTED" ] && [ "$PS_REAL" = "$PS_EXPECTED" ]; } \
  && check "B16f the shipped banner prints exactly the line the coverage module derives from hooks/hooks.json" PASS \
  || check "B16f the shipped banner prints exactly the line the coverage module derives from hooks/hooks.json (banner: $PS_REAL; module: $PS_EXPECTED)" FAIL
if node -e '
  const m = require(process.argv[1]);
  const gap = { hooks: { PostToolUse: [{ matcher: "Bash", hooks: [{ command: "bash x/hooks/post.sh" }] }] } };
  const both = { hooks: { PostToolUse: [{ matcher: "Bash|PowerShell", hooks: [{ command: "bash x/hooks/post.sh" }] }] } };
  const all = { hooks: { PreToolUse: [{ matcher: ".*", hooks: [{ command: "bash x/hooks/pre.sh" }] }] } };
  const ok = m.bannerLine(gap, {}, "win32").includes("on by default")
    && m.bannerLine(gap, {}, "darwin") === ""
    && m.bannerLine(gap, { CLAUDE_CODE_USE_POWERSHELL_TOOL: "0" }, "win32") === ""
    && m.bannerLine(gap, { CLAUDE_CODE_USE_POWERSHELL_TOOL: " TRUE " }, "linux").includes("is enabled here")
    && m.bannerLine(both, {}, "win32") === ""
    && m.bannerLine(all, {}, "win32") === ""
    && m.bannerLine(null, { CLAUDE_CODE_USE_POWERSHELL_TOOL: "1" }, "linux").includes("could not read hooks/hooks.json")
    && m.steerLine(both, {}, "win32").includes("Use the Bash tool")
    && m.steerLine(both, { CLAUDE_CODE_USE_POWERSHELL_TOOL: "1" }, "linux") === m.steerLine(both, {}, "win32")
    && m.steerLine(both, {}, "darwin") === ""
    && m.steerLine(both, { CLAUDE_CODE_USE_POWERSHELL_TOOL: "0" }, "win32") === ""
    && m.steerLine(gap, {}, "win32") === ""
    && m.steerLine(null, { CLAUDE_CODE_USE_POWERSHELL_TOOL: "1" }, "linux") === ""
    && m.shellCoverage({ hooks: [] }) === null
    && m.shellCoverage({}).gaps.length === 0;
  process.exit(ok ? 0 : 1);
' "$PLUGIN_DIR/hooks/lib/shell-tool-coverage-v1.js" 2>/dev/null; then
  check "B16g the coverage module warns only for a host that may run PowerShell and a hook that fires for Bash alone" PASS
else
  check "B16g the coverage module warns only for a host that may run PowerShell and a hook that fires for Bash alone" FAIL
fi
rm -rf "$PS_BASE"

PRIMER_START="$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' | bash "$PRIMER" 2>/dev/null)"
if printf '%s' "$PRIMER_START" | node -e '
  let s=""; process.stdin.on("data",c=>s+=c);
  process.stdin.on("end",()=>{ try { const j=JSON.parse(s);
    const ok = j.hookSpecificOutput && j.hookSpecificOutput.hookEventName==="SessionStart"
      && typeof j.hookSpecificOutput.additionalContext==="string"
      && j.hookSpecificOutput.additionalContext.length>0;
    process.exit(ok?0:1); } catch(_){ process.exit(1); } });
'; then
  check "B12 primer emits valid SessionStart additionalContext JSON on startup" PASS
else
  check "B12 primer emits valid SessionStart additionalContext JSON on startup" FAIL
fi
EXPECTED_START_HELPER_Q="$(printf '%q' "$PLUGIN_DIR/hooks/lib/zensu-log.sh")"
EXPECTED_START_DATA_Q="$(printf '%q' "$CLAUDE_PLUGIN_DATA")"
PRIMER_START_CTX="$(printf '%s' "$PRIMER_START" | node -e '
  try { process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).hookSpecificOutput.additionalContext); }
  catch (_) { process.exit(1); }
' 2>/dev/null)"
if printf '%s' "$PRIMER_START_CTX" | grep -qF "CLAUDE_PLUGIN_DATA=$EXPECTED_START_DATA_Q bash $EXPECTED_START_HELPER_Q --tdd-begin" \
  && ! printf '%s' "$PRIMER_START_CTX" | grep -qF '__ZENSU_LOG_COMMAND__' \
  && ! printf '%s' "$PRIMER_START_CTX" | grep -qF '${ZENSU_CLAUDE_PLUGIN_ROOT}'; then
  check "B12b primer output embeds quoted plugin data and concrete helper tokens" PASS
else
  check "B12b primer output embeds quoted plugin data and concrete helper tokens" FAIL
fi

# Session Control grants main-v1 only when both agent fields are absent. The
# orientation hook must make the same decision for top-level `claude --agent`
# and partial host payloads so no custom-agent principal sees main instructions.
PRIMER_AGENT_TYPE="$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup","agent_type":"zensu-plm"}' | bash "$PRIMER" 2>/dev/null)"
PRIMER_AGENT_ID="$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup","agent_id":"custom-agent-1"}' | bash "$PRIMER" 2>/dev/null)"
PRIMER_PARTIAL_EMPTY="$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup","agent_type":""}' | bash "$PRIMER" 2>/dev/null)"
if [ -z "$PRIMER_AGENT_TYPE" ] && [ -z "$PRIMER_AGENT_ID" ] && [ -z "$PRIMER_PARTIAL_EMPTY" ]; then
  check "B12c top-level --agent and partial principals receive no main primer" PASS
else
  check "B12c top-level --agent and partial principals receive no main primer" FAIL
fi

primer_context() {
  printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' | env -u ZENSU_SESSION_TOKEN "$@" bash "$PRIMER" 2>/dev/null | node -e '
    try { process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).hookSpecificOutput.additionalContext); }
    catch (_) { process.exit(1); }
  ' 2>/dev/null
}
PRIMER_AUTH_PLAIN="$(primer_context)"
PRIMER_AUTH_TOKEN="$(primer_context ZENSU_SESSION_TOKEN=zst_primer_case)"
if printf '%s' "$PRIMER_AUTH_PLAIN" | grep -qF 'Use /zensu:zensu-help to answer questions about Zensu. Zensu CLI auth recovery:' \
  && printf '%s' "$PRIMER_AUTH_PLAIN" | grep -qF 'run zensu auth login yourself' \
  && printf '%s' "$PRIMER_AUTH_TOKEN" | grep -qF 'Use /zensu:zensu-help to answer questions about Zensu. This is a one-time per-session orientation' \
  && printf '%s' "$PRIMER_AUTH_TOKEN" | grep -qF -- "--tdd-begin" \
  && ! printf '%s' "$PRIMER_AUTH_TOKEN" | grep -qF 'auth login' \
  && ! printf '%s%s' "$PRIMER_AUTH_PLAIN" "$PRIMER_AUTH_TOKEN" | grep -qF '__ZENSU_CLI_AUTH__'; then
  check "B12d the primer keeps the zensu auth login recovery out of a session that holds ZENSU_SESSION_TOKEN and gives it to every other session" PASS
else
  check "B12d the primer keeps the zensu auth login recovery out of a session that holds ZENSU_SESSION_TOKEN and gives it to every other session" FAIL
fi

PRIMER_COMPACT="$(printf '%s' '{"hook_event_name":"SessionStart","source":"compact"}' | bash "$PRIMER" 2>/dev/null)"
[ -z "$PRIMER_COMPACT" ] && check "B13 primer silent on source=compact" PASS || check "B13 primer silent on source=compact" FAIL

PRIMER_MISSING_SOURCE="$(printf '%s' '{"hook_event_name":"SessionStart"}' | bash "$PRIMER" 2>/dev/null)"
PRIMER_UNKNOWN_SOURCE="$(printf '%s' '{"hook_event_name":"SessionStart","source":"other"}' | bash "$PRIMER" 2>/dev/null)"
PRIMER_WRONG_EVENT="$(printf '%s' '{"hook_event_name":"SubagentStart","source":"startup"}' | bash "$PRIMER" 2>/dev/null)"
PRIMER_MISSING_DATA="$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' | env -u CLAUDE_PLUGIN_DATA bash "$PRIMER" 2>/dev/null)"
if [ -z "$PRIMER_MISSING_SOURCE" ] && [ -z "$PRIMER_UNKNOWN_SOURCE" ] \
  && [ -z "$PRIMER_WRONG_EVENT" ] && [ -z "$PRIMER_MISSING_DATA" ]; then
  check "B13a primer rejects missing/unknown source, wrong event, and missing plugin data" PASS
else
  check "B13a primer rejects missing/unknown source, wrong event, and missing plugin data" FAIL
fi

STRICT_CONFIG="$(mktemp -t zensu-primer-strict-XXXXXX)"
printf '%s\n' '{"hooks":{"tddImplementation":true}}' > "$STRICT_CONFIG"
PRIMER_STRICT="$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' | ZENSU_CONFIG="$STRICT_CONFIG" bash "$PRIMER" 2>/dev/null)"
rm -f "$STRICT_CONFIG"
if printf '%s' "$PRIMER_STRICT" | grep -qF "$PLUGIN_DIR/hooks/lib/zensu-log.sh" \
  && ! printf '%s' "$PRIMER_STRICT" | grep -qF '${CLAUDE_PLUGIN_ROOT}'; then
  check "B14 strict primer embeds the concrete session plugin root" PASS
else
  check "B14 strict primer embeds the concrete session plugin root" FAIL
fi

# Regression: the concrete root is serialized through JSON and then shown as a
# runnable shell token. Spaces, command substitutions, backticks, semicolons,
# quotes, and backslashes must stay data rather than becoming shell syntax.
SPECIAL_BASE="$(mktemp -d -t zensu-primer-root-XXXXXX)"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    SPECIAL_ROOT="$SPECIAL_BASE/"'plugin root $(touch PRIMER_PWNED) `touch PRIMER_TICKED`;touch PRIMER_SEMI; apostrophe'"'"'value [windows]'
    ;;
  *)
    SPECIAL_ROOT="$SPECIAL_BASE/"'plugin root $(touch PRIMER_PWNED) `touch PRIMER_TICKED`;touch PRIMER_SEMI; apostrophe'"'"'value quote"back\slash'$'\nnewline'
    ;;
esac
mkdir -p "$SPECIAL_ROOT/hooks/lib" "$SPECIAL_BASE/run"
SPECIAL_CANONICAL_ROOT="$(cd "$SPECIAL_ROOT" && pwd -P)"
cp "$PRIMER" "$SPECIAL_ROOT/hooks/session-start-primer.sh"
cp "$PLUGIN_DIR/hooks/lib/zensu-config.sh" "$SPECIAL_ROOT/hooks/lib/zensu-config.sh"
cp "$PLUGIN_DIR/hooks/lib/zensu-directive.sh" "$SPECIAL_ROOT/hooks/lib/zensu-directive.sh"
cp "$PLUGIN_DIR/hooks/lib/zensu-msys-env.sh" "$SPECIAL_ROOT/hooks/lib/zensu-msys-env.sh"
cp "$PLUGIN_DIR/hooks/lib/claude-principal-v1.js" "$SPECIAL_ROOT/hooks/lib/claude-principal-v1.js"
cp "$PLUGIN_DIR/hooks/lib/zensu-agent-context.sh" "$SPECIAL_ROOT/hooks/lib/zensu-agent-context.sh"
printf '%s\n' '#!/bin/bash' \
  '[ -d "${CLAUDE_PLUGIN_DATA:-}" ] || exit 7' \
  ': > "$CLAUDE_PLUGIN_DATA/PRIMER_EXECUTED"' > "$SPECIAL_ROOT/hooks/lib/zensu-log.sh"
chmod +x "$SPECIAL_ROOT/hooks/lib/zensu-log.sh"
printf '%s\n' '{"hooks":{"tddImplementation":true}}' > "$SPECIAL_BASE/strict.json"
SPECIAL_PLUGIN_DATA="$SPECIAL_BASE/"'plugin data $(touch PRIMER_DATA_PWNED) `touch PRIMER_DATA_TICKED`;touch PRIMER_DATA_SEMI; apostrophe'"'"'value'
mkdir -p "$SPECIAL_PLUGIN_DATA"
PRIMER_SPECIAL="$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' | CLAUDE_PLUGIN_ROOT="$SPECIAL_CANONICAL_ROOT" \
  CLAUDE_PLUGIN_DATA="$SPECIAL_PLUGIN_DATA" ZENSU_CONFIG="$SPECIAL_BASE/strict.json" \
  bash "$SPECIAL_ROOT/hooks/session-start-primer.sh" 2>/dev/null)"
EXPECTED_Q="$(printf '%q' "$SPECIAL_CANONICAL_ROOT/hooks/lib/zensu-log.sh")"
EXPECTED_DATA_Q="$(printf '%q' "$SPECIAL_PLUGIN_DATA")"
EXPECTED_COMMAND="CLAUDE_PLUGIN_DATA=$EXPECTED_DATA_Q bash $EXPECTED_Q --tdd-begin"
SPECIAL_CTX="$(printf '%s' "$PRIMER_SPECIAL" | node -e '
  let s=""; process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      const out = j.hookSpecificOutput || {};
      if (out.hookEventName !== "SessionStart" || typeof out.additionalContext !== "string") process.exit(2);
      process.stdout.write(out.additionalContext);
    } catch (_) { process.exit(1); }
  });
' 2>/dev/null)"
SPECIAL_PARSE_RC=$?
SPECIAL_MSYS_EXCL="EXPECTED"
[ -z "${MSYS2_ENV_CONV_EXCL:-}" ] || SPECIAL_MSYS_EXCL="${MSYS2_ENV_CONV_EXCL};${SPECIAL_MSYS_EXCL}"
SPECIAL_EMITTED_COMMAND="$(printf '%s' "$SPECIAL_CTX" | MSYS2_ENV_CONV_EXCL="$SPECIAL_MSYS_EXCL" EXPECTED="$EXPECTED_COMMAND" node -e '
  const body=require("fs").readFileSync(0,"utf8"), expected=process.env.EXPECTED;
  const at=body.indexOf(expected);
  if(at<0)process.exit(1);
  process.stdout.write(body.slice(at, at+expected.length));
' 2>/dev/null)"
SPECIAL_COMMAND_RC=$?
(
  cd "$SPECIAL_BASE/run" || exit 1
  unset CLAUDE_PLUGIN_DATA
  eval "$SPECIAL_EMITTED_COMMAND" >/dev/null 2>&1
)
SPECIAL_EXEC_RC=$?
SPECIAL_MARKER_OK=false
if [ -f "$SPECIAL_PLUGIN_DATA/PRIMER_EXECUTED" ]; then
  SPECIAL_MARKER_OK=true
fi
if [ "$SPECIAL_PARSE_RC" = "0" ] && [ "$SPECIAL_COMMAND_RC" = "0" ] && [ "$SPECIAL_EXEC_RC" = "0" ] \
  && printf '%s' "$SPECIAL_CTX" | grep -qF "$EXPECTED_COMMAND" \
  && ! printf '%s' "$SPECIAL_CTX" | grep -qF '${CLAUDE_PLUGIN_ROOT}' \
  && [ "$SPECIAL_MARKER_OK" = true ] \
  && [ ! -e "$SPECIAL_BASE/run/PRIMER_PWNED" ] \
  && [ ! -e "$SPECIAL_BASE/run/PRIMER_TICKED" ] \
  && [ ! -e "$SPECIAL_BASE/run/PRIMER_SEMI" ] \
  && [ ! -e "$SPECIAL_BASE/run/PRIMER_DATA_PWNED" ] \
  && [ ! -e "$SPECIAL_BASE/run/PRIMER_DATA_TICKED" ] \
  && [ ! -e "$SPECIAL_BASE/run/PRIMER_DATA_SEMI" ]; then
  check "B15 emitted command executes with inert quoted root and plugin data" PASS
else
  check "B15 emitted command executes with inert quoted root and plugin data (parse=$SPECIAL_PARSE_RC command=$SPECIAL_COMMAND_RC exec=$SPECIAL_EXEC_RC marker=$SPECIAL_MARKER_OK)" FAIL
fi
rm -rf "$SPECIAL_BASE"

ZC_BASE="$(mktemp -d -t zensu-banner-cli-XXXXXX)"
ZC_FAKE="$ZC_BASE/fake"
ZC_NODE_ONLY="$ZC_BASE/node-only"
ZC_LOG="$ZC_BASE/calls.log"
mkdir -p "$ZC_FAKE" "$ZC_NODE_ONLY"
printf '%s\n' '#!/bin/sh' 'printf "%s|%s\n" "${ZENSU_NO_UPDATE_CHECK:-unset}" "$*" >> "$ZC_LOG"' 'printf "%s\n" "$ZC_VERSION_LINE"' > "$ZC_FAKE/zensu"
chmod +x "$ZC_FAKE/zensu"
ln -s "$(command -v node)" "$ZC_NODE_ONLY/node"
ZC_FLOOR="$(node -e 'process.stdout.write(require(process.argv[1]).MIN_VERSION)' "$PLUGIN_DIR/hooks/lib/zensu-cli-version-v1.js")"
zc_banner() {
  printf '%s' '{"source":"startup"}' | env -u ZENSU_VERIFY_NAVIGATION_POLICY_V1 -u ZENSU_NO_UPDATE_CHECK -u ZENSU_SESSION_TOKEN PATH="$1" ZC_LOG="$ZC_LOG" ZC_VERSION_LINE="$2" "${@:3}" bash "$BANNER" 2>/dev/null
}
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) check "B16a-B16e the CLI line reads a shell-script zensu for its version (covered on macOS/Linux/WSL)" PASS ;;
  *)
    ZC_OLD="$(zc_banner "$ZC_FAKE:$ZC_NODE_ONLY:/usr/bin:/bin" 'zensu 0.9.0 (commit abc1234, built now)')"
    case "$ZC_OLD" in
      *"zensu CLI 0.9.0 ($ZC_FAKE/zensu) is older than $ZC_FLOOR"*'brew upgrade --cask zensu'*'curl -fsSL https://zensu.dev/install.sh | sh'*'irm https://zensu.dev/install.ps1 | iex'*)
        check "B16a a CLI below the floor turns the CLI line into a warning with the floor and the upgrade commands" PASS ;;
      *) check "B16a a CLI below the floor turns the CLI line into a warning with the floor and the upgrade commands" FAIL ;;
    esac
    ZC_CALLS="$(tr '\n' ' ' < "$ZC_LOG" 2>/dev/null)"
    case "$ZC_CALLS" in
      '1|--version ') check "B16b the banner runs zensu --version once, with the update check off" PASS ;;
      *) check "B16b the banner runs zensu --version once, with the update check off (got: $ZC_CALLS)" FAIL ;;
    esac
    case "$(zc_banner "$ZC_FAKE:$ZC_NODE_ONLY:/usr/bin:/bin" "zensu $ZC_FLOOR (commit abc1234, built now)")" in
      *"CLI ready ($ZC_FAKE/zensu, $ZC_FLOOR)"*) check "B16c a CLI at the floor names its version on the ready line" PASS ;;
      *) check "B16c a CLI at the floor names its version on the ready line" FAIL ;;
    esac
    rm -f "$ZC_LOG"
    ZC_RELATIVE="$(cd "$ZC_BASE" && zc_banner "fake:$ZC_FAKE:$ZC_NODE_ONLY:/usr/bin:/bin" 'zensu 0.9.0 (commit abc1234, built now)')"
    if [ ! -s "$ZC_LOG" ] && printf '%s' "$ZC_RELATIVE" | grep -qF 'CLI ready (' && ! printf '%s' "$ZC_RELATIVE" | grep -qF 'is older than'; then
      check "B16d a zensu that PATH reaches through a relative entry is never run at session start" PASS
    else
      check "B16d a zensu that PATH reaches through a relative entry is never run at session start" FAIL
    fi
    case "$(zc_banner "$ZC_NODE_ONLY:/usr/bin:/bin" '')" in
      *"'zensu' CLI not found on PATH — Zensu skills need zensu-cli $ZC_FLOOR or later. Install: brew install --cask mkitconsulting/tap/zensu, curl -fsSL https://zensu.dev/install.sh | sh, or on Windows irm https://zensu.dev/install.ps1 | iex"*)
        check "B16e a missing CLI names the floor and the three install commands" PASS ;;
      *) check "B16e a missing CLI names the floor and the three install commands" FAIL ;;
    esac
    ZC_READY_PLAIN="$(zc_banner "$ZC_FAKE:$ZC_NODE_ONLY:/usr/bin:/bin" "zensu $ZC_FLOOR (commit abc1234, built now)")"
    ZC_READY_TOKEN="$(zc_banner "$ZC_FAKE:$ZC_NODE_ONLY:/usr/bin:/bin" "zensu $ZC_FLOOR (commit abc1234, built now)" ZENSU_SESSION_TOKEN=zst_banner_case)"
    ZC_MISSING_PLAIN="$(zc_banner "$ZC_NODE_ONLY:/usr/bin:/bin" '')"
    ZC_MISSING_TOKEN="$(zc_banner "$ZC_NODE_ONLY:/usr/bin:/bin" '' ZENSU_SESSION_TOKEN=zst_banner_case)"
    if printf '%s' "$ZC_READY_PLAIN" | grep -qF "CLI ready ($ZC_FAKE/zensu, $ZC_FLOOR) — Zensu skills drive it. On an auth error run: zensu auth login." \
      && printf '%s' "$ZC_MISSING_PLAIN" | grep -qF 'irm https://zensu.dev/install.ps1 | iex — then: zensu auth login.' \
      && printf '%s' "$ZC_READY_TOKEN" | grep -qF "CLI ready ($ZC_FAKE/zensu, $ZC_FLOOR) — Zensu skills drive it." \
      && printf '%s' "$ZC_MISSING_TOKEN" | grep -qF 'irm https://zensu.dev/install.ps1 | iex.' \
      && ! printf '%s%s' "$ZC_READY_TOKEN" "$ZC_MISSING_TOKEN" | grep -qF 'auth login'; then
      check "B16f the CLI lines advise zensu auth login, except in a session that holds ZENSU_SESSION_TOKEN" PASS
    else
      check "B16f the CLI lines advise zensu auth login, except in a session that holds ZENSU_SESSION_TOKEN" FAIL
    fi
    ;;
esac
rm -rf "$ZC_BASE"

NO_NODE_BIN="$PRIMER_DATA_BASE/no-node-bin"
mkdir -p "$NO_NODE_BIN"
for no_node_tool in dirname cat; do
  printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v "$no_node_tool")" >"$NO_NODE_BIN/$no_node_tool"
  chmod +x "$NO_NODE_BIN/$no_node_tool"
done
NO_NODE_BASH="$(command -v bash)"
NO_NODE_QUIET="$PRIMER_DATA_BASE/no-node-quiet.json"
printf '%s' '{"hooks":{"sessionBanner":false}}' >"$NO_NODE_QUIET"
NO_NODE_OUT="$(printf '%s' '{"source":"resume"}' | PATH="$NO_NODE_BIN" ZENSU_CONFIG="$NO_NODE_QUIET" "$NO_NODE_BASH" "$BANNER" 2>/dev/null)"
NO_NODE_RC=$?
if [ "$NO_NODE_RC" -eq 0 ] && printf '%s' "$NO_NODE_OUT" | node -e '
  let s = ""; process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    const lines = s.split("\n").filter(Boolean);
    const j = JSON.parse(lines[0]);
    const msg = j.systemMessage, ctx = j.hookSpecificOutput && j.hookSpecificOutput.additionalContext;
    const ok = lines.length === 1
      && j.hookSpecificOutput.hookEventName === "SessionStart"
      && msg.includes("node was not found on the PATH that Claude Code was started with")
      && msg.includes("Zensu blocks every tool call until node is available")
      && msg.includes("Requirements in the plugin README") && msg.includes("disable the Zensu plugin")
      && ctx.includes("refuses every tool call") && !s.includes("Zensu PLM v");
    process.exit(ok ? 0 : 1);
  });
' 2>/dev/null; then
  check "B17 without node the banner emits one fixed JSON systemMessage that names node, the PATH, the README and disabling the plugin, on every source and above the sessionBanner gate" PASS
else
  check "B17 node-less banner (rc=$NO_NODE_RC out='$(printf '%s' "$NO_NODE_OUT" | head -c 200)')" FAIL
fi
rm -rf "$PRIMER_DATA_BASE"

echo "----"
echo "test-session-start-banner: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
