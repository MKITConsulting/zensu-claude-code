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
# BOTH summary spellings: `# tests`/`# pass` is the TAP reporter's form, and
# capturing only the other one made an empty capture look like a module failure.
# `^.*[[:space:]]` rather than a leading `.`: the spec reporter prefixes each
# summary with a three-BYTE glyph, and `.` matches one byte -- so under a non-UTF-8
# locale the capture came back empty, UNIT_TOTAL fell to 0, and a healthy module
# was reported as a failure. Anchored on the WORD and the digits instead.
UNIT_TOTAL="$(printf '%s' "$UNIT_OUT" | sed -n 's/^.*[[:space:]]tests \([0-9][0-9]*\)$/\1/p' | tail -1)"
UNIT_PASS="$(printf '%s' "$UNIT_OUT" | sed -n 's/^.*[[:space:]]pass \([0-9][0-9]*\)$/\1/p' | tail -1)"
UNIT_SKIP="$(printf '%s' "$UNIT_OUT" | sed -n 's/^.*[[:space:]]skipped \([0-9][0-9]*\)$/\1/p' | tail -1)"
case "$UNIT_TOTAL" in ''|*[!0-9]*) UNIT_TOTAL=0 ;; esac
case "$UNIT_PASS" in ''|*[!0-9]*) UNIT_PASS=0 ;; esac
case "$UNIT_SKIP" in ''|*[!0-9]*) UNIT_SKIP=0 ;; esac
# EXACT, not a floor. A pass floor accepts a case that quietly started skipping
# itself -- which is precisely how a platform-gated case dies: the gate widens, the
# case stops running, and the suite still reports green with a smaller pass count
# than the floor allows for. TWELVE cases carry `skip: process.platform === 'win32'`
# (symlinks, modes, and the O_NONBLOCK probe); TWO of those ALSO skip as root,
# where a mode guard cannot be observed at all. Both numbers are hand-maintained on
# purpose: deriving them from the file under test would make the check agree with
# whatever that file currently says.
UNIT_PLATFORM="$(node -p 'process.platform' 2>/dev/null)"
UNIT_ROOT="$(node -p 'process.platform !== "win32" && typeof process.getuid === "function" && process.getuid() === 0 ? 2 : 0' 2>/dev/null)"
case "$UNIT_ROOT" in ''|*[!0-9]*) UNIT_ROOT=0 ;; esac
if [ "$UNIT_PLATFORM" = "win32" ]; then UNIT_SKIP_WANT=12; else UNIT_SKIP_WANT="$UNIT_ROOT"; fi
if [ "$UNIT_RC" = "0" ] && [ "$UNIT_TOTAL" -ge 61 ] && [ "$UNIT_SKIP" = "$UNIT_SKIP_WANT" ] && [ "$UNIT_PASS" = "$((UNIT_TOTAL - UNIT_SKIP))" ]; then
  check "L-unit session-lineage-v1.test.js passes ($UNIT_PASS/$UNIT_TOTAL cases, $UNIT_SKIP skipped on $UNIT_PLATFORM)" PASS
else
  check "L-unit session-lineage-v1.test.js (rc=$UNIT_RC pass=${UNIT_PASS:-0} total=${UNIT_TOTAL:-0} skipped=${UNIT_SKIP:-0}, want total>=61 and exactly $UNIT_SKIP_WANT skipped on $UNIT_PLATFORM)" FAIL
  printf '%s\n' "$UNIT_OUT" | tail -20
fi

FAKE="$(mktemp -d -t zensu-session-trail-lineage-XXXXXX)" || FAKE=""
if [ -z "$FAKE" ]; then
  check "L0 could not create the synthetic root" FAIL
  report; exit 1
fi
trap 'rm -rf "$FAKE"; [ -n "${LIVE_SLEEPER:-}" ] && kill "$LIVE_SLEEPER" 2>/dev/null; true' EXIT

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

LIVE_SLEEPER="$(node -e '
const { spawn } = require("node:child_process");
const child = spawn(process.execPath, ["-e", "setTimeout(() => {}, 1800000)"], { stdio: "ignore", detached: true });
process.stdout.write(String(child.pid));
child.unref();
' 2>/dev/null)"
case "$LIVE_SLEEPER" in ''|*[!0-9]*) LIVE_SLEEPER="" ;; esac
LIVE_PID="${LIVE_SLEEPER:-$$}"
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
# A payload that never parsed is not a rendered chain. jq_field answers
# PARSE_ERROR there, which is neither ABSENT nor "[]", so the previous two-armed
# test reported the ledger as store-independent on exactly the output that proves
# nothing. The rule is a helper so its own rejection can be controlled.
renders_chain() { # <jq value>
  case "$1" in ''|ABSENT|PARSE_ERROR|'[]') return 1 ;; *) return 0 ;; esac
}
renders_chain "$CHAINS" && check "L6a the chain still renders with no store — the ledger does not depend on it" PASS || check "L6a the chain still renders with no store (got ${CHAINS:-<empty>})" FAIL
renders_chain "PARSE_ERROR" && check "L6a-control an unparseable payload is still accepted as a rendered chain" FAIL || check "L6a-control an unparseable payload is not accepted as a rendered chain" PASS
renders_chain '[{"root":"a"}]' && check "L6a-control a real chains array is accepted" PASS || check "L6a-control a real chains array is accepted" FAIL

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

# ── L9c..L9h — the --diagnose TEXT carrier, which no check ever executed ───
# Every other --diagnose invocation in this file passes --json, so the payload FIELDS
# were pinned and none of the print lines were -- and --diagnose exists to explain, to
# a PERSON, why attribution did not happen. Its human half is the answer to this
# feature's largest stated unknown: the Windows and Linux store paths nobody has
# observed. Its own variable throughout, never the shared `OUT`: the checks in this
# file hand `OUT` forward across blocks, and a text payload landing in it is read by
# the next JSON consumer as a parse error rather than as a mistake here.
DTXT="$(trail "$NOSTORE" "$SID_C" "$LIVE_PID" lineage --diagnose --all)"
case "$DTXT" in *"CONFIG ROOT"*) check "L9c the --diagnose text carrier prints the resolved config root" PASS ;; *) check "L9c the text carrier prints the config root (got $(printf '%s' "${DTXT:-<empty>}" | head -c 80))" FAIL ;; esac
# The guidance names the override a user is meant to reach for. Saying no store was
# found without naming ZENSU_CCD_STORE leaves the remedy undiscoverable on exactly the
# two platforms whose paths are inferred rather than measured.
case "$DTXT" in *ZENSU_CCD_STORE*) check "L9d the no-store guidance names the override the user is meant to set" PASS ;; *) check "L9d the no-store guidance names ZENSU_CCD_STORE" FAIL ;; esac
# EVERY probed candidate with its verdict, not only the one that won -- and therefore
# with NO override set, because L9b above pins that an override collapses the list to
# one. A report naming the winner alone cannot answer "which path did you try on this
# machine", which is the question the unverified paths make someone ask.
DTXT_ALL="$( cd "$SELF_CWD" 2>/dev/null || cd "$FAKE"
  # `unset` rather than a second `-u` on the env call: L28 below scans for the exact
  # `env -u CLAUDE_CONFIG_DIR node "$TRAIL_MJS"` literal, and an extra unset spliced
  # into it reads as one more EXEMPTION from the isolation rule. Widening that scan to
  # accept the longer form would trade a precise guard for a vaguer one; keeping the
  # idiom costs one line here.
  unset ZENSU_CCD_STORE
  HOME="$FAKE" USERPROFILE="$FAKE" \
  env -u CLAUDE_CONFIG_DIR node "$TRAIL_MJS" lineage --diagnose --all --config-dir "$CFG" 2>&1 )"
PROBE_LINES="$(printf '%s\n' "$DTXT_ALL" | grep -cE '^ +(absent|found) ' || true)"
if [ "$PROBE_LINES" -ge 2 ]; then
  check "L9e every probed store candidate is listed with its verdict, not only the winner ($PROBE_LINES)" PASS
else
  check "L9e every probed store candidate is listed with its verdict (matched=$PROBE_LINES)" FAIL
fi
# The unreadable-ledger arm of the same carrier. --diagnose prints an edge COUNT, and a
# directory it could not read yields zero -- so the line saying that zero is not a
# measurement is the whole difference between a diagnostic and a wrong answer. A
# dedicated config root, because $CFG holds the records the rest of this file needs.
L9_CFG="$(mktemp -d -t zensu-l9-XXXXXX)"
mkdir -p "$L9_CFG/zensu/session-lineage/v1"
printf 'x' > "$L9_CFG/zensu/session-lineage/v1/edges"
DTXT_BAD="$( cd "$SELF_CWD" 2>/dev/null || cd "$FAKE"
  HOME="$FAKE" USERPROFILE="$FAKE" ZENSU_CCD_STORE="$NOSTORE" \
  env -u CLAUDE_CONFIG_DIR node "$TRAIL_MJS" lineage --diagnose --all --config-dir "$L9_CFG" 2>&1 )"
rm -rf "$L9_CFG"
case "$DTXT_BAD" in
  *"NOT a measurement"*) check "L9f an unreadable ledger says the edge count above it is NOT a measurement" PASS ;;
  *) check "L9f the unreadable-ledger disclaimer is printed (got $(printf '%s' "${DTXT_BAD:-<empty>}" | head -c 120))" FAIL ;;
esac
# And it names the CAUSE. "could not read" without an errno sends an operator looking
# for a missing directory when the real state is a file sitting on the name.
case "$DTXT_BAD" in *"LEDGER ERROR ENOTDIR"*) check "L9g the disclaimer names the errno, not just that something failed" PASS ;; *) check "L9g the disclaimer names the errno" FAIL ;; esac
# Control: the same carrier against a READABLE ledger must NOT print it, or L9f is
# satisfied by a line the command always emits.
case "$DTXT" in *"NOT a measurement"*) check "L9h-control a readable ledger prints no unreadable disclaimer" FAIL ;; *) check "L9h-control a readable ledger prints no unreadable disclaimer" PASS ;; esac

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
# The CAUSE, not only the count. `skipped` rises for an unreadable record, a
# malformed one and a wrong-schema one alike, so the count alone would have stayed
# green if the schema check were deleted outright -- the neighbouring corrupt
# record from L11 already supplies a skip of its own.
[ "$(jq_field "$OUT" schemaNewer)" = "true" ] && check "L11b an edge record with an unknown schemaVersion is refused AS a newer schema, not read with today's meanings" PASS || check "L11b the refusal names the schema as the cause (schemaNewer=$(jq_field "$OUT" schemaNewer))" FAIL
[ "$(jq_field "$OUT" skipped)" -ge 2 ] 2>/dev/null && check "L11c and the record is counted among the skipped, so the output declares itself incomplete" PASS || check "L11c the refused record is counted among the skipped (skipped=$(jq_field "$OUT" skipped))" FAIL
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

# ── L12h — what a takeover is entitled to CLAIM ───────────────────────────
# Generating a takeover brief is not the same event as having taken the session over:
# the record is written at step 2 of the documented flow while the user is asked to
# confirm at step 5, so a plain takeover may claim `provisional` and no more. --force
# carries the user's approval on the command line, and `adopt` is the confirmation
# verb — both reach `confirmed`. Before the tier existed, every declined takeover
# left a permanent, unretractable assertion that the handover had happened.
edge_field() { # <dotted-field>
  node -e '
const fs = require("fs"), path = require("path");
const dir = process.argv[1], field = process.argv[2];
const files = fs.readdirSync(dir).filter((f) => f.endsWith(".json"));
if (files.length !== 1) { process.stdout.write(`FILES:${files.length}`); process.exit(0); }
const o = JSON.parse(fs.readFileSync(path.join(dir, files[0]), "utf8"));
process.stdout.write(String(field.split(".").reduce((a, k) => (a == null ? a : a[k]), o)));
' "$CFG/zensu/session-lineage/v1/edges" "$1"
}

reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_A" --no-git --all >/dev/null
[ "$(edge_field confidence)" = "provisional" ] && check "L12h a plain takeover claims provisional, not a completed handover" PASS || check "L12h a plain takeover claims provisional (got $(edge_field confidence))" FAIL

reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_A" --no-git --all --force >/dev/null
[ "$(edge_field confidence)" = "confirmed" ] && check "L12i --force carries the approval, so the edge is confirmed" PASS || check "L12i --force records a confirmed edge (got $(edge_field confidence))" FAIL

reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" adopt "$SID_A" --all >/dev/null
[ "$(edge_field confidence)" = "confirmed" ] && check "L12j adopt is the confirmation verb and records confirmed" PASS || check "L12j adopt records a confirmed edge (got $(edge_field confidence))" FAIL

# A confirmed link carries no annotation — the ordinary case must stay quiet, or the
# marker means nothing.
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --all)"
case "$TXT" in *"[unconfirmed"*) check "L12l a confirmed link is not annotated" FAIL ;; *) check "L12l a confirmed link is not annotated, so the marker keeps its meaning" PASS ;; esac

# The tier has to REACH the reader. Recording it and rendering nothing leaves the
# user exactly where they were: unable to tell a brief that was generated from a
# handover that actually happened.
reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_A" --no-git --all >/dev/null
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --all)"
case "$TXT" in *"[unconfirmed"*) check "L12k a provisional link is marked, so a generated brief never reads as a completed handover" PASS ;; *) check "L12k a provisional link is marked" FAIL ;; esac
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --all --json)"
case "$OUT" in *'"confidence": "provisional"'*) check "L12m the --json payload carries the tier for a machine consumer" PASS ;; *) check "L12m the --json payload carries the tier" FAIL ;; esac

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

APPLY_INSTANT="$(date -u +%Y-%m-%dT%H:%M:%S)"
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

# A reconstructed edge is stamped from the STALLED SESSION'S activity, never from the
# moment --apply ran. recordedAt is the sole ordering key at four sites, so an
# apply-time stamp made every guess newer than every real handover by construction —
# one backfill then promoted guesses above measurements permanently, and printChain
# printed the backfill date as the date of the handover.
BF_LATEST="$(node -e '
const fs = require("fs"), path = require("path");
const dir = process.argv[1];
const files = fs.readdirSync(dir).filter((f) => f.endsWith(".json"));
if (!files.length) { process.stdout.write("NO_FILES"); process.exit(0); }
const stamps = files.map((f) => JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")).recordedAt).sort();
process.stdout.write(stamps[stamps.length - 1]);
' "$CFG/zensu/session-lineage/v1/edges")"
# Everything the fixture builds is well in the past, so an mtime-derived stamp is
# strictly older than the instant this suite reached the apply.
[ -n "$BF_LATEST" ] && [ "$BF_LATEST" \< "$APPLY_INSTANT" ] && check "L13f a backfilled edge is stamped from the stalled session, not from the apply" PASS || check "L13f a backfilled edge is stamped from the stalled session (got $BF_LATEST, apply ran at $APPLY_INSTANT)" FAIL

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
    "$SID_A" "$(hostpath "$REPO_A")" "$SID_B" "$(hostpath "$REPO_A")" "$(hostpath "$REPO_A")" > "$CFG/zensu/session-lineage/v1/edges/1000000001-bbbbbbbb.json"
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

# -- L31 -- lineage --forget: the removal path ------------------------------
# The store is append-only and machine-wide, so until now a wrong edge -- a
# mistaken takeover, or a guess --backfill minted -- was permanent. Nothing the
# skill offered could retract it, and the operator's only recourse was deleting a
# file whose name the tool never showed them. --forget is a dry run first for the
# same reason --backfill is: it names what it would destroy before destroying it.
# Both edges below share the SAME `to` endpoint deliberately -- a removal keyed on
# a shared endpoint rather than on the named session would take both and still
# satisfy a check that only counted the survivors.
reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_A" --no-git --all >/dev/null
trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_B" --no-git --all >/dev/null
FORGET_BEFORE="$(edge_count)"
[ "$FORGET_BEFORE" = "2" ] || check "L31-setup two edges were recorded before the removal (got $FORGET_BEFORE)" FAIL

OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --forget "$SID_A" --json --all)"
[ "$(edge_count)" = "2" ] && check "L31 --forget without --apply destroys nothing" PASS || check "L31 --forget without --apply destroys nothing (got $(edge_count) of 2)" FAIL
[ "$(jq_field "$OUT" dryRun)" = "true" ] && check "L31a --forget reports itself as a dry run" PASS || check "L31a --forget reports itself as a dry run (got $(jq_field "$OUT" dryRun))" FAIL
[ "$(jq_field "$OUT" matched)" = "1" ] && check "L31b the dry run names how many records it would destroy" PASS || check "L31b the dry run names the count (got $(jq_field "$OUT" matched))" FAIL

OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --forget "$SID_A" --apply --json --all)"
[ "$(jq_field "$OUT" removed)" = "1" ] && check "L31c --apply removes the records naming that session" PASS || check "L31c --apply removes the records naming that session (removed=$(jq_field "$OUT" removed))" FAIL
[ "$(edge_count)" = "1" ] && check "L31d and it removes only those -- the unrelated edge survives" PASS || check "L31d the unrelated edge survives (ledger holds $(edge_count), want 1)" FAIL
SURVIVOR="$(node -e '
const fs = require("fs"), path = require("path");
const dir = process.argv[1];
const files = fs.readdirSync(dir).filter((f) => f.endsWith(".json"));
if (files.length !== 1) { process.stdout.write(`FILES:${files.length}`); process.exit(0); }
process.stdout.write(JSON.parse(fs.readFileSync(path.join(dir, files[0]), "utf8")).from.sessionId);
' "$CFG/zensu/session-lineage/v1/edges")"
[ "$SURVIVOR" = "$SID_B" ] && check "L31e the survivor is the OTHER predecessor, not whichever record sorted last" PASS || check "L31e the survivor is the other predecessor (got $SURVIVOR)" FAIL

# A prefix that names two sessions must be refused: deletion cannot be undone, so
# resolving the ambiguity by picking one would destroy records the user never named.
SID_F="abcdef12-0000-0000-0000-000000000001"
SID_G="abcdef12-0000-0000-0000-000000000002"
fix "$SID_F" "$DEAD_PID" 90 forget "$ACCT_A" stalled
fix "$SID_G" "$DEAD_PID" 60 forget "$ACCT_B"
reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_F" --no-git --all >/dev/null
trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_G" --no-git --all >/dev/null
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --forget abcdef12 --apply --all)"
case "$OUT" in *ambiguous*) check "L31f an ambiguous --forget prefix is refused rather than resolved" PASS ;; *) check "L31f an ambiguous --forget prefix is refused (got ${OUT:-<empty>})" FAIL ;; esac
[ "$(edge_count)" = "2" ] && check "L31g and the refusal destroyed nothing" PASS || check "L31g the refusal destroyed nothing (ledger holds $(edge_count), want 2)" FAIL
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --forget abc --apply --all)"
case "$OUT" in *"at least 6"*) check "L31h a --forget prefix under the floor is refused, as --where's is" PASS ;; *) check "L31h a short --forget prefix is refused (got ${OUT:-<empty>})" FAIL ;; esac

# -- L32 -- label --remove -------------------------------------------------
# The set path existed from the start and the clear path did not, so a label typed
# into the wrong window stayed on the account forever. Namespace-aware, because
# `label` writes into two maps and a remove that swept both would clear an
# unrelated window whose pid happens to spell the same digits.
reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" label "$ACCT_A" "Keep Me" >/dev/null
trail "$STORE" "$SID_C" "$LIVE_PID" label "$ACCT_B" "Drop Me" >/dev/null
label_at() { # <namespace> <key>
  node -e '
const fs = require("fs");
try {
  const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const ns = (o[process.argv[2]] || {});
  const v = ns[process.argv[3]];
  process.stdout.write(v === undefined ? "ABSENT" : String(v));
} catch (e) { process.stdout.write("UNREADABLE"); }
' "$CFG/zensu/session-lineage/v1/labels.json" "$1" "$2"
}
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" label --remove "$ACCT_B" --json)"
[ "$(label_at accounts "$ACCT_B")" = "ABSENT" ] && check "L32 label --remove clears the entry it names" PASS || check "L32 label --remove clears the entry it names (got $(label_at accounts "$ACCT_B"))" FAIL
[ "$(label_at accounts "$ACCT_A")" = "Keep Me" ] && check "L32a and leaves every other label standing" PASS || check "L32a it leaves every other label standing (got $(label_at accounts "$ACCT_A"))" FAIL
[ "$(jq_field "$OUT" removed)" = "true" ] && check "L32b the removal is reported to a machine consumer" PASS || check "L32b the removal is reported (got $(jq_field "$OUT" removed))" FAIL

# A LIVE pid: the window namespace keys on the process incarnation (L35), so a
# number with no running process behind it cannot be labelled at all.
trail "$STORE" "$SID_C" "$LIVE_PID" label "$LIVE_PID" "A Window" >/dev/null
label_keys() { # <namespace>
  node -e '
const fs = require("fs");
try {
  const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  process.stdout.write(Object.keys(o[process.argv[2]] || {}).join(","));
} catch (e) { process.stdout.write("UNREADABLE"); }
' "$CFG/zensu/session-lineage/v1/labels.json" "$1"
}
window_keys() { label_keys windows; }
[ -n "$(window_keys)" ] && check "L32c-control a pid-shaped key lands in the window namespace" PASS || check "L32c-control a pid-shaped key lands in the window namespace (windows is empty)" FAIL
trail "$STORE" "$SID_C" "$LIVE_PID" label --remove "$LIVE_PID" >/dev/null
[ -z "$(window_keys)" ] && check "L32c label --remove reaches the window namespace too, not only accounts" PASS || check "L32c label --remove reaches the window namespace (windows holds $(window_keys))" FAIL

# Removing what is not there must not read as a removal that happened -- the
# operator would otherwise believe a label they can still see was cleared.
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" label --remove "$ACCT_C" --json)"
[ "$(jq_field "$OUT" removed)" = "false" ] && check "L32d removing an absent key reports that nothing was removed" PASS || check "L32d removing an absent key reports nothing removed (got $(jq_field "$OUT" removed))" FAIL

# -- L33 -- the label write lands through the merging updater ---------------
# Nothing behavioural can see this from a shell: the loss window needs two
# processes interleaving between the caller's read and its write, so it is pinned
# at source. updateLabels owns the whole read-modify-write; a caller that reads,
# merges and calls writeLabels itself reintroduces exactly the lost update the
# module gained updateLabels to close, and prints success while doing it.
LBL_SRC="$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs"
grep -q 'updateLabels(LABELS_FILE' "$LBL_SRC" && L33_USES=YES || L33_USES=NO
grep -q 'writeLabels(LABELS_FILE' "$LBL_SRC" && L33_RAW=YES || L33_RAW=NO
if [ "$L33_USES" = "YES" ] && [ "$L33_RAW" = "NO" ]; then
  check "L33 the label command lands through updateLabels, not a caller-side read-modify-write" PASS
else
  check "L33 the label command lands through updateLabels (updateLabels=$L33_USES rawWriteLabels=$L33_RAW)" FAIL
fi
L33_CTRL="$(mktemp -t zensu-l33-XXXXXX)"
printf '  writeLabels(LABELS_FILE, next, CONFIG_ROOT);\n' > "$L33_CTRL"
grep -q 'writeLabels(LABELS_FILE' "$L33_CTRL" && check "L33-control the raw-write scan matches a planted caller-side write" PASS || check "L33-control the raw-write scan matched nothing, so the absence above is vacuous" FAIL
rm -f "$L33_CTRL"
reset_ledger

# -- L34 -- one mode at a time, and --apply is not a mode ------------------
# cmdLineage dispatches on a first-match ladder, so `--diagnose --backfill` ran
# the diagnostic and discarded the backfill without a word. That was survivable
# while both modes only READ. --forget is not: paired with --apply it destroys
# records, and a ladder that silently drops it prints a diagnostic while the
# removal the user asked for never happened. The controls matter more than the
# refusals -- a check that refused every combination would satisfy the four
# assertions below and make the command unusable.
reset_ledger
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --diagnose --backfill --all)"
case "$OUT" in *"one mode at a time"*) check "L34 two mode flags are refused, not silently resolved to one" PASS ;; *) check "L34 two mode flags are refused (got ${OUT:-<empty>})" FAIL ;; esac
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --backfill --forget "$SID_A" --all)"
case "$OUT" in *"one mode at a time"*) check "L34a a read mode paired with the destructive one is refused" PASS ;; *) check "L34a a read mode paired with the destructive one is refused (got ${OUT:-<empty>})" FAIL ;; esac
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --where "$SID_A" --backfill --all)"
case "$OUT" in *"one mode at a time"*) check "L34b a query paired with a mode is refused rather than dropped" PASS ;; *) check "L34b a query paired with a mode is refused (got ${OUT:-<empty>})" FAIL ;; esac

# --apply is the flag that turns a dry run into a write. On a mode that has no
# dry run to turn it is swallowed, and hearing nothing back reads as "applied".
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --apply --all)"
case "$OUT" in *"--apply has no effect on its own"*) check "L34c --apply with no mode is refused, never ignored" PASS ;; *) check "L34c --apply with no mode is refused (got ${OUT:-<empty>})" FAIL ;; esac
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --diagnose --apply --all)"
case "$OUT" in *"--apply has no effect on its own"*) check "L34d --apply on a mode that never writes is refused too" PASS ;; *) check "L34d --apply on a read-only mode is refused (got ${OUT:-<empty>})" FAIL ;; esac

OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --diagnose --all)"
case "$OUT" in *LEDGER*) check "L34e-control --diagnose alone still runs -- the refusal is not unconditional" PASS ;; *) check "L34e-control --diagnose alone still runs (got ${OUT:-<empty>})" FAIL ;; esac
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --backfill --json --all)"
[ "$(jq_field "$OUT" dryRun)" = "true" ] && check "L34f-control --backfill alone still runs its dry run" PASS || check "L34f-control --backfill alone still runs (got $(jq_field "$OUT" dryRun))" FAIL
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --forget "$SID_A" --json --all)"
[ "$(jq_field "$OUT" dryRun)" = "true" ] && check "L34g-control --forget alone still runs its dry run" PASS || check "L34g-control --forget alone still runs (got $(jq_field "$OUT" dryRun))" FAIL

# -- L35 -- a window label names an INCARNATION, not a reusable number -----
# An OS pid is reused the moment its process exits, so a label keyed by the bare
# number silently renames whatever window inherits it next -- and it renders with
# exactly the confidence a correct one gets. The key is qualified with the
# process's start time, read from the same table windowOf already builds. The
# fail direction is deliberate: a key that no longer matches a running process
# stops resolving, rather than resolving to the wrong window.
reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" label "$LIVE_PID" "That Window" >/dev/null
W_KEYS="$(label_keys windows)"
case "$W_KEYS" in
  "$LIVE_PID@"*) check "L35 a window label is keyed by pid AND start time, so a reused pid inherits nothing" PASS ;;
  *) check "L35 a window label is keyed by pid and start time (got ${W_KEYS:-<empty>})" FAIL ;;
esac
[ "$W_KEYS" = "$LIVE_PID" ] && check "L35a the bare pid is not the key -- the qualification is real" FAIL || check "L35a the bare pid is not the key -- the qualification is real" PASS

# A pid with no running process cannot be qualified, and inventing a key for it
# would put the label straight back into the reuse hazard. The value is DERIVED
# rather than hardcoded: the comment here used to name pid 2 while the check used
# 999999, and a Linux host with a raised `kernel.pid_max` can have a live 999999 --
# which would resolve, and the refusal would never fire.
DEAD_LABEL_PID="$(node -e '
let p = 4194304;
for (let i = 0; i < 64; i += 1, p -= 1) {
  try { process.kill(p, 0); } catch (e) { if (e && e.code === "ESRCH") { process.stdout.write(String(p)); process.exit(0); } }
}
process.stdout.write("");
')"
[ -n "$DEAD_LABEL_PID" ] && check "L35b-control an unused pid was found to test the refusal with" PASS || check "L35b-control no unused pid could be found, so the refusal below is untested" FAIL
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" label "$DEAD_LABEL_PID" "Ghost")"
case "$OUT" in *"$DEAD_LABEL_PID"*) L35B_NAMES=YES ;; *) L35B_NAMES=NO ;; esac
case "$OUT" in *"no running process"*) L35B_SAYS=YES ;; *) L35B_SAYS=NO ;; esac
{ [ "$L35B_NAMES" = YES ] && [ "$L35B_SAYS" = YES ]; } && check "L35b labelling a pid with no running process is refused, and the refusal names it" PASS || check "L35b labelling a dead pid is refused (got ${OUT:-<empty>})" FAIL

# --remove takes the BARE pid, because that is what the operator has: the
# qualification is machine state they never typed and cannot reconstruct once the
# window is gone. Every incarnation recorded under that pid goes.
trail "$STORE" "$SID_C" "$LIVE_PID" label --remove "$LIVE_PID" >/dev/null
[ -z "$(label_keys windows)" ] && check "L35c --remove takes the bare pid and clears every incarnation recorded under it" PASS || check "L35c --remove clears the qualified key (windows still holds $(label_keys windows))" FAIL

# The read half cannot be driven from here: rendering a window label needs a live
# process whose ancestor names Claude, which a sandbox cannot fabricate. Pinned at
# source instead, with a control -- a scan that matched nothing would pass for the
# wrong reason.
WL_SRC="$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs"
WL_BODY="$(awk '/^function windowLabel\(/{f=1} f{print} f&&/^\}/{exit}' "$WL_SRC")"
case "$WL_BODY" in *windowKey*) L35D_USES=YES ;; *) L35D_USES=NO ;; esac
case "$WL_BODY" in *'String(appPid)'*|*'[appPid]'*) L35D_BARE=YES ;; *) L35D_BARE=NO ;; esac
{ [ "$L35D_USES" = YES ] && [ "$L35D_BARE" = NO ]; } && check "L35d the reader resolves the qualified key and keeps no bare-pid fallback" PASS || check "L35d the reader resolves the qualified key (windowKey=$L35D_USES barePidLookup=$L35D_BARE)" FAIL
[ -n "$WL_BODY" ] && check "L35d-control the windowLabel body was actually extracted" PASS || check "L35d-control the windowLabel body was not found, so the scan above is vacuous" FAIL
# The extraction control above proves awk found SOMETHING; it says nothing about
# whether the needle can bite. A negative with only an extraction control reports a
# clean body for a reintroduced fallback spelled any other way. Both bare-pid
# spellings a reader would actually write are planted here.
L35D_CTRL="$(printf 'function windowLabel(appPid) {\n  const l = w[String(appPid)];\n}\n')"
case "$L35D_CTRL" in *'String(appPid)'*) check "L35d-control the bare-pid needle bites a planted lookup" PASS ;; *) check "L35d-control the bare-pid needle matched nothing, so L35d is vacuous" FAIL ;; esac
# And the OTHER spelling, which the needle deliberately does not cover: recorded as
# a known bound of this pin rather than left to be discovered as a false clean.
L35D_ALT="$(printf 'const l = w[appPid];\n')"
case "$L35D_ALT" in *'String(appPid)'*|*'[appPid]'*) check "L35d-bound the needle also covers an unwrapped w[appPid] lookup" PASS ;; *) check "L35d-bound the needle misses the unwrapped w[appPid] spelling, so L35d reports clean for a reintroduced fallback" FAIL ;; esac
reset_ledger

