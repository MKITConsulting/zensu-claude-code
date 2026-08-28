#!/bin/bash
set -u

# Pins the PreToolUse(Agent|Task) reviewer-spawn grant (pre-agent-reviewer-allow.sh):
# it admits Zensu's own capability-confined reviewer subagents before the host
# permission layer is consulted, stays silent on every other path, and NEVER denies.
# Also pins the disclosure surfaces — the SessionStart banner line and the
# /zensu:doctor rows — because a grant the plugin hands itself must be visible.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/pre-agent-reviewer-allow.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
MODULE="$PLUGIN_DIR/hooks/lib/reviewer-spawn-allow-v1.js"
UNIT="$PLUGIN_DIR/tests/structure/reviewer-spawn-allow-v1.test.js"
REPORT="$PLUGIN_DIR/hooks/lib/zensu-doctor-report.js"
BANNER="$PLUGIN_DIR/hooks/session-start-banner.sh"

SBOX="$(mktemp -d -t revallow-XXXXXX)"
export CLAUDE_PLUGIN_DATA="$SBOX/plugin-data"
mkdir -p "$CLAUDE_PLUGIN_DATA"
PROJECT="$SBOX/project"
mkdir -p "$PROJECT"
NO_CONFIG="$SBOX/.no-such-config.json"
trap 'rm -rf "$SBOX"' EXIT

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HOOK" ] || [ ! -f "$MODULE" ]; then
  check "A0 hook and decision module exist" FAIL
  echo "----"
  echo "test-reviewer-spawn-allow: $PASS PASS / $FAIL FAIL"
  exit 1
fi

[ -x "$HOOK" ] && check "A1 hook exists and is executable" PASS || check "A1 hook exists and is executable" FAIL
bash -n "$HOOK" 2>/dev/null && check "A2 bash -n syntax check passes" PASS || check "A2 bash -n syntax check passes" FAIL

# ── A3 registration, matcher included ────────────────────────────────
if node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const hit=(h.hooks.PreToolUse||[]).find(e=>(e.hooks||[])
    .some(z=>/pre-agent-reviewer-allow\.sh/.test(z.command||"")));
  if(!hit) process.exit(1);
  process.exit(hit.matcher==="Agent|Task"?0:2);
' "$HOOKS_JSON" 2>/dev/null; then
  check "A3 registered in hooks.json PreToolUse on matcher Agent|Task" PASS
else
  check "A3 registered in hooks.json PreToolUse on matcher Agent|Task" FAIL
fi

# ── A4 the unit driver runs here, with a case-count floor ────────────
# tests/run-all.sh discovers only test-*.sh, so a *.test.js with no driver is
# never executed by the tree runner. Exit 0 also accepts a file registering zero
# cases, which is why the floor is asserted rather than the exit status alone.
UNIT_OUT="$(node --test "$UNIT" 2>&1)"
UNIT_RC=$?
UNIT_COUNT="$(printf '%s\n' "$UNIT_OUT" | sed -n 's/^# *pass \([0-9][0-9]*\)$/\1/p' | tail -1)"
[ -z "$UNIT_COUNT" ] && UNIT_COUNT="$(printf '%s\n' "$UNIT_OUT" | sed -n 's/^.*pass \([0-9][0-9]*\)$/\1/p' | tail -1)"
# The floor is DERIVED from the file, not a literal: a hardcoded number drifts below the
# real count and then silently tolerates deleted cases.
# `test.skip(`/`test.todo(` count too: without them a disabled case lowers BOTH sides
# together and the equality still holds over a case that no longer runs.
UNIT_EXPECTED="$(grep -cE "^test(\.(skip|todo))?\(" "$UNIT" 2>/dev/null || echo 0)"
UNIT_TOTAL="$(printf '%s\n' "$UNIT_OUT" | sed -n 's/^# *tests \([0-9][0-9]*\)$/\1/p' | tail -1)"
[ -z "$UNIT_TOTAL" ] && UNIT_TOTAL="$(printf '%s\n' "$UNIT_OUT" | sed -n 's/^.*tests \([0-9][0-9]*\)$/\1/p' | tail -1)"
if [ "$UNIT_RC" -eq 0 ] && [ -n "$UNIT_COUNT" ] && [ "$UNIT_EXPECTED" -gt 0 ] \
  && [ "$UNIT_COUNT" -eq "$UNIT_EXPECTED" ] && [ "${UNIT_TOTAL:-0}" -eq "$UNIT_COUNT" ]; then
  check "A4 reviewer-spawn-allow-v1.test.js green with all $UNIT_EXPECTED registered cases" PASS
else
  check "A4 reviewer-spawn-allow-v1.test.js green with all registered cases (rc=$UNIT_RC ran=${UNIT_COUNT:-none} registered=$UNIT_EXPECTED)" FAIL
fi

# ── Behavioral helpers ───────────────────────────────────────────────
SESSION_ID="revallow-session-$$"

register_session() {
  node -e 'process.stdout.write(JSON.stringify({
    hook_event_name:"SessionStart", source:"startup",
    session_id:process.argv[1], cwd:process.argv[2]
  }))' "$SESSION_ID" "$PROJECT" \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
      env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
      bash "$PLUGIN_DIR/hooks/session-start-session-control.sh" >/dev/null 2>&1
}

# $1 subagent_type  $2 tool_name  $3 session_id  $4 config file  $5 optional agent_type
run_hook() {
  local sub="$1" tool="$2" sid="$3" cfg="$4" agent="${5:-}"
  node -e '
    const [sub, tool, sid, cwd, agent] = process.argv.slice(1);
    const p = { hook_event_name:"PreToolUse", session_id:sid, cwd:cwd,
      tool_name:tool, tool_input:{ subagent_type:sub, prompt:"review" } };
    if (agent) { p.agent_type = agent; p.agent_id = "agent-1"; }
    process.stdout.write(JSON.stringify(p));
  ' "$sub" "$tool" "$sid" "$PROJECT" "$agent" \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
      CLAUDE_PROJECT_DIR="$PROJECT" ZENSU_CONFIG="$cfg" \
      bash "$HOOK" 2>/dev/null
}

