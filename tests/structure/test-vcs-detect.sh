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

. "$PLUGIN_DIR/tests/structure/lib-unit-registry.sh"
unit_check "C1 the repository-conventions unit file passes" "$PLUGIN_DIR/tests/structure/repo-conventions-v1.test.js"
unit_check_done "C1z every unit file the registry gives this suite was graded"

CV="$(mktemp -d -t vcsdetect-conv-XXXXXX)"
CV_CFG="$(mktemp -t vcsdetect-gitconfig-XXXXXX)"
CV_GIT() { env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$CV_CFG" git -C "$CV" -c user.name=Fixture -c user.email=fixture@example.test -c commit.gpgsign=false "$@" >/dev/null 2>&1; }
conv() { env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_VCS_TEST=1 ZENSU_VCS_FAKE_AUTH=ready "$@" 2>/dev/null; }
jfield() { printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const v=JSON.parse(s)[process.argv[1]];process.stdout.write(typeof v==="string"?v:JSON.stringify(v));}catch(_){process.stdout.write("UNPARSEABLE");}})' "$2"; }
CV_GIT init -q
mkdir -p "$CV/.github" "$CV/.gitlab/merge_request_templates" "$CV/.zensu/templates" "$CV/docs"
printf '## Summary\n' > "$CV/.github/pull_request_template.md"
printf '## Acceptance criteria\n' > "$CV/.zensu/templates/pr-body.md"
printf '## Checklist\n' > "$CV/docs/review-template.md"
printf '## Summary\n' > "$CV/.gitlab/merge_request_templates/Default.md"
printf 'rules\n' > "$CV/CONTRIBUTING.md"
printf 'rules\n' > "$CV/AGENTS.md"
printf 'rules\n' > "$CV/CLAUDE.md"
printf '{"extends":["@commitlint/config-conventional"]}\n' > "$CV/.commitlintrc.json"
CV_GIT add --all
CV_GIT commit -q -m 'feat(core): first' -m 'Signed-off-by: Fixture <fixture@example.test>'
CV_GIT commit -q --allow-empty -m 'Second change'
O="$(conv bash "$LIB" --conventions --repo "$CV" --provider github)"
eq_c() { [ "$2" = "$3" ] && check "$1" PASS || check "$1 (got '$2' want '$3')" FAIL; }
eq_c "C2 github: provider"                 "$(jfield "$O" provider)"          "github"
eq_c "C2 github: default PR template"      "$(jfield "$O" prTemplate)"        ".github/pull_request_template.md"
eq_c "C2 github: every template found"     "$(jfield "$O" prTemplates)"       '[".github/pull_request_template.md",".gitlab/merge_request_templates/Default.md"]'
eq_c "C2 github: commitlint config"        "$(jfield "$O" commitlint)"        '[".commitlintrc.json"]'
eq_c "C2 github: conventional share"       "$(jfield "$O" conventionalShare)" "0.5"
eq_c "C2 github: newest subjects first"    "$(jfield "$O" subjects)"          '["Second change","feat(core): first"]'
eq_c "C2 github: trailer counts"           "$(jfield "$O" trailers)"          '{"Co-authored-by":0,"Signed-off-by":1,"Assisted-by":0}'
eq_c "C2 github: contributing documents"   "$(jfield "$O" contributing)"      '["CONTRIBUTING.md"]'
eq_c "C2 github: AGENTS path"              "$(jfield "$O" agents)"            '["AGENTS.md"]'
eq_c "C2 github: CLAUDE path"              "$(jfield "$O" claude)"            '["CLAUDE.md"]'
eq_c "C2 github: plain overrides"          "$(jfield "$O" overrides)"         '[".zensu/templates/pr-body.md"]'
eq_c "C2 github: no refusal"               "$(jfield "$O" prTemplateRefused)" "null"
O="$(conv bash "$LIB" --conventions --repo "$CV" --provider github --template docs/review-template.md)"
eq_c "C8 a configured template reaches the probe and is reported" "$(jfield "$O" prTemplate)" "docs/review-template.md"
O="$(conv bash "$LIB" --conventions --repo "$CV" --provider github --template ../outside.md)"
eq_c "C8 a configured template outside the work tree is refused" "$(jfield "$O" prTemplate)" "null"
case "$(jfield "$O" prTemplateRefused)" in
  ("the path is not a relative path below the top level of the work tree") check "C8 the refusal names its reason" PASS ;;
  (*) check "C8 the refusal names its reason (got '$(jfield "$O" prTemplateRefused)')" FAIL ;;