# -- L36 -- the record cap reaches the operator ----------------------------
# readEdges bounds how many records it enumerates and returns `truncated` saying
# so. ledgerRead dropped that field on the floor, so a ledger past the cap
# answered from a prefix and rendered exactly like a complete one -- the silent
# truncation the module-level bound was added to make visible. The unit suite
# proves the flag is COMPUTED (it plants MAX_EDGE_RECORDS + 5 records); these
# checks prove it TRAVELS, which no module test can see.
reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_A" --no-git --all >/dev/null
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --json --all)"
[ "$(jq_field "$OUT" ledgerTruncated)" = "false" ] && check "L36 the lineage payload carries the record-cap flag" PASS || check "L36 the lineage payload carries the record-cap flag (got $(jq_field "$OUT" ledgerTruncated))" FAIL
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --diagnose --json --all)"
[ "$(jq_field "$OUT" ledgerTruncated)" = "false" ] && check "L36a --diagnose carries it too -- it is the command an operator runs when counts look wrong" PASS || check "L36a --diagnose carries the record-cap flag (got $(jq_field "$OUT" ledgerTruncated))" FAIL

# Structural, because a payload added later cannot be caught behaviourally: every
# payload that reports the ledger's other two failure signals must report this one.
# Anchored on ledgerError, which is the field that marks a payload as ledger-aware.
LG_SRC="$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs"
LG_ERR="$(grep -c 'ledgerError:' "$LG_SRC")"
LG_TRUNC="$(grep -c 'ledgerTruncated:' "$LG_SRC")"
[ "$LG_ERR" -ge 5 ] && check "L36b-control the ledger-aware payload anchor still matches ($LG_ERR sites)" PASS || check "L36b-control the ledgerError anchor matched $LG_ERR sites, so the count below is vacuous" FAIL
# CO-OCCURRENCE, not two independent line counts: every current carrier happens to
# put both fields on one line, so the two counts moved together by construction and
# a payload emitting one without the other could still balance the totals.
LG_BOTH="$(grep -c 'ledgerTruncated:.*ledgerError:\|ledgerError:.*ledgerTruncated:' "$LG_SRC")"
[ "$LG_BOTH" = "$LG_ERR" ] && check "L36b every ledger-aware payload reports the record cap on the same payload, not only in the same file" PASS || check "L36b every ledger-aware payload reports the record cap ($LG_BOTH of $LG_ERR carry both)" FAIL

# And the refactor this step is named for: the read returns its own status rather
# than assigning module-scope globals a later reader might see stale.
grep -q 'let LEDGER_DIR_ERROR' "$LG_SRC" && check "L36c ledgerRead no longer publishes its status through module globals" FAIL || check "L36c ledgerRead no longer publishes its status through module globals" PASS
reset_ledger

# -- L37 -- the window ancestor is matched on the program, not the path ----
# `ps -o comm=` yields the full executable PATH on macOS, so /claude/i against the
# whole string matches any ancestor that merely LIVES under a claude-named
# directory -- ~/claude-tools/bin/watcher, or a checkout of this very plugin. The
# session is then grouped under a window that is not one, and the grouping is the
# fallback that exists precisely for when the desktop store is unreachable.
#
# NOT driven behaviourally, and the reason is worth stating: reaching windowOf
# needs a real ancestor process whose executable path contains "claude" and whose
# basename does not, which means planting an executable and a two-level process
# tree that would have to be skipped on Windows. Pinned at source with a control.
WO_SRC="$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs"
WO_BODY="$(awk '/^function windowOf\(/{f=1} f{print} f&&/^\}/{exit}' "$WO_SRC")"
[ -n "$WO_BODY" ] && check "L37-control the windowOf body was actually extracted" PASS || check "L37-control the windowOf body was not found, so the scan below is vacuous" FAIL
case "$WO_BODY" in *"path.basename(next.comm)"*) L37_BASE=YES ;; *) L37_BASE=NO ;; esac
case "$WO_BODY" in *"test(next.comm)"*) L37_WHOLE=YES ;; *) L37_WHOLE=NO ;; esac
{ [ "$L37_BASE" = YES ] && [ "$L37_WHOLE" = NO ]; } && check "L37 the ancestor match reads the program name, not the whole path" PASS || check "L37 the ancestor match reads the program name (basename=$L37_BASE wholePath=$L37_WHOLE)" FAIL
# The planted control the extraction check is not: a scan that cannot match reports
# a clean body for the very regression it exists to catch.
L37_CTRL="$(printf 'if (/claude/i.test(next.comm)) found = cur.ppid;\n')"
case "$L37_CTRL" in *"test(next.comm)"*) check "L37-control the whole-path needle bites a planted match" PASS ;; *) check "L37-control the whole-path needle matched nothing, so L37 is vacuous" FAIL ;; esac

# -- L38 -- the backfill filter is described once, by the paragraph that is true
# Two comment paragraphs sat above the successor filter and they contradicted each
# other: the first claimed "a successor whose start precedes the stall is skipped
# outright", which was a guard the code no longer has. A reader auditing whether a
# guessed edge can invert causality read the first one and stopped. A comment is
# not testable, so this is a source pin -- but a stale claim about a SAFETY guard
# is exactly the kind that gets believed.
BF_SRC="$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs"
grep -q 'A successor whose start precedes the stall is skipped outright' "$BF_SRC" \
  && check "L38 the retired start-guard claim is gone from the backfill filter" FAIL \
  || check "L38 the retired start-guard claim is gone from the backfill filter" PASS
# The survivor must still be there: deleting both would leave the real filter -- the
# one whose start claim is deliberately NOT established -- undescribed.
grep -q 'is NOT established for finished sessions' "$BF_SRC" \
  && check "L38a-control the paragraph that describes the real filter survives" PASS \
  || check "L38a-control the paragraph that describes the real filter survives" FAIL

# -- L39 -- the MSYS drive rule is shared, not re-spelled ------------------
# Under Git Bash a root handed in as `/d/work` reaches this script unconverted,
# and path.resolve reads that leading slash as drive-RELATIVE: the whole POSIX
# path is spliced under the current drive and the ledger is written somewhere
# nobody reads back. hooks/lib/claude-path-v1.js owns the one MSYS drive rule in
# this repo; a private copy here is exactly the drift CLAUDE.md records that rule
# to prevent. No behavioural check on a POSIX host can see any of this -- the
# function is identity off win32 -- so the three call sites are pinned at source
# and the module's reachability is proven by actually loading it.
PR_SRC="$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs"
PR_LOAD="$(node -e '
const { createRequire } = require("node:module");
const r = createRequire(process.argv[1]);
const m = r("../../../hooks/lib/claude-path-v1.js");
process.stdout.write(typeof m.msysDrivePrefix === "function" ? "OK" : "MISSING");
' "$PR_SRC" 2>&1)"
[ "$PR_LOAD" = "OK" ] && check "L39-control the shared path module resolves from the script's own directory" PASS || check "L39-control the shared path module resolves from the script's directory (got $PR_LOAD)" FAIL
# By NAME, not by count. A bare count catches a removal but not a substitution: a
# fourth externally supplied root added WITHOUT the normaliser holds the count at
# three, and moving normalisation off one carrier onto another holds it too. The
# count is kept as a secondary bound, using -o so two calls on one line still count
# as two.
# Scoped to the enclosing FUNCTION, not to a single line: two of the three read
# their variable one line above the resolve, so a line-scoped match found only the
# one that happens to name its carrier inline.
fn_body() { awk -v f="$2" '$0 ~ ("^function " f "\\(") {inside=1} inside {print} inside && /^\}/ {exit}' "$1"; }
PR_BY_NAME=0
for pair in 'defaultConfigRoot:CLAUDE_CONFIG_DIR' 'resolveRoots:configDir.trim()' 'ccdStoreCandidates:ZENSU_CCD_STORE'; do
  fn="${pair%%:*}"; carrier="${pair#*:}"
  body="$(fn_body "$PR_SRC" "$fn")"
  case "$body" in
    *"$carrier"*) case "$body" in *'path.resolve(hostPath('*) PR_BY_NAME=$((PR_BY_NAME+1)) ;; esac ;;
  esac
done
[ "$PR_BY_NAME" = "3" ] && check "L39 each of the three externally supplied roots is normalised inside the function that reads it" PASS || check "L39 each of the three roots is normalised by name (got $PR_BY_NAME of 3)" FAIL
PR_HOSTED="$(grep -o 'path.resolve(hostPath(' "$PR_SRC" | grep -c .)"
[ "$PR_HOSTED" = "3" ] && check "L39-bound and there are exactly three such sites, so a fourth root cannot be added unnormalised in silence" PASS || check "L39-bound exactly three normalised sites (got $PR_HOSTED)" FAIL
# `[[:space:]]`, not `\s`: this is a plain BRE grep, where `\s` is a GNU extension.
# The first spelling of this rule used it, so on a BSD host the scan could not match
# and reported a clean file for the wrong reason -- the same trap this suite's own
# language guard fell into one round earlier.
grep -q 'msysDrive[[:space:]]*=[[:space:]]*/\^' "$PR_SRC" && check "L39a no private copy of the drive rule reappears in this script" FAIL || check "L39a no private copy of the drive rule reappears in this script" PASS
L39A_CTRL="$(mktemp -t zensu-l39a-XXXXXX)"
printf 'const msysDrive = /^\\/([A-Za-z])(\\/|$)/;\n' > "$L39A_CTRL"
grep -q 'msysDrive[[:space:]]*=[[:space:]]*/\^' "$L39A_CTRL" && check "L39a-control the private-copy needle bites a planted rule" PASS || check "L39a-control the private-copy needle matched nothing, so L39a is vacuous" FAIL
rm -f "$L39A_CTRL"

# -- L40 -- a ledger under another schema directory is a MIGRATION ---------
# The store lives under `session-lineage/v<schema>/`, so the day the schema moves,
# every existing record becomes invisible to the new build. The empty-ledger branch
# then printed "No handover has been recorded yet" and offered `lineage --backfill`
# -- which would mint GUESSES for handovers the machine already held as
# MEASUREMENTS, one directory away. That is the worst outcome the confidence axis
# exists to prevent, reached by a command the tool itself recommends.
reset_ledger
mkdir -p "$CFG/zensu/session-lineage/v0/edges"
printf '{"schemaVersion":0,"from":{"sessionId":"a"},"to":{"sessionId":"b"}}' > "$CFG/zensu/session-lineage/v0/edges/1-aaaaaaaaaaaaaaaa.json"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --all)"
case "$OUT" in *"No handover has been recorded yet"*) check "L40 an empty current ledger beside a populated older one no longer reads as no history" FAIL ;; *) check "L40 an empty current ledger beside a populated older one no longer reads as no history" PASS ;; esac
case "$OUT" in *"--backfill"*) check "L40a and it does not offer to reconstruct guesses for records the machine already holds" FAIL ;; *) check "L40a and it does not offer to reconstruct guesses for records the machine already holds" PASS ;; esac
case "$OUT" in *v0*) check "L40b the older schema directory is named, so the operator can find it" PASS ;; *) check "L40b the older schema directory is named (got ${OUT:-<empty>})" FAIL ;; esac
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --json --all)"
[ "$(jq_field "$OUT" otherSchemaLedgers)" != "ABSENT" ] && [ "$(jq_field "$OUT" otherSchemaLedgers)" != "[]" ] && check "L40c the machine channel reports it too, not only the rendered text" PASS || check "L40c the machine channel reports it too (got $(jq_field "$OUT" otherSchemaLedgers))" FAIL

# The control that keeps every assertion above honest: with no foreign directory
# the ordinary empty-ledger guidance must come back, offer and all. A branch that
# fired unconditionally would satisfy L40/L40a and silently retire the one message
# a first-time user is meant to see.
rm -rf "$CFG/zensu/session-lineage/v0"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --all)"
case "$OUT" in *"No handover has been recorded yet"*) check "L40d-control a genuinely empty store still says so and still offers the reconstruction" PASS ;; *) check "L40d-control a genuinely empty store still says so (got ${OUT:-<empty>})" FAIL ;; esac

# An EMPTY foreign directory is not a migration: reporting one would send the
# operator hunting for records that were never written.
mkdir -p "$CFG/zensu/session-lineage/v0/edges"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --all)"
case "$OUT" in *"No handover has been recorded yet"*) check "L40e an empty foreign schema directory is not reported as a migration" PASS ;; *) check "L40e an empty foreign schema directory is not reported as a migration (got ${OUT:-<empty>})" FAIL ;; esac
rm -rf "$CFG/zensu/session-lineage/v0"
reset_ledger

# -- L41 -- the coverage tooling for these scripts ------------------------
# The coverage number is the evidence the plan's 90% target is measured against,
# so the command that produces it is part of the contract. Three defects, all
# invisible while it happened to work on one developer's machine: a caret range on
# c8 lets a minor release change what "90%" means between two runs of the same
# tree; the run covered ONE of the three suites that exercise these scripts, so
# every branch only the verdict and skill suites reach counted as uncovered; and
# the single-quoted --include is not a quote to cmd.exe, which passes the quotes
# INTO the glob and matches nothing at all on Windows.
PKG="$PLUGIN_DIR/package.json"
C8_RANGE="$(node -p 'require(process.argv[1]).devDependencies.c8' "$PKG" 2>/dev/null)"
case "$C8_RANGE" in [0-9]*.[0-9]*.[0-9]*) check "L41 c8 is pinned exactly ($C8_RANGE), as promptfoo and yaml already are" PASS ;; *) check "L41 c8 is pinned exactly (got ${C8_RANGE:-<absent>})" FAIL ;; esac
COV="$(node -p 'require(process.argv[1]).scripts["session-trail:coverage"] || ""' "$PKG" 2>/dev/null)"
# Resolved through whatever the script actually invokes, because the command that
# drives the suites is a FILE: npm hands its script to `sh -c` on POSIX and to
# cmd.exe on Windows, and no inline quoting form survives both -- the double-quoted
# one reached c8 as a single filename it then tried to open. Reading the referenced
# script keeps this check about WHICH SUITES RUN rather than about how they are
# spelled, so moving them behind a driver does not silently retire it.
COV_TEXT="$COV"
for ref in $(printf '%s' "$COV" | tr ' ' '\n' | grep -o 'tests/structure/[A-Za-z0-9._-]*\.sh'); do
  [ -f "$PLUGIN_DIR/$ref" ] && COV_TEXT="$COV_TEXT