granted() {
  node -e '
    let s=""; process.stdin.on("data",c=>s+=c); process.stdin.on("end",()=>{
      try {
        const j=JSON.parse(s);
        const o=j.hookSpecificOutput||{};
        process.exit(o.hookEventName==="PreToolUse" && o.permissionDecision==="allow" ? 0 : 1);
      } catch(_) { process.exit(1); }
    });
  ' 2>/dev/null
}

if register_session; then
  check "A5pre a Session Control record was registered for the fixture session" PASS
else
  check "A5pre a Session Control record was registered for the fixture session" FAIL
fi

AGENTS="$(node -e 'process.stdout.write(require(process.argv[1]).CONFINED_REVIEWER_AGENTS.join(" "))' "$MODULE" 2>/dev/null)"
if [ -n "$AGENTS" ]; then
  check "A5pre2 the confined agent list was resolved from the module" PASS
else
  check "A5pre2 the confined agent list was resolved from the module" FAIL
fi

# ── A5/A6 the grant itself ───────────────────────────────────────────
# Cardinality first: an empty derivation would leave GRANT_OK at 1 and print PASS having
# asserted nothing, which is the vacuous-row shape this repo rejects elsewhere.
AGENT_COUNT="$(printf '%s\n' $AGENTS | grep -c . || echo 0)"
if [ "$AGENT_COUNT" -eq 5 ]; then
  check "A5pre3 the derivation yields the five plugin-scoped reviewers" PASS
else
  check "A5pre3 the derivation yields the five plugin-scoped reviewers (got $AGENT_COUNT)" FAIL
fi
GRANT_OK=1
[ "$AGENT_COUNT" -gt 0 ] || GRANT_OK=0
for agent in $AGENTS; do
  for tool in Agent Task; do
    if ! printf '%s' "$(run_hook "$agent" "$tool" "$SESSION_ID" "$NO_CONFIG")" | granted; then
      GRANT_OK=0
      echo "        (no grant for $agent via $tool)"
    fi
  done
done
[ "$GRANT_OK" -eq 1 ] && check "A5 every confined reviewer is granted through Agent and Task" PASS \
  || check "A5 every confined reviewer is granted through Agent and Task" FAIL

GRANT_BODY="$(run_hook "zensu:code-reviewer" Agent "$SESSION_ID" "$NO_CONFIG")"
case "$GRANT_BODY" in
  *'"deny"'*|*'"ask"'*) check "A6 the emitted decision never carries deny or ask" FAIL ;;
  *) check "A6 the emitted decision never carries deny or ask" PASS ;;
esac
case "$GRANT_BODY" in
  *'hooks.reviewerSpawnAutoAllow'*) check "A7 the decision reason names the off-switch" PASS ;;
  *) check "A7 the decision reason names the off-switch" FAIL ;;
esac

# ── A8-A11 silence ───────────────────────────────────────────────────
# Asserts the STATUS as well as the silence. Empty output alone cannot tell a silent
# decline from the fail-closed `exit 2` every other gate in this tree uses — and a
# non-zero exit from a PreToolUse hook BLOCKS the spawn, which is the one outcome this
# hook must never produce. Without the status arm, changing either early exit to `exit 2`
# left these rows green while every Agent spawn in the session would have been blocked.
silent() {
  local label="$1"; shift
  local out rc
  out="$(run_hook "$@")"; rc=$?
  if [ -z "$out" ] && [ "$rc" -eq 0 ]; then check "$label" PASS; else check "$label" FAIL; fi
}
silent "A8 an unconfined subagent type is silent" "general-purpose" Agent "$SESSION_ID" "$NO_CONFIG"
silent "A9 the PLM agent is silent" "zensu:zensu-plm" Agent "$SESSION_ID" "$NO_CONFIG"
silent "A10 a bare reviewer name is silent, only plugin-scoped names are granted" "code-reviewer" Agent "$SESSION_ID" "$NO_CONFIG"
silent "A11 a tool outside Agent|Task is silent" "zensu:code-reviewer" Bash "$SESSION_ID" "$NO_CONFIG"
silent "A12 an unregistered session is silent, never granted" "zensu:code-reviewer" Agent "no-such-session-$$" "$NO_CONFIG"
silent "A13 a subagent principal never earns a grant" "zensu:code-reviewer" Agent "$SESSION_ID" "$NO_CONFIG" "zensu:review-aspect"

# ── A14/A15 the off-switch ───────────────────────────────────────────
printf '{"hooks":{"reviewerSpawnAutoAllow":false}}\n' > "$SBOX/off.json"
printf '{"hooks":{"reviewerSpawnAutoAllow":"false"}}\n' > "$SBOX/quoted.json"
silent "A14 hooks.reviewerSpawnAutoAllow=false disables the grant" "zensu:code-reviewer" Agent "$SESSION_ID" "$SBOX/off.json"
if printf '%s' "$(run_hook "zensu:code-reviewer" Agent "$SESSION_ID" "$SBOX/quoted.json")" | granted; then
  check "A15 a quoted \"false\" does not disable the grant" PASS
else
  check "A15 a quoted \"false\" does not disable the grant" FAIL
fi

# ── A16 the hook never exits non-zero ────────────────────────────────
EXIT_OK=1
for sub in "zensu:code-reviewer" "general-purpose" ""; do
  run_hook "$sub" Agent "$SESSION_ID" "$NO_CONFIG" >/dev/null 2>&1 || EXIT_OK=0
done
run_hook "zensu:code-reviewer" Agent "no-such-session-$$" "$NO_CONFIG" >/dev/null 2>&1 || EXIT_OK=0
[ "$EXIT_OK" -eq 1 ] && check "A16 the hook always exits 0 — a non-zero exit would block the spawn" PASS \
  || check "A16 the hook always exits 0 — a non-zero exit would block the spawn" FAIL

# ── A17-A20 disclosure: /zensu:doctor ────────────────────────────────
DOC_HOME="$SBOX/home"
mkdir -p "$DOC_HOME/.claude"
doctor() {
  ZDOC_ZENSU=absent ZDOC_NODE=vTEST ZDOC_FORGE_PROVIDER=unknown ZDOC_FORGE_CLI='' \
  ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$PLUGIN_DIR" ZENSU_CONFIG="$1" CLAUDE_PROJECT_DIR="$PROJECT" \
  HOME="$DOC_HOME" node "$REPORT" 2>/dev/null
}
DOC_ON="$(doctor "$NO_CONFIG")"
# The needle reaches INTO the rendered agent list: stopping at the sentence would leave a
# truncated or empty list rendering a wrong row with this check still green.
case "$DOC_ON" in
  *"admits its own read-only reviewer spawns (zensu:code-reviewer,"*"zensu:review-judge"*)
    check "A17 doctor discloses the active grant and names the agents it covers" PASS ;;
  *) check "A17 doctor discloses the active grant and names the agents it covers" FAIL ;;
