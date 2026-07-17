#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
PATHS="$ROOT/hooks/lib/claude-path-v1.js"
HOST_PATH="$ROOT/hooks/lib/zensu-host-path.sh"
PHASE="$ROOT/hooks/lib/zensu-tdd-phase.sh"
POST_REVIEW="$ROOT/hooks/post-review-tdd-delegate.sh"
STOP_ENFORCER="$ROOT/hooks/stop-chain-enforcer.sh"
PRE_EDIT="$ROOT/hooks/pre-edit-tdd-reminder.sh"
BANNER="$ROOT/hooks/session-start-banner.sh"
AGENT_CONTEXT="$ROOT/hooks/lib/zensu-agent-context.sh"
SESSION_BINDING="$ROOT/hooks/lib/zensu-session.sh"
AUTOPILOT_RESUME="$ROOT/hooks/session-start-autopilot-resume.sh"
CONFIG_LIB="$ROOT/hooks/lib/zensu-config.sh"
PLAN_SKILL="$ROOT/skills/plan-review/SKILL.md"
PR_SKILL="$ROOT/skills/pr-team-review/SKILL.md"
PASS=0
FAIL=0

check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

if [ -f "$PATHS" ] && [ ! -L "$PATHS" ] \
    && [ -f "$HOST_PATH" ] && [ ! -L "$HOST_PATH" ] && [ -x "$HOST_PATH" ]; then
  check "shared native-host path boundaries exist" PASS
else
  check "shared native-host path boundaries exist" FAIL
fi

if [ -f "$PATHS" ] && PATHS="$PATHS" node -e '
  const paths = require(process.env.PATHS);
  const cases = [
    ["/d/a/plugin root", "D:/a/plugin root"],
    ["/C/Users/name", "C:/Users/name"],
    ["D:\\a\\plugin", "D:\\a\\plugin"],
    ["//server/share/plugin", "\\\\server\\share\\plugin"],
    ["\\\\server\\share\\plugin", "\\\\server\\share\\plugin"],
    ["\\\\?\\C:\\plugin", "C:\\plugin"],
    ["//?/UNC/server/share/plugin", "\\\\server\\share\\plugin"],
    ["src/app.js", "src/app.js"],
  ];
  for (const [input, expected] of cases) {
    if (paths.normalizeHostPathInput(input, "fixture", "win32") !== expected) process.exit(1);
  }
  for (const input of [
    "/tmp/plugin", "\\rooted", "//server", "\\\\server", "///foo", "C:plugin",
    "\\\\.\\PhysicalDrive0", "//./pipe/name", "\\\\?\\GLOBALROOT\\Device\\HarddiskVolume1",
    "//?/GLOBALROOT/Device/HarddiskVolume1", "\\\\?\\UNC\\server",
    "\\\\?\\UNC\\.\\pipe\\name", "//?/UNC/?/GLOBALROOT/Device/name",
  ]) {
    let rejected = false;
    try { paths.normalizeHostPathInput(input, "fixture", "win32"); }
    catch { rejected = true; }
    if (!rejected) process.exit(1);
  }
  if (paths.normalizeHostPathInput("/tmp/plugin", "fixture", "linux") !== "/tmp/plugin") process.exit(1);
'; then
  check "MSYS drives and complete UNC paths normalize narrowly; ambiguous roots fail closed" PASS
else
  check "MSYS drives and complete UNC paths normalize narrowly; ambiguous roots fail closed" FAIL
fi

HOST_FIXTURE="$(mktemp -d -t zensu-host-path-XXXXXX)"
HOST_EXPECTED="$(cd -P -- "$HOST_FIXTURE" && pwd -P)"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) HOST_EXPECTED="$(cygpath -am "$HOST_EXPECTED")" ;;
esac
HOST_RENDERED="$(bash "$HOST_PATH" "$HOST_FIXTURE" 2>/dev/null)"
if [ "$HOST_RENDERED" = "$HOST_EXPECTED" ] \
    && [ -d "$HOST_RENDERED" ] \
    && node -e 'require("node:fs").realpathSync.native(process.argv[1])' "$HOST_RENDERED"; then
  check "temporary review workspace is rendered in a native-Node-readable spelling" PASS
