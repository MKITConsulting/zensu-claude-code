#!/bin/bash
set -u

# Behavioural contract for the session-trail LINEAGE ledger.
#
# A takeover used to leave no trace at all, so after a handover nobody could say
# which window continued a session — and the window that ran out of quota cannot
# ask, because answering costs a model turn it no longer has. The ledger records
# each handover as one edge; this suite asserts what the script actually writes
# and renders, so a change to the record shape, the chain walk, or the account
# resolution fails here rather than in front of a user.
#
# ISOLATION IS BY --config-dir AND $ZENSU_CCD_STORE, DELIBERATELY NOT BY $HOME.
# test-session-trail-verdict.sh redirects HOME and therefore SKIPS itself whole on
# Windows, where os.homedir() reads USERPROFILE instead — every check below would
# be lost the same way. --config-dir is argv, and $ZENSU_CCD_STORE is authoritative
# with no fallback probe, so both are honoured identically on every platform. HOME
# and USERPROFILE are still redirected as a second belt: nothing here may read the
# developer's real ~/.claude, and a future code path that resolves a root from the
# home directory must fail loudly here rather than quietly read the real machine.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TRAIL_MJS="$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs"

PASS=0; FAIL=0; SKIP=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
skip() { echo "  SKIP  $1"; SKIP=$((SKIP+1)); }
report() {
  echo "----"
  echo "test-session-trail-lineage: $PASS PASS / $FAIL FAIL / $SKIP SKIP"
  [ "$FAIL" -eq 0 ]
}

if [ ! -f "$TRAIL_MJS" ]; then
  check "L0 skills/session-trail/scripts/trail.mjs exists" FAIL
  report; exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  skip "all session-trail lineage behaviour checks (node unavailable)"
  report; exit 0
fi

# ── Unit-suite driver ───────────────────────────────────────────────────────
# tests/run-all.sh discovers only test-*.sh, so a bare *.test.js is never executed
# by the tree runner. Driven FIRST, before any scenario: at the tail a shard
# timeout would cost the whole unit suite, which is the only coverage the module's
# own refusal table has anywhere. The case-count floor matters because exit 0 also
# accepts a file that registered zero cases.
UNIT_OUT="$(node --test "$PLUGIN_DIR/tests/structure/session-lineage-v1.test.js" 2>&1)"
UNIT_RC=$?
# BOTH counters, as tests/structure/test-stop-enforcer-self-review-routing.sh does:
# the TOTAL is the real floor, and the pass floor is lower because TWO cases skip
# themselves on Windows -- both symlink cases. Keying the floor to `pass` alone would have failed
# this suite on the one platform it was just registered to run on — by
# construction, with nothing actually broken.
# BOTH summary spellings: `# tests`/`# pass` is the TAP reporter's form, and
# capturing only the other one made an empty capture look like a module failure.
UNIT_TOTAL="$(printf '%s' "$UNIT_OUT" | sed -n 's/^# tests \([0-9][0-9]*\)$/\1/p;s/^. tests \([0-9][0-9]*\)$/\1/p' | tail -1)"
UNIT_PASS="$(printf '%s' "$UNIT_OUT" | sed -n 's/^# pass \([0-9][0-9]*\)$/\1/p;s/^. pass \([0-9][0-9]*\)$/\1/p' | tail -1)"
case "$UNIT_TOTAL" in ''|*[!0-9]*) UNIT_TOTAL=0 ;; esac
case "$UNIT_PASS" in ''|*[!0-9]*) UNIT_PASS=0 ;; esac
if [ "$UNIT_RC" = "0" ] && [ "$UNIT_TOTAL" -ge 19 ] && [ "$UNIT_PASS" -ge 17 ]; then
  check "L-unit session-lineage-v1.test.js passes ($UNIT_PASS/$UNIT_TOTAL cases)" PASS
else
  check "L-unit session-lineage-v1.test.js (rc=$UNIT_RC pass=${UNIT_PASS:-0} total=${UNIT_TOTAL:-0}, floors 17/19)" FAIL
  printf '%s\n' "$UNIT_OUT" | tail -20
fi

FAKE="$(mktemp -d -t zensu-session-trail-lineage-XXXXXX)" || FAKE=""
if [ -z "$FAKE" ]; then
  check "L0 could not create the synthetic root" FAIL
  report; exit 1
fi
trap 'rm -rf "$FAKE"' EXIT

CFG="$FAKE/cfg"
STORE="$FAKE/store"
NOSTORE="$FAKE/store-that-does-not-exist"
mkdir -p "$CFG" "$STORE"

# Two accounts, and a third for the same-account discrimination in L20.
ACCT_A="aaaaaaaa-1111-1111-1111-111111111111"
ACCT_B="bbbbbbbb-2222-2222-2222-222222222222"
ACCT_C="cccccccc-3333-3333-3333-333333333333"

# ── Fixture builder ─────────────────────────────────────────────────────────
# A transcript plus its registry entry plus its desktop record. Written as a node
# script for the same reason the verdict suite does it: real mtimes and real ISO
# timestamps are spelled differently by BSD and GNU `touch`/`date`, and node is
# already a hard requirement here.
#
# The desktop record's file name is `<CLAUDE_CODE_HOST_SESSION_ID>.json`, and the
# real value of that variable already carries the `local_` prefix (measured
# 2026-08-21: CLAUDE_CODE_HOST_SESSION_ID=local_8a7e6341-… resolved to
# …/local_8a7e6341-….json). Naming the fixture without it would leave the
# host-session-id lookup unreachable while every check still passed, because
# ccdIndex() answers first whenever a cliSessionId is present.
cat > "$FAKE/mkfix.mjs" <<'MKFIX'
import fs from 'node:fs';
import path from 'node:path';

// argv: cfg store sessionId pid idleMin worktreeName account stalled
const [cfg, store, sessionId, pidRaw, idleRaw, wtName, account, stalled] = process.argv.slice(2);
const pid = Number(pidRaw);
const now = Date.now();
const mtime = now - Number(idleRaw) * 60000;
const iso = (ms) => new Date(ms).toISOString();

const cwd = path.join(cfg, 'work', wtName);
fs.mkdirSync(cwd, { recursive: true });
const slug = cwd.replace(/[^A-Za-z0-9]/g, '-');
const dir = path.join(cfg, 'projects', slug);
fs.mkdirSync(dir, { recursive: true });
fs.mkdirSync(path.join(cfg, 'sessions'), { recursive: true });