esac
case "$DOC_ON" in
  *"the session must bind to a valid Session Control record"*)
    check "A17a the row states the per-call conditions this check cannot see" PASS ;;
  *) check "A17a the row states the per-call conditions this check cannot see" FAIL ;;
esac
case "$DOC_ON" in
  *"pre-agent-reviewer-allow.sh"*) check "A18 the doctor row names the hook that grants" PASS ;;
  *) check "A18 the doctor row names the hook that grants" FAIL ;;
esac
DOC_OFF="$(doctor "$SBOX/off.json")"
case "$DOC_OFF" in
  *"reviewer-spawn grant is switched off"*) check "A19 doctor reports a disabled grant instead of falling silent" PASS ;;
  *) check "A19 doctor reports a disabled grant instead of falling silent" FAIL ;;
esac
case "$DOC_OFF" in
  *"admits its own read-only reviewer spawns"*) check "A19a the active row is suppressed while the grant is off" FAIL ;;
  *) check "A19a the active row is suppressed while the grant is off" PASS ;;
esac

# ── A19b/A19c the doctor must not assert a cause it never established ────────
# reviewerSpawnAutoAllowDisabled folded every readJson failure into one boolean whose only
# renderer names ONE cause. A trailing comma then sent the user hunting for a key they
# never wrote — the failure this file's own doctrine forbids one branch below, where the
# module-load row deliberately "names the load rather than asserting which file is absent".
# The fixture is created HERE and not reused from A31 below: at this point in the file
# that path does not exist yet, so a doctor run against it would take the missing-config
# branch and every assertion in this block would pass for the wrong reason.
printf 'this is not json\n' > "$SBOX/doc-broken.json"
DOC_BROKEN="$(doctor "$SBOX/doc-broken.json")"
case "$DOC_BROKEN" in
  *"permissions:"*) check "A19bpre the report reached its permissions block (absence anchor)" PASS ;;
  *) check "A19bpre the report reached its permissions block (absence anchor)" FAIL ;;
esac
case "$DOC_BROKEN" in
  *"a config source could not be read or parsed"*)
    check "A19b an unjudgeable config renders its own could-not-judge row" PASS ;;
  *) check "A19b an unjudgeable config renders its own could-not-judge row" FAIL ;;
esac
case "$DOC_BROKEN" in
  *"reviewer-spawn grant is switched off"*)
    check "A19b1 an unjudgeable config is NOT reported as a user configuration choice" FAIL ;;
  *) check "A19b1 an unjudgeable config is NOT reported as a user configuration choice" PASS ;;
esac

# The size case is worse than a wrong cause: readJson caps at CONFIG_MAX_BYTES while the
# ENFORCING reader has no cap, so an oversized well-formed config is read and applied by
# the hook — which GRANTS — while this row claimed the grant was switched off.
node -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({ pad: "x".repeat(1024 * 1024 + 64) }) + "\n");
' "$SBOX/oversize.json"
DOC_BIG="$(doctor "$SBOX/oversize.json")"
case "$DOC_BIG" in
  *"reviewer-spawn grant is switched off"*)
    check "A19c an oversized config is never rendered as switched off" FAIL ;;
  *) check "A19c an oversized config is never rendered as switched off" PASS ;;
esac

# A20 with permission mode auto and no allow rule, the advice must change:
# the grant already covers the spawn the old row told the user to add a rule for.
printf '{"permissions":{"defaultMode":"auto"}}\n' > "$DOC_HOME/.claude/settings.json"
DOC_AUTO_ON="$(doctor "$NO_CONFIG")"
DOC_AUTO_OFF="$(doctor "$SBOX/off.json")"
case "$DOC_AUTO_ON" in
  *"no settings edit is needed for them"*) check "A20 auto mode plus an active grant reports no settings edit is needed" PASS ;;
  *) check "A20 auto mode plus an active grant reports no settings edit is needed" FAIL ;;
esac
case "$DOC_AUTO_ON" in
  *'Add "Agent(zensu:code-reviewer)" to permissions.allow'*)
    check "A20a the settings-edit advice is withdrawn while the grant is active" FAIL ;;
  *) check "A20a the settings-edit advice is withdrawn while the grant is active" PASS ;;
esac
case "$DOC_AUTO_OFF" in
  *'Add "Agent(zensu:code-reviewer)" to permissions.allow'*)
    check "A20b the settings-edit advice returns when the grant is off" PASS ;;
  *) check "A20b the settings-edit advice returns when the grant is off" FAIL ;;
esac
# The grant does NOT survive a deny rule, so the caveat has to travel with the granted
# row too. Anchored on the caveat's own opening clause rather than the bare word "deny",
# which the surrounding rows also contain.
case "$DOC_AUTO_ON" in
  *"Remove any deny rule that names the Agent tool first"*)
    check "A20c the granted row keeps the deny-first caveat" PASS ;;
  *) check "A20c the granted row keeps the deny-first caveat" FAIL ;;
esac

# ── A21/A22 disclosure: the SessionStart banner ──────────────────────
banner() {
  node -e 'process.stdout.write(JSON.stringify({hook_event_name:"SessionStart",source:"startup",session_id:process.argv[1],cwd:process.argv[2]}))' \
    "$SESSION_ID" "$PROJECT" \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
      CLAUDE_PROJECT_DIR="$PROJECT" ZENSU_CONFIG="$1" bash "$BANNER" 2>/dev/null
}
BANNER_ON="$(banner "$NO_CONFIG")"
case "$BANNER_ON" in
  *"Reviewer spawns"*"hooks.reviewerSpawnAutoAllow=false"*)
    check "A21 the banner discloses the grant and names the off-switch" PASS ;;
  *) check "A21 the banner discloses the grant and names the off-switch" FAIL ;;
