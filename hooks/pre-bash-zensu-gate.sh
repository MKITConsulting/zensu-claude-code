#!/bin/bash
# pre-bash-zensu-gate.sh — PreToolUse(Bash) write-gate for the typed `zensu` CLI.
#
# Re-home of pre-mcp-zensu-gate.sh: same decision order, new trigger surface.
# Instead of intercepting `mcp__plugin_zensu_zensu__*` tool calls, it parses the
# Bash command for `zensu <noun> <verb>`
# invocations, maps each to its canonical tool name (hooks/lib/zensu-cli-map.sh),
# and classifies it through the same SoT (hooks/lib/zensu-mcp-tools.sh). Reads
# and unknown subcommands pass; a mutation run freelance on the main thread is
# DENIED unless a Zensu skill workflow declared it active.
#
# Scoped to its actual threat model — a low-context agent writing to the real
# tracked product — so it deliberately does NOT fire on: reads and `--help`/`-h`
# (how an agent *gains* the context the gate wants), the explicit per-command
# `ZENSU_MCP_GATE=off` prefix of a main-thread command, or a write whose target backend
# (`--api-url` flag / `ZENSU_API_URL` env) is localhost — a throwaway dev/test DB
# where the dedup/journey/classification conventions are meaningless.
#
# This is a convention-nudge, not an airtight boundary: once the CLI's OAuth
# token is cached on disk an agent can curl the API directly. The gate enforces
# the Zensu workflow conventions (dedup, journeys, baseline revisions, security
# classification, release-readiness), not a security control — same role, and
# same `ZENSU_MCP_GATE=off` / `hooks.mcpGate:false` escape, as the MCP gate it
# replaces (the env/config knob name is kept for backward compatibility).
set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 2
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _ZENSU_DECLARED_PLUGIN_ROOT="$(cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || {
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  }
  if [ "$_ZENSU_DECLARED_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  fi
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT _ZENSU_DECLARED_PLUGIN_ROOT

command -v node >/dev/null 2>&1 || exit 0

{ INPUT="$(cat 2>/dev/null || true)"; } 2>/dev/null

# Parse the Bash command into zensu invocations. Emits one line per invocation,
# tab-separated "<noun>\t<verb>\t<third word>". Emits nothing — so the
# gate is a no-op — when the command runs no `zensu` CLI binary. Anchoring on the
# known noun set makes flag values (e.g. an --api-url argument) immune to being
# misread as a subcommand, and basename=="zensu" keeps `bash .../zensu-log.sh`
# and `.zensu/...` paths from ever matching.
INVOCATIONS="$(if cd -P -- "${CLAUDE_PLUGIN_ROOT}/hooks/lib" 2>/dev/null; then ZPS=./powershell-command-v1.js; else ZPS=; fi; printf '%s' "$INPUT" | ZPS="$ZPS" ZAPI="${ZENSU_API_URL:-}" ZGUARD="${CLAUDE_PLUGIN_ROOT}/hooks/lib/subagent-shell-guard-v1.js" ZBIND="${CLAUDE_PLUGIN_ROOT}/hooks/lib/claude-hook-session-v1.js" node -e '
  let cmd = "", sub = false, ps = false, size = 0;
  try {
    const raw = require("fs").readFileSync(0);
    size = raw.length;
    const j = JSON.parse(raw.toString("utf8") || "{}");
    if (j.tool_input && typeof j.tool_input.command === "string") cmd = j.tool_input.command;
    sub = [j.agent_id, j.agent_type].some((v) => typeof v === "string" && v !== "");
    ps = j.tool_name === "PowerShell";
  } catch (_) { process.exit(0); }
  if (!cmd || (!ps && !/(?:^|[^A-Za-z0-9_.-])zensu(?![A-Za-z0-9_-])/.test(cmd))) process.exit(0);
  let cap = 0;
  try { cap = require(process.env.ZBIND).MAX_PAYLOAD_BYTES; } catch (_) {}
  if (!ps && Number.isSafeInteger(cap) && cap > 0 && size > cap) {
    process.stdout.write("__oversized__\t" + size + "\t" + cap);
    process.exit(0);
  }
  const ALIAS = {product:"products",feature:"features",subfeature:"subfeatures",roadmaps:"roadmap",tier:"tiers",sec:"security",journey:"journeys",mock:"mocks",docs:"doc",kb:"knowledge","wiki-pages":"wiki"};
  const NOUNS = new Set("products features subfeatures roadmap tiers security journeys mocks design link ghost wiki doc knowledge pulse work plan meta org auth product feature subfeature roadmaps tier sec journey mock docs kb wiki-pages".split(" "));
  const GROUPS = new Set(["work\tpolicy", "work\trepositories", "work\trepos", "plan\tfollowup"]);
  const WRAP = new Set(["command","builtin","exec","env","sudo","nohup","nice","time"]);
  const out = new Set();
  const OPQ = String.fromCharCode(0);
  const UNJ = "__unjudged__\t";
  function unquoted(value) {
    let start = 0, end = value.length;
    while (start < end && (value.charCodeAt(start) === 34 || value.charCodeAt(start) === 39)) start += 1;
    while (end > start && (value.charCodeAt(end - 1) === 34 || value.charCodeAt(end - 1) === 39)) end -= 1;
    return value.slice(start, end);
  }
  function isLocalUrl(u) {
    u = String(u || "").toLowerCase();
    const s = u.indexOf("://");
    if (s !== -1) u = u.slice(s + 3);
    let h = u;
    for (let ci = 0; ci < u.length; ci++) {
      const c = u.charAt(ci);
      if (c === ":" || c === "/") { h = u.slice(0, ci); break; }
    }
    return h === "localhost" || h === "127.0.0.1" || h === "0.0.0.0" || h === "::1" || h === "[::1]";
  }
  function takesNextWord(t) {
    return t.indexOf("=") === -1 && (t.length === 2 || t.charAt(1) === "-");
  }
  function isDynamic(t) {
    return t.indexOf("\u0001") !== -1 || t.indexOf("\x24") !== -1;
  }
  function dynamicReadings(c) {
    if (!c.rest.some(isDynamic)) return [];
    const skipped = c.rest.filter((t) => !isDynamic(t)), consumed = [];
    for (let i = 0; i < c.rest.length; i++) {
      if (isDynamic(c.rest[i])) { i++; continue; }
      consumed.push(c.rest[i]);
    }
    return [{ envp: c.envp, rest: skipped }, { envp: c.envp, rest: consumed }];
  }
  function tokenInvocations() {
    const found = [];
    const norm = cmd.replace(/\x24\x28|[\x60\x28\x29]/g, ";");                      // $( backtick ( ) start a fresh command — treat as boundaries. Hex escapes keep literal ()/$ out of the bash $(...)-embedded node script so its paren counter stays balanced.
    for (const seg of norm.split(/\|\||&&|[;|\n&]/)) {
      const toks = seg.trim().split(/\s+/).filter(Boolean);
      let i = 0, base = "";
      const envp = {};
      for (;;) {
        while (i < toks.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(toks[i])) {       // capture env prefixes (VAR=val)
          const a = toks[i], eq = a.indexOf("=");
          envp[a.slice(0, eq)] = unquoted(a.slice(eq + 1));
          i++;
        }
        if (i >= toks.length) break;
        const t = unquoted(toks[i].replace(/^\\/, ""));                           // strip a leading backslash and any wrapping quote chars
        if (WRAP.has(t)) { i++; continue; }                                        // skip transparent wrappers (command/env/sudo/…)
        base = t.split("/").pop(); break;                                           // resolved command basename
      }
      if (base !== "zensu") continue;                                              // command basename must be zensu
      found.push({ envp, rest: toks.slice(i + 1) });
    }
    return found;
  }
  function psInvocations() {
    let found = null;
    try { found = require(process.env.ZPS || "").zensuInvocations(cmd); } catch (_) {}
    if (!found) found = { unjudged: /zensu/i.test(cmd.replace(/\x60/g, "")) ? "the PowerShell analyzer could not be loaded" : "", invocations: [] };
    if (found.unjudged) out.add(UNJ + String(found.unjudged).split(/[\t\r\n]/)[0]);
    return found.invocations;
  }
  let invocations = ps ? psInvocations() : tokenInvocations();
  if (!ps) try {
    invocations = require(process.env.ZGUARD).commandInvocations(cmd, { platform: process.platform })
      .filter((c) => c.name === "zensu")
      .map((c) => ({ envp: c.environment, rest: c.words }))
      .concat(invocations);
  } catch (_) {}
  invocations = invocations.concat(...invocations.map(dynamicReadings));
  for (const invocation of invocations) {
    const envp = invocation.envp, rest = ps ? invocation.rest.map((w) => w.toLowerCase()) : invocation.rest;
    if (envp.ZENSU_MCP_GATE === "off" && !sub) {                                   // explicit per-command bypass (deliberate one-off) — reported as a ledger marker
      out.add("__bypass__\tZENSU_MCP_GATE");
      continue;
    }
    if (rest.indexOf("--help") !== -1 || rest.indexOf("-h") !== -1) continue;      // --help/-h is a read, never a mutation
    let apiUrl = envp.ZENSU_API_URL || "";
    const ai = rest.indexOf("--api-url");
    if (ai !== -1 && typeof rest[ai + 1] === "string") apiUrl = unquoted(rest[ai + 1]);
    if (!apiUrl) apiUrl = process.env.ZAPI || "";
    if (isLocalUrl(apiUrl)) continue;                                              // localhost/dev backend → conventions moot, not the tracked product
    let noun = "", k = 0;
    for (; k < rest.length; k++) {
      const t = rest[k];
      if (t === "--") break;
      if (t === "") continue;
      if (t.charAt(0) === "-") { if (takesNextWord(t)) k++; continue; }
      if (NOUNS.has(t)) { noun = ALIAS[t] || t; }
      break;                                                                       // first non-flag token decides
    }
    if (ps && typeof rest[k] === "string" && rest[k].indexOf(OPQ) !== -1) { out.add(UNJ + "the noun of a zensu call is built at run time"); continue; }
    if (!noun) continue;
    const words = [];
    for (let m = k + 1; m < rest.length && words.length < 2; m++) {
      const t = rest[m];
      if (t === "--") break;
      if (t === "") continue;
      if (t.charAt(0) === "-") { if (takesNextWord(t)) m++; continue; }
      words.push(t.split(/[\t\r\n]/)[0]);
    }
    const verb = words[0] || "", third = words[1] || "";
    if (ps && verb.indexOf(OPQ) !== -1) { out.add(UNJ + "the verb of a zensu call is built at run time"); continue; }
    if (ps && third.indexOf(OPQ) !== -1 && GROUPS.has(noun + "\t" + verb)) { out.add(UNJ + "the subcommand of a zensu call is built at run time"); continue; }
    out.add(noun + "\t" + verb + "\t" + third.split(OPQ).join(""));
  }
  process.stdout.write([...out].join("\n"));
' 2>/dev/null)"

field() {
  printf '%s' "$INPUT" | F="$1" node -e '
    try {
      const j = JSON.parse(require("fs").readFileSync(0, "utf8") || "{}");
      const v = j[process.env.F];
      process.stdout.write(typeof v === "string" ? v : "");
    } catch (_) { process.stdout.write(""); }
  ' 2>/dev/null
}

# No zensu CLI invocation at all (or unparseable) → not our concern, allow
# (fail-open, mirroring the MCP gate's empty/non-JSON behaviour). Inline
# bypasses still parse as __bypass__ marker lines, so a bypassed zensu segment
# never lands in this hot-path exit.
[ -z "$INVOCATIONS" ] && exit 0

# Config-disabled gate has no decision point — nothing to bypass, nothing to
# ledger (kept ahead of the marker/escape handling so all Bash gates share the
# order).
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled mcpGate || exit 0

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
case "$INVOCATIONS" in
  (__oversized__*)
    IFS="$(printf '\t')" read -r OVERSIZED_MARK OVERSIZED_BYTES OVERSIZED_CAP <<EOF
$INVOCATIONS
EOF
    zensu_emit_oversized_payload_deny "$OVERSIZED_BYTES" "$OVERSIZED_CAP" || zensu_emit_hook_session_deny
    exit 0
    ;;
esac
if ! zensu_bind_hook_session "$INPUT"; then
  # The two recognized commands are reachable in EVERY bind failure, not only the
  # two relaxable ones — including a record that exists and disagrees, which is
  # what a mid-session plugin upgrade produces. Denying them there put
  # /zensu:doctor behind the very defect it reports and left the repair
  # unreachable with it. Everything else in this branch denies as before.
  if zensu_doctor_allowed "$INPUT"; then
    exit 0
  fi
  # A deny still has to say WHY. The named-state ladder and its rationale live in
  # zensu_emit_named_bind_deny (hooks/lib/zensu-session.sh). This gate names no
  # fallback scope, so an unnamed state gets the generic deny.
  zensu_emit_named_bind_deny "$INPUT"
  exit 0
fi

# Bypass ledger: escapes stay free, but while a TDD session is active the
# opt-out is recorded to chain state (fail-open, gate name only). Inline
# escapes are reported by the embedded parser itself (__bypass__ marker lines
# in INVOCATIONS) — the one code path that decides the bypass — so quoted
# spellings, mixed commands, and mere textual mentions all behave correctly.
# Recording is DEFERRED to the allow outcomes below: a command that ends up
# denied never executes, so it must not mint a ledger entry (deny wins over
# markers, same rule the source-write parser enforces).
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"

BYPASS_GATES="$(printf '%s\n' "$INVOCATIONS" | awk -F'\t' '$1=="__bypass__"{print $2}')"
INVOCATIONS="$(printf '%s\n' "$INVOCATIONS" | grep -v '^__bypass__')"
record_bypass_markers() {
  for gate in $BYPASS_GATES; do
    case "$gate" in
      ZENSU_MCP_GATE) tdd_record_bypass_payload "$INPUT" "$gate" 2>/dev/null || true ;;
    esac
  done
}

