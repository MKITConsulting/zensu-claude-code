#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/user-prompt-session-hub-takeover-notice.sh"
MODULE="$PLUGIN_DIR/hooks/lib/session-hub-takeover-notice-v1.js"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
MINT="$PLUGIN_DIR/hooks/session-start-session-control.sh"
HUB_CONTRACT="$PLUGIN_DIR/plugins/session-hub/skills/session-trail/handover-contract.json"
HUB_RECEIPT="$PLUGIN_DIR/plugins/session-hub/hooks/lib/session-hub-receipt-v1.mjs"

SBOX="$(mktemp -d -t hubnotice-XXXXXX)"
SBOX="$(cd "$SBOX" && pwd -P)"
export CLAUDE_PLUGIN_DATA="$SBOX/plugin-data"
mkdir -p "$CLAUDE_PLUGIN_DATA"
export HOME="$SBOX/home"
mkdir -p "$HOME"
unset ZENSU_BASH_WRITE_GATE ZENSU_MCP_GATE CLAUDE_PROJECT_DIR ZENSU_CONFIG ZENSU_PROJECT_ROOT ZENSU_SESSION_KEY
ON_CONFIG="$SBOX/on.json"
printf '%s\n' '{"hooks":{"bashWriteGate":true}}' > "$ON_CONFIG"
OFF_CONFIG="$SBOX/off.json"
printf '%s\n' '{"hooks":{"bashWriteGate":false}}' > "$OFF_CONFIG"
STRING_CONFIG="$SBOX/string.json"
printf '%s\n' '{"hooks":{"bashWriteGate":"true"}}' > "$STRING_CONFIG"
NO_CONFIG="$SBOX/.no-such-config.json"
PROJECT="$SBOX/project"
mkdir -p "$PROJECT"
trap 'rm -rf "$SBOX"' EXIT

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
finish() {
  echo "----"
  echo "test-session-hub-takeover-notice: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

for f in "$HOOK" "$MODULE" "$HOOKS_JSON" "$MINT" "$HUB_CONTRACT" "$HUB_RECEIPT"; do
  if [ ! -f "$f" ]; then
    check "N0 required file exists: $f" FAIL
    finish; exit 1
  fi
done
check "N0 the hook, its module, hooks.json, the session-control minter and the companion's contract and receipt entry exist" PASS

[ -x "$HOOK" ] && check "N1 the hook is executable" PASS || check "N1 the hook is executable" FAIL
bash -n "$HOOK" 2>/dev/null && check "N1 bash -n accepts the hook" PASS || check "N1 bash -n accepts the hook" FAIL
if [ -x /bin/bash ]; then
  /bin/bash -n "$HOOK" 2>/dev/null && check "N1 /bin/bash -n accepts the hook" PASS || check "N1 /bin/bash -n accepts the hook" FAIL
fi
node --check "$MODULE" 2>/dev/null && check "N1 node --check accepts the module" PASS || check "N1 node --check accepts the module" FAIL

REG="$(node -e '
  const h = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const hits = [];
  for (const [event, groups] of Object.entries(h.hooks || {})) {
    for (const group of groups || []) {
      for (const hook of group.hooks || []) {
        if (String(hook.command || "").includes("user-prompt-session-hub-takeover-notice.sh")) hits.push(`${event}:${group.matcher || "none"}:${hook.timeout}`);
      }
    }
  }
  process.stdout.write(hits.join(","));
' "$HOOKS_JSON" 2>/dev/null)"
[ "$REG" = "UserPromptSubmit:none:10" ] \
  && check "N2 hooks.json registers the hook once, on UserPromptSubmit, with timeout 10" PASS \
  || check "N2 hooks.json registers the hook once, on UserPromptSubmit, with timeout 10 (got $REG)" FAIL

payload() {
  PROMPT="$1" SID="$2" CWD="$3" KIND="${4:-main}" node -e '
    const o = { hook_event_name: "UserPromptSubmit", session_id: process.env.SID, cwd: process.env.CWD, prompt: process.env.PROMPT, transcript_path: "/nonexistent" };
    if (process.env.KIND === "subagent") { o.agent_id = "agent-1"; o.agent_type = "code-reviewer"; }
    process.stdout.write(JSON.stringify(o));
  '
}
run_hook() {
  local cfg="$1"
  shift
  env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$cfg" "$@" bash "$HOOK"
}
context_of() {
  node -e '
    let s = "";
    process.stdin.on("data", (c) => { s += c; }).on("end", () => {
      try {
        const j = JSON.parse(s);
        const h = j && j.hookSpecificOutput;
        const keys = Object.keys(j || {}).join(",");
        if (keys !== "hookSpecificOutput" || !h || h.hookEventName !== "UserPromptSubmit") { process.stdout.write("BAD-SHAPE"); return; }
        process.stdout.write(String(h.additionalContext || ""));
      } catch (_) { process.stdout.write("NOT-JSON"); }
    });
  '
}

SID_FREE="0b6c1f2e-1111-4222-8333-444455556666"
TOKEN="0123456789abcdef0123456789abcdef"
TARGET="7d0b8a52-1111-4222-8333-444455556666"
HUB_PROMPT="/session-hub:session-trail takeover $TARGET --all --receipt $TOKEN"
TAG_PROMPT="$(printf '<command-message>session-hub:session-trail</command-message>\n<command-name>/session-hub:session-trail</command-name>\n<command-args>takeover %s --all</command-args>' "$TARGET")"
REMINDED_PROMPT="$(printf '<system-reminder>\nlinked sessions now\n</system-reminder>\n/session-hub:session-trail takeover %s' "$TARGET")"

SID_BOUND="hubnotice-$$-$RANDOM"
payload "start" "$SID_BOUND" "$PROJECT" | node -e '
  let s = ""; process.stdin.on("data", (c) => { s += c; }).on("end", () => {
    const o = JSON.parse(s); o.hook_event_name = "SessionStart"; o.source = "startup"; delete o.prompt;
    process.stdout.write(JSON.stringify(o));
  });
' | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$NO_CONFIG" bash "$MINT" >/dev/null 2>&1

notice_ok() {
  local ctx="$1"
  case "$ctx" in
    *"hooks.bashWriteGate: true"*"outside this session's Session Control root"*"/zensu:adopt-session --reanchor"*"--confirm"*) return 0 ;;
  esac
  return 1
}
unbound_notice_ok() {
  local ctx="$1"
  case "$ctx" in
    *"hooks.bashWriteGate: true"*"no usable Session Control record"*"/zensu:doctor"*"plan confirmation"*) ;;
    *) return 1 ;;
  esac
  case "$ctx" in
    *"--reanchor"*|*"$PROJECT"*) return 1 ;;
  esac
  return 0
}

