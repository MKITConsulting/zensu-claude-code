#!/bin/bash

UNIT_REGISTRY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
UNIT_REGISTRY_JS="$UNIT_REGISTRY_ROOT/tests/structure/lib-unit-registry.js"
UNIT_DRIVER="${UNIT_DRIVER:-$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")}"
UNIT_MODE="${UNIT_MODE:-}"
UNIT_RUN_VERDICT=""
UNIT_GRADED=""

unit_abs_path() {
  case "$1" in
    (/*|[A-Za-z]:*) printf '%s' "$1" ;;
    (*) printf '%s/%s' "$PWD" "$1" ;;
  esac
}

unit_registry_cli() {
  local command="${1:-}"
  [ "$#" -gt 0 ] && shift
  if [ -n "${UNIT_REGISTRY_FILE:-}" ]; then
    node "$UNIT_REGISTRY_JS" "$command" --registry "$UNIT_REGISTRY_FILE" ${1+"$@"} 2>&1
  else
    node "$UNIT_REGISTRY_JS" "$command" ${1+"$@"} 2>&1
  fi
}

unit_one_line() {
  printf '%s' "$1" | tr '\r\n' '  ' | sed 's/  */ /g; s/ $//'
}

unit_failure_excerpt() {
  awk '
    function emit(line) {
      if (printed < 200) { print line; printed++ }
    }
    { ring[NR % 40] = $0 }
    /^not ok / {
      found = 1
      first = (held > 40) ? held - 40 : 0
      if (first > 0) emit("# (" first " earlier diagnostic line(s) omitted)")
      for (i = first; i < held; i++) emit(pending[i % 40])
      held = 0
      show = 1
      emit($0)
      next
    }
    /^ok / || /^1\.\./ || /^# (tests|suites|pass|fail|cancelled|skipped|todo|duration_ms) / { show = 0; held = 0; next }
    /^# Subtest: / { show = 0; next }
    show {
      emit($0)
      if ($0 == "  ...") show = 0
      next
    }
    /^# / { pending[held % 40] = $0; held++ }
    END {
      if (!found) {
        start = NR > 40 ? NR - 39 : 1
        for (i = start; i <= NR; i++) print ring[i % 40]
      }
    }
  ' "$1"
}

unit_grade() {
  local abs out rc verdict status=0
  abs="$(unit_abs_path "${1:-}")"
  out="${2:-}"
  rc="${3:-}"
  UNIT_GRADED="$UNIT_GRADED$abs
"
  verdict="$(unit_registry_cli verify --path "$abs" --output "$out" --rc "$rc" --driver "$UNIT_DRIVER" --mode "$UNIT_MODE" --cwd "$PWD")" || status=$?
  UNIT_RUN_VERDICT="$(unit_one_line "$verdict")"
  [ -n "$UNIT_RUN_VERDICT" ] || UNIT_RUN_VERDICT="${abs#"$UNIT_REGISTRY_ROOT"/}: the registry library printed no verdict (exit $status)"
  if [ "$status" -eq 1 ] && [ "${UNIT_RUN_TEE:-0}" != 1 ] && [ -r "$out" ]; then
    unit_failure_excerpt "$out" >&2
  fi
  return "$status"
}

unit_run() {
  local given="${1:-}" abs out rc=0 status=0 text=""
  [ "$#" -gt 0 ] && shift
  [ "${1:-}" = "--" ] && shift
  abs="$(unit_abs_path "$given")"
  out="${UNIT_RUN_OUTPUT:-}"
  if [ -z "$out" ] && [ "${UNIT_RUN_TEE:-0}" = 1 ]; then
    UNIT_RUN_VERDICT="${abs#"$UNIT_REGISTRY_ROOT"/}: UNIT_RUN_TEE needs UNIT_RUN_OUTPUT, a file the driver creates and removes"
    UNIT_GRADED="$UNIT_GRADED$abs
"
    return 2
  fi
  if [ -z "$out" ]; then
    if text="$(cd "$UNIT_REGISTRY_ROOT" && exec node --test --test-reporter=tap ${1+"$@"} "$abs" 2>&1)"; then
      rc=0
    else
      rc=$?
    fi
    out="$(mktemp "${TMPDIR:-/tmp}/zensu-unit-run-XXXXXX")" || {
      UNIT_RUN_VERDICT="${abs#"$UNIT_REGISTRY_ROOT"/}: cannot create a temp file for node's output"
      UNIT_GRADED="$UNIT_GRADED$abs
"
      return 2
    }
    printf '%s\n' "$text" > "$out"
    unit_grade "$abs" "$out" "$rc" || status=$?
    rm -f "$out"
    return "$status"
  fi
  if [ "${UNIT_RUN_TEE:-0}" = 1 ]; then
    if (cd "$UNIT_REGISTRY_ROOT" && exec node --test --test-reporter=tap ${1+"$@"} "$abs") 2>&1 | tee "$out"; then
      rc=${PIPESTATUS[0]}
    else
      rc=${PIPESTATUS[0]}
    fi
  else
    if (cd "$UNIT_REGISTRY_ROOT" && exec node --test --test-reporter=tap ${1+"$@"} "$abs") >"$out" 2>&1; then
      rc=0
    else
      rc=$?
    fi
  fi
  unit_grade "$abs" "$out" "$rc" || status=$?
  return "$status"
}

unit_not_run() {
  local abs
  abs="$(unit_abs_path "${1:-}")"
  UNIT_GRADED="$UNIT_GRADED$abs
"
  UNIT_RUN_VERDICT="NOT RUN ${abs#"$UNIT_REGISTRY_ROOT"/}: ${2:-no reason given}"
  printf '%s\n' "$UNIT_RUN_VERDICT"
  [ -z "${CI:-}" ]
}

unit_registry_done() {
  local verdict status=0 saved_ifs="$IFS" noglob=0
  case "$-" in (*f*) noglob=1 ;; esac
  IFS='
'
  set -f
  set -- $UNIT_GRADED
  [ "$noglob" = 1 ] || set +f
  IFS="$saved_ifs"
  verdict="$(unit_registry_cli owned --driver "$UNIT_DRIVER" --mode "$UNIT_MODE" --cwd "$PWD" -- ${1+"$@"})" || status=$?
  UNIT_RUN_VERDICT="$(unit_one_line "$verdict")"
  [ -n "$UNIT_RUN_VERDICT" ] || UNIT_RUN_VERDICT="the registry library printed no verdict (exit $status)"
  return "$status"
}

unit_check() {
  local label="${1:-}"
  [ "$#" -gt 0 ] && shift
  if unit_run "$@"; then
    check "$label ($UNIT_RUN_VERDICT)" PASS
  else
    check "$label: $UNIT_RUN_VERDICT" FAIL
  fi
}

unit_check_done() {
  if unit_registry_done; then
    check "${1:-unit registry} ($UNIT_RUN_VERDICT)" PASS
  else
    check "${1:-unit registry}: $UNIT_RUN_VERDICT" FAIL
  fi
}
