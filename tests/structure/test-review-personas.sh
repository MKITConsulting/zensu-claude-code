#!/bin/bash
set -u

# Structure + functional test for repo-local review personas (activation
# triggers). Doc pins run BEFORE the node gate and the skip path propagates
# failures. Functional: fixture personas through the persona-activation.js
# CLI pin the spawn / skip / drop verdicts — segment-anchored ** globs
# (mid-pattern positive, subdomain negative), * / ? segment locality, regex
# metacharacters in globs, basename match for slashless patterns, comma-OR
# with quoted items, always-join default, empty activation value, malformed
# and hostile (built-in-spoofing / stem-mismatched) names, same-name copies
# (rejected via the stem gate), non-persona files ignored, matched-before-always-join cap ordering with
# skips not consuming slots, the 5-spawn cap boundary, wildcard-flood speed,
# missing-dir silence, and the always-exit-0 contract. Structure: module
# exports, the tdd SKILL.md 2b discovery + one-batch step-3 fan-out with
# not-registered / discovery-unavailable handling, the README persona
# contract (registration, name shape, trust boundary, output grammar, cap
# policy), the review-aspect.md note, and the 430-line skill cap.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$PLUGIN_DIR/hooks/lib/persona-activation.js"
TDD_MD="$PLUGIN_DIR/skills/tdd/SKILL.md"
ASPECT_MD="$PLUGIN_DIR/agents/review-aspect.md"
README="$PLUGIN_DIR/README.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$LIB" "$TDD_MD" "$ASPECT_MD" "$README"; do
  if [ ! -f "$f" ]; then
    check "P0 required file exists: $f" FAIL
    echo "----"
    echo "test-review-personas: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "P0 all target files exist" PASS

# P3 — doc/skill pins (no node needed; run before the gate)
if grep -qF 'hooks/lib/persona-activation.js' "$TDD_MD" && grep -qF '/.claude/agents' "$TDD_MD" && grep -qF 'zensu-review-*.md' "$TDD_MD"; then
  check "P3a tdd 2b discovery runs the helper against .claude/agents" PASS
else
  check "P3a tdd 2b discovery runs the helper against .claude/agents" FAIL
fi
if grep -qF 'PLUS one agent per step-2b' "$TDD_MD"; then
  check "P3b step 3 composes ONE batch of aspects plus personas" PASS
else
  check "P3b step 3 composes ONE batch of aspects plus personas" FAIL
fi
if grep -qF 'PERSONA SKIPPED' "$TDD_MD" && grep -qF 'PERSONA DROPPED' "$TDD_MD" && grep -qF '(no activation match | malformed)' "$TDD_MD"; then
  check "P3c humanized skip/drop log lines pinned" PASS
else
  check "P3c humanized skip/drop log lines pinned" FAIL
fi
if grep -qiE 'read-only' "$TDD_MD" && grep -qiE 'ID prefix|id-prefix' "$TDD_MD"; then
  check "P3d personas are read-only with ID-prefixed findings" PASS
else
  check "P3d personas are read-only with ID-prefixed findings" FAIL
fi
LINES="$(wc -l < "$TDD_MD" | tr -d '[:space:]')"
if [ "$LINES" -le 430 ]; then
  check "P3e tdd skill stays under the 430-line cap (actual: $LINES)" PASS
else
  check "P3e tdd skill stays under the 430-line cap (actual: $LINES)" FAIL
fi
if grep -qF '.claude/agents/zensu-review-' "$README" && grep -qF 'activation:' "$README"; then
  check "P3f README documents discovery path + activation field" PASS
else
  check "P3f README documents discovery path + activation field" FAIL
fi
if grep -qiF 'no `activation:` field always joins' "$README"; then
  check "P3g README documents the always-join default" PASS
else
  check "P3g README documents the always-join default" FAIL
fi
if grep -qiE 'cap(ped)? (of |at )?(five|5)' "$README" && grep -qiF 'glob-matched personas take slots before always-join' "$README"; then
  check "P3h README documents the cap + matched-first policy" PASS
