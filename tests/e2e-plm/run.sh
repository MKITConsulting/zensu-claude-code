#!/bin/bash
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

# Narrow branch-aware assertion for the Pulse fixture. Regex-only probes cannot
# distinguish an unconditional walk-back from a command explicitly scoped to a
# real session ID, especially when the qualifier follows the command.
pulse_disabled_followup_safe() {
  printf '%s' "$1" | node -e '
    let input = "";
    process.stdin.on("data", chunk => input += chunk);
    process.stdin.on("end", () => {
      const text = input.toLowerCase().replace(/\s+/g, " ").trim();
      const disabledAt = text.indexOf("tracking_disabled");
      if (disabledAt < 0) process.exit(1);

      const firstMatchIndex = (value, expressions) => {
        const hits = expressions.map(expression => value.search(expression)).filter(index => index >= 0);
        return hits.length ? Math.min(...hits) : -1;
      };
      const bareQualifiedId = /\b(?:real|valid|canonical|non[- ]?empty)\s+(?:session\s+)?id\b/;
      const positiveIdState = [
        /\b(?:session\s+)?id\s+(?:was\s+|is\s+)?(?:returned|received|created|available|present|real|valid|canonical|non[- ]?empty|set)\b/,
        /\b(?:session\s+)?id\s+exists\b/,
        /\bstart\s+(?:returns?|returned|creates?|created)\s+(?:a\s+)?(?:real\s+|valid\s+|canonical\s+)?(?:session\s+)?id\b/
      ];
      const positiveIdEvidenceAt = clause => {
        const hits = [];
        const stateAt = firstMatchIndex(clause, positiveIdState);
        if (stateAt >= 0) hits.push(stateAt);
        const bareAt = clause.search(bareQualifiedId);
        if (bareAt >= 0 && /\b(?:with|when|if|for)\b/.test(clause.slice(0, bareAt))) hits.push(bareAt);
        return hits.length ? Math.min(...hits) : -1;
      };
      const hasNegativeIdEvidence = clause =>
        /\b(?:no|without)(?:\s+(?:a|an|the))?\s+(?:real\s+|valid\s+|canonical\s+|non[- ]?empty\s+|invalid\s+|malformed\s+|non[- ]?canonical\s+)?(?:session\s+)?id\b/.test(clause)
        || /\b(?:unavailable|absent|missing|empty|unset|invalid|malformed|non[- ]?canonical)\s+(?:session\s+)?id\b/.test(clause)
        || /\b(?:real\s+|valid\s+|canonical\s+|non[- ]?empty\s+)?(?:session\s+)?id\s+(?:was\s+|is\s+)?(?:unavailable|absent|missing|empty|unset|invalid|malformed|non[- ]?canonical)\b/.test(clause)
        || /\b(?:session\s+)?id\s+(?:was\s+|is\s+)?(?:not|never)\s+(?:returned|received|created|available|present|real|valid|canonical|non[- ]?empty|set)\b/.test(clause)
        || /\b(?:session\s+)?id\s+(?:isn\x27t|isn\u2019t|wasn\x27t|wasn\u2019t)\s+(?:returned|received|created|available|present|real|valid|canonical|non[- ]?empty|set)\b/.test(clause)
        || /\b(?:session\s+)?id\s+(?:does\s+not|doesn\x27t|doesn\u2019t)\s+exist\b/.test(clause)
        || /\b(?:do(?:es)?\s+not|don\x27t|don\u2019t|doesn\x27t|doesn\u2019t|did\s+not|didn\x27t|didn\u2019t|will\s+not|won\x27t|won\u2019t|must\s+not|should\s+not|cannot|never)\s+(?:return(?:s|ed|ing)?|creat(?:e|es|ed|ing)|provid(?:e|es|ed|ing)|contain(?:s|ed|ing)?|sav(?:e|es|ed|ing)|stor(?:e|es|ed|ing)|retain(?:s|ed|ing)?|record(?:s|ed|ing)?|persist(?:s|ed|ing)?|invent(?:s|ed|ing)?|fabricat(?:e|es|ed|ing)|yield(?:s|ed|ing)?)\s+(?:a\s+|an\s+|the\s+)?(?:real\s+|valid\s+|canonical\s+|non[- ]?empty\s+)?(?:session\s+)?id\b/.test(clause);
      const hasDisabledIdQualifier = clause => hasNegativeIdEvidence(clause);

      const commandIsSuppressed = (segment, commandAt, commandEnd) => {
        const before = segment.slice(0, commandAt);
        const after = segment.slice(commandEnd);
        const skip = before.match(/\b(?:skip(?:s|ped|ping)?|omit(?:s|ted|ting)?|avoid(?:s|ed|ing)?|suppress(?:es|ed|ing)?)\s+(?:the\s+)?$/);
        if (skip) {
          const lead = before.slice(0, skip.index);
          const negatesSkip = /\b(?:(?:do(?:es)?|did|will|would|should|must|can)\s+not|don\x27t|don\u2019t|doesn\x27t|doesn\u2019t|didn\x27t|didn\u2019t|won\x27t|won\u2019t|wouldn\x27t|wouldn\u2019t|shouldn\x27t|shouldn\u2019t|mustn\x27t|mustn\u2019t|can\x27t|can\u2019t|cannot|never)\s*$/.test(lead);
          return !negatesSkip;
        }
        const without = before.match(/\bwithout(?:\s+(?:running|calling|executing|invoking|using|issuing|performing))?\s+(?:the\s+)?$/);
        if (without) {
          const lead = before.slice(0, without.index);
          if (!/\b(?:not|never)\s*$|\b(?:isn\x27t|isn\u2019t|wasn\x27t|wasn\u2019t)\s*$/.test(lead)) return true;
        }
        const negatedAction = /\b(?:(?:do(?:es)?|did|will|would|should|must|can)\s+not|don\x27t|don\u2019t|doesn\x27t|doesn\u2019t|didn\x27t|didn\u2019t|won\x27t|won\u2019t|wouldn\x27t|wouldn\u2019t|shouldn\x27t|shouldn\u2019t|mustn\x27t|mustn\u2019t|can\x27t|can\u2019t|cannot|never|not)\s+(?:(?:try|attempt|intend|plan|proceed)(?:s|ed|ing)?\s+to\s+)?(?:run(?:s|ning)?|call(?:s|ed|ing)?|execut(?:e|es|ed|ing)|invok(?:e|es|ed|ing)|us(?:e|es|ed|ing)|issu(?:e|es|ed|ing)|perform(?:s|ed|ing)?|trigger(?:s|ed|ing)?|send(?:s|ing)?|request(?:s|ed|ing)?)\s+(?:the\s+)?(?:\x60?zensu\s+)?$/.test(before);
        if (negatedAction) return true;
        return /^\s+(?:is|are|was|were|will\s+be|must\s+be|should\s+be)\s+(?:skipped|omitted|avoided|suppressed|not\s+(?:run|called|executed|invoked|used|issued|performed))\b/.test(after.slice(0, 120));
      };

      const segments = text.slice(disabledAt)
        .split(/[.!?;]+|\s*,\s*|\bbut\b|\bhowever\b|\botherwise\b|\bthen\b|\band\s+(?=(?:i|it|we|the\s+agent|with|when|if|for)\b)/)
        .map(value => value.trim()).filter(Boolean);
      let enabledScope = false;
      for (const segment of segments) {
        const disabledStatus = segment.includes("tracking_disabled");
        const disabledId = hasDisabledIdQualifier(segment);
        if (disabledStatus || disabledId) enabledScope = false;
        const positiveAt = disabledStatus || disabledId ? -1 : positiveIdEvidenceAt(segment);

        const command = /\b(?:zensu\s+)?pulse\s+(?:end|summary)\b/g;
        let match, previousCommandEnd = -1, previousCommandSuppressed = false;
        while ((match = command.exec(segment)) !== null) {
          const coordinatedSuppression = previousCommandSuppressed
            && /^\s*(?:and|or)\s*$/.test(segment.slice(previousCommandEnd, match.index));
          const suppressed = coordinatedSuppression || commandIsSuppressed(segment, match.index, command.lastIndex);
          previousCommandEnd = command.lastIndex;
          previousCommandSuppressed = suppressed;
          if (suppressed) continue;
          const evidenceBefore = positiveAt >= 0 && positiveAt < match.index;
          const evidenceAfter = positiveAt > match.index
            && /\bonly\s+(?:if|when)\b/.test(segment.slice(command.lastIndex, positiveAt));
          if (!enabledScope && !evidenceBefore && !evidenceAfter) process.exit(1);
        }
        if (positiveAt >= 0) enabledScope = true;
      }
      process.exit(0);
    });
  '
}