esac
O="$(conv env ZENSU_VCS_REMOTE='git@gitlab.com:group/proj.git' bash "$LIB" --conventions --repo "$CV")"
eq_c "C3 gitlab detected through the --detect ladder" "$(jfield "$O" provider)"   "gitlab"
eq_c "C3 gitlab: Default.md is the default template"  "$(jfield "$O" prTemplate)" ".gitlab/merge_request_templates/Default.md"
O="$(conv env ZENSU_VCS_REMOTE='git@github.com:owner/repo.git' bash "$LIB" --conventions --repo "$CV")"
eq_c "C4 github detected through the --detect ladder" "$(jfield "$O" provider)"   "github"
O="$(conv bash "$LIB" --conventions --repo "$CV" --provider bitbucket)"; RC=$?
{ [ -z "$O" ] && [ "$RC" -ne 0 ]; } && check "C5 an unsupported --provider is refused" PASS \
  || check "C5 an unsupported --provider is refused (out='$O' rc=$RC)" FAIL
CV_OUT="$(mktemp -d -t vcsdetect-noconv-XXXXXX)"
O="$(conv bash "$LIB" --conventions --repo "$CV_OUT" --provider github)"; RC=$?
{ [ -z "$O" ] && [ "$RC" -eq 1 ]; } && check "C6 a directory outside every git work tree fails with exit 1" PASS \
  || check "C6 a directory outside every git work tree fails with exit 1 (out='$O' rc=$RC)" FAIL
O="$(env -i PATH=/dev/null "$BASH_ABS" "$LIB" --conventions --repo "$CV" --provider github 2>/dev/null)"; RC=$?
{ [ -z "$O" ] && [ "$RC" -ne 0 ]; } && check "C7 without node the verb fails closed" PASS \
  || check "C7 without node the verb fails closed (out='$O' rc=$RC)" FAIL
rm -rf "$CV" "$CV_OUT" "$CV_CFG"

HD="$(mktemp -d -t vcsdetect-ghhost-XXXXXX)"
mkdir -p "$HD/bin" "$HD/nogit"
. "$PLUGIN_DIR/tests/structure/lib-gh-host-fake.sh"
gh_host_fake_write "$HD/bin/gh" <<'FAKE'
exit 2
FAKE
cat > "$HD/bin/ssh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
[ "${FAKE_SSH_FAIL:-0}" = 1 ] && exit 255
[ "${1:-}" = -G ] || exit 255
shift
[ "${1:-}" = -- ] && shift
case "${1:-}" in
  gh-work|gh_work) printf 'user git\nhostname GitHub.com\nport 22\n' ;;
  gh-bad) printf 'user git\nhostname bad_host.example\nport 22\n' ;;
  *) printf 'user git\nhostname %s\nport 22\n' "${1:-}" ;;
esac
FAKE
chmod +x "$HD/bin/ssh"
hd_run() {
  local remote="$1"; shift
  : > "$HD/ssh.log"; : > "$HD/config.log"
  HD_OUT="$(cd "$HD/nogit" && env PATH="$HD/bin:$PATH" GH_HOST= FAKE_SSH_LOG="$HD/ssh.log" \
    FAKE_GH_CONFIG_LOG="$HD/config.log" ZENSU_VCS_REMOTE="$remote" "$@" \
    bash -c 'source "$1" && _zensu_vcs_gh_host' _ "$LIB" 2>"$HD/err")"
  HD_RC=$?
  HD_ERR="$(cat "$HD/err")"; HD_SSH="$(cat "$HD/ssh.log")"; HD_CONFIG="$(cat "$HD/config.log")"
}
hd_host() {
  local label="$1" want="$2"
  if [ "$HD_RC" -eq 0 ] && [ "$HD_OUT" = "$want" ]; then check "$label" PASS
  else check "$label (rc=$HD_RC out='$HD_OUT' err='$HD_ERR')" FAIL; fi
}
hd_refused() {
  local label="$1" needle="$2"
  if [ "$HD_RC" -ne 0 ] && [ -z "$HD_OUT" ]; then
    case "$HD_ERR" in *"$needle"*) check "$label" PASS ;; *) check "$label (stderr misses '$needle': '$HD_ERR')" FAIL ;; esac
  else check "$label (rc=$HD_RC out='$HD_OUT')" FAIL; fi
}
hd_run https://github.com/acme/widget.git
hd_host "HD1 an HTTPS github.com remote reads as github.com" github.com
{ [ "$HD_RC" -eq 0 ] && [ "$HD_OUT" = github.com ] && [ -z "$HD_SSH" ] && [ -z "$HD_CONFIG" ]; } && check "HD1b an HTTPS remote runs no ssh and github.com needs no gh login lookup" PASS \
  || check "HD1b an HTTPS remote runs no ssh and github.com needs no gh login lookup (ssh='$HD_SSH' config='$HD_CONFIG')" FAIL
