#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
PASS=0; FAIL=0
check() {
  if [ "$2" = "PASS" ]; then echo "  PASS  $1"; PASS=$((PASS + 1));
  else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}
verdict() { if [ "$1" -eq 0 ]; then echo PASS; else echo FAIL; fi; }

echo "=== unit file: tests/structure/code-roots-v1.test.js ==="
. "$(dirname "$0")/lib-unit-registry.sh"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    check "native Windows run skipped: the fixtures need POSIX symlinks, perl -pi and an assumed different git owner" PASS
    unit_check_done "U2 every unit file the registry gives this suite was graded"
    echo ""
    echo "code-roots: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
    exit
    ;;
esac
unit_check "U1 the code-roots unit file passes" "$ROOT/tests/structure/code-roots-v1.test.js"
unit_check_done "U2 every unit file the registry gives this suite was graded"

WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
export XDG_CONFIG_HOME="$WORK/xdg"
export GIT_CONFIG_NOSYSTEM=1
export ZENSU_CONFIG="$WORK/no-such-config.json"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
  GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_ICASE_PATHSPECS ZENSU_EDIT_LANDING_GATE 2>/dev/null || true
printf '*.globalignored\n' > "$HOME/global-ignore"
git config --global core.excludesFile "$HOME/global-ignore"

PLUGIN_ON="$WORK/plugin-on"
mkdir -p "$PLUGIN_ON"
COPY_OK=true
for item in .claude-plugin hooks agents skills docs templates scripts README.md CHANGELOG.md LICENSE; do
  [ -e "$ROOT/$item" ] || continue
  cp -R "$ROOT/$item" "$PLUGIN_ON/" 2>/dev/null || COPY_OK=false
done
perl -pi -e 's/^const CODE_ROOTS_ENABLED = false;$/const CODE_ROOTS_ENABLED = true;/' "$PLUGIN_ON/hooks/lib/code-roots-v1.js" || COPY_OK=false
[ "$COPY_OK" = true ] && grep -qx 'const CODE_ROOTS_ENABLED = true;' "$PLUGIN_ON/hooks/lib/code-roots-v1.js" \
  && grep -qx 'const CODE_ROOTS_ENABLED = false;' "$ROOT/hooks/lib/code-roots-v1.js"
check "F0 the fixture plugin copy has the switch on while the tracked tree ships it off" "$(verdict $?)"

node "$ROOT/hooks/lib/code-roots-v1.js" enabled; OFF_RC=$?
node "$PLUGIN_ON/hooks/lib/code-roots-v1.js" enabled; ON_RC=$?
[ "$OFF_RC" -eq 1 ] && [ "$ON_RC" -eq 0 ]
check "F1 the enabled verb answers 1 for the shipped switch and 0 for the flipped copy" "$(verdict $?)"

gitc() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
mkrepo() {
  mkdir -p "$1"
  git -C "$1" init -q
  printf 'one\n' > "$1/base.txt"
  gitc -C "$1" add base.txt
  gitc -C "$1" commit -qm init
}
commit_all() { gitc -C "$1" add -A && gitc -C "$1" commit -qm "$2"; }

write_doc() {
  local out="$1"
  shift
  node - "$out" "$@" <<'NODE'
const fs = require('fs');
const cp = require('child_process');
const [out, ...pairs] = process.argv.slice(2);
const roots = [];
const git = (dir, args) => cp.execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8' }).trim();
for (let i = 0; i < pairs.length; i += 2) {
  const spec = pairs[i];
  const at = spec.indexOf(':');
  const label = at < 0 ? spec : spec.slice(0, at);
  const baselineOverride = at < 0 ? '' : spec.slice(at + 1);
  const root = fs.realpathSync(pairs[i + 1]);
  let baseline = 'unborn';
  try {
    baseline = git(root, ['rev-parse', '--verify', '-q', 'HEAD']);
  } catch {
    baseline = 'unborn';
  }
  roots.push({
    label,
    path: root,
    top: git(root, ['rev-parse', '--show-toplevel']),
    commonDir: git(root, ['rev-parse', '--path-format=absolute', '--git-common-dir']),
    baseline: baselineOverride || baseline,
  });
}
let document = {};
if (fs.existsSync(out)) document = JSON.parse(fs.readFileSync(out, 'utf8'));
document.codeRoots = roots;
fs.writeFileSync(out, JSON.stringify(document));
NODE
}

EL_ON="$PLUGIN_ON/hooks/lib/zensu-edit-landing.sh"
EL_OFF="$ROOT/hooks/lib/zensu-edit-landing.sh"

echo "=== audit: @<label>/ grading, respell, foreign remedy, faults ==="
SRC="$HOME/src"
ANCHOR="$SRC/anchor"
APP="$SRC/app"
FOREIGN="$SRC/other"
mkrepo "$ANCHOR"
mkrepo "$APP"
mkrepo "$FOREIGN"
mkdir -p "$APP/src" "$ANCHOR/src"
printf 'a\n' > "$APP/src/a.txt"
printf 'b\n' > "$APP/src/b.txt"
printf 'c\n' > "$APP/src/c.txt"
commit_all "$APP" app-files
printf 'c\n' > "$ANCHOR/src/c.txt"
commit_all "$ANCHOR" anchor-files
DOC="$WORK/audit-doc.json"
write_doc "$DOC" app "$APP"
printf 'changed\n' >> "$APP/src/a.txt"
printf 'anchor change\n' >> "$ANCHOR/src/c.txt"
AUDIT_LOG="$WORK/audit.log"
{
  printf 'S1 IMPL completed — files: @app/src/a.txt\n'
  printf 'S2 IMPL completed — files: @app/src/b.txt\n'
  printf 'S3 IMPL completed — files: %s\n' "$APP/src/a.txt"
  printf 'S4 IMPL completed — files: ~/src/app/src/a.txt\n'
  printf 'S5 IMPL completed — files: @app/src/c.txt\n'
  printf 'S6 IMPL completed — files: %s\n' "$FOREIGN/base.txt"
  printf 'S7 IMPL completed — files: src/c.txt\n'
} > "$AUDIT_LOG"
AUDIT_OUT="$(bash "$EL_ON" --log "$AUDIT_LOG" --project "$ANCHOR" --workflow "$DOC" --receipt "$WORK/audit-receipt.json" 2>&1)"; AUDIT_RC=$?
printf '%s\n' "$AUDIT_OUT" | grep -qxF 'EDIT LANDED — S1: @app/src/a.txt'
check "A1 an @<label>/ claim whose file changed in its root lands" "$(verdict $?)"
printf '%s\n' "$AUDIT_OUT" | grep -qF 'EDIT NOT LANDED — S2: claimed @app/src/b.txt, git shows no change'
check "A2 an @<label>/ claim whose file did not change in its root does not land" "$(verdict $?)"
printf '%s\n' "$AUDIT_OUT" | grep -F 'UNVERIFIED (respell) — S3:' | grep -qF 'spell it @app/src/a.txt'
check "A3 an absolute claim into a declared root grades respell with the exact @<label>/ spelling" "$(verdict $?)"
printf '%s\n' "$AUDIT_OUT" | grep -F 'UNVERIFIED (respell) — S4:' | grep -qF 'spell it @app/src/a.txt'
check "A4 a claim the run-log writer redacted to ~/… grades respell with the exact spelling" "$(verdict $?)"
printf '%s\n' "$AUDIT_OUT" | grep -qF 'EDIT NOT LANDED — S5: claimed @app/src/c.txt'
check "A5 aliasing negative: an @<label>/ claim never lands on a same-named dirty anchor file" "$(verdict $?)"
printf '%s\n' "$AUDIT_OUT" | grep -F 'UNVERIFIED (foreign root) — S6:' | grep -qF -- '--code-root <label>=<path>'
check "A6 an undeclared foreign root keeps the stage-1 verdict and names the declare-and-re-arm remedy" "$(verdict $?)"
printf '%s\n' "$AUDIT_OUT" | grep -qxF 'EDIT LANDED — S7: src/c.txt'
check "A7 the anchor's own unprefixed claim keeps grading against the anchor" "$(verdict $?)"
[ "$AUDIT_RC" -eq 1 ] && [ -f "$WORK/audit-receipt.json" ] && grep -q '"clean": *false' "$WORK/audit-receipt.json"
check "A8 the mixed audit fails and records a receipt that is not clean" "$(verdict $?)"
AB_ANCHOR="$SRC/ab-anchor"
AB_A="$SRC/ab-root-a"
AB_B="$SRC/ab-root-b"
mkrepo "$AB_ANCHOR"
mkrepo "$AB_A"
mkrepo "$AB_B"
AB_DOC="$WORK/ab-doc.json"
write_doc "$AB_DOC" rta "$AB_A" rtb "$AB_B"
AB_LOG="$WORK/ab.log"
printf 'S1 IMPL completed — files: @rtb/base.txt\n' > "$AB_LOG"
AB_OUT="$(bash "$EL_ON" --log "$AB_LOG" --project "$AB_ANCHOR" --workflow "$AB_DOC" --receipt "$WORK/ab-receipt.json" 2>&1)"; AB_RC=$?
[ "$AB_RC" -eq 1 ] && printf '%s\n' "$AB_OUT" | grep -qF 'EDIT NOT LANDED — S1: claimed @rtb/base.txt, git shows no change' \
  && [ -f "$WORK/ab-receipt.json" ] && grep -q '"clean": *false' "$WORK/ab-receipt.json"