else
  check "P3h README documents the cap + matched-first policy" FAIL
fi
if grep -qF '"**/domain/**"' "$README"; then
  check "P3i README example globs are quoted and project-agnostic" PASS
else
  check "P3i README example globs are quoted and project-agnostic" FAIL
fi
if grep -qiE 'custom personas?' "$ASPECT_MD" && grep -qF '## Aspect: <persona-name>' "$ASPECT_MD"; then
  check "P3j review-aspect.md references the persona output shape" PASS
else
  check "P3j review-aspect.md references the persona output shape" FAIL
fi
if grep -qF 'PERSONA SKIPPED — <name> (not registered)' "$TDD_MD" && grep -qF '(not registered)' "$README"; then
  check "P3k spawn-failure path is defined (not registered)" PASS
else
  check "P3k spawn-failure path is defined (not registered)" FAIL
fi
if grep -qF 'PERSONA DISCOVERY UNAVAILABLE' "$TDD_MD"; then
  check "P3l helper-command failure is loudly distinguished" PASS
else
  check "P3l helper-command failure is loudly distinguished" FAIL
fi
if grep -qiF 'Trust boundary' "$README" && grep -qiF 'not enforced by the plugin' "$README"; then
  check "P3m README states the persona trust boundary" PASS
else
  check "P3m README states the persona trust boundary" FAIL
fi
if grep -qF '## Aspect: <persona-name>' "$README" && grep -qF 'name:` must equal the filename stem' "$README"; then
  check "P3n README pins output grammar + name shape" PASS
else
  check "P3n README pins output grammar + name shape" FAIL
fi
if grep -qF 'git rev-parse --show-toplevel' "$TDD_MD"; then
  check "P3o personas dir resolves from the git root" PASS
else
  check "P3o personas dir resolves from the git root" FAIL
fi
if grep -qF 're-run the persona helper' "$TDD_MD"; then
  check "P3p fix rounds re-run the persona discovery" PASS
else
  check "P3p fix rounds re-run the persona discovery" FAIL
fi

if ! command -v node >/dev/null 2>&1; then
  echo "  SKIP  node not on PATH — functional CLI/export checks skipped (doc pins above ran)"
  echo "----"
  echo "test-review-personas: $PASS PASS / $FAIL FAIL (node missing, functional checks skipped)"
  if [ "$FAIL" -gt 0 ]; then exit 1; fi
  exit 0
fi

SBOX="$(mktemp -d 2>/dev/null)" || SBOX=""
if [ -z "$SBOX" ]; then
  check "P1 sandbox creation (mktemp)" FAIL
  echo "----"
  echo "test-review-personas: $PASS PASS / $FAIL FAIL"
  exit 1
fi
AG="$SBOX/agents"
mkdir -p "$AG"
printf -- '---\nname: zensu-review-always\n---\nAlways-on persona body.\n' > "$AG/zensu-review-always.md"
printf -- '---\nname: zensu-review-ddd\nactivation: "**/domain/**", "**/*.aggregate.ts"\n---\nDDD persona body.\n' > "$AG/zensu-review-ddd.md"
printf -- 'not a persona\n' > "$AG/zensu-review-broken.md"
printf -- '---\nname: zensu-review-tf\nactivation: "*.tf"\n---\nTerraform persona body.\n' > "$AG/zensu-review-tf.md"
printf -- '---\nname: zensu-review-q\nactivation: src/?.js\n---\nSingle-char persona body.\n' > "$AG/zensu-review-q.md"
printf -- '---\nname: zensu-review-mid\nactivation: src/**/*.spec.ts\n---\nMid-pattern persona body.\n' > "$AG/zensu-review-mid.md"
printf -- '---\nname: zensu-review-meta\nactivation: "a+b(1).ts"\n---\nMetachar persona body.\n' > "$AG/zensu-review-meta.md"
printf -- '---\nname: zensu:code-reviewer\n---\nHostile spoof body.\n' > "$AG/zensu-review-spoof.md"
printf -- '---\nname: zensu-review-other\n---\nStem mismatch body.\n' > "$AG/zensu-review-mismatch.md"
printf -- '---\nname: zensu-review-empty\nactivation:\n---\nEmpty activation body.\n' > "$AG/zensu-review-empty.md"
printf -- '---\nname: not-an-agent\n---\nIgnored file body.\n' > "$AG/other-agent.md"
printf -- 'plain text\n' > "$AG/notes.txt"