const L = [];
const push = (o) => L.push(JSON.stringify(o));
push({ type: 'user', message: { role: 'user', content: `work on ${wtName}` }, cwd, gitBranch: `feat/${wtName}`, isSidechain: false, timestamp: iso(mtime - 3600000) });
// Padding: buildIndex() drops any transcript under 200 bytes, so a two-record
// fixture would be filtered out before a single assertion could run.
for (let i = 0; i < 12; i++) push({ type: 'padding', blob: 'x'.repeat(40) });
push({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'done' }], stop_reason: 'end_turn' }, cwd, isSidechain: false, timestamp: iso(mtime - 1000) });
if (stalled === 'stalled') {
  push({
    type: 'assistant',
    message: { role: 'assistant', content: [{ type: 'text', text: 'API Error: 429 rate_limit' }] },
    cwd, isSidechain: false, isApiErrorMessage: true, apiErrorStatus: 429, error: 'rate_limit', timestamp: iso(mtime),
  });
}

const file = path.join(dir, `${sessionId}.jsonl`);
fs.writeFileSync(file, `${L.join('\n')}\n`);
fs.utimesSync(file, mtime / 1000, mtime / 1000);

fs.writeFileSync(path.join(cfg, 'sessions', `${sessionId}.json`), JSON.stringify({
  sessionId, cwd, pid, startedAt: mtime - 7200000, entrypoint: 'claude-desktop', name: `fixture-${wtName}`, kind: 'interactive',
}));

if (account !== 'none') {
  const recDir = path.join(store, account, 'ws-0001');
  fs.mkdirSync(recDir, { recursive: true });
  fs.writeFileSync(path.join(recDir, `local_host-${sessionId}.json`), JSON.stringify({
    cliSessionId: sessionId, isArchived: false, title: `fixture ${wtName}`, model: 'opus', effort: 'high', permissionMode: 'default',
  }));
}
process.stdout.write('ok');
MKFIX

fix() { # <sessionId> <pid> <idleMin> <worktreeName> <account|none> [stalled]
  local err
  if ! err="$(node "$FAKE/mkfix.mjs" "$CFG" "$STORE" "$1" "$2" "$3" "$4" "$5" "${6:-live}" 2>&1 >/dev/null)"; then
    check "L-fixture build failed for '$1': ${err:-<no stderr>}" FAIL
  fi
}

# Every invocation runs with the synthetic roots. HOME/USERPROFILE are pointed at
# the sandbox as the second belt described in the header; --config-dir and
# ZENSU_CCD_STORE are what actually decide the roots.
#
# The cwd is the fixture worktree, not the repo running the suite. selfIdentity()
# reads process.cwd() to describe the CONTINUING session, so a run launched from
# the plugin checkout would record this repository as the worktree of every
# takeover — true of the process, useless as a fixture, and it would let a wrong
# `to.worktree` pass unnoticed.
trail() { # <store-dir> <self-session-id> <self-pid> [args...]
  local store="$1" selfId="$2" selfPid="$3"; shift 3
  ( cd "$SELF_CWD" 2>/dev/null || cd "$FAKE"
    HOME="$FAKE" USERPROFILE="$FAKE" \
    ZENSU_CCD_STORE="$store" \
    CLAUDE_CODE_SESSION_ID="$selfId" CLAUDE_PID="$selfPid" CLAUDE_CODE_HOST_SESSION_ID="local_host-$selfId" \
    env -u CLAUDE_CONFIG_DIR node "$TRAIL_MJS" "$@" --config-dir "$CFG" 2>&1 )
}

jq_field() { # <json> <dotted-path>
  node -e '
const key = process.argv[2];
let o;
try { o = JSON.parse(process.argv[1]); } catch { process.stdout.write("PARSE_ERROR"); process.exit(0); }
let v = o;
for (const part of key.split(".")) { if (v == null) break; v = v[part]; }
process.stdout.write(v === undefined ? "ABSENT" : (typeof v === "object" ? JSON.stringify(v) : String(v)));
' "$1" "$2"
}

edge_count() { find "$CFG/zensu/session-lineage/v1/edges" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
reset_ledger() { rm -rf "$CFG/zensu/session-lineage/v1"; }

SID_A="11111111-0000-0000-0000-00000000000a"
SID_B="22222222-0000-0000-0000-00000000000b"
SID_C="33333333-0000-0000-0000-00000000000c"
SID_D="44444444-0000-0000-0000-00000000000d"
SID_E="55555555-0000-0000-0000-00000000000e"

LIVE_PID="$$"
DEAD_PID=2147483647

# One shared worktree name across A/B/C: a handover continues the SAME work, and
# the backfill heuristic keys on exactly that.
fix "$SID_A" "$DEAD_PID"  90 handover "$ACCT_A" stalled
fix "$SID_B" "$DEAD_PID"  60 handover "$ACCT_B"
fix "$SID_C" "$LIVE_PID"  10 handover "$ACCT_C"

# The worktree every `trail` call runs from — see the note on trail() above.
SELF_CWD="$CFG/work/handover"

# ── L0 — the premise ────────────────────────────────────────────────────────
# Both sides go through the same normalizer. node's path.resolve() returns a
# drive-qualified backslash spelling on win32, so comparing it against a raw shell
# path can NEVER match there — and the old failure branch was `skip; report; exit 0`,
# which the runner records as PASSED. A guard whose failure mode is "report success"
# is worse than no guard, so a premise that does not hold is now a FAIL.
hostpath() { # <path> -> the spelling node would produce for it
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
norm() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr '\\' '/'; }
same_path() { [ "$(norm "$(hostpath "$1")")" = "$(norm "$2")" ]; }

OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --diagnose --json)"
GOT_CFG="$(jq_field "$OUT" configRoot)"
if same_path "$CFG" "$GOT_CFG"; then
  check "L0 --config-dir decides the config root, so every fixture below is read instead of the real machine" PASS
else
  check "L0 --config-dir did not take (want $(hostpath "$CFG"), got ${GOT_CFG:-<empty>}) — every later check would read the real machine" FAIL
  report; exit 1
fi

# ── L0b — the SECOND premise: this shell's pid must read as alive ──────────
# Three checks below decide on liveness, which trail.mjs resolves with
# process.kill(pid, 0). Under Git Bash `$$` is an MSYS pid from a different
# namespace than the one node sees, so the premise is NOT verified on Windows.
# Asserted here so a failure names the pid instead of arriving as a lineage error.
LIVE_SEEN="$(node -e '
let o; try { o = JSON.parse(process.argv[1]); } catch { process.stdout.write("PARSE_ERROR"); process.exit(0); }
process.stdout.write((o.rows || []).some((r) => String(r.pid) === process.argv[2]) ? "ALIVE" : "ABSENT");
' "$(trail "$STORE" "$SID_C" "$LIVE_PID" instances --json)" "$LIVE_PID")"
[ "$LIVE_SEEN" = "ALIVE" ] && check "L0b the suite's own pid ($LIVE_PID) reads as a live session, so the liveness checks below mean something" PASS || check "L0b the suite's own pid ($LIVE_PID) does NOT read as live ($LIVE_SEEN) — L8b/L16/L24 would fail for that reason, not for theirs" FAIL