else
  check "temporary review workspace is rendered in a native-Node-readable spelling" FAIL
fi

HOST_NEGATIVE_OK=true
touch "$HOST_FIXTURE/not-a-directory"
bash "$HOST_PATH" "$HOST_FIXTURE/missing" >/dev/null 2>&1 && HOST_NEGATIVE_OK=false
bash "$HOST_PATH" "$HOST_FIXTURE/not-a-directory" >/dev/null 2>&1 && HOST_NEGATIVE_OK=false
if ln -s "$HOST_FIXTURE" "$HOST_FIXTURE/directory-alias" 2>/dev/null; then
  bash "$HOST_PATH" "$HOST_FIXTURE/directory-alias" >/dev/null 2>&1 && HOST_NEGATIVE_OK=false
fi
FAKE_BIN="$HOST_FIXTURE/fake-bin"
mkdir -p "$FAKE_BIN"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" MSYS_NT-10.0' > "$FAKE_BIN/uname"
chmod +x "$FAKE_BIN/uname"
PATH="$FAKE_BIN" /bin/bash "$HOST_PATH" "$HOST_FIXTURE" >/dev/null 2>&1 \
  && HOST_NEGATIVE_OK=false
printf '%s\n' '#!/bin/sh' 'exit 7' > "$FAKE_BIN/uname"
chmod +x "$FAKE_BIN/uname"
PATH="$FAKE_BIN" /bin/bash "$HOST_PATH" "$HOST_FIXTURE" >/dev/null 2>&1 \
  && HOST_NEGATIVE_OK=false
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" MSYS_NT-10.0' > "$FAKE_BIN/uname"
chmod +x "$FAKE_BIN/uname"
printf '%s\n' '#!/bin/sh' 'exit 7' > "$FAKE_BIN/cygpath"
chmod +x "$FAKE_BIN/cygpath"
PATH="$FAKE_BIN" /bin/bash "$HOST_PATH" "$HOST_FIXTURE" >/dev/null 2>&1 \
  && HOST_NEGATIVE_OK=false
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" /tmp/ambiguous' > "$FAKE_BIN/cygpath"
chmod +x "$FAKE_BIN/cygpath"
PATH="$FAKE_BIN" /bin/bash "$HOST_PATH" "$HOST_FIXTURE" >/dev/null 2>&1 \
  && HOST_NEGATIVE_OK=false
mkdir -p "$HOST_FIXTURE/C:/attacker-controlled"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" C:/attacker-controlled' > "$FAKE_BIN/cygpath"
chmod +x "$FAKE_BIN/cygpath"
(
  cd "$HOST_FIXTURE" || exit 1
  PATH="$FAKE_BIN" /bin/bash "$HOST_PATH" "$HOST_FIXTURE" >/dev/null 2>&1
) && HOST_NEGATIVE_OK=false
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" C:/first C:/second' > "$FAKE_BIN/cygpath"
chmod +x "$FAKE_BIN/cygpath"
PATH="$FAKE_BIN" /bin/bash "$HOST_PATH" "$HOST_FIXTURE" >/dev/null 2>&1 \
  && HOST_NEGATIVE_OK=false
if [ "$HOST_NEGATIVE_OK" = true ]; then
  check "host-path producer rejects missing, non-directory, aliased, unavailable, and malformed inputs" PASS
else
  check "host-path producer rejects missing, non-directory, aliased, unavailable, and malformed inputs" FAIL
