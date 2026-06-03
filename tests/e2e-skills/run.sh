#!/bin/bash
# Live E2E for the plugin's LLM surfaces that only had structure tests before:
#   zensu-help    (skill)  — read-only Q&A glossary
#   plan-review   (skill)  — multi-agent plan revalidation (TeamCreate)
#   self-review   (skill)  — terminal 7-dimension reflection over a diff
#   review-aspect (agent)  — single-perspective code reviewer
#
# Each fixture provides a prompt (prompts/<name>.txt) and a tolerant regex pattern
# (expected/<name>.pattern). Skills are invoked via their /slash form in the prompt
# (claude resolves skills via /skill-name under --print); a fixture that names an
# agent in prompts/<name>.agent is invoked with `--agent <name>` instead.
#
# Patterns are TOLERANT regexes (LLM output is non-deterministic). A line starting
# with `!` is a NEGATIVE assert (must NOT appear). `# ` lines are comments.
#
# Modes:
#   (no arg)/full   live run — calls `claude --print` per fixture (COSTS API CREDITS)
#   --offline       re-match the newest prior capture in results/ (no API)
#   --self-check    parse + skeleton only, no claude spawn (CI-safe, no API)
#
# Prereq for full/offline: run ./setup-fixtures.sh once to build the git fixtures.
set -u

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$EVAL_DIR/../.." && pwd)"

FIXTURES_DIR="${FIXTURES_DIR:-$EVAL_DIR/fixtures}"
EXPECTED_DIR="${EXPECTED_DIR:-$EVAL_DIR/expected}"
PROMPTS_DIR="${PROMPTS_DIR:-$EVAL_DIR/prompts}"
RESULTS_DIR="${RESULTS_DIR:-$EVAL_DIR/results}"
mkdir -p "$RESULTS_DIR"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$RESULTS_DIR/report-$TIMESTAMP.txt"

MODE="${1:-full}"

case "$MODE" in
  --self-check|--offline|""|full) ;;
  *)
    mkdir -p "$RESULTS_DIR"
    printf "  FAIL  unknown mode '%s' — accepted: --self-check, --offline, (no arg / full)\n" "$MODE" | tee -a "$REPORT" >&2
    exit 2
    ;;
esac

PASS_COUNT=0
FAIL_COUNT=0
TOTAL=0

log() {
  printf "%s\n" "$1" | tee -a "$REPORT"
}

check() {
  local label="$1" result="$2"
  TOTAL=$((TOTAL + 1))
  if [ "$result" = "PASS" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    log "  PASS  $label"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    log "  FAIL  $label"
  fi
}

# Positive asserts must match; `!`-prefixed asserts must NOT match; `# ` are comments.
match_pattern() {
  local pattern_file="$1" captured_file="$2"
  [ -f "$pattern_file" ] || return 1
  [ -f "$captured_file" ] || return 1
  local line needle
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in
      "# "*) continue ;;
      "!"*)
        needle="${line#!}"
        needle="${needle#"${needle%%[![:space:]]*}"}"
        needle="${needle%"${needle##*[![:space:]]}"}"
        if [ -z "$needle" ]; then
          printf '  WARN  empty negative-assert needle (pattern author typo) in %s\n' "$pattern_file" | tee -a "$REPORT" >&2
          continue
        fi
        if grep -Eqi -- "$needle" "$captured_file"; then
          return 1
        fi
        ;;
      *)
        if ! grep -Eqi -- "$line" "$captured_file"; then
          return 1
        fi
        ;;
    esac
  done < "$pattern_file"
  return 0
}

# Invoke a skill (via /slash prompt) or an agent (prompts/<name>.agent present).
invoke_target() {
  local fixture_dir="$1" captured_file="$2"
  local name
  name="$(basename "$fixture_dir")"
  local prompt_file="$PROMPTS_DIR/${name}.txt"
  [ -f "$prompt_file" ] || return 64

  local prompt
  prompt="$(cat "$prompt_file")"
  # Hermetic against the user's personal output-style plugins (e.g. caveman),
  # which compress section headings the patterns assert. APPEND (the skill
  # /slash must stay the first token) a normal-mode directive.
  prompt="$prompt

(${ZENSU_E2E_NORMAL_PREAMBLE:-Normal mode — respond in full prose, NOT caveman/compressed/ultra. Use all standard section headings and name tools explicitly.})"

  local agent_file="$PROMPTS_DIR/${name}.agent"
  local agent=""
  [ -f "$agent_file" ] && agent="$(tr -d '[:space:]' < "$agent_file")"

  (
    cd "$fixture_dir" 2>/dev/null || cd "$EVAL_DIR" || exit 1
    if [ -n "$agent" ]; then
      claude --print --plugin-dir "$PLUGIN_DIR" --agent "$agent" --permission-mode bypassPermissions "$prompt"
    else
      claude --print --plugin-dir "$PLUGIN_DIR" --permission-mode bypassPermissions "$prompt"
    fi
  ) > "$captured_file" 2>&1
}

log "=== Skill/Agent LLM E2E: $TIMESTAMP ($MODE) ==="
log "Plugin dir: $PLUGIN_DIR"
log "Fixtures:   $FIXTURES_DIR"
log "Prompts:    $PROMPTS_DIR"

if [ ! -d "$FIXTURES_DIR" ]; then
  log "  (no fixtures directory at $FIXTURES_DIR — run ./setup-fixtures.sh first)"
fi

log ""
log "▸ Fixture evaluations"

if [ -d "$FIXTURES_DIR" ]; then
  for fixture in "$FIXTURES_DIR"/*/; do
    [ -d "$fixture" ] || continue
    fixture_name="$(basename "$fixture")"
    pattern_file="$EXPECTED_DIR/${fixture_name}.pattern"
    prompt_file="$PROMPTS_DIR/${fixture_name}.txt"

    captured_file=""
    case "$MODE" in
      --self-check)
        continue
        ;;
      --offline)
        captured_file="$(ls -t "$RESULTS_DIR/${fixture_name}-"*.captured.txt 2>/dev/null | head -1)"
        if [ -z "$captured_file" ] || [ ! -f "$captured_file" ]; then
          check "$fixture_name (no prior capture in $RESULTS_DIR matching ${fixture_name}-*.captured.txt)" FAIL
          continue
        fi
        ;;
      ""|full)
        if [ ! -f "$prompt_file" ]; then
          check "$fixture_name (missing prompt file $prompt_file)" FAIL
          continue
        fi
        captured_file="$RESULTS_DIR/${fixture_name}-${TIMESTAMP}.captured.txt"
        invoke_target "$fixture" "$captured_file"
        ;;
    esac

    if [ ! -s "$captured_file" ]; then
      check "$fixture_name (zero-byte capture — claude --print produced no output)" FAIL
      continue
    fi

    if [ ! -f "$pattern_file" ]; then
      check "$fixture_name (missing pattern file $pattern_file)" FAIL
      continue
    fi

    if match_pattern "$pattern_file" "$captured_file"; then
      check "$fixture_name" PASS
    else
      check "$fixture_name" FAIL
    fi
  done
fi

log ""
log "════════════════════════════════════════"
log "  TOTAL: $PASS_COUNT/$TOTAL PASS ($FAIL_COUNT FAIL)"
log "  Report: $REPORT"
log "════════════════════════════════════════"

[ "$FAIL_COUNT" -eq 0 ]