OUT="$(payload "$HUB_PROMPT" "$SID_BOUND" "$PROJECT" | run_hook "$ON_CONFIG" 2>/dev/null)"; RC=$?
CTX="$(printf '%s' "$OUT" | context_of)"
[ "$RC" -eq 0 ] && notice_ok "$CTX" \
  && check "N3 the Session Hub's exact takeover command gets one notice naming the refusal and the reanchor" PASS \
  || check "N3 the Session Hub's exact takeover command gets one notice naming the refusal and the reanchor (rc=$RC out=${OUT:0:200})" FAIL
[ "$(printf '%s' "$OUT" | grep -c 'hookSpecificOutput')" = "1" ] \
  && check "N3 the hook prints exactly one JSON object" PASS \
  || check "N3 the hook prints exactly one JSON object" FAIL

for spec in \
  "N4 a hand-typed takeover with a selector|/session-hub:session-trail takeover abc12345" \
  "N4 a bare takeover|/session-hub:session-trail takeover" \
  "N4 a takeover separated by a tab|$(printf '/session-hub:session-trail\ttakeover abc')"; do
  label="${spec%%|*}"; prompt="${spec#*|}"
  CTX="$(payload "$prompt" "$SID_BOUND" "$PROJECT" | run_hook "$ON_CONFIG" 2>/dev/null | context_of)"
  notice_ok "$CTX" && check "$label gets the notice" PASS || check "$label gets the notice (got ${CTX:0:160})" FAIL
