#!/bin/bash
set -u

# Structure + functional test for /zensu:doctor read-only diagnostics.
# Structure pins: helper .sh (+ shebang), report .js, skill frontmatter,
# plugin.json skills[] registration, README Diagnostics section. Functional
# (sandbox, node required): zensu-doctor-report.js renders a four-block table
# and ALWAYS exits 0 while correctly flagging version mismatch (❌), hooks
# wired-but-missing (❌) + disk-but-unwired (⚠️), the quoted-boolean config
# trap (⚠️, real booleans NOT flagged), stale state markers (⚠️), and an
# expired pending-review marker (⚠️) vs a fresh one (✅); all-green fixture is
# all ✅. Read-only throughout.

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
if grep -qF 'bash {PLUGIN_ROOT}/hooks/lib/zensu-doctor.sh' "$SKILL_MD"; then
  check "P2d skill runs the helper" PASS
else
  check "P2d skill runs the helper" FAIL
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
mkdir -p "$SBOX/plug/.claude-plugin" "$SBOX/plug/hooks" "$SBOX/st"

run_report() {
  # run_report <plugin_dir> <config|-> <state_dir>  (tool facts fixed absent)
  local pd="$1" cfg="$2" sd="$3"
  local cfgenv=""
  [ "$cfg" != "-" ] && cfgenv="$cfg"
  ZDOC_ZENSU=absent ZDOC_NODE="vTEST" ZDOC_GH=absent ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$pd" ZENSU_CONFIG="$cfgenv" TDD_STATE_DIR="$sd" \
    node "$REPORT" 2>/dev/null
}

# --- all-green fixture -----------------------------------------------------
printf '{"name":"zensu","version":"1.2.3"}\n' > "$SBOX/plug/.claude-plugin/plugin.json"
printf '{"plugins":[{"name":"zensu","version":"1.2.3"}]}\n' > "$SBOX/plug/.claude-plugin/marketplace.json"
printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":"${CLAUDE_PLUGIN_ROOT}/hooks/a.sh"}]}]}}\n' > "$SBOX/plug/hooks/hooks.json"
printf '#!/bin/bash\n' > "$SBOX/plug/hooks/a.sh"
printf '{"hooks":{"prGate":true,"secretScan":false}}\n' > "$SBOX/good-cfg.json"

OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$SBOX/st")"; RC=$?
[ "$RC" -eq 0 ] && check "P1a report exits 0 on the green fixture" PASS || check "P1a report exits 0 (rc=$RC)" FAIL
case "$OUT" in *'version sync: plugin.json and marketplace.json agree'*) check "P1b version sync ✅ when equal" PASS ;; *) check "P1b version sync ✅ when equal" FAIL ;; esac
case "$OUT" in *'hooks wiring: all 1 hooks'*) check "P1c wiring ✅ when consistent" PASS ;; *) check "P1c wiring ✅ when consistent" FAIL ;; esac
case "$OUT" in *'no quoted-boolean traps'*) check "P1d config ✅ with real booleans (prGate:true/secretScan:false)" PASS ;; *) check "P1d config ✅ with real booleans" FAIL ;; esac
# all-green summary only when the tool block is green too (inject authed tools)
GREEN="$(ZDOC_ZENSU=authed ZDOC_NODE="vTEST" ZDOC_GH=authed ZDOC_PLAYWRIGHT=present \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" TDD_STATE_DIR="$SBOX/empty-st" \
  node "$REPORT" 2>/dev/null)"
case "$GREEN" in *'all checks green'*) check "P1e summary reports all green when every block is green" PASS ;; *) check "P1e summary all green (got: $GREEN)" FAIL ;; esac

# --- version mismatch ------------------------------------------------------
printf '{"plugins":[{"name":"zensu","version":"9.9.9"}]}\n' > "$SBOX/plug/.claude-plugin/marketplace.json"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$SBOX/st")"; RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *'version sync: plugin.json 1.2.3 != marketplace.json 9.9.9'*) check "P1f version mismatch ❌ (exit 0)" PASS ;; *) check "P1f version mismatch ❌ (got: $OUT)" FAIL ;; esac || check "P1f version mismatch (rc=$RC)" FAIL
printf '{"plugins":[{"name":"zensu","version":"1.2.3"}]}\n' > "$SBOX/plug/.claude-plugin/marketplace.json"

