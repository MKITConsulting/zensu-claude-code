#!/bin/bash
set -u

# Structure + functional test for the bypass ledger (visible gate opt-outs).
# Pins: the state seam (tdd_add_bypass / tdd_record_bypass /
# tdd_record_bypass_payload / tdd_bypasses / tdd_clear_bypasses, shape
# enforcement at write AND read, entry cap, clear-on-reset, exports); the
# zensu-log.sh verbs --bypass-note/--bypass-list (shape-validated,
# active-scoped, dedup, `none` when empty, --tdd-begin reset); parser-owned
# inline-bypass markers (__bypass__ lines from bash-source-write-parse.js and
# the zensu-gate embedded parser, __bypass__: verdict from
# secret-scan-decide.js); the recording call sites in all six hooks;
# the rendering surfaces (delegate directive incl. unconditional `none`,
# self-review template, autopilot PR-body line, README docs); and functional
# end-to-end recording through the REAL hooks for every gate in a sandboxed
# state dir. Gate ALLOW behavior under bypass must stay unchanged.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
PHASE_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
LOG_SH="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
PARSE_JS="$PLUGIN_DIR/hooks/lib/bash-source-write-parse.js"
DECIDE_JS="$PLUGIN_DIR/hooks/lib/secret-scan-decide.js"
DELEGATE="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
SELF_REVIEW_MD="$PLUGIN_DIR/skills/self-review/SKILL.md"
AUTOPILOT_MD="$PLUGIN_DIR/skills/autopilot/SKILL.md"
README="$PLUGIN_DIR/README.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$PHASE_LIB" "$LOG_SH" "$PARSE_JS" "$DECIDE_JS" "$DELEGATE" "$SELF_REVIEW_MD" "$AUTOPILOT_MD" "$README"; do
  if [ ! -f "$f" ]; then
    check "P0 required file exists: $f" FAIL
    echo "----"
    echo "test-bypass-ledger: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "P0 all core files exist" PASS

# P1 — state seam
if grep -qE '^tdd_add_bypass\(\)' "$PHASE_LIB" && grep -qE '^tdd_record_bypass\(\)' "$PHASE_LIB" && grep -qE '^tdd_record_bypass_payload\(\)' "$PHASE_LIB" && grep -qE '^tdd_bypasses\(\)' "$PHASE_LIB" && grep -qE '^tdd_clear_bypasses\(\)' "$PHASE_LIB"; then
  check "P1a phase lib defines the bypass helper family" PASS
else
  check "P1a phase lib defines the bypass helper family" FAIL
fi
if grep -qF 's.bypasses = [];' "$PHASE_LIB"; then
  check "P1b session clear resets the bypasses array" PASS
else
  check "P1b session clear resets the bypasses array" FAIL
fi
if grep -qE 'export -f .*tdd_add_bypass' "$PHASE_LIB" && grep -qE 'export -f .*tdd_record_bypass_payload' "$PHASE_LIB" && grep -qE 'export -f .*tdd_clear_bypasses' "$PHASE_LIB"; then
  check "P1c bypass helpers are exported" PASS
else
  check "P1c bypass helpers are exported" FAIL
fi
if grep -qE '^ZENSU_BYPASS_GATE_ALLOWLIST="ZENSU_TDD_GATE ' "$PHASE_LIB"; then
  ALLOW_USES="$(grep -cF 'ALLOWLIST="$ZENSU_BYPASS_GATE_ALLOWLIST"' "$PHASE_LIB")"
else
  ALLOW_USES=0
fi
if [ "${ALLOW_USES:-0}" -ge 2 ]; then
  check "P1d closed gate allowlist enforced at write and read ($ALLOW_USES sites)" PASS
else
  check "P1d closed gate allowlist enforced at write and read ($ALLOW_USES sites)" FAIL
fi
if grep -qF 'allow.indexOf(x) >= 0 && a.indexOf(x) === i' "$PHASE_LIB" && grep -qF 'allow.indexOf(gate) >= 0' "$PHASE_LIB"; then
  check "P1e ledger bounded by the closed allowlist + per-name dedup (no cap needed)" PASS
else
  check "P1e ledger bounded by the closed allowlist + per-name dedup (no cap needed)" FAIL
fi
if grep -qF 'tdd_session_active' "$PHASE_LIB" && grep -qE 'tdd_record_bypass\(\)' "$PHASE_LIB"; then
  check "P1f active-session scoping lives in the shared recorder" PASS
