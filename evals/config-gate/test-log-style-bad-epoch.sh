#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$WRAPPER" ]; then
  check "wrapper file exists" FAIL
  echo "----"
  echo "test-log-style-bad-epoch: $PASS PASS / $FAIL FAIL"
  exit 1
fi

export ZENSU_CONFIG="$EVAL_DIR/fixtures/config-log-relative.json"

STDERR_FILE="/tmp/zensu-log-bad-epoch-stderr-$$.txt"
rm -f "$STDERR_FILE"
stdout=$(bash "$WRAPPER" timestamp abc 2>"$STDERR_FILE")
rc=$?

if [ "$rc" -eq 0 ]; then
  check "exit code is 0 on non-numeric start arg" PASS
else
  check "exit code is 0 on non-numeric start arg (got $rc)" FAIL
fi

if [ "$stdout" = "[+00:00:00] " ]; then
  check "stdout is exactly '[+00:00:00] ' on non-numeric start arg in relative mode" PASS
else
  check "stdout is exactly '[+00:00:00] ' on non-numeric start arg in relative mode (got '$stdout')" FAIL
fi

if [ ! -s "$STDERR_FILE" ]; then
  check "stderr is empty on non-numeric start arg" PASS
else
  err=$(cat "$STDERR_FILE")
  check "stderr is empty on non-numeric start arg (got '$err')" FAIL
fi

rm -f "$STDERR_FILE"

for lz in 08 09 010; do
  STDERR_FILE="/tmp/zensu-log-lz-$lz-stderr-$$.txt"
  rm -f "$STDERR_FILE"
  out=$(bash "$WRAPPER" timestamp "$lz" 2>"$STDERR_FILE")
  rc=$?
  err=$(cat "$STDERR_FILE")
  rm -f "$STDERR_FILE"

  if [ "$rc" -eq 0 ]; then
    check "leading-zero '$lz': exit code is 0 (no octal-parse error)" PASS
  else
    check "leading-zero '$lz': exit code is 0 (got $rc)" FAIL
  fi

  if [ -z "$err" ]; then
    check "leading-zero '$lz': stderr is empty (no octal-parse error)" PASS
  else
    check "leading-zero '$lz': stderr is empty (got '$err')" FAIL
  fi

  case "$out" in
    \[+*)
      check "leading-zero '$lz': stdout starts with '[+'" PASS
      ;;
    *)
      check "leading-zero '$lz': stdout starts with '[+' (got '$out')" FAIL
      ;;
  esac
done

echo "----"
echo "test-log-style-bad-epoch: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
