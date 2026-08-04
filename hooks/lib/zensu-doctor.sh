#!/bin/bash
# zensu-doctor.sh — read-only setup diagnostics for /zensu:doctor.
#
# Probes the local toolchain (zensu CLI + auth, node, the code-forge CLI gh/glab
# resolved from the repo's provider, and Playwright MCP) in
# the shell — `command -v` and auth-status exit codes are a shell concern — then
# hands the results to zensu-doctor-report.js (env ZDOC_*), which reads the
# plugin manifest/hooks, the effective config, and the session state dir and
# renders a four-block ✅/⚠️/❌ table. NOTHING here writes; the script always
# exits 0 (a probe that errors degrades to a warning row, never a failure).
#
# Every ZDOC_* is set with `:=` so a caller (the structure test, or /zensu:doctor
# after observing loaded MCP tools) can inject a fixed toolchain verdict; real
# probing only fills the gaps left unset.
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

# Playwright: validate the plugin's lockfile-backed MCP declaration without executing it.
# Doctor stays read-only/offline, so a valid declaration + npm can prove only
# "configured", not that Claude loaded the MCP server or that npm can install
# the integrity-locked package graph. A PATH binary is a separate project-driver signal and is
# never sufficient for /zensu:verify-feature.
playwright_mcp_declared() {
  local probe_root mcp_file plugin_file package_file lock_file launcher proxy
  probe_root="${ZENSU_DOCTOR_PLUGIN_DIR:-$DIR/../..}"
  mcp_file="$probe_root/.mcp.json"
  plugin_file="$probe_root/.claude-plugin/plugin.json"
  package_file="$probe_root/mcp-runtime/package.json"
  lock_file="$probe_root/mcp-runtime/package-lock.json"
  launcher="$probe_root/scripts/playwright-mcp.sh"
  proxy="$probe_root/scripts/playwright-mcp-proxy.js"
  [ -f "$mcp_file" ] && [ -f "$plugin_file" ] && [ -f "$package_file" ] \
    && [ -f "$lock_file" ] && [ -x "$launcher" ] && [ -f "$proxy" ] \
    && command -v node >/dev/null 2>&1 || return 1
  (
    cd -P -- "$probe_root" || return 1
    node -e '
    const fs = require("fs");
    const mcp = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const plugin = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    const pkg = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
    const lock = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
    const proxy = require(process.argv[5]);
    const expectedTools = [
      "browser_click", "browser_close", "browser_console_messages",
      "browser_drag", "browser_fill_form", "browser_handle_dialog", "browser_hover",
      "browser_navigate", "browser_network_requests", "browser_press_key", "browser_resize",
      "browser_select_option", "browser_snapshot", "browser_tabs", "browser_take_screenshot",
      "browser_type", "browser_wait_for"
    ];
    const server = mcp && mcp.mcpServers && mcp.mcpServers.playwright;
    const args = server && Array.isArray(server.args) ? server.args : [];
    const locked = lock && lock.packages && lock.packages["node_modules/@playwright/mcp"];
    if (!server || server.type !== "stdio" ||
        server.command !== "${CLAUDE_PLUGIN_ROOT}/scripts/playwright-mcp.sh" ||
        pkg.dependencies?.["@playwright/mcp"] !== "0.0.75" ||
        !locked || locked.version !== "0.0.75" || !/^sha512-/.test(locked.integrity || "") ||
        !args.includes("--isolated") || args.includes("--caps=storage") ||
        JSON.stringify(proxy.ALLOWED_TOOLS) !== JSON.stringify(expectedTools) ||
        plugin.mcpServers !== "./.mcp.json") process.exit(1);
  ' ./.mcp.json ./.claude-plugin/plugin.json ./mcp-runtime/package.json \
    ./mcp-runtime/package-lock.json ./scripts/playwright-mcp-proxy.js >/dev/null 2>&1
  )
}

if [ -z "${ZDOC_PLAYWRIGHT:-}" ]; then
  if playwright_mcp_declared; then
    if [ "${ZDOC_PLAYWRIGHT_TOOLS:-}" = ready ]; then
      ZDOC_PLAYWRIGHT=ready
    elif command -v npm >/dev/null 2>&1; then
      ZDOC_PLAYWRIGHT=configured
    else
      ZDOC_PLAYWRIGHT=declared
    fi
  elif command -v playwright >/dev/null 2>&1; then
    ZDOC_PLAYWRIGHT=present
  else
    ZDOC_PLAYWRIGHT=absent
  fi
fi

if [ -z "${ZDOC_SESSION_KEY:-}" ] && [ -f "$DIR/zensu-session.sh" ]; then
  # shellcheck source=/dev/null
  . "$DIR/zensu-session.sh" 2>/dev/null || true
  if command -v zensu_resolve_session_id >/dev/null 2>&1; then
    ZDOC_SESSION_KEY="$(zensu_resolve_session_id 2>/dev/null)" || ZDOC_SESSION_KEY=""
  fi
fi
export ZDOC_SESSION_KEY="${ZDOC_SESSION_KEY:-}"

export ZDOC_ZENSU ZDOC_NODE ZDOC_PLAYWRIGHT

if ! command -v node >/dev/null 2>&1; then
  printf 'Zensu doctor — read-only setup diagnostics\n\n  %s  node: not found on PATH — cannot run the JSON/config/state checks\n' '⚠️'
  exit 0
fi

(cd -P -- "$DIR" && node ./zensu-doctor-report.js) 2>/dev/null || \
  printf '  %s  zensu-doctor: renderer could not run\n' '⚠️'
exit 0
