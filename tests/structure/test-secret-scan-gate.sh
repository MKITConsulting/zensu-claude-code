#!/bin/bash
set -u

# Structure + functional test for the secret-scan gate (pre-write-secret-scan.sh).
# Pins: the hook exists, is executable, and is wired in hooks.json under all
# THREE PreToolUse matcher groups (Edit|Write|MultiEdit, NotebookEdit, Bash —
# verified structurally, not by occurrence count); secret-patterns.js and
# secret-scan-decide.js exist, parse (node --check), and are the SoT the hook
# references; the config flag (secretScan) and env bypass (ZENSU_SECRET_SCAN)
# are honored; fail-open is documented; the README carries the hook-table row,
# the config row, the Secret Scan section, and a Hooks (N) header. Unit level:
# the engine CLI (stdin -> JSON) per rule incl. placeholder suppression and
# entropy negative; detectChannels per channel incl. fd-dup negative. Hook
# level: 19 synthetic-payload invocations (20 checks) under a hermetic
# ZENSU_CONFIG with ambient ZENSU_SECRET_SCAN/BSWG_MODE neutralized, incl.
# deny-reason content, the per-alternative path allowlist, a second-tool
# exemption case, and a node-shim scanner-crash fail-open case. It
# intentionally does NOT assert version sync or the README hook-count
# arithmetic — those are owned by sibling tests.

# Synthetic token literals below are SPLIT with '' (bash string concatenation)
# so the committed blob never contains a full provider-shaped token: the test
# feeds the joined value to the gate at runtime, but external secret scanners
# (e.g. GitHub push protection) scanning the raw file see only fragments.
PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/pre-write-secret-scan.sh"
ENGINE="$PLUGIN_DIR/hooks/lib/secret-patterns.js"
DECIDE="$PLUGIN_DIR/hooks/lib/secret-scan-decide.js"
PARSER="$PLUGIN_DIR/hooks/lib/bash-source-write-parse.js"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
README="$PLUGIN_DIR/README.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$HOOK" "$ENGINE" "$DECIDE" "$PARSER" "$HOOKS_JSON" "$README"; do
  if [ ! -f "$f" ]; then
    check "P0 required file exists: $f" FAIL
    echo "----"
    echo "test-secret-scan-gate: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "P0 all six target files exist" PASS

if [ -x "$HOOK" ]; then
  check "P0b hook is executable (hooks.json invokes it directly)" PASS
else
  check "P0b hook is executable (hooks.json invokes it directly)" FAIL
fi
if node --check "$ENGINE" >/dev/null 2>&1 && node --check "$DECIDE" >/dev/null 2>&1 && node --check "$PARSER" >/dev/null 2>&1; then
  check "P0c engine/decide/parser pass node --check" PASS
else
  check "P0c engine/decide/parser pass node --check" FAIL
fi

# P1 — structural wiring: one entry under each expected PreToolUse matcher
WIRING="$(node -e '
  const h = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const groups = (h.hooks && h.hooks.PreToolUse) || [];
  const has = (m) => groups.some((g) =>
    g.matcher === m &&
    (g.hooks || []).some((x) => [x.command || "", ...(x.args || [])].join(" ").indexOf("pre-write-secret-scan.sh") !== -1)
  );
  process.stdout.write([has("Edit|Write|MultiEdit"), has("NotebookEdit"), has("Bash")].join(","));
' "$HOOKS_JSON" 2>/dev/null)"
if [ "$WIRING" = "true,true,true" ]; then
  check "P1 hook wired under Edit|Write|MultiEdit + NotebookEdit + Bash matchers" PASS
else
  check "P1 hook wired under all three matchers (got: $WIRING)" FAIL
fi

# P2 — SoT references: hook delegates to decide.js; decide.js uses engine + parser
if grep -qF 'secret-scan-decide.js' "$HOOK" && grep -qF 'secret-patterns.js' "$DECIDE" && grep -qF 'bash-source-write-parse.js' "$DECIDE"; then
  check "P2 hook -> decide.js -> engine + shared parser (SoT chain)" PASS
