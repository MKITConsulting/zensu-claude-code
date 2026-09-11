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
# Injectable alongside ZDOC_BINDING, and empty for every verdict except the two
# that have a path to report: orphaned-project-root and
# orphaned-project-root+incompatible-runtime.
ZDOC_BINDING_PROJECT_ROOT="${ZDOC_BINDING_PROJECT_ROOT:-}"
# Same contract for the version pair: empty for every verdict except the three
# that have versions to name — incompatible-runtime, pruned-plugin-root and
# orphaned-project-root+incompatible-runtime.
ZDOC_BINDING_RECORDED_VERSION="${ZDOC_BINDING_RECORDED_VERSION:-}"
ZDOC_BINDING_EXECUTING_VERSION="${ZDOC_BINDING_EXECUTING_VERSION:-}"
# Set only on the incompatible-runtime verdict, and only when the third-fact
# probe could not answer at all. It is the difference between "the recorded root
# is still there" and "nobody could tell", which the row must not blur.
ZDOC_BINDING_ROOT_UNKNOWN="${ZDOC_BINDING_ROOT_UNKNOWN:-}"
ZDOC_BINDING_VERSIONS=""
# ONE implementation of the version-pair probe the binding ladder below runs for
# each named state. The two copies were identical but for the predicate name —
# same subshell, same source guard, same shape guard, same `printf '\t'`
# degradation — roughly fourteen duplicated lines that also added a fifth level of
# `else` nesting. Taking the predicate as an argument lets the ladder be a flat
# loop, which puts the "the order between the two is immaterial" claim into the
# code instead of leaving it in a comment.
#
# The shape guard MUST stay INSIDE this subshell, where the library that owns
# ZENSU_SAFE_VERSION_RE is sourced. The doctor's own shell never sees that
# variable, and under `set -u` referencing it out here aborts the branch and
# silently falls back to the wrong row — the one part of the duplicated block that
# was subtle, and the one an extraction must not lose. A pair failing the shape is
# DROPPED rather than printed: it prints a lone separator, so the caller still
# names the state and the renderer simply omits the two numbers. Losing two
# numbers is a worse message, never a wrong one.
zdoc_version_pair() {  # $1 = model predicate function name
  (
    # shellcheck disable=SC1090
    source "$DIR/zensu-session.sh" >/dev/null 2>&1 || exit 1
    zdoc_pair="$("$1")" || exit 1
    [ -n "$zdoc_pair" ] || exit 1
    zdoc_recorded="${zdoc_pair%%$'\t'*}"
    zdoc_executing="${zdoc_pair##*$'\t'}"
    if [[ "$zdoc_recorded" =~ $ZENSU_SAFE_VERSION_RE ]] \
      && [[ "$zdoc_executing" =~ $ZENSU_SAFE_VERSION_RE ]]; then
      printf '%s\t%s' "$zdoc_recorded" "$zdoc_executing"
    else
      printf '\t'
    fi
  )
}
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
      # The two narrow follow-ups, asked only AFTER the orphan question and never
      # before it. A record can be both orphaned and lineage-incompatible; the
      # vanished root is the heavier diagnosis and the one whose remedy differs,
      # so it wins. Asking in the other order would report a repairable lineage
      # state for a session whose workflow document is already gone.
      #
      # Between THESE two the order is immaterial, and the loop is what says so:
      # the predicates are disjoint by construction — the lineage one needs the
      # strict read to succeed, the pruned one needs it to fail at the plugin root
      # — so at most one can answer. Both render the same pair into the same two
      # variables, because the row that consumes them is one shape with two
      # causes. `unbound` is the default rather than a trailing `else`, so a third
      # named state is one row in this list.
      ZDOC_BINDING=unbound
      for zdoc_named in \
        'incompatible-runtime:zensu_session_incompatible_runtime_model' \
        'pruned-plugin-root:zensu_session_pruned_plugin_root_model'; do
        ZDOC_BINDING_VERSIONS="$(zdoc_version_pair "${zdoc_named#*:}")" \
          || ZDOC_BINDING_VERSIONS=""
        [ -n "$ZDOC_BINDING_VERSIONS" ] || continue
        ZDOC_BINDING="${zdoc_named%%:*}"
        ZDOC_BINDING_RECORDED_VERSION="${ZDOC_BINDING_VERSIONS%%$'\t'*}"
        ZDOC_BINDING_EXECUTING_VERSION="${ZDOC_BINDING_VERSIONS##*$'\t'}"
        break
      done
      # The THIRD probe, layered on top of the loop above rather than folded into
      # it. The loop's two predicates are disjoint and interchangeable; this one is
      # NOT — it refines a verdict the loop has already reached, so it runs only
      # once that verdict is the lineage break, and never on its own.
      if [ "$ZDOC_BINDING" = incompatible-runtime ]; then
        # THIRD narrow question, asked ONLY once the lineage break is
        # established, and never on its own. The orphan question above already
        # answered no for this session — it re-applies servesRecordedRuntime,
        # which an incompatible lineage fails — so a record that is BOTH orphaned
        # and lineage-incompatible would otherwise be reported as a plain lineage
        # break and the user would never learn their project root is gone. That
        # matters after the repair as much as before it: adoption succeeds in this
        # state and leaves the session orphaned, where Edit, Write and any WRITING
        # Bash command still deny — read-only Bash and this diagnostic do run.
        # No shape guard here, matching the orphan branch above: the printed path
        # comes from readOrphanedProjectRootContext, which rejects control
        # characters and a non-absolute value before it returns.
        # `|| exit 1` rather than `&&`, mirroring the versions probe above. Under
        # `&&` a failed source leaves the SOURCE's status in the subshell's exit
        # code, and the ladder below reads every value except 3 as unknown — so a
        # source that happened to exit 3 would clear the unknown flag and let the
        # plain lineage row DROP its hedge, implicitly asserting the recorded
        # project root still exists on evidence nobody produced. That is the exact
        # collapse the block below says it exists to prevent. The library's last
        # statement is `export -f ... || true`, so today a successful source
        # returns 0 and a missing file returns 1; this normalizes the CHANNEL, not
        # a demonstrated 3.
        # The status VOCABULARY is named in zensu-session.sh, and every `source` of that
        # library in this file is inside a command substitution, so the names are not in
        # scope out here — reading one directly under `set -u` aborted the whole
        # diagnostic. Both values are copied out of the owner in ONE subshell rather than
        # re-spelled as literals, which is the point of naming them at all.
        #
        # Each is then SCREENED as a decimal, the same guard ZDOC_TTL_REBOUND gets above.
        # An owner that RETYPED a value — `PRESENT=present` rather than `=3` — passes a
        # bare non-empty test and then reaches `-eq` with a non-numeric operand, which
        # bash reports on a stderr this script does NOT redirect and which the model reads
        # verbatim. Screening turns that into the empty value the fail-safe already
        # handles.
        ZDOC_ROOT_STATE_PAIR="$(
          # shellcheck disable=SC1090
          source "$DIR/zensu-session.sh" >/dev/null 2>&1 \
            && printf '%s\t%s' "${ZENSU_ROOT_STATE_GONE:-}" "${ZENSU_ROOT_STATE_PRESENT:-}"
        )" || ZDOC_ROOT_STATE_PAIR=""
        ZDOC_ROOT_STATE_GONE="${ZDOC_ROOT_STATE_PAIR%%$'\t'*}"
        ZDOC_ROOT_STATE_PRESENT="${ZDOC_ROOT_STATE_PAIR#*$'\t'}"
        case "$ZDOC_ROOT_STATE_GONE" in ''|*[!0-9]*) ZDOC_ROOT_STATE_GONE='' ;; esac
        case "$ZDOC_ROOT_STATE_PRESENT" in ''|*[!0-9]*) ZDOC_ROOT_STATE_PRESENT='' ;; esac
        if ZDOC_BINDING_PROJECT_ROOT="$(
          # shellcheck disable=SC1090
          source "$DIR/zensu-session.sh" >/dev/null 2>&1 || exit 1
          zensu_session_incompatible_orphaned_root_model
        )"; then
          ZDOC_ORPHAN_ROOT_STATUS=0
        else
          ZDOC_ORPHAN_ROOT_STATUS=$?
          ZDOC_BINDING_PROJECT_ROOT=""
        fi
        # The GONE half is guarded exactly like the PRESENT half below, and for the
        # same reason. It shipped as "${ZDOC_ROOT_STATE_GONE:-0}", which defeated both
        # halves of the screen above it: an owner that is unreadable, or whose constant
        # was retyped, yielded the empty string and the default then put the literal 0
        # back — the magic number this pair exists to remove — while still being able to
        # select the row that ASSERTS the recorded project root is gone. Requiring the
        # value instead routes an unresolvable constant to the else arm, which renders
        # the hedged row and sets the unknown flag. That is the fail-safe direction: a
        # missing constant must cost a definite claim, never manufacture one.
        if [ -n "$ZDOC_ROOT_STATE_GONE" ] \
        && [ "$ZDOC_ORPHAN_ROOT_STATUS" -eq "$ZDOC_ROOT_STATE_GONE" ] \
        && [ -n "$ZDOC_BINDING_PROJECT_ROOT" ]; then
        ZDOC_BINDING=orphaned-project-root+incompatible-runtime
        # The probe POSITIVELY answered here, so the unknown flag must not be
        # set: the gone status is not the present one, and an unguarded test would
        # export "unknown"
        # for the one state where the answer is certain. Placing the flag
        # outside this branch is exactly the trap the block below claims to
        # close.
        ZDOC_BINDING_ROOT_UNKNOWN=""
        else
        # WHY the status is captured at all, given both remaining arms render the
        # same verdict: it is what makes the claim CHECKABLE. The PRESENT status positively
        # says the recorded root is still there; every other non-zero says the
        # question could not be answered. The plain `incompatible-runtime` row
        # therefore has to be true in BOTH cases, which is why its body carries
        # the conditional Edit/Write clause rather than an unqualified repair
        # offer — an earlier revision of this block claimed the renderer already
        # did that and it did not. Export the distinction so the row can say so,
        # and so a future arm cannot be added that silently assumes a negative.
        # The status vocabulary is NAMED in zensu-session.sh, and this file only ever
        # sources that library inside a command substitution — every `source` call
        # here is in a subshell — so the name is not in scope out here, and under
        # `set -u` reading it directly aborts the whole diagnostic. Read the VALUE out
        # of the owner instead of re-spelling the literal: that keeps ONE definition,
        # which is the entire point of giving the trichotomy a name.
        #
        # The guard fails SAFE, and the direction is deliberate: a rename or removal
        # in the owner yields an empty string and the flag stays SET, so the row says
        # the question could not be determined. Defaulting to the literal instead
        # would silently restore the magic number this change exists to remove.
        # The `|| ZDOC_BINDING_ROOT_UNKNOWN=1` shape is kept deliberately: AC-C19 counts
        # this exact line, because it sits after a `||` and so no anchored count of the
        # assignments above reaches it — deleting it once left the clause permanently
        # unreachable with every row still green. An `if` block reads more plainly and
        # was tried; it makes that pin count zero, which is the wrong trade.
        ZDOC_BINDING_ROOT_UNKNOWN=""
        [ -n "$ZDOC_ROOT_STATE_PRESENT" ] \
          && [ "$ZDOC_ORPHAN_ROOT_STATUS" -eq "$ZDOC_ROOT_STATE_PRESENT" ] \
          || ZDOC_BINDING_ROOT_UNKNOWN=1
        fi
      fi
    fi
  fi
