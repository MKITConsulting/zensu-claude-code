#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REMINDER="$PLUGIN_DIR/hooks/user-prompt-tdd-reminder.sh"
PLANHOOK="$PLUGIN_DIR/hooks/plan-approved-delegate.sh"
HELPER="$PLUGIN_DIR/hooks/lib/zensu-delivery-route.sh"
DOCTOR="$PLUGIN_DIR/hooks/lib/zensu-doctor.sh"
CONFIG_LIB="$PLUGIN_DIR/hooks/lib/zensu-config.sh"
DIRECTIVE_LIB="$PLUGIN_DIR/hooks/lib/zensu-directive.sh"
LINKED_LIB="$PLUGIN_DIR/hooks/lib/zensu-linked-session.sh"
RESOLVER="$PLUGIN_DIR/hooks/lib/linked-session-v1.js"
CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

PASS=0; FAIL=0; SKIP=0
check() {
  case "$2" in
    (PASS) echo "  PASS  $1"; PASS=$((PASS+1)) ;;
    (SKIP) echo "  SKIP  $1"; SKIP=$((SKIP+1)) ;;
    (*) echo "  FAIL  $1"; FAIL=$((FAIL+1)) ;;
  esac
}
finish() {
  echo "----"
  echo "test-linked-session-route: $PASS PASS / $FAIL FAIL / $SKIP SKIP"
  [ "$FAIL" -eq 0 ]
}

if ! command -v node >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  check "L0 node and git are available" FAIL
  finish; exit
fi
PLATFORM="$(node -p process.platform 2>/dev/null)"
if [ "$PLATFORM" = win32 ]; then
  check "L0 the desktop store layout this suite builds is POSIX-only, so native Windows stays unverified" SKIP
  finish; exit
fi

echo "== Static: module, library, marker templates =="
{ [ -f "$RESOLVER" ] && [ -f "$LINKED_LIB" ] && bash -n "$LINKED_LIB" && node --check "$RESOLVER"; } >/dev/null 2>&1 \
  && check "L1 the resolver module and the shell library exist and parse" PASS \
  || check "L1 the resolver module or the shell library is missing or does not parse" FAIL
L2_BAD=""
for needle in '.zensu/state/inherited-route-' '.zensu/state/linked-session-'; do
  grep -qF "$needle" "$CONFIG_LIB" || L2_BAD="$L2_BAD [$needle missing from zensu-config.sh]"
done
[ -z "$L2_BAD" ] && check "L2 both new marker path templates live in zensu-config.sh, where R8k in test-delivery-route.sh holds every marker leaf in every file type under hooks/" PASS \
  || check "L2 marker templates:$L2_BAD" FAIL
L3_VOCAB="$(node -e '
  const m = require(process.argv[1]);
  process.stdout.write([Object.values(m.KINDS).sort().join(","), Object.values(m.REPOSITORY).sort().join(",")].join(" "));
' "$RESOLVER" 2>/dev/null)"
[ "$L3_VOCAB" = "linked,none,unresolved foreign,same,unknown" ] \
  && check "L3 the resolver answers only the documented kinds and repository verdicts" PASS \
  || check "L3 resolver vocabulary ($L3_VOCAB)" FAIL
L3B_OUT="$(node -e '
  const m = require(process.argv[1]);
  const show = (platform, env) => m.storeCandidates(platform, env).join("|");
  process.stdout.write([
    show("darwin", { HOME: "/h" }),
    show("win32", { HOME: "/h", APPDATA: "/a", LOCALAPPDATA: "/l" }),
    show("linux", { HOME: "/h", XDG_CONFIG_HOME: "/x" }),
    show("linux", { HOME: "/h", XDG_CONFIG_HOME: "relative" }),
    show("linux", {}) || "none",
  ].join("\n"));
' "$RESOLVER" 2>/dev/null)"
L3B_WANT="$(printf '%s\n' '/h/Library/Application Support/Claude/claude-code-sessions' \
  '/a/Claude/claude-code-sessions|/l/Claude/claude-code-sessions' \
  '/x/Claude/claude-code-sessions|/h/.config/Claude/claude-code-sessions' \
  '/h/.config/Claude/claude-code-sessions' 'none')"
[ "$L3B_OUT" = "$L3B_WANT" ] \
  && check "L3b the store candidates per platform: macOS Application Support, Windows APPDATA then LOCALAPPDATA, Linux XDG_CONFIG_HOME then ~/.config, never a relative base" PASS \
  || check "L3b store candidates ($(printf '%s' "$L3B_OUT" | tr '\n' ';'))" FAIL
L3C_OUT="$(node -e '
  const m = require(process.argv[1]);
  const show = (platform, env) => m.storeCandidates(platform, env).join("|") || "none";
  process.stdout.write([
    show("darwin", { HOME: "/h", ZENSU_CCD_STORE: " /s/store " }),
    show("linux", { HOME: "/h", XDG_CONFIG_HOME: "/x", ZENSU_CCD_STORE: "/s/store" }),
    show("win32", { APPDATA: "/a", ZENSU_CCD_STORE: "/d/store" }),
    show("linux", { HOME: "/h", ZENSU_CCD_STORE: "relative/store" }),
    show("darwin", { HOME: "/h", ZENSU_CCD_STORE: "   " }),
  ].join("\n"));
' "$RESOLVER" 2>/dev/null)"
L3C_WANT="$(printf '%s\n' '/s/store' '/s/store' 'D:/store' 'none' '/h/Library/Application Support/Claude/claude-code-sessions')"
[ "$L3C_OUT" = "$L3C_WANT" ] \
  && check "L3c ZENSU_CCD_STORE is the only candidate when set, as session-trail reads it: trimmed, MSYS drive mapped on win32, a relative value names no store, a blank one is ignored" PASS \
  || check "L3c store override ($(printf '%s' "$L3C_OUT" | tr '\n' ';'))" FAIL
L3D_LITERALS="$(grep -c 'zensu\.session-control' "$RESOLVER" 2>/dev/null || true)"
L3D_FROM_CORE="$(grep -cE 'controlCore\(\)\.SCHEMA\b.*controlCore\(\)\.SCHEMA_VERSION\b' "$RESOLVER" 2>/dev/null || true)"
[ "$L3D_LITERALS" = "0" ] && [ "${L3D_FROM_CORE:-0}" -ge 1 ] \
  && check "L3d the resolver spells no Session Control schema of its own and takes the name and version from the core" PASS \
  || check "L3d schema source (literals=$L3D_LITERALS from-core=$L3D_FROM_CORE)" FAIL
