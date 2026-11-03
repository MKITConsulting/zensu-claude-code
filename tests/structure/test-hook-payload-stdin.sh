#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCANNER="$PLUGIN_DIR/tests/structure/hook-payload-stdin-scan.js"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$SCANNER" ]; then
  check "tests/structure/hook-payload-stdin-scan.js exists" FAIL
  echo "----"
  echo "test-hook-payload-stdin: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP="$(mktemp -d -t hookpayload-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fixture() {
  mkdir -p "$TMP/$1/hooks/lib"
  cat > "$TMP/$1/$2"
}

scan() {
  node "$SCANNER" "$TMP/$1" 2>/dev/null
}

flagged() {
  printf '%s\n' "$1" | grep -qF -- "$2"
}

REAL="$(node "$SCANNER" "$PLUGIN_DIR" 2>"$TMP/real.err")"
REAL_RC=$?
if [ "$REAL_RC" -eq 0 ] && [ -z "$REAL" ]; then
  check "H1 no hook hands its payload to a child through an environment variable or an argument" PASS
else
  check "H1 a hook hands its payload to a child through an environment variable or an argument, so an oversized payload fails the exec with E2BIG and the hook reads the empty output as nothing to do; pipe it instead (printf '%s' \"\$INPUT\" | node ...) (rc=$REAL_RC)" FAIL
  printf '%s\n' "$REAL" | sed 's/^/        /'
fi

EXPECTED_FILES=0
for f in "$PLUGIN_DIR"/hooks/*.sh "$PLUGIN_DIR"/hooks/checks/*.sh "$PLUGIN_DIR"/hooks/lib/*.sh; do
  [ -f "$f" ] && EXPECTED_FILES=$((EXPECTED_FILES+1))
done
SCANNED="$(sed -n 's/^scanned \([0-9][0-9]*\) shell file.*/\1/p' "$TMP/real.err")"
if [ "$EXPECTED_FILES" -gt 0 ] && [ "$SCANNED" = "$EXPECTED_FILES" ]; then
  check "H2 the scan read all $EXPECTED_FILES shell files under hooks/, hooks/checks/ and hooks/lib/" PASS
else
  check "H2 the scan read ${SCANNED:-no} of $EXPECTED_FILES shell files under hooks/, hooks/checks/ and hooks/lib/" FAIL
fi

STDIN_HOOKS="$( { grep -lE '[A-Za-z_]+="?\$\( *(\{ *)?(cat|head)([ );]|$)' "$PLUGIN_DIR"/hooks/*.sh "$PLUGIN_DIR"/hooks/checks/*.sh; grep -lF "read -r -d ''" "$PLUGIN_DIR"/hooks/*.sh "$PLUGIN_DIR"/hooks/checks/*.sh; } 2>/dev/null | sort -u | wc -l | tr -d ' ')"
SOURCE_HOOKS="$(sed -n 's/.* in \([0-9][0-9]*\) hook script(s);.*/\1/p' "$TMP/real.err")"
FUNCTIONS="$(sed -n 's/.*; payload functions \([0-9][0-9]*\);.*/\1/p' "$TMP/real.err")"
if [ "$STDIN_HOOKS" -gt 0 ] && [ "$SOURCE_HOOKS" = "$STDIN_HOOKS" ] && [ "${FUNCTIONS:-0}" -gt 0 ]; then
  check "H3 the scan found the payload read in each of the $STDIN_HOOKS hook scripts that read stdin and traced it into $FUNCTIONS library functions" PASS
else
  check "H3 the scan found a payload read in ${SOURCE_HOOKS:-no} of $STDIN_HOOKS hook scripts that read stdin and traced it into ${FUNCTIONS:-no} library functions" FAIL
fi

fixture p1 hooks/a.sh <<'SH'
{ INPUT="$(cat)"; } 2>/dev/null
FIELD="$(PAYLOAD="$INPUT" node -e 'x')"
SH
OUT="$(scan p1)"
flagged "$OUT" "hooks/a.sh:2	environment	\$INPUT" \
  && check "C1 an environment prefix that carries \$INPUT is flagged" PASS \
  || check "C1 environment prefix with \$INPUT (got '$OUT')" FAIL

fixture p2 hooks/a.sh <<'SH'
INPUT="$(cat 2>/dev/null || true)"
OUT="$(MODE=targets \
  PAYLOAD="${INPUT}" node ./parse.js)"
SH
OUT="$(scan p2)"
flagged "$OUT" "hooks/a.sh:3	environment	\$INPUT" \
  && check "C2 a braced reference on a continued line is flagged on its own line" PASS \
  || check "C2 braced reference on a continued line (got '$OUT')" FAIL

fixture p3 hooks/a.sh <<'SH'
IFS= read -r -d '' INPUT || true
node ./a.js --payload "$INPUT"
SH
OUT="$(scan p3)"
flagged "$OUT" "hooks/a.sh:2	argument	\$INPUT" \
  && check "C3 the payload as an argument after the command word is flagged" PASS \
  || check "C3 payload as an argument (got '$OUT')" FAIL

fixture p4 hooks/lib/l.sh <<'SH'
read_field() {
  PAYLOAD="$1" FIELD="$2" node -e 'x'
}
SH
fixture p4 hooks/a.sh <<'SH'
INPUT="$(cat)"
source "$(dirname "$0")/lib/l.sh"
read_field "$INPUT" cwd
SH
OUT="$(scan p4)"
flagged "$OUT" "hooks/lib/l.sh:2	environment	\$1" \
  && check "C4 a library function's \$1 is flagged when a hook passes it the payload" PASS \
  || check "C4 payload function parameter (got '$OUT')" FAIL

fixture p5 hooks/lib/l.sh <<'SH'
outer() {
  local verb="${1:-}" input="${2:-}"
  inner "$input"
}
inner() {
  local payload="${1:-}"
  jq -r .x "$payload"
}
SH
fixture p5 hooks/a.sh <<'SH'
INPUT="$(cat)"
outer post "$INPUT"
SH
OUT="$(scan p5)"
flagged "$OUT" "hooks/lib/l.sh:7	argument	\$payload" \
  && check "C5 the payload is followed through a local copy and a second function" PASS \
  || check "C5 payload through a local copy and a second function (got '$OUT')" FAIL

fixture p6 hooks/a.sh <<'SH'
{ PAYLOAD="$(cat)"; } 2>/dev/null
PAYLOAD_BODY="$PAYLOAD" node -e 'x'
SH
OUT="$(scan p6)"
flagged "$OUT" "hooks/a.sh:2	environment	\$PAYLOAD" \
  && check "C6 a payload read from stdin under another name is flagged" PASS \
  || check "C6 payload under another name (got '$OUT')" FAIL

fixture p7 hooks/a.sh <<'SH'
INPUT="$(cat)"
export HOOK_PAYLOAD="$INPUT"
node -e 'x'
SH
OUT="$(scan p7)"
flagged "$OUT" "hooks/a.sh:2	export	\$INPUT" \
  && check "C7 exporting the payload is flagged" PASS \
  || check "C7 exported payload (got '$OUT')" FAIL

fixture p8 hooks/a.sh <<'SH'
INPUT="$(cat)"
env PAYLOAD="$INPUT" node -e 'x'
SH
OUT="$(scan p8)"
flagged "$OUT" "hooks/a.sh:2	argument	\$INPUT" \
  && check "C8 the payload handed to env as an assignment argument is flagged" PASS \
  || check "C8 payload through env (got '$OUT')" FAIL

fixture p9 hooks/a.sh <<'SH'
handle() {
  shift
  node ./a.js "$1"
}
INPUT="$(cat)"
handle post "$INPUT"
SH
OUT="$(scan p9)"
flagged "$OUT" "hooks/a.sh:3	argument	\$1" \
  && check "C9 a positional parameter after shift in a payload function is flagged" PASS \
  || check "C9 positional parameter after shift (got '$OUT')" FAIL

fixture n1 hooks/a.sh <<'SH'
#!/bin/bash
{ INPUT="$(cat)"; } 2>/dev/null
printf '%s' "$INPUT" | node -e 'require("fs").readFileSync(0, "utf8")'
node ./a.js <<<"$INPUT"
case "$INPUT" in *'"tool_name"'*) ;; *) exit 0 ;; esac
[ -n "$INPUT" ] || exit 0
[[ "$INPUT" == *x* ]] && true
COPY="$INPUT"
SUMMARY="$(printf '%s' "$INPUT" | node -e 'x')" node -e 'y'
LENGTH="${#INPUT}" node -e 'x'
node -e '
  const text = "PAYLOAD=\"$INPUT\" node";
