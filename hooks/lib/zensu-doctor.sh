#!/bin/bash
# zensu-doctor.sh — read-only setup diagnostics for /zensu:doctor.
#
# Probes the local toolchain (zensu CLI + auth, node, gh + auth, Playwright) in
# the shell — `command -v` and auth-status exit codes are a shell concern — then
# hands the results to zensu-doctor-report.js (env ZDOC_*), which reads the
# plugin manifest/hooks, the effective config, and the session state dir and
# renders a four-block ✅/⚠️/❌ table. NOTHING here writes; the script always
# exits 0 (a probe that errors degrades to a warning row, never a failure).
#
# Every ZDOC_* is set with `:=` so a caller (the structure test) can inject a
# fixed toolchain verdict; real probing only fills the gaps left unset.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve the pending-review TTL through the CANONICAL getter the Stop enforcer
# uses, so the doctor never reports a TTL the real hooks would disagree with.
if [ -z "${ZDOC_TTL_HOURS:-}" ] && [ -f "$DIR/zensu-config.sh" ]; then
  # shellcheck source=/dev/null
  . "$DIR/zensu-config.sh" 2>/dev/null || true
  if command -v zensu_pending_review_ttl_hours >/dev/null 2>&1; then
    ZDOC_TTL_HOURS="$(zensu_pending_review_ttl_hours 2>/dev/null)"
  fi
fi
export ZDOC_TTL_HOURS

# zensu CLI: installed? authenticated? (auth probe is best-effort + quiet)
if [ -z "${ZDOC_ZENSU:-}" ]; then
  if command -v zensu >/dev/null 2>&1; then
    if zensu auth status >/dev/null 2>&1; then ZDOC_ZENSU=authed; else ZDOC_ZENSU=present; fi
  else
    ZDOC_ZENSU=absent
  fi
fi

# node: version string (empty when absent)
if [ -z "${ZDOC_NODE:-}" ]; then
  if command -v node >/dev/null 2>&1; then ZDOC_NODE="$(node --version 2>/dev/null)"; else ZDOC_NODE=""; fi
fi

# gh: installed? authenticated?
if [ -z "${ZDOC_GH:-}" ]; then
  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then ZDOC_GH=authed; else ZDOC_GH=present; fi
  else
    ZDOC_GH=absent
  fi
fi

# Playwright: a resolvable binary is enough of a signal (no network install)
if [ -z "${ZDOC_PLAYWRIGHT:-}" ]; then
  if command -v playwright >/dev/null 2>&1 || npx --no-install playwright --version >/dev/null 2>&1; then
    ZDOC_PLAYWRIGHT=present
  else
    ZDOC_PLAYWRIGHT=absent
  fi
fi

export ZDOC_ZENSU ZDOC_NODE ZDOC_GH ZDOC_PLAYWRIGHT

if ! command -v node >/dev/null 2>&1; then
  printf 'Zensu doctor — read-only setup diagnostics\n\n  %s  node: not found on PATH — cannot run the JSON/config/state checks\n' '⚠️'
  exit 0
fi

node "$DIR/zensu-doctor-report.js" 2>/dev/null || \
  printf '  %s  zensu-doctor: renderer could not run\n' '⚠️'
exit 0