# Only markers, no real invocation left → allow.
[ -z "$INVOCATIONS" ] && { record_bypass_markers; exit 0; }

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-mcp-tools.sh"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-cli-map.sh"

# Global env escape (applies regardless of which tool) — an allow outcome, so
# record env + any markers here.
[ "${ZENSU_MCP_GATE:-}" = "off" ] && { tdd_record_bypass_payload "$INPUT" ZENSU_MCP_GATE 2>/dev/null || true; record_bypass_markers; exit 0; }

SID_CURRENT="$(zensu_resolve_session_id "$(field session_id)" 2>/dev/null || true)"
AGENT_ID="$(field agent_id)"
AGENT_TYPE="$(field agent_type)"
TOOL_NAME="$(field tool_name)"
IS_SUBAGENT=false
if [ -n "$AGENT_ID" ] || [ -n "$AGENT_TYPE" ]; then
  IS_SUBAGENT=true
fi
UNJUDGED="$(printf '%s\n' "$INVOCATIONS" | awk -F'\t' '$1=="__unjudged__"{print $2; exit}')"

# Returns 0 (allowed) only when the current hook payload session (or, when the
# payload omitted it, the exact exported Session Control key) owns a workflow
# declaring $1. Ambient CLAUDE_SESSION_ID is legacy introspection data and must
# never donate another session's authorization.
WORKFLOW_TOOLS=""
WORKFLOW_TOOLS_READ=false
tool_allowed_by_workflow() {
  local tool="$1" allowed
  [ -n "$SID_CURRENT" ] || return 1
  if [ "$WORKFLOW_TOOLS_READ" != true ]; then
    WORKFLOW_TOOLS="$(zensu_workflow_tools "$(tdd_state_file "$SID_CURRENT")")" || WORKFLOW_TOOLS=""
    WORKFLOW_TOOLS_READ=true
  fi
  while IFS= read -r allowed; do
    [ -n "$allowed" ] && [ "$allowed" = "$tool" ] && return 0
  done <<EOF
$WORKFLOW_TOOLS
EOF
  return 1
}

