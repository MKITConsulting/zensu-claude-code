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
# This is a convention-nudge, not an airtight boundary: once the CLI's OAuth
# token is cached on disk an agent can curl the API directly. The gate enforces
# the Zensu workflow conventions (dedup, journeys, baseline revisions, security
# classification, release-readiness), not a security control — same role, and
# same `ZENSU_MCP_GATE=off` / `hooks.mcpGate:false` escape, as the MCP gate it
# replaces (the env/config knob name is kept for backward compatibility).
set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"

command -v node >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null || true)"

# Parse the Bash command into zensu invocations. Emits one line per invocation,
# tab-separated "<noun>\t<verb>". Emits nothing — so the
# gate is a no-op — when the command runs no `zensu` CLI binary. Anchoring on the
# known noun set makes flag values (e.g. an --api-url argument) immune to being
# misread as a subcommand, and basename=="zensu" keeps `bash .../zensu-log.sh`
# and `.zensu/...` paths from ever matching.
INVOCATIONS="$(PAYLOAD="$INPUT" node -e '
  let cmd = "";
  try {
    const j = JSON.parse(process.env.PAYLOAD || "{}");
    if (j.tool_input && typeof j.tool_input.command === "string") cmd = j.tool_input.command;
  } catch (_) { process.exit(0); }
  if (!cmd || cmd.indexOf("zensu") === -1) process.exit(0);
  const ALIAS = {product:"products",feature:"features",subfeature:"subfeatures",roadmaps:"roadmap",tier:"tiers",sec:"security",journey:"journeys",docs:"doc",kb:"knowledge","wiki-pages":"wiki"};
  const NOUNS = new Set("products features subfeatures roadmap tiers security journeys link ghost wiki doc knowledge pulse meta org auth product feature subfeature roadmaps tier sec journey docs kb wiki-pages".split(" "));
  const WRAP = new Set(["command","builtin","exec","env","sudo","nohup","nice","time"]);
  const out = [];
  const norm = cmd.replace(/\x24\x28|[\x60\x28\x29]/g, ";");                        // $( backtick ( ) start a fresh command — treat as boundaries. Hex escapes keep literal ()/$ out of the bash $(...)-embedded node script so its paren counter stays balanced.
  for (const seg of norm.split(/\|\||&&|[;|\n&]/)) {
    const toks = seg.trim().split(/\s+/).filter(Boolean);
    let i = 0, base = "";
    for (;;) {
      while (i < toks.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(toks[i])) i++;      // skip env prefixes (VAR=val)
      if (i >= toks.length) break;
      const t = toks[i].replace(/^\\/, "").replace(/^[\x22\x27]+|[\x22\x27]+$/g, ""); // strip a leading backslash and any wrapping quote chars; quote bytes are hex-escaped so no literal quote appears in this bash single-quoted node script
      if (WRAP.has(t)) { i++; continue; }                                          // skip transparent wrappers (command/env/sudo/…)
      base = t.split("/").pop(); break;                                             // resolved command basename
    }
    if (base !== "zensu") continue;                                                // command basename must be zensu
    const rest = toks.slice(i + 1);
    let noun = "", k = 0;
    for (; k < rest.length; k++) {
      const t = rest[k];
      if (t === "--api-url") { k++; continue; }                                    // skip global flag value
      if (t.charAt(0) === "-") continue;                                           // skip flags
      if (NOUNS.has(t)) { noun = ALIAS[t] || t; }
      break;                                                                       // first non-flag token decides
    }
    if (!noun) continue;
    let verb = "";
    for (let m = k + 1; m < rest.length; m++) {
      const t = rest[m];
      if (t === "--api-url") { m++; continue; }
      if (t.charAt(0) === "-") continue;
      verb = t; break;
    }
    out.push(noun + "\t" + verb);
  }
  process.stdout.write(out.join("\n"));
' 2>/dev/null)"

# No zensu CLI invocation (or unparseable) → not our concern, allow (fail-open,
# mirroring the MCP gate's empty/non-JSON behaviour).
[ -z "$INVOCATIONS" ] && exit 0

field() {
  PAYLOAD="$INPUT" F="$1" node -e '
    try {
      const j = JSON.parse(process.env.PAYLOAD || "{}");
      const v = j[process.env.F];
      process.stdout.write(typeof v === "string" ? v : "");
    } catch (_) { process.stdout.write(""); }
  ' 2>/dev/null
}

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-mcp-tools.sh"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-cli-map.sh"

# Global escapes (apply regardless of which tool) — checked before per-tool work.
[ "${ZENSU_MCP_GATE:-}" = "off" ] && exit 0

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled mcpGate || exit 0

AGENT_TYPE="$(field agent_type)"
case "$AGENT_TYPE" in
  *zensu-plm*) exit 0 ;;
esac

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
SID_PRIMARY="$(zensu_resolve_session_id "$(field session_id)")"
SID_FALLBACK="$(zensu_resolve_session_id "${CLAUDE_SESSION_ID:-}")"

# Returns 0 (allowed) if a workflow declaring $1 is active in either session.
tool_allowed_by_workflow() {
  local tool="$1"
  [ "$(zensu_workflow_allows "$(tdd_state_file "$SID_PRIMARY")" "$tool")" = "true" ] && return 0
  [ -n "$SID_FALLBACK" ] && [ "$SID_FALLBACK" != "$SID_PRIMARY" ] \
    && [ "$(zensu_workflow_allows "$(tdd_state_file "$SID_FALLBACK")" "$tool")" = "true" ] && return 0
  return 1
}

DENY_TOOL=""
while IFS="$(printf '\t')" read -r noun verb; do
  [ -z "$noun" ] && continue
  TOOL="$(zensu_cli_to_tool "$noun" "$verb")"
  [ -z "$TOOL" ] && continue                          # unknown/neutral (auth, version) → allow
  zensu_is_read_tool "$TOOL" && continue              # read → allow
  zensu_is_mutation_tool "$TOOL" || continue          # not a known mutation → allow (safety)
  tool_allowed_by_workflow "$TOOL" && continue        # workflow-driven → allow
  DENY_TOOL="$TOOL"; break                            # freelance mutation → deny
done <<EOF
$INVOCATIONS
EOF

[ -z "$DENY_TOOL" ] && exit 0

REASON="Zensu state-mutating command (maps to '${DENY_TOOL}') was blocked. A direct main-thread \`zensu\` mutation bypasses the Zensu workflow conventions (dedup, user journeys, baseline revisions, security classification, release-readiness gates) that the skills and the zensu-plm agent enforce. Run the matching skill — /zensu:bootstrap or /zensu:ghost-scan (onboarding), /zensu:implement (feature work), /zensu:security-review (classification/review) — or delegate the whole task to the zensu-plm agent, instead of running the zensu CLI mutation directly. For a deliberate one-off, set ZENSU_MCP_GATE=off."

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