else
  check "P2 hook -> decide.js -> engine + shared parser (SoT chain)" FAIL
fi

# P3 — config flag + env bypass honored
if grep -qF 'zensu_hook_enabled secretScan' "$HOOK" && grep -qF 'ZENSU_SECRET_SCAN' "$HOOK"; then
  check "P3 hook honors hooks.secretScan config + ZENSU_SECRET_SCAN env" PASS
else
  check "P3 hook honors hooks.secretScan config + ZENSU_SECRET_SCAN env" FAIL
fi

# P4 — fail-open documented; inline Bash escape hatch documented
if grep -qiF 'FAIL OPEN' "$HOOK" && grep -qF 'failing open' "$HOOK"; then
  check "P4a fail-open behavior documented + implemented in the hook" PASS
else
  check "P4a fail-open behavior documented + implemented in the hook" FAIL
fi
if grep -qF 'stripHeredocs(cmd).split' "$DECIDE" && grep -qF '"ZENSU_SECRET_SCAN"' "$DECIDE" && grep -qF '=== "off"' "$DECIDE"; then
  check "P4b inline escape decided on heredoc-stripped segment-leading env tokens (code, not prose)" PASS
else
  check "P4b inline escape decided on heredoc-stripped segment-leading env tokens (code, not prose)" FAIL
fi

# P5 — shared parser exposes detectChannels for the secret path; deny caller pins the mode
if grep -qF 'detectChannels' "$PARSER" && grep -qF 'detectChannels' "$DECIDE"; then
  check "P5a write-channel detection reuses the shared parser (detectChannels)" PASS
else
  check "P5a write-channel detection reuses the shared parser (detectChannels)" FAIL
fi
if grep -qF 'BSWG_MODE= PAYLOAD=' "$PLUGIN_DIR/hooks/pre-bash-source-write-gate.sh"; then
  check "P5b source-write gate pins BSWG_MODE= at its call site" PASS
else
  check "P5b source-write gate pins BSWG_MODE= at its call site" FAIL
fi

# P6 — README: header exists, hook-table row, config row, Secret Scan section
if grep -qE '^### Hooks \([0-9]+\)$' "$README"; then
  check "P6a README has a '### Hooks (N)' header (count owned by sibling test)" PASS
else
  check "P6a README has a '### Hooks (N)' header (count owned by sibling test)" FAIL
fi
if grep -qF '| `pre-write-secret-scan.sh` |' "$README"; then
  check "P6b README hook table carries the secret-scan row" PASS
else
  check "P6b README hook table carries the secret-scan row" FAIL
fi
if grep -qF '| `secretScan` | `pre-write-secret-scan.sh` |' "$README"; then
  check "P6c README config table carries the secretScan row" PASS
else
  check "P6c README config table carries the secretScan row" FAIL
fi
if grep -qxF '## Secret Scan' "$README"; then
  check "P6d README has the Secret Scan section" PASS
else
  check "P6d README has the Secret Scan section" FAIL
fi

# U — engine CLI unit cases (stdin -> JSON), one per rule + suppressions
engine_rules() { printf '%s' "$1" | node "$ENGINE" 2>/dev/null; }

OUT="$(engine_rules 'k = "AKIA''IOSFODNN7RGY4Q2B"')"
case "$OUT" in *'"aws-access-key-id"'*) check "U1 engine: AWS access key id" PASS;; *) check "U1 engine: AWS access key id" FAIL;; esac

OUT="$(engine_rules 'aws_secret_access_key = wJalrXUtnFEMIK7MDENG''bPxRfiCY1234567890Zq')"
case "$OUT" in *'"aws-secret-access-key"'*) check "U2 engine: AWS secret assignment" PASS;; *) check "U2 engine: AWS secret assignment" FAIL;; esac

OUT="$(engine_rules 'ghs_''123456789012345678901234567890123456')"
case "$OUT" in *'"github-token"'*) check "U3 engine: GitHub sibling prefix ghs_" PASS;; *) check "U3 engine: GitHub sibling prefix ghs_" FAIL;; esac