fi

ZDOC_VERIFY_REASON="${ZDOC_VERIFY_REASON:-}"
if [ -z "${ZDOC_VERIFY:-}" ]; then
  ZDOC_VERIFY_REASON=""
  ZDOC_VERIFY_RECIPE_ROOT="${ZDOC_SESSION_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-}}"
  if [ -n "${ZENSU_VERIFY_NAVIGATION_POLICY_V1:-}" ]; then
    # Presence is not validity: the broker parses this value at start and REFUSES to
    # serve when it does not satisfy the contract, so a doctor claiming an active policy
    # from the variable alone reports green for a session whose browser cannot start.
    # The three TOP-LEVEL guards are CALLED, not copied: verify-navigation-floor-v1.js owns
    # policyContractFault and the consent gate calls the same function, so the doctor and the
    # gate cannot drift about what a usable policy is. The per-target rules stay parsePolicy's
    # alone, which is what keeps this synchronous — those are the ones that resolve DNS for a
    # remote origin, and a stubbed refusing resolver would report a VALID remote policy as
    # invalid, the one verdict a diagnostic must never invent. A module that will not load
    # answers "could not be judged" rather than green: the row says what it checked, and a
    # green row means the top-level contract holds, never that the broker will serve.
    ZDOC_VERIFY_POLICY_FAULT="$(ZDOC_FLOOR="$ZDOC_ROOT/hooks/lib/verify-navigation-floor-v1.js" node -e '
      const floor = require(process.env.ZDOC_FLOOR);
      const fault = floor.policyContractFault(process.env.ZENSU_VERIFY_NAVIGATION_POLICY_V1 || "");
      if (typeof fault !== "string") process.exit(1);
      process.stdout.write(fault);
    ' 2>/dev/null)" || ZDOC_VERIFY_POLICY_FAULT="policy could not be judged"
    if [ -n "$ZDOC_VERIFY_POLICY_FAULT" ]; then
      ZDOC_VERIFY=policy-invalid
      ZDOC_VERIFY_REASON="$ZDOC_VERIFY_POLICY_FAULT"
    else
      ZDOC_VERIFY=policy
    fi
  elif [ ! -f "$ZDOC_ROOT/scripts/playwright-mcp-proxy.js" ] || [ -L "$ZDOC_ROOT/scripts/playwright-mcp-proxy.js" ]; then
    ZDOC_VERIFY=unavailable
    ZDOC_VERIFY_REASON="broker script missing"
  elif [ ! -f "$ZDOC_ROOT/hooks/pre-browser-navigation-consent.sh" ] \
    || [ ! -f "$ZDOC_ROOT/hooks/post-browser-navigation-consent.sh" ] \
    || [ ! -f "$ZDOC_ROOT/hooks/lib/verify-consent-v1.js" ]; then
    ZDOC_VERIFY=unavailable
    ZDOC_VERIFY_REASON="consent hook pair or its module missing from the plugin"
  elif ! (cd -P -- "$ZDOC_ROOT" && node -e '
      const p = require("./scripts/playwright-mcp-proxy.js");
      process.exit(p.consentHookRegistered(process.cwd()) ? 0 : 1);
    ' >/dev/null 2>&1); then
    ZDOC_VERIFY=unavailable
    ZDOC_VERIFY_REASON="consent hook not registered on the navigation matcher"
  elif ! (cd -P -- "$ZDOC_ROOT" && node -e '
      const p = require("./scripts/playwright-mcp-proxy.js");
      process.exit(p.consentRecorderRegistered(process.cwd()) ? 0 : 1);
    ' >/dev/null 2>&1); then
    # The broker starts in consent mode on the GATE alone, so this half fails silently: every
    # navigation would prompt and none would ever be remembered. Reported rather than absorbed.
    ZDOC_VERIFY=unavailable
    ZDOC_VERIFY_REASON="consent recorder not registered on the navigation matcher"
  elif [ -z "$ZDOC_VERIFY_RECIPE_ROOT" ]; then
    # No project root resolved, so no recipe was looked for. Saying "no runtime recipe" here
    # would report a finding about a directory this run never opened.
    ZDOC_VERIFY=consent-recipe-unchecked
  elif (cd -P -- "$ZDOC_ROOT" && ZDOC_VERIFY_RECIPE_ROOT="$ZDOC_VERIFY_RECIPE_ROOT" node -e '
      const mod = require("./hooks/lib/verify-consent-v1.js");
      process.exit(mod.resolveRecipeFile(process.env.ZDOC_VERIFY_RECIPE_ROOT) ? 0 : 1);
    ' >/dev/null 2>&1); then
    ZDOC_VERIFY=consent
  else
    ZDOC_VERIFY=consent-no-recipe
  fi
fi

# AC-104: the row above reports REGISTRATION — it is derived from files on disk in the plugin's
# own tree and says nothing about whether the hook ran. This second state reports EXECUTION,
# read from the per-session marker the gate writes on every decided loopback navigation. It is
# derived only for the consent states: in policy mode consent mode is never entered, and under
# `unavailable` the row above is already red.
ZDOC_VERIFY_EXEC="${ZDOC_VERIFY_EXEC:-}"
if [ -z "$ZDOC_VERIFY_EXEC" ]; then
  case "${ZDOC_VERIFY:-}" in
    (consent|consent-no-recipe|consent-recipe-unchecked)
      if [ -z "${ZDOC_SESSION_KEY:-}" ] || [ -z "${ZDOC_SESSION_PROJECT_ROOT:-}" ]; then
        # No bound key or no recorded root: the marker is session-keyed, so the question could
        # not be asked. Saying "not exercised" here would report a finding about a file this
        # run never looked for.
        ZDOC_VERIFY_EXEC=unknown
      else
        # The STATUS is captured rather than reduced to success/failure by an `elif`. A missing
        # export, a module that will not load and a directory that cannot be read are contract
        # faults, and collapsing them into the benign state made the report render a green row
        # --- verify-feature gate EXECUTION probe -------------------------------------------
        # The verdict travels as a WORD the decision module produced, never as an exit status this
        # shell re-interprets. A status ladder put the answer on the same channel as every way a
        # process can die: the benign verdict shared 1 with node's generic fatal and with a failed
        # `cd`, and moving it to another small integer only traded one collision for another. The
        # classification itself belongs to the module — this probe used to spell its own, deciding
        # the same rules the broker's classifier already owns, with nothing comparing the two.
        ZDOC_VERIFY_WORD="$(cd -P -- "$ZDOC_ROOT" 2>/dev/null || exit 0
          ZDOC_VERIFY_ROOT="$ZDOC_SESSION_PROJECT_ROOT" ZDOC_VERIFY_KEY="$ZDOC_SESSION_KEY" node -e '
            try {
              const fs = require("node:fs");
              // The SAME load guard the gate and the broker apply. This probe is the third
              // consumer of the decision module and used a bare require: with a symlinked module
              // the gate denies every navigation while both verify rows render green for the
              // remaining life of an older marker.
              const info = fs.lstatSync("./hooks/lib/verify-consent-v1.js");
              if (!info.isFile() || info.isSymbolicLink()) process.exit(0);
              const mod = require("./hooks/lib/verify-consent-v1.js");
              if (typeof mod.classifyExecution !== "function"
                || typeof mod.executionEvidenceSeen !== "function"
                || typeof mod.evidenceDirFor !== "function") process.exit(0);
              // Canonicalized ONCE here: the reader compares its own realpath of the root
              // against the directory it was handed, so a spelling that is not already a
              // realpath fixed point made the two disagree and reported a working check as
              // a contract fault.
              const root = fs.realpathSync.native(process.env.ZDOC_VERIFY_ROOT || "");
              const seen = mod.executionEvidenceSeen(mod.evidenceDirFor(root), {
                projectRoot: root,
                sessionKey: process.env.ZDOC_VERIFY_KEY || "",
              });
              process.stdout.write(String(mod.classifyExecution(seen)));
            } catch (_error) {
              // Silence, which the shell reads as the could-not-judge residual.
            }
          ' 2>/dev/null)"
        case "$ZDOC_VERIFY_WORD" in
          (ran|ran-asked|none) ZDOC_VERIFY_EXEC="$ZDOC_VERIFY_WORD" ;;
          (*) ZDOC_VERIFY_EXEC=unjudged ;;
        esac
      fi
      ;;
    (*) ZDOC_VERIFY_EXEC="" ;;
  esac
fi

export ZDOC_ZENSU ZDOC_NODE ZDOC_PLAYWRIGHT ZDOC_BINDING ZDOC_BINDING_PROJECT_ROOT \
  ZDOC_BINDING_RECORDED_VERSION ZDOC_BINDING_EXECUTING_VERSION \
  ZDOC_BINDING_ROOT_UNKNOWN \
  ZDOC_SESSION_KEY ZDOC_SESSION_PROJECT_ROOT ZDOC_VERIFY ZDOC_VERIFY_REASON ZDOC_VERIFY_EXEC

if ! command -v node >/dev/null 2>&1; then
  printf 'Zensu doctor — read-only setup diagnostics\n\n  %s  node: not found on PATH — cannot run the JSON/config/state checks\n' '⚠️'
  exit 0
fi

(cd -P -- "$DIR" && node ./zensu-doctor-report.js) 2>/dev/null || \
  printf '  %s  zensu-doctor: renderer could not run\n' '⚠️'
exit 0