L3E_OUT="$(node -e '
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const m = require(process.argv[1]);
  const core = require(process.argv[2]);
  const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "linked-hash-")));
  try {
    const account = "11111111-1111-4111-8111-111111111111";
    const organization = "22222222-2222-4222-8222-222222222222";
    const childHost = "local_33333333-3333-4333-8333-333333333333";
    const parentHost = "local_44444444-4444-4444-8444-444444444444";
    const childCli = "55555555-5555-4555-8555-555555555555";
    const parentCli = "66666666-6666-4666-8666-666666666666";
    const store = path.join(scratch, "store");
    const desk = path.join(store, account, organization);
    fs.mkdirSync(desk, { recursive: true });
    fs.writeFileSync(path.join(desk, parentHost + ".json"), JSON.stringify({ sessionId: parentHost, cliSessionId: parentCli }));
    fs.writeFileSync(path.join(desk, childHost + ".json"), JSON.stringify({ sessionId: childHost, cliSessionId: childCli, spawnedFrom: { sessionId: parentHost } }));
    const records = path.join(scratch, "records");
    const root = path.join(scratch, "root");
    fs.mkdirSync(records);
    fs.mkdirSync(root);
    const record = path.join(records, core.sessionKey(parentCli) + ".json");
    const env = { CLAUDE_CODE_HOST_SESSION_ID: childHost, CLAUDE_CODE_ACCOUNT_UUID: account, CLAUDE_CODE_ORGANIZATION_UUID: organization, ZENSU_CCD_STORE: store };
    const resolve = (change) => {
      const context = { schema: core.SCHEMA, schema_version: core.SCHEMA_VERSION, host: "claude", session_id_hash: core.sessionIdHash(parentCli), project_root: root };
      change(context);
      fs.writeFileSync(record, JSON.stringify(context));
      const v = m.resolveLinkedSession({ env, sessionId: childCli, pluginData: scratch, deps: { recordsDirectory: () => records } });
      return v.kind + "/" + v.reason + "/" + (v.parentRoot === root ? "root" : "-");
    };
    process.stdout.write([
      resolve(() => {}),
      resolve((c) => { c.session_id_hash = core.sessionIdHash(childCli); }),
      resolve((c) => { delete c.session_id_hash; }),
      resolve((c) => { c.schema = "zensu.workflow-state"; }),
      resolve((c) => { delete c.schema; }),
      resolve((c) => { c.schema_version = core.SCHEMA_VERSION + 1; }),
      resolve((c) => { delete c.schema_version; }),
      resolve((c) => { c.host = "codex"; }),
      resolve((c) => { delete c.host; }),
    ].join("\n"));
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
' "$RESOLVER" "$CORE" 2>/dev/null)"
L3E_WANT="$(printf '%s\n' 'linked/resolved/root' 'linked/parent-context-unavailable/-' 'linked/parent-context-unavailable/-' 'linked/parent-context-unavailable/-' 'linked/parent-context-unavailable/-' 'linked/parent-context-unavailable/-' 'linked/parent-context-unavailable/-' 'linked/parent-context-unavailable/-' 'linked/parent-context-unavailable/-')"
[ "$L3E_OUT" = "$L3E_WANT" ] \
  && check "L3e a parent record whose session hash, schema, schema version or host is another one or missing leaves the session linked and uninherited, while the matching record resolves" PASS \
  || check "L3e parent identity ($(printf '%s' "$L3E_OUT" | tr '\n' ';'))" FAIL
L3F_INNER='
  const cp = require("child_process");
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const m = require(process.argv[1]);
  const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "linked-fifo-")));
  try {
    const account = "11111111-1111-4111-8111-111111111111";
    const organization = "22222222-2222-4222-8222-222222222222";
    const host = "local_33333333-3333-4333-8333-333333333333";
    const desk = path.join(scratch, "store", account, organization);
    fs.mkdirSync(desk, { recursive: true });
    const own = path.join(desk, host + ".json");
    cp.execFileSync("mkfifo", [own]);
    const realLstat = fs.lstatSync;
    const regular = realLstat(process.argv[1]);
    let hits = 0;
    fs.lstatSync = (target, ...rest) => {
      if (target !== own) return realLstat(target, ...rest);
      hits += 1;
      return regular;
    };
    const env = { CLAUDE_CODE_HOST_SESSION_ID: host, CLAUDE_CODE_ACCOUNT_UUID: account, CLAUDE_CODE_ORGANIZATION_UUID: organization, ZENSU_CCD_STORE: path.join(scratch, "store") };
    const v = m.resolveLinkedSession({ env, sessionId: "55555555-5555-4555-8555-555555555555", pluginData: scratch });
    process.stdout.write(v.kind + "/" + v.reason + "/" + (hits > 0 ? "stubbed" : "unstubbed"));
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
'
L3F_OUT="$(node -e '
  const r = require("child_process").spawnSync(process.execPath, ["-e", process.argv[1], process.argv[2]], { encoding: "utf8", timeout: 20000 });
  process.stdout.write(r.error && r.error.code === "ETIMEDOUT" ? "blocked" : String(r.status) + ":" + r.stdout);
' "$L3F_INNER" "$RESOLVER" 2>/dev/null)"
[ "$L3F_OUT" = "0:none/own-record-refused/stubbed" ] \
  && check "L3f a desktop record swapped for a FIFO after its lstat, which the stub saw, is refused at once instead of blocking the open" PASS \
  || check "L3f FIFO swapped in after lstat ($L3F_OUT)" FAIL
L3G_OUT="$(node -e '
  const fs = require("fs");
  const os = require("os");
  const path = require("path");
  const m = require(process.argv[1]);
  const core = require(process.argv[2]);
  const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "linked-again-")));
  try {
    const account = "11111111-1111-4111-8111-111111111111";
    const organization = "22222222-2222-4222-8222-222222222222";
    const childHost = "local_33333333-3333-4333-8333-333333333333";
    const parentHost = "local_44444444-4444-4444-8444-444444444444";
    const childCli = "55555555-5555-4555-8555-555555555555";
    const parentCli = "66666666-6666-4666-8666-666666666666";
    const store = path.join(scratch, "store");
    const desk = path.join(store, account, organization);
    fs.mkdirSync(desk, { recursive: true });
    fs.writeFileSync(path.join(desk, parentHost + ".json"), JSON.stringify({ sessionId: parentHost, cliSessionId: parentCli }));
    fs.writeFileSync(path.join(desk, childHost + ".json"), JSON.stringify({ sessionId: childHost, cliSessionId: childCli, spawnedFrom: { sessionId: parentHost } }));
    const records = path.join(scratch, "records");
    const root = path.join(scratch, "root");
    fs.mkdirSync(records);
    fs.mkdirSync(root);
    fs.writeFileSync(path.join(records, core.sessionKey(parentCli) + ".json"), JSON.stringify({ schema: core.SCHEMA, schema_version: core.SCHEMA_VERSION, host: "claude", session_id_hash: core.sessionIdHash(parentCli), project_root: root }));
    const env = { CLAUDE_CODE_HOST_SESSION_ID: childHost, CLAUDE_CODE_ACCOUNT_UUID: account, CLAUDE_CODE_ORGANIZATION_UUID: organization, ZENSU_CCD_STORE: store };
    const realRead = fs.readSync;
    const resolve = (failures) => {
      let left = failures;
      let thrown = 0;
      fs.readSync = (...args) => {
        if (left > 0) {
          left -= 1;
          thrown += 1;
          const error = new Error("resource temporarily unavailable");
          error.code = "EAGAIN";
          throw error;
        }
        return realRead(...args);
      };
      try {
        const v = m.resolveLinkedSession({ env, sessionId: childCli, pluginData: scratch, deps: { recordsDirectory: () => records } });
        return v.kind + "/" + v.reason + "/" + (v.parentRoot === root ? "root" : "-") + "/" + (thrown > 0 ? "stubbed" : "unstubbed");
      } finally {
        fs.readSync = realRead;
      }
    };
    process.stdout.write([resolve(3), resolve(Infinity)].join("\n"));
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
' "$RESOLVER" "$CORE" 2>/dev/null)"
L3G_WANT="$(printf '%s\n' 'linked/resolved/root/stubbed' 'unresolved/own-record-unreadable/-/stubbed')"
[ "$L3G_OUT" = "$L3G_WANT" ] \
  && check "L3g a read that answers would-block is retried: three EAGAIN answers still resolve, and one that never ends leaves the session unresolved for its one retry instead of refusing it for good" PASS \
  || check "L3g would-block reads ($(printf '%s' "$L3G_OUT" | tr '\n' ';'))" FAIL

T="$(mktemp -d 2>/dev/null)" || T=""
if [ -z "$T" ] || [ ! -d "$T" ]; then
  check "L0 mktemp -d created a scratch directory" FAIL
  finish; exit
fi
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT

unset CLAUDE_CODE_HOST_SESSION_ID CLAUDE_CODE_ACCOUNT_UUID CLAUDE_CODE_ORGANIZATION_UUID XDG_CONFIG_HOME ZENSU_CCD_STORE \
  CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR CLAUDE_AGENT_TYPE ZENSU_TDD_GATE ZENSU_CHAIN ZDOC_DELIVERY_ROUTE \
  2>/dev/null || true
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export HOME="$T/home"
mkdir -p "$HOME"
export ZENSU_TEST_PLUGIN_DATA="$T/plugin-data"
export CLAUDE_PLUGIN_DATA="$ZENSU_TEST_PLUGIN_DATA"
CFG_DEFAULT="$T/no-such-config.json"
CFG_NOREMIND="$T/cfg-noremind.json"
CFG_TDD="$T/cfg-tdd.json"
printf '%s' '{"hooks":{"tddReminder":false}}' > "$CFG_NOREMIND"
printf '%s' '{"hooks":{"defaultDeliveryRoute":"build"}}' > "$CFG_TDD"
export ZENSU_CONFIG="$CFG_DEFAULT"

git_q() {
  git -c user.email=fixture@example.invalid -c user.name=fixture -c init.defaultBranch=main \
    -c commit.gpgsign=false "$@" >/dev/null 2>&1
}
REPO="$T/repo"; WT="$T/worktree"; FOREIGN="$T/foreign"; NOGIT="$T/nogit"
mkdir -p "$REPO" "$FOREIGN" "$NOGIT"
if ! { git_q -C "$REPO" init && git_q -C "$REPO" commit --allow-empty -m init \
  && git_q -C "$REPO" worktree add -b linked "$WT" \
  && git_q -C "$FOREIGN" init && git_q -C "$FOREIGN" commit --allow-empty -m init; }; then
  check "L0 the git fixture (a repository, its worktree and a foreign repository) could be built" FAIL
  finish; exit
fi

case "$PLATFORM" in
  (darwin) STORE="$HOME/Library/Application Support/Claude/claude-code-sessions" ;;
  (*) STORE="$HOME/.config/Claude/claude-code-sessions" ;;
esac
ACCT="aaaaaaaa-1111-4111-8111-111111111111"
ORG="bbbbbbbb-2222-4222-8222-222222222222"
DESK="$STORE/$ACCT/$ORG"
mkdir -p "$DESK"

REAL_NODE="$(command -v node)"
SHIM="$T/shim"; TRACE="$T/node-trace.log"
mkdir -p "$SHIM"
cat > "$SHIM/node" <<SHIM_EOF
#!/bin/bash
printf '%s FIELD=%s\n' "\$*" "\${FIELD:-}" >> "$TRACE"
exec "$REAL_NODE" "\$@"
SHIM_EOF
chmod +x "$SHIM/node"
resolver_runs() { grep -c 'linked-session-v1.js' "$TRACE" 2>/dev/null || true; }
session_id_reads() { grep -c 'FIELD=session_id$' "$TRACE" 2>/dev/null || true; }

SEQ=0
next_id() { SEQ=$((SEQ+1)); ID="$(printf '%08x-0000-4000-8000-%012x' "$SEQ" "$SEQ")"; }
key_of() { "$REAL_NODE" "$CORE" session-key "$1"; }
register() {
  ( export CLAUDE_PROJECT_DIR="$2"; source "$BASELINE" "$1" ) >/dev/null 2>&1 \
    && [ -f "$CLAUDE_PLUGIN_DATA/session-control/v1/records/$(key_of "$1").json" ]
}
desk_record() {
  "$REAL_NODE" -e '
    const [file, host, cli, parent, turns] = process.argv.slice(1);
    const record = { sessionId: host, title: "fixture" };
    if (cli) record.cliSessionId = cli;
    if (parent) record.spawnedFrom = { sessionId: parent, taskId: "task_fixture", title: "fixture", sideSession: false, name: "fixture" };
    if (turns === "null") record.completedTurns = null;
    else if (turns) record.completedTurns = Number(turns);
    require("fs").writeFileSync(file, JSON.stringify(record));
  ' "$DESK/$1.json" "$1" "$2" "$3" "${4:-}"
}
session() {
  next_id; CLI="$ID"; HOST="local_$ID"
  register "$CLI" "$1" || return 1
  [ "${3:-}" = "--no-record" ] && return 0
  desk_record "$HOST" "$CLI" "${2:-}"
}
route() {
  CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PROJECT_DIR="$2" ZENSU_CONFIG="$CFG_DEFAULT" bash "$HELPER" "$3" 2>/dev/null
}
lib() { bash -c 'source "$0"; f="$1"; shift; "$f" "$@"' "$CONFIG_LIB" "$@"; }
linked_state() { lib zensu_linked_session_state "$1" "$(key_of "$2")"; }
inherited_state() { lib zensu_inherited_route_state "$1" "$(key_of "$2")"; }
linked_marker() { lib zensu_linked_session_marker_path "$1" "$(key_of "$2")"; }
ctx() {
  "$REAL_NODE" -e '
    let s = "";
    process.stdin.on("data", (c) => { s += c; });
    process.stdin.on("end", () => {
      try { process.stdout.write(JSON.parse(s).hookSpecificOutput.additionalContext || ""); } catch (_) {}
    });'
}
prompt_json() {
  "$REAL_NODE" -e 'process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",session_id:process.argv[1],prompt:process.argv[2]}))' "$1" "$2"
}
plan_json() {
  "$REAL_NODE" -e 'process.stdout.write(JSON.stringify({hook_event_name:"PostToolUse",session_id:process.argv[1],tool_name:"ExitPlanMode",tool_input:{plan:"Add a parser function to foo.js and call it from main."}}))' "$1"
}
HOOK_HOME="$HOME"
HOOK_ACCT="$ACCT"
hook() {
  local script="$1" root="$2" cli="$3" host="$4" payload="$5" config="${6:-$CFG_DEFAULT}"
  if [ -n "$host" ]; then
    printf '%s' "$payload" | HOME="$HOOK_HOME" CLAUDE_PROJECT_DIR="$root" CLAUDE_CODE_HOST_SESSION_ID="$host" \
      CLAUDE_CODE_ACCOUNT_UUID="$HOOK_ACCT" CLAUDE_CODE_ORGANIZATION_UUID="$ORG" ZENSU_CONFIG="$config" \
      PATH="$SHIM:$PATH" bash "$script" 2>/dev/null | ctx
  else
    printf '%s' "$payload" | HOME="$HOOK_HOME" CLAUDE_PROJECT_DIR="$root" ZENSU_CONFIG="$config" \
      PATH="$SHIM:$PATH" bash "$script" 2>/dev/null | ctx
  fi
}
remind() { hook "$REMINDER" "$1" "$2" "$3" "$(prompt_json "$2" "$4")" "${5:-}"; }
approve() { hook "$PLANHOOK" "$1" "$2" "$3" "$(plan_json "$2")" "${4:-}"; }
last_field() { printf '%s' "$1" | grep -o 'ZENSU DELIVERY ROUTE: [^<]*' | tail -1 | sed 's/[[:space:]]*$//'; }
LEAD="$(bash -c 'source "$0"; printf "%s" "${ZENSU_LINKED_BRIEF_LEAD:-}"' "$DIRECTIVE_LIB" 2>/dev/null)"
lead_count() { [ -n "$LEAD" ] || { echo 0; return; }; printf '%s' "$1" | grep -oF "$LEAD" | grep -c . || true; }
opens_with_lead() { [ -n "$LEAD" ] && [ "${1#"$LEAD "}" != "$1" ]; }
INHERITED='ZENSU DELIVERY ROUTE: build (inherited from parent session)'
ASK='ZENSU DELIVERY ROUTE: ask'

[ -n "$LEAD" ] && check "L4 zensu-directive.sh defines the brief lead" PASS \
  || check "L4 ZENSU_LINKED_BRIEF_LEAD is empty or missing" FAIL
case "$LEAD" in
  (*"brief another session wrote"*"not the user's own text"*"'/zensu:build'"*"'no tdd'"*"decides nothing"*)
    check "L5 the lead says the prompt is another session's brief and that a route preference in it decides nothing in either direction" PASS ;;
  (*) check "L5 lead wording ($LEAD)" FAIL ;;
esac

echo "== AC-001, AC-004, AC-005, AC-006: a linked session inherits build =="
if ! session "$REPO" ""; then
  check "L0 the parent session's Session Control record could be registered" FAIL
  finish; exit
fi
P_CLI="$CLI"; P_HOST="$HOST"
route "$P_CLI" "$REPO" --build >/dev/null
session "$WT" "$P_HOST"; C_CLI="$CLI"; C_HOST="$HOST"
: > "$TRACE"
A1="$(remind "$WT" "$C_CLI" "$C_HOST" "no tdd: add a parser to foo.js")"
A1_RUNS="$(resolver_runs)"
: > "$TRACE"
A2="$(remind "$WT" "$C_CLI" "$C_HOST" "add a function to foo.js")"
A2_RUNS="$(resolver_runs)"
if [ "$(last_field "$A1")" = "$INHERITED" ] && [ "$(inherited_state "$WT" "$C_CLI")" = build ] \
  && [ "$(linked_state "$WT" "$C_CLI")" = linked ] \
  && printf '%s' "$A1" | grep -qF 'route decided by the field below' \
  && ! printf '%s' "$A1" | grep -qF 'AskUserQuestion'; then
  check "L6 a session started from a parent that recorded build opens with the inherited route and is not asked" PASS
else
  check "L6 inheritance (field='$(last_field "$A1")' inherited=$(inherited_state "$WT" "$C_CLI") linked=$(linked_state "$WT" "$C_CLI"))" FAIL
fi
{ opens_with_lead "$A1" && [ "$(lead_count "$A1")" = 1 ]; } \
  && check "L7 the brief prompt opens with the brief note exactly once, even when the brief says 'no tdd'" PASS \
  || check "L7 brief note on the brief prompt (count=$(lead_count "$A1"))" FAIL
{ [ "$(lead_count "$A2")" = 0 ] && [ "$(last_field "$A2")" = "$INHERITED" ]; } \
  && check "L8 the next prompt carries no brief note and keeps the inherited route" PASS \
  || check "L8 later prompt (count=$(lead_count "$A2") field='$(last_field "$A2")')" FAIL
{ [ "$A1_RUNS" = 1 ] && [ "$A2_RUNS" = 0 ]; } \
  && check "L9 the lineage resolves with one resolver process on the first prompt and none on the next" PASS \
  || check "L9 resolver processes (first=$A1_RUNS next=$A2_RUNS)" FAIL

session "$REPO" "$C_HOST"; G_CLI="$CLI"; G_HOST="$HOST"
B1="$(remind "$REPO" "$G_CLI" "$G_HOST" "add a function to foo.js")"
{ [ "$(last_field "$B1")" = "$INHERITED" ] && [ "$(inherited_state "$REPO" "$G_CLI")" = build ]; } \
  && check "L10 a session two levels down inherits through its parent's inherited route" PASS \
  || check "L10 two-level inheritance (field='$(last_field "$B1")')" FAIL

session "$WT" "$P_HOST" --no-record
desk_record "$HOST" "" "$P_HOST"
NOCLI_OUT="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
[ "$(last_field "$NOCLI_OUT")" = "$INHERITED" ] \
  && check "L11 an own desktop record without cliSessionId is still bound by its host id and inherits" PASS \
  || check "L11 record without cliSessionId (field='$(last_field "$NOCLI_OUT")')" FAIL

echo "== AC-002: what is never inherited =="
parent_case() {
  session "$REPO" "" || return 1
  PC_CLI="$CLI"; PC_HOST="$HOST"
  local marker
  marker="$(lib zensu_delivery_route_marker_path "$REPO" "$(key_of "$PC_CLI")")"
  case "$1" in
    (direct) route "$PC_CLI" "$REPO" --direct >/dev/null ;;
    (released) route "$PC_CLI" "$REPO" --build >/dev/null; route "$PC_CLI" "$REPO" --auto >/dev/null ;;
    (none) : ;;
    (garbage) mkdir -p "$REPO/.zensu/state"; printf '%s' '{"route":"build' > "$marker" ;;
    (symlink)
      mkdir -p "$REPO/.zensu/state"; printf '%s\n' '{"route":"build"}' > "$T/build-target.json"
      ln -s "$T/build-target.json" "$marker" 2>/dev/null || return 2 ;;
    (direct-over-inherited)
      route "$PC_CLI" "$REPO" --direct >/dev/null
      printf '%s\n' '{"route":"build"}' > "$(lib zensu_inherited_route_marker_path "$REPO" "$(key_of "$PC_CLI")")" ;;
  esac
  session "$WT" "$PC_HOST" || return 1
  PCASE_OUT="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
  PCASE_INHERITED="$(inherited_state "$WT" "$CLI")"
  PCASE_LINKED="$(linked_state "$WT" "$CLI")"
}
L12_BAD=""
for state in direct released none garbage symlink direct-over-inherited; do
  parent_case "$state"; rc=$?
  if [ "$rc" -eq 2 ]; then
    check "L12 parent marker '$state' (this host cannot create a symlink)" SKIP
    continue
  fi
  if [ "$rc" -ne 0 ] || [ "$(last_field "$PCASE_OUT")" != "$ASK" ] || [ "$PCASE_INHERITED" != none ] \
    || [ "$PCASE_LINKED" != linked ] || ! opens_with_lead "$PCASE_OUT"; then
    L12_BAD="$L12_BAD [$state: rc=$rc field='$(last_field "$PCASE_OUT")' inherited=$PCASE_INHERITED linked=$PCASE_LINKED]"
  fi
done
[ -z "$L12_BAD" ] \
  && check "L12 a parent's direct, released, absent, unreadable or symlinked marker, and a direct over an inherited build, pass nothing on, while the brief note still applies" PASS \
  || check "L12 parent states:$L12_BAD" FAIL

parent_case none
session "$WT" ""
UNLINKED="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
if [ "$PCASE_OUT" = "$LEAD $UNLINKED" ] && printf '%s' "$UNLINKED" | grep -qF 'AskUserQuestion'; then
  check "L13 on the full reminder the brief note is one opening sentence and changes nothing else" PASS
else
  check "L13 full-text shape (linked=${#PCASE_OUT} chars, unlinked=${#UNLINKED} chars, lead=${#LEAD} chars)" FAIL
fi

repo_case() {
  session "$1" "" || return 1
  route "$CLI" "$1" --build >/dev/null
  local parent="$HOST"
  session "$WT" "$parent" || return 1
  RCASE_OUT="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
  RCASE_INHERITED="$(inherited_state "$WT" "$CLI")"
}
repo_case "$FOREIGN"
{ [ "$(last_field "$RCASE_OUT")" = "$ASK" ] && [ "$RCASE_INHERITED" = none ] && opens_with_lead "$RCASE_OUT"; } \
  && check "L14 a parent that recorded build in another repository passes nothing on" PASS \
  || check "L14 foreign repository (field='$(last_field "$RCASE_OUT")' inherited=$RCASE_INHERITED)" FAIL
repo_case "$NOGIT"
{ [ "$(last_field "$RCASE_OUT")" = "$ASK" ] && [ "$RCASE_INHERITED" = none ]; } \
  && check "L15 a parent root that is not a git work tree passes nothing on" PASS \
  || check "L15 non-git parent root (field='$(last_field "$RCASE_OUT")' inherited=$RCASE_INHERITED)" FAIL

session "$WT" "local_$(printf '%08x-0000-4000-8000-%012x' 4095 4095)"
MISSING_PARENT="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
{ [ "$(last_field "$MISSING_PARENT")" = "$ASK" ] && [ "$(linked_state "$WT" "$CLI")" = linked ] \
  && opens_with_lead "$MISSING_PARENT"; } \
  && check "L16 a parent without a desktop record leaves the session linked, noted and uninherited" PASS \
  || check "L16 missing parent record (field='$(last_field "$MISSING_PARENT")' linked=$(linked_state "$WT" "$CLI"))" FAIL

NOUUID_PARENT="local_$(printf '%08x-0000-4000-8000-%012x' 4094 4094)"
desk_record "$NOUUID_PARENT" "not-a-uuid" ""
session "$WT" "$NOUUID_PARENT"
PARENT_NOUUID="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
{ [ "$(last_field "$PARENT_NOUUID")" = "$ASK" ] && [ "$(linked_state "$WT" "$CLI")" = linked ]; } \
  && check "L17 a parent record whose cliSessionId is no UUID leaves the session linked and uninherited" PASS \
  || check "L17 parent cli id not a UUID (field='$(last_field "$PARENT_NOUUID")')" FAIL

GONE="$T/gone-root"
mkdir -p "$GONE"
session "$GONE" ""
route "$CLI" "$GONE" --build >/dev/null
GONE_PARENT="$HOST"
rm -rf "$GONE"
session "$WT" "$GONE_PARENT"
GONE_OUT="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
{ [ "$(last_field "$GONE_OUT")" = "$ASK" ] && [ "$(inherited_state "$WT" "$CLI")" = none ] \
  && [ "$(linked_state "$WT" "$CLI")" = linked ] && opens_with_lead "$GONE_OUT"; } \
  && check "L17b a parent whose recorded project root was removed leaves the session linked, noted and uninherited" PASS \
  || check "L17b removed parent root (field='$(last_field "$GONE_OUT")' linked=$(linked_state "$WT" "$CLI"))" FAIL
next_id
UNREGISTERED_PARENT="local_$ID"
desk_record "$UNREGISTERED_PARENT" "$ID" ""
session "$WT" "$UNREGISTERED_PARENT"
NOCTX_OUT="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
{ [ "$(last_field "$NOCTX_OUT")" = "$ASK" ] && [ "$(linked_state "$WT" "$CLI")" = linked ] \
  && opens_with_lead "$NOCTX_OUT"; } \
  && check "L17c a parent without a Session Control record leaves the session linked, noted and uninherited" PASS \
  || check "L17c parent without a Session Control record (field='$(last_field "$NOCTX_OUT")' linked=$(linked_state "$WT" "$CLI"))" FAIL

fault_case() {
  local label="$1" out state
  out="$2"; state="$3"
  if [ "$(last_field "$out")" = "$ASK" ] && [ "$(lead_count "$out")" = 0 ] && [ "$state" = none ]; then
    FAULT_GOOD="$FAULT_GOOD [$label]"
  else
    FAULT_BAD="$FAULT_BAD [$label: field='$(last_field "$out")' lead=$(lead_count "$out") state=$state]"
  fi
}
FAULT_GOOD=""; FAULT_BAD=""
session "$WT" ""
OUT_UNLINKED="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
fault_case not-linked "$OUT_UNLINKED" "$(linked_state "$WT" "$CLI")"
: > "$TRACE"
remind "$WT" "$CLI" "$HOST" "add a function to foo.js" >/dev/null
UNLINKED_RUNS="$(resolver_runs)"
session "$WT" "$P_HOST" --no-record
desk_record "$HOST" "$(printf '%08x-0000-4000-8000-%012x' 4093 4093)" "$P_HOST"
fault_case cli-mismatch "$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")" "$(linked_state "$WT" "$CLI")"
session "$WT" "$P_HOST"
fault_case malformed-host "$(remind "$WT" "$CLI" "local_NOT-A-UUID" "add a function to foo.js")" "$(linked_state "$WT" "$CLI")"
session "$WT" "$P_HOST"
HOOK_ACCT="not-a-uuid"
fault_case malformed-account "$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")" "$(linked_state "$WT" "$CLI")"
HOOK_ACCT="$ACCT"
session "$WT" "$P_HOST" --no-record
desk_record "$HOST" "$CLI" "$P_HOST"
mv "$DESK/$HOST.json" "$T/own-record-target.json"
if ln -s "$T/own-record-target.json" "$DESK/$HOST.json" 2>/dev/null; then
  fault_case symlinked-record "$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")" "$(linked_state "$WT" "$CLI")"