$(cat "$PLUGIN_DIR/$ref")"
done
# Comment lines are stripped first. The driver explains ITSELF by naming this very
# file, which supplied the `lineage` arm on its own -- so dropping that suite from
# the driver would have left this check green. Count what RUNS, not what is
# mentioned.
COV_CODE="$(printf '%s\n' "$COV_TEXT" | grep -v '^[[:space:]]*#')"
COV_SUITES=0
for suite in lineage verdict skill; do
  case "$COV_CODE" in *"test-session-trail-$suite.sh"*) COV_SUITES=$((COV_SUITES+1)) ;; esac
done
# The control: with comments stripped the driver must still name all three, and the
# stripping must actually have removed something -- otherwise this is the old check.
[ "${#COV_CODE}" -lt "${#COV_TEXT}" ] && check "L41a-strip the comment stripping removed something, so the count above is about code" PASS || check "L41a-strip the comment stripping removed nothing, so the count is still satisfiable by prose" FAIL
[ "$COV_SUITES" = "3" ] && check "L41a the coverage run drives all three suites that exercise these scripts" PASS || check "L41a the coverage run drives all three suites (got $COV_SUITES of 3)" FAIL
# The resolution must have actually happened: if the referenced driver were
# unreadable, COV_TEXT would collapse back to the npm script and the count above
# would silently measure the wrong thing.
case "$COV" in *run-session-trail-coverage.sh*) [ "${#COV_TEXT}" -gt "${#COV}" ] && check "L41a-control the referenced driver was read, not silently skipped" PASS || check "L41a-control the referenced driver was not read, so the count above is about the npm script alone" FAIL ;; *) check "L41a-control the coverage script names its suites inline, so no resolution was needed" PASS ;; esac
case "$COV" in *"--include='"*) check "L41b the include glob survives cmd.exe -- single quotes there are literal characters, not quotes" FAIL ;; *) check "L41b the include glob survives cmd.exe -- single quotes there are literal characters, not quotes" PASS ;; esac
case "$COV" in *'--include='*) check "L41c-control the coverage script still names an include glob at all" PASS ;; *) check "L41c-control the coverage script still names an include glob (got ${COV:-<empty>})" FAIL ;; esac

# -- L42 -- the destructive verbs on a store they could not read -----------
# Coverage for the branches this change ADDED, and they are the ones that matter
# most: both say "I could not look" rather than "there is nothing there". A
# removal that reported success against a failed read would tell the operator a
# record is gone while it is still on disk, asserting a handover they retracted.
reset_ledger
mkdir -p "$CFG/zensu/session-lineage/v1"
printf 'x' > "$CFG/zensu/session-lineage/v1/edges"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --forget "$SID_A" --apply --json --all)"
[ "$(jq_field "$OUT" refusal)" = "ledger-unreadable" ] && check "L42 --forget on an unreadable ledger refuses and names the cause" PASS || check "L42 --forget on an unreadable ledger refuses (refusal=$(jq_field "$OUT" refusal))" FAIL
[ "$(jq_field "$OUT" removed)" = "0" ] && check "L42a and it claims no removal it did not make" PASS || check "L42a it claims no removal it did not make (removed=$(jq_field "$OUT" removed))" FAIL
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --forget "$SID_A" --apply --all)"
case "$OUT" in *"NOT evidence that no record names that session"*) check "L42b the text channel refuses to read absence out of a failed read" PASS ;; *) check "L42b the text channel refuses to read absence out of a failed read (got ${OUT:-<empty>})" FAIL ;; esac
rm -f "$CFG/zensu/session-lineage/v1/edges"

# The labels half: a file this build cannot parse reduces to an EMPTY map on read,
# so a removal written on top of it would replace every label on the machine with
# the caller's one edit. Refused, exactly as the set path is.
reset_ledger
mkdir -p "$CFG/zensu/session-lineage/v1"
printf 'not json at all' > "$CFG/zensu/session-lineage/v1/labels.json"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" label --remove "$ACCT_A")"
case "$OUT" in *"refusing to overwrite it"*) check "L42c label --remove refuses an unreadable labels file instead of replacing it" PASS ;; *) check "L42c label --remove refuses an unreadable labels file (got ${OUT:-<empty>})" FAIL ;; esac
printf '{"schemaVersion":99,"accounts":{},"windows":{}}' > "$CFG/zensu/session-lineage/v1/labels.json"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" label --remove "$ACCT_A")"
case "$OUT" in *"different label schema"*) check "L42d and a labels file from another schema, which reads as empty for the same reason" PASS ;; *) check "L42d a labels file from another schema is refused (got ${OUT:-<empty>})" FAIL ;; esac
rm -f "$CFG/zensu/session-lineage/v1/labels.json"
reset_ledger

# -- L43 -- what a destructive verb SHOWS before and after it destroys -----
# The dry run is the whole safety surface of --forget: an operator decides from
# what it prints. Every earlier check drove the JSON channel, so the rendered
# text -- the only channel a person reads -- was unexercised.
reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_A" --no-git --all >/dev/null
trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_B" --no-git --all >/dev/null
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --forget "$SID_A" --all)"
case "$TXT" in *"FORGET (dry run)"*) check "L43 the text dry run announces itself as one" PASS ;; *) check "L43 the text dry run announces itself (got ${TXT:-<empty>})" FAIL ;; esac
case "$TXT" in *"cannot be undone"*) check "L43a it states that the removal is machine-wide and final before asking for --apply" PASS ;; *) check "L43a it states the removal is final" FAIL ;; esac
[ "$(edge_count)" = "2" ] && check "L43b and the text dry run removed nothing, like the --json one" PASS || check "L43b the text dry run removed nothing (ledger holds $(edge_count) of 2)" FAIL

TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --forget "$SID_A" --apply --all)"
case "$TXT" in *"FORGET APPLIED"*) check "L43c the applied run says so" PASS ;; *) check "L43c the applied run says so (got ${TXT:-<empty>})" FAIL ;; esac
case "$TXT" in *"  removed "*) check "L43d and names each record it removed, not only how many" PASS ;; *) check "L43d it names each record removed" FAIL ;; esac
[ "$(edge_count)" = "1" ] && check "L43e-control the text apply really did remove one, so the lines above are not decoration" PASS || check "L43e-control the text apply removed one (ledger holds $(edge_count) of 1)" FAIL

# A record the reader refused is a record --forget cannot see, so the count it
# prints is not "all of them". Disclosed rather than blocking: what it DID see is
# still removed correctly.
reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_A" --no-git --all >/dev/null
printf 'not json' > "$CFG/zensu/session-lineage/v1/edges/1-deadbeefdeadbeef.json"
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --forget "$SID_A" --all)"
case "$TXT" in *"were not examined"*) check "L43f an unreadable record is disclosed beside the count, which is therefore not a total" PASS ;; *) check "L43f an unreadable record is disclosed beside the count (got ${TXT:-<empty>})" FAIL ;; esac
reset_ledger

# -- L44 -- the plain-text channels AC-028 named ---------------------------
# Four surfaces the suite drove only through --json, or not at all. A person reads
# the text; --json is what a script reads. A branch exercised on one channel only
# is a branch that renders unverified prose to the operator.
reset_ledger
cyc 1 "$SID_A" "$SID_B"
cyc 2 "$SID_A" "$SID_C"
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --all)"
case "$TXT" in *"was taken over more than once"*) check "L44 the fork warning reaches the rendered chain, not only the --json payload" PASS ;; *) check "L44 the fork warning reaches the rendered chain (got ${TXT:-<empty>})" FAIL ;; esac

# --where, in the three shapes a person can land in.
reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_A" --no-git --all >/dev/null
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --where "$SID_A" --all)"
case "$TXT" in *"CONTINUED IN"*) check "L44a --where answers in plain text where a session went" PASS ;; *) check "L44a --where answers in plain text (got ${TXT:-<empty>})" FAIL ;; esac
case "$TXT" in *WORKTREE*) check "L44b and names the worktree, which is what makes the answer actionable" PASS ;; *) check "L44b --where names the worktree" FAIL ;; esac
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --where "ffffffff-0000-0000-0000-00000000000f" --all)"
case "$TXT" in *"No lineage recorded"*) check "L44c an unknown session is reported as unrecorded, not as an end of chain" PASS ;; *) check "L44c an unknown session is reported as unrecorded (got ${TXT:-<empty>})" FAIL ;; esac

# Ambiguity exits 2, and the exit STATUS is the half a caller acts on -- the text
# alone would let a script treat a refusal as an answer.
reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_F" --no-git --all >/dev/null
trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_G" --no-git --all >/dev/null
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --where abcdef12 --all)"; WHERE_RC=$?
case "$TXT" in *"ambiguous --where"*) check "L44d an ambiguous --where lists its candidates instead of picking one" PASS ;; *) check "L44d an ambiguous --where lists its candidates (got ${TXT:-<empty>})" FAIL ;; esac
[ "$WHERE_RC" = "2" ] && check "L44e and exits 2, so a caller can tell a refusal from an answer" PASS || check "L44e an ambiguous --where exits 2 (got $WHERE_RC)" FAIL

# adopt is the CONFIRMATION verb, so its two refusals decide whether a confirmed
# edge -- the top of the confidence order -- can be minted at all.
reset_ledger
OUT="$(trail "$STORE" "$SID_A" "$LIVE_PID" adopt "$SID_A" --no-git --all)"
case "$OUT" in *"its own continuation"*) check "L44f adopt refuses to record a session as its own continuation" PASS ;; *) check "L44f adopt refuses a self-adoption (got ${OUT:-<empty>})" FAIL ;; esac
[ "$(edge_count)" = "0" ] && check "L44g and the refusal wrote nothing" PASS || check "L44g the refused self-adoption wrote nothing (got $(edge_count))" FAIL
# An EMPTY session id rather than an unset one, deliberately: selfIdentity()
# reduces both to null, and a second `env -u` here would not match the isolation
# scan's literal at the end of this file -- it would have read as a SECOND
# CLAUDE_CONFIG_DIR exemption and failed L28 for a reason unrelated to isolation.
OUT="$(trail "$STORE" "" "$LIVE_PID" adopt "$SID_A" --no-git --all)"
case "$OUT" in *"no CLAUDE_CODE_SESSION_ID"*) check "L44h without a session id of its own, adopt refuses rather than inventing an endpoint" PASS ;; *) check "L44h adopt refuses without a session id (got ${OUT:-<empty>})" FAIL ;; esac
[ "$(edge_count)" = "0" ] && check "L44i-control neither refusal left a record behind" PASS || check "L44i-control a refusal left a record behind (got $(edge_count))" FAIL
reset_ledger

# The ledger holding a record from a NEWER schema must not read as an empty
# history either -- same failure, one directory closer than L40's.
reset_ledger
mkdir -p "$CFG/zensu/session-lineage/v1/edges"
printf '{"schemaVersion":99,"from":{"sessionId":"a"},"to":{"sessionId":"b"}}' > "$CFG/zensu/session-lineage/v1/edges/1-deadbeefdeadbee9.json"
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --all)"
case "$TXT" in *"NEWER schema"*) check "L44j a record from a newer schema is reported, not counted as no history" PASS ;; *) check "L44j a newer-schema record is reported (got ${TXT:-<empty>})" FAIL ;; esac
reset_ledger

# -- L45 -- --forget with nothing to forget --------------------------------
# A dry run that matched nothing still printed "Re-run with --apply to remove
# them", pointing the operator at a destructive command that would do nothing.
# Found by running the verb rather than by a check -- worth its own case because
# the offer is the one line of this output that carries a consequence.
reset_ledger
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --forget "ffffffff-0000-0000-0000-00000000000f" --all)"
case "$OUT" in *"--apply"*) check "L45 a dry run that matched nothing does not offer the destructive re-run" FAIL ;; *) check "L45 a dry run that matched nothing does not offer the destructive re-run" PASS ;; esac
case "$OUT" in *"No record names"*) check "L45a and it says plainly that nothing names that session" PASS ;; *) check "L45a it says plainly that nothing names that session (got ${OUT:-<empty>})" FAIL ;; esac
# The control: a dry run that DID match must still carry the offer, or the fix
# above would simply have deleted the instruction the verb needs.
trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_A" --no-git --all >/dev/null
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --forget "$SID_A" --all)"
case "$OUT" in *"--apply"*) check "L45b-control a dry run that matched something still offers the re-run" PASS ;; *) check "L45b-control a dry run that matched something still offers the re-run" FAIL ;; esac
reset_ledger

# -- L46 -- a plugin tree missing its shared lib says so, and does not crash ---
# hostPath is reached from resolveRoots, which ran at MODULE LOAD. fail() calls
# flush(), flush() calls skippedNote(), and skippedNote() reads two module-scope
# `let`s declared BELOW that call — so the carefully worded "the plugin tree is
# incomplete" message was replaced by `ReferenceError: Cannot access 'SKIPPED'
# before initialization`, on exactly the path it exists for. Found by the review
# panel and reproduced before the fix. The eager call is redundant: the dispatcher
# re-resolves every root before any command runs, and nothing at module scope
# between the two reads them.
TDZ_TREE="$(mktemp -d -t zensu-tdz-XXXXXX)"
mkdir -p "$TDZ_TREE/skills/session-trail/scripts"
cp "$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs" "$PLUGIN_DIR/skills/session-trail/scripts/session-lineage-v1.mjs" "$TDZ_TREE/skills/session-trail/scripts/" 2>/dev/null
TDZ_OUT="$( CLAUDE_CONFIG_DIR="$TDZ_TREE/cfg" HOME="$TDZ_TREE" USERPROFILE="$TDZ_TREE" node "$TDZ_TREE/skills/session-trail/scripts/trail.mjs" lineage --all 2>&1 )"
case "$TDZ_OUT" in *ReferenceError*) check "L46 a tree without hooks/lib does not crash before its own diagnostic" FAIL ;; *) check "L46 a tree without hooks/lib does not crash before its own diagnostic" PASS ;; esac
case "$TDZ_OUT" in *"plugin tree is incomplete"*) check "L46a and the authored diagnostic is what the user actually sees" PASS ;; *) check "L46a the authored diagnostic is what the user sees (got ${TDZ_OUT:-<empty>})" FAIL ;; esac
# The control: with the shared module reachable the same invocation must still
# work, or the two checks above would be satisfied by a build that never resolves
# a root at all.
TDZ_OK="$( CLAUDE_CONFIG_DIR="$TDZ_TREE/cfg2" HOME="$TDZ_TREE" USERPROFILE="$TDZ_TREE" node "$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs" lineage --all 2>&1 )"
case "$TDZ_OK" in *"No handover has been recorded yet"*) check "L46b-control the same invocation from the real tree still resolves its roots" PASS ;; *) check "L46b-control the same invocation from the real tree still works (got ${TDZ_OK:-<empty>})" FAIL ;; esac
rm -rf "$TDZ_TREE"

