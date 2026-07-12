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
  echo "test-vcs-detect: $PASS PASS / $FAIL FAIL"
  exit 1
fi

check "V1 lib exists" PASS
bash -n "$LIB" 2>/dev/null && check "V2 bash -n syntax check passes" PASS || check "V2 bash -n syntax check passes" FAIL

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

det() {
  local remote="$1" probe="${2:-}" prov="${3:-}" apibase="${4:-}" repodir="${5:-}"
  local a="--detect"
  [ -n "$prov" ] && a="$a --provider $prov"
  [ -n "$apibase" ] && a="$a --api-base $apibase"
  [ -n "$repodir" ] && a="$a --repo $repodir"
  env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
      ZENSU_VCS_TEST=1 \
      ZENSU_VCS_REMOTE="$remote" \
      ${probe:+ZENSU_VCS_PROBE_RESULT=$probe} \
      ZENSU_VCS_FAKE_AUTH=ready \
      bash "$LIB" $a 2>/dev/null
}

expect() {
  local label="$1" out="$2" key="$3" want="$4" got
  got="$(field "$out" "$key")"
  [ "$got" = "$want" ] && check "$label: $key=$want" PASS || check "$label ($key got '$got' want '$want')" FAIL
}

O="$(det 'git@github.com:owner/repo.git')"
expect "D1 github ssh"   "$O" provider github
expect "D1 github ssh"   "$O" edition  cloud
expect "D1 github ssh"   "$O" apiBase  "https://api.github.com"
expect "D1 github ssh"   "$O" repo     owner/repo

O="$(det 'https://github.com/owner/repo.git')"
expect "D2 github https" "$O" provider github
expect "D2 github https" "$O" edition  cloud

O="$(det 'git@gitlab.com:group/sub/proj.git')"
expect "D3 gitlab ssh subgroup" "$O" provider gitlab
expect "D3 gitlab ssh subgroup" "$O" edition  cloud
expect "D3 gitlab ssh subgroup" "$O" apiBase  "https://gitlab.com/api/v4"
expect "D3 gitlab ssh subgroup" "$O" repo     "group%2Fsub%2Fproj"

O="$(det 'git@git.corp.io:g/p.git' gitlab)"
expect "D4 gitlab self-hosted (probe)" "$O" provider gitlab
expect "D4 gitlab self-hosted (probe)" "$O" edition  selfhosted
expect "D4 gitlab self-hosted (probe)" "$O" apiBase  "https://git.corp.io/api/v4"
expect "D4 gitlab self-hosted (probe)" "$O" repo     "g%2Fp"

O="$(det 'https://ghe.corp.io/team/app.git' github-enterprise)"
expect "D5 github enterprise (probe)" "$O" provider github
expect "D5 github enterprise (probe)" "$O" edition  enterprise
expect "D5 github enterprise (probe)" "$O" apiBase  "https://ghe.corp.io/api/v3"
expect "D5 github enterprise (probe)" "$O" repo     team/app

O="$(det 'https://user@gitlab.com/g/p.git')"
expect "D6 https user@ gitlab" "$O" provider gitlab
expect "D6 https user@ gitlab" "$O" edition  cloud

O="$(det 'ssh://git@git.corp.io:22/g/p.git' gitlab)"
expect "D7 ssh:// scheme+port selfhosted" "$O" provider gitlab
expect "D7 ssh:// scheme+port selfhosted" "$O" edition  selfhosted
expect "D7 ssh:// scheme+port selfhosted" "$O" repo     "g%2Fp"

O="$(det 'git@git.corp.io:g/p.git' '' gitlab)"
expect "D8 forced provider gitlab" "$O" provider gitlab
expect "D8 forced provider gitlab" "$O" edition  selfhosted

O="$(det 'git@git.corp.io:g/p.git' '' github)"
expect "D9 forced provider github" "$O" provider github
expect "D9 forced provider github" "$O" edition  enterprise

O="$(det 'https://gitlab.com/g/p.git' '' '' 'https://gl.corp/api/v4')"
expect "D10 api-base override" "$O" apiBase "https://gl.corp/api/v4"
expect "D10 api-base override" "$O" provider gitlab

TMP="$(mktemp -d -t vcsdetect-XXXXXX)"; : > "$TMP/.gitlab-ci.yml"
O="$(det 'git@git.corp.io:g/p.git' none '' '' "$TMP")"
expect "D11 marker tiebreak gitlab" "$O" provider gitlab
expect "D11 marker tiebreak gitlab" "$O" edition  selfhosted
rm -rf "$TMP"

TMP="$(mktemp -d -t vcsdetect-XXXXXX)"; mkdir -p "$TMP/.github/workflows"
O="$(det 'git@git.corp.io:g/p.git' none '' '' "$TMP")"
expect "D12 marker tiebreak github" "$O" provider github
expect "D12 marker tiebreak github" "$O" edition  enterprise
rm -rf "$TMP"

TMP="$(mktemp -d -t vcsdetect-XXXXXX)"
O="$(det 'git@git.corp.io:g/p.git' none '' '' "$TMP")"
expect "D13 unknown (no probe, no marker)" "$O" provider unknown
expect "D13 unknown (no probe, no marker)" "$O" edition  ""
expect "D13 unknown (no probe, no marker)" "$O" apiBase  ""
expect "D13 unknown (no probe, no marker)" "$O" repo     ""
expect "D13 unknown (no probe, no marker)" "$O" cliName  ""
rm -rf "$TMP"

