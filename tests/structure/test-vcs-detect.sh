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

# --- SSRF: userinfo `@` must not smuggle the post-@ authority into the host ---
# `https://a@b@127.0.0.1/x` once parsed host `b@127.0.0.1`, which passed the
# private-IP guard yet curl-connected to loopback. BOTH host captures (URL-form
# and SSH-form) now exclude `@`. A sentinel curl on PATH records every URL it is
# handed. ZENSU_VCS_TEST=1 WITHOUT PROBE_RESULT so the REAL probe path runs;
# FAKE_AUTH keeps auth deterministic.
SS="$(mktemp -d -t vcsdetect-ssrf-at-XXXXXX)"; mkdir -p "$SS/bin"
CURL_LOG="$SS/curl-args.log"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit 1\n' "$CURL_LOG" > "$SS/bin/curl"; chmod +x "$SS/bin/curl"
ssrf_run() { # ssrf_run <remote> : reset the curl log, run detect, echo its output
  : > "$CURL_LOG"
  env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" PATH="$SS/bin:$PATH" \
    ZENSU_VCS_TEST=1 ZENSU_VCS_FAKE_AUTH=ready ZENSU_VCS_FAKE_RESOLVE='git.corp.io=93.184.216.34' \
    ZENSU_VCS_REMOTE="$1" bash "$LIB" --detect --repo "$SS" 2>/dev/null
}
# positive control: a benign probeable self-hosted host DOES reach the sentinel
# curl (both probe URLs, since the sentinel exits non-2xx) — proves the harness
# (PATH sentinel + real probe path) is wired, so the negative asserts below are
# meaningful, not vacuously green.
ssrf_run 'https://git.corp.io/g/p.git' >/dev/null
{ grep -q 'git\.corp\.io/api/v4/version' "$CURL_LOG" && grep -q 'git\.corp\.io/api/v3/meta' "$CURL_LOG"; } \
  && check "D23 positive control: sentinel curl IS reached for a probeable host" PASS \
  || check "D23 positive control: sentinel curl IS reached for a probeable host" FAIL
# HTTPS-form multi-@ (URL-form host capture): must not reach loopback.
MAL="$(ssrf_run 'https://a@b@127.0.0.1/x.git')"
grep -q '127\.0\.0\.1' "$CURL_LOG" \
  && check "D23 https @-bypass reached loopback (SSRF)" FAIL \
  || check "D23 https @-bypass: curl never reached loopback (URL-form capture excludes @)" PASS
case "$(field "$MAL" provider)" in
  gitlab|github) check "D23 https @-bypass classified a forge (should stay unknown)" FAIL ;;
  *)             check "D23 https @-bypass -> not a forge (safe unknown/marker tiebreak)" PASS ;;
esac
# SSH-form multi-@ (`git@evil@127.0.0.1:g/p.git`) — the equally-exploitable SSH
# vector; guards the SSH-form host capture, which a mutation reverting only that
# branch would otherwise re-open with D21(https) still green.
ssrf_run 'git@evil@127.0.0.1:g/p.git' >/dev/null
grep -q '127\.0\.0\.1' "$CURL_LOG" \
  && check "D23b ssh @-bypass reached loopback (SSRF)" FAIL \
  || check "D23b ssh @-bypass: curl never reached loopback (SSH-form capture excludes @)" PASS
rm -rf "$SS"