hd_run ''
hd_host "HD2 an empty remote outside every repository reads as github.com, the cloud host --detect reports for it" github.com
hd_run https://WWW.GitHub.com/acme/widget.git
hd_host "HD3 the host is lowercased and a leading www. is dropped, as gh reads a remote" github.com
hd_run git@gh-work:acme/widget.git
hd_host "HD4 an SSH alias resolves through ssh -G to the host it names" github.com
case "$HD_SSH" in
  *"-G -- gh-work"*) check "HD4b the alias goes to ssh -G behind an end-of-options marker" PASS ;;
  *) check "HD4b the alias goes to ssh -G behind an end-of-options marker (ssh='$HD_SSH')" FAIL ;;
esac
hd_run ssh://git@ssh.github.com:443/acme/widget.git
hd_host "HD5 ssh.github.com reads as github.com" github.com
hd_run https://ghe.example.com/acme/widget.git FAKE_GH_LOGINS=ghe.example.com
hd_host "HD6 a GitHub Enterprise host gh is logged in to is accepted" ghe.example.com
[ "$HD_CONFIG" = ghe.example.com ] && check "HD6b the login is looked up for exactly that host" PASS \
  || check "HD6b the login is looked up for exactly that host (config='$HD_CONFIG')" FAIL
hd_run https://ghe.example.com/acme/widget.git
hd_refused "HD7 a host gh knows no login for is refused and the refusal names the login command" "gh auth login --hostname ghe.example.com"
case "$HD_ERR" in
  *GH_HOST*) check "HD7b the refusal names no GH_HOST route past the login check (err='$HD_ERR')" FAIL ;;
  *"gh auth login --hostname ghe.example.com"*) check "HD7b the refusal names no GH_HOST route past the login check" PASS ;;
  *) check "HD7b the refusal names no GH_HOST route past the login check (err='$HD_ERR')" FAIL ;;
esac
hd_run https://ghe.example.com/acme/widget.git GH_HOST=GHE.Example.com
hd_host "HD8 the host GH_HOST names is accepted without a login lookup" ghe.example.com
{ [ "$HD_RC" -eq 0 ] && [ "$HD_OUT" = ghe.example.com ] && [ -z "$HD_CONFIG" ]; } && check "HD8b no gh login lookup runs for the GH_HOST host" PASS \
  || check "HD8b no gh login lookup runs for the GH_HOST host (config='$HD_CONFIG')" FAIL
hd_run 'git@-oProxyCommand=touch:acme/widget.git'
hd_refused "HD9 an option-shaped remote host is refused as no valid host name" "not a valid host name"
{ [ "$HD_RC" -ne 0 ] && [ -z "$HD_OUT" ] && [ -z "$HD_SSH" ] && [ -z "$HD_CONFIG" ] && case "$HD_ERR" in *"not a valid host name"*) true ;; *) false ;; esac; } \
  && check "HD9b the refused host reaches neither ssh nor gh" PASS \
  || check "HD9b the refused host reaches neither ssh nor gh (ssh='$HD_SSH' config='$HD_CONFIG')" FAIL
hd_run git@gh-bad:acme/widget.git
hd_refused "HD10 a translated host that is no valid host name is refused" "not a valid host name"
{ [ "$HD_RC" -ne 0 ] && [ "$HD_SSH" = "-G -- gh-bad" ] && [ -z "$HD_CONFIG" ]; } && check "HD10b the refused translated host reaches no gh login lookup" PASS \
  || check "HD10b the refused translated host reaches no gh login lookup (rc=$HD_RC ssh='$HD_SSH' config='$HD_CONFIG')" FAIL