else
  check "L18 a symlinked own record (this host cannot create a symlink)" SKIP
fi
session "$WT" "$P_HOST" --no-record
head -c 8388609 /dev/zero > "$DESK/$HOST.json"
fault_case oversized-record "$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")" "$(linked_state "$WT" "$CLI")"
rm -f "$DESK/$HOST.json"
HOME2="$T/home-linked-store"
case "$PLATFORM" in
  (darwin) STORE2_PARENT="$HOME2/Library/Application Support/Claude" ;;
  (*) STORE2_PARENT="$HOME2/.config/Claude" ;;
esac
mkdir -p "$STORE2_PARENT"
session "$WT" "$P_HOST"
if ln -s "$STORE" "$STORE2_PARENT/claude-code-sessions" 2>/dev/null; then
  HOOK_HOME="$HOME2"
  fault_case symlinked-store "$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")" "$(linked_state "$WT" "$CLI")"
  HOOK_HOME="$HOME"
else
  check "L18 a symlinked session store (this host cannot create a symlink)" SKIP
fi
session "$WT" "" --no-record
desk_record "$HOST" "$CLI" "$HOST"
fault_case self-parent "$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")" "$(linked_state "$WT" "$CLI")"
mkdir -p "$T/home-without-store"
session "$WT" "$P_HOST"
HOOK_HOME="$T/home-without-store"
fault_case no-store "$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")" "$(linked_state "$WT" "$CLI")"
HOOK_HOME="$HOME"
[ -z "$FAULT_BAD" ] \
  && check "L18 every own-side lineage fault answers none, final, with no note and today's route:$FAULT_GOOD" PASS \
  || check "L18 lineage faults:$FAULT_BAD" FAIL