done

CTX="$(payload "$TAG_PROMPT" "$SID_BOUND" "$PROJECT" | run_hook "$ON_CONFIG" 2>/dev/null | context_of)"
notice_ok "$CTX" && check "N5 the command-tag form gets the notice" PASS || check "N5 the command-tag form gets the notice (got ${CTX:0:160})" FAIL
CTX="$(payload "$REMINDED_PROMPT" "$SID_BOUND" "$PROJECT" | run_hook "$ON_CONFIG" 2>/dev/null | context_of)"
notice_ok "$CTX" && check "N5 a takeover behind leading system reminders gets the notice" PASS || check "N5 a takeover behind leading system reminders gets the notice (got ${CTX:0:160})" FAIL

silent_case() {
  local label="$1" prompt="$2" cfg="$3" kind="${4:-main}"
  shift 4
  local out rc
  out="$(payload "$prompt" "$SID_BOUND" "$PROJECT" "$kind" | run_hook "$cfg" "$@" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] && check "$label stays silent with exit 0" PASS || check "$label stays silent with exit 0 (rc=$rc out=${out:0:160})" FAIL
}
silent_case "N6 PLM's own takeover command" "/zensu:session-trail takeover $TARGET --all --receipt $TOKEN" "$ON_CONFIG" main
silent_case "N6 another companion verb" "/session-hub:session-trail list" "$ON_CONFIG" main
silent_case "N6 a show that names takeover later" "/session-hub:session-trail show takeover" "$ON_CONFIG" main
silent_case "N6 a command name glued to the verb" "/session-hub:session-trailtakeover abc" "$ON_CONFIG" main
silent_case "N6 a longer verb" "/session-hub:session-trail takeovers abc" "$ON_CONFIG" main
silent_case "N6 prose that quotes the command" "please run /session-hub:session-trail takeover abc" "$ON_CONFIG" main
silent_case "N6 PLM's command in the tag form" "$(printf '<command-name>/zensu:session-trail</command-name>\n<command-args>takeover abc</command-args>')" "$ON_CONFIG" main
silent_case "N6 a tag form with text outside the tags" "$(printf '%s\nand also this' "$TAG_PROMPT")" "$ON_CONFIG" main
silent_case "N6 a tag form with a repeated tag" "$(printf '%s\n<command-args>takeover abc</command-args>' "$TAG_PROMPT")" "$ON_CONFIG" main
silent_case "N6 an empty prompt" "" "$ON_CONFIG" main
silent_case "N7 the gate switched off" "$HUB_PROMPT" "$OFF_CONFIG" main
silent_case "N7 no config at all" "$HUB_PROMPT" "$NO_CONFIG" main
silent_case "N7 a quoted \"true\"" "$HUB_PROMPT" "$STRING_CONFIG" main
silent_case "N8 ZENSU_BASH_WRITE_GATE=off in the environment" "$HUB_PROMPT" "$ON_CONFIG" main ZENSU_BASH_WRITE_GATE=off
silent_case "N8 ZENSU_MCP_GATE=off in the environment" "$HUB_PROMPT" "$ON_CONFIG" main ZENSU_MCP_GATE=off
silent_case "N9 a subagent payload" "$HUB_PROMPT" "$ON_CONFIG" subagent