run_cli() {
  printf '%s' "$1" | node "$LIB" "$2" 2>/dev/null
}

# P1 — functional verdicts
OUT="$(run_cli 'src/domain/order.ts
README.md' "$AG")"
echo "$OUT" | grep -qxF 'spawn zensu-review-ddd' && check "P1a quoted ** glob matches and spawns" PASS || check "P1a quoted ** glob matches and spawns (got: $OUT)" FAIL
echo "$OUT" | grep -qxF 'spawn zensu-review-always' && check "P1b persona without activation always joins" PASS || check "P1b persona without activation always joins" FAIL
echo "$OUT" | grep -qxF 'skip zensu-review-broken malformed' && check "P1c malformed persona is skipped with a line" PASS || check "P1c malformed persona is skipped with a line" FAIL
echo "$OUT" | grep -qxF 'skip zensu-review-tf no-activation-match' && check "P1d non-matching persona is skipped by name" PASS || check "P1d non-matching persona is skipped by name" FAIL
echo "$OUT" | grep -qxF 'skip zensu-review-spoof malformed' && check "P1e hostile built-in name is rejected as malformed" PASS || check "P1e hostile built-in name is rejected (got: $OUT)" FAIL
echo "$OUT" | grep -qxF 'skip zensu-review-mismatch malformed' && check "P1f name != filename stem is rejected" PASS || check "P1f name != filename stem is rejected" FAIL
echo "$OUT" | grep -qxF 'skip zensu-review-empty no-activation-match' && check "P1g empty activation value skips (declared-but-empty)" PASS || check "P1g empty activation value skips (got: $OUT)" FAIL
if echo "$OUT" | grep -q 'other-agent\|not-an-agent\|notes'; then
  check "P1h non-persona files are ignored by the filename filter" FAIL
else
  check "P1h non-persona files are ignored by the filename filter" PASS
fi
FIRST="$(echo "$OUT" | head -1)"
if [ "$FIRST" = "spawn zensu-review-ddd" ]; then
  check "P1i matched personas order before always-join" PASS
else
  check "P1i matched personas order before always-join (got: $FIRST)" FAIL
fi

OUT="$(run_cli 'src/subdomain/order.ts' "$AG")"
echo "$OUT" | grep -qxF 'skip zensu-review-ddd no-activation-match' && check "P1j ** does not cross into partial segment names" PASS || check "P1j ** segment boundary negative (got: $OUT)" FAIL
OUT="$(run_cli 'src/a/b/x.spec.ts' "$AG")"
echo "$OUT" | grep -qxF 'spawn zensu-review-mid' && check "P1k mid-pattern src/**/*.spec.ts matches deep paths" PASS || check "P1k mid-pattern ** positive (got: $OUT)" FAIL
if node -e 'const m=require(process.argv[1]); process.exit(m.matchActivation("a**b",["a/x/b"])===false&&m.matchActivation("a**b",["axb"])===true?0:1)' "$LIB" 2>/dev/null; then
  check "P1k2 mid-segment ** stays within one segment" PASS
else
  check "P1k2 mid-segment ** stays within one segment" FAIL
fi
if node -e 'const m=require(process.argv[1]); const fs=require("fs"); const os=require("os"); const p=require("path"); const d=fs.mkdtempSync(p.join(os.tmpdir(),"crlf-")); fs.writeFileSync(p.join(d,"zensu-review-crlf.md"),"---\r\nname: zensu-review-crlf\r\n---\r\nbody\r\n"); const out=m.decide(d,["x"]); fs.rmSync(d,{recursive:true,force:true}); process.exit(out.indexOf("spawn zensu-review-crlf")>=0?0:1)' "$LIB" 2>/dev/null; then
  check "P1k3 CRLF persona files parse (Windows checkouts)" PASS