# -- L47 -- the tier reaches the instances view too -------------------------
# SKILL.md states the tier is annotated in EVERY rendering, and names `instances`
# as the machine-wide answer a window with no quota is told to run. That view
# annotated the legacy `inferred` boolean only, so a `provisional` edge -- a brief
# that was generated and never confirmed -- rendered there as a completed handover.
# Raised by the review panel; the earlier tier work reached printChain and stopped.
reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_A" --no-git --all >/dev/null
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" instances --json)"
INST_MARKED="$(node -e '
let o; try { o = JSON.parse(process.argv[1]); } catch { process.stdout.write("PARSE_ERROR"); process.exit(0); }
const lines = (o.rows || []).flatMap((r) => r.lineage || []);
if (!lines.length) { process.stdout.write("NO_LINEAGE"); process.exit(0); }
process.stdout.write(lines.some((l) => l.includes("unconfirmed")) ? "MARKED" : `UNMARKED:${lines[0]}`);
' "$OUT")"
[ "$INST_MARKED" = "MARKED" ] && check "L47 a provisional edge is marked in the instances view, not only in the rendered chain" PASS || check "L47 a provisional edge is marked in instances (got $INST_MARKED)" FAIL
# The control: a confirmed edge must stay unmarked there, or the annotation stops
# meaning anything.
reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" adopt "$SID_B" --all >/dev/null
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" instances --json)"
INST_CLEAN="$(node -e '
let o; try { o = JSON.parse(process.argv[1]); } catch { process.stdout.write("PARSE_ERROR"); process.exit(0); }
const lines = (o.rows || []).flatMap((r) => r.lineage || []);
if (!lines.length) { process.stdout.write("NO_LINEAGE"); process.exit(0); }
process.stdout.write(lines.some((l) => l.includes("unconfirmed")) ? `MARKED:${lines[0]}` : "CLEAN");
' "$OUT")"
[ "$INST_CLEAN" = "CLEAN" ] && check "L47a-control a confirmed edge is NOT marked there, so the marker keeps its meaning" PASS || check "L47a-control a confirmed edge is not marked (got $INST_CLEAN)" FAIL

# -- L48 -- a chain that came back is not reported as an ordinary end -------
# walkChain computes `revisited` for the documented reset flow -- adopt A>B, then
# adopt B>A from the original window -- and nothing read it, so `--where` still
# printed CONTINUED IN with no caveat while the newest edge said the work had come
# back. The fix landed in the module and never in the consumer.
reset_ledger
cyc 1 "$SID_A" "$SID_B"
cyc 2 "$SID_B" "$SID_A"
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --where "$SID_A" --all)"
case "$TXT" in *"came back"*) check "L48 a revisited chain says so instead of reading as an ordinary continuation" PASS ;; *) check "L48 a revisited chain says so (got ${TXT:-<empty>})" FAIL ;; esac
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --where "$SID_A" --json --all)"
[ "$(jq_field "$OUT" revisited)" = "true" ] && check "L48a and the machine channel carries it beside truncated" PASS || check "L48a the machine channel carries revisited (got $(jq_field "$OUT" revisited))" FAIL
# The control: an ordinary two-session chain must NOT be flagged.
reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" adopt "$SID_A" --all >/dev/null
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --where "$SID_A" --json --all)"
[ "$(jq_field "$OUT" revisited)" = "false" ] && check "L48b-control a chain that never came back is not flagged" PASS || check "L48b-control a chain that never came back is not flagged (got $(jq_field "$OUT" revisited))" FAIL
reset_ledger

# -- L49 -- a migration is a fact about the STORE, not about this repo ------
# The branch gated on the repo-SCOPED count, so a repo that simply has no
# handovers, beside one stale sibling record, printed "This build reads none of
# the records this machine already holds" while v1/ held plenty for other repos --
# and suppressed the ordinary guidance while doing it. Every earlier check drove
# it with --all, where the scoped and unscoped counts coincide, so the suite could
# not see the difference. Raised by the review panel.
reset_ledger
mkdir -p "$CFG/zensu/session-lineage/v0/edges"
printf '{"schemaVersion":0,"from":{"sessionId":"a"},"to":{"sessionId":"b"}}' > "$CFG/zensu/session-lineage/v0/edges/1-aaaaaaaaaaaaaaaa.json"
# A REAL repo context is required to reach the scoped/unscoped divergence at all:
# repoContext answers null outside a git repo, ctx is then null, inScope is
# unconditionally true and the two counts coincide -- which is exactly why every
# earlier check, all of which pass --all, could never observe this. `cyc` files its
# edge under repo root /r, so this context scopes it out while the store holds it.
OTHER_REPO="$FAKE/other-repo"
mkdir -p "$OTHER_REPO"
git -C "$OTHER_REPO" init -q >/dev/null 2>&1
cyc 1 "$SID_A" "$SID_B"
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --repo "$OTHER_REPO")"
case "$TXT" in *MIGRATION*) check "L49 a populated current store is not reported as a migration just because THIS repo has no handovers" FAIL ;; *) check "L49 a populated current store is not reported as a migration just because THIS repo has no handovers" PASS ;; esac
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --repo "$OTHER_REPO" --json)"
[ "$(jq_field "$OUT" otherSchemaLedgers)" = "[]" ] && check "L49a and the machine channel agrees -- the probe did not run" PASS || check "L49a the machine channel agrees (got $(jq_field "$OUT" otherSchemaLedgers))" FAIL
# The control: with the current store genuinely empty, the migration report must
# still fire without --all, or the fix would simply have disabled the feature.
reset_ledger
mkdir -p "$CFG/zensu/session-lineage/v0/edges"
printf '{"schemaVersion":0,"from":{"sessionId":"a"},"to":{"sessionId":"b"}}' > "$CFG/zensu/session-lineage/v0/edges/1-aaaaaaaaaaaaaaaa.json"
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --repo "$OTHER_REPO")"
case "$TXT" in *MIGRATION*) check "L49b-control an empty current store still reports the migration, and without --all" PASS ;; *) check "L49b-control an empty current store still reports the migration (got ${TXT:-<empty>})" FAIL ;; esac
rm -rf "$CFG/zensu/session-lineage/v0"

# -- L50 -- --where must not offer the reconstruction on a migrated store ---
# The listing path stopped offering it; the --where path did not, so the exact
# offer that would mint guesses for handovers the machine already holds as
# measurements survived on the sibling code path. Found by the main thread.
reset_ledger
mkdir -p "$CFG/zensu/session-lineage/v0/edges"
printf '{"schemaVersion":0,"from":{"sessionId":"aaaaaaaa-1"},"to":{"sessionId":"bbbbbbbb-2"}}' > "$CFG/zensu/session-lineage/v0/edges/1-aaaaaaaaaaaaaaaa.json"
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --where "aaaaaaaa-1" --all)"
case "$TXT" in *"--backfill"*) check "L50 --where on a migrated store does not offer to reconstruct what the store already holds" FAIL ;; *) check "L50 --where on a migrated store does not offer to reconstruct what the store already holds" PASS ;; esac
case "$TXT" in *MIGRATION*) check "L50a and it names the migration instead" PASS ;; *) check "L50a it names the migration instead (got ${TXT:-<empty>})" FAIL ;; esac
rm -rf "$CFG/zensu/session-lineage/v0"
# The control: with no sibling directory the ordinary unknown-session guidance,
# reconstruction offer included, must come back.
reset_ledger
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --where "ffffffff-0000-0000-0000-00000000000f" --all)"
case "$TXT" in *"--backfill"*) check "L50b-control an ordinary unknown session still gets the reconstruction offer" PASS ;; *) check "L50b-control an ordinary unknown session still gets the offer (got ${TXT:-<empty>})" FAIL ;; esac
reset_ledger

# -- L51 -- the record cap reaches the channel a PERSON reads ---------------
# readEdges bounds how many records it enumerates and every payload carries the
# flag -- but all eleven carriers were inside JSON.stringify, so the text channel
# rendered from a capped prefix exactly like a complete answer, beside LEDGER ERROR
# and LEDGER SCHEMA lines that do disclose. That is the silent truncation the bound
# was added to make visible. Raised by the review panel.
#
# NOT driven behaviourally, and the reason is a measurement rather than a hunch:
# tripping the cap needs MAX_EDGE_RECORDS + 1 records, which costs 1.3 s to create
# on macOS and is then READ, and this suite's Windows ceiling is already recorded
# as unmeasured after it doubled. The unit suite proves the flag is COMPUTED (it
# plants exactly that many); these pins prove every renderer consults it, and each
# negative carries a planted control.
TR_SRC="$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs"
TR_TEXT_SITES="$(grep -c 'ledgerTruncatedNote\|truncatedNote(' "$TR_SRC")"
[ "$TR_TEXT_SITES" -ge 4 ] && check "L51 the record cap is rendered on the text channel, not only inside JSON payloads ($TR_TEXT_SITES sites)" PASS || check "L51 the record cap is rendered on the text channel (got $TR_TEXT_SITES sites, want >= 4)" FAIL
# One owner for the sentence, as confidenceNote is for the tier: four hand-written
# copies of a disclosure drift, and three of them saying it is not a disclosure.
[ "$(grep -c 'function truncatedNote' "$TR_SRC")" = "1" ] && check "L51a the disclosure sentence has exactly one owner" PASS || check "L51a the disclosure sentence has exactly one owner (got $(grep -c 'function truncatedNote' "$TR_SRC"))" FAIL
# --forget's own note must cover truncation as well as refused records: it is the
# destructive verb, and "N of N removed" on a capped read is the worst spelling of
# this defect in the file.
FG_BODY="$(awk '/^function lineageForget\(/{f=1} f{print} f&&/^\}/{exit}' "$TR_SRC")"
[ -n "$FG_BODY" ] && check "L51b-control the lineageForget body was actually extracted" PASS || check "L51b-control the lineageForget body was not found, so the scan below is vacuous" FAIL
# The NOTE, not merely the identifier: `led.truncated` already appears in this
# function's JSON payloads, so scanning for it would have passed before the fix.
case "$FG_BODY" in *"truncatedNote("*) check "L51b the destructive verb's disclosure covers a capped read, not only refused records" PASS ;; *) check "L51b the destructive verb's disclosure covers a capped read" FAIL ;; esac
# The planted control both negatives above lack on their own: the scan must be able
# to report an absence, or "no site found" and "no site needed" read the same.
L51_CTRL="$(mktemp -t zensu-l51-XXXXXX)"
printf 'const x = 1;\n' > "$L51_CTRL"
[ "$(grep -c 'truncatedNote(' "$L51_CTRL")" = "0" ] && check "L51c-control the site scan reports zero on a file that has none" PASS || check "L51c-control the site scan reports zero on a file that has none" FAIL
rm -f "$L51_CTRL"

# -- L52 -- a label key the tool prints is a key the tool can remove --------
# The set path echoes the QUALIFIED window key it stored; `--remove` classified
# anything that is not all digits as an account, so copying the echoed key back
# searched the wrong namespace and reported "nothing was removed" while the label
# was still on disk. And the account path stored the RAW key while every reader
# resolves a BOUNDED one, so an over-long or control-carrying key round-tripped
# into a state nothing could name. Both raised by the review panel; both leave a
# label permanent, which is the state --remove exists to end.
reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" label "$LIVE_PID" "A Window" >/dev/null
ECHOED="$(node -e '
const fs = require("fs");
try {
  const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  process.stdout.write(Object.keys(o.windows || {})[0] || "");
} catch (e) { process.stdout.write(""); }
' "$CFG/zensu/session-lineage/v1/labels.json")"
[ -n "$ECHOED" ] && check "L52-control the set path stored a window key to copy" PASS || check "L52-control the set path stored a window key to copy" FAIL
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" label --remove "$ECHOED" --json)"
[ "$(jq_field "$OUT" removed)" = "true" ] && check "L52 the qualified key the tool printed is one --remove can name" PASS || check "L52 the qualified key the tool printed is removable (removed=$(jq_field "$OUT" removed))" FAIL
[ -z "$(label_keys windows)" ] && check "L52a and the entry is really gone, not merely reported gone" PASS || check "L52a the entry is really gone (windows holds $(label_keys windows))" FAIL

# An account key longer than the reader's bound: stored raw, it becomes a
# different key on the next read and nothing can ever name it again.
reset_ledger
LONG_KEY="$(node -e 'process.stdout.write("k".repeat(200))')"
trail "$STORE" "$SID_C" "$LIVE_PID" label "$LONG_KEY" "Too Long" >/dev/null
STORED_KEY="$(node -e '
const fs = require("fs");
try {
  const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  process.stdout.write(String((Object.keys(o.accounts || {})[0] || "").length));
} catch (e) { process.stdout.write("ERR"); }
' "$CFG/zensu/session-lineage/v1/labels.json")"
{ [ "$STORED_KEY" != "ERR" ] && [ "$STORED_KEY" -gt 0 ] && [ "$STORED_KEY" -lt 200 ]; } 2>/dev/null \
  && check "L52b an over-long account key is stored in the form the reader will resolve (length $STORED_KEY)" PASS \
  || check "L52b an over-long account key is stored bounded (stored length $STORED_KEY — 'ERR' or 0 means nothing was stored, which this check used to pass on)" FAIL
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" label --remove "$LONG_KEY" --json)"
[ "$(jq_field "$OUT" removed)" = "true" ] && check "L52c and the same spelling the user typed still removes it" PASS || check "L52c the same spelling still removes it (removed=$(jq_field "$OUT" removed))" FAIL
reset_ledger

# -- L53 -- the two rules the module states are actually held by its consumer
# The module says there is ONE comparison rule for recordedAt and that the pair key
# is JSON-encoded because `>` survives boundText. Its only consumer held neither:
# a localeCompare ordered the endpoint `--where` renders (so a machine-wide
# ledger's order depended on the reader's ICU build), and the backfill duplicate
# guard rebuilt the very `from>to` key dedupeEdges abandoned. Both raised by the
# review panel; both are the module's own stated invariant, contradicted one file
# over.
CMP_SRC="$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs"
grep -q 'localeCompare(' "$CMP_SRC" && check "L53 the consumer holds the module's single timestamp comparison rule" FAIL || check "L53 the consumer holds the module's single timestamp comparison rule" PASS
grep -q '`${e.from.sessionId}>${e.to.sessionId}`' "$CMP_SRC" && check "L53a the backfill duplicate key cannot be spelled by two different pairs" FAIL || check "L53a the backfill duplicate key cannot be spelled by two different pairs" PASS
# Planted controls: a negative scan that cannot match reports a clean file for the
# wrong reason, which is the defect the panel found in two sibling checks.
L53_CTRL="$(mktemp -t zensu-l53-XXXXXX)"
printf 'const x = a.localeCompare(b);\n' > "$L53_CTRL"
grep -q 'localeCompare' "$L53_CTRL" && check "L53b-control the comparator scan matches a planted localeCompare" PASS || check "L53b-control the comparator scan matched nothing, so L53 is vacuous" FAIL
printf 'const k = `${e.from.sessionId}>${e.to.sessionId}`;\n' > "$L53_CTRL"
grep -q '`${e.from.sessionId}>${e.to.sessionId}`' "$L53_CTRL" && check "L53c-control the pair-key scan matches a planted from>to key" PASS || check "L53c-control the pair-key scan matched nothing, so L53a is vacuous" FAIL
rm -f "$L53_CTRL"
# And the ordering must still WORK: a pin that only forbids a spelling is satisfied
# by deleting the sort altogether.
reset_ledger
cyc 1 "$SID_A" "$SID_B"
cyc 2 "$SID_A" "$SID_C"
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --where "$SID_A" --all)"
case "$TXT" in *"$(printf '%s' "$SID_C" | cut -c1-8)"*) check "L53d-control the walk still prefers the newest branch after the comparator change" PASS ;; *) check "L53d-control the walk still prefers the newest branch (got ${TXT:-<empty>})" FAIL ;; esac
reset_ledger