else
  check "P1f active-session scoping lives in the shared recorder" FAIL
fi
if [ "$(grep -c 'bypasses = \[\];' "$PHASE_LIB")" -ge 2 ]; then
  check "P1g deferred-review seed clears the ledger too" PASS
else
  check "P1g deferred-review seed clears the ledger too" FAIL
fi

# P2 — zensu-log.sh verbs
if grep -qF -- '--bypass-note)' "$LOG_SH" && grep -qF -- '--bypass-list)' "$LOG_SH"; then
  check "P2a zensu-log.sh carries --bypass-note and --bypass-list verbs" PASS
else
  check "P2a zensu-log.sh carries --bypass-note and --bypass-list verbs" FAIL
fi
if grep -qF 'requires a known gate name' "$LOG_SH" && grep -qF '_tdd_bypass_shape_ok "$gate_val"' "$LOG_SH"; then
  check "P2b --bypass-note validates via the shared allowlist helper" PASS
else
  check "P2b --bypass-note validates via the shared allowlist helper" FAIL
fi
if grep -qF 'echo "none"' "$LOG_SH"; then
  check "P2c --bypass-list echoes none for an empty ledger" PASS
else
  check "P2c --bypass-list echoes none for an empty ledger" FAIL
fi
BEGIN_SESSION_BLOCK="$(awk '/^_tdd_begin_session_critical\(\)/,/^}/' "$PHASE_LIB")"
if grep -qF 'tdd_begin_session "$session_val" "$begin_vanilla"' "$LOG_SH" \
  && printf '%s\n' "$BEGIN_SESSION_BLOCK" | grep -qF 's.bypasses = [];'; then
  check "P2d --tdd-begin resets the ledger inside its atomic transition" PASS
else
  check "P2d --tdd-begin resets the ledger inside its atomic transition" FAIL
fi
if grep -qF 'tdd_record_bypass "$session_val" "$gate_val"' "$LOG_SH"; then
  check "P2e --bypass-note routes through the active-scoped recorder" PASS
else
  check "P2e --bypass-note routes through the active-scoped recorder" FAIL
fi

# P3 — recording call sites route through the shared recorder, fail-open
SITES="pre-edit-tdd-reminder.sh:ZENSU_TDD_GATE pre-bash-source-write-gate.sh:ZENSU_BASH_WRITE_GATE pre-bash-source-write-gate.sh:ZENSU_MCP_GATE pre-bash-zensu-gate.sh:ZENSU_MCP_GATE pre-write-secret-scan.sh:ZENSU_SECRET_SCAN stop-chain-enforcer.sh:ZENSU_CHAIN post-bash-witness.sh:ZENSU_TEST_WITNESS"
for entry in $SITES; do
  hook_file="${entry%%:*}"; gate_name="${entry#*:}"
  hf="$PLUGIN_DIR/hooks/$hook_file"
  if [ -f "$hf" ] && grep -qE "tdd_record_bypass(_payload)? \"[^\"]+\" $gate_name([[:space:]]|$)" "$hf"; then
    check "P3 $hook_file records $gate_name via the shared recorder" PASS
  else
    check "P3 $hook_file records $gate_name via the shared recorder" FAIL
  fi
done
for hook_file in pre-edit-tdd-reminder.sh pre-bash-source-write-gate.sh pre-bash-zensu-gate.sh pre-write-secret-scan.sh stop-chain-enforcer.sh post-bash-witness.sh; do
  hf="$PLUGIN_DIR/hooks/$hook_file"
  if [ -f "$hf" ] && grep -qE 'tdd_record_bypass(_payload)? .*2>/dev/null \|\| true' "$hf"; then
    check "P3 $hook_file records fail-open" PASS
  else
    check "P3 $hook_file records fail-open" FAIL
  fi
done

# P3m — parser-owned inline markers (detection shares the deciding code path)
if grep -qF '__bypass__\t' "$PARSE_JS" && grep -qF 'bypassMarkers' "$PARSE_JS"; then
  check "P3m1 source-write parser emits __bypass__ markers" PASS
else
  check "P3m1 source-write parser emits __bypass__ markers" FAIL
fi
if grep -qF '__bypass__*)' "$PLUGIN_DIR/hooks/pre-bash-source-write-gate.sh"; then
  check "P3m2 source-write gate consumes the parser markers" PASS
