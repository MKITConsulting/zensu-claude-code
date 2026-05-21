#!/bin/bash
#
# assert-tdd-log-compliance.sh — verify a TDD log file satisfies the
# Per-Step Logging Contract from agents/tdd-manager.md (Principle 3).
#
# Usage:
#   assert-tdd-log-compliance.sh --log <path> [--impl-dir <path>]
#
# Required checks:
#   1. For every `{step_id} GREEN ` entry, a preceding `{step_id} RED ` AND
#      `{step_id} IMPL ` entry must exist with the SAME step_id.
#   2. Reject "bulk-shortcut" RED entries — a RED line whose step_id token
#      contains a range like `BE-1..6` or `BE-1,BE-2` does not satisfy the
#      RED requirement for any constituent step. Each step needs its OWN
#      RED entry.
#   3. With --impl-dir: per step, parse `IMPL completed — files: <list>`,
#      resolve each file under --impl-dir, find the test file via the
#      RED entry's `{test_name}` token, and compare mtimes. If any test
#      mtime exceeds any matching impl mtime for that step → violation.
#
# Exit codes:
#   0   all checks pass
#   1   compliance violation (message names the offending step)
#   2   usage error
#
# Step-id grammar: `[A-Z0-9]+-[A-Z0-9]+` (e.g. BE-1, FE-12, S1) — alphanumeric
# token, hyphen, alphanumeric token. The bulk-shortcut detector treats any
# RED line whose step_id token contains `..`, `,`, or a whitespace-separated
# list of multiple step ids inside the same prefix as INVALID.

set -u

LOG_PATH=""
IMPL_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --log)
      LOG_PATH="${2:-}"
      shift 2
      ;;
    --impl-dir)
      IMPL_DIR="${2:-}"
      shift 2
      ;;
    --help|-h)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "assert-tdd-log-compliance: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$LOG_PATH" ]; then
  echo "assert-tdd-log-compliance: --log <path> is required" >&2
  exit 2
fi
if [ ! -f "$LOG_PATH" ]; then
  echo "assert-tdd-log-compliance: log file not found: $LOG_PATH" >&2
  exit 2
fi

# strip optional `[HH:MM:SS]` or `[+HH:MM:SS]` timestamp prefix from each line
# and return only the message body. Awk handles both wall and relative styles.
strip_ts() {
  awk '{
    if (match($0, /^\[[+0-9:dhms\\ ]+\] /)) {
      print substr($0, RSTART + RLENGTH)
    } else {
      print $0
    }
  }' "$1"
}

STEP_ID_RE='[A-Z][A-Z0-9]*-[A-Z0-9]+'

# Detect bulk-shortcut RED lines first (covers tokens like BE-1..6 or BE-1,BE-2).
# A bulk-shortcut RED line is any line whose first whitespace-delimited token
# contains a range marker (`..`) or a comma. We check BEFORE the body so the
# step-id parser does not silently accept a range as a real step_id.
detect_bulk_shortcut() {
  local body
  while IFS= read -r body; do
    case "$body" in
      *' RED '*)
        local first_token="${body%% *}"
        case "$first_token" in
          *..*|*,*)
            echo "BULK_RED_TOKEN:$first_token" ;;
        esac
        ;;
    esac
  done
  return 0
}

BULK_VIOLATIONS=$(strip_ts "$LOG_PATH" | detect_bulk_shortcut)
if [ -n "$BULK_VIOLATIONS" ]; then
  while IFS= read -r entry; do
    token="${entry#BULK_RED_TOKEN:}"
    echo "VIOLATION: bulk-shortcut RED line — '$token' collapses multiple step_ids into one RED entry. Each merged step requires its own RED log entry (Per-Step Logging Contract, Principle 3)." >&2
  done <<< "$BULK_VIOLATIONS"
  exit 1
fi

# Build lookup maps: which step_ids appeared in RED, IMPL, GREEN entries.
# We use the message body (timestamp stripped) so the parser is independent
# of the user's logging.timestampStyle setting.
TMP_BODY=$(mktemp)
trap 'rm -f "$TMP_BODY"' EXIT
strip_ts "$LOG_PATH" > "$TMP_BODY"

extract_steps_for() {
  local marker="$1"
  grep -E "^${STEP_ID_RE} ${marker} " "$TMP_BODY" \
    | awk '{print $1}' \
    | sort -u
}