O="$(det 'git@github.com:owner/repo.git')"
for k in provider edition apiBase repo cliReady cliName cliState; do
  printf '%s\n' "$O" | grep -q "^$k=" && check "D14 output line present: $k" PASS || check "D14 output line present: $k" FAIL
done

O="$(det 'git@github.com:owner/repo.git' '' gitlab)"
expect "D15 forced provider on cloud host" "$O" provider gitlab
expect "D15 forced provider on cloud host" "$O" edition  cloud

if command -v git >/dev/null 2>&1; then
  GT="$(mktemp -d -t vcsdetect-git-XXXXXX)"
  git -C "$GT" init -q 2>/dev/null
  git -C "$GT" remote add origin 'https://github.com/acme/widget.git' 2>/dev/null
  O="$(env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_VCS_TEST=1 ZENSU_VCS_FAKE_AUTH=ready bash "$LIB" --detect --repo "$GT" 2>/dev/null)"
  expect "D16 real git remote resolution" "$O" provider github
  expect "D16 real git remote resolution" "$O" repo     acme/widget
  rm -rf "$GT"

  GT2="$(mktemp -d -t vcsdetect-git0-XXXXXX)"
  git -C "$GT2" init -q 2>/dev/null
  O="$(env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_VCS_TEST=1 bash "$LIB" --detect --repo "$GT2" 2>/dev/null)"
  expect "D17 git repo with no remote -> unknown" "$O" provider unknown
  rm -rf "$GT2"
else
  check "D16/D17 real git path (git present)" FAIL
fi

BASH_ABS="$(command -v bash)"
O="$(env -i PATH=/dev/null ZENSU_VCS_REMOTE='git@github.com:o/r.git' "$BASH_ABS" "$LIB" --detect 2>/dev/null)"
expect "D18 no-node degrade -> unknown" "$O" provider unknown
expect "D18 no-node degrade -> empty repo" "$O" repo     ""

ML="$(mktemp -d -t vcsdetect-ssrf-XXXXXX)"
for badhost in 127.0.0.1 169.254.169.254 10.0.0.5 192.168.1.1; do
  O="$(env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_VCS_TEST=1 ZENSU_VCS_REMOTE="git@${badhost}:g/p.git" bash "$LIB" --detect --repo "$ML" 2>/dev/null)"
  P="$(field "$O" provider)"
  [ "$P" = unknown ] && check "D19 probe-guard skips $badhost -> unknown" PASS || check "D19 probe-guard $badhost (got '$P')" FAIL
done
rm -rf "$ML"

MC="$(mktemp -d -t vcsdetect-cli-XXXXXX)"
O="$(env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_VCS_TEST=1 ZENSU_VCS_REMOTE='git@git.corp.io:g/p.git' ZENSU_VCS_PROBE_RESULT=none bash "$LIB" --detect --repo "$MC" 2>/dev/null)"
expect "D20 unknown real-auth empty cli" "$O" cliName  ""
expect "D20 unknown real-auth empty cli" "$O" cliState missing
expect "D20 unknown real-auth empty cli" "$O" cliReady false
rm -rf "$MC"

# D21/D22 — ZENSU_VCS_NO_PROBE=1 must make _zensu_vcs_probe skip curl and fall to
# the marker/unknown tiebreak (the offline mode /zensu:doctor relies on). A
# sentinel `curl` on PATH proves no outbound probe fires; TEST=1 + FAKE_AUTH keep
# auth deterministic WITHOUT stubbing the probe (no ZENSU_VCS_PROBE_RESULT set),
# so execution actually reaches the NO_PROBE branch.
NP="$(mktemp -d -t vcsdetect-noprobe-XXXXXX)"; mkdir -p "$NP/bin"
CURL_HIT="$NP/curl-was-called"
printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$CURL_HIT" > "$NP/bin/curl"; chmod +x "$NP/bin/curl"
noprobe() {
  env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" PATH="$NP/bin:$PATH" \
      ZENSU_VCS_TEST=1 ZENSU_VCS_FAKE_AUTH=ready ZENSU_VCS_NO_PROBE=1 \
      ZENSU_VCS_REMOTE='git@git.corp.io:g/p.git' bash "$LIB" --detect --repo "$1" 2>/dev/null
}
O="$(noprobe "$NP")"
expect "D21 NO_PROBE self-hosted no-marker -> unknown (offline)" "$O" provider unknown
[ ! -f "$CURL_HIT" ] && check "D21 NO_PROBE fired no curl" PASS || check "D21 NO_PROBE fired no curl (curl WAS called)" FAIL
: > "$NP/.gitlab-ci.yml"
O="$(noprobe "$NP")"
expect "D22 NO_PROBE falls to CI-marker tiebreak gitlab" "$O" provider gitlab
[ ! -f "$CURL_HIT" ] && check "D22 NO_PROBE (marker path) fired no curl" PASS || check "D22 NO_PROBE (marker path) fired no curl" FAIL
rm -rf "$NP"

echo "----"
echo "test-vcs-detect: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