else
  check "P3m2 source-write gate consumes the parser markers" FAIL
fi
if grep -qF '__bypass__\tZENSU_MCP_GATE' "$PLUGIN_DIR/hooks/pre-bash-zensu-gate.sh" && grep -qF '$1=="__bypass__"' "$PLUGIN_DIR/hooks/pre-bash-zensu-gate.sh"; then
  check "P3m3 zensu gate parser emits and the hook consumes __bypass__ markers" PASS
else
  check "P3m3 zensu gate parser emits and the hook consumes __bypass__ markers" FAIL
fi
if grep -qF '__bypass__:ZENSU_SECRET_SCAN' "$DECIDE_JS" && grep -qF '__bypass__:ZENSU_SECRET_SCAN' "$PLUGIN_DIR/hooks/pre-write-secret-scan.sh"; then
  check "P3m4 secret-scan decider reports the inline bypass as a verdict" PASS
else
  check "P3m4 secret-scan decider reports the inline bypass as a verdict" FAIL
fi

# P4 — rendering surfaces
if grep -qF 'Gates bypassed during this session:' "$DELEGATE" && grep -qF 'tdd_bypasses' "$DELEGATE" && grep -qF '[ -z "$BYPASSES" ] && BYPASSES="none"' "$DELEGATE"; then
  check "P4a delegate bakes the ledger unconditionally (none when clean)" PASS
else
  check "P4a delegate bakes the ledger unconditionally (none when clean)" FAIL
fi
if grep -qF -- '--bypass-list' "$SELF_REVIEW_MD" && grep -qF 'Gates bypassed during this session:' "$SELF_REVIEW_MD"; then
  check "P4b self-review template renders the ledger line" PASS
else
  check "P4b self-review template renders the ledger line" FAIL
fi
if grep -qF 'Gates bypassed during build:' "$AUTOPILOT_MD" && grep -qF -- '--bypass-list' "$AUTOPILOT_MD" && grep -qF 'Gates bypassed (build union):' "$AUTOPILOT_MD"; then
  check "P4c autopilot PR body carries the durable build-level ledger line" PASS
else
  check "P4c autopilot PR body carries the durable build-level ledger line" FAIL
fi
if grep -qiF 'bypass ledger' "$README" && grep -qF -- '--bypass-list' "$README" && grep -qF 'decision point' "$README"; then
  check "P4d README documents the ledger with the decision-point semantic" PASS
else
  check "P4d README documents the ledger with the decision-point semantic" FAIL
fi