# --- hooks wiring both directions -----------------------------------------
printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":"${CLAUDE_PLUGIN_ROOT}/hooks/ghost.sh"}]}]}}\n' > "$SBOX/plug/hooks/hooks.json"
printf '#!/bin/bash\n' > "$SBOX/plug/hooks/orphan.sh"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$SBOX/st")"
case "$OUT" in *'referenced but missing on disk'*ghost.sh*) check "P1g wired-but-missing ❌ names the script" PASS ;; *) check "P1g wired-but-missing ❌ (got: $OUT)" FAIL ;; esac
case "$OUT" in *'not referenced in hooks.json'*orphan.sh*) check "P1h disk-but-unwired ⚠️ names the script" PASS ;; *) check "P1h disk-but-unwired ⚠️ (got: $OUT)" FAIL ;; esac
# restore consistent wiring
printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":"${CLAUDE_PLUGIN_ROOT}/hooks/a.sh"}]}]}}\n' > "$SBOX/plug/hooks/hooks.json"
rm -f "$SBOX/plug/hooks/orphan.sh"

# --- quoted-boolean trap ---------------------------------------------------
printf '{"hooks":{"prGate":"true","secretScan":false}}\n' > "$SBOX/bad-cfg.json"
OUT="$(run_report "$SBOX/plug" "$SBOX/bad-cfg.json" "$SBOX/st")"; RC=$?
[ "$RC" -eq 0 ] && check "P1i report exits 0 on quoted-boolean config" PASS || check "P1i report exits 0 (rc=$RC)" FAIL
case "$OUT" in *'quoted boolean'*'hooks.prGate = "true"'*) check "P1j quoted boolean ⚠️ names the dotted key" PASS ;; *) check "P1j quoted boolean ⚠️ (got: $OUT)" FAIL ;; esac
case "$OUT" in *secretScan*) check "P1k real boolean secretScan:false NOT flagged" FAIL ;; *) check "P1k real boolean secretScan:false NOT flagged" PASS ;; esac

# --- invalid JSON config ---------------------------------------------------
printf '{not json' > "$SBOX/broken-cfg.json"
OUT="$(run_report "$SBOX/plug" "$SBOX/broken-cfg.json" "$SBOX/st")"; RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *'config: invalid JSON'*) check "P1l invalid config ❌ (exit 0, defaults apply)" PASS ;; *) check "P1l invalid config ❌ (got: $OUT)" FAIL ;; esac || check "P1l invalid config (rc=$RC)" FAIL

# --- state markers ---------------------------------------------------------
: > "$SBOX/st/tdd-phase-x.json"; : > "$SBOX/st/rounds-x.json"; : > "$SBOX/st/review-pass-x"; : > "$SBOX/st/y.stopblocks"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$SBOX/st")"
case "$OUT" in *'4 per-session marker file(s) present'*'1 tdd-phase, 1 rounds, 1 review-pass, 1 stopblocks'*) check "P1m stale markers ⚠️ with per-type counts" PASS ;; *) check "P1m stale markers ⚠️ (got: $OUT)" FAIL ;; esac

# expired vs fresh pending-review.json
: > "$SBOX/st/pending-review.json"
touch -t 202001010000 "$SBOX/st/pending-review.json" 2>/dev/null
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$SBOX/st")"
case "$OUT" in *'pending-review.json is'*'old (TTL'*'expired'*) check "P1n expired pending-review ⚠️" PASS ;; *) check "P1n expired pending-review ⚠️ (got: $OUT)" FAIL ;; esac
: > "$SBOX/st/pending-review.json"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$SBOX/st")"
case "$OUT" in *'pending-review.json present and within'*) check "P1o fresh pending-review ✅" PASS ;; *) check "P1o fresh pending-review ✅ (got: $OUT)" FAIL ;; esac

# --- empty state dir -------------------------------------------------------
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$SBOX/empty-st")"
case "$OUT" in *'does not exist yet'*) check "P1p missing state dir handled read-only" PASS ;; *) check "P1p missing state dir handled (got: $OUT)" FAIL ;; esac

