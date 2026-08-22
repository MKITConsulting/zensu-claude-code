#!/bin/bash
# Shared `node --test` summary parse for the structure suites that drive a unit
# file. NOT a suite itself — `tests/run-all.sh` iterates `structure/test-*.sh`, so
# this name is deliberately outside that glob and is sourced, never executed.
#
# WHY IT IS SHARED. The expression below is locale-sensitive in a way that fails
# SILENTLY, and it was hand-copied into two suites before this file existed. node
# --test emits its summary as `ℹ pass 29` under the spec reporter and `# pass 29`
# under TAP. U+2139 is THREE bytes in UTF-8, so a `^. pass` pattern matches one
# BYTE with LANG/LC_ALL/LC_CTYPE unset — macOS sed then runs in the C locale, the
# pattern never fires, the count parses as empty, and a driver flooring on it
# reports 0 cases while the unit suite itself passed 29. Anchoring on the trailing
# text removes the dependency; the `# pass` TAP branch stays FIRST so both reporter
# dialects still parse. One copy means the next correction has one site.
#
# ASSUMPTION, load-bearing and stated rather than left implicit: the trailing-text
# branch matches ANY line ending in whitespace + <field> + digits, so `tail -1`
# selects the summary only because node emits its summary block last. That is a
# property of the reporter, not of this helper. If a driver captures `2>&1` and a
# stray line can follow the summary, floor on the value with that in mind.
#
# WHY A COUNT AT ALL. `node --test` exits 0 whether a file registered its cases or
# not, so an exit-status-only driver cannot tell "the unit suite passed" from "the
# unit suite was emptied, renamed, or never collected a case". Measured, not assumed:
# an EMPTIED file reports `tests 1` — node counts the file itself as one test — and
# still exits 0 with zero failures. So the floor is what separates the two, and it
# floors on the registered TOTAL, because that is what catches a case silently
# skipping itself; the passing floor is separate and only lower where a skip is
# MEASURED.

# unit_summary_field <field> <file> — echoes the count, or 0 when absent/unparsed.
# Fields are node's own summary labels: tests, pass, fail, skipped, todo.
unit_summary_field() {
  local field="$1" file="$2" value
  # The field is interpolated into a sed SCRIPT, so anything but a bare label could
  # terminate the s/// expression and turn a count lookup into an arbitrary sed
  # program. Every caller passes a literal today; this keeps that true by force
  # rather than by convention.
  case "$field" in
    ''|*[!a-z]*) printf '0'; return 2 ;;
  esac
  [ -r "$file" ] || { printf '0'; return 1; }
  value="$(sed -n "s/^# $field \([0-9][0-9]*\)\$/\1/p;s/^.*[[:space:]]$field \([0-9][0-9]*\)\$/\1/p" "$file" | tail -1)"
  case "$value" in ''|*[!0-9]*) value=0 ;; esac
  printf '%s' "$value"
}

# unit_cases_meet_floor <file> <min_tests> [min_pass] — returns 0 when the unit
# suite registered at least <min_tests> cases and passed at least <min_pass> of
# them. <min_pass> defaults to <min_tests>: pass a LOWER value only for a skip you
# have measured, and say in the caller which case skips and on which host.
# Sets UNIT_CASES_TESTS / UNIT_CASES_PASS so the caller can report what it saw.
unit_cases_meet_floor() {
  local file="$1" min_tests="$2" min_pass="${3:-$2}"
  UNIT_CASES_TESTS="$(unit_summary_field tests "$file")"
  UNIT_CASES_PASS="$(unit_summary_field pass "$file")"
  [ "$UNIT_CASES_TESTS" -ge "$min_tests" ] && [ "$UNIT_CASES_PASS" -ge "$min_pass" ]
}

# unit_cases_report <file> — "N/M cases", for a check label.
unit_cases_report() {
  printf '%s/%s cases' "$(unit_summary_field pass "$1")" "$(unit_summary_field tests "$1")"
}

# TEXT variants, for the drivers that capture node's output into a variable rather
# than a file. They spool to a temp file and delegate, so the parse itself still
# exists exactly once — the point of this file is that there is no second copy of
# that expression to correct later.
unit_cases_meet_floor_text() {
  local text="$1" min_tests="$2" min_pass="${3:-$2}" tmp rc
  tmp="$(mktemp "${TMPDIR:-/tmp}/zensu-unit-summary-XXXXXX")" || return 1
  printf '%s\n' "$text" > "$tmp"
  unit_cases_meet_floor "$tmp" "$min_tests" "$min_pass"
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

unit_cases_report_text() {
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/zensu-unit-summary-XXXXXX")" || { printf 'unreadable'; return 1; }
  printf '%s\n' "$1" > "$tmp"
  unit_cases_report "$tmp"
  rm -f "$tmp"
}