# P5 — functional (sandboxed state dir; ZENSU_CONFIG pinned to defaults;
# ambient gate escapes neutralized per invocation)
SBOX="$(mktemp -d 2>/dev/null)" || SBOX=""
if [ -n "$SBOX" ]; then
  printf '{"hooks":{}}\n' > "$SBOX/config.json"
  run_log() {
    TDD_STATE_DIR="$SBOX/state" CLAUDE_PROJECT_DIR="$SBOX" ZENSU_CONFIG="$SBOX/config.json" \
      bash "$LOG_SH" ${1+"$@"}
  }
  run_hook() {
    local hook="$1"
    TDD_STATE_DIR="$SBOX/state" CLAUDE_PROJECT_DIR="$SBOX" ZENSU_CONFIG="$SBOX/config.json" \
      ZENSU_TDD_GATE= ZENSU_BASH_WRITE_GATE= ZENSU_MCP_GATE= ZENSU_SECRET_SCAN= ZENSU_CHAIN= ZENSU_TEST_WITNESS= \
      bash "$PLUGIN_DIR/hooks/$hook" 2>/dev/null
  }
  run_hook_env() {
    local var="$1" hook="$2"
    TDD_STATE_DIR="$SBOX/state" CLAUDE_PROJECT_DIR="$SBOX" ZENSU_CONFIG="$SBOX/config.json" \
      ZENSU_TDD_GATE= ZENSU_BASH_WRITE_GATE= ZENSU_MCP_GATE= ZENSU_SECRET_SCAN= ZENSU_CHAIN= ZENSU_TEST_WITNESS= \
      env "$var=off" bash "$PLUGIN_DIR/hooks/$hook" 2>/dev/null
  }
  review_payload() {
    local sid="$1" ticket
    ticket="$(run_log --review-ticket --session "$sid" 2>/dev/null)" || return 1
    SID_VALUE="$sid" TICKET="$ticket" node -e '
      process.stdout.write(JSON.stringify({
        session_id: process.env.SID_VALUE,
        tool_name: "Agent",
        tool_input: {
          subagent_type: "zensu:code-reviewer",
          prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nfixture`
        }
      }));
    '
  }

  run_log --tdd-begin --session fx >/dev/null 2>&1
  run_log --bypass-note ZENSU_TDD_GATE --session fx >/dev/null 2>&1
  run_log --bypass-note ZENSU_CHAIN --session fx >/dev/null 2>&1
  run_log --bypass-note ZENSU_TDD_GATE --session fx >/dev/null 2>&1
  LIST="$(run_log --bypass-list --session fx 2>/dev/null)"
  if [ "$LIST" = "ZENSU_TDD_GATE, ZENSU_CHAIN" ]; then
    check "P5a note+list round-trip with dedup" PASS
  else
    check "P5a note+list round-trip with dedup (got: $LIST)" FAIL
  fi
  EMPTY="$(run_log --bypass-list --session fresh 2>/dev/null)"
  if [ "$EMPTY" = "none" ]; then
    check "P5b empty ledger lists none" PASS
  else
    check "P5b empty ledger lists none (got: $EMPTY)" FAIL
  fi
  run_log --tdd-begin --session fx >/dev/null 2>&1
  CLEARED="$(run_log --bypass-list --session fx 2>/dev/null)"
  if [ "$CLEARED" = "none" ]; then
    check "P5c --tdd-begin clears the ledger" PASS
  else
    check "P5c --tdd-begin clears the ledger (got: $CLEARED)" FAIL
  fi
  # --tdd-begin also resets the stop-chain anti-deadlock budget (.stopblocks) so a
  # long multi-feature session cannot carry a stale budget past the cap.
  printf 'xxxxx' > "$SBOX/state/tdd-phase-fx.json.stopblocks"
  run_log --tdd-begin --session fx >/dev/null 2>&1
  if [ ! -f "$SBOX/state/tdd-phase-fx.json.stopblocks" ]; then
    check "P5c2 --tdd-begin clears the .stopblocks budget" PASS
  else
    check "P5c2 --tdd-begin clears the .stopblocks budget (still present)" FAIL
  fi
  run_log --tdd-begin --session fx2 >/dev/null 2>&1
  run_log --bypass-note ZENSU_TDD_GATE --session fx2 >/dev/null 2>&1
  run_log --tdd-reset --session fx2 >/dev/null 2>&1
  RESET_L="$(run_log --bypass-list --session fx2 2>/dev/null)"
  if [ "$RESET_L" = "none" ]; then
    check "P5c2 --tdd-reset clears the ledger" PASS
  else
    check "P5c2 --tdd-reset clears the ledger (got: $RESET_L)" FAIL
  fi

  run_log --tdd-begin --session hx >/dev/null 2>&1
  OUT="$(printf '%s' '{"session_id":"hx","tool_name":"Edit","tool_input":{"file_path":"src/x.js"}}' | run_hook_env ZENSU_TDD_GATE pre-edit-tdd-reminder.sh)"
  L1="$(run_log --bypass-list --session hx 2>/dev/null)"
  if [ "$L1" = "ZENSU_TDD_GATE" ]; then
    check "P5d env escape records through the real tdd gate" PASS
  else
    check "P5d env escape records through the real tdd gate (got: $L1)" FAIL
  fi
  case "$OUT" in
    *'"deny"'*) check "P5e bypassed tdd gate still allows" FAIL ;;
    *)          check "P5e bypassed tdd gate still allows" PASS ;;
  esac

  OUT="$(printf '%s' '{"session_id":"hx","tool_name":"Bash","tool_input":{"command":"ZENSU_BASH_WRITE_GATE=off printf x >> src/y.js"}}' | run_hook pre-bash-source-write-gate.sh)"
  L2="$(run_log --bypass-list --session hx 2>/dev/null)"
  if [ "$L2" = "ZENSU_TDD_GATE, ZENSU_BASH_WRITE_GATE" ]; then
    check "P5f inline prefix records through the source-write gate (exact)" PASS
  else
    check "P5f inline prefix records through the source-write gate (got: $L2)" FAIL
  fi
  case "$OUT" in
    *'"deny"'*) check "P5g inline-bypassed write still allows" FAIL ;;
    *)          check "P5g inline-bypassed write still allows" PASS ;;
  esac

  OUT="$(printf '%s' '{"session_id":"hx","tool_name":"Bash","tool_input":{"command":"ZENSU_BASH_WRITE_GATE=\"off\" printf x >> src/q.js"}}' | run_hook pre-bash-source-write-gate.sh)"
  L3="$(run_log --bypass-list --session hx 2>/dev/null)"
  case "$OUT" in *'"deny"'*) QUOTED_ALLOWED=no ;; *) QUOTED_ALLOWED=yes ;; esac
  if [ "$QUOTED_ALLOWED" = "yes" ] && [ "$L3" = "ZENSU_TDD_GATE, ZENSU_BASH_WRITE_GATE" ]; then
    check "P5h QUOTED inline prefix is honored AND recorded (dedup)" PASS
  else
    check "P5h QUOTED inline prefix is honored AND recorded (got: $L3, allowed: $QUOTED_ALLOWED)" FAIL
  fi

  OUT="$(printf '%s' '{"session_id":"hx","tool_name":"PostToolUse","tool_input":{"command":"ls"},"tool_response":{"stdout":"x"}}' | run_hook_env ZENSU_TEST_WITNESS post-bash-witness.sh)"
  L4="$(run_log --bypass-list --session hx 2>/dev/null)"
  case "$L4" in
    *ZENSU_TEST_WITNESS*) check "P5i witness env escape records (armed session)" PASS ;;
    *)                    check "P5i witness env escape records (got: $L4)" FAIL ;;
  esac

  OUT="$(printf '%s' '{"session_id":"hx"}' | run_hook_env ZENSU_CHAIN stop-chain-enforcer.sh)"
  L5="$(run_log --bypass-list --session hx 2>/dev/null)"
  case "$L5" in
    *ZENSU_CHAIN*) check "P5j enforcer env escape records (armed session)" PASS ;;
    *)             check "P5j enforcer env escape records (got: $L5)" FAIL ;;
  esac
  case "$OUT" in
    *'"block"'*) check "P5k bypassed enforcer still allows the stop" FAIL ;;
    *)           check "P5k bypassed enforcer still allows the stop" PASS ;;
  esac

  OUT="$(printf '%s' '{"session_id":"hx","tool_name":"Bash","tool_input":{"command":"zensu products create --name X"}}' | run_hook_env ZENSU_MCP_GATE pre-bash-zensu-gate.sh)"
  L6="$(run_log --bypass-list --session hx 2>/dev/null)"
  case "$L6" in
    *ZENSU_MCP_GATE*) check "P5l zensu-gate env escape records (invocation present)" PASS ;;
    *)                check "P5l zensu-gate env escape records (got: $L6)" FAIL ;;
  esac

  OUT="$(printf '%s' '{"session_id":"hx","tool_name":"Bash","tool_input":{"command":"ZENSU_MCP_GATE=off zensu products create --name X && zensu products list"}}' | run_hook pre-bash-zensu-gate.sh)"
  case "$OUT" in
    *'"deny"'*) check "P5m mixed command: read segment still allowed" FAIL ;;
    *)          check "P5m mixed command: read segment still allowed" PASS ;;
  esac
  L7="$(run_log --bypass-list --session hx 2>/dev/null)"
  case "$L7" in
    *ZENSU_MCP_GATE*) check "P5n mixed command: inline bypass recorded despite other invocations" PASS ;;
    *)                check "P5n mixed command: inline bypass recorded (got: $L7)" FAIL ;;
  esac

  run_log --tdd-begin --session zdx >/dev/null 2>&1
  OUT="$(printf '%s' '{"session_id":"zdx","tool_name":"Bash","tool_input":{"command":"ZENSU_MCP_GATE=off zensu features create A; zensu products create B"}}' | run_hook pre-bash-zensu-gate.sh)"
  L7b="$(run_log --bypass-list --session zdx 2>/dev/null)"
  case "$OUT" in
    *'"deny"'*)
      if [ "$L7b" = "none" ]; then
        check "P5n2 zensu-gate deny wins over markers: denied command records nothing" PASS
      else
        check "P5n2 zensu-gate deny wins over markers (got: $L7b)" FAIL
      fi
      ;;
    *) check "P5n2 zensu-gate deny wins over markers (no deny emitted)" FAIL ;;
  esac

  OUT="$(printf '%s' '{"session_id":"hx","tool_name":"Write","tool_input":{"file_path":"src/app.js","content":"const x = 1;"}}' | run_hook_env ZENSU_SECRET_SCAN pre-write-secret-scan.sh)"
  L8="$(run_log --bypass-list --session hx 2>/dev/null)"
  case "$L8" in
    *ZENSU_SECRET_SCAN*) check "P5o secret-scan env escape records" PASS ;;
    *)                   check "P5o secret-scan env escape records (got: $L8)" FAIL ;;
  esac
  if [ "$L8" = "ZENSU_TDD_GATE, ZENSU_BASH_WRITE_GATE, ZENSU_TEST_WITNESS, ZENSU_CHAIN, ZENSU_MCP_GATE, ZENSU_SECRET_SCAN" ]; then
    check "P5p cumulative ledger exact (order + dedup across all six gates)" PASS
  else
    check "P5p cumulative ledger exact (got: $L8)" FAIL
  fi

  run_log --tdd-begin --session hh >/dev/null 2>&1
  PAYLOAD_HD='{"session_id":"hh","tool_name":"Bash","tool_input":{"command":"cat > note.md <<'\''EOF'\''\nfor one-offs use ZENSU_SECRET_SCAN=off inline\nEOF"}}'
  if printf '%s' "$PAYLOAD_HD" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{JSON.parse(s);})' 2>/dev/null; then
    check "P5q0 heredoc payload is valid JSON (non-vacuous)" PASS
  else
    check "P5q0 heredoc payload is valid JSON (non-vacuous)" FAIL
  fi
  OUT="$(printf '%s' "$PAYLOAD_HD" | run_hook pre-write-secret-scan.sh)"
  L9="$(run_log --bypass-list --session hh 2>/dev/null)"
  if [ "$L9" = "none" ]; then
    check "P5q heredoc body mentioning the escape does NOT record" PASS
  else
    check "P5q heredoc body mentioning the escape does NOT record (got: $L9)" FAIL
  fi
  PAYLOAD_MENTION='{"session_id":"hh","tool_name":"Bash","tool_input":{"command":"git commit -m \"docs: use ZENSU_SECRET_SCAN=off inline\""}}'
  OUT="$(printf '%s' "$PAYLOAD_MENTION" | run_hook pre-write-secret-scan.sh)"
  L9b="$(run_log --bypass-list --session hh 2>/dev/null)"
  if [ "$L9b" = "none" ]; then
    check "P5q2 channel-less textual mention does NOT record" PASS
  else
    check "P5q2 channel-less textual mention does NOT record (got: $L9b)" FAIL
  fi

  OUT="$(printf '%s' '{"session_id":"coldfx","tool_name":"Edit","tool_input":{"file_path":"src/x.js"}}' | run_hook_env ZENSU_TDD_GATE pre-edit-tdd-reminder.sh)"
  L10="$(run_log --bypass-list --session coldfx 2>/dev/null)"
  if [ "$L10" = "none" ]; then
    check "P5r inactive session records nothing (tdd gate)" PASS
  else
    check "P5r inactive session records nothing (got: $L10)" FAIL
  fi
  OUT="$(printf '%s' '{"session_id":"coldw","tool_input":{"command":"ls"},"tool_response":{"stdout":"x"}}' | run_hook_env ZENSU_TEST_WITNESS post-bash-witness.sh)"
  L11="$(run_log --bypass-list --session coldw 2>/dev/null)"
  if [ "$L11" = "none" ]; then
    check "P5s inactive session records nothing (witness)" PASS
  else
    check "P5s inactive session records nothing (got: $L11)" FAIL
  fi

  if run_log --bypass-note --session fx >/dev/null 2>&1; then
    check "P5t --bypass-note without gate exits non-zero" FAIL
  else
    check "P5t --bypass-note without gate exits non-zero" PASS
  fi
  if run_log --bypass-note 'lower case$(x)' --session fx >/dev/null 2>&1; then
    check "P5u --bypass-note rejects non-gate-shaped values" FAIL
  else
    check "P5u --bypass-note rejects non-gate-shaped values" PASS
  fi
  run_log --bypass-note ZENSU_TDD_GATE --session coldv >/dev/null 2>&1
  L12="$(run_log --bypass-list --session coldv 2>/dev/null)"
  if [ "$L12" = "none" ]; then
    check "P5v --bypass-note is active-scoped (inactive session no-ops)" PASS
  else
    check "P5v --bypass-note is active-scoped (got: $L12)" FAIL
  fi
  if run_log --bypass-note ZENSU_NOT_A_GATE --session fx >/dev/null 2>&1; then
    check "P5v2 --bypass-note rejects unknown uppercase gate names" FAIL
  else
    check "P5v2 --bypass-note rejects unknown uppercase gate names" PASS
  fi
  if run_log --bypass-note "ZENSU_SECRET_SCAN ZENSU_CHAIN" --session fx >/dev/null 2>&1; then
    check "P5v3 --bypass-note rejects space-joined adjacent gate names" FAIL
  else
    check "P5v3 --bypass-note rejects space-joined adjacent gate names" PASS
  fi

  printf '{"session_id":"jx","active":true,"phase":"UNINITIALIZED","history":[],"bypasses":["ZENSU_TDD_GATE","EVIL_UPPER_TOKEN","not shaped","ZENSU_TDD_GATE"]}\n' > "$SBOX/state/tdd-phase-jx.json"
  L13="$(run_log --bypass-list --session jx 2>/dev/null)"
  if [ "$L13" = "ZENSU_TDD_GATE" ]; then
    check "P5y read filters junk AND duplicates from a crafted state file" PASS
  else
    check "P5y read filters junk AND duplicates (got: $L13)" FAIL
  fi

  JUNK_ROW="$(node -e 'const a=[];for(let i=0;i<40;i++)a.push("JUNK_"+i);process.stdout.write(JSON.stringify(a))' 2>/dev/null)"
  printf '{"session_id":"kx","active":true,"phase":"UNINITIALIZED","history":[],"bypasses":%s}\n' "$JUNK_ROW" > "$SBOX/state/tdd-phase-kx.json"
  run_log --bypass-note ZENSU_TDD_GATE --session kx >/dev/null 2>&1
  L13b="$(run_log --bypass-list --session kx 2>/dev/null)"
  if [ "$L13b" = "ZENSU_TDD_GATE" ]; then
    check "P5y2 pre-seeded junk cannot exhaust the cap (sanitize precedes it)" PASS
  else
    check "P5y2 pre-seeded junk cannot exhaust the cap (got: $L13b)" FAIL
  fi

  DWSBOX="$SBOX/denyrepo"
  mkdir -p "$DWSBOX/src"
  git -C "$DWSBOX" init -q -b main 2>/dev/null
  git -C "$DWSBOX" config user.email t@t.local
  git -C "$DWSBOX" config user.name t
  git -C "$DWSBOX" config commit.gpgsign false
  printf 'x\n' > "$DWSBOX/src/t.js"
  git -C "$DWSBOX" add -A 2>/dev/null && git -C "$DWSBOX" commit -qm base 2>/dev/null
  run_log --tdd-begin --session dwx >/dev/null 2>&1
  DW_PAYLOAD="$(printf '{"session_id":"dwx","tool_name":"Bash","cwd":%s,"tool_input":{"command":"ZENSU_BASH_WRITE_GATE=off printf a >> ok.js; printf b >> src/t.js"}}' "$(printf '%s' "$DWSBOX" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(s)))')")"
  OUT="$(printf '%s' "$DW_PAYLOAD" | TDD_STATE_DIR="$SBOX/state" CLAUDE_PROJECT_DIR="$DWSBOX" ZENSU_CONFIG="$SBOX/config.json" ZENSU_BSWGATE_TEMP_DIRS=/nonexistent-temp-root ZENSU_TDD_GATE= ZENSU_BASH_WRITE_GATE= ZENSU_MCP_GATE= ZENSU_SECRET_SCAN= ZENSU_CHAIN= ZENSU_TEST_WITNESS= bash "$PLUGIN_DIR/hooks/pre-bash-source-write-gate.sh" 2>/dev/null)"
  L14="$(run_log --bypass-list --session dwx 2>/dev/null)"
  case "$OUT" in
    *'"deny"'*)
      if [ "$L14" = "none" ]; then
        check "P5z deny wins over markers: denied command records nothing" PASS
      else
        check "P5z deny wins over markers: denied command records nothing (got: $L14)" FAIL
      fi
      ;;
    *) check "P5z deny wins over markers (no deny emitted for tracked overwrite)" FAIL ;;
  esac

  SEED_SBOX_SID="sdx"
  run_log --tdd-begin --session "$SEED_SBOX_SID" >/dev/null 2>&1
  run_log --bypass-note ZENSU_CHAIN --session "$SEED_SBOX_SID" >/dev/null 2>&1
  run_log --tdd-complete --session "$SEED_SBOX_SID" >/dev/null 2>&1
  review_payload "$SEED_SBOX_SID" | run_hook post-review-tdd-delegate.sh >/dev/null
  SEED_REVIEW_TICKET="$(run_log --current-review-ticket --session "$SEED_SBOX_SID" 2>/dev/null)"
  run_log --code-review-done --claimed-review-ticket "$SEED_REVIEW_TICKET" \
    --session "$SEED_SBOX_SID" >/dev/null 2>&1
  run_log --chain-done --claimed-review-ticket "$SEED_REVIEW_TICKET" \
    --session "$SEED_SBOX_SID" >/dev/null 2>&1
  ( TDD_STATE_DIR="$SBOX/state" CLAUDE_PROJECT_DIR="$SBOX" ZENSU_CONFIG="$SBOX/config.json" bash -c "source '$PHASE_LIB'; tdd_seed_deferred_review '$SEED_SBOX_SID' false" ) >/dev/null 2>&1
  L15="$(run_log --bypass-list --session "$SEED_SBOX_SID" 2>/dev/null)"
  if [ "$L15" = "none" ]; then
    check "P5aa deferred-review seed starts with a clean ledger" PASS
  else
    check "P5aa deferred-review seed starts with a clean ledger (got: $L15)" FAIL
  fi

  # With selfReview enabled (default) the delegate hands rendering to the
  # /zensu:self-review template; the delegate-baked directive is the
  # selfReview:false path — pin THAT path with a dedicated config.
  printf '{"hooks":{"selfReview":false}}\n' > "$SBOX/config-nosr.json"
  run_delegate_nosr() {
    TDD_STATE_DIR="$SBOX/state" CLAUDE_PROJECT_DIR="$SBOX" ZENSU_CONFIG="$SBOX/config-nosr.json" \
      ZENSU_TDD_GATE= ZENSU_BASH_WRITE_GATE= ZENSU_MCP_GATE= ZENSU_SECRET_SCAN= ZENSU_CHAIN= ZENSU_TEST_WITNESS= \
      bash "$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh" 2>/dev/null
  }
  run_log --tdd-begin --session dx >/dev/null 2>&1
  run_log --bypass-note ZENSU_TDD_GATE --session dx >/dev/null 2>&1
  run_log --tdd-complete --session dx >/dev/null 2>&1
  DOUT="$(review_payload dx | run_delegate_nosr)"
  case "$DOUT" in
    *'Gates bypassed during this session: ZENSU_TDD_GATE'*)
      check "P5w delegate directive carries the actual ledger (selfReview off)" PASS ;;
    *)
      check "P5w delegate directive carries the actual ledger (selfReview off)" FAIL ;;
  esac
  run_log --tdd-begin --session dy >/dev/null 2>&1
  run_log --tdd-complete --session dy >/dev/null 2>&1
  DOUT2="$(review_payload dy | run_delegate_nosr)"
  case "$DOUT2" in
    *'Gates bypassed during this session: none'*)
      check "P5x delegate attests none on a clean ledger (selfReview off)" PASS ;;
    *)
      check "P5x delegate attests none on a clean ledger (selfReview off)" FAIL ;;
  esac
  printf '{"hooks":{"selfReview":false,"combinedSummary":false}}\n' > "$SBOX/config-doubleoff.json"
  DOUT3="$(review_payload dx | TDD_STATE_DIR="$SBOX/state" CLAUDE_PROJECT_DIR="$SBOX" ZENSU_CONFIG="$SBOX/config-doubleoff.json" ZENSU_TDD_GATE= ZENSU_BASH_WRITE_GATE= ZENSU_MCP_GATE= ZENSU_SECRET_SCAN= ZENSU_CHAIN= ZENSU_TEST_WITNESS= bash "$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh" 2>/dev/null)"
  case "$DOUT3" in
    *'Gates bypassed during this session: ZENSU_TDD_GATE'*)
      check "P5x2 ledger line survives combinedSummary:false + selfReview:false" PASS ;;
    *)
      check "P5x2 ledger line survives combinedSummary:false + selfReview:false" FAIL ;;
  esac

  rm -rf "$SBOX" 2>/dev/null
else
  check "P5 sandbox creation (mktemp)" FAIL
fi

echo "----"
echo "test-bypass-ledger: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