# --- summary escalation (❌ wins over ⚠️; ⚠️-only is "no blockers") --------
printf '{"plugins":[{"name":"zensu","version":"9.9.9"}]}\n' > "$SBOX/plug/.claude-plugin/marketplace.json"
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$SBOX/empty-st")"
case "$OUT" in *'Summary:'*'resolve the ❌ items first'*) check "P1r summary escalates to ❌ when a red row exists" PASS ;; *) check "P1r summary ❌ (got: $OUT)" FAIL ;; esac
printf '{"plugins":[{"name":"zensu","version":"1.2.3"}]}\n' > "$SBOX/plug/.claude-plugin/marketplace.json"
# green plugin/config but absent tools (run_report injects absent) -> warn-only
OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$SBOX/empty-st")"
case "$OUT" in *'Summary:'*'no blockers'*) check "P1s summary is warn-only (no blockers) when only ⚠️ rows exist" PASS ;; *) check "P1s summary warn-only (got: $OUT)" FAIL ;; esac

# --- state dir not writable -------------------------------------------------
# Probe whether chmod actually made the dir read-only; filesystems that ignore
# Unix mode bits (root, Windows git-bash, some network mounts) cannot simulate
# this branch, so skip the assertion there instead of failing spuriously.
mkdir -p "$SBOX/ro-st"; : > "$SBOX/ro-st/tdd-phase-z.json"; chmod 0500 "$SBOX/ro-st" 2>/dev/null
if ( : > "$SBOX/ro-st/.wtest" ) 2>/dev/null; then
  rm -f "$SBOX/ro-st/.wtest" 2>/dev/null; chmod 0700 "$SBOX/ro-st" 2>/dev/null
  check "P1t state-not-writable ❌ (skipped: filesystem ignores mode bits)" PASS
else
  OUT="$(run_report "$SBOX/plug" "$SBOX/good-cfg.json" "$SBOX/ro-st")"; RC=$?
  chmod 0700 "$SBOX/ro-st" 2>/dev/null
  [ "$RC" -eq 0 ] && case "$OUT" in *'is not writable'*) check "P1t state-not-writable ❌ (exit 0)" PASS ;; *) check "P1t state-not-writable ❌ (got: $OUT)" FAIL ;; esac || check "P1t state-not-writable (rc=$RC)" FAIL
fi

# --- manifest degradation (missing / invalid / plugin not listed) ----------
mkdir -p "$SBOX/plug2/.claude-plugin" "$SBOX/plug2/hooks"
printf '{"hooks":{}}\n' > "$SBOX/plug2/hooks/hooks.json"
printf '{"plugins":[{"name":"zensu","version":"1.2.3"}]}\n' > "$SBOX/plug2/.claude-plugin/marketplace.json"
OUT="$(run_report "$SBOX/plug2" "$SBOX/good-cfg.json" "$SBOX/empty-st")"
case "$OUT" in *'plugin.json: missing'*) check "P1u plugin.json missing ❌" PASS ;; *) check "P1u plugin.json missing ❌ (got: $OUT)" FAIL ;; esac
printf '{"name":"zensu","version":"1.2.3"}\n' > "$SBOX/plug2/.claude-plugin/plugin.json"
rm -f "$SBOX/plug2/.claude-plugin/marketplace.json"
OUT="$(run_report "$SBOX/plug2" "$SBOX/good-cfg.json" "$SBOX/empty-st")"
case "$OUT" in *'marketplace.json: missing'*) check "P1v marketplace.json missing ⚠️" PASS ;; *) check "P1v marketplace.json missing ⚠️ (got: $OUT)" FAIL ;; esac
printf '{"plugins":[{"name":"other","version":"1.2.3"}]}\n' > "$SBOX/plug2/.claude-plugin/marketplace.json"
OUT="$(run_report "$SBOX/plug2" "$SBOX/good-cfg.json" "$SBOX/empty-st")"
case "$OUT" in *'not listed in marketplace.json'*) check "P1w plugin not listed ⚠️" PASS ;; *) check "P1w plugin not listed ⚠️ (got: $OUT)" FAIL ;; esac
printf '{"plugins":[{"name":"zensu","version":"1.2.3"}]}\n' > "$SBOX/plug2/.claude-plugin/marketplace.json"
printf '{bad json' > "$SBOX/plug2/hooks/hooks.json"
OUT="$(run_report "$SBOX/plug2" "$SBOX/good-cfg.json" "$SBOX/empty-st")"
case "$OUT" in *'hooks.json: invalid JSON'*) check "P1x hooks.json invalid ❌" PASS ;; *) check "P1x hooks.json invalid ❌ (got: $OUT)" FAIL ;; esac