esac
BANNER_OFF="$(banner "$SBOX/off.json")"
# ANCHORED absence: the banner has several earlier `exit 0` paths, so empty output is also
# what a banner that never rendered looks like. Prove it rendered before proving the line is
# gone.
case "$BANNER_OFF" in
  *"Zensu PLM v"*) check "A22pre the banner rendered in the off case (absence anchor)" PASS ;;
  *) check "A22pre the banner rendered in the off case (absence anchor)" FAIL ;;
esac
case "$BANNER_OFF" in
  *"Reviewer spawns"*) check "A22 the banner line is absent once the grant is off" FAIL ;;
  *) check "A22 the banner line is absent once the grant is off" PASS ;;
esac

# ── A23 the flag is carried by config.example.json, like every sibling flag ───
if node -e '
  const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  process.exit(c.hooks && c.hooks.reviewerSpawnAutoAllow === true ? 0 : 1);
' "$PLUGIN_DIR/config.example.json" 2>/dev/null; then
  check "A23 config.example.json carries hooks.reviewerSpawnAutoAllow" PASS
else
  check "A23 config.example.json carries hooks.reviewerSpawnAutoAllow" FAIL
fi

# ── A24 every rendered permissions row is documented in the doctor skill ─────
# P1be is the drift pin two documents name as holding the doctor rows and
# skills/doctor/SKILL.md in step, but its corpus is built from fixtures that never reach a
# grant state, so all four rows added here are invisible to it. Pin them where they render.
SKILL_MD="$PLUGIN_DIR/skills/doctor/SKILL.md"
A24_MISS=""
for phrase in \
  "admits its own read-only reviewer spawns" \
  "no settings edit is needed for them" \
  "the reviewer-spawn grant is switched off" \
  "could not be loaded" \
  "does not register it on a PreToolUse matcher covering the spawn tools" \
  "could not be read or parsed"; do
  grep -qF -- "$phrase" "$SKILL_MD" || A24_MISS="$A24_MISS [$phrase]"
done
[ -z "$A24_MISS" ] && check "A24 all four grant rows are documented in skills/doctor/SKILL.md" PASS \
  || check "A24 grant rows missing from skills/doctor/SKILL.md:$A24_MISS" FAIL

# ── A25/A26 the two broken-installation doctor states ────────────────────────
# Both are unreachable from the live plugin root, so they need throwaway roots. Without
# these the "installed but unloadable" and "not installed" branches are pinned nowhere.
mk_root() { # $1 dest  $2 include module  $3 include hook
  local d="$1"
  mkdir -p "$d/.claude-plugin" "$d/hooks/lib"
  cp "$PLUGIN_DIR/.claude-plugin/plugin.json" "$d/.claude-plugin/" 2>/dev/null
  cp "$PLUGIN_DIR/.claude-plugin/marketplace.json" "$d/.claude-plugin/" 2>/dev/null
  cp "$PLUGIN_DIR/hooks/hooks.json" "$d/hooks/" 2>/dev/null
  [ "$3" = "hook" ] && cp "$PLUGIN_DIR/hooks/pre-agent-reviewer-allow.sh" "$d/hooks/"
  [ "$2" = "module" ] && cp "$PLUGIN_DIR/hooks/lib/reviewer-spawn-allow-v1.js" "$d/hooks/lib/"
  return 0
}
doctor_at() {
  ZDOC_ZENSU=absent ZDOC_NODE=vTEST ZDOC_FORGE_PROVIDER=unknown ZDOC_FORGE_CLI='' \
  ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZENSU_DOCTOR_PLUGIN_DIR="$1" ZENSU_CONFIG="$NO_CONFIG" CLAUDE_PROJECT_DIR="$PROJECT" \
  HOME="$DOC_HOME" node "$REPORT" 2>/dev/null
}
mk_root "$SBOX/root-nomodule" nomodule hook
DOC_NOMOD="$(doctor_at "$SBOX/root-nomodule")"
case "$DOC_NOMOD" in
  *"could not be loaded"*"broken installation, not a configuration choice"*)
    check "A25 an installed hook without its decision module reports a broken installation" PASS ;;
  *) check "A25 an installed hook without its decision module reports a broken installation" FAIL ;;
esac
case "$DOC_NOMOD" in
  *"admits its own read-only reviewer spawns"*)
    check "A25a the active grant row is suppressed on a broken installation" FAIL ;;
  *) check "A25a the active grant row is suppressed on a broken installation" PASS ;;
esac
mk_root "$SBOX/root-nohook" module nohook
DOC_NOHOOK="$(doctor_at "$SBOX/root-nohook")"
case "$DOC_NOHOOK" in
  *"permissions:"*) check "A26pre the report reached its permissions block (absence anchor)" PASS ;;
  *) check "A26pre the report reached its permissions block (absence anchor)" FAIL ;;
esac
case "$DOC_NOHOOK" in
  *"reviewer-spawn grant"*|*"admits its own read-only reviewer spawns"*)
    check "A26 a root predating the feature renders no grant row at all" FAIL ;;
  *) check "A26 a root predating the feature renders no grant row at all" PASS ;;
esac

# ── A27 a deny rule still warns while the grant is active ────────────────────
# AC-009's second half. Every deny/ask fixture in test-doctor.sh runs against a sandbox root
# where the grant is inactive, so this pairing existed nowhere.
printf '{"permissions":{"defaultMode":"auto","deny":["Agent(zensu:code-reviewer)"]}}\n' > "$DOC_HOME/.claude/settings.json"
DOC_DENY="$(doctor "$NO_CONFIG")"
case "$DOC_DENY" in
  *"a permissions.deny entry in ~/.claude/settings.json matches the"*)
    check "A27 a deny rule still warns while the grant is active" PASS ;;
  *) check "A27 a deny rule still warns while the grant is active" FAIL ;;
esac
case "$DOC_DENY" in
  *"no settings edit is needed for them"*)
    check "A27a the granted row does not fire while a deny rule stands" FAIL ;;
  *) check "A27a the granted row does not fire while a deny rule stands" PASS ;;
