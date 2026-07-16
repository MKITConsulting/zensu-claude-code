#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$PLUGIN_DIR/hooks/lib/zensu-vcs.sh"
PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = PASS ]; then echo "  PASS  $label"; PASS=$((PASS + 1));
  else echo "  FAIL  $label"; FAIL=$((FAIL + 1)); fi
}
eq() { local l="$1" g="$2" w="$3"; [ "$g" = "$w" ] && check "$l" PASS || check "$l (got '$g' want '$w')" FAIL; }
has() { local l="$1" g="$2" n="$3"; case "$g" in *"$n"*) check "$l" PASS ;; *) check "$l (missing '$n')" FAIL ;; esac; }
jfield() { FIELD="$1" node -e 'var s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{var j=JSON.parse(s);var v=j[process.env.FIELD];process.stdout.write(v==null?"":(typeof v==="object"?JSON.stringify(v):String(v)));}catch(_){process.exit(1);}});'; }
IS_WINDOWS="$(node -p 'process.platform === "win32" ? "true" : "false"')"
make_file_symlink() {
  node -e '
    const fs=require("fs"),target=process.argv[1],link=process.argv[2];
    try {
      fs.symlinkSync(target,link,process.platform==="win32"?"file":undefined);
      process.exit(fs.lstatSync(link).isSymbolicLink()?0:1);
    } catch (_) { process.exit(1); }
  ' "$1" "$2"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vcs-reconcile.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/a.json" <<'JSON'
{"event":"COMMENT","body":"Stable body","commit_id":"abcdef0","comments":[{"body":"Second","line":9,"path":"b.js","side":"RIGHT"},{"path":"a.js","body":"First","side":"LEFT","line":4}]}
JSON
cat > "$WORK/b.json" <<'JSON'
{
  "comments": [ { "side": "RIGHT", "path": "b.js", "line": 9, "body": "Second" }, { "line": 4, "side": "LEFT", "body": "First", "path": "a.js" } ],
  "commit_id": "abcdef0", "body": "Stable body", "event": "COMMENT"
}
JSON
cat > "$WORK/context.json" <<'JSON'
{"event":"COMMENT","body":"Context body","commit_id":"abcdef0","comments":[{"body":"Context finding","line":11,"path":"renamed-new.js","side":"RIGHT"}]}
JSON
cat > "$WORK/summary.json" <<'JSON'
{"event":"COMMENT","body":"Summary only","commit_id":"abcdef0","comments":[]}
JSON
cat > "$WORK/single.json" <<'JSON'
{"event":"COMMENT","body":"Single","commit_id":"abcdef0","comments":[{"body":"One","line":9,"path":"b.js","side":"RIGHT"}]}
JSON
printf '%s' '{bad json' > "$WORK/bad.json"

source "$LIB" >/dev/null 2>&1

# Canonical payload hashing is independent of JSON key order and whitespace.
MA="$(_zensu_vcs_review_payload_meta github "$WORK/a.json" abcdef0 'team-review:v1:run-7')"
MB="$(_zensu_vcs_review_payload_meta github "$WORK/b.json" ABCDEF0 'team-review:v1:run-7')"
PDA="$(printf '%s' "$MA" | jfield payloadDigest)"; PDB="$(printf '%s' "$MB" | jfield payloadDigest)"
if [ -n "$PDA" ] && [ "$PDA" = "$PDB" ]; then check "M1 canonical payload digest is stable" PASS; else check "M1 canonical payload digest is stable" FAIL; fi
eq "M2 head SHA is normalized lowercase" "$(printf '%s' "$MB" | jfield headSha)" "abcdef0"
eq "M3 GitHub review is one atomic part" "$(printf '%s' "$MA" | jfield partCount)" "1"
MARKER="$(printf '%s' "$MA" | jfield marker)"
if printf '%s' "$MARKER" | grep -Eq '^<!-- zensu-review:v1:[0-9a-f]{64}:[0-9a-f]{64}:abcdef0:1:part=1/1 -->$'; then
  check "M4 marker has exact v1 envelope" PASS
else
  check "M4 marker has exact v1 envelope ($MARKER)" FAIL
fi
if _zensu_vcs_review_payload_meta github "$WORK/bad.json" abcdef0 op >/dev/null 2>&1; then
  check "M5 malformed payload fails closed" FAIL
else
  check "M5 malformed payload fails closed" PASS
fi
if _zensu_vcs_review_marker "$(printf '%064d' 0)" "$(printf '%064d' 0)" a 1 1 >/dev/null 2>&1; then
  check "M6 marker rejects an implausibly short head SHA" FAIL
else
  check "M6 marker rejects an implausibly short head SHA" PASS
fi
if _zensu_vcs_review_marker "$(printf '%064d' 0)" "$(printf '%064d' 0)" abcdef0 1000000 1 >/dev/null 2>&1; then
  check "M7 marker rejects part counts beyond the state contract" FAIL
else
  check "M7 marker rejects part counts beyond the state contract" PASS
fi
if _zensu_vcs_review_result present marker abcdef0 1 1 url >/dev/null 2>&1; then
  check "M8 result rejects a present status with posted writes" FAIL
else
  check "M8 result rejects a present status with posted writes" PASS
fi
if printf '%s' '{"html_url":42}' | _zensu_vcs_json_http_url_field html_url >/dev/null 2>&1 \
  || printf '%s' '{"html_url":true}' | _zensu_vcs_json_http_url_field html_url >/dev/null 2>&1 \
  || printf '%s' '{"html_url":"https://?"}' | _zensu_vcs_json_http_url_field html_url >/dev/null 2>&1; then
  check "M8b remote URL extraction rejects non-string primitives" FAIL
else
  check "M8b remote URL extraction rejects non-string primitives" PASS
fi
cat > "$WORK/poison.json" <<'JSON'
{"event":"COMMENT","body":"<!-- zensu-review:v1:attacker -->","commit_id":"abcdef0","comments":[]}
JSON
if _zensu_vcs_review_payload_meta github "$WORK/poison.json" abcdef0 op >/dev/null 2>&1; then
  check "M9 payload cannot self-inject the reserved marker namespace" FAIL
else
  check "M9 payload cannot self-inject the reserved marker namespace" PASS
fi
cat > "$WORK/short-head.json" <<'JSON'
{"event":"COMMENT","body":"short","comments":[]}
JSON
if _zensu_vcs_review_payload_meta github "$WORK/short-head.json" abcdef op >/dev/null 2>&1; then
  check "M10 payload metadata rejects a six-character head" FAIL
else
  check "M10 payload metadata rejects a six-character head" PASS
fi
if _zensu_vcs_review_marker "$(printf '%064d' 0)" "$(printf '%064d' 0)" abcdef 1 1 >/dev/null 2>&1; then
  check "M11 marker rejects a six-character head" FAIL
else
  check "M11 marker rejects a six-character head" PASS
fi
LONG_OP="$(printf '%0257d' 0)"
if _zensu_vcs_review_payload_meta github "$WORK/a.json" abcdef0 "$LONG_OP" >/dev/null 2>&1; then
  check "M12 operation key respects the durable-state 256-byte limit" FAIL
else
  check "M12 operation key respects the durable-state 256-byte limit" PASS
fi
if grep -qF -- '--input -' "$LIB" \
  && ! grep -qF 'zensu-review.XXXXXXXX' "$LIB" \
  && ! grep -qF 'zensu-review-notes.' "$LIB" \
  && ! grep -qF 'zensu-review-discussions.' "$LIB"; then
  check "M13 final publication and inventory streams avoid mutable pathname handoffs" PASS
else
  check "M13 final publication and inventory streams avoid mutable pathname handoffs" FAIL
fi
cat > "$WORK/control.json" <<'JSON'
{"event":"COMMENT","body":"bad\u0001body","comments":[]}
JSON
if _zensu_vcs_review_payload_meta github "$WORK/control.json" abcdef0 op >/dev/null 2>&1; then
  check "M14 remote body control bytes fail before digest or write" FAIL
else
  check "M14 remote body control bytes fail before digest or write" PASS
fi
cat > "$WORK/path-poison.json" <<'JSON'
{"event":"COMMENT","body":"ok","comments":[{"path":"<!-- zensu-review:v1:broken -->","body":"finding"}]}
JSON
if _zensu_vcs_review_payload_meta gitlab "$WORK/path-poison.json" abcdef0 op >/dev/null 2>&1; then
  check "M15 rendered comment paths cannot inject the reserved marker namespace" FAIL
else
  check "M15 rendered comment paths cannot inject the reserved marker namespace" PASS
fi
cat > "$WORK/line-less.json" <<'JSON'
{"event":"COMMENT","body":"ok","comments":[{"path":"a.js","body":"file-level"}]}
JSON
if _zensu_vcs_review_payload_meta github "$WORK/line-less.json" abcdef0 op >/dev/null 2>&1 \
  || ! _zensu_vcs_review_payload_meta gitlab "$WORK/line-less.json" abcdef0 op >/dev/null 2>&1; then
  check "M15a GitHub requires anchored comments while GitLab permits positionless discussions" FAIL
else
  check "M15a GitHub requires anchored comments while GitLab permits positionless discussions" PASS
fi
cat > "$WORK/range.json" <<'JSON'
{"event":"COMMENT","body":"ok","comments":[{"path":"a.js","body":"range","start_line":4,"start_side":"RIGHT","line":6,"side":"RIGHT"}]}
JSON
cat > "$WORK/bad-range.json" <<'JSON'
{"event":"COMMENT","body":"ok","comments":[{"path":"a.js","body":"range","start_line":7,"start_side":"LEFT","line":6,"side":"RIGHT"}]}
JSON
if _zensu_vcs_review_payload_meta github "$WORK/range.json" abcdef0 op >/dev/null 2>&1 \
  && ! _zensu_vcs_review_payload_meta github "$WORK/bad-range.json" abcdef0 op >/dev/null 2>&1 \
  && ! _zensu_vcs_review_payload_meta gitlab "$WORK/range.json" abcdef0 op >/dev/null 2>&1; then
  check "M15b GitHub range anchors are strict and never silently degraded on GitLab" PASS
else
  check "M15b GitHub range anchors are strict and never silently degraded on GitLab" FAIL
fi
SNAPSHOT_TARGET="$(mktemp "$WORK/snapshot.XXXXXXXX")"
if make_file_symlink "$WORK/a.json" "$WORK/payload-link.json"; then
  if _zensu_vcs_snapshot_review_payload "$WORK/payload-link.json" "$SNAPSHOT_TARGET" >/dev/null 2>&1; then
    check "M16 payload snapshot rejects symlink sources" FAIL
  else
    check "M16 payload snapshot rejects symlink sources" PASS
  fi
elif [ "$IS_WINDOWS" = true ]; then
  check "M16 payload snapshot rejects symlink sources (native file symlinks unavailable)" PASS
else
  check "M16 payload snapshot rejects symlink sources (fixture creation failed)" FAIL
fi
cp "$WORK/a.json" "$WORK/payload-hard.json"; ln "$WORK/payload-hard.json" "$WORK/payload-hard-alias.json"
if _zensu_vcs_snapshot_review_payload "$WORK/payload-hard.json" "$SNAPSHOT_TARGET" >/dev/null 2>&1; then
  check "M17 payload snapshot rejects multiply-linked sources" FAIL
else
  check "M17 payload snapshot rejects multiply-linked sources" PASS
fi
SNAPSHOT_DIGEST="$(_zensu_vcs_snapshot_review_payload "$WORK/a.json" "$SNAPSHOT_TARGET" 2>/dev/null || true)"
if [ "${#SNAPSHOT_DIGEST}" -eq 64 ] \
  && _zensu_vcs_review_payload_meta github "$SNAPSHOT_TARGET" abcdef0 \
    'team-review:v1:run-7' "$SNAPSHOT_DIGEST" >/dev/null 2>&1; then
  check "M18 payload metadata accepts the exact snapshotted byte digest" PASS
else
  check "M18 payload metadata accepts the exact snapshotted byte digest" FAIL
fi
printf ' ' >> "$SNAPSHOT_TARGET"
if _zensu_vcs_review_payload_meta github "$SNAPSHOT_TARGET" abcdef0 \
    'team-review:v1:run-7' "$SNAPSHOT_DIGEST" >/dev/null 2>&1; then
  check "M19 payload metadata rejects semantically equivalent post-snapshot bytes" FAIL
else
  check "M19 payload metadata rejects semantically equivalent post-snapshot bytes" PASS
fi
rm -f "$SNAPSHOT_TARGET"

# Pin both private inputs across GitLab planning and manifest generation. The
# control must render, while semantically harmless byte changes after each
# digest was captured must fail closed.
PINNED_PAYLOAD="$(mktemp "$WORK/pinned-payload.XXXXXXXX")"
PINNED_PLAN="$(mktemp "$WORK/pinned-plan.XXXXXXXX")"
PINNED_MANIFEST="$(mktemp "$WORK/pinned-manifest.XXXXXXXX")"
PINNED_PAYLOAD_DIGEST="$(_zensu_vcs_snapshot_review_payload "$WORK/a.json" "$PINNED_PAYLOAD" 2>/dev/null || true)"
PINNED_META="$(_zensu_vcs_review_payload_meta github "$PINNED_PAYLOAD" abcdef0 \
  'team-review:v1:run-7' "$PINNED_PAYLOAD_DIGEST" 2>/dev/null || true)"
PINNED_OD="$(printf '%s' "$PINNED_META" | jfield opDigest)"
PINNED_PD="$(printf '%s' "$PINNED_META" | jfield payloadDigest)"
PINNED_DIFF='[[{"old_path":"b.js","new_path":"b.js","diff":"@@ -8 +8,2 @@\n context\n+added\n"},{"old_path":"a.js","new_path":"a.js","diff":"@@ -4 +4,0 @@\n-removed\n"}]]'
PINNED_PLAN_DIGEST="$(printf '%s' "$PINNED_DIFF" | _zensu_vcs_review_gitlab_diff_plan \
  "$PINNED_PAYLOAD" '{"base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0"}' \
  abcdef0 "$PINNED_PD" "$PINNED_PLAN" "$PINNED_PAYLOAD_DIGEST" 2>/dev/null || true)"
PINNED_MANIFEST_DIGEST="$(_zensu_vcs_review_gitlab_manifest "$PINNED_PAYLOAD" "$PINNED_PLAN" \
  "$PINNED_OD" "$PINNED_PD" abcdef0 3 "$PINNED_MANIFEST" "$PINNED_PLAN_DIGEST" \
  "$PINNED_PAYLOAD_DIGEST" 2>/dev/null || true)"
if [ "${#PINNED_MANIFEST_DIGEST}" -eq 64 ]; then
  check "M19a exact payload and plan digests render the GitLab manifest" PASS
else
  check "M19a exact payload and plan digests render the GitLab manifest" FAIL
fi
printf ' ' >> "$PINNED_PLAN"
if _zensu_vcs_review_gitlab_manifest "$PINNED_PAYLOAD" "$PINNED_PLAN" \
    "$PINNED_OD" "$PINNED_PD" abcdef0 3 "$PINNED_MANIFEST" "$PINNED_PLAN_DIGEST" \
    "$PINNED_PAYLOAD_DIGEST" >/dev/null 2>&1; then
  check "M19b post-plan byte mutation cannot reach manifest generation" FAIL
else
  check "M19b post-plan byte mutation cannot reach manifest generation" PASS
fi
PINNED_PLAN_DIGEST="$(printf '%s' "$PINNED_DIFF" | _zensu_vcs_review_gitlab_diff_plan \
  "$PINNED_PAYLOAD" '{"base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0"}' \
  abcdef0 "$PINNED_PD" "$PINNED_PLAN" "$PINNED_PAYLOAD_DIGEST" 2>/dev/null || true)"
printf ' ' >> "$PINNED_PAYLOAD"
if _zensu_vcs_review_gitlab_manifest "$PINNED_PAYLOAD" "$PINNED_PLAN" \
    "$PINNED_OD" "$PINNED_PD" abcdef0 3 "$PINNED_MANIFEST" "$PINNED_PLAN_DIGEST" \
    "$PINNED_PAYLOAD_DIGEST" >/dev/null 2>&1; then
  check "M19c post-meta private payload mutation cannot reach manifest generation" FAIL
else
  check "M19c post-meta private payload mutation cannot reach manifest generation" PASS
fi
rm -f "$PINNED_PAYLOAD" "$PINNED_PLAN" "$PINNED_MANIFEST"

if bash -c 'for f in _zensu_vcs_reconcile_review _zensu_vcs_snapshot_review_payload _zensu_vcs_review_present_parts _zensu_vcs_review_full_parts _zensu_vcs_review_has_part _zensu_vcs_review_validate_diffrefs _zensu_vcs_review_gitlab_diff_plan _zensu_vcs_review_gitlab_manifest _zensu_vcs_review_gitlab_publisher_id _zensu_vcs_review_gitlab_call; do type "$f" >/dev/null 2>&1 || exit 1; done'; then
  check "M20 exported reconcile function retains every transitive helper" PASS
else
  check "M20 exported reconcile function retains every transitive helper" FAIL
fi
if bash "$LIB" --reconcile-review --provider github --provider github --repo-id acme/widget --expected-head abcdef0 --operation-key op 42 "$WORK/a.json" >/dev/null 2>&1; then
  check "M21 duplicate reconcile options fail closed" FAIL
else
  check "M21 duplicate reconcile options fail closed" PASS
fi
if bash "$LIB" --reconcile-review --provider github --repo-id acme/widget --expected-head abcdef0 --operation-key op 42 "$WORK/a.json" extra >/dev/null 2>&1; then
  check "M22 extra reconcile positionals fail closed" FAIL
else
  check "M22 extra reconcile positionals fail closed" PASS
fi
if _zensu_vcs_review_validate_diffrefs '{"base_sha":"BA5E000","start_sha":"57a2700","head_sha":"abcdef0"}' abcdef0 1 >/dev/null 2>&1; then
  check "M23 diff refs use one canonical lowercase hexadecimal form" FAIL
else
  check "M23 diff refs use one canonical lowercase hexadecimal form" PASS
fi
DUPLICATE_DIFF='[[{"old_path":"b.js","new_path":"b.js","diff":"@@ -8 +8,2 @@\n context\n+added\n"},{"old_path":"b.js","new_path":"b.js","diff":"@@ -8 +8,2 @@\n context\n+added\n"}]]'
DUPLICATE_PLAN="$(printf '%s' "$DUPLICATE_DIFF" | _zensu_vcs_review_gitlab_diff_plan "$WORK/single.json" '{"base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0"}' abcdef0)"
eq "M24 ambiguous GitLab anchors degrade deterministically to general discussions" \
  "$(printf '%s' "$DUPLICATE_PLAN" | jfield comments)" '[{"kind":"general"}]'
OVERFLOW_DIFF='[[{"old_path":"b.js","new_path":"b.js","diff":"@@ -9007199254740991,2 +8,2 @@\n context\n context\n"}]]'
if printf '%s' "$OVERFLOW_DIFF" | _zensu_vcs_review_gitlab_diff_plan "$WORK/single.json" '{"base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0"}' abcdef0 >/dev/null 2>&1; then
  check "M25 overflowing diff coordinates fail closed" FAIL
else
  check "M25 overflowing diff coordinates fail closed" PASS
fi

# Marker inventory reads every GitHub page and rejects ambiguity.
OD="$(printf '%s' "$MA" | jfield opDigest)"; PD="$(printf '%s' "$MA" | jfield payloadDigest)"
GH_EMPTY='[{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}]'
eq "I1 empty GitHub inventory" "$(printf '%s' "$GH_EMPTY" | _zensu_vcs_review_inventory github "$OD" "$PD" abcdef0 1 | jfield present)" "[]"
GH_PRESENT="[{\"data\":{\"repository\":{\"pullRequest\":{\"reviews\":{\"nodes\":[{\"id\":\"r1\",\"url\":\"https://review/1\",\"body\":\"$MARKER\\n\\nStable body\"}],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}}}}}]"
eq "I2 exact GitHub marker is present" "$(printf '%s' "$GH_PRESENT" | _zensu_vcs_review_inventory github "$OD" "$PD" abcdef0 1 | jfield present)" "[1]"
GH_DUP="$(MARKER="$MARKER" node -e 'var m=process.env.MARKER;process.stdout.write(JSON.stringify([{data:{repository:{pullRequest:{reviews:{nodes:[{id:"r1",body:m},{id:"r2",body:m}],pageInfo:{hasNextPage:false,endCursor:null}}}}}}]));')"
if printf '%s' "$GH_DUP" | _zensu_vcs_review_inventory github "$OD" "$PD" abcdef0 1 >/dev/null 2>&1; then
  check "I3 duplicate exact marker fails closed" FAIL
else
  check "I3 duplicate exact marker fails closed" PASS
fi
GH_BAD='[{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[{"id":"r1","body":"<!-- zensu-review:v1:broken -->"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}]'
if printf '%s' "$GH_BAD" | _zensu_vcs_review_inventory github "$OD" "$PD" abcdef0 1 >/dev/null 2>&1; then
  check "I4 malformed marker fails closed" FAIL
else
  check "I4 malformed marker fails closed" PASS
fi
GH_CONFLICT="${GH_PRESENT/$PD/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff}"
if printf '%s' "$GH_CONFLICT" | _zensu_vcs_review_inventory github "$OD" "$PD" abcdef0 1 >/dev/null 2>&1; then
  check "I5 same operation with conflicting payload fails closed" FAIL
else
  check "I5 same operation with conflicting payload fails closed" PASS
fi
if printf '%s' 'not json' | _zensu_vcs_review_inventory github "$OD" "$PD" abcdef0 1 >/dev/null 2>&1; then
  check "I6 malformed remote read fails closed" FAIL
else
  check "I6 malformed remote read fails closed" PASS
fi
GH_TRUNCATED='[{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":"next"}}}}}}]'
if printf '%s' "$GH_TRUNCATED" | _zensu_vcs_review_inventory github "$OD" "$PD" abcdef0 1 >/dev/null 2>&1; then
  check "I7 truncated GitHub pagination fails closed" FAIL
else
  check "I7 truncated GitHub pagination fails closed" PASS
fi
GL_ID_CONFLICT="$(MARKER="$MARKER" node -e 'var m=process.env.MARKER;process.stdout.write(JSON.stringify({notes:[[{id:7,type:null,body:m}]],discussions:[[{id:"d",individual_note:true,notes:[{id:7,type:null,body:"<!-- zensu-review:broken -->"}]}]]}));')"
if printf '%s' "$GL_ID_CONFLICT" | _zensu_vcs_review_inventory gitlab "$OD" "$PD" abcdef0 1 >/dev/null 2>&1; then
  check "I8 duplicate note ID with conflicting content fails closed" FAIL
else
  check "I8 duplicate note ID with conflicting content fails closed" PASS
fi
GL_URL_CONFLICT="$(MARKER="$MARKER" node -e 'var m=process.env.MARKER;process.stdout.write(JSON.stringify({notes:[[{id:7,type:null,body:m,web_url:"https://one"}]],discussions:[[{id:"d",individual_note:true,notes:[{id:7,type:null,body:m,web_url:"https://two"}]}]]}));')"
if printf '%s' "$GL_URL_CONFLICT" | _zensu_vcs_review_inventory gitlab "$OD" "$PD" abcdef0 1 >/dev/null 2>&1; then
  check "I9 duplicate note ID with conflicting URL fails closed" FAIL
else
  check "I9 duplicate note ID with conflicting URL fails closed" PASS
fi
GH_LEGACY='[{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[{"id":"legacy","url":"https://review/legacy","body":"text zensu-review: is harmless; <!-- zensu-review:deadbeef -->; <!-- zensu:pr7:deadbeef -->"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}]'
eq "I10 legacy marker and unrelated text are ignored" "$(printf '%s' "$GH_LEGACY" | _zensu_vcs_review_inventory github "$OD" "$PD" abcdef0 1 | jfield present)" "[]"
GH_ERRORS='[{"errors":[{"message":"partial data"}],"data":{"repository":{"pullRequest":{"reviews":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}]'
if printf '%s' "$GH_ERRORS" | _zensu_vcs_review_inventory github "$OD" "$PD" abcdef0 1 >/dev/null 2>&1; then
  check "I11 GitHub GraphQL errors fail closed despite partial review data" FAIL
else
  check "I11 GitHub GraphQL errors fail closed despite partial review data" PASS
fi
GH_COMPOSITE_ID="$(MARKER="$MARKER" node -e 'var m=process.env.MARKER;process.stdout.write(JSON.stringify([{data:{repository:{pullRequest:{reviews:{nodes:[{id:{bad:true},url:"https://review/1",body:m}],pageInfo:{hasNextPage:false,endCursor:null}}}}}}]));')"
if printf '%s' "$GH_COMPOSITE_ID" | _zensu_vcs_review_inventory github "$OD" "$PD" abcdef0 1 >/dev/null 2>&1; then
  check "I12 GitHub review IDs must be nonempty strings" FAIL
else
  check "I12 GitHub review IDs must be nonempty strings" PASS
fi
GH_MISSING_URL="$(MARKER="$MARKER" node -e 'var m=process.env.MARKER;process.stdout.write(JSON.stringify([{data:{repository:{pullRequest:{reviews:{nodes:[{id:"r-no-url",url:null,body:m}],pageInfo:{hasNextPage:false,endCursor:null}}}}}}]));')"
if printf '%s' "$GH_MISSING_URL" | _zensu_vcs_review_inventory github "$OD" "$PD" abcdef0 1 >/dev/null 2>&1; then
  check "I13 an attested GitHub review requires its review URL" FAIL
else
  check "I13 an attested GitHub review requires its review URL" PASS
fi
GL_COMPOSITE_ID="$(MARKER="$MARKER" node -e 'var m=process.env.MARKER;process.stdout.write(JSON.stringify({notes:[{id:{bad:true},type:null,body:m}],discussions:[]}));')"
if printf '%s' "$GL_COMPOSITE_ID" | _zensu_vcs_review_inventory gitlab "$OD" "$PD" abcdef0 1 >/dev/null 2>&1; then
  check "I14 GitLab note IDs must be positive integers" FAIL
else
  check "I14 GitLab note IDs must be positive integers" PASS
fi
if printf '%s' '{"notes":[],"discussions":[{"id":"d-empty","individual_note":false,"notes":[]}]}' | _zensu_vcs_review_inventory gitlab "$OD" "$PD" abcdef0 1 >/dev/null 2>&1; then
  check "I15 truncated empty GitLab discussions fail closed" FAIL
else
  check "I15 truncated empty GitLab discussions fail closed" PASS
fi

# End-to-end GitHub operation: OPEN/head checks before and after, one POST, then present.
mkdir -p "$WORK/bin" "$WORK/state"
cat > "$WORK/bin/gh" <<'FAKE'
#!/bin/bash
set -u
printf '%s\n' "$*" >> "$FAKE_DIR/calls"
if [ "${1:-}" = api ] && [ "${2:-}" = graphql ]; then
  if [ "${FAKE_MUTATE_PAYLOAD:-0}" = 1 ] && [ ! -f "$FAKE_DIR/payload-mutated" ]; then
    printf '%s' '{"event":"COMMENT","body":"MUTATED AFTER DIGEST","commit_id":"abcdef0","comments":[]}' > "$ORIGINAL_PAYLOAD"
    : > "$FAKE_DIR/payload-mutated"
  fi
  if [ "${FAKE_DRIFT_DURING_INVENTORY:-0}" = 1 ] && [ ! -f "$FAKE_DIR/body" ]; then
    : > "$FAKE_DIR/drift-before-write"
  fi
  if [ -f "$FAKE_DIR/body" ]; then
    BODY_FILE="$FAKE_DIR/body" node -e 'var fs=require("fs"),b=fs.readFileSync(process.env.BODY_FILE,"utf8");process.stdout.write(JSON.stringify([{data:{repository:{pullRequest:{reviews:{nodes:[{id:"r1",url:"https://github.test/acme/widget/pull/42#pullrequestreview-1",body:b}],pageInfo:{hasNextPage:false,endCursor:null}}}}}}]));'
  else
    printf '%s' '[{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}]'
  fi
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = 'repos/acme/widget/pulls/42' ]; then
  if [ "${FAKE_MUTATE_PRIVATE_PAYLOAD:-0}" = 1 ] && [ ! -f "$FAKE_DIR/private-payload-mutated" ]; then
    for snapshot in "$TMPDIR"/zensu-review-payload.*; do
      [ -f "$snapshot" ] || continue
      cp "$snapshot" "$snapshot.swap" || exit 2
      printf ' ' >> "$snapshot.swap" || exit 2
      mv "$snapshot.swap" "$snapshot" || exit 2
    done
    : > "$FAKE_DIR/private-payload-mutated"
  fi
  head=abcdef0
  [ -f "$FAKE_DIR/drift-before-write" ] && head=deadbee
  [ "${FAKE_DRIFT_AFTER_POST:-0}" = 1 ] && [ -f "$FAKE_DIR/body" ] && head=deadbee
  if [ "${FAKE_COMPOSITE_STATE:-0}" = 1 ]; then
    printf '{"state":["open"],"html_url":"https://github.test/acme/widget/pull/42","head":{"sha":"%s"}}' "$head"
  else
    printf '{"state":"%s","html_url":"https://github.test/acme/widget/pull/42","head":{"sha":"%s"}}' "${FAKE_STATE:-open}" "$head"
  fi
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = -X ] && [ "${3:-}" = POST ]; then
  input=""; prev=""
  for arg in "$@"; do [ "$prev" = --input ] && input="$arg"; prev="$arg"; done
  [ "$input" = - ] || exit 2
  node -e '
    var fs=require("fs"),raw="";
    process.stdin.on("data",function(c){raw+=c;});process.stdin.on("end",function(){
      var j;try{j=JSON.parse(raw);}catch(_){process.exit(2);}
      fs.writeFileSync(process.env.FAKE_DIR+"/post.json",raw);
      fs.writeFileSync(process.env.FAKE_DIR+"/body",j.body);
    });'
  printf '%s' '{"html_url":"https://github.test/acme/widget/pull/42#pullrequestreview-1"}'
  exit 0