RED_STEPS=$(extract_steps_for "RED")
IMPL_STEPS=$(grep -E "^${STEP_ID_RE} IMPL completed — files: " "$TMP_BODY" | awk '{print $1}' | sort -u)
GREEN_STEPS=$(extract_steps_for "GREEN")

# Grammar guard: if the log carries TDD-manager markers (TDD STARTED /
# EXECUTION STARTED / TDD COMPLETE / CHECKPOINT) but no step-id matched
# the uppercase grammar STEP_ID_RE, the log most likely uses a wrong prefix
# convention (e.g. lowercase `be-1` instead of `BE-1`). Without this guard
# the previous behavior was a silent exit 0, defeating the entire audit.
if grep -qE '^(TDD STARTED|EXECUTION STARTED|TDD COMPLETE|CHECKPOINT)' "$TMP_BODY"; then
  if [ -z "$RED_STEPS" ] && [ -z "$IMPL_STEPS" ] && [ -z "$GREEN_STEPS" ]; then
    echo "VIOLATION: no step entries detected — log may use wrong prefix grammar (expected uppercase step-ids like BE-1, S1)" >&2
    exit 1
  fi
fi

# Return the line number (in the timestamp-stripped body) of the FIRST entry
# matching `{step} {marker}` (where marker is RED/IMPL/GREEN). Empty string if
# no match. Used for ordering enforcement so a log with GREEN at line 3 and RED
# at line 5 is rejected even though both entries exist.
step_marker_line() {
  local step="$1" marker="$2"
  if [ "$marker" = "IMPL" ]; then
    awk -v step="$step" '
      $0 ~ "^"step" IMPL completed — files: " {print NR; exit}
    ' "$TMP_BODY"
  else
    awk -v step="$step" -v marker="$marker" '
      $0 ~ "^"step" "marker" " {print NR; exit}
    ' "$TMP_BODY"
  fi
}

# Every GREEN step must have a matching RED and IMPL entry, AND they must
# appear in canonical order: red_line < impl_line < green_line.
VIOLATIONS=0
while IFS= read -r step; do
  [ -z "$step" ] && continue
  has_red=0
  has_impl=0
  grep -qx "$step" <<< "$RED_STEPS" && has_red=1
  grep -qx "$step" <<< "$IMPL_STEPS" && has_impl=1
  if [ "$has_red" -eq 0 ]; then
    echo "VIOLATION: step '$step' has GREEN entry but no matching RED entry. Per-Step Logging Contract requires {step_id} RED before {step_id} GREEN." >&2
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
  if [ "$has_impl" -eq 0 ]; then
    echo "VIOLATION: step '$step' has GREEN entry but no matching 'IMPL completed — files:' entry. Per-Step Logging Contract requires IMPL log between RED and GREEN." >&2
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
  if [ "$has_red" -eq 1 ] && [ "$has_impl" -eq 1 ]; then
    red_line=$(step_marker_line "$step" "RED")
    impl_line=$(step_marker_line "$step" "IMPL")
    green_line=$(step_marker_line "$step" "GREEN")
    if [ -n "$red_line" ] && [ -n "$green_line" ] && [ "$red_line" -ge "$green_line" ]; then
      echo "VIOLATION: step '$step' RED-after-GREEN ordering violation — RED entry on line $red_line appears after GREEN entry on line $green_line. RED must precede GREEN (Principle 1, RED→IMPL→GREEN)." >&2
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
    if [ -n "$impl_line" ] && [ -n "$red_line" ] && [ "$impl_line" -lt "$red_line" ]; then
      echo "VIOLATION: step '$step' IMPL-before-RED ordering violation — IMPL entry on line $impl_line appears before RED entry on line $red_line. RED must precede IMPL (Principle 1, RED→IMPL→GREEN)." >&2
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
    if [ -n "$impl_line" ] && [ -n "$green_line" ] && [ "$impl_line" -ge "$green_line" ]; then
      echo "VIOLATION: step '$step' IMPL-after-GREEN ordering violation — IMPL entry on line $impl_line is not before GREEN entry on line $green_line. IMPL must precede GREEN (Principle 1, RED→IMPL→GREEN)." >&2
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  fi
done <<< "$GREEN_STEPS"

if [ "$VIOLATIONS" -gt 0 ]; then
  exit 1
fi

