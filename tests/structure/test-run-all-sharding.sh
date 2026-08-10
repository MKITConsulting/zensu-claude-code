#!/bin/bash
# The --ci shard split of tests/run-all.sh.
#
# The property that matters is COVERAGE, not balance: the union of the shards must
# be exactly the enforced suite inventory, every time, for any shard count. A split
# that loses a suite reports green on every shard while that suite ran nowhere —
# the same failure the Windows profile timeout produced, arrived at from the other
# direction. Balance only costs wall clock, so it is asserted loosely and last.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="$PLUGIN_DIR/tests/run-all.sh"
MANIFEST="$PLUGIN_DIR/tests/profiles/promptfoo-local-only.v1.json"
WEIGHTS="$PLUGIN_DIR/tests/profiles/ci-shard-weights.v1.json"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$RUNNER" "$MANIFEST" "$WEIGHTS"; do
  [ -f "$f" ] || { check "S0 required file missing: $f" FAIL; echo "----"; echo "test-run-all-sharding: $PASS PASS / $FAIL FAIL"; exit 1; }
done

# The partition is lifted out of the runner rather than re-implemented here: a
# second copy would drift, and a drifted copy would assert the split it computes
# itself instead of the one that actually runs in CI.
PARTITION="$WORKDIR/partition.js"
awk '/^shard_labels\(\) \{/{f=1} f && /<<.NODE.$/{p=1;next} p && /^NODE$/{exit} p{print}' "$RUNNER" > "$PARTITION"
if [ ! -s "$PARTITION" ]; then
  check "S1 shard_labels heredoc could not be extracted from run-all.sh — the partition moved" FAIL
  echo "----"; echo "test-run-all-sharding: $PASS PASS / $FAIL FAIL"; exit 1
fi
check "S1 the partition under test is the one run-all.sh executes" PASS

plan() { node "$PARTITION" "$MANIFEST" "$WEIGHTS" "$1" "$2"; }

INVENTORY="$WORKDIR/inventory.txt"
node -e '
const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const all = [...m.ciStructureTests.map((n) => "structure/" + n), ...m.ciOfflineSuites.map((s) => s.label)];
process.stdout.write(all.sort().join("\n") + "\n");
' "$MANIFEST" > "$INVENTORY"
INV_COUNT="$(grep -c . "$INVENTORY")"
[ "$INV_COUNT" -gt 0 ] \
  && check "S2 inventory resolves ($INV_COUNT suites)" PASS \
  || check "S2 inventory is empty — every assertion below would be vacuous" FAIL

# S3 is the whole point of the file. An N that no CI workflow uses is included on
# purpose: the invariant is a property of the split, not of one configuration.
for N in 1 2 3 5 8 13; do
  UNION="$WORKDIR/union-$N.txt"
  : > "$UNION"
  ok=1
  for i in $(seq 1 "$N"); do
    plan "$i" "$N" >> "$UNION" 2>/dev/null || ok=0
    printf '\n' >> "$UNION"
  done
  got="$(grep . "$UNION" | sort)"
  uniq_count="$(printf '%s\n' "$got" | sort -u | grep -c .)"
  total_count="$(printf '%s\n' "$got" | grep -c .)"
  want="$(cat "$INVENTORY")"
  if [ "$ok" = 1 ] && [ "$got" = "$(printf '%s\n' "$want" | grep . | sort)" ] \
     && [ "$uniq_count" = "$total_count" ]; then
    check "S3 N=$N — the shards are an exact partition of the inventory" PASS
  else
    check "S3 N=$N — union $total_count/$uniq_count unique vs inventory $INV_COUNT (a suite is duplicated or runs nowhere)" FAIL
  fi
done

# Every shard computes the split independently, so disagreement between two
# processes would hand the same suite to two shards or to none.
A="$(plan 2 5)"; B="$(plan 2 5)"
[ "$A" = "$B" ] && [ -n "$A" ] \
  && check "S4 the split is reproducible across processes" PASS \
  || check "S4 the split differs between two runs of the same shard" FAIL

# Coverage must not depend on the weight table. A suite nobody has timed yet is
# the normal state right after one is added, and it must still run.
STRIPPED="$WORKDIR/weights-empty.json"
node -e '
const fs = require("fs");
const w = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
fs.writeFileSync(process.argv[2], JSON.stringify({ ...w, seconds: {} }));
' "$WEIGHTS" "$STRIPPED"
UNION_S="$WORKDIR/union-stripped.txt"; : > "$UNION_S"
for i in 1 2 3 4 5; do
  node "$PARTITION" "$MANIFEST" "$STRIPPED" "$i" 5 >> "$UNION_S" 2>/dev/null
  printf '\n' >> "$UNION_S"
done
[ "$(grep . "$UNION_S" | sort)" = "$(grep . "$INVENTORY" | sort)" ] \
  && check "S5 an empty weight table changes the balance, never the coverage" PASS \
  || check "S5 suites vanish when the weight table does not list them" FAIL