OUT="$(printf '%s' '{"prompt": "/session-hub:session-trail takeover' | run_hook "$ON_CONFIG" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && check "N9 a payload that is not JSON stays silent with exit 0" PASS || check "N9 a payload that is not JSON stays silent with exit 0 (rc=$RC)" FAIL

CTX="$(payload "$HUB_PROMPT" "$SID_FREE" "$PROJECT" | run_hook "$ON_CONFIG" 2>/dev/null | context_of)"
unbound_notice_ok "$CTX" \
  && check "N10 a session with no usable Session Control record gets the unbound notice: /zensu:doctor, no reanchor, no root path" PASS \
  || check "N10 a session with no usable Session Control record gets the unbound notice: /zensu:doctor, no reanchor, no root path (got ${CTX:0:240})" FAIL

CTX="$(payload "$HUB_PROMPT" "$SID_BOUND" "$PROJECT" | run_hook "$ON_CONFIG" 2>/dev/null | context_of)"
case "$CTX" in
  *"outside this session's Session Control root, \"$PROJECT\". "*) check "N10 a bound session's notice names its recorded root in double quotes" PASS ;;
  *) check "N10 a bound session's notice names its recorded root in double quotes (got ${CTX:0:240})" FAIL ;;
esac

SHIM="$SBOX/shim"
mkdir -p "$SHIM"
REAL_NODE="$(command -v node)"
FLAG="$SBOX/node-started"
cat > "$SHIM/node" <<SHIM_END
#!/bin/bash
: > "$FLAG"
exec "$REAL_NODE" "\$@"
SHIM_END
chmod 755 "$SHIM/node"
PAYLOAD_PLAIN="$(payload "write the release notes" "$SID_FREE" "$PROJECT")"
PAYLOAD_HUB="$(payload "$HUB_PROMPT" "$SID_FREE" "$PROJECT")"
rm -f "$FLAG"
printf '%s' "$PAYLOAD_PLAIN" | run_hook "$ON_CONFIG" PATH="$SHIM:$PATH" >/dev/null 2>&1
[ ! -e "$FLAG" ] && check "N11 a prompt that does not name the companion's command starts no node" PASS || check "N11 a prompt that does not name the companion's command starts no node" FAIL
rm -f "$FLAG"
printf '%s' "$PAYLOAD_HUB" | run_hook "$ON_CONFIG" PATH="$SHIM:$PATH" >/dev/null 2>&1
[ -e "$FLAG" ] && check "N11 control: the takeover prompt does reach node through the shim" PASS || check "N11 control: the takeover prompt does reach node through the shim" FAIL