esac
printf '{"permissions":{"defaultMode":"auto","ask":["Agent(zensu:code-reviewer)"]}}\n' > "$DOC_HOME/.claude/settings.json"
DOC_ASK="$(doctor "$NO_CONFIG")"
case "$DOC_ASK" in
  *"a permissions.ask entry in ~/.claude/settings.json matches the"*)
    check "A28 an ask rule still warns while the grant is active" PASS ;;
  *) check "A28 an ask rule still warns while the grant is active" FAIL ;;
esac

# ── A29 the grant survives every hook registered on the Agent matcher ────────
# The host resolves deny > ask > allow across ALL hooks on a matcher, so exercising this
# hook alone proves nothing about the real pipeline. Drive every PreToolUse hook whose
# matcher matches `Agent` and require that none of them denies or asks.
A29_BAD=""
A29_HOOKS="$(node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const out=[];
  for (const g of (h.hooks.PreToolUse||[])) {
    if (!new RegExp(g.matcher || ".*").test("Agent")) continue;
    for (const e of (g.hooks||[])) {
      const m=/hooks\/([A-Za-z0-9._-]+\.sh)/.exec(e.command||"");
      if (m) out.push(m[1]);
    }
  }
  process.stdout.write([...new Set(out)].join(" "));
' "$HOOKS_JSON" 2>/dev/null)"
for hk in $A29_HOOKS; do
  [ "$hk" = "pre-agent-reviewer-allow.sh" ] && continue
  HK_OUT="$(node -e '
    process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",session_id:process.argv[1],
      cwd:process.argv[2],tool_name:"Agent",
      tool_input:{subagent_type:"zensu:code-reviewer",prompt:"review"}}));
  ' "$SESSION_ID" "$PROJECT" \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
      CLAUDE_PROJECT_DIR="$PROJECT" ZENSU_CONFIG="$NO_CONFIG" \
      bash "$PLUGIN_DIR/hooks/$hk" 2>/dev/null)"
  case "$HK_OUT" in
    *'"deny"'*|*'"ask"'*) A29_BAD="$A29_BAD [$hk]" ;;
  esac
done
if [ -z "$A29_HOOKS" ]; then
  check "A29 no sibling hook on the Agent matcher outranks the grant (no hooks resolved)" FAIL
elif [ -z "$A29_BAD" ]; then
  check "A29 no sibling hook on the Agent matcher outranks the grant" PASS
else
  check "A29 sibling hooks on the Agent matcher return deny or ask:$A29_BAD" FAIL
fi

# ── A30 the hook reads the flag through the FAIL-CLOSED helper ───────────────
# A14/A15 pass identically under either reader, so without this pair the whole FR-001
# decision could be reverted with every check green.
if grep -qF 'zensu_hook_enabled_strict reviewerSpawnAutoAllow' "$HOOK"; then
  check "A30 the hook reads the flag through zensu_hook_enabled_strict" PASS
else
  check "A30 the hook reads the flag through zensu_hook_enabled_strict" FAIL
fi
if grep -qE '(^|[^_])zensu_hook_enabled reviewerSpawnAutoAllow' "$HOOK"; then
  check "A30a the permissive reader is not used on this key" FAIL
else
  check "A30a the permissive reader is not used on this key" PASS
fi

# ── A31 a present-but-unreadable config withdraws the grant ──────────────────
# The behavioral half of FR-001. The permissive reader answers "enabled" here because rd()
# swallows the parse error and returns {}; the fail-closed one declines.
printf 'this is not json\n' > "$SBOX/broken.json"
if [ -z "$(run_hook "zensu:code-reviewer" Agent "$SESSION_ID" "$SBOX/broken.json")" ]; then
  check "A31 a present but unparseable config withdraws the grant" PASS
else
  check "A31 a present but unparseable config withdraws the grant" FAIL
fi

# ── A32 withdrawal is sticky across config sources ───────────────────────────
# A project-local .zensu/config.json must not be able to re-arm a grant the user withdrew
# globally: that file travels with a checked-out repository.
STICKY_HOME="$SBOX/sticky-home"; STICKY_PROJ="$SBOX/sticky-project"
mkdir -p "$STICKY_HOME/.zensu" "$STICKY_PROJ/.zensu"
printf '{"hooks":{"reviewerSpawnAutoAllow":true}}\n' > "$STICKY_PROJ/.zensu/config.json"
# A32pre is the control this check lacked. A32 varies TWO environment axes at once — it
# strips ZENSU_CONFIG and redirects both HOME and CLAUDE_PROJECT_DIR — and the hook has
# several silent exits before the flag is ever read, so an empty result alone could mean
# any of them. Prove the SAME fixture grants first; then the only thing A32 changes is the
# global file's value, and its silence can only be the sticky withdrawal.
printf '{"hooks":{"reviewerSpawnAutoAllow":true}}\n' > "$STICKY_HOME/.zensu/config.json"
STICKY_CTL="$(node -e '
  process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",session_id:process.argv[1],
    cwd:process.argv[2],tool_name:"Agent",tool_input:{subagent_type:"zensu:code-reviewer"}}));
' "$SESSION_ID" "$PROJECT" \
  | env -u ZENSU_CONFIG CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
    CLAUDE_PROJECT_DIR="$STICKY_PROJ" HOME="$STICKY_HOME" \
    bash "$HOOK" 2>/dev/null)"
printf '%s' "$STICKY_CTL" | granted \
  && check "A32pre the sticky fixture grants before the global withdrawal (control)" PASS \
  || check "A32pre the sticky fixture grants before the global withdrawal (control)" FAIL
printf '{"hooks":{"reviewerSpawnAutoAllow":false}}\n' > "$STICKY_HOME/.zensu/config.json"
STICKY_OUT="$(node -e '
  process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",session_id:process.argv[1],
    cwd:process.argv[2],tool_name:"Agent",tool_input:{subagent_type:"zensu:code-reviewer"}}));
' "$SESSION_ID" "$PROJECT" \
  | env -u ZENSU_CONFIG CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
    CLAUDE_PROJECT_DIR="$STICKY_PROJ" HOME="$STICKY_HOME" \
    bash "$HOOK" 2>/dev/null)"
[ -z "$STICKY_OUT" ] && check "A32 a project overlay cannot re-arm a globally withdrawn grant" PASS \
  || check "A32 a project overlay cannot re-arm a globally withdrawn grant" FAIL