else
  check "P1k3 CRLF persona files parse (Windows checkouts)" FAIL
fi
OUT="$(run_cli 'a+b(1).ts' "$AG")"
echo "$OUT" | grep -qxF 'spawn zensu-review-meta' && check "P1l regex metacharacters in globs are escaped" PASS || check "P1l regex metacharacters escaped (got: $OUT)" FAIL
OUT="$(run_cli 'a+b(1)xts' "$AG")"
echo "$OUT" | grep -qxF 'skip zensu-review-meta no-activation-match' && check "P1m escaped dot does not act as regex wildcard" PASS || check "P1m escaped dot literal (got: $OUT)" FAIL

OUT="$(run_cli 'infra/prod/main.tf' "$AG")"
echo "$OUT" | grep -qxF 'spawn zensu-review-tf' && check "P1n slashless glob matches the basename" PASS || check "P1n slashless glob matches the basename (got: $OUT)" FAIL
OUT="$(run_cli 'src/a.js' "$AG")"
echo "$OUT" | grep -qxF 'spawn zensu-review-q' && check "P1o ? matches exactly one segment char" PASS || check "P1o ? matches one char (got: $OUT)" FAIL
OUT="$(run_cli 'src/ab.js' "$AG")"
echo "$OUT" | grep -qxF 'skip zensu-review-q no-activation-match' && check "P1p ? does not match two chars" PASS || check "P1p ? not two chars (got: $OUT)" FAIL
OUT="$(run_cli 'src/x/deep/file.aggregate.ts' "$AG")"
echo "$OUT" | grep -qxF 'spawn zensu-review-ddd' && check "P1q comma-separated quoted globs OR together" PASS || check "P1q comma-OR (got: $OUT)" FAIL

DUP_DIR="$SBOX/dup"
mkdir -p "$DUP_DIR"
printf -- '---\nname: zensu-review-two\n---\nbody\n' > "$DUP_DIR/zensu-review-two.md"
python3 -c "import shutil; shutil.copy('$DUP_DIR/zensu-review-two.md','$DUP_DIR/zensu-review-zz.md')" 2>/dev/null || cp "$DUP_DIR/zensu-review-two.md" "$DUP_DIR/zensu-review-zz.md"
OUT="$(run_cli 'x.txt' "$DUP_DIR")"
if echo "$OUT" | grep -qxF 'spawn zensu-review-two' && echo "$OUT" | grep -qxF 'skip zensu-review-zz malformed'; then
  check "P1r duplicate/stem-mismatched second file cannot double-spawn" PASS
else
  check "P1r duplicate second file cannot double-spawn (got: $OUT)" FAIL
fi

CAP_DIR="$SBOX/cap"
mkdir -p "$CAP_DIR"
i=1
while [ $i -le 6 ]; do
  printf -- '---\nname: zensu-review-p%d\n---\nbody\n' "$i" > "$CAP_DIR/zensu-review-p$i.md"
  i=$((i+1))
done
printf -- '---\nname: zensu-review-zmatch\nactivation: "*.txt"\n---\nbody\n' > "$CAP_DIR/zensu-review-zmatch.md"
OUT="$(run_cli 'any.txt' "$CAP_DIR")"
SPAWNS="$(echo "$OUT" | grep -c '^spawn ')"
DROPS="$(echo "$OUT" | grep -c '^drop ')"
if [ "$SPAWNS" = "5" ] && [ "$DROPS" = "2" ] && echo "$OUT" | grep -qxF 'spawn zensu-review-zmatch' && echo "$OUT" | grep -qxF 'drop zensu-review-p5 over-cap'; then
  check "P1s matched persona wins a slot; always-join overflow drops" PASS
else
  check "P1s matched-first cap policy (got spawns=$SPAWNS drops=$DROPS)" FAIL