[ "$UNLINKED_RUNS" = 0 ] \
  && check "L19 a resolved unlinked session starts no resolver process on its next prompt" PASS \
  || check "L19 unlinked session next prompt ran the resolver $UNLINKED_RUNS time(s)" FAIL

parent_case none
CFG_OUT="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js" "$CFG_TDD")"
{ [ "$(last_field "$CFG_OUT")" = "ZENSU DELIVERY ROUTE: build (hooks.defaultDeliveryRoute)" ] \
  && [ "$(inherited_state "$WT" "$CLI")" = none ]; } \
  && check "L20 a linked session that inherits nothing still takes the configured default" PASS \
  || check "L20 configured default (field='$(last_field "$CFG_OUT")')" FAIL

echo "== D8: a missing own record is retried once =="
session "$WT" "$P_HOST" --no-record
R_CLI="$CLI"; R_HOST="$HOST"
: > "$TRACE"
R1="$(remind "$WT" "$R_CLI" "$R_HOST" "add a function to foo.js")"
R1_STATE="$(linked_state "$WT" "$R_CLI")"
desk_record "$R_HOST" "$R_CLI" "$P_HOST"
R2="$(remind "$WT" "$R_CLI" "$R_HOST" "add a function to foo.js")"
R_RUNS="$(resolver_runs)"
if [ "$R1_STATE" = unresolved ] && [ "$(last_field "$R1")" = "$ASK" ] && [ "$(lead_count "$R1")" = 0 ] \
  && [ "$(last_field "$R2")" = "$INHERITED" ] && [ "$(lead_count "$R2")" = 0 ] \
  && [ "$(linked_state "$WT" "$R_CLI")" = linked ] && [ "$R_RUNS" = 2 ]; then
  check "L21 a record that appears after the first prompt is picked up on the retry, which inherits and adds no brief note" PASS