fi
exit 2
FAKE
chmod +x "$WORK/bin/gh"

run_gh() {
  local payload="${1:-$WORK/a.json}"
  mkdir -p "$WORK/state/tmp"
  FAKE_DIR="$WORK/state" FAKE_MUTATE_PAYLOAD="${FAKE_MUTATE_PAYLOAD:-0}" \
    FAKE_MUTATE_PRIVATE_PAYLOAD="${FAKE_MUTATE_PRIVATE_PAYLOAD:-0}" \
    ORIGINAL_PAYLOAD="${ORIGINAL_PAYLOAD:-$payload}" \
    FAKE_COMPOSITE_STATE="${FAKE_COMPOSITE_STATE:-0}" \
    FAKE_DRIFT_DURING_INVENTORY="${FAKE_DRIFT_DURING_INVENTORY:-0}" \
    FAKE_DRIFT_AFTER_POST="${FAKE_DRIFT_AFTER_POST:-0}" TMPDIR="$WORK/state/tmp" PATH="$WORK/bin:$PATH" \
    bash "$LIB" --reconcile-review --provider github --repo-id acme/widget \
      --expected-head abcdef0 --operation-key 'team-review:v1:run-7' 42 "$payload" 2>/dev/null
}
R1="$(run_gh)"
eq "G1 first reconcile status posted" "$(printf '%s' "$R1" | jfield status)" "posted"
eq "G2 first reconcile postedCount" "$(printf '%s' "$R1" | jfield postedCount)" "1"
eq "G3 result schema partCount" "$(printf '%s' "$R1" | jfield partCount)" "1"
eq "G3a result schema provider" "$(printf '%s' "$R1" | jfield provider)" "github"
eq "G4 result schema headSha" "$(printf '%s' "$R1" | jfield headSha)" "abcdef0"
eq "G5 result schema marker" "$(printf '%s' "$R1" | jfield marker)" "$MARKER"
eq "G6 result schema URL" "$(printf '%s' "$R1" | jfield url)" "https://github.test/acme/widget/pull/42#pullrequestreview-1"
R2="$(run_gh)"
eq "G7 repeat reconcile status present" "$(printf '%s' "$R2" | jfield status)" "present"
eq "G8 repeat reconcile posts nothing" "$(printf '%s' "$R2" | jfield postedCount)" "0"
eq "G9 GitHub review POST is atomic and unique" "$(grep -c -- '-X POST repos/acme/widget/pulls/42/reviews' "$WORK/state/calls")" "1"
has "G9a GitHub POST consumes the rendered review only through stdin" \
  "$(cat "$WORK/state/calls")" "--input -"