# ── A31a a config the reader cannot REACH is not the same as one that is absent ──
# one() mapped every statSync error to "absent", so an EACCES/ENOTDIR/ELOOP on a config
# path was read as "no config here" and the grant survived a withdrawal the process could
# not reach. A regular file in the parent position yields ENOTDIR for every user including
# root, so this arm cannot go vacuous in a container. A5 is the granting control: it runs
# the same helper in the same environment and differs only in the config path.
printf 'x\n' > "$SBOX/notadir"
if [ -z "$(run_hook "zensu:code-reviewer" Agent "$SESSION_ID" "$SBOX/notadir/config.json")" ]; then
  check "A31a a config path the reader cannot traverse withdraws the grant" PASS
else
  check "A31a a config path the reader cannot traverse withdraws the grant" FAIL
fi

# ── A31b the sentinel and value domains must not collide ─────────────────────
# one() returned either a parsed JSON value or a sentinel STRING. JSON.parse('"absent"')
# is the string absent, so a config whose whole content is that literal took the
# not-present branch: present, unusable, and the grant survived.
printf '"absent"\n' > "$SBOX/sentinel.json"
if [ -z "$(run_hook "zensu:code-reviewer" Agent "$SESSION_ID" "$SBOX/sentinel.json")" ]; then
  check "A31b a config whose content is the sentinel literal withdraws the grant" PASS
else
  check "A31b a config whose content is the sentinel literal withdraws the grant" FAIL
fi

# ── A32a an EMPTY candidate list must withdraw, not grant ────────────────────
# Driven against the helper rather than the hook, because with HOME unset there is no
# place to put a granting config and no positive control could exist through run_hook.
# A32apre IS that control: the same stripped environment with HOME restored to a
# config-free tree must still GRANT, so a failure of A32a names the empty list and not
# some unrelated decline the stripped environment caused.
STRICT_PROBE='source "$1/hooks/lib/zensu-config.sh"; zensu_hook_enabled_strict reviewerSpawnAutoAllow'
mkdir -p "$SBOX/empty-home"
if env -u ZENSU_CONFIG -u CLAUDE_PROJECT_DIR HOME="$SBOX/empty-home" \
     bash -c "$STRICT_PROBE" _ "$PLUGIN_DIR"; then
  check "A32apre a config-free HOME still grants (control for A32a)" PASS
else
  check "A32apre a config-free HOME still grants (control for A32a)" FAIL
fi
if env -u ZENSU_CONFIG -u HOME -u CLAUDE_PROJECT_DIR \
     bash -c "$STRICT_PROBE" _ "$PLUGIN_DIR"; then
  check "A32a an empty candidate list withdraws the grant" FAIL
else
  check "A32a an empty candidate list withdraws the grant" PASS
fi

# ── A33 the autoMode.allow prose row is suppressed while the grant is active ──
printf '{"permissions":{"defaultMode":"auto"},"autoMode":{"allow":["prefer zensu:code-reviewer"]}}\n' > "$DOC_HOME/.claude/settings.json"
DOC_PROSE_ON="$(doctor "$NO_CONFIG")"
DOC_PROSE_OFF="$(doctor "$SBOX/off.json")"
case "$DOC_PROSE_ON" in
  *"permissions:"*) check "A33pre the report reached its permissions block (absence anchor)" PASS ;;
  *) check "A33pre the report reached its permissions block (absence anchor)" FAIL ;;
esac
case "$DOC_PROSE_ON" in
  *"classifier guidance in prose"*)
    check "A33 the autoMode prose row is suppressed while the grant is active" FAIL ;;
  *) check "A33 the autoMode prose row is suppressed while the grant is active" PASS ;;
esac
case "$DOC_PROSE_OFF" in
  *"classifier guidance in prose"*)
    check "A33a the autoMode prose row returns when the grant is off" PASS ;;
  *) check "A33a the autoMode prose row returns when the grant is off" FAIL ;;
esac

# ── A34 an unwired hook is a broken installation, not a grant ────────────────
mk_root "$SBOX/root-unwired" module hook
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash \\"${CLAUDE_PLUGIN_ROOT}/hooks/pre-agent-reviewer-allow.sh\\""}]}]}}\n' > "$SBOX/root-unwired/hooks/hooks.json"
DOC_UNWIRED="$(doctor_at "$SBOX/root-unwired")"
case "$DOC_UNWIRED" in
  *"does not register it on a PreToolUse matcher covering the spawn tools"*)
    check "A34 a hook registered on a non-spawn matcher reports a broken installation" PASS ;;
  *) check "A34 a hook registered on a non-spawn matcher reports a broken installation" FAIL ;;
esac
case "$DOC_UNWIRED" in
  *"admits its own read-only reviewer spawns"*)
    check "A34a the active grant row is suppressed for an unwired hook" FAIL ;;
  *) check "A34a the active grant row is suppressed for an unwired hook" PASS ;;
esac
mk_root "$SBOX/root-badjson" module hook
printf 'not json at all\n' > "$SBOX/root-badjson/hooks/hooks.json"
DOC_BADJSON="$(doctor_at "$SBOX/root-badjson")"
case "$DOC_BADJSON" in
  *"could not be read or parsed"*)
    check "A34b an unreadable hooks.json reports could-not-judge, not not-wired" PASS ;;
  *) check "A34b an unreadable hooks.json reports could-not-judge, not not-wired" FAIL ;;
esac

# ── A35 the granted row keeps its ✅ level ───────────────────────────────────
# ROW_LEVEL carries exactly one entry and defaults to WARN, so deleting it would silently
# turn a healthy configuration's row into a warning.
printf '{"permissions":{"defaultMode":"auto"}}\n' > "$DOC_HOME/.claude/settings.json"
DOC_GLYPH="$(doctor "$NO_CONFIG")"
if printf '%s\n' "$DOC_GLYPH" | grep -q '^ *✅.*no settings edit is needed for them'; then
  check "A35 the granted exposure row renders at the ✅ level" PASS
else
  check "A35 the granted exposure row renders at the ✅ level" FAIL
fi