else
  check "L21 retry (first=$R1_STATE '$(last_field "$R1")' second='$(last_field "$R2")' lead=$(lead_count "$R2") runs=$R_RUNS)" FAIL
fi
session "$WT" "$P_HOST" --no-record
: > "$TRACE"
remind "$WT" "$CLI" "$HOST" "add a function to foo.js" >/dev/null
remind "$WT" "$CLI" "$HOST" "add a function to foo.js" >/dev/null
TWICE_STATE="$(linked_state "$WT" "$CLI")"
remind "$WT" "$CLI" "$HOST" "add a function to foo.js" >/dev/null
TWICE_RUNS="$(resolver_runs)"
{ [ "$TWICE_STATE" = none ] && [ "$TWICE_RUNS" = 2 ]; } \
  && check "L22 a record still missing on the retry is given up as none, so a third prompt starts no resolver" PASS \
  || check "L22 bounded retry (state=$TWICE_STATE runs=$TWICE_RUNS)" FAIL
session "$WT" "$P_HOST" --no-record
printf '%s' '{"sessionId":' > "$DESK/$HOST.json"
UNPARSED="$(remind "$WT" "$CLI" "$HOST" "add a function to foo.js")"
{ [ "$(linked_state "$WT" "$CLI")" = unresolved ] && [ "$(lead_count "$UNPARSED")" = 0 ] \
  && [ "$(last_field "$UNPARSED")" = "$ASK" ]; } \
  && check "L22b an own record that does not parse is held as unresolved for the one retry, with no note" PASS \
  || check "L22b unparsable own record (state=$(linked_state "$WT" "$CLI") field='$(last_field "$UNPARSED")')" FAIL