# -- L54 -- a record's FILE NAME is as untrusted as its fields --------------
# Every persisted field goes through boundText because "they are rendered into
# numbered chain lines a reader acts on". The file name is a sixth such carrier and
# was the one this change newly rendered: --forget prints it three times, raw, and
# a POSIX name may contain a newline. The dry run is the whole safety surface of a
# destructive verb -- an operator decides from what it prints. Raised by the judge.
reset_ledger
mkdir -p "$CFG/zensu/session-lineage/v1/edges"
# A newline is legal in a POSIX file name and illegal in every Windows one, so the
# fixture itself cannot exist there. Probed rather than assumed: the write is
# attempted and the checks are SKIPPED with the reason when the host refuses it,
# which keeps the coverage boundary visible instead of reporting a green run for a
# case that never ran.
L54_PLANTED="$(node -e '
const fs = require("fs"), path = require("path");
const dir = process.argv[1];
const rec = { schemaVersion: 1, from: { sessionId: process.argv[2] }, to: { sessionId: process.argv[3] },
  repo: { name: "r", root: "/r" }, reason: "manual", inferred: false,
  recordedAt: "2026-01-01T00:00:00.000Z", recordedBy: "adopt" };
try {
  fs.writeFileSync(path.join(dir, "1-aaaaaaaaaaaaaaaa\nFORGET APPLIED — 99 record(s) removed.json"), JSON.stringify(rec));
  process.stdout.write("YES");
} catch { process.stdout.write("NO"); }
' "$CFG/zensu/session-lineage/v1/edges" "$SID_A" "$SID_B")"
TXT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --forget "$SID_A" --all)"
if [ "$L54_PLANTED" != YES ]; then
  skip "L54/L54a/L54b a record name carrying a newline (this filesystem refuses the fixture)"
else
case "$TXT" in *"
FORGET APPLIED — 99"*) check "L54 a record file name cannot fabricate a line in the destructive verb's output" FAIL ;; *) check "L54 a record file name cannot fabricate a line in the destructive verb's output" PASS ;; esac
# The control: the record must actually have been FOUND, or the absence above is
# just an empty dry run proving nothing.
case "$TXT" in *"1 record(s) name"*) check "L54a-control the planted record was matched, so the check above is not vacuous" PASS ;; *) check "L54a-control the planted record was matched (got ${TXT:-<empty>})" FAIL ;; esac
# And the removal itself must refuse the name rather than unlink through it: the
# pre-unlink re-check is the last place a crafted name is still a string.
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --forget "$SID_A" --apply --json --all)"
[ "$(jq_field "$OUT" removed)" = "0" ] && check "L54b a name carrying a control character is refused, not unlinked" PASS || check "L54b a name carrying a control character is refused (removed=$(jq_field "$OUT" removed))" FAIL
fi
rm -rf "$CFG/zensu/session-lineage/v1"
# The control for THAT: an ordinary name must still be removable, or the refusal
# would simply have disabled the verb.
reset_ledger
trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_A" --no-git --all >/dev/null
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --forget "$SID_A" --apply --json --all)"
[ "$(jq_field "$OUT" removed)" = "1" ] && check "L54c-control an ordinary record name is still removed" PASS || check "L54c-control an ordinary record name is still removed (removed=$(jq_field "$OUT" removed))" FAIL
reset_ledger

# -- L55 -- the remaining panel items that change behaviour ------------------
# A flag that belongs to another command must be refused, not dropped. The parser
# accepts every flag for every command, so `lineage --remove <key>` parsed and then
# fell through to the default listing -- the shape the exclusivity block's own
# comment names, surviving on the flags it did not list.
reset_ledger
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --remove 4242 --all)"
case "$OUT" in *"not a flag of"*) check "L55 a flag belonging to another command is refused by lineage, not silently dropped" PASS ;; *) check "L55 lineage refuses a flag of another command (got ${OUT:-<empty>})" FAIL ;; esac
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" label --forget "$SID_A" "$ACCT_A" "x")"
case "$OUT" in *"not a flag of"*) check "L55a and label refuses one of lineage's, so the rule is not one-sided" PASS ;; *) check "L55a label refuses one of lineage's flags (got ${OUT:-<empty>})" FAIL ;; esac
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --json --all)"
[ "$(jq_field "$OUT" edgeCount)" = "0" ] && check "L55b-control an ordinary invocation is unaffected by the new refusal" PASS || check "L55b-control an ordinary invocation is unaffected (got $(jq_field "$OUT" edgeCount))" FAIL

# A symlinked EDGES directory is refused on the read and delete paths too. The
# write path already refuses one; read and delete followed it, so the guard held
# for the operation that creates the store and not for the one that empties it.
reset_ledger
mkdir -p "$CFG/zensu/session-lineage/v1" "$FAKE/elsewhere-edges"
ln -s "$FAKE/elsewhere-edges" "$CFG/zensu/session-lineage/v1/edges" 2>/dev/null
IS_LINK="$(node -e '
const fs = require("node:fs");
try { process.stdout.write(fs.lstatSync(process.argv[1]).isSymbolicLink() ? "YES" : "NO"); }
catch { process.stdout.write("NO"); }
' "$CFG/zensu/session-lineage/v1/edges")"
[ "$IS_LINK" = YES ] && check "L55c-control the edges path is really a symlink, not a copy this host substituted" PASS || check "L55c-control the edges path is really a symlink (got $IS_LINK)" FAIL
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --json --all)"
case "$(jq_field "$OUT" ledgerError)" in ''|null|ABSENT|PARSE_ERROR) check "L55c a symlinked edges directory is reported, not read through (got $(jq_field "$OUT" ledgerError))" FAIL ;; *) check "L55c a symlinked edges directory is reported, not read through" PASS ;; esac
rm -f "$CFG/zensu/session-lineage/v1/edges"
reset_ledger

# The process table's start-time parse fails SILENTLY when the locale pin does not
# hold: every window label stops resolving and nothing anywhere says why. The
# command whose entire job is explaining why something does not resolve must say so.
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --diagnose --json --all)"
case "$(jq_field "$OUT" processStartTimes)" in ABSENT|PARSE_ERROR|'') check "L55d --diagnose reports whether process start times could be read at all (got $(jq_field "$OUT" processStartTimes))" FAIL ;; *) check "L55d --diagnose reports whether process start times could be read at all" PASS ;; esac

# -- L56 -- the flag-scoping rule must cover every command, not two ----------
# R13 put the refusal inside the two handlers that had the flags. The dispatcher
# routes NINE, so `takeover x --forget y` still parsed both, recorded an edge and
# named neither -- the same silence one layer out. The rule belongs where the
# command name is decided, and the table must be exhaustive over that set or a
# command missing from it accepts everything again.
reset_ledger
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_A" --no-git --all --forget "$SID_B")"
case "$OUT" in *"not a flag of"*) check "L56 takeover refuses a flag of another command" PASS ;; *) check "L56 takeover refuses a flag of another command (got ${OUT:-<empty>})" FAIL ;; esac
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" show "$SID_A" --no-git --all --apply)"
case "$OUT" in *"not a flag of"*) check "L56a show refuses a flag of another command" PASS ;; *) check "L56a show refuses a flag of another command (got $(printf '%s' "${OUT:-<empty>}" | head -c 80))" FAIL ;; esac
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" instances --all --self)"
case "$OUT" in *"not a flag of"*) check "L56b instances refuses a flag of another command" PASS ;; *) check "L56b instances refuses a flag of another command (got $(printf '%s' "${OUT:-<empty>}" | head -c 80))" FAIL ;; esac

# `adopt` is the verb whose ENTIRE output is the record it just wrote, so the
# documented `--no-record` inspection has no meaning there -- it never read the
# flag and wrote the machine-wide record anyway, while SKILL.md told the user that
# spelling opts out. Refusing is the honest answer; silently obeying the doc would
# leave a verb that does nothing.
reset_ledger
BEFORE_ADOPT="$(edge_count)"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" adopt "$SID_A" --all --no-record)"
case "$OUT" in *"not a flag of"*) check "L56c adopt refuses --no-record rather than writing the record it says it skipped" PASS ;; *) check "L56c adopt refuses --no-record (got $(printf '%s' "${OUT:-<empty>}" | head -c 80))" FAIL ;; esac
[ "$(edge_count)" = "$BEFORE_ADOPT" ] && check "L56d and the refused adopt wrote nothing to the ledger" PASS || check "L56d the refused adopt wrote nothing (before=$BEFORE_ADOPT after=$(edge_count))" FAIL

# The two documented deliberate ignores must SURVIVE the rule. SKILL.md states
# that `--force` is accepted and ignored by the selector-less surveys on purpose,
# so a table that refused it there would break a documented contract, not tighten
# one. Positive controls, not bites: they pass on both sides of the fix.
reset_ledger
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" list --no-git --all --json --force)"
case "$OUT" in *"not a flag of"*) check "L56e-control --force stays accepted by list, which documents ignoring it" FAIL ;; *) check "L56e-control --force stays accepted by list, which documents ignoring it" PASS ;; esac
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" limited --no-git --all --json --force)"
case "$OUT" in *"not a flag of"*) check "L56f-control --force stays accepted by limited for the same documented reason" FAIL ;; *) check "L56f-control --force stays accepted by limited for the same documented reason" PASS ;; esac
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" takeover "$SID_A" --no-git --all --json --no-record --reason handover)"
[ "$(jq_field "$OUT" lineage.recorded)" = "false" ] && check "L56g-control takeover still honours --no-record, which is its own flag" PASS || check "L56g-control takeover honours --no-record (recorded=$(jq_field "$OUT" lineage.recorded))" FAIL

# The table must be EXHAUSTIVE over the dispatched set. Both sides are derived
# from source rather than hardcoded here, so a tenth command added to the
# dispatcher without a flag table fails this check instead of quietly accepting
# every flag in the namespace again.
L56_SRC="$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs"
DISPATCHED="$(node -e '
const fs = require("node:fs");
const src = fs.readFileSync(process.argv[1], "utf8");
const m = src.match(/const COMMANDS = \{([\s\S]*?)\n\};/);
if (!m) { process.stdout.write("NO_COMMANDS"); process.exit(0); }
const keys = [...m[1].matchAll(/^\s{2}([A-Za-z]+):/gm)].map((x) => x[1]);
process.stdout.write(keys.sort().join(","));
' "$L56_SRC")"
TABLED="$(node -e '
const fs = require("node:fs");
const src = fs.readFileSync(process.argv[1], "utf8");
const m = src.match(/const COMMAND_FLAGS = \{([\s\S]*?)\n\};/);
if (!m) { process.stdout.write("NO_TABLE"); process.exit(0); }
const keys = [...m[1].matchAll(/^\s{2}([A-Za-z]+):/gm)].map((x) => x[1]);
process.stdout.write(keys.sort().join(","));
' "$L56_SRC")"
if [ "$DISPATCHED" = "$TABLED" ] && [ "$DISPATCHED" != "NO_COMMANDS" ] && [ -n "$DISPATCHED" ]; then
  check "L56h every dispatched command has a flag table ($DISPATCHED)" PASS
else
  check "L56h every dispatched command has a flag table (dispatched=$DISPATCHED tabled=$TABLED)" FAIL
fi

# -- L57 -- the disclosures that reach one carrier and not its sibling -------
# Every one of these is the same defect the listing branch already fixed, alive in
# a sibling code path: a read that FAILED rendered exactly like a read that found
# nothing. The listing branch names both causes; its `--where` sibling named
# neither and closed with the reconstruction offer, which is the one line here
# that mints machine-wide guesses.
reset_ledger
mkdir -p "$CFG/zensu/session-lineage/v1"
printf 'x' > "$CFG/zensu/session-lineage/v1/edges"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --where "$SID_A" --all)"
case "$OUT" in *"could not be read"*) check "L57 --where on an unreadable ledger names the fault instead of reporting no lineage" PASS ;; *) check "L57 --where on an unreadable ledger names the fault (got $(printf '%s' "${OUT:-<empty>}" | head -c 100))" FAIL ;; esac
case "$OUT" in *"--backfill"*) check "L57a and it does not offer to reconstruct from a read that failed" FAIL ;; *) check "L57a and it does not offer to reconstruct from a read that failed" PASS ;; esac
rm -f "$CFG/zensu/session-lineage/v1/edges"

# The newer-schema half of the same branch. `--where` reported "either that session
# was never handed over, or the handover predates the ledger" for a ledger this
# build simply cannot read yet.
reset_ledger
mkdir -p "$CFG/zensu/session-lineage/v1/edges"
printf '{"schemaVersion":99,"from":{"sessionId":"%s"},"to":{"sessionId":"%s"},"recordedAt":"2026-01-01T00:00:00.000Z"}' "$SID_A" "$SID_B" \
  > "$CFG/zensu/session-lineage/v1/edges/9999999999-deadbeef.json"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --where "$SID_A" --all)"
case "$OUT" in *"NEWER schema"*) check "L57b --where on a newer-schema ledger says so instead of asserting no handover" PASS ;; *) check "L57b --where on a newer-schema ledger says so (got $(printf '%s' "${OUT:-<empty>}" | head -c 100))" FAIL ;; esac
reset_ledger

# `instances` is the view SKILL.md names as the machine-wide answer to "where did
# that session go" -- the one a window with no quota left cannot ask for itself.
# Its --json carrier reported the ledger fault; its TEXT carrier printed the
# sessions with no lineage lines and nothing to say they were missing rather than
# absent.
reset_ledger
mkdir -p "$CFG/zensu/session-lineage/v1"
printf 'x' > "$CFG/zensu/session-lineage/v1/edges"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" instances --all)"
case "$OUT" in *"could not be read"*) check "L57c the text instances view discloses a ledger it could not read" PASS ;; *) check "L57c the text instances view discloses an unreadable ledger (got $(printf '%s' "${OUT:-<empty>}" | head -c 100))" FAIL ;; esac
rm -f "$CFG/zensu/session-lineage/v1/edges"
reset_ledger

# --diagnose is the command whose entire job is explaining why something does not
# resolve. The start-time parse is the single point of failure for every window
# label, and its health reached the machine carrier only.
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --diagnose --all)"
case "$OUT" in *"START TIMES"*) check "L57d --diagnose reports the start-time parse on the channel a person reads" PASS ;; *) check "L57d --diagnose reports the start-time parse on the text channel (got $(printf '%s' "${OUT:-<empty>}" | head -c 100))" FAIL ;; esac

# `revisited` reaches the --where rendering and is dropped by the listing one, on
# BOTH carriers -- the reset flow it exists for (adopt A>B, then adopt B>A) renders
# a chain that stops with no caveat while the newest edge says the work came back.
reset_ledger
cyc 1 "$SID_A" "$SID_B"
cyc 2 "$SID_B" "$SID_A"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --all)"
case "$OUT" in *"came back"*) check "L57e the listing view discloses that the work came back to a session already in the chain" PASS ;; *) check "L57e the listing view discloses a revisited chain (got $(printf '%s' "${OUT:-<empty>}" | head -c 120))" FAIL ;; esac
REV_JSON="$(node -e '
let o; try { o = JSON.parse(process.argv[1]); } catch { process.stdout.write("PARSE_ERROR"); process.exit(0); }
const c = (o.chains || [])[0];
if (!c) { process.stdout.write("NO_CHAIN"); process.exit(0); }
process.stdout.write(["revisited","truncated"].every((k) => k in c) ? "BOTH" : "MISSING:" + ["revisited","truncated"].filter((k) => !(k in c)).join(","));
' "$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --json --all)")"
[ "$REV_JSON" = "BOTH" ] && check "L57f and the machine carrier keeps both walk bounds per chain" PASS || check "L57f the machine carrier keeps both walk bounds per chain (got $REV_JSON)" FAIL
reset_ledger