match_pattern() {
  local pattern_file="$1" captured_file="$2"
  [ -f "$pattern_file" ] || return 1
  [ -f "$captured_file" ] || return 1
  local line needle normalized_capture
  normalized_capture="$(tr '\r\n' '  ' < "$captured_file")"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in
      "# "*) continue ;;
      "@pulse-disabled-followup-safe")
        if ! pulse_disabled_followup_safe "$normalized_capture"; then
          return 1
        fi
        ;;
      "!"*)
        needle="${line#!}"
        needle="${needle#"${needle%%[![:space:]]*}"}"
        needle="${needle%"${needle##*[![:space:]]}"}"
        if [ -z "$needle" ]; then
          printf '  WARN  empty negative-assert needle (pattern author typo) in %s\n' "$pattern_file" | tee -a "$REPORT" >&2
          continue
        fi
        if grep -Eqi -- "$needle" <<<"$normalized_capture"; then
          return 1
        fi
        ;;
      *)
        if ! grep -Eqi -- "$line" "$captured_file" \
          && ! grep -Eqi -- "$line" <<<"$normalized_capture"; then
          return 1
        fi
        if [ -n "${VERBOSE_MATCH:-}" ]; then
          local _match_text
          _match_text="$(grep -Eoi -- "$line" "$captured_file" | head -1)"
          [ -n "$_match_text" ] || _match_text="$(grep -Eoi -- "$line" <<<"$normalized_capture" | head -1)"
          [ -z "$_match_text" ] && _match_text="$line"
          printf '  MATCH  %s <- %s\n' "$(basename "$pattern_file")" "$_match_text" | tee -a "$REPORT"
        fi
        ;;
    esac
  done < "$pattern_file"
  return 0
}