has "G10 GitHub marker read is fully paginated" "$(cat "$WORK/state/calls")" "graphql --paginate --slurp"

rm -f "$WORK/state/body" "$WORK/state/calls" "$WORK/state/payload-mutated"
cp "$WORK/a.json" "$WORK/race.json"
RACE_RESULT="$(FAKE_MUTATE_PAYLOAD=1 ORIGINAL_PAYLOAD="$WORK/race.json" run_gh "$WORK/race.json")"
if [ "$(printf '%s' "$RACE_RESULT" | jfield status)" = posted ] \
  && grep -qF 'Stable body' "$WORK/state/body" \
  && ! grep -qF 'MUTATED AFTER DIGEST' "$WORK/state/body" \
  && grep -qF 'MUTATED AFTER DIGEST' "$WORK/race.json"; then
  check "G11 payload mutation after inventory cannot change attested remote content" PASS
else
  check "G11 payload mutation after inventory cannot change attested remote content" FAIL
fi

rm -f "$WORK/state/body" "$WORK/state/calls" "$WORK/state/private-payload-mutated"
rm -rf "$WORK/state/tmp"; mkdir -p "$WORK/state/tmp"
if FAKE_MUTATE_PRIVATE_PAYLOAD=1 run_gh >/dev/null 2>&1; then
  check "G11a private payload replacement after metadata fails closed" FAIL