check "A8b a claim in root B that never landed fails the audit while the anchor and root A are clean" "$(verdict $?)"

OFF_LOG="$WORK/foreign-off.log"
printf 'S6 IMPL completed — files: %s\n' "$FOREIGN/base.txt" > "$OFF_LOG"
OFF_OUT="$(bash "$EL_OFF" --log "$OFF_LOG" --project "$ANCHOR" 2>&1)"
printf '%s\n' "$OFF_OUT" | grep -qF 'UNVERIFIED (foreign root) — S6:' \
  && ! printf '%s\n' "$OFF_OUT" | grep -qF -- '--code-root'
check "A9 with the switch off the foreign-root verdict names no --code-root remedy" "$(verdict $?)"

DEP="$SRC/dep"
mkrepo "$DEP"
DEP_BASE="$(git -C "$DEP" rev-parse HEAD)"
mkdir -p "$DEP/src"
printf 'd\n' > "$DEP/src/d.txt"
commit_all "$DEP" committed-before-arming
BASE_DOC="$WORK/baseline-doc.json"
write_doc "$BASE_DOC" "dep:$DEP_BASE" "$DEP"
printf 'S8 IMPL completed — files: @dep/src/d.txt\n' > "$WORK/baseline.log"
BASE_OUT="$(bash "$EL_ON" --log "$WORK/baseline.log" --project "$ANCHOR" --workflow "$BASE_DOC" 2>&1)"
printf '%s\n' "$BASE_OUT" | grep -qxF 'EDIT LANDED — S8: @dep/src/d.txt'
check "A10 work committed in a root after its declared baseline counts and lands" "$(verdict $?)"

FOLDER="$WORK/folder"
mkdir -p "$FOLDER"
mkrepo "$FOLDER/svc"
mkdir -p "$FOLDER/svc/src"
printf 's\n' > "$FOLDER/svc/src/s.txt"
commit_all "$FOLDER/svc" svc-files
printf 'notes\n' > "$FOLDER/notes.txt"
FOLDER_DOC="$WORK/folder-doc.json"
write_doc "$FOLDER_DOC" svc "$FOLDER/svc"
printf 'more\n' >> "$FOLDER/svc/src/s.txt"
{
  printf 'F1 IMPL completed — files: @svc/src/s.txt\n'
  printf 'F2 IMPL completed — files: svc/src/s.txt\n'
  printf 'F3 IMPL completed — files: notes.txt\n'
} > "$WORK/folder.log"
FOLDER_OUT="$(bash "$EL_ON" --log "$WORK/folder.log" --project "$FOLDER" --workflow "$FOLDER_DOC" 2>&1)"
printf '%s\n' "$FOLDER_OUT" | grep -qxF 'EDIT LANDED — F1: @svc/src/s.txt'
check "A11 folder anchor: an @<label>/ claim lands" "$(verdict $?)"
printf '%s\n' "$FOLDER_OUT" | grep -F 'UNVERIFIED (respell) — F2:' | grep -qF 'spell it @svc/src/s.txt'
check "A12 folder anchor: an unprefixed claim resolving into the root grades respell" "$(verdict $?)"
printf '%s\n' "$FOLDER_OUT" | grep -qF 'UNVERIFIED — F3: notes.txt cannot be checked outside a git work tree'
check "A13 folder anchor: a folder file outside every root grades UNVERIFIED" "$(verdict $?)"

FAULT_HOME="$WORK/fault-home"
mkdir -p "$FAULT_HOME"
FAULT_OUT="$(HOME="$FAULT_HOME" XDG_CONFIG_HOME="$FAULT_HOME/xdg" GIT_TEST_ASSUME_DIFFERENT_OWNER=1 \
  bash "$EL_ON" --log "$WORK/folder.log" --project "$FOLDER" --workflow "$FOLDER_DOC" --receipt "$WORK/fault-receipt.json" 2>&1)"; FAULT_RC=$?
CONTROL_OUT="$(LC_ALL=C HOME="$FAULT_HOME" XDG_CONFIG_HOME="$FAULT_HOME/xdg" GIT_TEST_ASSUME_DIFFERENT_OWNER=1 \
  git -C "$FOLDER/svc" status --porcelain 2>&1)"; CONTROL_RC=$?
[ "$CONTROL_RC" -ne 0 ] && printf '%s\n' "$CONTROL_OUT" | grep -qi 'dubious ownership'
check "A14-control real git refuses the code root under the assumed different owner" "$(verdict $?)"
[ "$FAULT_RC" -eq 2 ] && [ ! -e "$WORK/fault-receipt.json" ] \
  && printf '%s\n' "$FAULT_OUT" | grep -F 'EDIT LANDING AUDIT FAULT —' | grep -qF "$FOLDER/svc" \
  && ! printf '%s\n' "$FAULT_OUT" | grep -qE '^EDIT (NOT )?LANDED'
check "A14 a git fault in a code root names that root, grades nothing and writes no receipt" "$(verdict $?)"

INV_LOG="$WORK/inventory.log"
{
  printf 'I1 IMPL completed — files: %s\n' "$APP/src/a.txt"
  printf 'I2 IMPL completed — files: %s\n' "$FOREIGN/base.txt"
} > "$INV_LOG"
INV_ON="$(bash "$EL_ON" --inventory --log "$INV_LOG" --project "$ANCHOR" --workflow "$DOC" 2>&1)"
INV_OFF="$(bash "$EL_ON" --inventory --log "$INV_LOG" --project "$ANCHOR" 2>&1)"
printf '%s\n' "$INV_ON" | grep -qxF "foreign-root	$FOREIGN" \
  && ! printf '%s\n' "$INV_ON" | grep -qxF "foreign-root	$APP" \
  && printf '%s\n' "$INV_OFF" | grep -qxF "foreign-root	$APP"
check "A15 the inventory stops reporting a declared root as foreign and keeps an undeclared one" "$(verdict $?)"

echo "=== parity: the module and the shell recipes ==="
PAR="$SRC/parity"
mkrepo "$PAR"
printf 'x\n' > "$PAR/tracked.txt"
commit_all "$PAR" tracked
PAR_BASE="$(git -C "$PAR" rev-parse HEAD)"
printf 'y\n' >> "$PAR/tracked.txt"
printf 'n\n' > "$PAR/new.txt"
printf 'g\n' > "$PAR/only.globalignored"
mkdir -p "$PAR/dir"
printf 'z\n' > "$PAR/dir/mid.txt"
gitc -C "$PAR" add dir/mid.txt
gitc -C "$PAR" commit -qm mid-run
PAR_DOC="$WORK/parity-doc.json"
write_doc "$PAR_DOC" "par:$PAR_BASE" "$PAR"
MODULE_SET="$(node "$PLUGIN_ON/hooks/lib/code-roots-v1.js" enumerate --anchor "$ANCHOR" --workflow "$PAR_DOC" | awk -F '\t' '$1 == "file" { print $3 }' | sort)"
SHELL_SET="$(bash "$EL_OFF" --change-set --project "$PAR" --baseline "$PAR_BASE" | sort)"
[ -n "$MODULE_SET" ] && [ "$MODULE_SET" = "$SHELL_SET" ] && printf '%s\n' "$MODULE_SET" | grep -qx 'dir/mid.txt' \
  && printf '%s\n' "$MODULE_SET" | grep -qx 'only.globalignored'
check "P1 enumeration parity with the audit recipe, a mid-run commit and a globally ignored file included" "$(verdict $?)"

