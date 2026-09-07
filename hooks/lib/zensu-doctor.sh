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
# probing only fills the gaps left unset. That claim scopes to the EXPORTED inputs
# the renderer reads, not to derived locals such as ZDOC_ROOT or ZDOC_SESSION_PAIR.
# Two of the exported ones are exceptions, and they are exceptions
# on purpose: ZDOC_SESSION_KEY and ZDOC_SESSION_PROJECT_ROOT are cleared
# unconditionally rather than seeded, because their meaning depends on a verdict
# reached further down and an inherited value would survive the branches that
# never reach the bind. See the comment at their assignment.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"

# Root preflight, moved here from skills/doctor/SKILL.md Phase 1. It used to be a
# compound if/elif block in the skill, which meant the diagnostic reached Bash as
# a multi-command script — and nothing that shape-heavy can be admitted by the
# allowlist in zensu-doctor-invocation.js that keeps /zensu:doctor reachable when
# the session binding has failed. Living here, the skill emits ONE command.
#
# The skill keeps a prose fallback for the case this script cannot be started at
# all; a guard inside a file that never ran cannot print anything. Exits 0 like
# every other path here: a red row is a finding, not a failure.
ZDOC_ROOT="${DIR%/hooks/lib}"
if [ -z "$DIR" ] || [ "$ZDOC_ROOT" = "$DIR" ] || [ -L "$ZDOC_ROOT" ] || [ ! -d "$ZDOC_ROOT" ] \
  || [ -L "$DIR/zensu-doctor.sh" ] || [ ! -f "$DIR/zensu-doctor.sh" ]; then
  printf '%s\n' \
    'Zensu doctor — read-only setup diagnostics' '' 'Plugin integrity' \
    '  ❌  Session Control: plugin root unavailable or invalid — start a fresh Claude Code session' \
    '' 'Summary: 1 ❌  0 ⚠️  — resolve the ❌ items first.'
  exit 0
fi

# ONE source per run, for BOTH canonical getters below. There were two — one
# inside each resolve block — and in an ordinary invocation neither ZDOC_ variable
# is pre-set, so both guards passed and the library was sourced twice. That was
# shipped while the round-3 plan recorded the single-source requirement as met,
# which is why the count is now pinned (C33) rather than left to reading.
# The condition is deliberately the DISJUNCTION of the two resolve guards: a
# caller that pins both values still sources nothing, and a caller that pins one
# sources once. Hoisting it unconditionally would put a source on a path that
# needs no getter at all.
if { [ -z "${ZDOC_TTL_HOURS:-}" ] || [ -z "${ZDOC_IMPL_STOP_NUDGE_AFTER:-}" ]; } \
  && [ -f "$DIR/zensu-config.sh" ]; then
  # shellcheck source=/dev/null
  . "$DIR/zensu-config.sh" 2>/dev/null || true
fi

# Resolve the pending-review TTL through the CANONICAL getter the Stop enforcer
# uses, so the doctor never reports a TTL the real hooks would disagree with.
# This runs BEFORE the session bind, so it necessarily reads the config overlay
# under CLAUDE_PROJECT_DIR; the bind block below re-resolves it from the record
# root when the two differ. Remember whether the caller pinned it, because that
# choice must survive the re-resolution.
ZDOC_TTL_PINNED=""
[ -n "${ZDOC_TTL_HOURS:-}" ] && ZDOC_TTL_PINNED=1
if [ -z "${ZDOC_TTL_HOURS:-}" ]; then
  if command -v zensu_pending_review_ttl_hours >/dev/null 2>&1; then
    ZDOC_TTL_HOURS="$(zensu_pending_review_ttl_hours 2>/dev/null)"
  fi
fi
export ZDOC_TTL_HOURS