# ── L1/L2 — adopt writes one edge, and never overwrites ─────────────────────
reset_ledger
trail "$STORE" "$SID_B" "$DEAD_PID" adopt "$SID_A" --reason rate_limit --all >/dev/null
[ "$(edge_count)" = "1" ] && check "L1 adopt writes exactly one edge record" PASS || check "L1 adopt writes exactly one edge record (got $(edge_count))" FAIL

trail "$STORE" "$SID_C" "$LIVE_PID" adopt "$SID_B" --all >/dev/null
[ "$(edge_count)" = "2" ] && check "L2 a second adopt adds a second record and overwrites nothing" PASS || check "L2 a second adopt adds a second record (got $(edge_count))" FAIL

# ── L3 — the record shape ───────────────────────────────────────────────────
EDGE_FILE="$(find "$CFG/zensu/session-lineage/v1/edges" -name '*.json' | sort | head -1)"
EDGE_JSON="$([ -n "$EDGE_FILE" ] && cat "$EDGE_FILE")"
SHAPE_OK=PASS
[ -n "$EDGE_JSON" ] || SHAPE_OK=FAIL
for k in schemaVersion from to repo reason inferred recordedAt recordedBy; do
  case "$(jq_field "$EDGE_JSON" "$k")" in ABSENT|PARSE_ERROR) SHAPE_OK=FAIL ;; esac
done
check "L3 an edge record carries every contracted top-level field" "$SHAPE_OK"
[ "$(jq_field "$EDGE_JSON" schemaVersion)" = "1" ] && check "L3a schemaVersion is 1" PASS || check "L3a schemaVersion is 1" FAIL
[ "$(jq_field "$EDGE_JSON" inferred)" = "false" ] && check "L3b an adopt edge is not marked inferred" PASS || check "L3b an adopt edge is not marked inferred" FAIL
[ "$(jq_field "$EDGE_JSON" recordedBy)" = "adopt" ] && check "L3c recordedBy names the verb that wrote it" PASS || check "L3c recordedBy names the verb that wrote it" FAIL

# ── L4 — Windows-illegal characters in the file name ────────────────────────
# ':' is legal on POSIX and forbidden on Windows, so an ISO timestamp in the name
# would make every edge unwritable there — and this suite is meant to run there.
COLON_HITS="$(find "$CFG/zensu/session-lineage/v1/edges" -name '*:*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$COLON_HITS" = "0" ] && check "L4 no edge file name contains ':' (unwritable on Windows)" PASS || check "L4 no edge file name contains ':'" FAIL

# ── L5 — the account comes from the store's top-level directory ─────────────
FROM_ACCT="$(jq_field "$EDGE_JSON" from.accountUuid)"
[ "$FROM_ACCT" = "$ACCT_A" ] && check "L5 accountUuid is the desktop store's top-level directory" PASS || check "L5 accountUuid is the store's top-level directory (want $ACCT_A, got ${FROM_ACCT:-<empty>})" FAIL

# ── L6 — no store: account is null, the chain survives ─────────────────────
# The account is resolved when the edge is WRITTEN, so this has to write one with
# the store unreachable. Asserting against the edges L1/L2 already wrote would only
# re-read a value captured while the store was present — a check that passes on a
# build where store resolution is broken in every direction.
reset_ledger
trail "$NOSTORE" "$SID_B" "$DEAD_PID" adopt "$SID_A" --reason rate_limit --all >/dev/null
OUT="$(trail "$NOSTORE" "$SID_C" "$LIVE_PID" lineage --json --all)"
CHAINS="$(jq_field "$OUT" chains)"
NOSTORE_ACCT="$(node -e '
let o; try { o = JSON.parse(process.argv[1]); } catch { process.stdout.write("PARSE_ERROR"); process.exit(0); }
const first = (o.chains || [])[0];
const link = first && first.links && first.links[0];
process.stdout.write(link ? String(link.from.accountUuid) : "NO_LINK");
' "$OUT")"
[ "$NOSTORE_ACCT" = "null" ] && check "L6 with no reachable store the account is null rather than guessed" PASS || check "L6 with no reachable store the account is null (got ${NOSTORE_ACCT:-<empty>})" FAIL
[ "$CHAINS" != "ABSENT" ] && [ "$CHAINS" != "[]" ] && check "L6a the chain still renders with no store — the ledger does not depend on it" PASS || check "L6a the chain still renders with no store" FAIL

# Rebuild the two-edge chain L7/L8 read, now that L6 has cleared the ledger.
reset_ledger
trail "$STORE" "$SID_B" "$DEAD_PID" adopt "$SID_A" --reason rate_limit --all >/dev/null
trail "$STORE" "$SID_C" "$LIVE_PID" adopt "$SID_B" --all >/dev/null

# ── L7 — the chain renders its links in order ──────────────────────────────
ORDER="$(node -e '
let o; try { o = JSON.parse(process.argv[1]); } catch { process.stdout.write("PARSE_ERROR"); process.exit(0); }
const c = (o.chains || []).find((x) => (x.links || []).length >= 2);
if (!c) { process.stdout.write("NO_CHAIN"); process.exit(0); }
const seq = [c.links[0].from.sessionId, ...c.links.map((l) => l.to.sessionId)];
process.stdout.write(seq.map((s) => s.slice(0, 8)).join(">"));
' "$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --json --all)")"
[ "$ORDER" = "11111111>22222222>33333333" ] && check "L7 a three-session chain renders in handover order" PASS || check "L7 a three-session chain renders in handover order (got ${ORDER:-<empty>})" FAIL

# ── L8 — --where answers 'where did this go' from the OLD session ──────────
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --where "$SID_A" --json --all)"
CUR="$(jq_field "$OUT" current.sessionId)"
[ "$CUR" = "$SID_C" ] && check "L8 --where on the first session names the last link of the chain" PASS || check "L8 --where names the last link (want $SID_C, got ${CUR:-<empty>})" FAIL
CUR_WT="$(jq_field "$OUT" current.worktree)"
case "$CUR_WT" in *handover*) check "L8a --where reports the worktree of the continuing session" PASS ;; *) check "L8a --where reports the worktree (got ${CUR_WT:-<empty>})" FAIL ;; esac
[ "$(jq_field "$OUT" live)" = "LIVE" ] && check "L8b --where reports the live status of the continuing session" PASS || check "L8b --where reports the live status (got $(jq_field "$OUT" live))" FAIL

# A session nobody handed over must say so, not answer with somebody else's chain.
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --where "99999999" --json --all)"
[ "$(jq_field "$OUT" found)" = "false" ] && check "L8c --where on an unrecorded session reports not-found rather than a wrong chain" PASS || check "L8c --where on an unrecorded session reports not-found" FAIL