UNBORN="$SRC/unborn"
mkdir -p "$UNBORN"
git -C "$UNBORN" init -q
printf 'u\n' > "$UNBORN/first.txt"
printf 's\n' > "$UNBORN/staged.txt"
git -C "$UNBORN" add staged.txt
UNBORN_DOC="$WORK/unborn-doc.json"
write_doc "$UNBORN_DOC" fresh "$UNBORN"
MODULE_UNBORN="$(node "$PLUGIN_ON/hooks/lib/code-roots-v1.js" enumerate --anchor "$ANCHOR" --workflow "$UNBORN_DOC" | awk -F '\t' '$1 == "file" { print $3 }' | sort)"
SHELL_UNBORN="$(bash "$EL_OFF" --change-set --project "$UNBORN" | sort)"
[ -n "$MODULE_UNBORN" ] && [ "$MODULE_UNBORN" = "$SHELL_UNBORN" ]
check "P2 enumeration parity on an unborn HEAD" "$(verdict $?)"

COUNT_FUNCS="$WORK/count-funcs.sh"
awk '/^_tc_git\(\) \{ \($/,/^\); \}$/' "$ROOT/hooks/lib/zensu-log.sh" > "$COUNT_FUNCS"
awk '/^_tc_git_magic\(\) \{ \($/,/^\); \}$/' "$ROOT/hooks/lib/zensu-log.sh" >> "$COUNT_FUNCS"
awk '/^_zensu_unqualified_change_count\(\) \{$/,/^}$/' "$ROOT/hooks/lib/zensu-log.sh" >> "$COUNT_FUNCS"
COUNT_DOC="$WORK/count-doc.json"
write_doc "$COUNT_DOC" par "$PAR"
SHELL_COUNT="$(bash -c '. "$1"; _zensu_unqualified_change_count "$2"' _ "$COUNT_FUNCS" "$PAR")"
MODULE_COUNT="$(node "$PLUGIN_ON/hooks/lib/code-roots-v1.js" count --anchor "$ANCHOR" --workflow "$COUNT_DOC" | awk -F '\t' '$1 == "count" { print $3 }')"
[ -n "$SHELL_COUNT" ] && [ "$SHELL_COUNT" = "$MODULE_COUNT" ] && [ "$SHELL_COUNT" -eq 2 ]
check "P3 count parity with _zensu_unqualified_change_count on the uncommitted part, global excludes kept" "$(verdict $?)"