OUT="$(engine_rules 'github_pat_''11ABCDEFG0123456789abc')"
case "$OUT" in *'"github-fine-grained-pat"'*) check "U4 engine: GitHub fine-grained PAT" PASS;; *) check "U4 engine: GitHub fine-grained PAT" FAIL;; esac

OUT="$(engine_rules 'xox''b-1234567890-abcdefghij')"
case "$OUT" in *'"slack-token"'*) check "U5 engine: Slack token" PASS;; *) check "U5 engine: Slack token" FAIL;; esac

OUT="$(engine_rules 'rk_''live_abcdef1234567890XY')"
case "$OUT" in *'"stripe-live-key"'*) check "U6 engine: Stripe restricted live key" PASS;; *) check "U6 engine: Stripe restricted live key" FAIL;; esac

OUT="$(engine_rules '-----BEGIN PRIVATE KEY-----')"
case "$OUT" in *'"private-key-pem"'*) check "U7 engine: PKCS#8 PEM header" PASS;; *) check "U7 engine: PKCS#8 PEM header" FAIL;; esac

# windowed scan: a secret PAST the 2048-char per-line window must still be caught
# (old code truncated the line to 2048 and missed it)
LONGLINE="$(printf 'a%.0s' $(seq 1 2100))\"AKIA""IOSFODNN7RGY4Q2B\""
OUT="$(engine_rules "$LONGLINE")"
case "$OUT" in *'"aws-access-key-id"'*) check "U8 engine: secret past column 2048 is caught (window scan)" PASS;; *) check "U8 engine: secret past column 2048 is caught (window scan)" FAIL;; esac

OUT="$(engine_rules 'api_token = "f8Zk2pQ9xL4mNv7wRs3TuY6bE1cD5gHj"')"
case "$OUT" in *'"high-entropy-assignment"'*'"line":1'*) check "U8 engine: quoted high-entropy assignment + line number" PASS;; *) check "U8 engine: quoted high-entropy assignment + line number" FAIL;; esac

OUT="$(engine_rules 'DB_PASSWORD=f8Zk2pQ9xL4mNv7wRs3TuY6bE1cD5gHj')"
case "$OUT" in *'"high-entropy-assignment"'*) check "U9 engine: unquoted .env-style assignment" PASS;; *) check "U9 engine: unquoted .env-style assignment" FAIL;; esac

OUT="$(engine_rules 'password = "aaaaaaaaaaaaaaaa1"')"
[ "$OUT" = '{"matches":[]}' ] && check "U10 engine: low-entropy value stays clean" PASS || check "U10 engine: low-entropy value stays clean" FAIL

OUT="$(engine_rules 'k = "AKIA''IOSFODNN7EXAMPLE"')"
[ "$OUT" = '{"matches":[]}' ] && check "U11 engine: placeholder suppresses provider rule (EXAMPLE)" PASS || check "U11 engine: placeholder suppresses provider rule (EXAMPLE)" FAIL

OUT="$(engine_rules 'api_key = "XXXX9aB3kZpQ7Lm2XXXX"')"
[ "$OUT" = '{"matches":[]}' ] && check "U12 engine: placeholder suppresses entropy value (XXXX)" PASS || check "U12 engine: placeholder suppresses entropy value (XXXX)" FAIL

OUT="$(engine_rules 'plain text, nothing secret here')"
[ "$OUT" = '{"matches":[]}' ] && check "U13 engine: clean input -> empty matches" PASS || check "U13 engine: clean input -> empty matches" FAIL

# D — detectChannels unit cases (direct parser invocation, BSWG_MODE=detect)
detect() { PAYLOAD="{\"tool_input\":{\"command\":$1}}" BSWG_MODE=detect node "$PARSER" 2>/dev/null; }

OUT="$(detect '"printf foo >> notes.txt"')"
case "$OUT" in *redirect*) check "D1 detect: >> redirect" PASS;; *) check "D1 detect: >> redirect" FAIL;; esac