hd_run git@gh-work:acme/widget.git FAKE_SSH_FAIL=1
hd_refused "HD11 an alias ssh cannot resolve keeps its own name and is refused without a login" "gh auth login --hostname gh-work"
hd_run "https://$(printf '%064d' 0 | tr 0 a).example/acme/widget.git"
hd_refused "HD12 a host label longer than 63 characters is refused" "not a valid host name"
HD_OUT="$(env -i PATH=/dev/null ZENSU_VCS_REMOTE=https://github.com/acme/widget.git "$BASH_ABS" -c 'source "$1" && _zensu_vcs_gh_host' _ "$LIB" 2>"$HD/err")"
HD_RC=$?; HD_ERR="$(cat "$HD/err")"
hd_refused "HD13 without node the host is not derived" "node"
hd_run https://ghe.example.com/acme/widget.git FAKE_GH_EMPTY_LOGINS=ghe.example.com
hd_refused "HD14 a login lookup that exits 0 with an empty answer counts as no login" "gh auth login --hostname ghe.example.com"
hd_run git@gh_work:acme/widget.git
hd_host "HD15 an SSH alias with an underscore resolves through ssh -G" github.com
[ "$HD_SSH" = "-G -- gh_work" ] && check "HD15b the underscore alias reaches ssh -G unchanged" PASS \
  || check "HD15b the underscore alias reaches ssh -G unchanged (ssh='$HD_SSH')" FAIL
hd_run git@gh_work:acme/widget.git FAKE_SSH_FAIL=1
hd_refused "HD16 an underscore alias ssh cannot translate is no host name to pin" "not a valid host name"
{ [ "$HD_RC" -ne 0 ] && [ -z "$HD_CONFIG" ]; } && check "HD16b the untranslated underscore alias reaches no gh login lookup" PASS \
  || check "HD16b the untranslated underscore alias reaches no gh login lookup (config='$HD_CONFIG')" FAIL
hd_run git+ssh://git@gh-work/acme/widget.git
hd_host "HD17 a git+ssh remote is an SSH remote whose alias goes through ssh -G" github.com
hd_run ssh+git://git@gh-work/acme/widget.git
hd_host "HD18 an ssh+git remote is an SSH remote whose alias goes through ssh -G" github.com
hd_run 'gh-work:acme/odd://name.git'
hd_host "HD19 a scp-like remote whose path holds :// stays an SSH remote" github.com
hd_bad_host() {
  local label="$1" host="$2"
  hd_run "https://$host/acme/widget.git" FAKE_GH_LOGINS="$host"
  if [ "$HD_RC" -ne 0 ] && [ -z "$HD_OUT" ] && [ -z "$HD_SSH" ] && [ -z "$HD_CONFIG" ]; then
    case "$HD_ERR" in *"not a valid host name"*) check "$label" PASS ;; *) check "$label (err='$HD_ERR')" FAIL ;; esac
  else check "$label (rc=$HD_RC out='$HD_OUT' ssh='$HD_SSH' config='$HD_CONFIG')" FAIL; fi
}
hd_bad_host "HD20 a label that ends with a hyphen is refused before any lookup" ghe-.example.com
hd_bad_host "HD21 a label that starts with a hyphen is refused before any lookup" -ghe.example.com
hd_bad_host "HD22 a leading dot is refused before any lookup" .ghe.example.com
hd_bad_host "HD23 a trailing dot is refused before any lookup" ghe.example.com.
hd_bad_host "HD24 an empty label is refused before any lookup" ghe..example.com
HD_LONG="$(i=0; while [ "$i" -lt 25 ]; do printf 'abcdefghi.'; i=$((i + 1)); done; printf 'abc')"
hd_run "https://$HD_LONG/acme/widget.git" FAKE_GH_LOGINS="$HD_LONG"
hd_host "HD25 a host name of 253 characters is accepted" "$HD_LONG"
hd_bad_host "HD25b a host name of 254 characters is refused before any lookup" "${HD_LONG}x"
hd_repo() {
  mkdir -p "$1" && git -C "$1" init -q && git -C "$1" symbolic-ref HEAD refs/heads/main \
    && git -C "$1" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -q --no-verify --allow-empty -m init
}
hd_run_in() {
  local dir="$1"; shift
  : > "$HD/ssh.log"; : > "$HD/config.log"
  HD_OUT="$(cd "$dir" && env PATH="$HD/bin:$PATH" GH_HOST= FAKE_SSH_LOG="$HD/ssh.log" \
    FAKE_GH_CONFIG_LOG="$HD/config.log" ZENSU_VCS_REMOTE= "$@" \
    bash -c 'source "$1" && _zensu_vcs_gh_host' _ "$LIB" 2>"$HD/err")"
  HD_RC=$?
  HD_ERR="$(cat "$HD/err")"; HD_SSH="$(cat "$HD/ssh.log")"; HD_CONFIG="$(cat "$HD/config.log")"
}
hd_repo "$HD/local-upstream" && git -C "$HD/local-upstream" remote add origin https://ghe.example.com/acme/widget.git \
  && git -C "$HD/local-upstream" checkout -q -b feat --track main