UNIT="$(cd "$PLUGIN_DIR/hooks/lib" && node -e '
  const m = require("./session-hub-takeover-notice-v1.js");
  const bad = [];
  if (m.COMMAND_NAME !== "/session-hub:session-trail") bad.push("command-name");
  const plain = m.noticeText("");
  if (!plain.includes("Session Control root. ")) bad.push("empty-root");
  if (m.noticeText("/a/b\u001b[2Jc").includes("/a/b")) bad.push("control-root");
  if (m.noticeText("/a/b\u2028c").includes("/a/b")) bad.push("separator-root");
  if (m.noticeText("/" + "x".repeat(5000)).includes("xxxx")) bad.push("long-root");
  if (m.noticeText("/a/\"b").includes("/a/\"b")) bad.push("quote-root");
  if (!m.noticeText("/work/tree").includes("root, \"/work/tree\". ")) bad.push("plain-root");
  if (m.noticeText("/work/tree").includes("stays writable")) bad.push("writable-claim");
  if (!m.noticeText("/work/tree").includes("Inside that root the gate still refuses a raw Bash overwrite of a git-tracked source file; in a worktree outside it this takeover can edit and test but not commit.")) bad.push("clobber-rule");
  const unbound = m.noticeText("/work/tree", false);
  if (unbound.includes("/work/tree") || unbound.includes("--reanchor")) bad.push("unbound-advice");
  if (!unbound.includes("no usable Session Control record") || !unbound.includes("/zensu:doctor")) bad.push("unbound-text");
  if (m.decide("[]", {}) !== null) bad.push("array-payload");
  if (m.decide("null", {}) !== null) bad.push("null-payload");
  if (m.decide("{\"prompt\":42}", {}) !== null) bad.push("number-prompt");
  const big = JSON.stringify({ prompt: "/session-hub:session-trail takeover " + "a".repeat(300 * 1024) });
  if (m.decide(big, {}) !== null) bad.push("oversized");
  if (!m.isTakeoverPrompt("  /session-hub:session-trail   takeover  x  ")) bad.push("spaced");
  if (m.isTakeoverPrompt("<system-reminder>unclosed /session-hub:session-trail takeover x")) bad.push("unclosed-reminder");
  const out = m.decide(JSON.stringify({ prompt: "/session-hub:session-trail takeover x" }), { ZENSU_NOTICE_ROOT: "/r" });
  if (!out || Object.keys(out).join() !== "hookSpecificOutput" || Object.keys(out.hookSpecificOutput).join() !== "hookEventName,additionalContext") bad.push("shape");
  else if (!out.hookSpecificOutput.additionalContext.includes("root, \"/r\". ")) bad.push("decide-bound");
  const off = m.decide(JSON.stringify({ prompt: "/session-hub:session-trail takeover x" }), { ZENSU_NOTICE_ROOT: "/r", ZENSU_NOTICE_BOUND: "0" });
  if (!off || off.hookSpecificOutput.additionalContext !== m.noticeText("/r", false)) bad.push("decide-unbound");
  process.stdout.write(bad.length ? bad.join(",") : "ok");
' 2>&1)"
[ "$UNIT" = "ok" ] && check "N12 the module withholds an unsafe root, quotes a safe one, states that the clobber rule still applies inside the root, renders the unbound variant, refuses malformed and oversized payloads and keeps the output shape" PASS \
  || check "N12 the module withholds an unsafe root, quotes a safe one, states that the clobber rule still applies inside the root, renders the unbound variant, refuses malformed and oversized payloads and keeps the output shape ($UNIT)" FAIL

NAMES="$(cd "$PLUGIN_DIR" && node -e '
  const fs = require("fs");
  const path = require("path");
  const { pathToFileURL } = require("url");
  (async () => {
    const contract = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const prefix = contract && contract.takeover && contract.takeover.prefix;
    const verb = " takeover ";
    if (typeof prefix !== "string" || !prefix.endsWith(verb) || prefix.length <= verb.length) { process.stdout.write("bad-prefix"); return; }
    const name = prefix.slice(0, -verb.length);
    const notice = require(path.resolve(process.argv[2]));
    const receipt = await import(pathToFileURL(path.resolve(process.argv[3])).href);
    const hook = fs.readFileSync(process.argv[4], "utf8");
    const q = String.fromCharCode(39);
    const bad = [];
    if (notice.COMMAND_NAME !== name) bad.push("notice");
    if (receipt.COMMAND_NAME !== name) bad.push("receipt");
    if (receipt.TAKEOVER_PREFIX !== prefix) bad.push("receipt-prefix");
    if (!hook.includes("*" + q + name + q + "*")) bad.push("hook-prefilter");
    process.stdout.write(bad.length ? bad.join(",") : "ok:" + name);
  })().catch((error) => process.stdout.write("error:" + error.message));
' "$HUB_CONTRACT" "$MODULE" "$HUB_RECEIPT" "$HOOK" 2>&1)"
[ "$NAMES" = "ok:/session-hub:session-trail" ] \
  && check "N13 the notice module, the hook's prefilter and the companion's receipt entry name the command its contract-2 takeover prefix declares" PASS \
  || check "N13 the notice module, the hook's prefilter and the companion's receipt entry name the command its contract-2 takeover prefix declares ($NAMES)" FAIL

finish