# --- config-absent (defaults apply) ---------------------------------------
OUT="$(ZDOC_ZENSU=absent ZDOC_NODE=vT ZDOC_GH=absent ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" HOME="$SBOX/nohome" CLAUDE_PROJECT_DIR="$SBOX/noproj" TDD_STATE_DIR="$SBOX/empty-st" \
  node "$REPORT" 2>/dev/null)"
case "$OUT" in *'no config file present'*) check "P1y config-absent falls back to defaults ✅" PASS ;; *) check "P1y config-absent (got: $OUT)" FAIL ;; esac

# --- nested quoted boolean + __proto__ guard -------------------------------
printf '{"hooks":{"nested":{"flag":"true"}},"__proto__":{"x":"true"}}\n' > "$SBOX/nested-cfg.json"
OUT="$(run_report "$SBOX/plug" "$SBOX/nested-cfg.json" "$SBOX/empty-st")"
case "$OUT" in *'hooks.nested.flag = "true"'*) check "P1z nested quoted boolean ⚠️ (recursion)" PASS ;; *) check "P1z nested quoted boolean (got: $OUT)" FAIL ;; esac
case "$OUT" in *'__proto__'*) check "P1aa __proto__ key not reported (pollution guard)" FAIL ;; *) check "P1aa __proto__ key not reported (pollution guard)" PASS ;; esac

# --- TTL honored from ZDOC_TTL_HOURS (canonical getter value) --------------
# age ~3548h: default TTL 6 would call it expired; the injected max TTL 8760
# (!= 6) keeps it fresh — proving ZDOC_TTL_HOURS is the value that is honored.
mkdir -p "$SBOX/ttl-st"; : > "$SBOX/ttl-st/pending-review.json"
touch -t 202601010000 "$SBOX/ttl-st/pending-review.json" 2>/dev/null
FAR="$(ZDOC_ZENSU=absent ZDOC_NODE=vT ZDOC_GH=absent ZDOC_PLAYWRIGHT=absent ZDOC_TTL_HOURS=8760 ZDOC_NOW_MS=1780000000000 \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" TDD_STATE_DIR="$SBOX/ttl-st" node "$REPORT" 2>/dev/null)"
case "$FAR" in *'within its 8760h TTL'*) check "P1ab TTL honored from ZDOC_TTL_HOURS (injected 8760 != default 6)" PASS ;; *) check "P1ab TTL honored (got: $FAR)" FAIL ;; esac
NEAR="$(ZDOC_ZENSU=absent ZDOC_NODE=vT ZDOC_GH=absent ZDOC_PLAYWRIGHT=absent ZDOC_NOW_MS=1780000000000 \
  ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" ZENSU_CONFIG="$SBOX/good-cfg.json" TDD_STATE_DIR="$SBOX/ttl-st" node "$REPORT" 2>/dev/null)"
case "$NEAR" in *'(TTL 6h) — expired'*) check "P1ac default TTL 6h (getter default) marks the same marker expired" PASS ;; *) check "P1ac default TTL 6h expired (got: $NEAR)" FAIL ;; esac

# --- wrapper end-to-end (real toolchain) -----------------------------------
OUT="$(ZENSU_DOCTOR_PLUGIN_DIR="$SBOX/plug" CLAUDE_PROJECT_DIR="$SBOX" bash "$HELPER" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *'Zensu doctor — read-only setup diagnostics'*) check "P1ad wrapper runs end-to-end and exits 0" PASS ;; *) check "P1ad wrapper header (got: $OUT)" FAIL ;; esac || check "P1ad wrapper exit (rc=$RC)" FAIL
if grep -qF 'zensu_pending_review_ttl_hours' "$HELPER" && grep -qF 'zensu-config.sh' "$HELPER"; then
  check "P2i wrapper resolves the TTL through the canonical getter" PASS
else
  check "P2i wrapper resolves the TTL through the canonical getter" FAIL
fi

rm -rf "$SBOX"
echo "----"
echo "test-doctor: $PASS PASS / $FAIL FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