# ── A36 the banner's file guards, not only its flag ──────────────────────────
mk_root "$SBOX/root-banner" nomodule hook
cp "$PLUGIN_DIR/hooks/session-start-banner.sh" "$SBOX/root-banner/hooks/" 2>/dev/null
cp -R "$PLUGIN_DIR/hooks/lib" "$SBOX/root-banner/hooks/" 2>/dev/null
rm -f "$SBOX/root-banner/hooks/lib/reviewer-spawn-allow-v1.js"
cp "$PLUGIN_DIR/.claude-plugin/plugin.json" "$SBOX/root-banner/.claude-plugin/" 2>/dev/null
BANNER_NOMOD="$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"SessionStart",source:"startup",session_id:process.argv[1],cwd:process.argv[2]}))' "$SESSION_ID" "$PROJECT" \
  | CLAUDE_PLUGIN_ROOT="$SBOX/root-banner" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
    CLAUDE_PROJECT_DIR="$PROJECT" ZENSU_CONFIG="$NO_CONFIG" \
    bash "$SBOX/root-banner/hooks/session-start-banner.sh" 2>/dev/null)"
case "$BANNER_NOMOD" in
  *"Zensu PLM v"*) check "A36pre the throwaway-root banner rendered (absence anchor)" PASS ;;
  *) check "A36pre the throwaway-root banner rendered (absence anchor)" FAIL ;;
esac
case "$BANNER_NOMOD" in
  *"Reviewer spawns"*)
    check "A36 the banner withholds the grant line when the decision module is absent" FAIL ;;
  *) check "A36 the banner withholds the grant line when the decision module is absent" PASS ;;
esac

# ── A37 the doctor applies the SAME module guard the hook applies ────────────
# pre-agent-reviewer-allow.sh refuses a symlinked decider outright ([ ! -L ]), but the
# report used require() and statSync, which both follow links — so on a --plugin-dir or
# dotfile-managed tree the ✅ row asserted a grant the hook declines on every spawn.
# A37pre is the control: the SAME root with a real file must render the ✅ row, so a
# failure of A37 names the symlink and not the throwaway root's own incompleteness.
mk_root "$SBOX/root-symlink" nomodule hook
cp -R "$PLUGIN_DIR/agents" "$SBOX/root-symlink/agents"
cp "$PLUGIN_DIR/hooks/lib/reviewer-spawn-allow-v1.js" "$SBOX/root-symlink/hooks/lib/"
cp "$PLUGIN_DIR/hooks/lib/reviewer-spawn-denial-v1.js" "$SBOX/root-symlink/hooks/lib/"
cp "$PLUGIN_DIR/hooks/lib/claude-principal-v1.js" "$SBOX/root-symlink/hooks/lib/"
DOC_REALMOD="$(doctor_at "$SBOX/root-symlink")"
case "$DOC_REALMOD" in
  *"admits its own read-only reviewer spawns"*)
    check "A37pre a real module in the throwaway root renders the active row (control)" PASS ;;
  *) check "A37pre a real module in the throwaway root renders the active row (control)" FAIL ;;
esac
if ln -sf "$PLUGIN_DIR/hooks/lib/reviewer-spawn-allow-v1.js" \
     "$SBOX/root-symlink/hooks/lib/reviewer-spawn-allow-v1.js" \
   && [ -L "$SBOX/root-symlink/hooks/lib/reviewer-spawn-allow-v1.js" ]; then
  DOC_SYMLINK="$(doctor_at "$SBOX/root-symlink")"
  case "$DOC_SYMLINK" in
    *"admits its own read-only reviewer spawns"*)
      check "A37 a symlinked decision module is refused, matching the hook's own guard" FAIL ;;
    *) check "A37 a symlinked decision module is refused, matching the hook's own guard" PASS ;;
  esac
else
  # ln -s exiting 0 is not evidence of a symlink on every host; refuse to report a
  # verdict the fixture never established.
  check "A37 a symlinked decision module is refused (SKIPPED — no real symlink)" FAIL
fi

# A37a the same guard on the HOOK path. A symlinked hook is a broken installation, not an
# installation predating the feature, so it must WARN rather than fall silent — silence is
# the one verdict this check cannot qualify.
mk_root "$SBOX/root-symhook" module nomodule
cp -R "$PLUGIN_DIR/agents" "$SBOX/root-symhook/agents"
cp "$PLUGIN_DIR/hooks/lib/reviewer-spawn-denial-v1.js" "$SBOX/root-symhook/hooks/lib/"
cp "$PLUGIN_DIR/hooks/lib/claude-principal-v1.js" "$SBOX/root-symhook/hooks/lib/"
if ln -sf "$PLUGIN_DIR/hooks/pre-agent-reviewer-allow.sh" \
     "$SBOX/root-symhook/hooks/pre-agent-reviewer-allow.sh" \
   && [ -L "$SBOX/root-symhook/hooks/pre-agent-reviewer-allow.sh" ]; then
  DOC_SYMHOOK="$(doctor_at "$SBOX/root-symhook")"
  case "$DOC_SYMHOOK" in
    *"admits its own read-only reviewer spawns"*)
      check "A37a a symlinked grant hook is never reported as an active grant" FAIL ;;
    *"pre-agent-reviewer-allow.sh"*)
      check "A37a a symlinked grant hook is never reported as an active grant" PASS ;;
    *) check "A37a a symlinked grant hook is never reported as an active grant" FAIL ;;
  esac
else
  check "A37a a symlinked grant hook is refused (SKIPPED — no real symlink)" FAIL
fi

# ── A38 the ✅ row's frontmatter claim is now BACKED, not asserted ────────────
# The row says "Each is confined to Read/Grep/Glob by its agent frontmatter" while the
# renderer never opened a file under agents/. It is true only because the module now drops
# any member whose frontmatter is not exactly the read trio — so a tampered agent must
# vanish from the rendered list while the untampered ones stay granted. Withholding the
# whole row would be the wrong fix: the other agents are legitimately confined.
mk_root "$SBOX/root-tampered" module nomodule
cp -R "$PLUGIN_DIR/agents" "$SBOX/root-tampered/agents"
cp "$PLUGIN_DIR/hooks/lib/reviewer-spawn-denial-v1.js" "$SBOX/root-tampered/hooks/lib/"
cp "$PLUGIN_DIR/hooks/lib/claude-principal-v1.js" "$SBOX/root-tampered/hooks/lib/"
cp "$PLUGIN_DIR/hooks/pre-agent-reviewer-allow.sh" "$SBOX/root-tampered/hooks/"
DOC_UNTAMPERED="$(doctor_at "$SBOX/root-tampered")"
case "$DOC_UNTAMPERED" in
  *"zensu:review-judge"*)
    check "A38pre the untampered root lists review-judge among the granted (control)" PASS ;;
  *) check "A38pre the untampered root lists review-judge among the granted (control)" FAIL ;;