invoke_plm() {
  local fixture_dir="$1" captured_file="$2"
  local fixture_name
  fixture_name="$(basename "$fixture_dir")"
  local prompt_file="$PROMPTS_DIR/${fixture_name}.txt"

  if [ ! -f "$prompt_file" ]; then
    return 64
  fi

  local prompt
  prompt="$(cat "$prompt_file")"
  # Hermetic against the user's personal output-style plugins (e.g. caveman):
  # tests assert the agent NAMES its tools/sections, which a compressed style can
  # drop. Prepend a normal-mode directive so the run measures plugin behavior.
  prompt="${ZENSU_E2E_NORMAL_PREAMBLE:-Normal mode — respond in full prose (NOT caveman/compressed/ultra). Name every Zensu skill, CLI command, or MCP tool you would use by its exact name.}

$prompt"

  (
    cd "$fixture_dir" 2>/dev/null || cd "$EVAL_DIR" || exit 1
    claude --print --plugin-dir "$PLUGIN_DIR" --agent zensu:zensu-plm --permission-mode bypassPermissions "$prompt"
  ) > "$captured_file" 2>&1
}

log "=== zensu-plm Agent E2E: $TIMESTAMP ($MODE) ==="
log "Plugin dir: $PLUGIN_DIR"
log "Fixtures:   $FIXTURES_DIR"
log "Prompts:    $PROMPTS_DIR"

if [ ! -d "$FIXTURES_DIR" ]; then
  log "  (no fixtures directory at $FIXTURES_DIR — treating as empty)"
fi

log ""
log "▸ Fixture evaluations"

if [ -d "$FIXTURES_DIR" ]; then
  for fixture in "$FIXTURES_DIR"/*/; do
    [ -d "$fixture" ] || continue
    fixture_name="$(basename "$fixture")"
    case "$fixture_name" in
      live-regressions) continue ;;
    esac
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
        invoke_plm "$fixture" "$captured_file"
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