# The record cap is pinned at SOURCE, not driven: tripping it needs
# MAX_EDGE_RECORDS + 1 files, whose cost L51 already measured and declined for a
# suite whose Windows ceiling is recorded as unmeasured. Same decision, same
# reason, and each negative carries the planted control L51 established.
L57_SRC="$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs"
# --apply is refused while the read was capped, for the identical reason it is
# refused while a record is unreadable: the duplicate guard is built from that
# read, so a pair beyond the cap re-proposes and --apply mints a second copy of an
# edge the machine already holds. The refusal text already states that argument for
# the per-record cause.
BF_BLOCK="$(grep -n 'const applyBlocked' "$L57_SRC" | head -1 | cut -d: -f1)"
[ -n "$BF_BLOCK" ] && check "L57g-control the --apply gate expression was located" PASS || check "L57g-control the --apply gate expression was not found, so the scan below is vacuous" FAIL
case "$(sed -n "${BF_BLOCK:-1}p" "$L57_SRC")" in *"truncated"*) check "L57g --apply is gated on a capped read as well as an unreadable record" PASS ;; *) check "L57g --apply is gated on a capped read (got $(sed -n "${BF_BLOCK:-1}p" "$L57_SRC" | head -c 90))" FAIL ;; esac
# And the cap reaches the instances text view, which renders lineage per session.
IN_BODY="$(awk '/^function cmdInstances\(/{f=1} f{print} f&&/^\}/{exit}' "$L57_SRC")"
[ -n "$IN_BODY" ] && check "L57h-control the cmdInstances body was actually extracted" PASS || check "L57h-control the cmdInstances body was not found, so the scan below is vacuous" FAIL
case "$IN_BODY" in *"truncatedNote("*) check "L57h the record cap reaches the instances text view too" PASS ;; *) check "L57h the record cap reaches the instances text view" FAIL ;; esac

# -- L58 -- the label key is bounded BEFORE anything reads its shape ---------
# R13 bounded the key so the stored spelling and the typed one agree. Two things
# above and below that line still read the raw value. `kind` is decided by regex
# on the RAW target and the bound runs afterwards, so a key whose bounded form is
# a window key but whose raw form is not was looked up in the account namespace --
# "no account label is recorded" while the label sits under windows, which is the
# permanent state this verb exists to end. The fallback `|| target` then restores
# the unbounded value in exactly the case the bound matters: a key that bounds to
# nothing at all is stored and printed raw.
CTRL_CHAR="$(printf '\001')"
reset_ledger
LBL_PID="$LIVE_PID"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" label "$LBL_PID" "window under test" --all)"
STORED_KEY="$(window_keys)"
case "$STORED_KEY" in ''|UNREADABLE) check "L58-control the set path stored a window label to remove" FAIL ;; *) check "L58-control the set path stored a window label to remove" PASS ;; esac
# The raw spelling fails /^\d+(@|$)/ and the bounded one passes it, so the two
# disagree about which namespace to look in.
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" label --remove "${CTRL_CHAR}${LBL_PID}" --all --json)"
[ "$(jq_field "$OUT" kind)" = "window" ] && check "L58 the key kind is decided on the bounded spelling, not the raw one" PASS || check "L58 the key kind is decided on the bounded spelling (kind=$(jq_field "$OUT" kind))" FAIL
[ "$(jq_field "$OUT" removed)" = "true" ] && check "L58a and the label the tool stored is one that spelling can remove" PASS || check "L58a the label is removable through the bounded spelling (removed=$(jq_field "$OUT" removed))" FAIL

# A key that bounds to nothing must be refused, not restored to its raw form. The
# `|| target` fallback made the bound a no-op for precisely the input it exists to
# reject, and that value then became a stored key and a printed one.
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" label --remove "${CTRL_CHAR}${CTRL_CHAR}" --all 2>&1)"
case "$OUT" in *"no usable"*|*"not a usable"*) check "L58b a key that bounds to nothing is refused rather than used raw" PASS ;; *) check "L58b a key that bounds to nothing is refused (got $(printf '%s' "${OUT:-<empty>}" | tr -d '\001' | head -c 90))" FAIL ;; esac
# The same rule on the SET path, which stores the key rather than only reading it.
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" label "${CTRL_CHAR}${CTRL_CHAR}" "some text" --all 2>&1)"
case "$OUT" in *"no usable"*|*"not a usable"*) check "L58c and the set path refuses it too, before it reaches the file" PASS ;; *) check "L58c the set path refuses an unusable key (got $(printf '%s' "${OUT:-<empty>}" | tr -d '\001' | head -c 90))" FAIL ;; esac
# The ordinary spellings must survive both changes -- a guard that refused every
# key would satisfy the two assertions above on its own.
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" label "$ACCT_A" "ordinary account label" --all --json)"
[ "$(jq_field "$OUT" kind)" = "account" ] && check "L58d-control an ordinary account key still sets, and still reads as an account" PASS || check "L58d-control an ordinary account key still sets (kind=$(jq_field "$OUT" kind))" FAIL
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" label --remove "$ACCT_A" --all --json)"
[ "$(jq_field "$OUT" removed)" = "true" ] && check "L58e-control and removing it still works through the plain spelling" PASS || check "L58e-control removing an ordinary account key still works (removed=$(jq_field "$OUT" removed))" FAIL
reset_ledger

# -- L59 -- the round-3 security seat's findings, driven ---------------------
# A NEWER-schema record is refused INDIVIDUALLY while its neighbours parse, so a
# non-empty listing rendered with no hint that this build cannot read part of the
# store. R17 moved the fault disclosure above the offer; it did not reach the
# NON-EMPTY arm, where the only surviving line is the generic skipped NOTE, which
# names neither cause nor remedy.
reset_ledger
cyc 1 "$SID_A" "$SID_B"
printf '{"schemaVersion":99,"from":{"sessionId":"%s"},"to":{"sessionId":"%s"},"recordedAt":"2026-01-01T00:00:00.000Z"}' "$SID_D" "$SID_E" \
  > "$CFG/zensu/session-lineage/v1/edges/9999999999-deadbee9.json"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --all)"
case "$OUT" in *"RECORDED HANDOVERS: 1"*) check "L59-control the listing is NON-empty, so the empty-arm disclosure cannot be what fires" PASS ;; *) check "L59-control the listing is non-empty (got $(printf '%s' "${OUT:-<empty>}" | head -c 70))" FAIL ;; esac
case "$OUT" in *"NEWER schema"*) check "L59 a non-empty listing still discloses that part of the store is unreadable by this build" PASS ;; *) check "L59 a non-empty listing discloses the newer-schema records (got $(printf '%s' "${OUT:-<empty>}" | head -c 90))" FAIL ;; esac
reset_ledger

# The config root itself may be a SYMLINK -- the ordinary dotfile-manager layout --
# and the write path accepts it on purpose. The round-2 ancestor guard judged the
# ceiling instead of bounding at it, so records kept being written while every read
# answered ESYMLINK and `--forget`, the only retraction channel, refused forever.
ALT_REAL="$FAKE/real-cfg-root"
ALT_LINK="$FAKE/linked-cfg-root"
mkdir -p "$ALT_REAL"
ln -s "$ALT_REAL" "$ALT_LINK" 2>/dev/null
LINK_OK="$(node -e '
const fs = require("node:fs");
try { process.stdout.write(fs.lstatSync(process.argv[1]).isSymbolicLink() ? "YES" : "NO"); } catch { process.stdout.write("NO"); }
' "$ALT_LINK")"
if [ "$LINK_OK" != YES ]; then
  skip "L59a/L59b a symlinked config root (this filesystem did not create the link)"
else
  check "L59a-control the alternate config root is really a symlink" PASS
  OUT="$( ( cd "$SELF_CWD" 2>/dev/null || cd "$FAKE"
    HOME="$FAKE" USERPROFILE="$FAKE" ZENSU_CCD_STORE="$STORE" \
    CLAUDE_CODE_SESSION_ID="$SID_C" CLAUDE_PID="$LIVE_PID" \
    env -u CLAUDE_CONFIG_DIR node "$TRAIL_MJS" adopt "$SID_A" --all --json --config-dir "$ALT_LINK" 2>&1 ) )"
  [ "$(jq_field "$OUT" file)" != "ABSENT" ] && check "L59a a write through a symlinked config root still lands" PASS || check "L59a a write through a symlinked config root lands (got $(printf '%s' "${OUT:-<empty>}" | head -c 80))" FAIL
  OUT="$( ( cd "$SELF_CWD" 2>/dev/null || cd "$FAKE"
    HOME="$FAKE" USERPROFILE="$FAKE" ZENSU_CCD_STORE="$STORE" \
    CLAUDE_CODE_SESSION_ID="$SID_C" CLAUDE_PID="$LIVE_PID" \
    env -u CLAUDE_CONFIG_DIR node "$TRAIL_MJS" lineage --json --all --config-dir "$ALT_LINK" 2>&1 ) )"
  case "$(jq_field "$OUT" ledgerError)" in ''|null) check "L59b and the SAME tree is readable -- the two halves cannot disagree about one root" PASS ;; *) check "L59b the same tree is readable (ledgerError=$(jq_field "$OUT" ledgerError))" FAIL ;; esac
fi
rm -rf "$ALT_REAL" "$ALT_LINK"
reset_ledger

# -- L60 -- the migration signal must reach BOTH --where carriers -----------
# L50 drives the TEXT carrier only, so the machine carrier could answer
# `found: false` on a store whose schema moved with nothing to tell that apart from
# "never handed over" — while the text path printed the whole "That is a MIGRATION,
# not an empty history" paragraph. The listing JSON already carried the field; its
# --where sibling did not. Same one-owner-both-carriers rule, one code path over.
reset_ledger
mkdir -p "$CFG/zensu/session-lineage/v0/edges" "$CFG/zensu/session-lineage/v1/edges"
printf '{"schemaVersion":1,"from":{"sessionId":"%s"},"to":{"sessionId":"%s"},"recordedAt":"2026-01-01T00:00:00.000Z"}' "$SID_A" "$SID_B" \
  > "$CFG/zensu/session-lineage/v0/edges/1000000001-aaaaaaaa.json"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" lineage --where "$SID_A" --all --json)"
case "$(jq_field "$OUT" found)" in false) check "L60-control the --where JSON carrier reports not-found on a migrated store" PASS ;; *) check "L60-control the --where JSON carrier reports not-found (found=$(jq_field "$OUT" found))" FAIL ;; esac
case "$(jq_field "$OUT" otherSchemaLedgers)" in ABSENT|PARSE_ERROR) check "L60 the --where machine carrier distinguishes a migration from an absent handover (got $(jq_field "$OUT" otherSchemaLedgers))" FAIL ;; '[]') check "L60 the --where machine carrier carries the migration signal (empty on a store that HAS one)" FAIL ;; *) check "L60 the --where machine carrier distinguishes a migration from an absent handover" PASS ;; esac
rm -rf "$CFG/zensu/session-lineage/v0"
reset_ledger

# -- L61 -- no render of a path-shaped transcript value is left raw ---------
# Rounds 3 and 4 each found ANOTHER unbounded render of the same values rather
# than a wrong one: list's row header survived while the line below it was fixed,
# the handoff brief survived while its takeover twin was fixed, and cmdLimited
# reproduced the same shape inside one function. A per-site pin needs
# hand-extending every time, which is how the twin survived a whole round. This
# scans for the SHAPE instead: any interpolation of one of these identifiers,
# unwrapped, on a line that prints or pushes.
L61_SRC="$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs"
# Assignments as well as renders: the value can reach a printed line through an
# intermediate local, which is how `${r.branch}` on a `const gitPart =` line
# survived the first spelling of this scan while only `${gitPart}` reached the
# print. And `[^}]*` inside the braces, because `${r.wt || '(unknown)'}` is an
# idiom this file already uses and a bare-token pattern does not see it.
# The value can reach a rendered line WITHOUT ever being interpolated at its own
# site: `: (r.branch || '?')` assigns a bare expression to a local, and only the
# LOCAL is interpolated four lines later. A `${...}` pattern cannot see that, which
# is how the branch defect survived two spellings of this scan. So the scan is on
# the IDENTIFIER, anywhere it appears unwrapped, and the non-rendering consumers
# are allowlisted BY NAME. That allowlist is the maintenance cost, and it fails in
# the right direction: a new consumer added without an entry is reported, not
# silently passed.
L61_PAT='\br\.(wt|cwd|worktree|branch|title)\b'
# Wrappers that bound, and consumers that provably do not render their argument:
# rel/path.* take it as a prefix base, dirExists/worktreeRoot/gitState/gitDiffText/
# findPlanDocs/nearestRepoRoot take it as a filesystem path, Set/toLowerCase build
# a match structure, and ===/!==/typeof/.length compare it.
L61_OK='(oneLine|flatPath|briefPath|briefShellArg|writeAnchor|rel\(|path\.|gitState|gitDiffText|findPlanDocs|nearestRepoRoot|new Set\(|===|!==|\.toLowerCase|const r |r\.cwd !== r\.wt)'
# The `cd ${...}` exemption removes the exempted TOKEN, never the line, so a second
# raw interpolation on one of those four lines stays visible.
# Comment lines are excluded: they describe the rule rather than render anything,
# and prose naming `r.wt` was being reported as an unbounded render of it.
L61_RAW="$(sed -e 's/cd \${[^}]*}//g' "$L61_SRC" | grep -nE "$L61_PAT" | grep -vE '^[0-9]+:[[:space:]]*//' | grep -vE "$L61_OK" || true)"
if [ -z "$L61_RAW" ]; then
  check "L61 every r.wt/cwd/worktree/branch/title reference is wrapped, consumed by an allowlisted callee, or the documented cd exemption" PASS
else
  check "L61 an unbounded path-shaped render remains: $(printf '%s' "$L61_RAW" | head -2 | tr '\n' ' ' | cut -c1-140)" FAIL
fi
# The control: the scan must be able to REPORT one, or "none found" and "none
# looked for" read the same -- the defect this suite has now repaired six times.
L61_CTRL="$(mktemp -t zensu-l61-XXXXXX)"
printf 'print(`WORKTREE ${r.wt}`);\n' > "$L61_CTRL"
if grep -qE "$L61_PAT" "$L61_CTRL"; then
  check "L61-control the raw-render scan bites a planted unbounded interpolation" PASS
else
  check "L61-control the raw-render scan matched nothing, so L61 is vacuous" FAIL
fi
printf 'const gitPart = g ? x : (${r.branch} || 1);\n' > "$L61_CTRL"
if grep -qE "$L61_PAT" "$L61_CTRL"; then
  check "L61-control2 the scan bites the INTERMEDIATE-LOCAL shape, which is how the last defect evaded it" PASS
else
  check "L61-control2 the scan misses an intermediate local, so the evasion that already happened is still open" FAIL
fi
printf 'print(`${r.wt || "(unknown)"}`);\n' > "$L61_CTRL"
if grep -qE "$L61_PAT" "$L61_CTRL"; then
  check "L61-control3 the scan bites a || fallback inside the braces" PASS
else
  check "L61-control3 the scan misses a || fallback inside the braces" FAIL