'
# PAYLOAD="$INPUT" node -e 'x'
node - <<'NODE'
PAYLOAD="$INPUT" node -e 'x'
NODE
read_field() {
  printf '%s' "$1" | FIELD="$2" node -e 'x'
}
TRANSCRIPT="$(read_field "$INPUT" transcript_path)"
copy_through() {
  local payload="${1:-}"
  printf '%s' "$payload" | node -e 'x'
}
copy_through "$INPUT"
SH
fixture n1 hooks/b.sh <<'SH'
INPUT="$(cat)"
read_field() {
  node -e 'x' "$1"
}
read_field session_id
SH
OUT="$(scan n1)"
RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] \
  && check "C10 stdin pipes, here-strings, tests, local copies, quoted text, comments, heredoc bodies and a same-named function in another hook stay unflagged" PASS \
  || check "C10 safe shapes flagged (rc=$RC: $OUT)" FAIL

fixture u1 hooks/a.sh <<'SH'
INPUT="$(cat)"
PAYLOAD="$INPUT node -e 'x'
SH
OUT="$(scan u1)"
RC=$?
[ "$RC" -eq 1 ] && flagged "$OUT" "hooks/a.sh:2	unparsed" \
  && check "C11 a file the scan cannot read fails the check instead of passing unread" PASS \
  || check "C11 unreadable file (rc=$RC: $OUT)" FAIL

echo "----"
echo "test-hook-payload-stdin: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