echo "=== zensu-log.sh: arming, union count, read verbs ==="
bind_session() {
  local sid="$1" plugin="$2" project="$3"
  export CLAUDE_PLUGIN_ROOT="$plugin"
  export CLAUDE_PROJECT_DIR="$project"
  export ZENSU_TEST_PLUGIN_DATA="$WORK/plugin-data-$sid"
  source "$ROOT/tests/session-control/initialize-baseline.sh" "$sid" "$plugin"
}
state_file_of() {
  (source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"; tdd_state_file "$1")
}
inject_roots() {
  local state="$1"
  shift
  write_doc "$state" "$@"
}

GITP="$WORK/projects/git-anchor"
mkrepo "$GITP"
printf '.zensu/\n.session-control-test/\n' > "$GITP/.gitignore"
commit_all "$GITP" ignore
bind_session "cr-disabled" "$ROOT" "$GITP"
DIS_ERR="$WORK/disabled.err"
bash "$ROOT/hooks/lib/zensu-log.sh" --tdd-begin --session cr-disabled --code-root "app=$APP" >/dev/null 2>"$DIS_ERR"; DIS_RC=$?
DIS_STATE="$(state_file_of cr-disabled)"
DIS_ACTIVE="$(source "$ROOT/hooks/lib/zensu-tdd-phase.sh"; tdd_session_active "$DIS_STATE")"
[ "$DIS_RC" -eq 2 ] && grep -qF 'multi-repo chains are not enabled in this build' "$DIS_ERR" && [ "$DIS_ACTIVE" != true ]
check "L1 --tdd-begin --code-root refuses while the switch is off and arms nothing" "$(verdict $?)"
AP_ERR="$WORK/autopilot.err"
bash "$ROOT/hooks/lib/zensu-log.sh" --tdd-begin --session cr-disabled --code-root "app=$APP" \
  --autopilot-run run-x --autopilot-attempt 1 --autopilot-return-stage CONVERGE --chain-id chain-x >/dev/null 2>"$AP_ERR"; AP_RC=$?
[ "$AP_RC" -eq 2 ] && grep -qF 'refused together with the Autopilot binding flags' "$AP_ERR"
check "L2 --code-root is refused together with the Autopilot binding flags" "$(verdict $?)"
bash "$ROOT/hooks/lib/zensu-log.sh" --tdd-complete --session cr-disabled --code-root "app=$APP" >/dev/null 2>"$WORK/verb.err"; VERB_RC=$?
[ "$VERB_RC" -eq 2 ] && grep -qF 'option is not valid for this verb' "$WORK/verb.err"
check "L3 --code-root belongs to --tdd-begin alone" "$(verdict $?)"

bash "$ROOT/hooks/lib/zensu-log.sh" --tdd-begin --session cr-disabled >/dev/null 2>"$WORK/git-begin.err"; GB_RC=$?
[ "$GB_RC" -eq 0 ] && ! grep -qF 'FOLDER ANCHOR' "$WORK/git-begin.err" && ! grep -qF '"codeRoots"' "$DIS_STATE"
check "L4 a work-tree anchor arms silently and its document carries no codeRoots key" "$(verdict $?)"

UNBORNP="$WORK/projects/unborn-anchor"
mkdir -p "$UNBORNP"
git -C "$UNBORNP" init -q
bind_session "cr-unborn" "$ROOT" "$UNBORNP"
bash "$ROOT/hooks/lib/zensu-log.sh" --tdd-begin --session cr-unborn >/dev/null 2>"$WORK/unborn-begin.err"; UB_RC=$?
[ "$UB_RC" -eq 0 ] && ! grep -qF 'FOLDER ANCHOR' "$WORK/unborn-begin.err"
check "L4b a work-tree anchor with an unborn HEAD arms silently" "$(verdict $?)"

FOLDERP="$WORK/projects/folder-anchor"
mkdir -p "$FOLDERP"
bind_session "cr-folder" "$ROOT" "$FOLDERP"
bash "$ROOT/hooks/lib/zensu-log.sh" --tdd-begin --session cr-folder >/dev/null 2>"$WORK/folder-begin.err"; FB_RC=$?
[ "$FB_RC" -eq 0 ] && grep -qF 'FOLDER ANCHOR' "$WORK/folder-begin.err" \
  && grep -qF 'Start a session in the repository the work changes' "$WORK/folder-begin.err"
check "L5 a folder anchor without --code-root is disclosed at arming" "$(verdict $?)"

GATE_PHRASE="refusing the unqualified standalone terminus"
union_case() {
  local sid="$1" project="$2" label="$3" root="$4" dirty="$5" expect="$6" name="$7" state rc err
  bind_session "$sid" "$PLUGIN_ON" "$project"
  bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --tdd-begin --session "$sid" >/dev/null 2>&1
  bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --tdd-complete --session "$sid" >/dev/null 2>&1
  state="$(state_file_of "$sid")"
  inject_roots "$state" "$label" "$root"
  [ "$dirty" = dirty ] && printf 'dirty\n' >> "$root/base.txt"
  err="$WORK/$sid.err"
  bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --chain-done --session "$sid" >/dev/null 2>"$err"; rc=$?
  [ "$dirty" = dirty ] && git -C "$root" checkout -q -- base.txt
  case "$expect" in
    (refuse) [ "$rc" -ne 0 ] && grep -qF "$GATE_PHRASE" "$err" ;;
    (close) [ "$rc" -eq 0 ] ;;
  esac
  check "$name" "$(verdict $?)"
}
U1R="$SRC/union-one"; mkrepo "$U1R"
U2R="$SRC/union-two"; mkrepo "$U2R"
U3R="$SRC/union-three"; mkrepo "$U3R"
U4R="$SRC/union-four"; mkrepo "$U4R"
GITP2="$WORK/projects/git-anchor-2"; mkrepo "$GITP2"; printf '.zensu/\n.session-control-test/\n' > "$GITP2/.gitignore"; commit_all "$GITP2" ignore
GITP3="$WORK/projects/git-anchor-3"; mkrepo "$GITP3"; printf '.zensu/\n.session-control-test/\n' > "$GITP3/.gitignore"; commit_all "$GITP3" ignore
FOLDERP2="$WORK/projects/folder-anchor-2"; mkdir -p "$FOLDERP2"
FOLDERP3="$WORK/projects/folder-anchor-3"; mkdir -p "$FOLDERP3"
union_case cr-union-dirty "$GITP2" one "$U1R" dirty refuse "L6 a change in a code root makes the union non-zero while the anchor is clean"
union_case cr-union-clean "$GITP3" two "$U2R" clean close "L7 clean roots and a clean anchor give a union of zero"
union_case cr-folder-dirty "$FOLDERP2" three "$U3R" dirty refuse "L8 folder anchor: a changed root makes the union non-zero although the anchor answers unknown"
union_case cr-folder-clean "$FOLDERP3" four "$U4R" clean close "L9 folder anchor: clean roots keep the anchor's unknown, which the terminus reads as zero"
FOLDERP5="$WORK/projects/folder-anchor-5"; mkdir -p "$FOLDERP5"
U7R="$SRC/union-seven"; mkdir -p "$U7R"; git -C "$U7R" init -q; printf 'n\n' > "$U7R/new.txt"
union_case cr-folder-unborn "$FOLDERP5" seven "$U7R" clean refuse "L8b folder anchor: an unborn code root holding a new file makes the union non-zero while the anchor answers unknown"

GITP4="$WORK/projects/git-anchor-4"; mkrepo "$GITP4"; printf '.zensu/\n.session-control-test/\n' > "$GITP4/.gitignore"; commit_all "$GITP4" ignore
U5R="$SRC/union-five"; mkrepo "$U5R"
bind_session cr-union-fault "$PLUGIN_ON" "$GITP4"
bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --tdd-begin --session cr-union-fault >/dev/null 2>&1
bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --tdd-complete --session cr-union-fault >/dev/null 2>&1
inject_roots "$(state_file_of cr-union-fault)" five "$U5R"
mv "$U5R/.git" "$U5R/.git-moved"
bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --chain-done --session cr-union-fault >/dev/null 2>"$WORK/fault.err"; UF_RC=$?
mv "$U5R/.git-moved" "$U5R/.git"
[ "$UF_RC" -ne 0 ] && grep -qF 'code root five could not be counted' "$WORK/fault.err"
check "L10 a failing code root makes the union unavailable, never unknown" "$(verdict $?)"
FOLDERP4="$WORK/projects/folder-anchor-4"; mkdir -p "$FOLDERP4"
U6R="$SRC/union-six"; mkrepo "$U6R"
bind_session cr-anchor-fault "$PLUGIN_ON" "$FOLDERP4"
bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --tdd-begin --session cr-anchor-fault >/dev/null 2>&1
bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --tdd-complete --session cr-anchor-fault >/dev/null 2>&1
inject_roots "$(state_file_of cr-anchor-fault)" six "$U6R"
printf 'not a gitfile\n' > "$FOLDERP4/.git"
bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --chain-done --session cr-anchor-fault >/dev/null 2>"$WORK/anchor-fault.err"; AF_RC=$?
rm -f "$FOLDERP4/.git"
[ "$AF_RC" -ne 0 ] && grep -qF "git could not list this worktree's changes" "$WORK/anchor-fault.err"
check "L10b folder anchor: a git failure other than the no-work-tree answer makes the union unavailable while every root is clean" "$(verdict $?)"

GITP5="$WORK/projects/git-anchor-5"; mkrepo "$GITP5"
printf '.zensu/\n.session-control-test/\n' > "$GITP5/.gitignore"
commit_all "$GITP5" ignore
INNER="$GITP5/inner"
mkrepo "$INNER"
bind_session cr-nested "$PLUGIN_ON" "$GITP5"
bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --tdd-begin --session cr-nested >/dev/null 2>&1
NESTED_STATE="$(state_file_of cr-nested)"
inject_roots "$NESTED_STATE" inner "$INNER"
bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --tdd-complete --session cr-nested >/dev/null 2>"$WORK/nested-complete.err"; NESTED_COMPLETE_RC=$?
[ "$NESTED_COMPLETE_RC" -eq 0 ]
check "L11a --tdd-complete counts a clean nested root as no change, so it needs no receipt" "$(verdict $?)"
NESTED_SET="$(bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --change-set 2>&1)"
printf '%s\n' "$NESTED_SET" | grep -qxF "root	-	$GITP5" \
  && printf '%s\n' "$NESTED_SET" | grep -qxF "root	inner	$INNER" \
  && ! printf '%s\n' "$NESTED_SET" | grep -q '^file	inner/'
check "L11 a clean nested root yields no <dir>/ line in --change-set" "$(verdict $?)"
bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --chain-done --session cr-nested >/dev/null 2>"$WORK/nested.err"; NESTED_RC=$?
[ "$NESTED_RC" -eq 0 ]
check "L12 a non-ignored nested root with every root clean gives a union of zero" "$(verdict $?)"
printf 'x\n' > "$INNER/new.txt"
DIRTY_SET="$(bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --change-set 2>&1)"
printf '%s\n' "$DIRTY_SET" | grep -qxF 'file	@inner/new.txt' && ! printf '%s\n' "$DIRTY_SET" | grep -q '^file	inner/'
check "L13 --change-set prints a code-root change under its @<label>/ spelling" "$(verdict $?)"
ROOTS_OUT="$(bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --code-roots 2>&1)"
[ "$ROOTS_OUT" = "inner $INNER" ]
check "L14 --code-roots prints one <label> <path> line per declared root" "$(verdict $?)"
bind_session cr-disabled "$ROOT" "$GITP"
inject_roots "$DIS_STATE" app "$APP"
OFF_ROOTS="$(bash "$ROOT/hooks/lib/zensu-log.sh" --code-roots 2>"$WORK/off-roots.err")"
[ -z "$OFF_ROOTS" ] && grep -qF 'multi-repo chains are not enabled in this build' "$WORK/off-roots.err"
check "L15 with the switch off --code-roots prints nothing and says the list is ignored" "$(verdict $?)"

PLUGIN_THROW="$WORK/plugin-throw"
cp -R "$PLUGIN_ON" "$PLUGIN_THROW"
{ printf 'throw new Error("fixture: the module fails to load");\n'; cat "$PLUGIN_ON/hooks/lib/code-roots-v1.js"; } > "$PLUGIN_THROW/hooks/lib/code-roots-v1.js"
GITP6="$WORK/projects/git-anchor-6"; mkrepo "$GITP6"; printf '.zensu/\n.session-control-test/\n' > "$GITP6/.gitignore"; commit_all "$GITP6" ignore
U8R="$SRC/union-eight"; mkrepo "$U8R"
bind_session cr-throw "$PLUGIN_THROW" "$GITP6"
bash "$PLUGIN_THROW/hooks/lib/zensu-log.sh" --tdd-begin --session cr-throw >/dev/null 2>&1
bash "$PLUGIN_THROW/hooks/lib/zensu-log.sh" --tdd-complete --session cr-throw >/dev/null 2>&1
inject_roots "$(state_file_of cr-throw)" eight "$U8R"
bash "$PLUGIN_THROW/hooks/lib/zensu-log.sh" --code-roots >"$WORK/throw-roots.out" 2>"$WORK/throw-roots.err"; TR_RC=$?
bash "$PLUGIN_THROW/hooks/lib/zensu-log.sh" --chain-done --session cr-throw >/dev/null 2>"$WORK/throw-done.err"; TD_RC=$?
[ "$TR_RC" -eq 2 ] && [ ! -s "$WORK/throw-roots.out" ] && grep -qF 'the declared code roots could not be read' "$WORK/throw-roots.err" \
  && [ "$TD_RC" -ne 0 ] && grep -qF 'the declared code roots could not be counted' "$WORK/throw-done.err"
check "L16 a module that fails to load makes --code-roots exit 2 and the union unavailable, never the anchor's own count ($TR_RC/$TD_RC)" "$(verdict $?)"

round_prepare_case() {
  local sid="$1" plugin="$2" project log plain declared plain_rc declared_rc
  project="$WORK/projects/$sid"; mkrepo "$project"; printf '.zensu/\n.session-control-test/\n' > "$project/.gitignore"; commit_all "$project" ignore
  mkrepo "$SRC/$sid"
  bind_session "$sid" "$plugin" "$project"
  bash "$plugin/hooks/lib/zensu-log.sh" --tdd-begin --session "$sid" >/dev/null 2>&1
  mkdir -p "$project/.zensu/logs"
  log="$project/.zensu/logs/round.log"
  printf 'S1 IMPL completed — files: base.txt\n' > "$log"
  plain="$(bash "$plugin/hooks/lib/zensu-log.sh" --round-prepare --round 0 --log "$log" 2>&1)"; plain_rc=$?
  inject_roots "$(state_file_of "$sid")" round "$SRC/$sid"
  declared="$(bash "$plugin/hooks/lib/zensu-log.sh" --round-prepare --round 0 --log "$log" 2>&1)"; declared_rc=$?
  printf '%s|%s\n%s\n----\n%s\n' "$plain_rc" "$declared_rc" "$plain" "$declared" > "$WORK/$sid.out"
  RP_RESULT="$plain_rc/$declared_rc"
}
round_prepare_case cr-round-on "$PLUGIN_ON"; RP_ON="$RP_RESULT"
round_prepare_case cr-round-off "$ROOT"; RP_OFF="$RP_RESULT"
[ "$RP_ON" = 0/2 ] && grep -qF 'ROUND PREPARE STOPPED — code-roots: this chain declares code roots' "$WORK/cr-round-on.out" \
  && [ "$RP_OFF" = 0/0 ] && ! grep -qF 'ROUND PREPARE STOPPED' "$WORK/cr-round-off.out"
check "L17 --round-prepare stops before any step while the chain declares code roots, and runs without them or with the switch off ($RP_ON $RP_OFF)" "$(verdict $?)"

echo "=== carrier: a begin, the shell resets and the chain reset ==="
CARRIERP="$WORK/projects/carrier"
mkrepo "$CARRIERP"
printf '.zensu/\n.session-control-test/\n' > "$CARRIERP/.gitignore"
commit_all "$CARRIERP" ignore
ROOTS_LIB='[{"label":"lib","path":"/zf/lib","top":"/zf/lib","commonDir":"/zf/lib/.git","baseline":"unborn"}]'
ROOTS_API='[{"label":"api","path":"/zf/api","top":"/zf/api","commonDir":"/zf/api/.git","baseline":"unborn"}]'
labels_of() {
  node -e '
    const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.stdout.write(Object.prototype.hasOwnProperty.call(d, "codeRoots") ? d.codeRoots.map((r) => r.label).join(",") : "absent");
  ' "$1" 2>/dev/null || printf 'unreadable'
}
phase_call() {
  (source "$ROOT/hooks/lib/zensu-tdd-phase.sh"; "$@") >/dev/null 2>&1
}
bind_session cr-carrier "$ROOT" "$CARRIERP"
CARRIER_STATE="$(state_file_of cr-carrier)"
phase_call tdd_begin_session cr-carrier false false false "" "" "" "" "" "$ROOTS_LIB"; C1A_RC=$?
C1A="$(labels_of "$CARRIER_STATE")"
phase_call tdd_begin_session cr-carrier false false false "" "" "" "" "" "$ROOTS_API"; C1B_RC=$?
C1B="$(labels_of "$CARRIER_STATE")"
phase_call tdd_begin_session cr-carrier false; C1C_RC=$?
C1C="$(labels_of "$CARRIER_STATE")"
[ "$C1A_RC$C1B_RC$C1C_RC" = 000 ] && [ "$C1A" = lib ] && [ "$C1B" = api ] && [ "$C1C" = absent ]
check "C1 a begin records its list, a new begin replaces it and a begin without one deletes it ($C1A_RC$C1B_RC$C1C_RC $C1A/$C1B/$C1C)" "$(verdict $?)"
phase_call tdd_begin_session cr-carrier false false false "" run-x 1 CONVERGE chain-x "$ROOTS_LIB"; C2A_RC=$?
phase_call tdd_begin_session cr-carrier false false false "" "" "" "" "" '{"label":"lib"}'; C2B_RC=$?
C2_LABELS="$(labels_of "$CARRIER_STATE")"
phase_call tdd_begin_session cr-carrier false false false "" run-x 1 CONVERGE chain-x; C2C_RC=$?
[ "$C2A_RC" -ne 0 ] && [ "$C2B_RC" -ne 0 ] && [ "$C2_LABELS" = absent ] && [ "$C2C_RC" -eq 0 ]
check "C2 a begin refuses a list beside an Autopilot binding and a value that is no JSON list, while the binding alone arms ($C2A_RC/$C2B_RC/$C2C_RC)" "$(verdict $?)"
inject_roots "$CARRIER_STATE" app "$APP"
phase_call tdd_reset_chain_flags cr-carrier; C3_RC=$?
C3="$(labels_of "$CARRIER_STATE")"
[ "$C3_RC" -eq 0 ] && [ "$C3" = app ]
check "C3 the chain reset keeps the declared list ($C3_RC $C3)" "$(verdict $?)"
phase_call tdd_clear_autopilot_session cr-carrier run-x 1 chain-x; C4A_RC=$?
C4A="$(labels_of "$CARRIER_STATE")"
inject_roots "$CARRIER_STATE" app "$APP"
phase_call tdd_clear_standalone_session cr-carrier; C4B_RC=$?
C4B="$(labels_of "$CARRIER_STATE")"
inject_roots "$CARRIER_STATE" app "$APP"
phase_call tdd_clear_session cr-carrier; C4C_RC=$?
C4C="$(labels_of "$CARRIER_STATE")"
[ "$C4A_RC$C4B_RC$C4C_RC" = 000 ] && [ "$C4A" = absent ] && [ "$C4B" = absent ] && [ "$C4C" = absent ]
check "C4 the Autopilot, the standalone and the session reset each delete the list ($C4A_RC$C4B_RC$C4C_RC $C4A/$C4B/$C4C)" "$(verdict $?)"

echo "=== Stop hook: the implementing-turn probe counts the union ==="
NUDGE_CFG="$WORK/nudge-config.json"
printf '{"hooks":{"implStopNudgeAfter":1}}\n' > "$NUDGE_CFG"
counter_of() {
  (source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"; tdd_get_counter "$(tdd_state_file "$1")" implStopCount) 2>/dev/null
}
nudge_case() {
  local sid="$1" project="$2" root="$3" dirty="$4" expect="$5" name="$6" count
  bind_session "$sid" "$PLUGIN_ON" "$project"
  bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --tdd-begin --session "$sid" >/dev/null 2>&1
  inject_roots "$(state_file_of "$sid")" nudge "$root"
  [ "$dirty" = dirty ] && printf 'x\n' >> "$root/base.txt"
  printf '{"session_id":"%s","hook_event_name":"Stop"}' "$sid" \
    | ZENSU_CONFIG="$NUDGE_CFG" bash "$PLUGIN_ON/hooks/stop-chain-enforcer.sh" >/dev/null 2>&1
  count="$(counter_of "$sid")"
  [ "$dirty" = dirty ] && git -C "$root" checkout -q -- base.txt
  [ "$count" = "$expect" ]
  check "$name (count=$count)" "$(verdict $?)"
}
N1R="$SRC/nudge-one"; mkrepo "$N1R"
N2R="$SRC/nudge-two"; mkrepo "$N2R"
N3R="$SRC/nudge-three"; mkrepo "$N3R"
NP1="$WORK/projects/nudge-git"; mkrepo "$NP1"; printf '.zensu/\n.session-control-test/\n' > "$NP1/.gitignore"; commit_all "$NP1" ignore
NP2="$WORK/projects/nudge-git-2"; mkrepo "$NP2"; printf '.zensu/\n.session-control-test/\n' > "$NP2/.gitignore"; commit_all "$NP2" ignore
NP3="$WORK/projects/nudge-folder"; mkdir -p "$NP3"
nudge_case cr-nudge-dirty "$NP1" "$N1R" dirty 1 "N1 the turn counter sees a change in a code root while the anchor is clean"
nudge_case cr-nudge-clean "$NP2" "$N2R" clean 0 "N2 clean roots and a clean anchor count no turn"
nudge_case cr-nudge-folder "$NP3" "$N3R" dirty 1 "N3 folder anchor: the turn counter sees a change in a code root"
grep -qF "in any code root the chain declared" "$ROOT/hooks/stop-chain-enforcer.sh" \
  && grep -qF "every declared code root that 'git diff --name-only HEAD' in the anchor does not list" "$ROOT/hooks/stop-chain-enforcer.sh"
check "N4 the zero-change note and the resume directive name the union, not the anchor's git diff alone" "$(verdict $?)"

echo "=== edit gate: every root's .zensu/state, test paths per owning root ==="
edit_out() {
  printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$1" "$2" \
    | bash "$PLUGIN_ON/hooks/pre-edit-tdd-reminder.sh" 2>/dev/null
}
EGP="$WORK/projects/edit-gate"; mkrepo "$EGP"; printf '.zensu/\n.session-control-test/\n' > "$EGP/.gitignore"; commit_all "$EGP" ignore
EGR="$EGP/test/app"; mkrepo "$EGR"; mkdir -p "$EGR/src" "$EGR/.zensu/state"
bind_session cr-edit "$PLUGIN_ON" "$EGP"
bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --tdd-begin --session cr-edit --tdd-mode strict >/dev/null 2>&1
inject_roots "$(state_file_of cr-edit)" app "$EGR"
EDIT_STATE_OUT="$(edit_out cr-edit "$EGR/.zensu/state/forged.json")"
printf '%s' "$EDIT_STATE_OUT" | grep -q '"permissionDecision":"deny"' \
  && printf '%s' "$EDIT_STATE_OUT" | grep -qF 'session-state files'
check "E1 the edit gate refuses a declared root's .zensu/state like the anchor's" "$(verdict $?)"
bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --phase RED_WRITE --step S1 >/dev/null 2>&1
bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --phase RED_RUN --step S1 >/dev/null 2>&1
bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --phase RED_FAIL --step S1 --reason "fixture red" >/dev/null 2>&1
EDIT_SRC_OUT="$(edit_out cr-edit "$EGR/src/main.js")"
EDIT_TEST_OUT="$(edit_out cr-edit "$EGR/tests/main.test.js")"
printf '%s' "$EDIT_SRC_OUT" | grep -q '"permissionDecision":"deny"' \
  && ! printf '%s' "$EDIT_TEST_OUT" | grep -q '"permissionDecision":"deny"'
E2_RC=$?
[ "$E2_RC" -eq 0 ] || printf '    src: %s\n    test: %s\n' "$EDIT_SRC_OUT" "$EDIT_TEST_OUT" | cut -c1-300
[ "$E2_RC" -eq 0 ]
check "E2 a root under a directory named test classifies its files relative to its own top" "$(verdict $?)"
TEST_SHAPE="$(source "$ROOT/hooks/lib/zensu-tdd-phase.sh"; tdd_is_test_path "$EGR/src/main.js" src/main.js; tdd_is_test_path "$EGR/src/main.js")"
[ "$TEST_SHAPE" = "false
true" ]
check "E3 tdd_is_test_path judges the owning-root shape when one is given and keeps the one-argument form ($(printf '%s' "$TEST_SHAPE" | tr '\n' ' '))" "$(verdict $?)"
edit_out_via() {
  printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$2" "$3" \
    | bash "$1/hooks/pre-edit-tdd-reminder.sh" 2>/dev/null
}
edit_unrooted_case() {
  local sid="$1" plugin="$2" spec="$3" name="$4" project root state_out src_out
  project="$WORK/projects/$sid"; mkrepo "$project"; printf '.zensu/\n.session-control-test/\n' > "$project/.gitignore"; commit_all "$project" ignore
  root="$project/test/app"; mkrepo "$root"; mkdir -p "$root/src" "$root/.zensu/state"
  bind_session "$sid" "$plugin" "$project"
  bash "$plugin/hooks/lib/zensu-log.sh" --tdd-begin --session "$sid" --tdd-mode strict >/dev/null 2>&1
  inject_roots "$(state_file_of "$sid")" "$spec" "$root"
  bash "$plugin/hooks/lib/zensu-log.sh" --phase RED_WRITE --step S1 >/dev/null 2>&1
  bash "$plugin/hooks/lib/zensu-log.sh" --phase RED_RUN --step S1 >/dev/null 2>&1
  bash "$plugin/hooks/lib/zensu-log.sh" --phase RED_FAIL --step S1 --reason "fixture red" >/dev/null 2>&1
  state_out="$(edit_out_via "$plugin" "$sid" "$root/.zensu/state/forged.json")"
  src_out="$(edit_out_via "$plugin" "$sid" "$root/src/main.js")"
  printf '%s' "$state_out" | grep -q '"permissionDecision":"deny"' \
    && printf '%s' "$state_out" | grep -qF 'session-state files' \
    && ! printf '%s' "$src_out" | grep -q '"permissionDecision":"deny"'
  check "$name" "$(verdict $?)"
}
edit_unrooted_case cr-edit-rejected "$PLUGIN_ON" "app:bad" "E4 a list the judge rejects still protects the root's .zensu/state and classifies its files relative to the anchor"
edit_unrooted_case cr-edit-disabled "$ROOT" app "E5 with the switch off the list still protects the root's .zensu/state and classifies its files relative to the anchor"

echo "=== reviewer and neutral profiles: protected .zensu of every root ==="
GATE_JS="$WORK/gate-check.js"
cat > "$GATE_JS" <<'NODE'
const path = require('path');
const fs = require('fs');
const [lib, project, root] = process.argv.slice(2);
const gate = require(lib);
fs.mkdirSync(path.join(project, 'inner', '.zensu', 'state'), { recursive: true });
fs.mkdirSync(path.join(root, '.zensu', 'state'), { recursive: true });
const base = {
  contextFile: path.join(project, 'context.json'),
  pluginData: path.join(project, 'plugin-data'),
  projectRoot: project,
  pluginRoot: path.dirname(path.dirname(path.dirname(lib))),
  toolCwd: project,
};
const read = (file) => ({ tool_name: 'Read', tool_input: { file_path: file }, agent_type: 'helper', agent_id: 'a1' });
const results = {
  reviewerNested: gate.protectedAccessViolation(read(path.join(project, 'inner', '.zensu', 'state', 'x.json')), { ...base, codeRootTops: [] }),
  reviewerPlain: gate.protectedAccessViolation(read(path.join(project, 'base.txt')), { ...base, codeRootTops: [] }),
  neutralDeclared: gate.neutralViolation(read(path.join(root, '.zensu', 'state', 'x.json')), { ...base, codeRootTops: [root] }),
  neutralRootFile: gate.neutralViolation(read(path.join(root, 'base.txt')), { ...base, codeRootTops: [root] }),
  neutralNestedNoList: gate.neutralViolation(read(path.join(project, 'inner', '.zensu', 'x')), { ...base, codeRootTops: [] }),
  reviewerDeclaredTraversal: gate.protectedAccessViolation({ tool_name: 'Grep', tool_input: { pattern: 'x', path: path.join(project, 'inner') }, agent_type: 'helper', agent_id: 'a1' }, { ...base, codeRootTops: [path.join(project, 'inner')] }),
  reviewerUndeclaredTraversal: gate.protectedAccessViolation({ tool_name: 'Grep', tool_input: { pattern: 'x', path: path.join(project, 'inner') }, agent_type: 'helper', agent_id: 'a1' }, { ...base, codeRootTops: [] }),
  brokenList: gate.declaredRootTops({ codeRoots: [{ label: 'X', path: root, top: root, commonDir: '', baseline: 'bad' }] }),
};
process.stdout.write(JSON.stringify({
  reviewerNested: Boolean(results.reviewerNested),
  reviewerPlain: Boolean(results.reviewerPlain),
  neutralDeclared: Boolean(results.neutralDeclared),
  neutralRootFile: Boolean(results.neutralRootFile),
  neutralNestedNoList: Boolean(results.neutralNestedNoList),
  reviewerDeclaredTraversal: Boolean(results.reviewerDeclaredTraversal),
  reviewerUndeclaredTraversal: Boolean(results.reviewerUndeclaredTraversal),
  brokenList: results.brokenList.length === 1,
}));
NODE
GATE_OUT="$(node "$GATE_JS" "$PLUGIN_ON/hooks/lib/reviewer-capability-v1.js" "$GITP5" "$APP" 2>&1)"
[ "$GATE_OUT" = '{"reviewerNested":true,"reviewerPlain":false,"neutralDeclared":true,"neutralRootFile":false,"neutralNestedNoList":true,"reviewerDeclaredTraversal":true,"reviewerUndeclaredTraversal":false,"brokenList":true}' ]
check "R1 the read-only check refuses a .zensu below the anchor and a traversal into a declared root's .zensu, the neutral check every declared root's .zensu, list absent or broken ($GATE_OUT)" "$(verdict $?)"

echo "=== opt-in Bash gate: the union from the stdin frame ==="
BSWG_DIR="$PLUGIN_ON/hooks/lib"
bswg_payload() {
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]},cwd:process.argv[2]}))' "$1" "$2"
}
bswg() {
  local project="$1" document="$2" command="$3" payload size
  payload="$(bswg_payload "$command" "$project")"
  if [ -n "$document" ]; then
    size="$(wc -c < "$document" | tr -d ' ')"
    { printf 'ZENSU-BSWG-FRAME-V1 %s\n' "$size"; cat "$document"; printf '%s' "$payload"; } \
      | (cd "$BSWG_DIR" && BSWG_MODE= PAYLOAD= BSWG_REANCHOR= CLAUDE_PROJECT_DIR="$project" node ./bash-source-write-parse.js)
  else
    { printf 'ZENSU-BSWG-FRAME-V1 0\n'; printf '%s' "$payload"; } \
      | (cd "$BSWG_DIR" && BSWG_MODE= PAYLOAD= BSWG_REANCHOR= CLAUDE_PROJECT_DIR="$project" ZENSU_CODE_ROOTS="$APP" node ./bash-source-write-parse.js)
  fi
}
BSWG_DOC="$WORK/bswg-doc.json"
printf '{"active":true}' > "$BSWG_DOC"
write_doc "$BSWG_DOC" app "$APP"
B1="$(bswg "$ANCHOR" "$BSWG_DOC" "echo x > $APP/src/new.js")"
B2="$(bswg "$ANCHOR" "" "echo x > $APP/src/new.js")"
[ -z "$B1" ] && printf '%s' "$B2" | grep -qF 'OUTSIDE this session'
check "B1 rule (B) allows a write inside a declared root and denies it without the frame, a root named in the environment included" "$(verdict $?)"
B3="$(bswg "$ANCHOR" "$BSWG_DOC" "echo x > $FOREIGN/new.js")"
printf '%s' "$B3" | grep -qF 'OUTSIDE this session'
check "B2 rule (B) still denies outside every union member" "$(verdict $?)"
B4="$(bswg "$ANCHOR" "$BSWG_DOC" "git -C $APP commit -qm x")"
B5="$(bswg "$ANCHOR" "" "git -C $APP commit -qm x")"
[ -z "$B4" ] && printf '%s' "$B5" | grep -qF 'OUTSIDE this session'
check "B3 rule (C) allows a git mutation inside a declared root and denies it without the frame" "$(verdict $?)"
TEMP_ZONE="$WORK/temp-zone"
mkrepo "$TEMP_ZONE/inside"
TEMP_DOC="$WORK/temp-doc.json"
printf '{"active":true}' > "$TEMP_DOC"
write_doc "$TEMP_DOC" inside "$TEMP_ZONE/inside"
B6="$(ZENSU_BSWGATE_TEMP_DIRS="$TEMP_ZONE" bswg "$ANCHOR" "$TEMP_DOC" "echo x > $TEMP_ZONE/other.js")"
B7="$(ZENSU_BSWGATE_TEMP_DIRS="$TEMP_ZONE" bswg "$ANCHOR" "" "echo x > $TEMP_ZONE/other.js")"
printf '%s' "$B6" | grep -qF 'OUTSIDE this session' && [ -z "$B7" ]
check "B4 TEMP_SAFE rejects a temp entry that contains any union member" "$(verdict $?)"
B8="$(cd "$ROOT/hooks/lib" && { printf 'ZENSU-BSWG-FRAME-V1 %s\n' "$(wc -c < "$BSWG_DOC" | tr -d ' ')"; cat "$BSWG_DOC"; bswg_payload "echo x > $APP/src/new.js" "$ANCHOR"; } \
  | BSWG_MODE= PAYLOAD= BSWG_REANCHOR= CLAUDE_PROJECT_DIR="$ANCHOR" node ./bash-source-write-parse.js)"