OUT="$(detect '"echo hi | tee out.log"')"
case "$OUT" in *tee*) check "D2 detect: tee" PASS;; *) check "D2 detect: tee" FAIL;; esac

OUT="$(detect '"sed -i s/a/b/ f.txt"')"
case "$OUT" in *"sed -i"*) check "D3 detect: sed -i" PASS;; *) check "D3 detect: sed -i" FAIL;; esac

OUT="$(detect '"dd if=/dev/zero of=img.bin bs=1"')"
case "$OUT" in *"dd of="*) check "D4 detect: dd of=" PASS;; *) check "D4 detect: dd of=" FAIL;; esac

OUT="$(detect '"cat > x.txt <<EOF\nbody\nEOF"')"
case "$OUT" in *heredoc*) check "D5 detect: heredoc" PASS;; *) check "D5 detect: heredoc" FAIL;; esac

OUT="$(detect '"ls -la 2>&1"')"
[ -z "$OUT" ] && check "D6 detect: fd-dup 2>&1 is NOT a channel" PASS || check "D6 detect: fd-dup 2>&1 is NOT a channel (got: $OUT)" FAIL

OUT="$(detect '"echo token123>creds.env"')"
case "$OUT" in *redirect*) check "D7 detect: glued redirect" PASS;; *) check "D7 detect: glued redirect" FAIL;; esac

OUT="$(detect '"git status && ls"')"
[ -z "$OUT" ] && check "D8 detect: read-only command -> no channel" PASS || check "D8 detect: read-only command -> no channel" FAIL

# F — hook functional cases. Hermetic: ZENSU_CONFIG temp override, ambient
# ZENSU_SECRET_SCAN/BSWG_MODE neutralized (empty is not "off"); extra env
# pairs after the fixed ones win (env last-assignment semantics).
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
printf '{"hooks":{}}' > "$TMPD/config-on.json"
printf '{"hooks":{"secretScan":false}}' > "$TMPD/config-off.json"
export CLAUDE_PROJECT_DIR="$TMPD"
export ZENSU_TEST_PLUGIN_DATA="$TMPD/plugin-data"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" secret-scan-test

run_hook() {
  local payload="$1"; shift
  if [[ "$payload" = \{* ]]; then
    payload="$(printf '%s' "$payload" | node -e '
      let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{
        const j=JSON.parse(s);j.hook_event_name="PreToolUse";j.session_id="secret-scan-test";j.cwd=process.argv[1];
        process.stdout.write(JSON.stringify(j));
      });
    ' "$TMPD")"
  fi
  printf '%s' "$payload" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY \
    -u ZENSU_SESSION_CONTEXT -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$TMPD/config-on.json" ZENSU_SECRET_SCAN= BSWG_MODE= \
    STATE_DIR="$TMPD/state" CLAUDE_PROJECT_DIR="$TMPD" ${1+"$@"} bash "$HOOK" 2>/dev/null
}

DENY='permissionDecision":"deny'

is_deny() {
  printf '%s' "$1" | node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d));
    process.stdin.on("end", () => {
      try {
        const j = JSON.parse(s);
        process.exit(j.hookSpecificOutput && j.hookSpecificOutput.permissionDecision === "deny" ? 0 : 1);
      } catch (e) { process.exit(1); }
    });
  ' 2>/dev/null
}

OUT="$(run_hook '{"tool_name":"Write","tool_input":{"file_path":"/x/src/app.ts","content":"const k = \"AKIA''IOSFODNN7RGY4Q2B\";"}}')"
if is_deny "$OUT"; then check "F1 Write with AWS access key -> deny (parsed JSON verdict)" PASS; else check "F1 Write with AWS access key -> deny (parsed JSON verdict)" FAIL; fi
case "$OUT" in *aws-access-key-id*zensu-secret-allow*) check "F1b deny reason names the rule + remediation" PASS;; *) check "F1b deny reason names the rule + remediation" FAIL;; esac