echo "== AC-005, AC-006: outside the desktop app =="
session "$WT" "$P_HOST"
: > "$TRACE"
TERM_OUT="$(remind "$WT" "$CLI" "" "add a function to foo.js")"
TERM_RUNS="$(resolver_runs)"
TERM_MARKER="$(linked_marker "$WT" "$CLI")"
{ [ "$TERM_RUNS" = 0 ] && [ ! -e "$TERM_MARKER" ] && [ "$(lead_count "$TERM_OUT")" = 0 ] \
  && [ "$(last_field "$TERM_OUT")" = "$ASK" ]; } \
  && check "L23 a session without CLAUDE_CODE_HOST_SESSION_ID starts no resolver, writes no marker and gets no note" PASS \
  || check "L23 terminal session (runs=$TERM_RUNS marker=$([ -e "$TERM_MARKER" ] && echo present || echo absent))" FAIL

echo "== AC-003, AC-007: override, release and disclosure =="
session "$WT" "$P_HOST"; H_CLI="$CLI"; H_HOST="$HOST"
remind "$WT" "$H_CLI" "$H_HOST" "add a function to foo.js" >/dev/null
H_STATUS="$(route "$H_CLI" "$WT" --status)"
H_DOCTOR="$(CLAUDE_CODE_SESSION_ID="$H_CLI" CLAUDE_PROJECT_DIR="$WT" ZENSU_CONFIG="$CFG_DEFAULT" bash "$DOCTOR" 2>/dev/null)"
[ "$H_STATUS" = "build (inherited from parent session)" ] \
  && check "L24 /zensu:delivery-route --status names the inherited source" PASS \
  || check "L24 --status ($H_STATUS)" FAIL
printf '%s' "$H_DOCTOR" | grep -F 'delivery route: build (inherited from parent session)' | grep -qF '✅' \
  && check "L25 the /zensu:doctor session row names the inherited source, green" PASS \
  || check "L25 doctor row ($(printf '%s' "$H_DOCTOR" | grep -o 'delivery route: [^—]*' | head -1))" FAIL
route "$H_CLI" "$WT" --direct >/dev/null
H_DIRECT_FIELD="$(last_field "$(remind "$WT" "$H_CLI" "$H_HOST" "add a function to foo.js")")"
H_DIRECT_STATUS="$(route "$H_CLI" "$WT" --status)"
route "$H_CLI" "$WT" --auto >/dev/null
H_AUTO_FIELD="$(last_field "$(remind "$WT" "$H_CLI" "$H_HOST" "add a function to foo.js")")"
H_AUTO_STATUS="$(route "$H_CLI" "$WT" --status)"
{ [ "$H_DIRECT_FIELD" = "ZENSU DELIVERY ROUTE: direct (session marker)" ] && [ "$H_DIRECT_STATUS" = "direct (session)" ]; } \
  && check "L26 the linked session's own marker outranks the inherited route" PASS \
  || check "L26 own marker over inherited (field='$H_DIRECT_FIELD' status='$H_DIRECT_STATUS')" FAIL
{ [ "$H_AUTO_FIELD" = "$ASK" ] && [ "$H_AUTO_STATUS" = "ask (default, session choice released)" ] \
  && [ "$(inherited_state "$WT" "$H_CLI")" = build ]; } \
  && check "L27 --auto in the linked session releases the inherited route too, back to the question" PASS \
  || check "L27 release (field='$H_AUTO_FIELD' status='$H_AUTO_STATUS')" FAIL