printf '%s' "$B8" | grep -qF 'OUTSIDE this session'
check "B5 with the switch off the frame widens nothing" "$(verdict $?)"
BSWG_DONE_DOC="$WORK/bswg-done-doc.json"
printf '{"active":true,"chainDone":true}' > "$BSWG_DONE_DOC"
write_doc "$BSWG_DONE_DOC" app "$APP"
BSWG_IDLE_DOC="$WORK/bswg-idle-doc.json"
printf '{"active":false}' > "$BSWG_IDLE_DOC"
write_doc "$BSWG_IDLE_DOC" app "$APP"
B5D="$(bswg "$ANCHOR" "$BSWG_DONE_DOC" "echo x > $APP/src/new.js")"
B5I="$(bswg "$ANCHOR" "$BSWG_IDLE_DOC" "echo x > $APP/src/new.js")"
printf '%s' "$B5D" | grep -qF 'OUTSIDE this session' && printf '%s' "$B5I" | grep -qF 'OUTSIDE this session'
check "B5b the list of a finished or an inactive chain widens nothing" "$(verdict $?)"
frame_verdict() {
  local head="$1" payload rc
  payload="$(bswg_payload "echo x > $FOREIGN/new.js" "$ANCHOR")"
  { printf '%s' "$head"; printf '%s' "$payload"; } \
    | (cd "$BSWG_DIR" && BSWG_MODE= PAYLOAD= BSWG_REANCHOR= CLAUDE_PROJECT_DIR="$ANCHOR" node ./bash-source-write-parse.js) > "$WORK/frame.out" 2>/dev/null
  rc=$?
  printf '%s/%s' "$rc" "$(wc -c < "$WORK/frame.out" | tr -d ' ')"
}
FRAME_PAST="$(frame_verdict "$(printf 'ZENSU-BSWG-FRAME-V1 4194304\n{}')")"
FRAME_OVER="$(frame_verdict "$(printf 'ZENSU-BSWG-FRAME-V1 4194305\n{}')")"
FRAME_TEXT="$(frame_verdict "$(printf 'ZENSU-BSWG-FRAME-V1 12x\n{}')")"
FRAME_OPEN="$(frame_verdict 'ZENSU-BSWG-FRAME-V1 2')"
FRAME_GOOD="$(frame_verdict "$(printf 'ZENSU-BSWG-FRAME-V1 2\n{}')")"
[ "$FRAME_PAST" = 1/0 ] && [ "$FRAME_OVER" = 1/0 ] && [ "$FRAME_TEXT" = 1/0 ] && [ "$FRAME_OPEN" = 1/0 ] \
  && [ "${FRAME_GOOD%%/*}" = 0 ] && [ "${FRAME_GOOD#*/}" -gt 0 ]
