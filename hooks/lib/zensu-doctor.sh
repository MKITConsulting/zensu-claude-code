#!/bin/bash
# zensu-doctor.sh — read-only setup diagnostics for /zensu:doctor.
#
# Probes the local toolchain (zensu CLI + auth, node, the code-forge CLI gh/glab
# resolved from the repo's provider, Playwright) in
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

# forge CLI: resolve the repo's provider (GitHub/GitLab) through the VCS driver's
# PUBLIC --detect subcommand — the same seam autopilot/pr-* drive — so the report
# names the MATCHING CLI (gh/glab) + its auth state instead of hard-probing gh.
# ZENSU_VCS_NO_PROBE=1 keeps this offline: a self-hosted host degrades to the
# CI-file marker, never an outbound HTTP probe (doctor promises no network).
# Guarded so the structure test can inject a fixed provider/CLI/state.
if [ -z "${ZDOC_FORGE_PROVIDER:-}" ] && [ -f "$DIR/zensu-vcs.sh" ]; then
  while IFS='=' read -r _zk _zv; do
    case "$_zk" in
      provider) ZDOC_FORGE_PROVIDER="$_zv" ;;
      edition)  ZDOC_FORGE_EDITION="$_zv" ;;
      cliName)  ZDOC_FORGE_CLI="$_zv" ;;
      cliState) ZDOC_FORGE_STATE="$_zv" ;;
    esac
  done <<EOF
$(ZENSU_VCS_NO_PROBE=1 bash "$DIR/zensu-vcs.sh" --detect --repo "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null)
EOF
fi
export ZDOC_FORGE_PROVIDER="${ZDOC_FORGE_PROVIDER:-}" \
       ZDOC_FORGE_EDITION="${ZDOC_FORGE_EDITION:-}" \
       ZDOC_FORGE_CLI="${ZDOC_FORGE_CLI:-}" \
       ZDOC_FORGE_STATE="${ZDOC_FORGE_STATE:-}"

# Playwright: a PATH binary is a safe signal. Deliberately NOT `npx playwright`
# — even `--no-install` would execute a repo-planted ./node_modules/.bin binary.
if [ -z "${ZDOC_PLAYWRIGHT:-}" ]; then
  if command -v playwright >/dev/null 2>&1; then
    ZDOC_PLAYWRIGHT=present
  else
    ZDOC_PLAYWRIGHT=absent
  fi
fi

export ZDOC_ZENSU ZDOC_NODE ZDOC_PLAYWRIGHT

if ! command -v node >/dev/null 2>&1; then
  printf 'Zensu doctor — read-only setup diagnostics\n\n  %s  node: not found on PATH — cannot run the JSON/config/state checks\n' '⚠️'
  exit 0
fi

node "$DIR/zensu-doctor-report.js" 2>/dev/null || \
  printf '  %s  zensu-doctor: renderer could not run\n' '⚠️'
exit 0