work_order_session_bound() {
  local hook_lib="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-work-order-hook.sh"
  [ -n "${ZENSU_SESSION_TOKEN:-}" ] || return 1
  [ -f "$hook_lib" ] && [ ! -L "$hook_lib" ] || return 1
  source "$hook_lib" 2>/dev/null || return 1
  [ "$(zensu_work_order_hook bound "$INPUT")" = bound ]
}

work_order_session_owns() {
  zensu_is_work_order_session_tool "$1" && work_order_session_bound
}

DENY_TOOL=""
while IFS="$(printf '\t')" read -r noun verb third; do
  [ -z "$noun" ] && continue
  TOOL="$(zensu_cli_to_tool "$noun" "$verb" "$third")"
  [ -z "$TOOL" ] && continue                          # unknown/neutral (auth, version) → allow
  zensu_is_read_tool "$TOOL" && continue              # read → allow
  zensu_is_mutation_tool "$TOOL" || continue          # not a known mutation → allow (safety)
  if [ "$IS_SUBAGENT" != true ]; then
    work_order_session_owns "$TOOL" && continue
    if ! zensu_is_human_decision_tool "$TOOL" && ! zensu_is_work_order_tool "$TOOL"; then
      tool_allowed_by_workflow "$TOOL" && continue    # workflow-driven → allow
    fi
  fi
  if zensu_is_human_decision_tool "$TOOL"; then
    DENY_TOOL="$TOOL"; break
  fi
  if [ -z "$DENY_TOOL" ] || { zensu_is_work_order_tool "$TOOL" && ! zensu_is_work_order_tool "$DENY_TOOL"; }; then
    DENY_TOOL="$TOOL"
  fi