hd_run_in "$HD/local-upstream" FAKE_GH_LOGINS=ghe.example.com
hd_host "HD26 a branch that tracks a local branch reads the host of origin" ghe.example.com
HD_URL="$(cd "$HD/local-upstream" && ZENSU_VCS_REMOTE= bash -c 'source "$1" && _zensu_vcs_remote_url .' _ "$LIB" 2>/dev/null)"
[ "$HD_URL" = https://ghe.example.com/acme/widget.git ] && check "HD26b the remote helper --detect shares falls back to origin for a local upstream" PASS \
  || check "HD26b the remote helper --detect shares falls back to origin for a local upstream (url='$HD_URL')" FAIL
hd_repo "$HD/disagree" && git -C "$HD/disagree" remote add upstream https://ghe.example.com/acme/widget.git \
  && git -C "$HD/disagree" remote add github https://github.com/acme/widget.git
hd_run_in "$HD/disagree" FAKE_GH_LOGINS=ghe.example.com
hd_refused "HD27 remotes on different hosts that the branch tracks none of are refused instead of read as github.com" "name different hosts"
case "$HD_ERR" in
  *ZENSU_VCS_REMOTE*"git branch --set-upstream-to"*) check "HD27b that refusal names ZENSU_VCS_REMOTE and git branch --set-upstream-to" PASS ;;
  *) check "HD27b that refusal names ZENSU_VCS_REMOTE and git branch --set-upstream-to (err='$HD_ERR')" FAIL ;;
esac
hd_repo "$HD/no-remote"
hd_run_in "$HD/no-remote"
hd_host "HD28 a work tree without any remote reads as github.com" github.com
hd_run /srv/git/widget.git
hd_refused "HD29 a remote URL that yields no host is refused instead of read as github.com" "names no GitHub host"
{ [ "$HD_RC" -ne 0 ] && [ -z "$HD_SSH" ] && [ -z "$HD_CONFIG" ]; } && check "HD29b the hostless remote reaches neither ssh nor gh" PASS \
  || check "HD29b the hostless remote reaches neither ssh nor gh (ssh='$HD_SSH' config='$HD_CONFIG')" FAIL
hd_run "git@$(printf '%0254d' 0 | tr 0 a):acme/widget.git"
hd_refused "HD30 an SSH alias longer than 253 characters is refused" "not a valid host name"
[ -z "$HD_SSH" ] && check "HD30b the overlong alias reaches no ssh" PASS \
  || check "HD30b the overlong alias reaches no ssh (ssh='$HD_SSH')" FAIL
hd_run 'git@-gh-work:acme/widget.git'
hd_refused "HD31 an SSH alias that starts with a hyphen is refused" "not a valid host name"
[ -z "$HD_SSH" ] && check "HD31b the hyphen-led alias reaches no ssh" PASS \
  || check "HD31b the hyphen-led alias reaches no ssh (ssh='$HD_SSH')" FAIL
hd_repo "$HD/github-only" && git -C "$HD/github-only" remote add github https://github.com/acme/widget.git
hd_run_in "$HD/github-only"
hd_host "HD32 a branch without an upstream in a work tree whose only remote is not origin reads the host of that remote" github.com
hd_repo "$HD/agree" && git -C "$HD/agree" remote add upstream https://ghe.example.com/acme/widget.git \
  && git -C "$HD/agree" remote add fork git@ghe.example.com:me/widget.git