# ── L9 — --diagnose reports what it probed ─────────────────────────────────
OUT="$(trail "$NOSTORE" "$SID_C" "$LIVE_PID" lineage --diagnose --json)"
D_OK=PASS
for k in configRoot ledgerDir labelsFile edgeCount probes platform; do
  case "$(jq_field "$OUT" "$k")" in ABSENT|PARSE_ERROR) D_OK=FAIL ;; esac
done
check "L9 --diagnose reports config root, ledger, labels, edge count, probes and platform" "$D_OK"
[ "$(jq_field "$OUT" store)" = "null" ] && check "L9a --diagnose reports a null store when none was found, instead of pretending" PASS || check "L9a --diagnose reports a null store when none was found" FAIL

# An explicit override must be authoritative: falling through to a guessed path
# would attribute sessions to accounts read out of a store nobody chose.
PROBE_COUNT="$(node -e '
let o; try { o = JSON.parse(process.argv[1]); } catch { process.stdout.write("PARSE_ERROR"); process.exit(0); }
process.stdout.write(String((o.probes || []).length));
' "$OUT")"
[ "$PROBE_COUNT" = "1" ] && check "L9b ZENSU_CCD_STORE is authoritative — no fallback probe behind it" PASS || check "L9b ZENSU_CCD_STORE is authoritative (probe count ${PROBE_COUNT:-<empty>})" FAIL

# ── L10 — CLAUDE_CONFIG_DIR redirects the ledger ───────────────────────────
ALTCFG="$FAKE/altcfg"
mkdir -p "$ALTCFG"
HOME="$FAKE" USERPROFILE="$FAKE" ZENSU_CCD_STORE="$STORE" CLAUDE_CONFIG_DIR="$ALTCFG" \
  CLAUDE_CODE_SESSION_ID="$SID_C" CLAUDE_PID="$LIVE_PID" \
  node "$TRAIL_MJS" lineage --diagnose --json >"$FAKE/alt.json" 2>&1