done <<EOF
$INVOCATIONS
EOF

[ -z "$DENY_TOOL" ] && [ -z "$UNJUDGED" ] && { record_bypass_markers; exit 0; }

if [ -n "$UNJUDGED" ] && [ "$IS_SUBAGENT" = true ]; then
  REASON="A PowerShell command that names zensu was blocked because the Zensu CLI write-gate cannot judge it: ${UNJUDGED}. Zensu CLI mutations are reserved for the interactive main thread. Do not retry this command. Report the operation you need to the main thread."
elif [ -n "$UNJUDGED" ]; then
  REASON="A PowerShell command that names zensu was blocked because the Zensu CLI write-gate cannot judge it: ${UNJUDGED}. Run the zensu call through the Bash tool, or as a plain PowerShell command with a literal noun and verb (zensu <noun> <verb> ...) that no other command starts and no text built at run time names. Reads and --help pass; a mutation still needs the matching skill — /zensu:bootstrap or /zensu:ghost-scan (onboarding), /zensu:implement (feature work), /zensu:security-review (classification/review)."
elif [ "$IS_SUBAGENT" = true ]; then
  REASON="Zensu state-mutating command (maps to '${DENY_TOOL}') was blocked. Zensu CLI mutations are reserved for the interactive main thread: a subagent never borrows the main thread's skill window, and the per-command gate escape is a deliberate one-off for the main thread, never a route for a subagent. Do not retry this command, with or without a prefix. Report the operation you need to the main thread, which runs it through the matching skill — /zensu:bootstrap or /zensu:ghost-scan (onboarding), /zensu:implement (feature work), /zensu:security-review (classification/review)."