else
  check "G11a private payload replacement after metadata fails closed" PASS
fi
POSTS=0; [ ! -f "$WORK/state/calls" ] || POSTS="$(grep -c -- '-X POST' "$WORK/state/calls" || true)"
eq "G11b private payload replacement causes zero GitHub writes" "$POSTS" "0"

rm -f "$WORK/state/body" "$WORK/state/calls" "$WORK/state/drift-before-write"
if FAKE_STATE=closed run_gh >/dev/null 2>&1; then check "G12 closed PR fails before posting" FAIL; else check "G12 closed PR fails before posting" PASS; fi
POSTS=0; [ ! -f "$WORK/state/calls" ] || POSTS="$(grep -c -- '-X POST' "$WORK/state/calls" || true)"
eq "G13 closed PR caused no POST" "$POSTS" "0"
rm -f "$WORK/state/body" "$WORK/state/calls" "$WORK/state/drift-before-write"
if FAKE_COMPOSITE_STATE=1 run_gh >/dev/null 2>&1; then check "G13a composite remote state fails closed" FAIL; else check "G13a composite remote state fails closed" PASS; fi
rm -f "$WORK/state/body" "$WORK/state/calls" "$WORK/state/drift-before-write"
if FAKE_DRIFT_DURING_INVENTORY=1 run_gh >/dev/null 2>&1; then check "G14 head drift during inventory fails before posting" FAIL; else check "G14 head drift during inventory fails before posting" PASS; fi
eq "G15 inventory drift causes zero stale review POSTs" "$(grep -c -- '-X POST' "$WORK/state/calls" || true)" "0"
rm -f "$WORK/state/body" "$WORK/state/calls" "$WORK/state/drift-before-write"
if FAKE_DRIFT_AFTER_POST=1 run_gh >/dev/null 2>&1; then check "G16 post-write head drift fails closed" FAIL; else check "G16 post-write head drift fails closed" PASS; fi
eq "G17 drift case reached the POST before failing post-check" "$(grep -c -- '-X POST repos/acme/widget/pulls/42/reviews' "$WORK/state/calls")" "1"
case "$(tail -n 1 "$WORK/state/calls")" in
  'api repos/acme/widget/pulls/42') check "G18 final OPEN/head snapshot is the last remote observation" PASS ;;
  *) check "G18 final OPEN/head snapshot is the last remote observation" FAIL ;;