OUT="$(run_hook '{"tool_name":"Write","tool_input":{"file_path":"/x/tests/unit/aws.txt","content":"AKIA''IOSFODNN7RGY4Q2B"}}')"
[ -z "$OUT" ] && check "F2a tests/ path exemption" PASS || check "F2a tests/ path exemption" FAIL

OUT="$(run_hook '{"tool_name":"Write","tool_input":{"file_path":"/x/evals/case/aws.txt","content":"AKIA''IOSFODNN7RGY4Q2B"}}')"
[ -z "$OUT" ] && check "F2b evals/ path exemption" PASS || check "F2b evals/ path exemption" FAIL

OUT="$(run_hook '{"tool_name":"Write","tool_input":{"file_path":"/x/fixtures/aws.txt","content":"AKIA''IOSFODNN7RGY4Q2B"}}')"
[ -z "$OUT" ] && check "F2c fixtures/ path exemption" PASS || check "F2c fixtures/ path exemption" FAIL

OUT="$(run_hook '{"tool_name":"Write","tool_input":{"file_path":"/x/src/config.example.json","content":"AKIA''IOSFODNN7RGY4Q2B"}}')"
[ -z "$OUT" ] && check "F2d *.example.* filename exemption" PASS || check "F2d *.example.* filename exemption" FAIL

OUT="$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"/x/__tests__/cfg.spec.py","new_string":"k = \"AKIA''IOSFODNN7RGY4Q2B\""}}')"
[ -z "$OUT" ] && check "F2e Edit-tool path exemption (__tests__/)" PASS || check "F2e Edit-tool path exemption (__tests__/)" FAIL

OUT="$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"/x/src/cfg.py","new_string":"k = \"AKIA''IOSFODNN7EXAMPLE\""}}')"
[ -z "$OUT" ] && check "F3 placeholder suppression (AWS doc key EXAMPLE) -> allow" PASS || check "F3 placeholder suppression (AWS doc key EXAMPLE) -> allow" FAIL

OUT="$(run_hook '{"tool_name":"Edit","tool_input":{"file_path":"/x/src/cfg.py","new_string":"cfg = \"AKIA''IOSFODNN7RGY4Q2B\" zensu-secret-allow"}}')"
[ -z "$OUT" ] && check "F4 inline zensu-secret-allow marker -> allow" PASS || check "F4 inline zensu-secret-allow marker -> allow" FAIL

OUT="$(run_hook '{"tool_name":"Write","tool_input":{"file_path":"/x/src/a.ts","content":"AKIA''IOSFODNN7RGY4Q2B"}}' ZENSU_SECRET_SCAN=off)"
[ -z "$OUT" ] && check "F5 ZENSU_SECRET_SCAN=off env -> allow" PASS || check "F5 ZENSU_SECRET_SCAN=off env -> allow" FAIL

OUT="$(run_hook 'this is not json')"
if is_deny "$OUT"; then check "F6 broken payload cannot bind a hook session -> deny" PASS; else check "F6 broken payload binding deny" FAIL; fi

OUT="$(run_hook '{"tool_name":"Bash","tool_input":{"command":"cat > creds.env <<EOF\nghp_''123456789012345678901234567890123456\nEOF"}}')"
case "$OUT" in *"$DENY"*github-token*) check "F7 Bash heredoc with GitHub token -> deny (rule named)" PASS;; *) check "F7 Bash heredoc with GitHub token -> deny (rule named)" FAIL;; esac

OUT="$(run_hook '{"tool_name":"Bash","tool_input":{"command":"ZENSU_SECRET_SCAN=off cat > creds.env <<EOF\nghp_''123456789012345678901234567890123456\nEOF"}}')"
[ -z "$OUT" ] && check "F7b inline ZENSU_SECRET_SCAN=off prefix on Bash -> allow" PASS || check "F7b inline ZENSU_SECRET_SCAN=off prefix on Bash -> allow" FAIL