elif [ "$TOOL_NAME" = PowerShell ]; then
  REASON="Zensu state-mutating command (maps to '${DENY_TOOL}') was blocked. A direct command without an active main-thread skill window bypasses the Zensu workflow conventions (dedup, user journeys, baseline revisions, security classification, release-readiness gates). Run the matching skill — /zensu:bootstrap or /zensu:ghost-scan (onboarding), /zensu:implement (feature work), /zensu:security-review (classification/review) — in the interactive main thread. A PowerShell command has no inline gate escape; writes targeting a localhost backend (--api-url, or ZENSU_API_URL in the session environment) and --help are never gated."
else
  REASON="Zensu state-mutating command (maps to '${DENY_TOOL}') was blocked. A direct command without an active main-thread skill window bypasses the Zensu workflow conventions (dedup, user journeys, baseline revisions, security classification, release-readiness gates). Run the matching skill — /zensu:bootstrap or /zensu:ghost-scan (onboarding), /zensu:implement (feature work), /zensu:security-review (classification/review) — in the interactive main thread. For a deliberate one-off, prefix the command with ZENSU_MCP_GATE=off (honored inline); writes targeting a localhost backend (--api-url/ZENSU_API_URL) and --help are never gated."
fi

if zensu_is_human_decision_tool "$DENY_TOOL"; then
  REASON="Zensu command (maps to '${DENY_TOOL}') was blocked. It records a decision that the person makes, so the person runs it, not an agent and not a skill. Do not run it, with or without a prefix."
  if [ "$IS_SUBAGENT" = true ]; then
    REASON="$REASON Report the command and what it decides to the main thread, which puts the decision to the user."
  elif work_order_session_bound; then
    REASON="$REASON This session runs a Zensu work order without a person, so put the decision to the people behind the plan as a work-order question (zensu-work-order.sh --ask)."
  else
    REASON="$REASON Tell the user the exact command, what it decides and what you recommend, and let them run it."
  fi
elif zensu_is_work_order_tool "$DENY_TOOL"; then
  REASON="Zensu command (maps to '${DENY_TOOL}') was blocked. It belongs to the Zensu work-order protocol: the worker sends claim, confirm, release and usage, and only a bound work-order session sends heartbeat, event, ask and followup, the first two through the /zensu:work helper alone. Do not run it here, with or without a prefix."
  if [ "$IS_SUBAGENT" = true ]; then
    REASON="$REASON A subagent never sends it: report what you need to the main thread instead."
  fi
fi

REASON="$REASON" node -e '
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: process.env.REASON
    }
  }));
'
echo
exit 0