# Same canonical-getter rule as the TTL above, and the same known bound: this
# runs before the session bind, so where the record root and CLAUDE_PROJECT_DIR
# differ it reads the overlay under the latter. Deliberately NOT re-resolved
# after the bind, and the cost is stated rather than glossed: a stale value
# changes which chains the implementing-turns row names, and a stale `0`
# withholds that row entirely — the renderer treats 0 as "switched off" and says
# so in its own row rather than falling silent.
if [ -z "${ZDOC_IMPL_STOP_NUDGE_AFTER:-}" ]; then
  if command -v zensu_impl_stop_nudge_after >/dev/null 2>&1; then
    ZDOC_IMPL_STOP_NUDGE_AFTER="$(zensu_impl_stop_nudge_after 2>/dev/null)"
  fi
fi
export ZDOC_IMPL_STOP_NUDGE_AFTER

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

# The PreToolUse denial that every stateful helper renders when Session Control
# cannot bind points the user here, so reproduce that exact binding attempt.
# It needs the two inputs the model-side path needs; without them this stays
# `unknown` and the renderer prints nothing rather than a guess.
# Injectable alongside ZDOC_BINDING, and empty for every verdict except
# orphaned-project-root, which is the only one that has a path to report.
ZDOC_BINDING_PROJECT_ROOT="${ZDOC_BINDING_PROJECT_ROOT:-}"
# Same contract for the version pair: empty for every verdict except
# incompatible-runtime, the only one that has two versions to name.
ZDOC_BINDING_RECORDED_VERSION="${ZDOC_BINDING_RECORDED_VERSION:-}"
ZDOC_BINDING_EXECUTING_VERSION="${ZDOC_BINDING_EXECUTING_VERSION:-}"
ZDOC_BINDING_VERSIONS=""
# The session's own key and the RECORD's own project anchor, so the renderer can
# tell a chain THIS session owns from one it does not, and can refuse the
# comparison when the record and the caller disagree about which project it is.
# The bind already computes both and the branch below discarded them, so nothing
# new is resolved here.
#
# Deliberately NOT `:=`-seeded, unlike every other ZDOC_* in this file. These two
# are the only ones whose meaning depends on a verdict reached further down, and
# "empty for every verdict except bound" has to be TRUE rather than merely
# stated: an inherited value would otherwise survive the unknown and unavailable
# branches, which set a verdict and never reach the bind. The renderer enforces
# the same invariant from its side (it requires ZDOC_BINDING=bound), because a
# caller who supplies ZDOC_BINDING skips this whole block.
ZDOC_SESSION_KEY=""
ZDOC_SESSION_PROJECT_ROOT=""
if [ -z "${ZDOC_BINDING:-}" ]; then
  if [ -z "${CLAUDE_CODE_SESSION_ID:-}" ] || [ -z "${CLAUDE_PLUGIN_DATA:-}" ]; then
    ZDOC_BINDING=unknown
  elif [ -L "$DIR/zensu-session.sh" ] || [ ! -f "$DIR/zensu-session.sh" ]; then
    ZDOC_BINDING=unavailable
  # The status of an assignment whose value is a command substitution IS that
  # substitution status, so the branch is still decided exactly as the bare
  # subshell decided it: a bind failure exits non-zero and the orphan /
  # incompatible-runtime follow-ups below run unchanged. What is new is that the
  # two values the bind already computed are reached out instead of discarded.
  #
  # The shape guard runs INSIDE the subshell that sourced the library, for the
  # reason ZDOC_BINDING_VERSIONS gives: the value is rendered into the terminal
  # and into the model context, so one failing the shape is DROPPED rather than
  # printed. The bind succeeded either way, so the verdict stays bound while the
  # pair stays empty. Losing them costs the foreign-chain row AND reverts the
  # whole Session state block to CLAUDE_PROJECT_DIR, which is the directory no
  # writer uses whenever the two roots differ; the renderer discloses both with
  # their own WARN rows rather than rendering as health. Printing a bad one is
  # still worse than losing them.
  # Both travel on ONE line as `key<TAB>root` so a single substitution decides
  # the branch; a partial pair is dropped whole for the same reason. The root is
  # refused for ANY control byte, not just the separator: it is printed into the
  # report and the doctor skill feeds that exact path to `rm`, which is the policy
  # session-control-core-v1.js already applies to the same field for the same sink.
  # A SYMLINKED root is refused too, matching zensu_resolve_project_dir, which is
  # the authority every writer resolves through: it fails such a root outright, so
  # accepting one here would report on a tree no writer can reach.
  #
  # TWO bash 3.2 traps apply INSIDE the substitution below, and they are ONE
  # defect seen twice: that release extracts a $( ) body with a naive scanner
  # that tracks quotes and parens instead of parsing it, so any token the scanner
  # miscounts ends the substitution early. macOS ships 3.2 as /bin/bash, so this
  # is the default shell here rather than an edge case.
  #
  # 1. An apostrophe in a comment opens a quote state the scanner never closes,
  #    and the file then fails to parse entirely rather than at that line.
  #    Ordinary comments are fine, which is why the shellcheck directive stays.
  # 2. A case arm in the bare `pattern)` form supplies an unbalanced `)` that
  #    CLOSES the substitution at that character. Write every case pattern in
  #    here with the POSIX-optional leading paren — `(pattern)` — which balances
  #    the scanner and parses identically on bash 5.
  #
  # Trap 2 shipped in 0.20.0 and its cost was the whole binding verdict, not a
  # cosmetic one. Measured on 3.2.57 against a genuinely bound session: the body
  # truncates mid-`case`, the subshell dies of a syntax error, the assignment
  # returns 1, this elif falls to the else branch, neither follow-up question
  # matches, and the report renders `unbound` — telling the user to start a fresh
  # session over a record that is present, readable and already bound. Note the
  # ORDER that hid it: 3.2 executes the body command by command, so the bind runs
  # and SUCCEEDS before the malformed `case` is ever reached. The record was never
  # the problem, only the reporting of it, which is why every other component
  # disagreed with this row. tests/structure/test-bash32-portability.sh pins the
  # rule tree-wide.
  elif ZDOC_SESSION_PAIR="$(
    # shellcheck disable=SC1090
    # no apostrophes in comments, no bare case pattern: bash 3.2, see above
    source "$DIR/zensu-session.sh" >/dev/null 2>&1 || exit 1
    zensu_bind_model_session >/dev/null 2>&1 || exit 1
    [[ "${ZENSU_SESSION_KEY:-}" =~ ^scv1_[a-f0-9]{64}$ ]] || exit 0
    [ -n "${ZENSU_PROJECT_ROOT:-}" ] || exit 0
    [ ! -L "${ZENSU_PROJECT_ROOT:-}" ] || exit 0
    [ -d "${ZENSU_PROJECT_ROOT:-}" ] || exit 0
    case "${ZENSU_PROJECT_ROOT:-}" in (*[[:cntrl:]]*) exit 0 ;; esac
    printf '%s\t%s' "${ZENSU_SESSION_KEY:-}" "${ZENSU_PROJECT_ROOT:-}"
  )"; then
    ZDOC_BINDING=bound
    if [ -n "$ZDOC_SESSION_PAIR" ]; then
      ZDOC_SESSION_KEY="${ZDOC_SESSION_PAIR%%$'\t'*}"
      ZDOC_SESSION_PROJECT_ROOT="${ZDOC_SESSION_PAIR#*$'\t'}"
      # The TTL is resolved far above this block, where the parent shell does not
      # yet hold the record root, so it came from the config overlay under
      # CLAUDE_PROJECT_DIR. The Session state block now reads the RECORD root, so
      # where the two differ that TTL judged one tree and governed rows about
      # another — including the pending-review row, whose verdict becomes a
      # deletion offer. Re-resolve from the tree that is actually scanned. A TTL
      # the caller pinned explicitly is never overridden.
      if [ -z "${ZDOC_TTL_PINNED:-}" ] \
        && [ "$ZDOC_SESSION_PROJECT_ROOT" != "${CLAUDE_PROJECT_DIR:-}" ] \
        && command -v zensu_pending_review_ttl_hours >/dev/null 2>&1; then
        ZDOC_TTL_REBOUND="$(
          CLAUDE_PROJECT_DIR="$ZDOC_SESSION_PROJECT_ROOT" \
            zensu_pending_review_ttl_hours 2>/dev/null
        )"
        case "$ZDOC_TTL_REBOUND" in
          ''|*[!0-9]*) ;;
          *) ZDOC_TTL_HOURS="$ZDOC_TTL_REBOUND"; export ZDOC_TTL_HOURS ;;
        esac
        unset ZDOC_TTL_REBOUND
      fi
    fi
  else
    # An unbound session is not one state. Ask the one narrow follow-up question
    # that has its own remedy: is there a valid record whose recorded project
    # root is simply gone? That session reaches this diagnostic precisely
    # because the Bash gate relaxes it, so answering "no record" would be the
    # one wrong thing to tell the user standing in front of it.
    ZDOC_BINDING_PROJECT_ROOT="$(
      # shellcheck disable=SC1090
      source "$DIR/zensu-session.sh" >/dev/null 2>&1 \
        && zensu_session_orphaned_project_root_model
    )" || ZDOC_BINDING_PROJECT_ROOT=""
    if [ -n "$ZDOC_BINDING_PROJECT_ROOT" ]; then
      ZDOC_BINDING=orphaned-project-root
    else
      # The SECOND narrow follow-up, asked only after the orphan question and
      # never before it. A record can be both orphaned and lineage-incompatible;
      # the vanished root is the heavier diagnosis and the one whose remedy is
      # different, so it wins. Asking in the other order would report a repairable
      # lineage state for a session whose workflow document is already gone.
      # The shape guard runs INSIDE this subshell, where the library that owns
      # ZENSU_SAFE_VERSION_RE is sourced — the doctor's own shell never sees that
      # variable, and under `set -u` referencing it out here aborts the branch and
      # silently falls back to the wrong row. Same guard the deny path applies,
      # and for the same reason: a manifest version is validated only by
      # requireText, and this pair is rendered verbatim into the terminal and into
      # the model's context by the doctor skill. A pair that fails the shape is
      # dropped, not printed — losing two numbers is a worse message, never a
      # wrong one, and the row still names the state.
      ZDOC_BINDING_VERSIONS="$(
        # shellcheck disable=SC1090
        source "$DIR/zensu-session.sh" >/dev/null 2>&1 || exit 1
        zdoc_pair="$(zensu_session_incompatible_runtime_model)" || exit 1
        [ -n "$zdoc_pair" ] || exit 1
        zdoc_recorded="${zdoc_pair%%$'\t'*}"
        zdoc_executing="${zdoc_pair##*$'\t'}"
        if [[ "$zdoc_recorded" =~ $ZENSU_SAFE_VERSION_RE ]] \
          && [[ "$zdoc_executing" =~ $ZENSU_SAFE_VERSION_RE ]]; then
          printf '%s\t%s' "$zdoc_recorded" "$zdoc_executing"
        else
          printf '\t'
        fi
      )" || ZDOC_BINDING_VERSIONS=""
      if [ -n "$ZDOC_BINDING_VERSIONS" ]; then
        ZDOC_BINDING=incompatible-runtime
        ZDOC_BINDING_RECORDED_VERSION="${ZDOC_BINDING_VERSIONS%%$'\t'*}"
        ZDOC_BINDING_EXECUTING_VERSION="${ZDOC_BINDING_VERSIONS##*$'\t'}"
      else
        ZDOC_BINDING=unbound
      fi
    fi
  fi
fi

export ZDOC_ZENSU ZDOC_NODE ZDOC_PLAYWRIGHT ZDOC_BINDING ZDOC_BINDING_PROJECT_ROOT \
  ZDOC_BINDING_RECORDED_VERSION ZDOC_BINDING_EXECUTING_VERSION \
  ZDOC_SESSION_KEY ZDOC_SESSION_PROJECT_ROOT

if ! command -v node >/dev/null 2>&1; then
  printf 'Zensu doctor — read-only setup diagnostics\n\n  %s  node: not found on PATH — cannot run the JSON/config/state checks\n' '⚠️'
  exit 0
fi

(cd -P -- "$DIR" && node ./zensu-doctor-report.js) 2>/dev/null || \
  printf '  %s  zensu-doctor: renderer could not run\n' '⚠️'
exit 0