OUT="$(run_hook '{"tool_name":"Bash","tool_input":{"command":"cat > creds.env <<EOF\nZENSU_SECRET_SCAN=off is the escape hatch\nghp_''123456789012345678901234567890123456\nEOF"}}')"
if is_deny "$OUT"; then check "F7c escape token inside heredoc BODY does not disable the scan" PASS; else check "F7c escape token inside heredoc BODY does not disable the scan" FAIL; fi

OUT="$(run_hook '{"tool_name":"Bash","tool_input":{"command":"echo ghp_''123456789012345678901234567890123456"}}')"
[ -z "$OUT" ] && check "F8 Bash without write channel -> allow" PASS || check "F8 Bash without write channel -> allow" FAIL

OUT="$(run_hook '{"tool_name":"MultiEdit","tool_input":{"file_path":"/x/src/n.go","edits":[{"new_string":"ok"},{"new_string":"t := \"xox''b-1234567890-abcdefghij\""}]}}')"
case "$OUT" in *"$DENY"*slack-token*) check "F9 MultiEdit with Slack token -> deny (rule named)" PASS;; *) check "F9 MultiEdit with Slack token -> deny (rule named)" FAIL;; esac

OUT="$(run_hook '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"/x/nb/analysis.ipynb","new_source":"key = \"sk_''live_abcdef1234567890XY\""}}')"
case "$OUT" in *"$DENY"*stripe-live-key*) check "F10 NotebookEdit with Stripe key -> deny (rule named)" PASS;; *) check "F10 NotebookEdit with Stripe key -> deny (rule named)" FAIL;; esac

OUT="$(run_hook '{"tool_name":"Write","tool_input":{"file_path":"/x/src/a.ts","content":"AKIA''IOSFODNN7RGY4Q2B"}}' ZENSU_CONFIG="$TMPD/config-off.json")"
[ -z "$OUT" ] && check "F11 hooks.secretScan:false -> allow" PASS || check "F11 hooks.secretScan:false -> allow" FAIL

OUT="$(run_hook '{"tool_name":"Write","tool_input":{"file_path":"/x/src/readme.md","content":"plain documentation text, nothing secret"}}')"
[ -z "$OUT" ] && check "F12 clean content -> allow" PASS || check "F12 clean content -> allow" FAIL

mkdir -p "$TMPD/shim"
cat > "$TMPD/shim/node" <<'SHIM'
#!/bin/bash
for a in "$@"; do
  case "$a" in *secret-scan-decide.js*) exit 1;; esac
done
exec "$REAL_NODE_BIN" "$@"
SHIM
chmod +x "$TMPD/shim/node" 2>/dev/null
REAL_NODE_DIR="$(dirname "$(command -v node)")"
# Effectiveness probe: this case needs a chmod +x'd script to be executable by
# bare name off PATH. Filesystems that ignore the Unix exec bit (Windows
# git-bash, some mounts) can't simulate the node shim, so skip rather than fail.
printf '#!/bin/bash\necho SHIMOK\n' > "$TMPD/shim/_probe"
chmod +x "$TMPD/shim/_probe" 2>/dev/null
if [ "$(PATH="$TMPD/shim:/usr/bin:/bin" _probe 2>/dev/null)" = "SHIMOK" ]; then
  OUT="$(run_hook '{"tool_name":"Write","tool_input":{"file_path":"/x/src/a.ts","content":"AKIA''IOSFODNN7RGY4Q2B"}}' \
    REAL_NODE_BIN="$REAL_NODE_DIR/node" PATH="$TMPD/shim:$REAL_NODE_DIR:/usr/bin:/bin")"
  [ -z "$OUT" ] && check "F13 scanner crash (node shim rc=1) -> fail-open allow" PASS || check "F13 scanner crash (node shim rc=1) -> fail-open allow" FAIL
else
  check "F13 scanner crash -> fail-open allow (skipped: FS ignores exec bit)" PASS
fi
rm -f "$TMPD/shim/_probe" 2>/dev/null

echo "----"
echo "test-secret-scan-gate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