esac

# GitLab uses one summary note plus one discussion per inline finding. A partial
# exact set is completed, while duplicate/conflicting/malformed marker sets stop.
MGL="$(_zensu_vcs_review_payload_meta gitlab "$WORK/a.json" abcdef0 'team-review:v1:run-7')"
eq "L1 GitLab part count includes summary and discussions" "$(printf '%s' "$MGL" | jfield partCount)" "3"
GL_OD="$(printf '%s' "$MGL" | jfield opDigest)"; GL_PD="$(printf '%s' "$MGL" | jfield payloadDigest)"
GL_M1="$(_zensu_vcs_review_marker "$GL_OD" "$GL_PD" abcdef0 3 1)"
eq "L2 part-one helper matches result marker" "$GL_M1" "$(printf '%s' "$MGL" | jfield marker)"
GL_M2="$(_zensu_vcs_review_marker "$GL_OD" "$GL_PD" abcdef0 3 2)"
GL_M3="$(_zensu_vcs_review_marker "$GL_OD" "$GL_PD" abcdef0 3 3)"
GL_BODY1="$(printf '%s\n\n_Verdict: COMMENT_\n\nStable body' "$GL_M1")"
GL_BODY2="$(printf '%s\n\nSecond' "$GL_M2")"
GL_BODY3="$(printf '%s\n\nFirst' "$GL_M3")"
GL_MULTI_RECORD="$(GL_M1="$GL_M1" GL_M2="$GL_M2" GL_M3="$GL_M3" node -e 'process.stdout.write(JSON.stringify({notes:[{id:101,type:null,body:[process.env.GL_M1,process.env.GL_M2,process.env.GL_M3].join("\n")}],discussions:[]}));')"
if printf '%s' "$GL_MULTI_RECORD" | _zensu_vcs_review_inventory gitlab "$GL_OD" "$GL_PD" abcdef0 3 >/dev/null 2>&1; then
  check "L2a one GitLab record cannot attest multiple publication parts" FAIL
else
  check "L2a one GitLab record cannot attest multiple publication parts" PASS
fi
GL_VALID_OVERLAP="$(GL_M1="$GL_M1" GL_M2="$GL_M2" GL_M3="$GL_M3" node -e '
  function position(path,line,side){var p={position_type:"text",base_sha:"ba5e000",start_sha:"57a2700",head_sha:"abcdef0",old_path:path,new_path:path};p[side==="LEFT"?"old_line":"new_line"]=line;return p;}
  var summary={id:101,type:null,body:process.env.GL_M1};
  var inline2={id:102,type:"DiffNote",body:process.env.GL_M2,position:position("b.js",9,"RIGHT")};
  var inline3={id:103,type:"DiffNote",body:process.env.GL_M3,position:position("a.js",4,"LEFT")};
  process.stdout.write(JSON.stringify({notes:[summary,inline2,inline3],discussions:[
    {id:"individual-101",individual_note:true,notes:[summary]},
    {id:"thread-102",individual_note:false,notes:[inline2]},
    {id:"thread-103",individual_note:false,notes:[inline3]}
  ]}));')"
eq "L2b legitimate GitLab note/discussion endpoint overlap is accepted" \
  "$(printf '%s' "$GL_VALID_OVERLAP" | _zensu_vcs_review_inventory gitlab "$GL_OD" "$GL_PD" abcdef0 3 | jfield present)" "[1,2,3]"
GL_INDIVIDUAL_INLINE="$(GL_M2="$GL_M2" node -e 'var b=process.env.GL_M2,n={id:102,type:null,body:b};process.stdout.write(JSON.stringify({notes:[n],discussions:[{id:"individual-102",individual_note:true,notes:[n]}]}));')"
if printf '%s' "$GL_INDIVIDUAL_INLINE" | _zensu_vcs_review_inventory gitlab "$GL_OD" "$GL_PD" abcdef0 3 >/dev/null 2>&1; then
  check "L2c individual GitLab notes cannot impersonate inline discussions" FAIL
else
  check "L2c individual GitLab notes cannot impersonate inline discussions" PASS
fi
GL_CROSS_SOURCE_SUMMARY="$(GL_M1="$GL_M1" node -e '
  var b=process.env.GL_M1,p={position_type:"text",base_sha:"ba5e000",start_sha:"57a2700",head_sha:"abcdef0",old_path:"a.js",new_path:"a.js",new_line:4};
  var n={id:101,type:"DiffNote",body:b,position:p};process.stdout.write(JSON.stringify({notes:[n],discussions:[{id:"thread-101",individual_note:false,notes:[n]}]}));')"
if printf '%s' "$GL_CROSS_SOURCE_SUMMARY" | _zensu_vcs_review_inventory gitlab "$GL_OD" "$GL_PD" abcdef0 3 >/dev/null 2>&1; then
  check "L2d a threaded discussion cannot impersonate the summary note" FAIL
else
  check "L2d a threaded discussion cannot impersonate the summary note" PASS
fi
GL_SHAPE_CONFLICT="$(GL_M2="$GL_M2" node -e '
  var b=process.env.GL_M2,n={id:102,type:null,body:b},d={id:102,type:"DiscussionNote",body:b};
  process.stdout.write(JSON.stringify({notes:[n],discussions:[{id:"thread-102",individual_note:false,notes:[d]}]}));')"
if printf '%s' "$GL_SHAPE_CONFLICT" | _zensu_vcs_review_inventory gitlab "$GL_OD" "$GL_PD" abcdef0 3 >/dev/null 2>&1; then
  check "L2e duplicate GitLab note IDs with contradictory types fail closed" FAIL
else
  check "L2e duplicate GitLab note IDs with contradictory types fail closed" PASS
fi

gl_record_write() {
  local target="$1" body="$2" position_json="$3"
  RECORD_TARGET="$target" RECORD_BODY="$body" RECORD_POSITION="$position_json" node -e '
    var fs=require("fs"),position;
    try{position=JSON.parse(process.env.RECORD_POSITION);}catch(_){process.exit(1);}
    if(position!==null&&(!position||typeof position!=="object"||Array.isArray(position)))process.exit(1);
    fs.writeFileSync(process.env.RECORD_TARGET,JSON.stringify({body:process.env.RECORD_BODY,position:position}));'
}
gl_record_field() {
  local record="$1" field="$2"
  RECORD="$record" FIELD="$field" node -e '
    var fs=require("fs"),j;
    try{j=JSON.parse(fs.readFileSync(process.env.RECORD,"utf8"));}catch(_){process.exit(1);}
    var v=j;for(var p of process.env.FIELD.split(".")){if(v==null||!Object.prototype.hasOwnProperty.call(v,p)){v="";break;}v=v[p];}
    process.stdout.write(v==null?"":String(v));'
}