fi
rm -rf -- "$HOST_FIXTURE"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    MSYS_TMP="$(mktemp -d /tmp/zensu-host-path-XXXXXX)"
    MSYS_NATIVE="$(bash "$HOST_PATH" "$MSYS_TMP" 2>/dev/null)"
    if printf '%s' "$MSYS_NATIVE" | grep -Eq '^[A-Za-z]:/' \
        && [ -d "$MSYS_NATIVE" ] \
        && node -e 'require("node:fs").realpathSync.native(process.argv[1])' "$MSYS_NATIVE"; then
      check "Git-Bash /tmp workspace becomes an absolute drive path for native Node" PASS
    else
      check "Git-Bash /tmp workspace becomes an absolute drive path for native Node" FAIL
    fi
    rm -rf -- "$MSYS_TMP"
    ;;
  *)
    check "Git-Bash /tmp workspace conversion is exercised on the Windows CI runner" PASS
    ;;
esac

PLAN_MKTEMP_LINE="$(grep -nF 'RAW_DIR=$(mktemp -d' "$PLAN_SKILL" | head -1 | cut -d: -f1)"
PLAN_HOST_LINE="$(grep -nF 'zensu-host-path.sh" "$RAW_DIR"' "$PLAN_SKILL" | head -1 | cut -d: -f1)"
PLAN_REPO_LINE="$(grep -nF 'RAW_REPO=$(pwd -P)' "$PLAN_SKILL" | head -1 | cut -d: -f1)"
PLAN_REPO_HOST_LINE="$(grep -nF 'zensu-host-path.sh" "$RAW_REPO"' "$PLAN_SKILL" | head -1 | cut -d: -f1)"
PLAN_MANIFEST_LINE="$(grep -nF "printf 'DIR=%s" "$PLAN_SKILL" | head -1 | cut -d: -f1)"
PR_MKTEMP_LINE="$(grep -nF 'RAW_WORKDIR="$(mktemp -d' "$PR_SKILL" | head -1 | cut -d: -f1)"
PR_HOST_LINE="$(grep -nF 'zensu-host-path.sh" "$RAW_WORKDIR"' "$PR_SKILL" | head -1 | cut -d: -f1)"
PR_REPO_LINE="$(grep -nF 'RAW_REPO="$REPO"' "$PR_SKILL" | head -1 | cut -d: -f1)"
PR_REPO_HOST_LINE="$(grep -nF 'zensu-host-path.sh" "$RAW_REPO"' "$PR_SKILL" | head -1 | cut -d: -f1)"
PR_WORKTREE_LINE="$(grep -nF 'WORKTREE="$WORKDIR/wt"' "$PR_SKILL" | head -1 | cut -d: -f1)"
if [ -n "$PLAN_MKTEMP_LINE" ] && [ -n "$PLAN_HOST_LINE" ] && [ -n "$PLAN_MANIFEST_LINE" ] \
    && [ "$PLAN_MKTEMP_LINE" -lt "$PLAN_HOST_LINE" ] && [ "$PLAN_HOST_LINE" -lt "$PLAN_MANIFEST_LINE" ] \
    && [ -n "$PLAN_REPO_LINE" ] && [ -n "$PLAN_REPO_HOST_LINE" ] \
    && [ "$PLAN_REPO_LINE" -lt "$PLAN_REPO_HOST_LINE" ] && [ "$PLAN_REPO_HOST_LINE" -lt "$PLAN_MANIFEST_LINE" ] \
    && [ -n "$PR_MKTEMP_LINE" ] && [ -n "$PR_HOST_LINE" ] && [ -n "$PR_WORKTREE_LINE" ] \
    && [ "$PR_MKTEMP_LINE" -lt "$PR_HOST_LINE" ] && [ "$PR_HOST_LINE" -lt "$PR_WORKTREE_LINE" ] \
    && [ -n "$PR_REPO_LINE" ] && [ -n "$PR_REPO_HOST_LINE" ] \
    && [ "$PR_REPO_LINE" -lt "$PR_REPO_HOST_LINE" ]; then
  check "both review skills convert temporary roots before emitting paths or creating worktrees" PASS
else
  check "both review skills convert temporary roots before emitting paths or creating worktrees" FAIL
fi

if grep -qF '_tdd_winpid_from_ps()' "$PHASE" \
  && grep -qF '_tdd_is_msys_runtime()' "$PHASE" \
  && grep -qF '_tdd_native_process_pid()' "$PHASE" \
  && grep -qF 'ps_output="$(ps -p "$shell_pid" -l' "$PHASE" \
  && grep -qF 'owner_pid="$(_tdd_native_process_pid "$owner_pid")"' "$PHASE"; then
  check "deferred review translates the MSYS shell PID before native Node liveness checks" PASS
else
  check "deferred review translates the MSYS shell PID before native Node liveness checks" FAIL
fi

if (
  export CLAUDE_PLUGIN_ROOT="$ROOT"
  # shellcheck disable=SC1090
  source "$PHASE"
  [ "$(printf '%s\n' \
      'PID PPID PGID WINPID TTY UID STIME COMMAND' \
      '42 1 42 9001 pty0 1000 12:00 /usr/bin/bash' \
      | _tdd_winpid_from_ps 42)" = 9001 ] || exit 1
  [ "$(printf '%s\n' \
      'PID PPID PGID WINPID TTY UID STIME COMMAND' \
      'I 42 1 42 9002 pty0 1000 12:00 /usr/bin/bash' \
      | _tdd_winpid_from_ps 42)" = 9002 ] || exit 1
  [ "$(printf '%s\n' \
      'S PID PPID PGID WINPID TTY UID STIME COMMAND' \
      'I 42 1 42 9003 pty0 1000 12:00 /usr/bin/bash' \
      | _tdd_winpid_from_ps 42)" = 9003 ] || exit 1
  if printf '%s\n' \
      'PID PPID PGID WINPID TTY UID STIME COMMAND' \
      '42 1 42 nope pty0 1000 12:00 /usr/bin/bash' \
      | _tdd_winpid_from_ps 42 >/dev/null; then exit 1; fi
  if printf '%s\n' \
      'PID PPID PGID WINPID TTY UID STIME COMMAND' \
      '42 1 42 0 pty0 1000 12:00 /usr/bin/bash' \
      | _tdd_winpid_from_ps 42 >/dev/null; then exit 1; fi
  if printf '%s\n' \
      'not a process header' \
      '42 1 42 9004 pty0 1000 12:00 /usr/bin/bash' \
      | _tdd_winpid_from_ps 42 >/dev/null; then exit 1; fi
); then
  check "Cygwin/MSYS long ps output yields only the matching numeric WINPID" PASS
else
  check "Cygwin/MSYS long ps output yields only the matching numeric WINPID" FAIL
fi

if (
  export CLAUDE_PLUGIN_ROOT="$ROOT"
  # shellcheck disable=SC1090
  source "$PHASE"
  _tdd_is_msys_runtime() { return 0; }
  ps() {
    printf '%s\n' \
      'PID PPID PGID WINPID TTY UID STIME COMMAND' \
      '42 1 42 9005 pty0 1000 12:00 /usr/bin/bash'
    return 7
  }
  ! _tdd_native_process_pid 42 >/dev/null 2>&1
); then
  check "deferred review rejects plausible ps output when the producer exits non-zero" PASS
else
  check "deferred review rejects plausible ps output when the producer exits non-zero" FAIL
fi

if (
  export CLAUDE_PLUGIN_ROOT="$ROOT"
  # shellcheck disable=SC1090
  source "$PHASE"
  # Capture the long-lived parent before command substitution creates a
  # short-lived Git-Bash process with its own BASHPID.
  shell_pid="${BASHPID:-$$}"
  native_pid="$(_tdd_native_process_pid "$shell_pid")" || exit 1
  node -e 'process.kill(Number(process.argv[1]), 0)' "$native_pid"
); then
  check "deferred review PID maps to a process visible to native Node" PASS
else
  check "deferred review PID maps to a process visible to native Node" FAIL
fi

DECLARED_ROOT="$ROOT"
WRONG_ROOT="$(cd "$ROOT/.." && pwd -P)"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    DECLARED_ROOT="$(cygpath -aw "$ROOT")"
    WRONG_ROOT="$(cygpath -aw "$WRONG_ROOT")"
    ;;
esac
ROOT_OK_OUT="$(printf '%s' '{"hook_event_name":"SessionStart","source":"resume"}' \
  | CLAUDE_PLUGIN_ROOT="$DECLARED_ROOT" bash "$BANNER" 2>&1)"
ROOT_OK_RC=$?
ROOT_BAD_OUT="$(printf '%s' '{"hook_event_name":"SessionStart","source":"resume"}' \
  | CLAUDE_PLUGIN_ROOT="$WRONG_ROOT" bash "$BANNER" 2>&1)"
ROOT_BAD_RC=$?
if [ "$ROOT_OK_RC" -eq 0 ] && [ "$ROOT_BAD_RC" -eq 2 ] \
    && printf '%s' "$ROOT_BAD_OUT" | grep -qF 'does not match the executing plugin' \
    && ! grep -R -l -F '[ "$CLAUDE_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]' "$ROOT/hooks" \
      | grep -q .; then
  check "canonical root guard accepts host-native spelling and rejects a different installation" PASS
else
  check "canonical root guard accepts host-native spelling and rejects a different installation" FAIL
fi

if ! grep -qF 'process.argv[1]' "$POST_REVIEW" \
    && grep -qF 'readFileSync(0, "utf8")' "$POST_REVIEW" \
    && ! grep -qF 'reason:process.argv[1]' "$STOP_ENFORCER" \
    && grep -qF 'readFileSync(0, "utf8")' "$STOP_ENFORCER" \
    && [ "$(grep -cF 'MSYS2_ENV_CONV_EXCL="$_ZENSU_MSYS2_ENV_CONV_EXCL"' "$PRE_EDIT")" -eq 2 ]; then
  check "free-form hook messages bypass MSYS argv and environment path conversion" PASS
else
  check "free-form hook messages bypass MSYS argv and environment path conversion" FAIL
fi

if (
  export MSYS2_ENV_CONV_EXCL=EXISTING_SELECTOR
  EXPECTED_PRINCIPAL_CWD="$(cd -P -- "$(dirname "$AGENT_CONTEXT")" && pwd -P)"
  node() {
    [ -z "${PRINCIPAL_LIB:-}" ] || return 9
    [ "${MSYS2_ENV_CONV_EXCL:-}" = EXISTING_SELECTOR ] || return 9
    [ "$(pwd -P)" = "$EXPECTED_PRINCIPAL_CWD" ] || return 9
    command node "$@"
  }
  # shellcheck disable=SC1090
  source "$AGENT_CONTEXT"
  [ "$(zensu_hook_principal '{"hook_event_name":"SessionStart"}' SessionStart)" = main-v1 ]
); then
  check "principal classifier resolves from native process cwd without path transport" PASS
else
  check "principal classifier resolves from native process cwd without path transport" FAIL
fi

if [ "$(grep -cF 'node ./claude-hook-session-v1.js' "$SESSION_BINDING")" -eq 2 ] \
    && ! grep -qF 'node "$binder"' "$SESSION_BINDING" \
    && [ "$(grep -cF 'node ./session-control-core-v1.js session-key' "$SESSION_BINDING")" -eq 2 ] \
    && grep -qF 'require("./session-control-core-v1.js")' "$SESSION_BINDING" \
    && ! grep -qF 'CLAUDE_PLUGIN_ROOT="$ZENSU_CLAUDE_PLUGIN_ROOT"' "$SESSION_BINDING" \
    && grep -qF '_ZENSU_TDD_NATIVE_PLUGIN_ROOT="$(bash "$_ZENSU_TDD_HOST_PATH" "$CLAUDE_PLUGIN_ROOT")"' "$PHASE" \
    && grep -qF '_ZENSU_TDD_CONTROL_CORE="${_ZENSU_TDD_NATIVE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js"' "$PHASE" \
    && ! grep -qF '${ZENSU_CLAUDE_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}' "$PHASE" \
    && ! grep -qF 'CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js"' "$PHASE" \
    && grep -qF '_tdd_native_project_path()' "$PHASE" \
    && grep -qF 'native_state_file="$(_tdd_native_project_path "$state_file")"' "$PHASE" \
    && grep -qF 'require("./claude-hook-session-v1.js")' "$AUTOPILOT_RESUME" \
    && ! grep -qF 'require(process.env.BINDER)' "$AUTOPILOT_RESUME"; then
  check "session helpers keep Bash paths separate from authenticated native Node paths" PASS
else
  check "session helpers keep Bash paths separate from authenticated native Node paths" FAIL
fi

if (
  export CLAUDE_PLUGIN_ROOT="$ROOT"
  export ZENSU_CLAUDE_PLUGIN_ROOT="$WRONG_ROOT"
  # shellcheck disable=SC1090
  source "$PHASE"
  expected_native="$(bash "$HOST_PATH" "$ROOT")" || exit 1
  [ "$_ZENSU_TDD_NATIVE_PLUGIN_ROOT" = "$expected_native" ] || exit 1
  [ "$_ZENSU_TDD_CONTROL_CORE" = "$expected_native/hooks/lib/session-control-core-v1.js" ] || exit 1
); then
  check "TDD native code-load authority ignores an ambient ZENSU plugin root" PASS
else
  check "TDD native code-load authority ignores an ambient ZENSU plugin root" FAIL
fi

CONFIG_FIXTURE="$(mktemp -d -t "zensu config apostrophe'XXXXXX")"
mkdir -p "$CONFIG_FIXTURE/home/.zensu" "$CONFIG_FIXTURE/project/.zensu"
printf '%s\n' '{"hooks":{"combinedSummary":false},"globalOnly":true}' \
  > "$CONFIG_FIXTURE/home/.zensu/config.json"
printf '%s\n' '{"hooks":{"combinedSummary":true},"projectOnly":true}' \
  > "$CONFIG_FIXTURE/project/.zensu/config.json"
printf '%s\n' '{"overrideOnly":true}' > "$CONFIG_FIXTURE/override config.json"
if (
  export HOME="$CONFIG_FIXTURE/home"
  export CLAUDE_PROJECT_DIR="$CONFIG_FIXTURE/project"
  unset ZENSU_CONFIG
  # shellcheck disable=SC1090
  source "$CONFIG_LIB"
  merged="$(_zensu_config_json)" || exit 1
  MERGED="$merged" node -e '
    const value = JSON.parse(process.env.MERGED);
    process.exit(value.globalOnly === true && value.projectOnly === true
      && value.hooks?.combinedSummary === true ? 0 : 1);
  ' || exit 1
  export ZENSU_CONFIG="$CONFIG_FIXTURE/override config.json"
  overridden="$(_zensu_config_json)" || exit 1
  OVERRIDDEN="$overridden" node -e '
    const value = JSON.parse(process.env.OVERRIDDEN);
    process.exit(value.overrideOnly === true && Object.keys(value).length === 1 ? 0 : 1);
  '
); then
  check "config global, project, and override paths survive shell-special MSYS transport" PASS
else
  check "config global, project, and override paths survive shell-special MSYS transport" FAIL
fi
rm -rf -- "$CONFIG_FIXTURE"

printf '%s\n' '----' "test-msys-runtime-boundaries: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