esac
perl -0pi -e 's/^tools:.*$/tools: Read, Grep, Glob, Bash/m' "$SBOX/root-tampered/agents/review-judge.md"
grep -qF 'tools: Read, Grep, Glob, Bash' "$SBOX/root-tampered/agents/review-judge.md" \
  && check "A38tamper the fixture edit landed (re-read, not assumed)" PASS \
  || check "A38tamper the fixture edit landed (re-read, not assumed)" FAIL
DOC_TAMPERED="$(doctor_at "$SBOX/root-tampered")"
case "$DOC_TAMPERED" in
  *"zensu:review-judge"*)
    check "A38 an agent armed beyond the read trio is dropped from the granted set" FAIL ;;
  *) check "A38 an agent armed beyond the read trio is dropped from the granted set" PASS ;;
esac
case "$DOC_TAMPERED" in
  *"admits its own read-only reviewer spawns (zensu:code-reviewer,"*)
    check "A38a the remaining confined agents stay granted" PASS ;;
  *) check "A38a the remaining confined agents stay granted" FAIL ;;
esac

# ── A39 the hook's own stderr stays clean, and its read is bounded ───────────
# Every sibling PreToolUse hook in this tree spells the read `$(cat 2>/dev/null || true)`.
# This one took the bare form, so a payload carrying a NUL byte puts bash's own
# "ignored null byte in input" warning on the channel the hook otherwise reserves for its
# single deliberate loud branch — the inherited-plugin-root mismatch.
A39_ERR="$(printf 'x\000y' \
  | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
    CLAUDE_PROJECT_DIR="$PROJECT" ZENSU_CONFIG="$NO_CONFIG" \
    bash "$HOOK" 2>&1 >/dev/null)"
[ -z "$A39_ERR" ] && check "A39 a payload with a NUL byte leaves the hook's stderr clean" PASS \
  || check "A39 a payload with a NUL byte leaves the hook's stderr clean" FAIL

# The module's MAX_PAYLOAD_BYTES bounds the LAST of three full copies of the payload; the
# shell holds the first with no ceiling at all. Pinned at source because the memory bound
# is not observable from the outside, and the sibling technique already exists in
# hooks/lib/zensu-config.sh.
if grep -qE 'head -c' "$HOOK"; then
  check "A39a the hook caps its stdin read at the shell boundary" PASS
else
  check "A39a the hook caps its stdin read at the shell boundary" FAIL
fi

# ── A40 the cheapest condition runs before the ones that cost processes ──────
# All four conditions are conjunctive, so this is a cost ordering with no behavioural
# signature — every decline path emits identical silence either way. Pinned at source
# because there is nothing observable to assert: an ordinary Agent spawn that names no
# confined reviewer must not pay a principal read, a Session Control bind and two node
# starts to be refused by a check that reads stdin alone.
A40_DEC="$(grep -n 'node ./reviewer-spawn-allow-v1.js' "$HOOK" | head -1 | cut -d: -f1)"
A40_BIND="$(grep -n 'zensu_bind_hook_session' "$HOOK" | head -1 | cut -d: -f1)"
A40_PRIN="$(grep -n 'zensu_hook_is_main_principal' "$HOOK" | head -1 | cut -d: -f1)"
A40_CFG="$(grep -n 'zensu_hook_enabled_strict' "$HOOK" | head -1 | cut -d: -f1)"
if [ -n "$A40_DEC" ] && [ -n "$A40_BIND" ] && [ -n "$A40_PRIN" ] && [ -n "$A40_CFG" ] \
   && [ "$A40_DEC" -lt "$A40_BIND" ] && [ "$A40_DEC" -lt "$A40_PRIN" ] \
   && [ "$A40_DEC" -lt "$A40_CFG" ]; then
  check "A40 the decider precedes the principal, session and config conditions" PASS
else
  check "A40 the decider precedes the principal, session and config conditions" FAIL
fi

# ── A41 the capability disclosure is not silenceable by an unrelated flag ────
# hooks.sessionBanner is a NOISE control — "hide this banner", usage hints, the skills
# list — and it is read permissively, so a .zensu/config.json travelling inside a checked
# out repository can set it. The grant's own reader was made sticky and fail-closed
# precisely so such a file cannot RE-ARM the bypass; nothing stopped it HIDING the
# announcement while the bypass stayed active. A capability the plugin hands itself is
# disclosed on its own terms or not at all.
printf '{"hooks":{"sessionBanner":false}}\n' > "$SBOX/nobanner.json"
BANNER_QUIET="$(banner "$SBOX/nobanner.json")"
case "$BANNER_QUIET" in
  *"Zensu PLM v"*)
    check "A41pre the noise half of the banner IS silenced (control)" FAIL ;;
  *) check "A41pre the noise half of the banner IS silenced (control)" PASS ;;
esac
case "$BANNER_QUIET" in
  *"Reviewer spawns"*)
    check "A41 the grant disclosure survives hooks.sessionBanner=false" PASS ;;
  *) check "A41 the grant disclosure survives hooks.sessionBanner=false" FAIL ;;
esac

# A41a the banner is the SECOND of exactly two production callers of the fail-closed
# reader, and the unpinned one: A21/A22/A36 all pass identically under either reader, so
# without this pair the choice could be reverted here with every check green.
if grep -qF 'zensu_hook_enabled_strict reviewerSpawnAutoAllow' "$BANNER"; then
  check "A41a the banner reads the flag through zensu_hook_enabled_strict" PASS
else
  check "A41a the banner reads the flag through zensu_hook_enabled_strict" FAIL
fi
if grep -qE '(^|[^_])zensu_hook_enabled reviewerSpawnAutoAllow' "$BANNER"; then
  check "A41b the permissive reader is not used on this key in the banner" FAIL
else
  check "A41b the permissive reader is not used on this key in the banner" PASS
fi

echo "----"
echo "test-reviewer-spawn-allow: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