echo "== D8, D14: the plan gate resolves the lineage when the reminder is off =="
session "$WT" "$P_HOST"; Q_CLI="$CLI"; Q_HOST="$HOST"
Q_REMIND="$(remind "$WT" "$Q_CLI" "$Q_HOST" "add a function to foo.js" "$CFG_NOREMIND")"
: > "$TRACE"
Q_PLAN="$(approve "$WT" "$Q_CLI" "$Q_HOST" "$CFG_NOREMIND")"
Q_READS="$(session_id_reads)"; Q_RUNS="$(resolver_runs)"
{ [ -z "$Q_REMIND" ] && printf '%s' "$Q_PLAN" | grep -qF "$INHERITED" && [ "$(lead_count "$Q_PLAN")" = 0 ] \
  && [ "$(linked_state "$WT" "$Q_CLI")" = linked ]; } \
  && check "L28 with tddReminder off the plan gate resolves the lineage, dispatches on the inherited route and adds no brief note" PASS \
  || check "L28 plan gate (reminder='${Q_REMIND:0:40}' field='$(last_field "$Q_PLAN")' lead=$(lead_count "$Q_PLAN") linked=$(linked_state "$WT" "$Q_CLI"))" FAIL
{ [ "$Q_READS" = 1 ] && [ "$Q_RUNS" = 1 ]; } \
  && check "L28b the resolving plan approval reads the payload session id once and starts one resolver" PASS \
  || check "L28b resolving approval (session-id reads=$Q_READS resolver=$Q_RUNS)" FAIL

echo "== R1-F1: the plan gate starts no process for a lineage that is not pending =="
session "$WT" ""; W_CLI="$CLI"
: > "$TRACE"
approve "$WT" "$W_CLI" "" >/dev/null
W_READS="$(session_id_reads)"; W_RUNS="$(resolver_runs)"
{ [ "$W_READS" = 1 ] && [ "$W_RUNS" = 0 ]; } \
  && check "L31 a plan approval outside the desktop app reads the payload session id once and starts no resolver" PASS \
  || check "L31 terminal approval (session-id reads=$W_READS resolver=$W_RUNS)" FAIL
: > "$TRACE"
approve "$WT" "$C_CLI" "$C_HOST" >/dev/null
V_READS="$(session_id_reads)"; V_RUNS="$(resolver_runs)"
{ [ "$V_READS" = 1 ] && [ "$V_RUNS" = 0 ]; } \
  && check "L32 a plan approval in a session whose lineage is resolved reads the payload session id once and starts no resolver" PASS \
  || check "L32 resolved approval (session-id reads=$V_READS resolver=$V_RUNS)" FAIL

echo "== R1-F11: the brief note follows the desktop's completed turns =="
session "$WT" "$P_HOST"; N_CLI="$CLI"; N_HOST="$HOST"
remind "$WT" "$N_CLI" "$N_HOST" "add a function to foo.js" >/dev/null
desk_record "$N_HOST" "$N_CLI" "$P_HOST" 1
rm -f "$(linked_marker "$WT" "$N_CLI")" "$(lib zensu_inherited_route_marker_path "$WT" "$(key_of "$N_CLI")")"
N_AGAIN="$(remind "$WT" "$N_CLI" "$N_HOST" "add a function to foo.js")"
{ [ "$(lead_count "$N_AGAIN")" = 0 ] && [ "$(last_field "$N_AGAIN")" = "$INHERITED" ] \
  && [ "$(linked_state "$WT" "$N_CLI")" = linked ]; } \
  && check "L29 a lineage resolved again after its markers vanished, with a completed turn on record, inherits and adds no brief note" PASS \
  || check "L29 lost markers (lead=$(lead_count "$N_AGAIN") field='$(last_field "$N_AGAIN")' linked=$(linked_state "$WT" "$N_CLI"))" FAIL
next_id; K_CLI="$ID"
if register "$K_CLI" "$WT"; then
  desk_record "$N_HOST" "$K_CLI" "$P_HOST" 2
  K_OUT="$(remind "$WT" "$K_CLI" "$N_HOST" "add a function to foo.js")"
  { [ "$(lead_count "$K_OUT")" = 0 ] && [ "$(last_field "$K_OUT")" = "$INHERITED" ]; } \
    && check "L30 a new CLI session id under the same desktop session inherits and adds no brief note" PASS \
    || check "L30 re-keyed session (lead=$(lead_count "$K_OUT") field='$(last_field "$K_OUT")')" FAIL
else
  check "L30 the re-keyed session's Session Control record could be registered" FAIL
fi

echo "== R1-F13: a plugin data root reached through a symlinked parent =="
if ln -s "$T" "$T/alias-root" 2>/dev/null; then
  session "$WT" "$P_HOST"; S_CLI="$CLI"; S_HOST="$HOST"
  S_OUT="$(export CLAUDE_PLUGIN_DATA="$T/alias-root/plugin-data"; remind "$WT" "$S_CLI" "$S_HOST" "add a function to foo.js")"
  { [ "$(last_field "$S_OUT")" = "$INHERITED" ] && [ "$(inherited_state "$WT" "$S_CLI")" = build ]; } \
    && check "L33 a CLAUDE_PLUGIN_DATA reached through a symlinked parent directory still finds the parent's record and inherits" PASS \
    || check "L33 aliased plugin data (field='$(last_field "$S_OUT")' inherited=$(inherited_state "$WT" "$S_CLI"))" FAIL
else
  check "L33 a plugin data root behind a symlinked parent (this host cannot create a symlink)" SKIP
fi

echo "== R1-F2: ZENSU_CCD_STORE names the desktop store, as /zensu:session-trail reads it =="
session "$WT" "$P_HOST"; O_CLI="$CLI"; O_HOST="$HOST"
O_OUT="$(export ZENSU_CCD_STORE="$STORE"; HOOK_HOME="$T/home-without-store"; remind "$WT" "$O_CLI" "$O_HOST" "add a function to foo.js")"
{ [ "$(last_field "$O_OUT")" = "$INHERITED" ] && [ "$(linked_state "$WT" "$O_CLI")" = linked ]; } \
  && check "L34 ZENSU_CCD_STORE names the desktop store when the home directory holds none, and the session inherits" PASS \
  || check "L34 store override (field='$(last_field "$O_OUT")' linked=$(linked_state "$WT" "$O_CLI"))" FAIL
mkdir -p "$T/empty-store"
session "$WT" "$P_HOST"; E_CLI="$CLI"; E_HOST="$HOST"
E_OUT="$(export ZENSU_CCD_STORE="$T/empty-store"; remind "$WT" "$E_CLI" "$E_HOST" "add a function to foo.js")"
{ [ "$(last_field "$E_OUT")" = "$ASK" ] && [ "$(linked_state "$WT" "$E_CLI")" = none ] && [ "$(lead_count "$E_OUT")" = 0 ]; } \
  && check "L35 an override naming a directory without the store is authoritative: no fallback to the home store, answered none" PASS \
  || check "L35 authoritative override (field='$(last_field "$E_OUT")' linked=$(linked_state "$WT" "$E_CLI"))" FAIL

