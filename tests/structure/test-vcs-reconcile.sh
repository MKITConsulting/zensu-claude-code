#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$PLUGIN_DIR/hooks/lib/zensu-vcs.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$LIB" ]; then
  check "hooks/lib/zensu-vcs.sh exists" FAIL
  echo "----"
  echo "test-vcs-reconcile: $PASS PASS / $FAIL FAIL"
  exit 1
fi

check "R1 lib exists" PASS
bash -n "$LIB" 2>/dev/null && check "R2 bash -n syntax check passes" PASS || check "R2 bash -n syntax check passes" FAIL

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

SSH_STUB="$(mktemp -d -t vcsreconcile-ssh-XXXXXX)"; mkdir -p "$SSH_STUB/bin"
cat > "$SSH_STUB/bin/ssh" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$SSH_STUB/ssh.log"
for a in "\$@"; do h="\$a"; done
printf 'user git\nhostname %s\nport 22\n' "\$h"
STUB
chmod +x "$SSH_STUB/bin/ssh"
PATH="$SSH_STUB/bin:$PATH"; export PATH

det2() {
  local remote="$1" auth="$2" prov="${3:-}"
  local a="--detect"
  [ -n "$prov" ] && a="$a --provider $prov"
  env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
      ZENSU_VCS_TEST=1 \
      ZENSU_VCS_REMOTE="$remote" \
      ZENSU_VCS_FAKE_AUTH="$auth" \
      bash "$LIB" $a 2>/dev/null
}

expect() {
  local label="$1" out="$2" key="$3" want="$4" got
  got="$(field "$out" "$key")"
  [ "$got" = "$want" ] && check "$label: $key=$want" PASS || check "$label ($key got '$got' want '$want')" FAIL
}

O="$(det2 'git@gitlab.com:g/p.git' ready)"
expect "C1 gitlab ready"    "$O" cliName  glab
expect "C1 gitlab ready"    "$O" cliReady true
expect "C1 gitlab ready"    "$O" cliState ready
case "$(cat "$SSH_STUB/ssh.log" 2>/dev/null)" in
  *"-G -- gitlab.com"*) check "C1b an SSH remote reaches the suite's identity ssh, never the machine's ssh configuration" PASS ;;
  *) check "C1b an SSH remote reaches the suite's identity ssh, never the machine's ssh configuration" FAIL ;;
esac

O="$(det2 'git@gitlab.com:g/p.git' missing)"
expect "C2 gitlab CLI missing" "$O" cliName  glab
expect "C2 gitlab CLI missing" "$O" cliReady false
expect "C2 gitlab CLI missing" "$O" cliState missing

O="$(det2 'git@gitlab.com:g/p.git' unauthed)"
expect "C3 gitlab present-but-unauthed" "$O" cliName  glab
expect "C3 gitlab present-but-unauthed" "$O" cliReady false
expect "C3 gitlab present-but-unauthed" "$O" cliState unauthed

O="$(det2 'git@github.com:o/r.git' ready)"
expect "C4 github ready"    "$O" cliName  gh
expect "C4 github ready"    "$O" cliReady true
expect "C4 github ready"    "$O" cliState ready

O="$(det2 'git@github.com:o/r.git' missing)"
expect "C5 github CLI missing" "$O" cliName  gh
expect "C5 github CLI missing" "$O" cliReady false
expect "C5 github CLI missing" "$O" cliState missing

O="$(det2 'git@github.com:o/r.git' unauthed)"
expect "C6 github present-but-unauthed" "$O" cliName  gh
expect "C6 github present-but-unauthed" "$O" cliReady false
expect "C6 github present-but-unauthed" "$O" cliState unauthed

N1="$(field "$(det2 'git@gitlab.com:g/p.git' ready)" cliName)"
N2="$(field "$(det2 'git@gitlab.com:g/p.git' missing)" cliName)"
N3="$(field "$(det2 'git@gitlab.com:g/p.git' unauthed)" cliName)"
if [ "$N1" = glab ] && [ "$N1" = "$N2" ] && [ "$N2" = "$N3" ]; then
  check "C7 cliName invariant across auth states (provider-derived, no fallback to gh)" PASS
else
  check "C7 cliName invariant (ready='$N1' missing='$N2' unauthed='$N3')" FAIL
fi
rm -rf "$SSH_STUB"

echo "----"
echo "test-vcs-reconcile: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