ALT_ROOT="$(jq_field "$(cat "$FAKE/alt.json")" configRoot)"
same_path "$ALTCFG" "$ALT_ROOT" && check "L10 CLAUDE_CONFIG_DIR redirects the config root away from ~/.claude" PASS || check "L10 CLAUDE_CONFIG_DIR redirects the config root (got ${ALT_ROOT:-<empty>})" FAIL
ALT_LEDGER="$(jq_field "$(cat "$FAKE/alt.json")" ledgerDir)"
case "$(norm "$ALT_LEDGER")" in "$(norm "$(hostpath "$ALTCFG")")"/*) check "L10a the ledger follows CLAUDE_CONFIG_DIR, not the home directory" PASS ;; *) check "L10a the ledger follows CLAUDE_CONFIG_DIR (got ${ALT_LEDGER:-<empty>})" FAIL ;; esac

# ── L11 — an unreadable edge record is counted, never swallowed ────────────
mkdir -p "$CFG/zensu/session-lineage/v1/edges"
printf 'not json at all' > "$CFG/zensu/session-lineage/v1/edges/9999999999-deadbeef.json"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --json --all)"
[ "$(jq_field "$OUT" skipped)" -ge 1 ] 2>/dev/null && check "L11 an unparseable edge record is counted in skipped, not silently dropped" PASS || check "L11 an unparseable edge record is counted in skipped (got $(jq_field "$OUT" skipped))" FAIL
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --all)"
case "$TXT" in *"record(s) unreadable and skipped"*) check "L11a the text channel says the output is incomplete" PASS ;; *) check "L11a the text channel says the output is incomplete" FAIL ;; esac

# A record with the wrong schema version is refused the same way — accepting it
# would let a future shape be read with today's field meanings.
printf '{"schemaVersion":99,"from":{"sessionId":"a"},"to":{"sessionId":"b"}}' > "$CFG/zensu/session-lineage/v1/edges/9999999998-deadbee2.json"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --json --all)"
[ "$(jq_field "$OUT" skipped)" -ge 2 ] 2>/dev/null && check "L11b an edge record with an unknown schemaVersion is refused, not read with today's meanings" PASS || check "L11b an edge record with an unknown schemaVersion is refused (skipped=$(jq_field "$OUT" skipped))" FAIL
rm -f "$CFG/zensu/session-lineage/v1/edges/9999999999-deadbeef.json" "$CFG/zensu/session-lineage/v1/edges/9999999998-deadbee2.json"

# ── L12 — takeover records automatically; --no-record opts out ─────────────
reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_A" --no-git --all --no-record >/dev/null
[ "$(edge_count)" = "0" ] && check "L12 takeover --no-record writes no edge" PASS || check "L12 takeover --no-record writes no edge (got $(edge_count))" FAIL

trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_A" --no-git --all >/dev/null
[ "$(edge_count)" = "1" ] && check "L12a takeover without the flag records exactly one edge" PASS || check "L12a takeover records exactly one edge (got $(edge_count))" FAIL

TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_A" --no-git --all)"
case "$TXT" in *"LINEAGE  recorded"*) check "L12b the write is announced — a read command that writes says so" PASS ;; *) check "L12b the write is announced" FAIL ;; esac

# The --json path must record too: a tool-driven takeover is a takeover.
reset_ledger
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_A" --no-git --all --json)"
[ "$(jq_field "$OUT" lineage.recorded)" = "true" ] && check "L12c the --json path records the edge as well as the text path" PASS || check "L12c the --json path records the edge (got $(jq_field "$OUT" lineage.recorded))" FAIL
[ "$(edge_count)" = "1" ] && check "L12d the --json takeover left exactly one record on disk" PASS || check "L12d the --json takeover left exactly one record (got $(edge_count))" FAIL

# Taking over yourself is not a handover, and a process outside Claude Code cannot
# name the continuing session at all — both must decline rather than invent one.
reset_ledger
OUT="$(trail "$STORE" "$SID_A" "$DEAD_PID" takeover "$SID_A" --no-git --all --json)"
[ "$(jq_field "$OUT" lineage.reason)" = "self-target" ] && check "L12e a session is never recorded as its own continuation" PASS || check "L12e a session is never recorded as its own continuation (got $(jq_field "$OUT" lineage.reason))" FAIL
[ "$(edge_count)" = "0" ] && check "L12f the declined self-takeover wrote nothing" PASS || check "L12f the declined self-takeover wrote nothing (got $(edge_count))" FAIL

# CLAUDE_CODE_SESSION_ID is emptied EXPLICITLY, not merely left unset: this suite
# usually runs inside a Claude Code session, which exports it — inheriting the
# runner's own id would have this case record a real edge and pass for the wrong
# reason.
OUT="$(cd "$SELF_CWD" && HOME="$FAKE" USERPROFILE="$FAKE" ZENSU_CCD_STORE="$STORE" CLAUDE_CODE_SESSION_ID="" CLAUDE_CODE_HOST_SESSION_ID="" env -u CLAUDE_CONFIG_DIR node "$TRAIL_MJS" takeover "$SID_A" --no-git --all --json --config-dir "$CFG" 2>&1)"
[ "$(jq_field "$OUT" lineage.reason)" = "no-self-session-id" ] && check "L12g without CLAUDE_CODE_SESSION_ID no endpoint is invented" PASS || check "L12g without CLAUDE_CODE_SESSION_ID no endpoint is invented (got $(jq_field "$OUT" lineage.reason))" FAIL

# ── L13 — backfill is a dry run until --apply ──────────────────────────────
reset_ledger
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --backfill --json --all)"
[ "$(edge_count)" = "0" ] && check "L13 --backfill without --apply writes nothing" PASS || check "L13 --backfill without --apply writes nothing (got $(edge_count))" FAIL
[ "$(jq_field "$OUT" dryRun)" = "true" ] && check "L13a --backfill reports itself as a dry run" PASS || check "L13a --backfill reports itself as a dry run" FAIL

trail "$STORE" "$SID_C" "$LIVE_PID" lineage --backfill --apply --all >/dev/null
BF_COUNT="$(edge_count)"
[ "$BF_COUNT" -ge 1 ] && check "L13b --backfill --apply records the reconstructed edge" PASS || check "L13b --backfill --apply records the reconstructed edge (got $BF_COUNT)" FAIL

ALL_INFERRED="$(node -e '
const fs = require("fs"), path = require("path");
const dir = process.argv[1];
const files = fs.readdirSync(dir).filter((f) => f.endsWith(".json"));
if (!files.length) { process.stdout.write("NO_FILES"); process.exit(0); }
const bad = files.filter((f) => {
  const o = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
  return o.inferred !== true || o.recordedBy !== "backfill";
});
process.stdout.write(bad.length ? `BAD:${bad.length}` : "ALL_INFERRED");
' "$CFG/zensu/session-lineage/v1/edges")"
[ "$ALL_INFERRED" = "ALL_INFERRED" ] && check "L13c every backfilled edge is marked inferred and recordedBy=backfill" PASS || check "L13c every backfilled edge is marked inferred (got $ALL_INFERRED)" FAIL

TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --all)"
case "$TXT" in *"[inferred"*) check "L13d a rendered chain marks an inferred link, so a guess never reads like a measurement" PASS ;; *) check "L13d a rendered chain marks an inferred link" FAIL ;; esac

# Re-running must not duplicate what the ledger already holds.
BEFORE="$(edge_count)"
trail "$STORE" "$SID_C" "$LIVE_PID" lineage --backfill --apply --all >/dev/null
[ "$(edge_count)" = "$BEFORE" ] && check "L13e a second --apply does not duplicate an edge the ledger already holds" PASS || check "L13e a second --apply does not duplicate (before $BEFORE, after $(edge_count))" FAIL

# ── L14 — backfill discriminates: same account is a resume, not a handover ──
reset_ledger
fix "$SID_D" "$DEAD_PID" 90 sameacct "$ACCT_A" stalled
fix "$SID_E" "$DEAD_PID" 60 sameacct "$ACCT_A"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --backfill --json --all)"
SAME_HIT="$(node -e '
let o; try { o = JSON.parse(process.argv[1]); } catch { process.stdout.write("PARSE_ERROR"); process.exit(0); }
process.stdout.write(String((o.candidates || []).filter((c) => c.from.startsWith("44444444")).length));
' "$OUT")"
DIFF_HIT="$(node -e '
let o; try { o = JSON.parse(process.argv[1]); } catch { process.stdout.write("PARSE_ERROR"); process.exit(0); }
process.stdout.write(String((o.candidates || []).filter((c) => c.from.startsWith("11111111")).length));
' "$OUT")"
# The positive control: without it an empty candidate list — a renamed field, a
# broken heuristic — would satisfy the absence assertion having exercised nothing.
[ "$DIFF_HIT" -ge 1 ] 2>/dev/null && check "L14-control the different-account pair IS proposed in the same invocation" PASS || check "L14-control the different-account pair is proposed (got ${DIFF_HIT:-<empty>}) — the absence below would be vacuous" FAIL
[ "$SAME_HIT" = "0" ] && check "L14 a successor under the SAME account is a resumption, not a proposed handover" PASS || check "L14 a same-account successor is not proposed (got $SAME_HIT)" FAIL

# ── L15 — labels are cosmetic, the grouping is not ─────────────────────────
reset_ledger
trail "$STORE" "$SID_B" "$DEAD_PID" adopt "$SID_A" --reason rate_limit --all >/dev/null
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --all)"
case "$TXT" in *"account aaaaaaaa"*) check "L15 an unlabelled account renders as its own uuid prefix" PASS ;; *) check "L15 an unlabelled account renders as its uuid prefix" FAIL ;; esac

trail "$STORE" "$SID_C" "$LIVE_PID" label "$ACCT_A" "Account One" >/dev/null
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --all)"
case "$TXT" in *"Account One"*) check "L15a a labelled account renders under its label" PASS ;; *) check "L15a a labelled account renders under its label" FAIL ;; esac

# The label must never become the identity: the uuid stays visible, or two
# accounts sharing a label would be indistinguishable in the chain.
case "$TXT" in *"Account One (aaaaaaaa)"*) check "L15b the label is shown WITH the uuid prefix, never instead of it" PASS ;; *) check "L15b the label is shown with the uuid prefix" FAIL ;; esac

# ── L16 — instances carries the lineage ────────────────────────────────────
# The edge has to reach a session that is actually LIVE: liveRegistry() drops every
# dead pid, so `instances` only ever renders live rows, and an edge between two
# finished sessions could not be observed here at all.
trail "$STORE" "$SID_C" "$LIVE_PID" adopt "$SID_B" --all >/dev/null
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" instances --json)"
INST_LINEAGE="$(node -e '
let o; try { o = JSON.parse(process.argv[1]); } catch { process.stdout.write("PARSE_ERROR"); process.exit(0); }
const withLineage = (o.rows || []).filter((r) => Array.isArray(r.lineage) && r.lineage.length);
process.stdout.write(String(withLineage.length));
' "$OUT")"
[ "$INST_LINEAGE" -ge 1 ] 2>/dev/null && check "L16 instances reports the lineage of a session, so one call answers it from any window" PASS || check "L16 instances reports the lineage of a session (got ${INST_LINEAGE:-<empty>})" FAIL

# ── L17 — operand validation ───────────────────────────────────────────────
# An operand swallowed from the following flag would silently make "--json" the
# directory the ledger is written into.
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --where --json --all)"
case "$OUT" in *"--where needs a value"*) check "L17 a flag consumed as an operand is refused, not written into the ledger path" PASS ;; *) check "L17 a flag consumed as an operand is refused" FAIL ;; esac

# ── L18 — the non-macOS store candidates are real, not decoration ──────────
# These carry the cross-platform promise and are the ONLY paths a Windows or
# Linux user can be found through, yet they were unexercised: every case above
# sets $ZENSU_CCD_STORE, which short-circuits the whole probe list. Reaching them
# needs the override UNSET and the macOS candidate absent, which is what the
# synthetic HOME provides. A regression here is invisible on this developer's
# machine and total on the platforms it is for.
probe_store() { # <env-assignment>
  local assignment="$1"
  local out
  # Every store variable unset, not only the override: %APPDATA% and %LOCALAPPDATA%
  # are always defined on Windows and are not derived from the redirected
  # USERPROFILE, so a real store could answer these checks — a PASS the fixture had
  # no part in, while reading the developer's real store.
  out="$(cd "$SELF_CWD" && env -u ZENSU_CCD_STORE -u APPDATA -u LOCALAPPDATA -u XDG_CONFIG_HOME HOME="$FAKE" USERPROFILE="$FAKE" \
    CLAUDE_CODE_SESSION_ID="$SID_C" CLAUDE_PID="$LIVE_PID" \
    "$assignment" env -u CLAUDE_CONFIG_DIR node "$TRAIL_MJS" lineage --diagnose --json --config-dir "$CFG" 2>&1)"
  printf '%s|%s' "$(jq_field "$out" store.source)" "$(jq_field "$out" store.dir)"
}

# source AND directory, both required. The earlier spelling appended a marker to a
# string the case arm still matched, so a wrong directory passed.
probe_ok() { # <combined> <source-substring> <expected-dir>
  local src="${1%%|*}" dir="${1##*|}"
  case "$src" in *"$2"*) ;; *) return 1 ;; esac
  same_path "$3" "$dir"
}

mkdir -p "$FAKE/appdata/Claude/claude-code-sessions/$ACCT_A/ws-0001"
GOT="$(probe_store "APPDATA=$FAKE/appdata")"
if probe_ok "$GOT" "Windows APPDATA" "$FAKE/appdata/Claude/claude-code-sessions"; then check "L18 the %APPDATA% candidate is probed and can win" PASS; else check "L18 the %APPDATA% candidate is probed and can win (got $GOT)" FAIL; fi

mkdir -p "$FAKE/localappdata/Claude/claude-code-sessions/$ACCT_A/ws-0001"
GOT="$(probe_store "LOCALAPPDATA=$FAKE/localappdata")"
if probe_ok "$GOT" "LOCALAPPDATA" "$FAKE/localappdata/Claude/claude-code-sessions"; then check "L18a the %LOCALAPPDATA% candidate is probed and can win" PASS; else check "L18a the %LOCALAPPDATA% candidate is probed and can win (got $GOT)" FAIL; fi

mkdir -p "$FAKE/xdg/Claude/claude-code-sessions/$ACCT_A/ws-0001"
GOT="$(probe_store "XDG_CONFIG_HOME=$FAKE/xdg")"
if probe_ok "$GOT" "XDG_CONFIG_HOME" "$FAKE/xdg/Claude/claude-code-sessions"; then check "L18b the \$XDG_CONFIG_HOME candidate is probed and can win" PASS; else check "L18b the \$XDG_CONFIG_HOME candidate is probed and can win (got $GOT)" FAIL; fi

# The bare ~/.config fallback needs no env var at all, so it is the one Linux
# users get by default.
mkdir -p "$FAKE/.config/Claude/claude-code-sessions/$ACCT_A/ws-0001"
GOT="$(cd "$SELF_CWD" && env -u ZENSU_CCD_STORE -u APPDATA -u LOCALAPPDATA -u XDG_CONFIG_HOME HOME="$FAKE" USERPROFILE="$FAKE" \
  CLAUDE_CODE_SESSION_ID="$SID_C" CLAUDE_PID="$LIVE_PID" \
  env -u CLAUDE_CONFIG_DIR node "$TRAIL_MJS" lineage --diagnose --json --config-dir "$CFG" 2>&1)"
case "$(jq_field "$GOT" store.source)" in *"Linux ~/.config"*) check "L18c the bare ~/.config candidate is probed with no env var set" PASS ;; *) check "L18c the bare ~/.config candidate is probed (got $(jq_field "$GOT" store.source))" FAIL ;; esac

# ── L19 — the running session's own account, resolved by record NAME ────────
# ccdIndex() keys on cliSessionId, so a session whose desktop record does not
# carry one is invisible to it. CLAUDE_CODE_HOST_SESSION_ID names the record file
# directly, and that fallback is how the CURRENT session finds its own account —
# the single lookup that does not depend on the transcript being readable.
mkdir -p "$STORE/$ACCT_B/ws-0002"
printf '{"isArchived":false,"title":"orphan record with no cliSessionId"}' > "$STORE/$ACCT_B/ws-0002/local_orphan-host.json"
reset_ledger
OUT="$(cd "$SELF_CWD" && HOME="$FAKE" USERPROFILE="$FAKE" ZENSU_CCD_STORE="$STORE" \
  CLAUDE_CODE_SESSION_ID="ffffffff-0000-0000-0000-0000000000ff" CLAUDE_PID="$LIVE_PID" \
  CLAUDE_CODE_HOST_SESSION_ID="local_orphan-host" \
  env -u CLAUDE_CONFIG_DIR node "$TRAIL_MJS" adopt "$SID_A" --all --json --config-dir "$CFG" 2>&1)"
GOT="$(jq_field "$OUT" recorded.to.accountUuid)"
[ "$GOT" = "$ACCT_B" ] && check "L19 a session with no cliSessionId record still resolves its account through the record file name" PASS || check "L19 the host-session-id fallback resolves the account (want $ACCT_B, got ${GOT:-<empty>})" FAIL
rm -f "$STORE/$ACCT_B/ws-0002/local_orphan-host.json"

# ── L20 — a ledger that cannot be written is reported, never swallowed ──────
# The ledger's own parent is made a FILE, so mkdirSync fails with ENOTDIR for
# every uid — a chmod-based fixture would silently pass when the suite runs as
# root, which is how CI containers run. The CONFIG root stays valid on purpose:
# breaking that instead would fail the selector lookup long before the ledger is
# touched, and the check would pass on a build where the write path is fine.
reset_ledger
rm -rf "$CFG/zensu"
printf 'not a directory' > "$CFG/zensu"
OUT="$(cd "$SELF_CWD" && HOME="$FAKE" USERPROFILE="$FAKE" ZENSU_CCD_STORE="$STORE" \
  CLAUDE_CODE_SESSION_ID="$SID_C" CLAUDE_PID="$LIVE_PID" \
  env -u CLAUDE_CONFIG_DIR node "$TRAIL_MJS" takeover "$SID_A" --no-git --all --json --config-dir "$CFG" 2>&1)"
[ "$(jq_field "$OUT" lineage.recorded)" = "false" ] && check "L20 an unwritable ledger reports the failure instead of claiming a record" PASS || check "L20 an unwritable ledger reports the failure (got $(jq_field "$OUT" lineage.recorded))" FAIL
[ "$(jq_field "$OUT" lineage.reason)" = "write-failed" ] && check "L20a the failure names itself as a write failure, not as an opt-out" PASS || check "L20a the failure names itself as a write failure (got $(jq_field "$OUT" lineage.reason))" FAIL
rm -f "$CFG/zensu"

# ── L21 — label --self ──────────────────────────────────────────────────────
# The spelling a user actually reaches for: naming the window they are sitting in,
# without having to look a UUID up first.
trail "$STORE" "$SID_C" "$LIVE_PID" label --self "This Window" >/dev/null
# Asserted on the KEY, not merely on the value: a build where --self fell through
# to the window-pid namespace would otherwise pass a check about the ACCOUNT.
LABELED="$(node -e '
const fs = require("fs");
try {
  const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  process.stdout.write((o.accounts || {})[process.argv[2]] === "This Window" ? "YES" : `NO:${JSON.stringify(o)}`);
} catch (e) { process.stdout.write("UNREADABLE"); }
' "$CFG/zensu/session-lineage/v1/labels.json" "$ACCT_C")"
[ "$LABELED" = "YES" ] && check "L21 label --self keys the running session's own ACCOUNT, not the window-pid fallback" PASS || check "L21 label --self keys the running session's own account (got $LABELED)" FAIL

# An empty label is a deletion in disguise; it must be refused, not written.
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" label --self "")"
case "$OUT" in *"usage: label"*) check "L21a an empty label is refused rather than silently stored" PASS ;; *) check "L21a an empty label is refused (got ${OUT:-<empty>})" FAIL ;; esac

# ── L22 — the cycle guard, which nothing exercised ─────────────────────────
# walkChain documents `seen` as the difference between a wrong answer and a hang.
# Nothing planted a cycle, so deleting the guard left all checks green and the
# regression would have surfaced only as a shard timeout — which silently
# truncates the tail of a shard rather than reporting.
reset_ledger
mkdir -p "$CFG/zensu/session-lineage/v1/edges"
cyc() { # <n> <from> <to>
  mkdir -p "$CFG/zensu/session-lineage/v1/edges"
  printf '{"schemaVersion":1,"from":{"sessionId":"%s"},"to":{"sessionId":"%s"},"repo":{"name":"r","root":"/r"},"reason":"manual","inferred":false,"recordedAt":"2026-01-0%sT00:00:00.000Z","recordedBy":"adopt"}' \
    "$2" "$3" "$1" > "$CFG/zensu/session-lineage/v1/edges/100000000$1-aaaaaaaa.json"
}
cyc 1 "$SID_A" "$SID_B"
cyc 2 "$SID_B" "$SID_A"
CYC_OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --json --all)"
# The LENGTH, not merely that the payload parses: walkChain also stops at its
# 64-hop bound, so a parseable payload is satisfied even with the seen set deleted.
CYC_LEN="$(node -e '
let o; try { o = JSON.parse(process.argv[1]); } catch { process.stdout.write("PARSE_ERROR"); process.exit(0); }
const c = (o.chains || [])[0];
process.stdout.write(c ? String((c.links || []).length) : "NO_CHAIN");
' "$CYC_OUT")"
{ [ "$CYC_LEN" != "PARSE_ERROR" ] && [ "$CYC_LEN" != "NO_CHAIN" ] && [ "$CYC_LEN" -le 2 ]; } 2>/dev/null \
  && check "L22 a cyclic ledger stops on the seen set, not on the hop bound (links=$CYC_LEN)" PASS \
  || check "L22 a cyclic ledger stops on the seen set (links=${CYC_LEN:-<empty>}, expected <= 2)" FAIL
CYC_CHAINS="$(node -e '
let o; try { o = JSON.parse(process.argv[1]); } catch { process.stdout.write("PARSE_ERROR"); process.exit(0); }
process.stdout.write(String((o.chains || []).length));
' "$CYC_OUT")"
[ "$CYC_CHAINS" -ge 1 ] 2>/dev/null && check "L22a a cycle still renders a chain — a non-zero count above no chain at all is the worse answer" PASS || check "L22a a cycle still renders a chain (got ${CYC_CHAINS:-<empty>})" FAIL

# ── L23 — a fork is reported, not silently dropped ─────────────────────────
reset_ledger
cyc 1 "$SID_A" "$SID_B"
cyc 2 "$SID_A" "$SID_C"
FORKS="$(node -e '
let o; try { o = JSON.parse(process.argv[1]); } catch { process.stdout.write("PARSE_ERROR"); process.exit(0); }
const all = (o.chains || []).flatMap((c) => c.forks || []);
process.stdout.write(String(all.length));
' "$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --json --all)")"
[ "$FORKS" -ge 1 ] 2>/dev/null && check "L23 two windows taking over one session is reported as a fork, not silently halved" PASS || check "L23 a fork is reported (got ${FORKS:-<empty>})" FAIL

# ── L24 — instances shows the FORWARD direction ────────────────────────────
# The `→ continued in` branch is the one the feature is justified by: the window
# that ran out of quota cannot ask, so one call from any working window has to
# answer where its work went. Only the `←` branch had ever executed.
reset_ledger
trail "$STORE" "$SID_B" "$DEAD_PID" adopt "$SID_C" --all >/dev/null
FWD="$(node -e '
let o; try { o = JSON.parse(process.argv[1]); } catch { process.stdout.write("PARSE_ERROR"); process.exit(0); }
const lines = (o.rows || []).flatMap((r) => r.lineage || []);
process.stdout.write(lines.some((l) => l.startsWith("\u2192")) ? "FORWARD" : `NONE:${JSON.stringify(lines)}`);
' "$(trail "$STORE" "$SID_C" "$LIVE_PID" instances --json)")"
[ "$FWD" = "FORWARD" ] && check "L24 instances renders the forward direction for a session that was handed OFF" PASS || check "L24 instances renders the forward direction (got $FWD)" FAIL

# ── L25 — repo scoping, which every earlier check bypassed with --all ──────
# Without this the default invocation — the one SKILL.md describes as "the chains
# for this repo" — had zero coverage, which is exactly what let an edge filed
# under the wrong repo pass unnoticed.
REPO_A="$FAKE/repos/alpha"; REPO_B="$FAKE/repos/beta"
mkdir -p "$REPO_A" "$REPO_B"
git -C "$REPO_A" init -q 2>/dev/null; git -C "$REPO_B" init -q 2>/dev/null
if [ -d "$REPO_A/.git" ] && [ -d "$REPO_B/.git" ]; then
  reset_ledger
  mkdir -p "$CFG/zensu/session-lineage/v1/edges"
  printf '{"schemaVersion":1,"from":{"sessionId":"%s","worktree":"%s"},"to":{"sessionId":"%s","worktree":"%s"},"repo":{"name":"alpha","root":"%s"},"reason":"rate_limit","inferred":false,"recordedAt":"2026-01-01T00:00:00.000Z","recordedBy":"adopt"}' \
    "$SID_A" "$REPO_A" "$SID_B" "$REPO_A" "$REPO_A" > "$CFG/zensu/session-lineage/v1/edges/1000000001-bbbbbbbb.json"
  IN_A="$(cd "$REPO_A" && HOME="$FAKE" USERPROFILE="$FAKE" ZENSU_CCD_STORE="$STORE" CLAUDE_CODE_SESSION_ID="$SID_C" CLAUDE_PID="$LIVE_PID" env -u CLAUDE_CONFIG_DIR node "$TRAIL_MJS" lineage --json --config-dir "$CFG" 2>&1)"
  IN_B="$(cd "$REPO_B" && HOME="$FAKE" USERPROFILE="$FAKE" ZENSU_CCD_STORE="$STORE" CLAUDE_CODE_SESSION_ID="$SID_C" CLAUDE_PID="$LIVE_PID" env -u CLAUDE_CONFIG_DIR node "$TRAIL_MJS" lineage --json --config-dir "$CFG" 2>&1)"
  [ "$(jq_field "$IN_A" edgeCount)" = "1" ] && check "L25 a repo-scoped lineage finds the handover in the repo the work belongs to" PASS || check "L25 repo-scoped lineage finds the handover (got $(jq_field "$IN_A" edgeCount))" FAIL
  [ "$(jq_field "$IN_B" edgeCount)" = "0" ] && check "L25a and does NOT show it in an unrelated repo" PASS || check "L25a does not leak into an unrelated repo (got $(jq_field "$IN_B" edgeCount))" FAIL
else
  skip "L25/L25a repo-scoping checks (git init unavailable)"
fi

# ── L26 — a --where prefix that is too short is refused ────────────────────
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --where "  " --all)"
case "$OUT" in *"at least 6 characters"*) check "L26 a blank or too-short --where is refused instead of matching every edge" PASS ;; *) check "L26 a blank --where is refused (got ${OUT:-<empty>})" FAIL ;; esac

# ── L27 — an unreadable ledger never reads as an empty history ─────────────
reset_ledger
mkdir -p "$CFG/zensu/session-lineage/v1"
printf 'x' > "$CFG/zensu/session-lineage/v1/edges"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --all)"
case "$OUT" in *"could not be read"*) check "L27 an unreadable ledger says so instead of asserting nothing was recorded" PASS ;; *) check "L27 an unreadable ledger says so (got ${OUT:-<empty>})" FAIL ;; esac
rm -f "$CFG/zensu/session-lineage/v1/edges"

# -- L30 -- --apply is refused while ANY record is unreadable ---------------
# The duplicate guard is built from the read: one dropped record is one pair
# missing from it, so an edge that IS already recorded re-proposes and --apply
# mints a second copy machine-wide. The whole-directory case was already refused;
# this is the per-record half. The positive control matters more than the refusal
# here -- a gate that refused unconditionally would satisfy the first assertion
# alone and would have made --apply permanently unreachable.
reset_ledger
mkdir -p "$CFG/zensu/session-lineage/v1/edges"
printf 'not json' > "$CFG/zensu/session-lineage/v1/edges/1-deadbeefdeadbeef.json"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --backfill --apply --json --all)"
[ "$(jq_field "$OUT" applied)" = "false" ] && check "L30 --apply is refused while a ledger record is unreadable" PASS || check "L30 --apply is refused while a record is unreadable (applied=$(jq_field "$OUT" applied))" FAIL
[ "$(jq_field "$OUT" refusal)" = "records-refused" ] && check "L30a the refusal names the per-record cause, not the directory one" PASS || check "L30a the refusal names the per-record cause (got $(jq_field "$OUT" refusal))" FAIL
[ "$(jq_field "$OUT" refusedRecords)" = "1" ] && check "L30b the refused-record count is reported, not just the verdict" PASS || check "L30b the refused-record count is reported (got $(jq_field "$OUT" refusedRecords))" FAIL
rm -f "$CFG/zensu/session-lineage/v1/edges/1-deadbeefdeadbeef.json"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --backfill --apply --json --all)"
[ "$(jq_field "$OUT" applied)" = "true" ] && check "L30c and a readable ledger still applies -- the gate is not unconditional" PASS || check "L30c a readable ledger still applies (applied=$(jq_field "$OUT" applied))" FAIL
reset_ledger

# -- L28/L29 -- the suite's own isolation, scanned rather than assumed ------
# `--config-dir` already outranks CLAUDE_CONFIG_DIR in resolveRoots, so the unset
# is belt, not the mechanism -- and belt that nothing pins rots. A check added
# later by copying the L10 line inherits the developer's REAL config root and a
# `takeover` there writes a real edge into it. Both halves are asserted: every
# invocation carries the unset, and EXACTLY ONE is exempt. Either alone is
# satisfiable by accident -- a second forgotten `env -u` is indistinguishable
# from a second deliberate exemption.
SELF_FILE="$PLUGIN_DIR/tests/structure/test-session-trail-lineage.sh"
INV_TOTAL="$(grep -c 'node "\$TRAIL_MJS"' "$SELF_FILE" || true)"
INV_UNSET="$(grep -c 'env -u CLAUDE_CONFIG_DIR node "\$TRAIL_MJS"' "$SELF_FILE" || true)"
INV_EXEMPT=$(( INV_TOTAL - INV_UNSET ))
if [ "$INV_TOTAL" -ge 8 ] && [ "$INV_EXEMPT" -eq 1 ]; then
  check "L28 every trail.mjs invocation unsets CLAUDE_CONFIG_DIR except the one case that tests it ($INV_UNSET/$INV_TOTAL)" PASS
else
  check "L28 exactly one CLAUDE_CONFIG_DIR exemption (total=$INV_TOTAL unset=$INV_UNSET exempt=$INV_EXEMPT)" FAIL
fi
# And that the one exemption is the L10 case specifically, not whichever line
# happened to be forgotten -- the count above cannot tell those apart.
if grep -q 'CLAUDE_CONFIG_DIR="$ALTCFG"' "$SELF_FILE" \
  && [ "$(awk '/CLAUDE_CONFIG_DIR="\$ALTCFG"/{f=3} f&&/node "\$TRAIL_MJS"/&&!/env -u/{c++} f{f--} END{print c+0}' "$SELF_FILE")" -eq 1 ]; then
  check "L29 the single exemption is the L10 case, which must see the variable it tests" PASS
else
  check "L29 the single exemption is the L10 case" FAIL
fi

report