cat > "$WORK/bin/glab" <<'FAKE'
#!/bin/bash
set -u
printf '%s\n' "$*" >> "$FAKE_DIR/calls"
path="${*: -1}"
mutate_manifest() {
  for manifest in "$TMPDIR"/zensu-review-manifest.*; do
    [ -f "$manifest" ] || continue
    cp "$manifest" "$manifest.swap" || return 1
    printf ' ' >> "$manifest.swap" || return 1
    mv "$manifest.swap" "$manifest" || return 1
  done
}
if [ "${1:-}" = api ] && [ "$path" = user ]; then
  printf '%s' '{"id":701}'
  exit 0
fi
if [ "${1:-}" = api ] && [ "$path" = 'projects/grp%2Fproj/merge_requests/7' ]; then
  count=0; [ ! -f "$FAKE_DIR/mr-count" ] || count="$(cat "$FAKE_DIR/mr-count")"
  count=$((count + 1)); printf '%s' "$count" > "$FAKE_DIR/mr-count"
  if [ "${FAKE_MUTATE_MANIFEST_BEFORE_POST:-0}" = 1 ] && [ "$count" -eq 2 ] \
    && [ ! -f "$FAKE_DIR/manifest-mutated-before-post" ]; then
    mutate_manifest || exit 2
    : > "$FAKE_DIR/manifest-mutated-before-post"
  fi
  if [ "$count" -le "${FAKE_DIFF_DELAY_CALLS:-0}" ]; then
    printf '%s' '{"state":"opened","web_url":"https://gitlab.test/grp/proj/-/merge_requests/7","sha":"abcdef0","diff_refs":null}'
  else
    printf '%s' '{"state":"opened","web_url":"https://gitlab.test/grp/proj/-/merge_requests/7","sha":"abcdef0","diff_refs":{"base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0"}}'
  fi
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = --paginate ]; then
  if [[ "$path" = */diffs ]]; then
    if [ "${FAKE_DIFFS_MALFORMED:-0}" = 1 ]; then printf '%s' '{bad diff json'; exit 0; fi
    if [ "${FAKE_DIFFS_TRUNCATED:-0}" = 1 ]; then
      printf '%s' '[[{"old_path":"b.js","new_path":"b.js","collapsed":false,"too_large":false,"diff":"@@ -8 +8,2 @@\n context\n"}]]'
    elif [ "${FAKE_CONTEXT_DIFF:-0}" = 1 ]; then
      printf '%s' '[[{"old_path":"renamed-old.js","new_path":"renamed-new.js","renamed_file":true,"collapsed":false,"too_large":false,"diff":"@@ -10,2 +10,3 @@\n+added\n context\n next\n"}]]'
    else
      printf '%s' '[[{"old_path":"b.js","new_path":"b.js","collapsed":false,"too_large":false,"diff":"@@ -8 +8,2 @@\n context\n+added\n"},{"old_path":"a.js","new_path":"a.js","collapsed":false,"too_large":false,"diff":"@@ -4 +4,0 @@\n-removed\n"}]]'
    fi
    exit 0
  fi
  if [ "${FAKE_MALFORMED:-0}" = 1 ]; then printf '%s' 'not json'; exit 0; fi
  if [ "${FAKE_MUTATE_MANIFEST:-0}" = 1 ] && [ ! -f "$FAKE_DIR/manifest-mutated" ]; then
    mutate_manifest || exit 2
    : > "$FAKE_DIR/manifest-mutated"
  fi
  if [[ "$path" = */notes ]]; then
    FAKE_DIR="$FAKE_DIR" FAKE_DUPLICATE="${FAKE_DUPLICATE:-0}" FAKE_AUTHOR_ID="${FAKE_AUTHOR_ID:-701}" node -e '
      var fs=require("fs"),d=process.env.FAKE_DIR,a=[];
      var author={id:Number(process.env.FAKE_AUTHOR_ID)};
      function record(i){var f=d+"/part"+i;if(!fs.existsSync(f))return null;var r;try{r=JSON.parse(fs.readFileSync(f,"utf8"));}catch(_){process.exit(2);}if(!r||typeof r.body!=="string"||!(r.position===null||(r.position&&typeof r.position==="object"&&!Array.isArray(r.position))))process.exit(2);return r;}
      var summary=record(1);if(summary){a.push({id:101,type:null,body:summary.body,author:author,web_url:"https://gitlab.test/note/101"});if(process.env.FAKE_DUPLICATE==="1")a.push({id:999,type:null,body:summary.body,author:author});}
      [2,3].forEach(function(i){var r=record(i);if(r)a.push({id:100+i,type:r.position===null?"DiscussionNote":"DiffNote",body:r.body,author:author,position:r.position});});
      process.stdout.write(JSON.stringify([a]));'
  else
    FAKE_DIR="$FAKE_DIR" FAKE_DUPLICATE="${FAKE_DUPLICATE:-0}" FAKE_AUTHOR_ID="${FAKE_AUTHOR_ID:-701}" node -e '
      var fs=require("fs"),d=process.env.FAKE_DIR,a=[];
      var author={id:Number(process.env.FAKE_AUTHOR_ID)};
      function record(i){var f=d+"/part"+i;if(!fs.existsSync(f))return null;var r;try{r=JSON.parse(fs.readFileSync(f,"utf8"));}catch(_){process.exit(2);}if(!r||typeof r.body!=="string"||!(r.position===null||(r.position&&typeof r.position==="object"&&!Array.isArray(r.position))))process.exit(2);return r;}
      var summary=record(1);if(summary){a.push({id:"individual-summary",individual_note:true,notes:[{id:101,type:null,body:summary.body,author:author}]});if(process.env.FAKE_DUPLICATE==="1")a.push({id:"individual-summary-duplicate",individual_note:true,notes:[{id:999,type:null,body:summary.body,author:author}]});}
      [2,3].forEach(function(i){var r=record(i);if(r)a.push({id:"d"+i,individual_note:false,notes:[{id:100+i,type:r.position===null?"DiscussionNote":"DiffNote",body:r.body,author:author,position:r.position,web_url:"https://gitlab.test/discussion/"+i}]});});
      process.stdout.write(JSON.stringify([a]));'
  fi
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = --method ] && [ "${3:-}" = POST ]; then
  [ "${5:-}" = --input ] && [ "${6:-}" = - ] || exit 2
  part="$(ENDPOINT="${4:-}" node -e '
    var fs=require("fs"),raw="";
    process.stdin.on("data",function(c){raw+=c;});process.stdin.on("end",function(){
      var request;try{request=JSON.parse(raw);}catch(_){process.exit(2);}
      if(!request||typeof request!=="object"||Array.isArray(request)||typeof request.body!=="string"||!request.body
          ||!Object.keys(request).every(function(k){return k==="body"||k==="position";}))process.exit(2);
      var position=Object.prototype.hasOwnProperty.call(request,"position")?request.position:null;
      if(!(position===null||(position&&typeof position==="object"&&!Array.isArray(position))))process.exit(2);
      var match=request.body.match(/:part=([0-9]+)\//);if(!match)process.exit(2);
      var part=Number(match[1]),suffix=part===1?"/notes":"/discussions";
      if(!Number.isSafeInteger(part)||part<1||!process.env.ENDPOINT.endsWith(suffix))process.exit(2);
      fs.writeFileSync(process.env.FAKE_DIR+"/part"+part,JSON.stringify({body:request.body,position:position}));
      process.stdout.write(String(part));
    });')" || exit 2
  printf '{"web_url":"https://gitlab.test/part/%s"}' "$part"
  exit 0
fi
exit 2
FAKE
chmod +x "$WORK/bin/glab"
run_gl() {
  local payload="${1:-$WORK/a.json}" operation_key="${2:-team-review:v1:run-7}"
  mkdir -p "$WORK/glstate/tmp"
  FAKE_DIR="$WORK/glstate" FAKE_DUPLICATE="${FAKE_DUPLICATE:-0}" FAKE_MALFORMED="${FAKE_MALFORMED:-0}" \
    FAKE_DIFFS_MALFORMED="${FAKE_DIFFS_MALFORMED:-0}" FAKE_DIFFS_TRUNCATED="${FAKE_DIFFS_TRUNCATED:-0}" \
    FAKE_CONTEXT_DIFF="${FAKE_CONTEXT_DIFF:-0}" FAKE_AUTHOR_ID="${FAKE_AUTHOR_ID:-701}" \
    FAKE_MUTATE_MANIFEST="${FAKE_MUTATE_MANIFEST:-0}" \
    FAKE_MUTATE_MANIFEST_BEFORE_POST="${FAKE_MUTATE_MANIFEST_BEFORE_POST:-0}" TMPDIR="$WORK/glstate/tmp" \
    PATH="$WORK/bin:$PATH" bash "$LIB" --reconcile-review --provider gitlab --repo-id grp%2Fproj \
      --expected-head abcdef0 --operation-key "$operation_key" \
      --diff-refs-json '{"base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0"}' 7 "$payload" 2>/dev/null
}
rm -rf "$WORK/glstate"; mkdir -p "$WORK/glstate"
gl_record_write "$WORK/glstate/part1" "$GL_BODY1" 'null'
LR1="$(run_gl)"
eq "L3 partial GitLab reconcile status" "$(printf '%s' "$LR1" | jfield status)" "reconciled"
eq "L4 partial GitLab posts only missing parts" "$(printf '%s' "$LR1" | jfield postedCount)" "2"
eq "L5 exact partial reconcile avoids duplicate summary" "$(grep -c -- '--method POST projects/grp%2Fproj/merge_requests/7/notes' "$WORK/glstate/calls" || true)" "0"
eq "L6 partial reconcile posts two discussions" "$(grep -c -- '--method POST projects/grp%2Fproj/merge_requests/7/discussions' "$WORK/glstate/calls")" "2"
has "L7 GitLab reads notes with full pagination" "$(cat "$WORK/glstate/calls")" "--paginate --output json projects/grp%2Fproj/merge_requests/7/notes"
has "L7a GitLab resolves anchors from fully paginated MR diffs" "$(cat "$WORK/glstate/calls")" "--paginate --output json projects/grp%2Fproj/merge_requests/7/diffs"
eq "L8 diff discussion carries old_path" "$(gl_record_field "$WORK/glstate/part2" position.old_path)" "b.js"
eq "L9 diff discussion also carries new_path" "$(gl_record_field "$WORK/glstate/part2" position.new_path)" "b.js"
eq "L10 LEFT discussion uses old_line fallback" "$(gl_record_field "$WORK/glstate/part3" position.old_line)" "4"
eq "L10a persisted RIGHT part retains exact body" "$(gl_record_field "$WORK/glstate/part2" body)" "$GL_BODY2"
eq "L10b persisted RIGHT anchor retains exact position type" "$(gl_record_field "$WORK/glstate/part2" position.position_type)" "text"
eq "L10c persisted RIGHT anchor retains exact base SHA" "$(gl_record_field "$WORK/glstate/part2" position.base_sha)" "ba5e000"
eq "L10d persisted RIGHT anchor retains exact start SHA" "$(gl_record_field "$WORK/glstate/part2" position.start_sha)" "57a2700"
eq "L10e persisted RIGHT anchor retains exact head SHA" "$(gl_record_field "$WORK/glstate/part2" position.head_sha)" "abcdef0"
eq "L10f persisted RIGHT anchor retains exact old path" "$(gl_record_field "$WORK/glstate/part2" position.old_path)" "b.js"
eq "L10g persisted RIGHT anchor retains exact new path" "$(gl_record_field "$WORK/glstate/part2" position.new_path)" "b.js"
eq "L10h persisted RIGHT anchor retains exact new line" "$(gl_record_field "$WORK/glstate/part2" position.new_line)" "9"
eq "L10i persisted RIGHT anchor does not synthesize an old line" "$(gl_record_field "$WORK/glstate/part2" position.old_line)" ""
eq "L10j persisted LEFT part retains exact body" "$(gl_record_field "$WORK/glstate/part3" body)" "$GL_BODY3"
eq "L10k persisted LEFT anchor retains exact position type" "$(gl_record_field "$WORK/glstate/part3" position.position_type)" "text"
eq "L10l persisted LEFT anchor retains exact base SHA" "$(gl_record_field "$WORK/glstate/part3" position.base_sha)" "ba5e000"
eq "L10m persisted LEFT anchor retains exact start SHA" "$(gl_record_field "$WORK/glstate/part3" position.start_sha)" "57a2700"
eq "L10n persisted LEFT anchor retains exact head SHA" "$(gl_record_field "$WORK/glstate/part3" position.head_sha)" "abcdef0"
eq "L10o persisted LEFT anchor retains exact old path" "$(gl_record_field "$WORK/glstate/part3" position.old_path)" "a.js"
eq "L10p persisted LEFT anchor retains exact new path" "$(gl_record_field "$WORK/glstate/part3" position.new_path)" "a.js"
eq "L10q persisted LEFT anchor retains exact old line" "$(gl_record_field "$WORK/glstate/part3" position.old_line)" "4"
eq "L10r persisted LEFT anchor does not synthesize a new line" "$(gl_record_field "$WORK/glstate/part3" position.new_line)" ""
LR2="$(run_gl)"
eq "L11 complete GitLab reconcile status present" "$(printf '%s' "$LR2" | jfield status)" "present"
eq "L12 complete GitLab reconcile posts nothing" "$(printf '%s' "$LR2" | jfield postedCount)" "0"
eq "L12a GitLab result URL remains the stable merge-request URL" "$(printf '%s' "$LR2" | jfield url)" "https://gitlab.test/grp/proj/-/merge_requests/7"

rm -rf "$WORK/glstate"; mkdir -p "$WORK/glstate"
gl_record_write "$WORK/glstate/part1" "$GL_BODY1" 'null'
gl_record_write "$WORK/glstate/part2" "$(printf '%s\n\nFORGED BODY' "$GL_M2")" '{"position_type":"text","base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0","old_path":"b.js","new_path":"b.js","new_line":9}'
gl_record_write "$WORK/glstate/part3" "$GL_BODY3" '{"position_type":"text","base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0","old_path":"a.js","new_path":"a.js","old_line":4}'
if run_gl >/dev/null 2>&1; then check "L12b copied marker with changed body fails closed" FAIL; else check "L12b copied marker with changed body fails closed" PASS; fi
eq "L12c changed attested body causes zero remote writes" "$(grep -c -- '--method POST' "$WORK/glstate/calls" || true)" "0"

rm -rf "$WORK/glstate"; mkdir -p "$WORK/glstate"
gl_record_write "$WORK/glstate/part1" "$GL_BODY1" 'null'
gl_record_write "$WORK/glstate/part2" "$GL_BODY2" '{"position_type":"text","base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0","old_path":"b.js","new_path":"b.js","new_line":8}'
gl_record_write "$WORK/glstate/part3" "$GL_BODY3" '{"position_type":"text","base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0","old_path":"a.js","new_path":"a.js","old_line":4}'
if run_gl >/dev/null 2>&1; then check "L12d copied marker at a different diff anchor fails closed" FAIL; else check "L12d copied marker at a different diff anchor fails closed" PASS; fi
eq "L12e changed attested anchor causes zero remote writes" "$(grep -c -- '--method POST' "$WORK/glstate/calls" || true)" "0"

rm -rf "$WORK/glstate"; mkdir -p "$WORK/glstate"
gl_record_write "$WORK/glstate/part1" "$GL_BODY1" 'null'
gl_record_write "$WORK/glstate/part2" "$GL_BODY2" '{"position_type":"text","base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0","old_path":"b.js","new_path":"b.js","new_line":9}'
gl_record_write "$WORK/glstate/part3" "$GL_BODY3" '{"position_type":"text","base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0","old_path":"a.js","new_path":"a.js","old_line":4}'
if FAKE_AUTHOR_ID=999 run_gl >/dev/null 2>&1; then check "L12f marker copied by another GitLab author fails closed" FAIL; else check "L12f marker copied by another GitLab author fails closed" PASS; fi
eq "L12g foreign publisher causes zero remote writes" "$(grep -c -- '--method POST' "$WORK/glstate/calls" || true)" "0"

rm -rf "$WORK/glstate"; mkdir -p "$WORK/glstate"
if FAKE_MUTATE_MANIFEST=1 run_gl >/dev/null 2>&1; then
  check "L12h replaced GitLab manifest fails closed before publication" FAIL
else
  check "L12h replaced GitLab manifest fails closed before publication" PASS
fi
eq "L12i replaced manifest causes zero remote writes" "$(grep -c -- '--method POST' "$WORK/glstate/calls" || true)" "0"

rm -rf "$WORK/glstate"; mkdir -p "$WORK/glstate"
if FAKE_MUTATE_MANIFEST_BEFORE_POST=1 run_gl >/dev/null 2>&1; then
  check "L12j manifest replacement after inventory fails closed before POST" FAIL
else
  check "L12j manifest replacement after inventory fails closed before POST" PASS
fi
eq "L12k post-inventory manifest replacement causes zero remote writes" \
  "$(grep -c -- '--method POST' "$WORK/glstate/calls" || true)" "0"

# A valid body may be much larger than execve(2) ARG_MAX. Reconcile a partial
# review whose remaining inline discussion is three MiB and prove the exact
# JSON reaches GitLab over stdin rather than argv.
LARGE_PAYLOAD="$WORK/large-gitlab.json"
LARGE_PAYLOAD="$LARGE_PAYLOAD" node -e '
  const fs=require("fs");
  fs.writeFileSync(process.env.LARGE_PAYLOAD,JSON.stringify({
    event:"COMMENT",body:"Large summary",commit_id:"abcdef0",
    comments:[{path:"b.js",line:9,side:"RIGHT",body:"x".repeat(3*1024*1024)}]
  }));'
LARGE_KEY='team-review:v1:large-body'
LARGE_META="$(_zensu_vcs_review_payload_meta gitlab "$LARGE_PAYLOAD" abcdef0 "$LARGE_KEY")"
LARGE_OD="$(printf '%s' "$LARGE_META" | jfield opDigest)"
LARGE_PD="$(printf '%s' "$LARGE_META" | jfield payloadDigest)"
LARGE_MARKER1="$(_zensu_vcs_review_marker "$LARGE_OD" "$LARGE_PD" abcdef0 2 1)"
LARGE_MARKER2="$(_zensu_vcs_review_marker "$LARGE_OD" "$LARGE_PD" abcdef0 2 2)"
rm -rf "$WORK/glstate"; mkdir -p "$WORK/glstate"
gl_record_write "$WORK/glstate/part1" "$(printf '%s\n\n_Verdict: COMMENT_\n\nLarge summary' "$LARGE_MARKER1")" 'null'
LARGE_RESULT="$(run_gl "$LARGE_PAYLOAD" "$LARGE_KEY")"
eq "L12l partial large-body reconcile completes" "$(printf '%s' "$LARGE_RESULT" | jfield status)" "reconciled"
eq "L12m partial large-body reconcile writes one missing discussion" \
  "$(printf '%s' "$LARGE_RESULT" | jfield postedCount)" "1"
if LARGE_PAYLOAD="$LARGE_PAYLOAD" LARGE_RECORD="$WORK/glstate/part2" LARGE_MARKER="$LARGE_MARKER2" node -e '
  const fs=require("fs");
  const payload=JSON.parse(fs.readFileSync(process.env.LARGE_PAYLOAD,"utf8"));
  const record=JSON.parse(fs.readFileSync(process.env.LARGE_RECORD,"utf8"));
  process.exit(record.body===process.env.LARGE_MARKER+"\n\n"+payload.comments[0].body?0:1);
'; then
  check "L12n multi-megabyte discussion body survives stdin transport exactly" PASS
else
  check "L12n multi-megabyte discussion body survives stdin transport exactly" FAIL
fi
has "L12o GitLab body transport uses stdin instead of command arguments" \
  "$(cat "$WORK/glstate/calls")" "--input -"

rm -rf "$WORK/glstate"; mkdir -p "$WORK/glstate"
LR3="$(run_gl)"
eq "L13 empty GitLab reconcile status posted" "$(printf '%s' "$LR3" | jfield status)" "posted"
eq "L14 empty GitLab reconcile posts all parts" "$(printf '%s' "$LR3" | jfield postedCount)" "3"

rm -rf "$WORK/glstate"; mkdir -p "$WORK/glstate"
LR_CONTEXT="$(FAKE_CONTEXT_DIFF=1 run_gl "$WORK/context.json" 'team-review:v1:context')"
eq "L14a renamed context-line review posts every part" "$(printf '%s' "$LR_CONTEXT" | jfield postedCount)" "2"
eq "L14b renamed context anchor carries the exact old path" \
  "$(gl_record_field "$WORK/glstate/part2" position.old_path)" "renamed-old.js"
eq "L14c renamed context anchor carries the exact new path" \
  "$(gl_record_field "$WORK/glstate/part2" position.new_path)" "renamed-new.js"
eq "L14d context anchor carries its old-side line" \
  "$(gl_record_field "$WORK/glstate/part2" position.old_line)" "10"
eq "L14e context anchor carries its new-side line" \
  "$(gl_record_field "$WORK/glstate/part2" position.new_line)" "11"

rm -rf "$WORK/glstate"; mkdir -p "$WORK/glstate"
LR_SUMMARY="$(FAKE_DIR="$WORK/glstate" PATH="$WORK/bin:$PATH" bash "$LIB" --reconcile-review \
  --provider gitlab --repo-id grp%2Fproj --expected-head abcdef0 --operation-key 'team-review:v1:summary' \
  --diff-refs-json '{"head_sha":"abcdef0"}' 7 "$WORK/summary.json" 2>/dev/null)"
eq "L14f summary-only reconcile needs no positional diff refs" "$(printf '%s' "$LR_SUMMARY" | jfield status)" "posted"
if grep -qF '/diffs' "$WORK/glstate/calls"; then
  check "L14g summary-only reconcile avoids an unnecessary diff read" FAIL
else
  check "L14g summary-only reconcile avoids an unnecessary diff read" PASS
fi

rm -rf "$WORK/glstate"; mkdir -p "$WORK/glstate"
gl_record_write "$WORK/glstate/part1" "$GL_BODY1" 'null'
if FAKE_DUPLICATE=1 run_gl >/dev/null 2>&1; then check "L15 duplicate marker with distinct note IDs fails closed" FAIL; else check "L15 duplicate marker with distinct note IDs fails closed" PASS; fi
rm -rf "$WORK/glstate"; mkdir -p "$WORK/glstate"
if FAKE_MALFORMED=1 run_gl >/dev/null 2>&1; then check "L16 malformed paginated read fails closed" FAIL; else check "L16 malformed paginated read fails closed" PASS; fi
rm -rf "$WORK/glstate"; mkdir -p "$WORK/glstate"
if FAKE_DIFFS_MALFORMED=1 run_gl >/dev/null 2>&1; then check "L16a malformed diff pagination fails closed" FAIL; else check "L16a malformed diff pagination fails closed" PASS; fi
eq "L16b malformed diff pagination causes zero remote writes" "$(grep -c -- '--method POST' "$WORK/glstate/calls" || true)" "0"
rm -rf "$WORK/glstate"; mkdir -p "$WORK/glstate"
if FAKE_DIFFS_TRUNCATED=1 run_gl >/dev/null 2>&1; then check "L16c truncated diff hunk fails closed" FAIL; else check "L16c truncated diff hunk fails closed" PASS; fi
eq "L16d truncated diff hunk causes zero remote writes" "$(grep -c -- '--method POST' "$WORK/glstate/calls" || true)" "0"
rm -rf "$WORK/glstate"; mkdir -p "$WORK/glstate"
run_gl_bad_diff() {
  FAKE_DIR="$WORK/glstate" PATH="$WORK/bin:$PATH" bash "$LIB" --reconcile-review --provider gitlab --repo-id grp%2Fproj --expected-head abcdef0 --operation-key 'team-review:v1:run-7' --diff-refs-json '{"head_sha":"abcdef0"}' 7 "$WORK/a.json" 2>/dev/null
}
if run_gl_bad_diff >/dev/null 2>&1; then check "L17 incomplete diff refs fail before posting" FAIL; else check "L17 incomplete diff refs fail before posting" PASS; fi
BAD_POSTS="$(grep -c -- '--method POST' "$WORK/glstate/calls" || true)"
eq "L18 incomplete diff refs cause zero remote writes" "$BAD_POSTS" "0"

rm -rf "$WORK/glstate"; mkdir -p "$WORK/glstate"
LR_READY="$(FAKE_DIR="$WORK/glstate" FAKE_DIFF_DELAY_CALLS=4 PATH="$WORK/bin:$PATH" \
  bash "$LIB" --reconcile-review --provider gitlab --repo-id grp%2Fproj \
    --expected-head abcdef0 --operation-key 'team-review:v1:run-7' 7 "$WORK/a.json" 2>/dev/null)"
eq "L19 delegated GitLab reconcile waits for asynchronously populated diff refs" "$(printf '%s' "$LR_READY" | jfield status)" "posted"
eq "L20 readiness retry still publishes every part exactly once" "$(grep -c -- '--method POST' "$WORK/glstate/calls")" "3"
if [ "$(grep -cF 'api projects/grp%2Fproj/merge_requests/7' "$WORK/glstate/calls")" -ge 5 ]; then
  check "L21 every readiness attempt performs fresh MR observations" PASS
else
  check "L21 every readiness attempt performs fresh MR observations" FAIL
fi

echo "----"
echo "test-vcs-review-marker-reconcile: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