fi

SLOT_DIR="$SBOX/slots"
mkdir -p "$SLOT_DIR"
printf -- '---\nname: zensu-review-a\nactivation: "*.nomatch"\n---\nbody\n' > "$SLOT_DIR/zensu-review-a.md"
i=1
while [ $i -le 5 ]; do
  printf -- '---\nname: zensu-review-s%d\n---\nbody\n' "$i" > "$SLOT_DIR/zensu-review-s$i.md"
  i=$((i+1))
done
OUT="$(run_cli 'x.txt' "$SLOT_DIR")"
SPAWNS="$(echo "$OUT" | grep -c '^spawn ')"
DROPS="$(echo "$OUT" | grep -c '^drop ')"
if [ "$SPAWNS" = "5" ] && [ "$DROPS" = "0" ]; then
  check "P1t skips do not consume cap slots" PASS
else
  check "P1t skips do not consume cap slots (got spawns=$SPAWNS drops=$DROPS)" FAIL
fi

FLOOD_DIR="$SBOX/flood"
mkdir -p "$FLOOD_DIR"
GLOB="$(python3 -c "print('*a' * 40)" 2>/dev/null)" || GLOB='*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a'
printf -- '---\nname: zensu-review-flood\nactivation: "%s"\n---\nbody\n' "$GLOB" > "$FLOOD_DIR/zensu-review-flood.md"
FLOOD_OUT="$SBOX/flood.out"
( printf '%s' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab' | node "$LIB" "$FLOOD_DIR" > "$FLOOD_OUT" 2>/dev/null ) &
FLOOD_PID=$!
WAITED=0
while kill -0 "$FLOOD_PID" 2>/dev/null && [ "$WAITED" -lt 10 ]; do
  sleep 1
  WAITED=$((WAITED+1))
done
if kill -0 "$FLOOD_PID" 2>/dev/null; then
  kill -9 "$FLOOD_PID" 2>/dev/null
  check "P1u wildcard-flood glob is bounded (no ReDoS hang)" FAIL
elif grep -qxF 'skip zensu-review-flood no-activation-match' "$FLOOD_OUT"; then
  check "P1u wildcard-flood glob is bounded (no ReDoS hang)" PASS
else
  check "P1u wildcard-flood glob is bounded (got: $(cat "$FLOOD_OUT"))" FAIL
fi

OUT="$(printf 'x\n' | node "$LIB" "$SBOX/nosuch" 2>/dev/null)"
RC=$?
[ -z "$OUT" ] && check "P1v missing personas dir is silent" PASS || check "P1v missing personas dir is silent (got: $OUT)" FAIL
[ "$RC" -eq 0 ] && check "P1w always-exit-0 contract holds" PASS || check "P1w always-exit-0 contract holds (rc=$RC)" FAIL

# P2 — module exports
if node -e 'const m=require(process.argv[1]); process.exit(typeof m.globToRegExp==="function"&&typeof m.matchActivation==="function"&&typeof m.parsePersona==="function"&&typeof m.decide==="function"&&m.SPAWN_CAP===5?0:1)' "$LIB" 2>/dev/null; then
  check "P2a lib exports glob/match/parse/decide + SPAWN_CAP=5" PASS
else
  check "P2a lib exports glob/match/parse/decide + SPAWN_CAP=5" FAIL
fi
if node -e 'const m=require(process.argv[1]); process.exit(m.matchActivation("**/*.tf",["a/b/c.tf"])===true&&m.matchActivation("*.tf",["a/b/c.tfx"])===false&&m.matchActivation("",["x"])===false&&m.matchActivation("\"*.tf\", \"*.md\"",["a/x.md"])===true?0:1)' "$LIB" 2>/dev/null; then
  check "P2b matchActivation edge semantics (suffix, empty, quoted OR)" PASS
else
  check "P2b matchActivation edge semantics (suffix, empty, quoted OR)" FAIL
fi

rm -rf "$SBOX" 2>/dev/null

echo "----"
echo "test-review-personas: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