echo "== R1-F3: the substitution fallback keeps the brief note =="
FAILNODE="$T/failnode"
mkdir -p "$FAILNODE"
printf '%s\n' '#!/bin/bash' 'exit 1' > "$FAILNODE/node"
chmod +x "$FAILNODE/node"
L36_BAD=""
for body in '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "Reminder. ZENSU DELIVERY ROUTE: __ZENSU_DELIVERY_ROUTE__"}}' \
  '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Reminder. ZENSU DELIVERY ROUTE: __ZENSU_DELIVERY_ROUTE__"}}'; do
  L36_OUT="$(printf '%s' "$body" | PATH="$FAILNODE:$PATH" bash -c 'source "$1"; zensu_delivery_route_substitute ask "$2" "$3"' _ "$DIRECTIVE_LIB" cmd "$LEAD" 2>/dev/null | ctx)"
  [ "$L36_OUT" = "$LEAD Reminder. ZENSU DELIVERY ROUTE: ask" ] || L36_BAD="$L36_BAD [${L36_OUT:0:60}]"
done
[ -z "$L36_BAD" ] \
  && check "L36 when node cannot substitute, the fallback still opens the context with the brief note, in both opener spellings" PASS \
  || check "L36 fallback lead:$L36_BAD" FAIL

echo "== R1-F4: an unwritable lineage cache starts no resolver =="
RO="$T/ro-worktree"
if git_q -C "$REPO" worktree add -b ro "$RO" && session "$RO" "$P_HOST"; then
  RO_CLI="$CLI"; RO_HOST="$HOST"
  mkdir -p "$RO/.zensu/state"
  chmod 500 "$RO/.zensu/state"
  if [ -w "$RO/.zensu/state" ]; then
    chmod 700 "$RO/.zensu/state"
    check "L37 an unwritable lineage cache (this host lets the suite write into a mode-500 directory)" SKIP
  else
    : > "$TRACE"
    RO_1="$(remind "$RO" "$RO_CLI" "$RO_HOST" "add a function to foo.js")"
    remind "$RO" "$RO_CLI" "$RO_HOST" "add a function to foo.js" >/dev/null
    RO_3="$(remind "$RO" "$RO_CLI" "$RO_HOST" "add a function to foo.js")"
    RO_RUNS="$(resolver_runs)"
    chmod 700 "$RO/.zensu/state"
    { [ "$RO_RUNS" = 0 ] && [ "$(last_field "$RO_1")" = "$ASK" ] && [ "$(lead_count "$RO_1")" = 0 ] \
      && [ "$(last_field "$RO_3")" = "$ASK" ]; } \
      && check "L37 a session whose lineage cache cannot be written starts no resolver over three prompts and keeps today's route without a note" PASS \
      || check "L37 unwritable cache (runs=$RO_RUNS first='$(last_field "$RO_1")' lead=$(lead_count "$RO_1") third='$(last_field "$RO_3")')" FAIL
  fi
else
  check "L37 the second worktree and its Session Control record could be built" FAIL
fi

echo "== R1-F5: which prompt origins carry the brief note =="
session "$WT" "$P_HOST"; SL_CLI="$CLI"; SL_HOST="$HOST"
SL_OUT="$(remind "$WT" "$SL_CLI" "$SL_HOST" "/zensu:build add a parser to foo.js")"
{ opens_with_lead "$SL_OUT" && [ "$(lead_count "$SL_OUT")" = 1 ] && [ "$(last_field "$SL_OUT")" = "$INHERITED" ]; } \
  && check "L38 a brief that is a slash command with arguments opens with the brief note once" PASS \
  || check "L38 slash-command brief (lead=$(lead_count "$SL_OUT") field='$(last_field "$SL_OUT")')" FAIL
session "$WT" "$P_HOST"; CM_CLI="$CLI"; CM_HOST="$HOST"
CM_1="$(remind "$WT" "$CM_CLI" "$CM_HOST" "<ci-monitor-event>CI failed on pull request 1</ci-monitor-event>")"
CM_STATE="$(linked_state "$WT" "$CM_CLI")"
CM_2="$(remind "$WT" "$CM_CLI" "$CM_HOST" "add a function to foo.js")"
{ [ "$CM_STATE" = linked ] && [ "$(lead_count "$CM_1")" = 0 ] && [ "$(lead_count "$CM_2")" = 0 ] \
  && [ "$(last_field "$CM_1")" = "$INHERITED" ] && [ "$(last_field "$CM_2")" = "$INHERITED" ]; } \
  && check "L39 a CI-monitor event that resolves the lineage carries no brief note, and neither does the next typed prompt" PASS \
  || check "L39 CI-monitor first (state=$CM_STATE lead=$(lead_count "$CM_1")/$(lead_count "$CM_2") field='$(last_field "$CM_1")')" FAIL
session "$WT" "$P_HOST"; PF_CLI="$CLI"; PF_HOST="$HOST"
: > "$TRACE"
PF_PLAN="$(approve "$WT" "$PF_CLI" "$PF_HOST")"
PF_NEXT="$(remind "$WT" "$PF_CLI" "$PF_HOST" "add a function to foo.js")"
PF_RUNS="$(resolver_runs)"
{ [ "$(linked_state "$WT" "$PF_CLI")" = linked ] && [ "$(lead_count "$PF_PLAN")" = 0 ] && [ "$(lead_count "$PF_NEXT")" = 0 ] \
  && [ "$(last_field "$PF_NEXT")" = "$INHERITED" ] && [ "$PF_RUNS" = 1 ]; } \
  && check "L40 with the reminder on, a plan approval that resolves the lineage first leaves no brief note for the next typed prompt" PASS \
  || check "L40 plan gate first (linked=$(linked_state "$WT" "$PF_CLI") lead=$(lead_count "$PF_NEXT") field='$(last_field "$PF_NEXT")' runs=$PF_RUNS)" FAIL

echo "== R2-F3: a record that counts no completed turn yet, and the plan gate's retry =="
L41_BAD=""
for turns in 0 null; do
  session "$WT" "$P_HOST" --no-record; Z_CLI="$CLI"; Z_HOST="$HOST"
  desk_record "$Z_HOST" "$Z_CLI" "$P_HOST" "$turns"
  Z_OUT="$(remind "$WT" "$Z_CLI" "$Z_HOST" "add a function to foo.js")"
  { opens_with_lead "$Z_OUT" && [ "$(lead_count "$Z_OUT")" = 1 ]; } || L41_BAD="$L41_BAD [completedTurns=$turns lead=$(lead_count "$Z_OUT")]"
done
[ -z "$L41_BAD" ] \
  && check "L41 an own record whose completedTurns is 0 or null still counts as the first turn and carries the brief note" PASS \
  || check "L41 first-turn values:$L41_BAD" FAIL
session "$WT" "$P_HOST"; U_CLI="$CLI"; U_HOST="$HOST"
mkdir -p "$WT/.zensu/state"
printf '%s\n' '{"state":"unresolved"}' > "$(linked_marker "$WT" "$U_CLI")"
: > "$TRACE"
U_PLAN="$(approve "$WT" "$U_CLI" "$U_HOST" "$CFG_NOREMIND")"
U_RUNS="$(resolver_runs)"
{ [ "$(linked_state "$WT" "$U_CLI")" = linked ] && printf '%s' "$U_PLAN" | grep -qF "$INHERITED" \
  && [ "$U_RUNS" = 1 ] && [ "$(lead_count "$U_PLAN")" = 0 ]; } \
  && check "L42 with the reminder off, the plan gate retries an unresolved lineage once, links it and dispatches on the inherited route" PASS \
  || check "L42 plan gate retry (linked=$(linked_state "$WT" "$U_CLI") runs=$U_RUNS)" FAIL

finish