# legit single-userinfo HTTPS + SSH forms must still parse to the right host (the
# fix must not break real `user@host` URLs). PROBE_RESULT stubs classification; a
# correct apiBase proves the host itself parsed intact past the userinfo.
O="$(det 'https://user@gitlab.example.com/g/p.git' gitlab)"
expect "D24 single-userinfo self-hosted host parses intact" "$O" provider gitlab
expect "D24 single-userinfo self-hosted host parses intact" "$O" apiBase "https://gitlab.example.com/api/v4"
O="$(det 'git@github.com:owner/repo.git')"
expect "D24 ssh git@host form still parses" "$O" provider github
expect "D24 ssh git@host form still parses" "$O" repo     owner/repo
# --- SSRF: named-host denylist is case-insensitive -------------------------
# `FOO.LOCALHOST` / `y.LOCAL` / `x.INTERNAL` must be rejected exactly like their
# lowercase forms; on `*.localhost`->127.0.0.1 resolvers an uppercase form was a
# loopback SSRF. A sentinel curl on PATH records probe attempts; assert these
# hosts are never handed to curl. ZENSU_VCS_TEST=1 WITHOUT PROBE_RESULT drives
# the REAL probe path; FAKE_AUTH keeps auth deterministic.
SC="$(mktemp -d -t vcsdetect-case-XXXXXX)"; mkdir -p "$SC/bin"
CLOG="$SC/curl.log"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit 1\n' "$CLOG" > "$SC/bin/curl"; chmod +x "$SC/bin/curl"
case_run() { : > "$CLOG"; env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" PATH="$SC/bin:$PATH" ZENSU_VCS_TEST=1 ZENSU_VCS_FAKE_AUTH=ready ZENSU_VCS_FAKE_RESOLVE='git.corp.io=93.184.216.34' ZENSU_VCS_REMOTE="$1" bash "$LIB" --detect --repo "$SC" >/dev/null 2>&1; }
# positive control: a benign probeable host DOES reach the sentinel curl — proves
# the harness is wired, so the negatives below are non-vacuous.
case_run 'https://git.corp.io/g/p.git'
grep -q 'git\.corp\.io/api/v4/version' "$CLOG" \
  && check "D25 positive control: sentinel curl IS reached for a benign probeable host" PASS \
  || check "D25 positive control: sentinel curl IS reached for a benign probeable host" FAIL
# uppercase / mixed-case + trailing-dot FQDN + .localdomain loopback-synonyms must NOT be probed
for bad in FOO.LOCALHOST y.LOCAL x.INTERNAL LOCALHOST Foo.LocalHost \
           foo.localhost. LOCALHOST. y.LOCAL. x.INTERNAL. localhost.localdomain \
           foo.localhost.. x.LOCALHOST..; do
  case_run "https://${bad}/x.git"
  [ -s "$CLOG" ] \
    && check "D25 loopback denylist: $bad was probed (SSRF)" FAIL \
    || check "D25 loopback denylist rejects $bad (never probed)" PASS
done
# SSH remote form of a mixed-case named host (a different parse path) must also be rejected
case_run 'git@FOO.LOCALHOST:x.git'
[ -s "$CLOG" ] \
  && check "D25 ssh mixed-case denylist: git@FOO.LOCALHOST was probed (SSRF)" FAIL \
  || check "D25 ssh mixed-case denylist rejects git@FOO.LOCALHOST (never probed)" PASS
rm -rf "$SC"

# --- SSRF: connection-time IP pinning closes IP-literal encodings + rebinding --
# probeable_host is a string pre-filter; the AUTHORITATIVE gate resolves the host,
# rejects if ANY resolved address is private/loopback (defeats round-robin
# rebinding), then curls with --resolve pinned to the checked IP (defeats the
# check-vs-connect TOCTOU). ZENSU_VCS_FAKE_RESOLVE mocks DNS under TEST=1; a PATH
# curl sentinel records what would be fetched.
IPP="$(mktemp -d -t vcsdetect-ippin-XXXXXX)"; mkdir -p "$IPP/bin"
ILOG="$IPP/curl.log"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit 1\n' "$ILOG" > "$IPP/bin/curl"; chmod +x "$IPP/bin/curl"
ippin_run() { : > "$ILOG"; env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" PATH="$IPP/bin:$PATH" ZENSU_VCS_TEST=1 ZENSU_VCS_FAKE_AUTH=ready ZENSU_VCS_FAKE_RESOLVE="$2" ZENSU_VCS_REMOTE="$1" bash "$LIB" --detect --repo "$IPP" >/dev/null 2>&1; }
# hosts that (string-)pass the pre-filter but RESOLVE to a private/loopback/
# link-local/metadata/transition address must NEVER be curled — one biting
# reject per classifier branch (else a mutant dropping the branch survives).
# The first three are realistic IP-literal encodings; the rest are ordinary
# hostnames that resolve into each rejected range.
for spec in \
  "0x7f.0.0.1=127.0.0.1" \
  "0x7f.0x0.0x0.0x1=127.0.0.1" \
  "foo.127.0.0.1.nip.io=127.0.0.1" \
  "meta.example.test=169.254.169.254" \
  "ten.example.test=10.0.0.5" \
  "rfc1918a.example.test=192.168.1.1" \
  "rfc1918b.example.test=172.16.0.1" \
  "cgnat.example.test=100.64.0.1" \
  "zeronet.example.test=0.0.0.1" \
  "mcast.example.test=224.0.0.1" \
  "overflow.example.test=999.1.2.3" \
  "v6lo.example.test=::1" \
  "v6un.example.test=::" \
  "v6ll.example.test=fe80::1" \
  "v6ula.example.test=fc00::1" \
  "v6mc.example.test=ff02::1" \
  "v6map.example.test=::ffff:127.0.0.1" \
  "v6nat64.example.test=64:ff9b::a9fe:a9fe" \
  "v66to4.example.test=2002:c058:6301::1"; do
  h="${spec%%=*}"; ip="${spec#*=}"
  ippin_run "https://${h}/x.git" "$spec"
  [ -s "$ILOG" ] \
    && check "D26 IP-pin: $h (-> $ip) was curled (SSRF)" FAIL \
    || check "D26 IP-pin rejects $h -> $ip (never curled)" PASS
done
# round-robin rebinding: ANY private address in the resolved set -> reject
ippin_run 'https://rebind.example.test/x.git' 'rebind.example.test=93.184.216.34,127.0.0.1'
[ -s "$ILOG" ] \
  && check "D26 IP-pin: rebind set (public+private) was curled" FAIL \
  || check "D26 IP-pin rejects a resolve set with ANY private address" PASS
# unresolvable host -> fail-closed (never curled)
ippin_run 'https://nxdomain.example.test/x.git' 'other.example.test=1.2.3.4'
[ -s "$ILOG" ] \
  && check "D26 IP-pin: unresolvable host was curled" FAIL \
  || check "D26 IP-pin fail-closed on an unresolvable host" PASS
# positive control: a benign host with TWO public IPs IS curled, pinned to the
# FIRST validated address (proves the harness, the --resolve pin, AND that
# pick() pins addrs[0] rather than an arbitrary resolved address).
ippin_run 'https://git.corp.io/x.git' 'git.corp.io=93.184.216.34,8.8.4.4'
grep -q -- '--resolve git.corp.io:443:93.184.216.34' "$ILOG" \
  && check "D26 IP-pin: benign host pinned to the FIRST validated IP" PASS \
  || check "D26 IP-pin benign --resolve pin (got: $(cat "$ILOG"))" FAIL
grep -q -- ':443:8.8.4.4' "$ILOG" \
  && check "D26 IP-pin: pinned a non-first resolved address (wrong)" FAIL \
  || check "D26 IP-pin: does not pin a non-first resolved address" PASS
grep -q 'git.corp.io/api/v4/version' "$ILOG" \
  && check "D26 IP-pin positive control: benign host actually probed" PASS \
  || check "D26 IP-pin positive control probed" FAIL
# positive control (IPv6): a benign host resolving to a PUBLIC IPv6 IS curled,
# pinned with a bare-v6 --resolve (curl reads everything after host:port: as the
# address) — exercises the IPv6-accept path end-to-end, not just the classifier.
ippin_run 'https://v6ok.example.test/x.git' 'v6ok.example.test=2606:2800:220:1:248:1893:25c8:1946'
grep -q -- '--resolve v6ok.example.test:443:2606:2800:220:1:248:1893:25c8:1946' "$ILOG" \
  && check "D26 IP-pin: public-IPv6 host curled with a bare-v6 --resolve pin" PASS \
  || check "D26 IP-pin public-IPv6 --resolve pin (got: $(cat "$ILOG"))" FAIL
rm -rf "$IPP"

echo "----"
echo "test-vcs-detect: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