fi
rm -f "$L61_CTRL"
# And the exemption filter must not be inert: if the shell-command class ever stops
# matching, L61 would silently start reporting a clean tree for a reason unrelated
# to the property it names.
# The exemption this filter used to carry was for an UNQUOTED `cd ${...}`, and that
# spelling no longer exists: every runnable line routes its path through
# `briefShellArg`, which single-quotes. So the check is now that the fix is in place
# rather than that the hazard is exempted -- a scan for the old class would report a
# clean tree for a reason unrelated to the property it names.
L61_SHELLARG="$(grep -cF 'briefShellArg(' "$L61_SRC" || true)"
if [ "$L61_SHELLARG" -ge 4 ] && ! grep -qF 'cd ${' "$L61_SRC"; then
  check "L61b every runnable line quotes its path through briefShellArg, and no unquoted cd remains ($L61_SHELLARG sites)" PASS
else
  check "L61b runnable-line quoting (briefShellArg sites=$L61_SHELLARG, must be >= 4; unquoted cd must be absent)" FAIL
fi
# The file_path extractor binds at its SOURCE, so all three of its renderers are
# covered by one site rather than three chances to miss one.
ETF_BODY="$(awk '/^function extractTouchedFiles\(/{f=1} f{print} f&&/^\}/{exit}' "$L61_SRC")"
[ -n "$ETF_BODY" ] && check "L61a-control the extractTouchedFiles body was actually extracted" PASS || check "L61a-control the extractTouchedFiles body was not found, so the scan below is vacuous" FAIL
case "$ETF_BODY" in
  *"boundText("*) check "L61a the file_path extractor binds early, which breaks rel() against the raw worktree" FAIL ;;
  *) check "L61a the file_path extractor leaves the raw path for rel(), and the renderers bind it" PASS ;;
esac
# The other half of that rule: all three renderers must bind, or removing the early
# bound would leave the value unbounded rather than bound later.
ETF_RENDER="$(grep -cE '(flatPath|briefPath)\(rel\(t\.path, r\.wt\)\)' "$L61_SRC" || true)"
if [ "$ETF_RENDER" -ge 3 ]; then
  check "L61a-render every touched-file row binds after rel(), not before it ($ETF_RENDER sites)" PASS
else
  check "L61a-render a touched-file row renders rel() unbound ($ETF_RENDER of 3 sites)" FAIL
fi

# Every L61_OK alternative must still EXEMPT something, mirroring L61b-control for
# the cd class. The suite already states the argument for that control -- if the
# exempted class stops matching, the scan reports a clean tree for a reason
# unrelated to the property it names -- and the same argument applies here and was
# not applied. An entry that goes inert is pure blind spot: it can only ever
# suppress a line, never surface one, so it must report itself rather than widen
# the filter silently. Fails, never skips, on zero.
L61_STALE=""
for alt in 'oneLine' 'flatPath' 'briefPath' 'briefShellArg' 'writeAnchor' 'rel\(' 'path\.' 'gitState' 'gitDiffText' 'findPlanDocs' 'nearestRepoRoot' 'new Set\(' '===' '!==' '\.toLowerCase' 'const r ' 'r\.cwd !== r\.wt'; do
  if [ "$(grep -cE "$L61_PAT" "$L61_SRC" 2>/dev/null || echo 0)" = "0" ]; then break; fi
  HITS="$(grep -E "$L61_PAT" "$L61_SRC" | grep -cE "$alt" || true)"
  [ "$HITS" = "0" ] && L61_STALE="$L61_STALE $alt"
done
if [ -z "$L61_STALE" ]; then
  check "L61d every wrapper-allowlist entry still exempts at least one line, so none is a silent blind spot" PASS
else
  check "L61d wrapper-allowlist entries exempt nothing and are pure blind spot:$L61_STALE — drop them or narrow L61_OK" FAIL
fi

# -- L62 -- the display bound on the session id, pinned by BEHAVIOUR -----------
# The showId() bound was pinned by nothing: its only occurrence anywhere in tests/
# was inside L61's own ALLOWLIST, so deleting every call left the suite green. A
# source pin is also the wrong instrument here -- `sessionId` has many legitimate
# non-render uses (lookups, comparisons, Map keys), and an identifier scan over it
# needs an allowlist longer than the property it protects. So this drives the
# PROPERTY instead: an escape byte planted in the live registry -- which validates
# only truthiness -- must not reach the terminal. `.slice(0, 8)` bounds LENGTH and
# not content, and eight bytes is a complete SGR sequence.
reset_ledger
ESC="$(printf '\033')"
mkdir -p "$CFG/sessions"
node -e '
const fs = require("node:fs"), path = require("node:path");
const E = String.fromCharCode(27);
fs.writeFileSync(path.join(process.argv[1], "planted.json"), JSON.stringify({
  sessionId: E + "[31mPWNED" + E + "[0m-bbbb-cccc-dddddddddddd",
  pid: Number(process.argv[2]), startedAt: Date.now() - 60000,
  cwd: process.argv[3], name: "planted", entrypoint: "cli",
}));
' "$CFG/sessions" "$LIVE_PID" "$SELF_CWD"
OUT="$(trail "$STORE" "$SID_C" "$LIVE_PID" instances --all)"
case "$OUT" in *"[31mPWN"*) check "L62-control the planted row rendered with the ESC stripped and its visible bytes kept" PASS ;; *) check "L62-control the planted row rendered" FAIL ;; esac
case "$OUT" in *"$ESC"*) check "L62 an escape byte planted in a registry session id does not reach the terminal" FAIL ;; *) check "L62 an escape byte planted in a registry session id does not reach the terminal" PASS ;; esac
rm -f "$CFG/sessions/planted.json"
reset_ledger

# -- L63 -- the ancestry rule, which no fixture could reach ------------------
# Every fixture in this suite spawns node from a shell, so no ancestor ever matches
# /claude/i and windowOf returned null throughout -- the walk was effectively
# untestable and neutering it to `return null` cost almost nothing. The table is a
# parameter now and `window-probe` feeds it from stdin, so the shapes that actually
# decide the rule can be arranged. Ported from the parallel working copy on this
# branch, which found this first; the basename rule the walk applies is this line's.
probe() { printf '%s' "$1" | ( cd "$SELF_CWD" 2>/dev/null || cd "$FAKE"; HOME="$FAKE" USERPROFILE="$FAKE" env -u CLAUDE_CONFIG_DIR node "$TRAIL_MJS" window-probe --config-dir "$CFG" 2>&1 ); }
# HIGHEST match, not nearest. A helper process between the session and the app also
# matches /claude/i, and the window a user sees is the OUTERMOST one -- answering
# with the helper would group sessions under a process the user cannot point at.
OUT="$(probe '{"pid":100,"table":[{"pid":100,"ppid":90,"comm":"node"},{"pid":90,"ppid":80,"comm":"claude-helper"},{"pid":80,"ppid":1,"comm":"/Applications/Claude.app/Contents/MacOS/Claude"}]}')"
[ "$(jq_field "$OUT" appPid)" = "80" ] && check "L63 the ancestry walk answers with the OUTERMOST Claude ancestor, not the nearest" PASS || check "L63 the walk answers with the outermost match (appPid=$(jq_field "$OUT" appPid), want 80)" FAIL
# A single ancestor is still found -- without this the check above is satisfied by a
# walk that simply climbs to the top and reports whatever it lands on.
OUT="$(probe '{"pid":100,"table":[{"pid":100,"ppid":90,"comm":"node"},{"pid":90,"ppid":1,"comm":"/Applications/Claude.app/Contents/MacOS/Claude"}]}')"
[ "$(jq_field "$OUT" appPid)" = "90" ] && check "L63a a single Claude ancestor is found" PASS || check "L63a a single Claude ancestor is found (appPid=$(jq_field "$OUT" appPid), want 90)" FAIL
# No Claude ancestor answers NULL rather than a stray pid. This is the arm that keeps
# the window grouping honest when the desktop store is unreachable.
OUT="$(probe '{"pid":100,"table":[{"pid":100,"ppid":90,"comm":"node"},{"pid":90,"ppid":80,"comm":"zsh"},{"pid":80,"ppid":1,"comm":"login"}]}')"
case "$(jq_field "$OUT" appPid)" in null) check "L63b a chain with no Claude ancestor answers null, never a stray pid" PASS ;; *) check "L63b a chain with no Claude ancestor answers null (got $(jq_field "$OUT" appPid))" FAIL ;; esac
# The hop bound. A match beyond it must not be reached, or a deep tree costs an
# unbounded walk on every row rendered.
DEEP="$(node -e '
const rows = [{ pid: 100, ppid: 101, comm: "node" }];
for (let i = 101; i < 130; i += 1) rows.push({ pid: i, ppid: i + 1, comm: "sh" });
rows.push({ pid: 130, ppid: 1, comm: "Claude" });
process.stdout.write(JSON.stringify({ pid: 100, table: rows }));
')"
OUT="$(probe "$DEEP")"
case "$(jq_field "$OUT" appPid)" in null) check "L63c a Claude ancestor beyond the hop bound is not reached" PASS ;; *) check "L63c a match beyond the hop bound is not reached (got $(jq_field "$OUT" appPid))" FAIL ;; esac
# The seam reaches nothing on the machine: malformed input is refused rather than
# falling back to the real process table.
OUT="$(probe 'not json')"
case "$(jq_field "$OUT" error)" in ABSENT|null) check "L63d-control malformed probe input is refused, so the seam cannot fall back to the live table" FAIL ;; *) check "L63d-control malformed probe input is refused, so the seam cannot fall back to the live table" PASS ;; esac
# The BASENAME, never the whole string. `ps -o comm=` yields the full executable path
# on macOS, so a whole-string test matched any ancestor that merely LIVED under a
# claude-named directory -- a checkout of this plugin, or ~/claude-tools/bin/watcher.
# The session was then grouped under a "window" that is not one, and this walk is the
# fallback that exists precisely for when the desktop store is unreachable. Until
# `window-probe` existed this rule was pinned at SOURCE only; it is behavioural now.
OUT="$(probe '{"pid":100,"table":[{"pid":100,"ppid":90,"comm":"node"},{"pid":90,"ppid":1,"comm":"/Users/x/claude-tools/bin/watcher"}]}')"
case "$(jq_field "$OUT" appPid)" in null) check "L63e a path that merely LIVES under a claude-named directory is not a window" PASS ;; *) check "L63e a claude-named DIRECTORY is not a window (got $(jq_field "$OUT" appPid))" FAIL ;; esac
# The positive half of the same rule, so L63e is not satisfied by a walk that stopped
# matching anything: the identical tree with the name moved into the basename matches.
OUT="$(probe '{"pid":100,"table":[{"pid":100,"ppid":90,"comm":"node"},{"pid":90,"ppid":1,"comm":"/Users/x/tools/bin/claude-watcher"}]}')"
[ "$(jq_field "$OUT" appPid)" = "90" ] && check "L63f-control the same tree matches once the name is in the basename" PASS || check "L63f-control the same tree matches once the name is in the basename (got $(jq_field "$OUT" appPid))" FAIL

# -- L64 -- the process probe spawns nothing it has not pinned -------------
# Neither arm of `processTable` is reachable from a test on the other platform, so
# the discipline is scanned rather than executed. It is scanned as a RULE over the
# function body, not as two named sites: a third arm added later is covered without
# editing this check. The POSIX arm pins PATH/LC_ALL/LANG/TZ; the Windows arm must
# pin its own environment for one reason more -- `-NoProfile` does not cover module
# resolution, so `Get-CimInstance` is auto-loaded from whatever `PSModulePath` names,
# and an inherited entry naming a writable directory that holds a `CimCmdlets` module
# is loaded by the real powershell.exe.
PROBE_FN="$(awk '/^function processTable\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$TRAIL_MJS")"
PROBE_SPAWNS="$(printf '%s\n' "$PROBE_FN" | grep -c 'execFileSync(' || true)"
PROBE_PINNED="$(printf '%s\n' "$PROBE_FN" | grep -c 'env: {' || true)"
if [ "$PROBE_SPAWNS" -ge 2 ] && [ "$PROBE_SPAWNS" = "$PROBE_PINNED" ]; then
  check "L64 every spawn in the process probe carries a pinned environment ($PROBE_PINNED/$PROBE_SPAWNS)" PASS
else
  check "L64 every spawn in the process probe carries a pinned environment (spawns=$PROBE_SPAWNS pinned=$PROBE_PINNED)" FAIL
fi
# Control: the same expression measured against a copy whose Windows pin is gone. A
# scan that still reports agreement there is inert and would stay green through the
# exact defect it names. The Windows pin is the one `env: {` alone on its line.
L64_CTRL="$(mktemp -t zensu-l64-XXXXXX)"
sed 's/^        env: {$/        unpinned: {/' "$TRAIL_MJS" > "$L64_CTRL"
CTRL_FN="$(awk '/^function processTable\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$L64_CTRL")"
CTRL_SPAWNS="$(printf '%s\n' "$CTRL_FN" | grep -c 'execFileSync(' || true)"
CTRL_PINNED="$(printf '%s\n' "$CTRL_FN" | grep -c 'env: {' || true)"
rm -f "$L64_CTRL"
if [ "$CTRL_SPAWNS" -ge 2 ] && [ "$CTRL_SPAWNS" != "$CTRL_PINNED" ]; then
  check "L64-control an unpinned spawn is detected, so L64 is not inert (spawns=$CTRL_SPAWNS pinned=$CTRL_PINNED)" PASS
else
  check "L64-control an unpinned spawn is detected (spawns=$CTRL_SPAWNS pinned=$CTRL_PINNED)" FAIL
fi
# `%SystemRoot%` being absolute is a SHAPE test, never a trust test: `D:\evil` is
# absolute too, and this process's environment is set by whatever launched it. The
# resolved interpreter is therefore stat'd BEFORE it is spawned, and a non-file
# degrades to the empty table rather than executing. Order is the whole property --
# a stat after the spawn would read the same in a diff and prove nothing.
PROBE_STAT_AT="$(printf '%s\n' "$PROBE_FN" | grep -n 'fs\.lstatSync(shell)' | head -1 | cut -d: -f1)"
PROBE_SPAWN_AT="$(printf '%s\n' "$PROBE_FN" | grep -n 'execFileSync(shell' | head -1 | cut -d: -f1)"
if [ -n "$PROBE_STAT_AT" ] && [ -n "$PROBE_SPAWN_AT" ] && [ "$PROBE_STAT_AT" -lt "$PROBE_SPAWN_AT" ] \
  && printf '%s\n' "$PROBE_FN" | grep -q 'shellStat\.isFile()'; then
  check "L64a the Windows interpreter is stat'd before it is spawned, and a non-file degrades" PASS
else
  check "L64a the Windows interpreter is stat'd before it is spawned (stat@$PROBE_STAT_AT spawn@$PROBE_SPAWN_AT)" FAIL
fi
# And the module path is DERIVED from the same resolved root rather than inherited --
# pinning an environment that copies the caller's PSModulePath through would satisfy
# L64 while leaving the load channel open.
if printf '%s\n' "$PROBE_FN" | grep -q "PSModulePath: path.join(root," \
  && ! printf '%s\n' "$PROBE_FN" | grep -q 'PSModulePath: process\.env'; then
  check "L64b PSModulePath is derived from the resolved root, never inherited" PASS
else
  check "L64b PSModulePath is derived from the resolved root, never inherited" FAIL
fi

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