check "B5c a frame head whose size runs past the input, exceeds the bound, is no number or has no newline exits 1 and prints nothing, while a whole frame is judged ($FRAME_PAST $FRAME_OVER $FRAME_TEXT $FRAME_OPEN $FRAME_GOOD)" "$(verdict $?)"
RA_ANCHOR="$WORK/rule-a/anchor"
RA_ROOT="$WORK/rule-a/root"
mkrepo "$RA_ANCHOR"
mkrepo "$RA_ROOT"
mkdir -p "$RA_ANCHOR/src" "$RA_ROOT/src"
printf 'one\n' > "$RA_ANCHOR/src/tracked.js"
printf 'one\n' > "$RA_ROOT/src/tracked.js"
commit_all "$RA_ANCHOR" tracked
commit_all "$RA_ROOT" tracked
printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$WORK/rule-a/anchor-fsmonitor-ran" > "$WORK/rule-a/anchor-hook.sh"
printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$WORK/rule-a/root-fsmonitor-ran" > "$WORK/rule-a/root-hook.sh"
chmod +x "$WORK/rule-a/anchor-hook.sh" "$WORK/rule-a/root-hook.sh"
git -C "$RA_ANCHOR" config core.fsmonitor "$WORK/rule-a/anchor-hook.sh"
git -C "$RA_ROOT" config core.fsmonitor "$WORK/rule-a/root-hook.sh"
touch -t 202601010000 "$RA_ANCHOR/src/tracked.js" "$RA_ROOT/src/tracked.js"
RA_INDEX_BEFORE="$(node -e 'process.stdout.write(String(require("fs").statSync(process.argv[1]).mtimeMs))' "$RA_ROOT/.git/index")"
RA_DOC="$WORK/rule-a/doc.json"
printf '{"active":true}' > "$RA_DOC"
write_doc "$RA_DOC" root "$RA_ROOT"
B9="$(bswg "$RA_ANCHOR" "$RA_DOC" "echo x > $RA_ROOT/src/tracked.js")"
RA_INDEX_AFTER="$(node -e 'process.stdout.write(String(require("fs").statSync(process.argv[1]).mtimeMs))' "$RA_ROOT/.git/index")"
B10="$(bswg "$RA_ANCHOR" "$RA_DOC" "echo x > $RA_ANCHOR/src/tracked.js")"
printf '%s' "$B9" | grep -qF 'overwrite an existing git-tracked source file' \
  && [ ! -e "$WORK/rule-a/root-fsmonitor-ran" ] && [ "$RA_INDEX_BEFORE" = "$RA_INDEX_AFTER" ] \
  && printf '%s' "$B10" | grep -qF 'overwrite an existing git-tracked source file' \
  && [ -e "$WORK/rule-a/anchor-fsmonitor-ran" ]