# S6: the runner must refuse a spec it cannot honour rather than silently running
# a wrong slice — or, worse, everything.
reject() {
  local label="$1"; shift
  if bash "$RUNNER" "$@" >/dev/null 2>&1; then
    check "S6 $label was accepted" FAIL
  else
    check "S6 $label is rejected" PASS
  fi
}
reject "shard index 0"          --ci "0/5"
reject "shard index above total" --ci "6/5"
reject "non-numeric shard spec"  --ci "a/5"
reject "--shard outside --ci"    "" "1/5"

# S7: balance is best-effort, but a split this lopsided means the LPT loop broke
# and the parallelism bought nothing — position-sliced, one shard held 33 of the
# 72 sequential minutes.
node -e '
const fs = require("fs");
const w = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const cost = (l) => (typeof w.seconds[l] === "number" && w.seconds[l] > 0 ? w.seconds[l] : w.defaultSeconds);
const loads = [];
for (let i = 1; i <= 5; i += 1) {
  const labels = require("child_process")
    .execFileSync(process.execPath, [process.argv[1], process.argv[3], process.argv[2], String(i), "5"])
    .toString().split("\n").filter(Boolean);
  loads.push(labels.reduce((a, l) => a + cost(l), 0));
}
const max = Math.max(...loads); const min = Math.min(...loads);
process.exit(max <= min * 1.5 ? 0 : 1);
' "$PARTITION" "$WEIGHTS" "$MANIFEST" \
  && check "S7 the heaviest shard stays within 1.5x of the lightest" PASS \
  || check "S7 shard loads are lopsided — the cost-aware split is not working" FAIL

# S8: the workflow must derive the shard TOTAL from the matrix. A literal beside
# the shard list is the one edit that drops suites while every shard stays green.
CI_YML="$PLUGIN_DIR/.github/workflows/ci.yml"
if [ -f "$CI_YML" ]; then
  { grep -qF 'strategy.job-total' "$CI_YML" && grep -qF 'strategy.job-index' "$CI_YML" \
    && ! grep -qE 'run-all\.sh --ci .*--shard=[0-9]+/[0-9]+' "$CI_YML"; } \
    && check "S8 ci.yml derives both shard halves from the matrix" PASS \
    || check "S8 ci.yml hardcodes a shard number — bumping the matrix would drop suites" FAIL
else
  check "S8 .github/workflows/ci.yml is missing" FAIL
fi

# S9: cancel-in-progress must not apply to main, whose runs are the record that a
# merged commit was green.
if [ -f "$CI_YML" ]; then
  { grep -qF 'cancel-in-progress: true' "$CI_YML" && grep -qF 'github.run_id' "$CI_YML"; } \
    && check "S9 concurrency cancels superseded PR runs but never main" PASS \
    || check "S9 concurrency is absent or would cancel a main run" FAIL
fi

# S10: a weight key that matches no suite is a SILENT balance failure — the suite
# it was meant to describe falls back to defaultSeconds and the split quietly
# stops being cost-aware, with every coverage assertion above still green. The
# first table shipped with exactly this defect: the label of each offline eval
# carries a parenthetical, and the keys had been harvested with a pattern that
# stopped at the first space, so the 10-minute suite was costed at 20 seconds.
node -e '
const fs = require("fs");
const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const weights = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const valid = new Set([
  ...manifest.ciStructureTests.map((n) => "structure/" + n),
  ...manifest.ciOfflineSuites.map((s) => s.label),
]);
const orphans = Object.keys(weights.seconds).filter((k) => !valid.has(k));
if (orphans.length) {
  process.stderr.write("orphan weight keys: " + orphans.join(", ") + "\n");
  process.exit(1);
}
' "$MANIFEST" "$WEIGHTS" \
  && check "S10 every weight key names a real suite" PASS \
  || check "S10 the weight table describes suites that do not exist — the split is not cost-aware" FAIL

# The converse is deliberately NOT an error: a suite with no weight is the normal
# state the moment one is added, and S5 already proves it still runs. Report it so
# the drift is visible rather than silent.
UNWEIGHTED="$(node -e '
const fs = require("fs");
const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const weights = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const all = [
  ...manifest.ciStructureTests.map((n) => "structure/" + n),
  ...manifest.ciOfflineSuites.map((s) => s.label),
];
process.stdout.write(String(all.filter((l) => weights.seconds[l] === undefined).length));
' "$MANIFEST" "$WEIGHTS")"
[ "$UNWEIGHTED" = "0" ] \
  && check "S11 every suite carries a measured weight" PASS \
  || check "S11 $UNWEIGHTED suite(s) fall back to defaultSeconds — coverage is safe, balance drifts" PASS

echo "----"
echo "test-run-all-sharding: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