hd_run_in "$HD/agree" FAKE_GH_LOGINS=ghe.example.com
hd_host "HD33 remotes that all name one host pin that host when the branch tracks none of them" ghe.example.com
hd_repo "$HD/unreadable" && printf '[remote "origin"\n\turl = https://ghe.example.com/acme/widget.git\n' >> "$HD/unreadable/.git/config"
hd_run_in "$HD/unreadable" FAKE_GH_LOGINS=ghe.example.com
hd_refused "HD34 a work tree whose remotes git cannot read is refused instead of read as github.com" "git cannot read the remotes"
{ [ "$HD_RC" -ne 0 ] && [ -z "$HD_SSH" ] && [ -z "$HD_CONFIG" ]; } && check "HD34b the unreadable work tree reaches neither ssh nor gh" PASS \
  || check "HD34b the unreadable work tree reaches neither ssh nor gh (ssh='$HD_SSH' config='$HD_CONFIG')" FAIL
hd_repo "$HD/ceiling" && mkdir -p "$HD/ceiling/sub" && git -C "$HD/ceiling" remote add origin https://ghe.example.com/acme/widget.git
hd_run_in "$HD/ceiling/sub" GIT_CEILING_DIRECTORIES="$HD/ceiling"
hd_host "HD35 a directory GIT_CEILING_DIRECTORIES keeps out of the repository above it reads as github.com" github.com
mkdir -p "$HD/agree/pkg/widget" && ln -s "$HD/agree/pkg/widget" "$HD/agree-link"
hd_run_in "$HD/agree-link" FAKE_GH_LOGINS=ghe.example.com
hd_host "HD36 a directory reached through a symlink into a work tree reads the host its remotes name" ghe.example.com
git init -q --bare "$HD/bare.git" && git -C "$HD/bare.git" remote add upstream https://ghe.example.com/acme/widget.git
hd_run_in "$HD/bare.git" FAKE_GH_LOGINS=ghe.example.com
hd_host "HD37 a bare repository reads the host its remotes name" ghe.example.com
mkdir -p "$HD/unreadable/pkg" && ln -s "$HD/unreadable/pkg" "$HD/unreadable-link"
hd_run_in "$HD/unreadable-link" FAKE_GH_LOGINS=ghe.example.com
hd_refused "HD38 a directory reached through a symlink into a work tree whose remotes git cannot read is refused" "git cannot read the remotes"
git init -q --bare "$HD/bare-unreadable.git" \
  && printf '[remote "origin"\n\turl = https://ghe.example.com/acme/widget.git\n' >> "$HD/bare-unreadable.git/config"
hd_run_in "$HD/bare-unreadable.git" FAKE_GH_LOGINS=ghe.example.com
hd_refused "HD39 a bare repository whose remotes git cannot read is refused" "git cannot read the remotes"
ln -s "$HD/ceiling" "$HD/ceiling-link"
hd_run_in "$HD/ceiling/sub" GIT_CEILING_DIRECTORIES="$HD/ceiling-link"
hd_host "HD40 a ceiling spelled through a symlink stops the walk where it stops git" github.com
mkdir -p "$HD/unreadable/sub" && ln -s "$HD/unreadable" "$HD/unreadable-ceiling"
hd_run_in "$HD/unreadable/sub" GIT_CEILING_DIRECTORIES=":$HD/unreadable-ceiling"
hd_refused "HD41 a ceiling after an empty entry is compared as written, as git compares it" "git cannot read the remotes"
hd_run_in "$HD/unreadable/sub" GIT_CEILING_DIRECTORIES=..
hd_refused "HD41b a relative ceiling is ignored, as git ignores it" "git cannot read the remotes"
hd_repo "$HD/mirror" && git -C "$HD/mirror" remote add origin https://ghe.example.com/acme/widget.git \
  && git -C "$HD/mirror" remote add mirror https://github.com/acme/widget.git
hd_run_in "$HD/mirror" FAKE_GH_LOGINS=ghe.example.com
hd_host "HD42 origin pins its host beside a mirror remote on another host" ghe.example.com
hd_repo "$HD/tracking" && git -C "$HD/tracking" remote add upstream https://ghe.example.com/acme/widget.git \
  && git -C "$HD/tracking" remote add origin https://github.com/me/widget.git \
  && git -C "$HD/tracking" update-ref refs/remotes/upstream/main HEAD \
  && git -C "$HD/tracking" branch --set-upstream-to upstream/main >/dev/null
hd_run_in "$HD/tracking" FAKE_GH_LOGINS=ghe.example.com
hd_host "HD43 the remote the current branch tracks pins its host beside origin on another host" ghe.example.com
rm -rf "$HD"

echo "----"
echo "test-vcs-detect: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