check "B6 rule (A) asks a code root whether a file is tracked with the read-only prefix: its fsmonitor hook never runs and its index is not rewritten, while the anchor's plain probe runs the anchor's hook" "$(verdict $?)"
BH_PROJECT="$WORK/projects/bswg-hook"
mkrepo "$BH_PROJECT"
printf '.zensu/\n.session-control-test/\n' > "$BH_PROJECT/.gitignore"
commit_all "$BH_PROJECT" ignore
BH_ROOT="$SRC/wörk-root"
mkrepo "$BH_ROOT"
bind_session cr-bswg-hook "$PLUGIN_ON" "$BH_PROJECT"
bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --tdd-begin --session cr-bswg-hook >/dev/null 2>&1
inject_roots "$(state_file_of cr-bswg-hook)" wrk "$BH_ROOT"
BH_CFG="$WORK/bswg-on.json"
printf '%s' '{"hooks":{"bashWriteGate":true}}' > "$BH_CFG"
BH_LOCALE=""
for candidate in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
  if [ "$(LC_ALL="$candidate" bash -c 's="ö"; printf %s "${#s}"' 2>/dev/null)" = 1 ]; then BH_LOCALE="$candidate"; break; fi
done
bh_run() {
  node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:process.argv[1]},cwd:process.argv[2],session_id:"cr-bswg-hook"}))' "$1" "$BH_PROJECT" \
    | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY -u ZENSU_SESSION_CONTEXT -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_ON" CLAUDE_PROJECT_DIR="$BH_PROJECT" ZENSU_CONFIG="$BH_CFG" LC_ALL="${BH_LOCALE:-C}" \
      bash "$PLUGIN_ON/hooks/pre-bash-source-write-gate.sh" 2>/dev/null
}
B11="$(bh_run "echo x > $BH_ROOT/new.js")"
B12="$(bh_run "echo x > $FOREIGN/new.js")"
[ -z "$B11" ] && printf '%s' "$B12" | grep -qF 'OUTSIDE this session'
check "B7 the opt-in hook frames the workflow document, so a write into a declared root whose path holds a multibyte character is allowed and one outside every union member is denied (locale ${BH_LOCALE:-C})" "$(verdict $?)"
if [ -n "$BH_LOCALE" ]; then
  BH_STATE="$(state_file_of cr-bswg-hook)"
  BH_BYTES="$(wc -c < "$BH_STATE" | tr -d ' ')"
  BH_CHARS="$(LC_ALL="$BH_LOCALE" bash -c 'IFS= read -r -d "" d < "$1"; printf %s "${#d}"' _ "$BH_STATE")"
  [ -n "$BH_CHARS" ] && [ "$BH_CHARS" -lt "$BH_BYTES" ]
  check "B7b the framed document holds fewer characters than bytes under $BH_LOCALE, so B7 tells a byte count from a character count ($BH_CHARS < $BH_BYTES)" "$(verdict $?)"
else
  check "B7b no UTF-8 locale on this host, so B7 cannot tell a byte count from a character count" PASS
fi
BH_BIG_STATE="$(state_file_of cr-bswg-hook)"
node -e '
  const fs = require("fs");
  const document = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  document.padding = "x".repeat(Number(process.argv[2]));
  fs.writeFileSync(process.argv[1], JSON.stringify(document));
' "$BH_BIG_STATE" 4194304
B13="$(bh_run "echo x > $BH_ROOT/big.js")"
B14="$(bh_run "echo x > $BH_PROJECT/big.js")"
BH_MAX_HOOK="$(sed -n 's/^BSWG_FRAME_DOCUMENT_MAX=\([0-9][0-9]*\)$/\1/p' "$ROOT/hooks/pre-bash-source-write-gate.sh")"
BH_MAX_PARSER="$(node -e 'process.stdout.write(String(require(process.argv[1]).FRAME_DOCUMENT_MAX))' "$ROOT/hooks/lib/bash-source-write-parse.js")"
printf '%s' "$B13" | grep -qF 'OUTSIDE this session' && [ -z "$B14" ] \
  && [ -n "$BH_MAX_HOOK" ] && [ "$BH_MAX_HOOK" = "$BH_MAX_PARSER" ]
check "B7c a workflow document over the frame bound reaches the parser as the zero-length frame, so the session keeps the anchor-only rules, and the hook's bound equals the parser's ($BH_MAX_HOOK = $BH_MAX_PARSER)" "$(verdict $?)"

echo "=== doctor: the topology row ==="
run_doctor() {
  local plugin="$1" project="$2" key="$3"
  ZDOC_ZENSU=absent ZDOC_NODE=vT ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh \
  ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  CLAUDE_PROJECT_DIR="$project" \
  ZDOC_BINDING=bound ZDOC_SESSION_KEY="$key" ZDOC_SESSION_PROJECT_ROOT="$project" \
    node "$plugin/hooks/lib/zensu-doctor-report.js" 2>/dev/null
}
DOC_FOLDER="$WORK/projects/doctor-folder"
mkdir -p "$DOC_FOLDER/.zensu/logs"
mkrepo "$DOC_FOLDER/declared"
mkrepo "$DOC_FOLDER/undeclared"
bind_session cr-doctor "$PLUGIN_ON" "$DOC_FOLDER"
DOCTOR_KEY="$ZENSU_SESSION_KEY"
bash "$PLUGIN_ON/hooks/lib/zensu-log.sh" --tdd-begin --session cr-doctor >/dev/null 2>&1
inject_roots "$(state_file_of cr-doctor)" declared "$DOC_FOLDER/declared"
{
  printf 'S1 IMPL completed — files: %s/declared/base.txt\n' "$DOC_FOLDER"
  printf 'S2 IMPL completed — files: %s/undeclared/base.txt\n' "$DOC_FOLDER"
} > "$DOC_FOLDER/.zensu/logs/run.log"
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/run.log","claims":2,"clean":false}\n' \
  > "$DOC_FOLDER/.zensu/state/edit-landing-$DOCTOR_KEY.json"
DOCTOR_ON="$(run_doctor "$PLUGIN_ON" "$DOC_FOLDER" "$DOCTOR_KEY")"
printf '%s\n' "$DOCTOR_ON" | grep -F 'topology: this chain declares 1 code root' | grep -qF '`@declared/`'
D1_RC=$?
[ "$D1_RC" -eq 0 ] || printf '%s\n' "$DOCTOR_ON" | grep -i 'topology\|code root' | sed 's/^/    doctor: /'
[ "$D1_RC" -eq 0 ]
check "D1 the topology row lists the declared roots" "$(verdict $?)"
printf '%s\n' "$DOCTOR_ON" | grep -qF 'topology: the anchor is a folder anchor'
check "D2 the topology row names a folder anchor" "$(verdict $?)"
printf '%s\n' "$DOCTOR_ON" | grep -F 'topology: this session' | grep -F 'claims edits under' | grep -qF "$DOC_FOLDER/undeclared" \
  && ! printf '%s\n' "$DOCTOR_ON" | grep -F 'claims edits under' | grep -qF "$DOC_FOLDER/declared"
check "D3 the row still warns about an undeclared foreign root and not about a declared one" "$(verdict $?)"
bind_session cr-doctor "$PLUGIN_ON" "$DOC_FOLDER"
DOCTOR_OFF="$(run_doctor "$ROOT" "$DOC_FOLDER" "$DOCTOR_KEY")"
printf '%s\n' "$DOCTOR_OFF" | grep -qF 'this build ignores them'
check "D4 with the switch off the row says the declared roots are ignored" "$(verdict $?)"

echo ""
echo "code-roots: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