# Optional mtime audit. For each GREEN step, extract its IMPL file list and
# its RED test name, resolve them under --impl-dir, and require every test
# file mtime <= every impl file mtime for the same step.
if [ -n "$IMPL_DIR" ]; then
  if [ ! -d "$IMPL_DIR" ]; then
    echo "assert-tdd-log-compliance: --impl-dir path not found: $IMPL_DIR" >&2
    exit 2
  fi

  # cross-platform mtime: BSD uses `stat -f %m`, GNU uses `stat -c %Y`.
  file_mtime() {
    local f="$1"
    if stat -f %m "$f" >/dev/null 2>&1; then
      stat -f %m "$f"
    else
      stat -c %Y "$f"
    fi
  }

  while IFS= read -r step; do
    [ -z "$step" ] && continue

    # IMPL files for this step (comma-separated after "files: ")
    impl_line=$(grep -E "^${step} IMPL completed — files: " "$TMP_BODY" | head -1)
    if [ -z "$impl_line" ]; then
      continue
    fi
    impl_files=$(echo "$impl_line" | sed -E "s/^${step} IMPL completed — files: //")

    # RED test name token (5th field on the RED line, after `RED`)
    red_line=$(grep -E "^${step} RED " "$TMP_BODY" | head -1)
    if [ -z "$red_line" ]; then
      continue
    fi
    test_token=$(echo "$red_line" | awk '{print $3}')

    # Resolve test file under --impl-dir using heuristic matches.
    test_path=""
    for candidate in \
      "$IMPL_DIR/${test_token}" \
      "$IMPL_DIR/${test_token}.java" \
      "$IMPL_DIR/${test_token}.ts" \
      "$IMPL_DIR/${test_token}.spec.ts" \
      "$IMPL_DIR/${test_token}.test.ts" \
      "$IMPL_DIR/${test_token}.py" \
    ; do
      if [ -f "$candidate" ]; then
        test_path="$candidate"
        break
      fi
    done
    if [ -z "$test_path" ]; then
      match=$(find "$IMPL_DIR" -type f -name "${test_token}*" 2>/dev/null | head -1)
      if [ -n "$match" ]; then
        test_path="$match"
      fi
    fi
    if [ -z "$test_path" ]; then
      continue
    fi

    # Collision guard: if the heuristic resolved the test file to one of this
    # step's IMPL files (by basename match), the mtime comparison degenerates
    # into file-vs-itself and silently passes. Emit a visible WARN and skip
    # the mtime check for this step rather than yielding a false-pass.
    test_basename=$(basename "$test_path")
    collision=0
    OLDIFS=$IFS
    IFS=','
    for raw in $impl_files; do
      f=$(echo "$raw" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
      [ -z "$f" ] && continue
      if [ "$(basename "$f")" = "$test_basename" ]; then
        collision=1
        break
      fi
    done
    IFS=$OLDIFS
    if [ "$collision" -eq 1 ]; then
      echo "WARN: cannot resolve test file for step ${step} — heuristic collided with impl file ${test_path}; mtime audit skipped for this step" >&2
      continue
    fi

    test_mtime=$(file_mtime "$test_path")

    # iterate impl files (comma- or whitespace-separated)
    impl_min=""
    OLDIFS=$IFS
    IFS=','
    for raw in $impl_files; do
      f=$(echo "$raw" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
      [ -z "$f" ] && continue

      resolved=""
      if [ -f "$IMPL_DIR/$f" ]; then
        resolved="$IMPL_DIR/$f"
      else
        match=$(find "$IMPL_DIR" -type f -name "$(basename "$f")" 2>/dev/null | head -1)
        if [ -n "$match" ]; then resolved="$match"; fi
      fi
      [ -z "$resolved" ] && continue

      m=$(file_mtime "$resolved")
      if [ -z "$impl_min" ] || [ "$m" -lt "$impl_min" ]; then
        impl_min="$m"
      fi
    done
    IFS=$OLDIFS

    if [ -z "$impl_min" ]; then
      continue
    fi

    if [ "$test_mtime" -gt "$impl_min" ]; then
      echo "VIOLATION: step '$step' is test-after — test file '$test_path' (mtime=$test_mtime) is newer than impl files (min mtime=$impl_min). Tests must be written BEFORE implementation (Principle 1, RED→IMPL→GREEN)." >&2
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  done <<< "$GREEN_STEPS"

  if [ "$VIOLATIONS" -gt 0 ]; then
    exit 1
  fi
fi

exit 0
