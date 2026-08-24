#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  ledgerPaths, writeEdge, readEdges, dedupeEdges,
  makeEndpoint, buildEdge as buildLedgerEdge, walkChain, chainRoots,
  readLabels as readLabelsFile, writeLabels, emptyLabels, boundLabel,
  isSafeHostSessionId, EDGE_REFUSALS, boundText, siblingLedgerVersions,
  LEDGER_SCHEMA_VERSION,
} from './session-lineage-v1.mjs';

const HOME = os.homedir();
// The config root is resolved, not hardcoded: an instance started with its own
// CLAUDE_CONFIG_DIR writes its registry, transcripts AND lineage ledger there, so
// a reader pinned to ~/.claude reports "no sessions found" for that user and — far
// worse once the ledger exists — writes edges into a root nobody reads back.
// These stay `let` because `--config-dir` is only known after parseArgs; every
// consumer is a function the dispatcher calls, so `resolveRoots()` below runs first.
// The derivation lives in ONE place: a second copy at module load would only be
// overwritten, and a root added there and forgotten here reproduces exactly the
// hazard the paragraph above describes.
let CONFIG_ROOT;
let PROJECTS;
let SESSIONS;
let HANDOFFS;
let LEDGER_DIR;
let LABELS_FILE;

function defaultConfigRoot() {
  const env = process.env.CLAUDE_CONFIG_DIR;
  if (env && env.trim()) return path.resolve(env.trim());
  return path.join(HOME, '.claude');
}

function resolveRoots(configDir) {
  CONFIG_ROOT = configDir && configDir.trim() ? path.resolve(configDir.trim()) : defaultConfigRoot();
  PROJECTS = path.join(CONFIG_ROOT, 'projects');
  SESSIONS = path.join(CONFIG_ROOT, 'sessions');
  HANDOFFS = path.join(CONFIG_ROOT, 'handoffs');
  const led = ledgerPaths(CONFIG_ROOT);
  LEDGER_DIR = led.edges;
  LABELS_FILE = led.labels;
}
resolveRoots(null);
// Records that could not be read at all. Counted rather than swallowed: a
// silently short answer is indistinguishable from an idle machine, and the
// skill's own docs route "no sessions found" to a different cause.
let SKIPPED = 0;
// Set from argv before any command runs. `skippedNote()` must consult a
// module-scope flag rather than `opts`: parseArgs can call fail() -> flush()
// while `const opts` is still in its temporal dead zone.
let JSON_MODE = false;
const FULL_READ_LIMIT = 8 * 1024 * 1024;
const HEAD_BYTES = 256 * 1024;
const TAIL_BYTES = 768 * 1024;

function parseArgs(argv) {
  const out = {
    _: [], days: 21, prompts: 12, json: false, all: false, live: false, git: true, repo: null, force: false,
    configDir: null, where: null, diagnose: false, backfill: false, apply: false, record: true, reason: null, self: false,
    daysExplicit: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') out.json = true;
    else if (a === '--all') out.all = true;
    else if (a === '--force') out.force = true;
    else if (a === '--live') out.live = true;
    else if (a === '--no-git') out.git = false;
    else if (a === '--diagnose') out.diagnose = true;
    else if (a === '--backfill') out.backfill = true;
    else if (a === '--apply') out.apply = true;
    else if (a === '--no-record') out.record = false;
    // A real flag, not a positional: parseArgs rejects every unknown `--token`,
    // so reading `--self` off the positional list could never have worked.
    else if (a === '--self') out.self = true;
    else if (a === '--config-dir') out.configDir = stringOperand(a, argv[++i]);
    else if (a === '--where') out.where = stringOperand(a, argv[++i]);
    else if (a === '--reason') out.reason = stringOperand(a, argv[++i]);
    // Both operands are validated. An unvalidated `--prompts` was the worse of
    // the two: `Number("--json")` is NaN, `Math.max(1, NaN)` is NaN, and
    // `slice(-NaN)` is `slice(0)` — the ENTIRE prompt history, with the
    // "(N earlier omitted)" self-report suppressed by the same NaN. The mistake
    // ran towards maximum disclosure and reported nothing.
    else if (a === '--days') { out.days = numericOperand(a, argv[++i]); out.daysExplicit = true; }
    else if (a === '--prompts') out.prompts = numericOperand(a, argv[++i]);
    else if (a === '--repo') out.repo = stringOperand(a, argv[++i]);
    else if (a.startsWith('--')) fail(`unknown flag: ${a}`);
    else out._.push(a);
  }
  return out;
}

function numericOperand(flag, raw) {
  const n = Number(raw);
  if (raw === undefined || raw === '' || !Number.isFinite(n)) fail(`${flag} needs a number (got ${raw === undefined ? 'nothing' : `"${raw}"`})`);
  return n;
}

// Validated for the same reason numericOperand is: an operand swallowed from a
// following flag (`--where --json`) would otherwise become the value silently, and
// for --config-dir that means writing the ledger into a directory named "--json".
function stringOperand(flag, raw) {
  if (raw === undefined || raw === '' || raw.startsWith('--')) {
    fail(`${flag} needs a value (got ${raw === undefined ? 'nothing' : `"${raw}"`})`);
  }
  return raw;
}

function fail(msg, code = 1) {
  flush();
  process.stderr.write(`session-trail: ${msg}\n`);
  process.exit(code);
}

function git(cwd, args) {
  try {
    return execFileSync('git', args, { cwd, encoding: 'utf8', timeout: 8000, stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return null;
  }
}

function dirExists(p) {
  try { return fs.statSync(p).isDirectory(); } catch { return false; }
}

function normSlug(s) {
  return s.replace(/[^A-Za-z0-9]/g, '-');
}

function repoContext(startDir) {
  if (!dirExists(startDir)) return null;
  const common = git(startDir, ['rev-parse', '--git-common-dir']);
  if (!common) return null;
  const abs = path.isAbsolute(common) ? common : path.resolve(startDir, common);
  const root = path.basename(abs) === '.git' ? path.dirname(abs) : abs;
  const worktrees = new Set([root]);
  const listed = git(startDir, ['worktree', 'list', '--porcelain']) || '';
  for (const line of listed.split('\n')) {
    if (line.startsWith('worktree ')) worktrees.add(line.slice(9).trim());
  }
  return { root, name: path.basename(root), worktrees };
}

function nearestRepoRoot(cwd, memo) {
  if (memo.has(cwd)) return memo.get(cwd);
  let dir = cwd;
  for (let i = 0; i < 12; i++) {
    const dotGit = path.join(dir, '.git');
    let st;
    try { st = fs.statSync(dotGit); } catch { st = null; }
    if (st) {
      const root = st.isDirectory() ? dir : mainRootFromGitFile(dotGit) || dir;
      memo.set(cwd, root);
      return root;
    }
    const up = path.dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  memo.set(cwd, null);
  return null;
}

function mainRootFromGitFile(gitFile) {
  let txt;
  try { txt = fs.readFileSync(gitFile, 'utf8'); } catch { return null; }
  const m = /^gitdir:\s*(.+)$/m.exec(txt);
  if (!m) return null;
  const gitdir = m[1].trim();
  const idx = gitdir.indexOf(`${path.sep}.git${path.sep}worktrees${path.sep}`);
  if (idx === -1) return null;
  return gitdir.slice(0, idx);
}

// The desktop store's top-level directory is the ACCOUNT UUID, not a "desktop
// instance". Measured 2026-08-21 on macOS, three independent ways: one directory
// equalled `oauthAccount.accountUuid` in ~/.claude.json; another equalled
// `lastKnownAccountUuid` in Claude/config.json AND held the running session's own
// record; and ant-device-registry.json — a per-account artifact — is keyed on
// exactly that set of UUIDs. So the account that owns a session IS derivable, which
// the SKILL's blanket "no account provenance exists" claim got wrong: that claim
// holds for the registry and the transcripts, and only for those.
//
// ONLY the macOS path is verified. The Windows and Linux candidates below are
// INFERRED from the usual Electron userData locations and have never been observed;
// `lineage --diagnose` prints every probe so a wrong guess is visible in one command,
// and $ZENSU_CCD_STORE overrides the list without a code change.
function ccdStoreCandidates() {
  const out = [];
  // An explicit override is AUTHORITATIVE, not merely first: falling through to a
  // guessed path when the named one is absent would silently attribute sessions to
  // accounts read out of a store the operator did not choose, and the fallback would
  // be invisible in every output except --diagnose.
  const env = process.env.ZENSU_CCD_STORE;
  if (env && env.trim()) return [{ source: 'ZENSU_CCD_STORE (authoritative)', dir: path.resolve(env.trim()) }];
  out.push({ source: 'macOS (verified)', dir: path.join(HOME, 'Library', 'Application Support', 'Claude', 'claude-code-sessions') });
  const appData = process.env.APPDATA;
  if (appData && appData.trim()) out.push({ source: 'Windows APPDATA (unverified)', dir: path.join(appData.trim(), 'Claude', 'claude-code-sessions') });
  const localAppData = process.env.LOCALAPPDATA;
  if (localAppData && localAppData.trim()) out.push({ source: 'Windows LOCALAPPDATA (unverified)', dir: path.join(localAppData.trim(), 'Claude', 'claude-code-sessions') });
  const xdg = process.env.XDG_CONFIG_HOME;
  if (xdg && xdg.trim()) out.push({ source: 'XDG_CONFIG_HOME (unverified)', dir: path.join(xdg.trim(), 'Claude', 'claude-code-sessions') });
  out.push({ source: 'Linux ~/.config (unverified)', dir: path.join(HOME, '.config', 'Claude', 'claude-code-sessions') });
  return out;
}

function ccdStore() {
  for (const c of ccdStoreCandidates()) {
    if (dirExists(c.dir)) return c;
  }
  return null;
}
let CCD_CACHE = null;

function ccdIndex() {
  if (CCD_CACHE) return CCD_CACHE;
  const map = new Map();
  CCD_CACHE = map;
  const store = ccdStore();
  if (!store) return map;
  const walk = (dir, depth, accountUuid) => {
    if (depth > 3) return;
    let es;
    try { es = fs.readdirSync(dir, { withFileTypes: true }); } catch { SKIPPED += 1; return; }
    for (const e of es) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) { walk(p, depth + 1, accountUuid || e.name); continue; }
      if (!/^local_.*\.json$/.test(e.name)) continue;
      let o;
      try { o = JSON.parse(fs.readFileSync(p, 'utf8')); } catch { continue; }
      if (!o || !o.cliSessionId) continue;
      map.set(o.cliSessionId, {
        accountUuid: accountUuid || null,
        archived: o.isArchived === true,
        title: o.title || null,
        model: o.model || null,
        effort: o.effort || null,
        permissionMode: o.permissionMode || null,
        lastFocusedAt: o.lastFocusedAt || null,
      });
    }
  };
  walk(store.dir, 0, null);
  return map;
}

function appTag(app) {
  if (!app) return '';
  const acct = app.accountUuid ? accountLabel(app.accountUuid) : 'account ?';
  return `${app.archived ? '[ARCHIVED] ' : ''}${acct}`;
}

// ── Account labels ──────────────────────────────────────────────────────────
// The account UUID is derivable; a human-readable name for it is not — the only
// email on disk is `oauthAccount.emailAddress` in ~/.claude.json, and that names
// whichever account wrote the file LAST, not the account of any given session. So
// the label is user-supplied and purely cosmetic: the GROUPING is automatic and
// cannot be typo'd, the label only makes it readable.
let LABEL_CACHE = null;

let LABELS_UNREADABLE = false;
let LABELS_SCHEMA_MISMATCH = false;

function readLabels() {
  if (LABEL_CACHE) return LABEL_CACHE;
  const { labels, unreadable, schemaMismatch } = readLabelsFile(LABELS_FILE);
  LABELS_UNREADABLE = unreadable;
  LABELS_SCHEMA_MISMATCH = !!schemaMismatch;
  if (unreadable || schemaMismatch) SKIPPED += 1;
  LABEL_CACHE = labels;
  return LABEL_CACHE;
}

// The uuid prefix stays beside the label, never instead of it: two accounts
// sharing a label must still be distinguishable in a rendered chain.
function accountLabel(key) {
  if (!key) return 'account ?';
  const l = Object.prototype.hasOwnProperty.call(readLabels().accounts, key) ? readLabels().accounts[key] : undefined;
  return l ? `${l} (${String(key).slice(0, 8)})` : `account ${String(key).slice(0, 8)}`;
}

function windowLabel(appPid) {
  const w = readLabels().windows;
  const l = Object.prototype.hasOwnProperty.call(w, String(appPid)) ? w[String(appPid)] : undefined;
  return l ? `window ${appPid} (${l})` : `window pid ${appPid}`;
}

// ── Window identity ─────────────────────────────────────────────────────────
// A second, INDEPENDENT route to "which window": each account runs its own
// Claude.app main process, and a CLI session is a descendant of exactly one of
// them (measured 2026-08-21: 13084 -> 13083 Contents/Helpers/disclaimer -> 79209
// Claude.app/Contents/MacOS/Claude). This matters because the desktop store is the
// ONLY source of accountUuid, and its path outside macOS is unverified — when the
// store is unreachable, this still groups sessions by window correctly.
let PROC_TABLE = null;

// A probe carrier for the ancestry walk: the suite feeds a synthetic table on stdin
// and reads back the pid this rule selects. It exists because the live process tree
// cannot be arranged into the shapes that matter (a helper hop between the session
// and the app, a chain with no Claude ancestor, the hop bound) from a test.
function windowProbe(raw) {
  let spec;
  try { spec = JSON.parse(raw); } catch { return { error: 'probe input is not JSON' }; }
  if (!spec || !Array.isArray(spec.table) || !Number.isFinite(spec.pid)) {
    return { error: 'probe needs { pid: <number>, table: [{ pid, ppid, comm }] }' };
  }
  const table = new Map();
  for (const row of spec.table) {
    if (!row || !Number.isFinite(row.pid) || !Number.isFinite(row.ppid)) continue;
    table.set(row.pid, { ppid: row.ppid, comm: String(row.comm || '') });
  }
  return { appPid: windowOf(spec.pid, table) };
}

function processTable() {
  if (PROC_TABLE) return PROC_TABLE;
  PROC_TABLE = new Map();
  // One table read rather than a `ps` per ancestor: the walk is at most a handful
  // of hops, but on Windows each hop would be a separate PowerShell start-up.
  let out = '';
  try {
    if (process.platform === 'win32') {
      // An absolute root only: a relative %SystemRoot% would make the interpreter
      // path relative to the process cwd, which is the repository directory. Absolute
      // is a SHAPE test and not a trust test, so the resolved interpreter is stat'd
      // before it is spawned — `D:\\evil` is absolute too, and this process's
      // environment is set by whatever launched it.
      const sysRoot = process.env.SystemRoot;
      const root = sysRoot && path.isAbsolute(sysRoot) ? sysRoot : 'C:\\Windows';
      const shell = path.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
      let shellStat;
      try { shellStat = fs.lstatSync(shell); } catch { return PROC_TABLE; }
      if (!shellStat.isFile()) return PROC_TABLE;
      // The environment is pinned here for the same reason it is pinned on the POSIX
      // arm below, and one reason more: `-NoProfile` does not cover module resolution,
      // so `Get-CimInstance` is auto-loaded from whatever `PSModulePath` names. An
      // inherited entry pointing at a writable directory holding a `CimCmdlets` module
      // is loaded by the real powershell.exe. Degrading here costs only the
      // window-grouping route, which every caller already treats as optional.
      out = execFileSync(shell, ['-NoProfile', '-NonInteractive', '-Command',
        'Get-CimInstance Win32_Process | ForEach-Object { "$($_.ProcessId)`t$($_.ParentProcessId)`t$($_.Name)" }'],
      { encoding: 'utf8',
        timeout: 8000,
        stdio: ['ignore', 'pipe', 'ignore'],
        env: {
          SystemRoot: root,
          PSModulePath: path.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'Modules'),
          PATHEXT: '.COM;.EXE;.BAT;.CMD',
          TEMP: process.env.TEMP || path.join(root, 'Temp'),
          TMP: process.env.TMP || path.join(root, 'Temp'),
        } });
    } else {
      // Absolute path and a pinned environment, as hooks/lib/session-control-core-v1.js
      // does for the same probe: the argument vector is a fixed literal, so the only
      // exposure left is program resolution and an inherited environment.
      out = execFileSync('/bin/ps', ['-Ao', 'pid=,ppid=,comm='], {
        encoding: 'utf8', timeout: 8000, stdio: ['ignore', 'pipe', 'ignore'],
        env: { PATH: '/usr/bin:/bin', LC_ALL: 'C', LANG: 'C', TZ: 'UTC' },
      });
    }
  } catch { return PROC_TABLE; }
  for (const line of out.split('\n')) {
    const t = line.trim();
    if (!t) continue;
    const m = process.platform === 'win32'
      ? t.split('\t')
      : /^(\d+)\s+(\d+)\s+(.*)$/.exec(t)?.slice(1);
    if (!m || m.length < 3) continue;
    const pid = Number(m[0]);
    const ppid = Number(m[1]);
    if (!Number.isFinite(pid) || !Number.isFinite(ppid)) continue;
    PROC_TABLE.set(pid, { ppid, comm: String(m[2]).trim() });
  }
  return PROC_TABLE;
}

// The HIGHEST ancestor whose command names Claude, excluding the CLI process
// itself. Highest rather than nearest: the chain passes through a helper
// (`Contents/Helpers/disclaimer`) that also matches, and it is the app process at
// the top that owns the window. A session with no such ancestor — a terminal or
// IDE launch — answers null, which is the honest result, not a fallback to itself.
// The table is a PARAMETER with a default rather than a hidden read, because it is
// the only seam this walk has. Every fixture spawns node from a shell, so no
// ancestor matches /claude/i and this function returns null throughout the suite --
// which means replacing its body with `return null` left every behavioural check
// green while SKILL.md sold the ancestry route as the fallback for a missing
// desktop store. `processTable` is absolute-path and pinned by design, so a PATH
// shim cannot stand in for it; injecting the table is what makes the selection
// rule -- highest match, not nearest -- observable at all.
function windowOf(pid, table = processTable()) {
  if (!table || !table.size || !Number.isFinite(pid)) return null;
  let cur = table.get(pid);
  let found = null;
  for (let hop = 0; hop < 12 && cur && cur.ppid > 1; hop += 1) {
    const next = table.get(cur.ppid);
    if (!next) break;
    if (/claude/i.test(next.comm)) found = cur.ppid;
    cur = next;
  }
  return found;
}

// ── Lineage ledger ──────────────────────────────────────────────────────────
// The schema, the store layout and the chain walk live in session-lineage-v1.mjs.
// These wrappers only bind the module to this process's resolved roots and to the
// module-scope SKIPPED counter, so the record shape has exactly one owner.
let LEDGER_DIR_ERROR = null;
let LEDGER_SCHEMA_NEWER = false;
// Per-record refusals, kept apart from the whole-directory failure: they are the
// narrow half of the same hazard -- one dropped record is one pair missing from
// the duplicate guard -- and the remedies differ.
let LEDGER_REFUSED = 0;

function ledgerWrite(edge) {
  return writeEdge(LEDGER_DIR, edge, Date.now(), CONFIG_ROOT);
}

// A refused record is COUNTED, never dropped silently, and a directory that could
// not be read at all is reported separately: a lineage that quietly loses a link
// reads exactly like a session nobody ever took over, which is the one wrong
// answer this whole feature exists to prevent.
function ledgerRead() {
  const { edges, refused, directoryError } = readEdges(LEDGER_DIR);
  LEDGER_DIR_ERROR = directoryError;
  LEDGER_REFUSED = refused.length;
  if (directoryError) SKIPPED += 1;
  for (const r of refused) {
    SKIPPED += 1;
    if (r.reason === EDGE_REFUSALS.SCHEMA_NEWER) LEDGER_SCHEMA_NEWER = true;
  }
  return edges;
}


// ── Edge construction ───────────────────────────────────────────────────────
// The running session identifies itself from its own environment rather than by
// guessing from the registry: CLAUDE_PID and CLAUDE_CODE_SESSION_ID are set for
// every session, and CLAUDE_CODE_HOST_SESSION_ID is the desktop record's file name
// — the direct join to this session's own account.
function selfIdentity() {
  const pid = Number(process.env.CLAUDE_PID);
  const sessionId = (process.env.CLAUDE_CODE_SESSION_ID || '').trim() || null;
  const hostSessionId = (process.env.CLAUDE_CODE_HOST_SESSION_ID || '').trim() || null;
  let accountUuid = null;
  if (sessionId) {
    const app = ccdIndex().get(sessionId);
    if (app) accountUuid = app.accountUuid;
  }
  if (!accountUuid && hostSessionId) accountUuid = accountForHostSession(hostSessionId);
  const cwd = process.cwd();
  const wt = (dirExists(cwd) && worktreeRoot(cwd)) || cwd;
  return makeEndpoint({
    sessionId,
    accountUuid,
    appPid: Number.isFinite(pid) ? windowOf(pid) : null,
    pid: Number.isFinite(pid) ? pid : null,
    cwd,
    worktree: wt,
    branch: git(wt, ['rev-parse', '--abbrev-ref', 'HEAD']),
    title: null,
  });
}

// The desktop record is keyed on cliSessionId, so a session whose transcript this
// tool cannot see is invisible to ccdIndex(). CLAUDE_CODE_HOST_SESSION_ID names the
// record file directly, which is the one lookup that does not need the transcript.
function accountForHostSession(hostSessionId) {
  // Refused before it becomes a path component: `..` normalises out of the store,
  // and because the probe returns the first matching account directory, any
  // always-present path would make one account answer for every session — and
  // that answer is then persisted as provenance.
  if (!isSafeHostSessionId(hostSessionId)) return null;
  const store = ccdStore();
  if (!store) return null;
  const want = `${hostSessionId}.json`;
  let accounts;
  try { accounts = fs.readdirSync(store.dir, { withFileTypes: true }); } catch { SKIPPED += 1; return null; }
  for (const a of accounts) {
    if (!a.isDirectory()) continue;
    const accountDir = path.join(store.dir, a.name);
    let workspaces;
    try { workspaces = fs.readdirSync(accountDir, { withFileTypes: true }); } catch { continue; }
    for (const w of workspaces) {
      if (!w.isDirectory()) continue;
      try {
        if (fs.existsSync(path.join(accountDir, w.name, want))) return a.name;
      } catch { /* keep probing */ }
    }
  }
  return null;
}

function endpointFromRow(row) {
  const pid = row && row.live && Number.isFinite(row.live.pid) ? row.live.pid : null;
  return makeEndpoint({
    sessionId: row && row.sessionId,
    accountUuid: (row && row.app && row.app.accountUuid) || null,
    appPid: pid ? windowOf(pid) : null,
    pid,
    cwd: row && row.cwd,
    worktree: row && row.wt,
    branch: row && row.branch,
    title: row && row.title,
  });
}

// `workRoot` is the HANDED-OVER work, never the recording process's directory.
// The documented takeover route runs from a window in a different repo, so
// deriving the repo from the recorder filed the edge under the taker's repo and
// made the default, repo-scoped `lineage` render nothing where the work lives.
// `at` is a PARAMETER for the backfill path's sake. `recordedAt` is the sole ordering
// key in four places -- walkChain's branch preference, dedupeEdges' survivor,
// readEdges' display order, and the --where leaf -- so stamping a reconstructed
// handover with the moment `--apply` ran makes every guess newer than every
// measurement BY CONSTRUCTION, and one backfill then wins each of those four
// decisions against records that were actually observed. A measured takeover keeps
// the clock; a guess is stamped with the instant it is guessing ABOUT.
function buildEdge(fromRow, to, reason, recordedBy, inferred, at = new Date().toISOString()) {
  return buildLedgerEdge({
    from: endpointFromRow(fromRow),
    to,
    workRoot: (fromRow && fromRow.wt) || to.worktree || null,
    repoRootOf: (root) => nearestRepoRoot(root, new Map()),
    reason,
    recordedBy,
    inferred,
    at,
  });
}

function liveState(sessionId, live) {
  return live.has(sessionId) ? 'LIVE' : 'not running';
}

function endpointLabel(ep) {
  if (ep.accountUuid) return accountLabel(ep.accountUuid);
  if (ep.appPid) return windowLabel(ep.appPid);
  return 'account unknown';
}

function liveRegistry() {
  const map = new Map();
  if (!dirExists(SESSIONS)) return map;
  let regFiles;
  try { regFiles = fs.readdirSync(SESSIONS); } catch { SKIPPED += 1; return map; }
  for (const f of regFiles) {
    if (!f.endsWith('.json')) continue;
    let o;
    try { o = JSON.parse(fs.readFileSync(path.join(SESSIONS, f), 'utf8')); } catch { continue; }
    if (!o || !o.sessionId || !o.pid) continue;
    let alive = false;
    try { process.kill(o.pid, 0); alive = true; } catch (e) { alive = e && e.code === 'EPERM'; }
    if (!alive) continue;
    const prev = map.get(o.sessionId);
    if (!prev || (o.startedAt || 0) > (prev.startedAt || 0)) map.set(o.sessionId, o);
  }
  return map;
}

// Returns the text AND the two facts only this function can know: whether the
// read was complete, and where the tail segment starts inside the returned
// string. Both were previously re-derived by the caller from `size`, and one of
// those re-derivations now gates a verdict — a second truncation path added here
// would otherwise leave the caller asserting a full read it never got.
function readTranscript(file, size) {
  if (size <= FULL_READ_LIMIT) return { text: fs.readFileSync(file, 'utf8'), full: true, tailOffset: 0 };
  const fd = fs.openSync(file, 'r');
  try {
    const head = Buffer.alloc(HEAD_BYTES);
    fs.readSync(fd, head, 0, HEAD_BYTES, 0);
    const tail = Buffer.alloc(TAIL_BYTES);
    fs.readSync(fd, tail, 0, TAIL_BYTES, size - TAIL_BYTES);
    const headText = head.toString('utf8');
    return { text: `${headText}\n${tail.toString('utf8')}`, full: false, tailOffset: headText.length + 1 };
  } finally {
    fs.closeSync(fd);
  }
}

function lastMatch(text, re) {
  let m, last = null;
  re.lastIndex = 0;
  while ((m = re.exec(text)) !== null) last = m[1];
  return last;
}

function lastValidBranch(text) {
  const re = /"gitBranch":"((?:[^"\\]|\\.)*)"/g;
  let m;
  let last = null;
  while ((m = re.exec(text)) !== null) {
    const b = m[1];
    if (!b || b === 'HEAD') continue;
    last = b;
  }
  return last;
}

function firstMatch(text, re) {
  re.lastIndex = 0;
  const m = re.exec(text);
  return m ? m[1] : null;
}

const WT_MEMO = new Map();
function worktreeRoot(cwd) {
  if (WT_MEMO.has(cwd)) return WT_MEMO.get(cwd);
  let dir = cwd;
  for (let i = 0; i < 12; i++) {
    if (fs.existsSync(path.join(dir, '.git'))) { WT_MEMO.set(cwd, dir); return dir; }
    const up = path.dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  WT_MEMO.set(cwd, null);
  return null;
}

function collectTyped(text, type) {
  const needle = `"type":"${type}"`;
  const out = [];
  for (const line of text.split('\n')) {
    if (line.indexOf(needle) === -1) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    if (o && o.type === type) out.push(o);
  }
  return out;
}

function scrub(t) {
  return t
    .replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '')
    .replace(/<command-message>[\s\S]*?<\/command-message>/g, '')
    .trim();
}

const MACHINE_TAG = /^<(task-notification|local-command-stdout|local-command-out|local-command-caveat|bash-input|bash-stdout|user-prompt-submit-hook|ide_|new_file_contents|function_results|tool_use_error)/;
const MACHINE_PREFIX = [
  'Base directory for this skill:',
  'Stop hook feedback:',
  'PreToolUse:',
  'PostToolUse:',
  'Caveat: The messages below were generated by the user',
];
const SLASH_TAG = /<command-name>([^<]*)<\/command-name>/;
const BARE_SLASH = /^\/[A-Za-z0-9][A-Za-z0-9:_-]{1,60}\s*$/;
const COMPACTED = 'This session is being continued from a previous conversation';

function extractPrompts(text) {
  const out = [];
  const seen = new Set();
  const push = (at, raw) => {
    let t = scrub(String(raw || ''));
    if (!t) return;
    const slash = SLASH_TAG.exec(t);
    if (slash) t = `[slash] ${slash[1].trim()}`;
    else if (BARE_SLASH.test(t)) t = `[slash] ${t.trim()}`;
    else if (t.startsWith(COMPACTED)) t = `[compaction summary] ${t.slice(COMPACTED.length).replace(/^[.\s]*/, '')}`;
    if (MACHINE_TAG.test(t)) return;
    if (MACHINE_PREFIX.some((p) => t.startsWith(p))) return;
    if (t.startsWith('[Request interrupted')) return;
    if (t.startsWith('Caveman')) return;
    const key = t.slice(0, 160);
    if (seen.has(key)) return;
    seen.add(key);
    out.push({ at, text: t });
  };
  for (const line of text.split('\n')) {
    if (line.indexOf('"type":"queue-operation"') !== -1) {
      let o; try { o = JSON.parse(line); } catch { continue; }
      if (o && o.operation === 'enqueue') push(o.timestamp, o.content);
      continue;
    }
    if (line.indexOf('"type":"user"') === -1) continue;
    if (line.indexOf('"toolUseResult"') !== -1) continue;
    if (line.indexOf('"isSidechain":true') !== -1) continue;
    let o; try { o = JSON.parse(line); } catch { continue; }
    if (!o || o.type !== 'user') continue;
    const c = o.message && o.message.content;
    const t = typeof c === 'string'
      ? c
      : Array.isArray(c) ? c.filter((x) => x && x.type === 'text').map((x) => x.text).join('\n') : '';
    push(o.timestamp, t);
  }
  out.sort((a, b) => String(a.at || '').localeCompare(String(b.at || '')));
  return out;
}

function extractAssistantTail(text, n) {
  const lines = text.split('\n');
  const out = [];
  for (let i = lines.length - 1; i >= 0 && out.length < n; i--) {
    const line = lines[i];
    if (line.indexOf('"type":"assistant"') === -1) continue;
    if (line.indexOf('"isSidechain":true') !== -1) continue;
    if (line.indexOf('"isApiErrorMessage":true') !== -1) continue;
    let o; try { o = JSON.parse(line); } catch { continue; }
    const c = o && o.message && o.message.content;
    if (!Array.isArray(c)) continue;
    const t = c.filter((x) => x && x.type === 'text').map((x) => x.text).join('\n').trim();
    if (t) out.push({ at: o.timestamp, text: t });
  }
  return out.reverse();
}

function isRealTurn(line) {
  if (line.indexOf('"isSidechain":true') !== -1) return false;
  if (line.indexOf('"isApiErrorMessage":true') !== -1) return false;
  if (line.indexOf('"type":"assistant"') !== -1) return true;
  if (line.indexOf('"type":"user"') !== -1 && line.indexOf('"toolUseResult"') === -1) return true;
  return false;
}

// `fromOffset` is the tail seam, for the same reason its two siblings take it:
// `laterTurns` — and therefore `final`, which decides STALLED vs RECOVERED and
// routes the whole usage-limit handover — is counted by walking forward from the
// error record. Across a spliced head+tail that walk crosses an unread gap, so a
// head-resident error would be graded against tail records that are not its
// successors. Scanning the tail slice alone keeps the count over contiguous text;
// an error that falls outside it is simply not reported, which is the honest
// answer for a read that never saw it.
function extractStopCause(text, fromOffset = 0) {
  if (fromOffset > 0) return extractStopCauseIn(text.slice(fromOffset));
  return extractStopCauseIn(text);
}

function extractStopCauseIn(text) {
  if (text.indexOf('"isApiErrorMessage":true') === -1) return null;
  const lines = text.split('\n');
  let errIdx = -1;
  let err = null;
  for (let i = lines.length - 1; i >= 0 && errIdx === -1; i--) {
    if (lines[i].indexOf('"isApiErrorMessage":true') === -1) continue;
    let o;
    try { o = JSON.parse(lines[i]); } catch { continue; }
    if (!o || o.isApiErrorMessage !== true) continue;
    errIdx = i;
    err = o;
  }
  if (errIdx === -1) return null;
  let laterTurns = 0;
  let lastTurnAt = null;
  for (let i = errIdx + 1; i < lines.length; i++) {
    if (!lines[i] || !isRealTurn(lines[i])) continue;
    laterTurns++;
    const m = /"timestamp":"([^"]+)"/.exec(lines[i]);
    if (m) lastTurnAt = m[1];
  }
  const c = err.message && err.message.content;
  const msg = typeof c === 'string'
    ? c
    : Array.isArray(c) ? c.filter((x) => x && x.type === 'text').map((x) => x.text).join(' ') : '';
  // ALL FOUR transcript-derived fields are bounded here, not just `message`.
  // Every one of them is interpolated raw into the takeover brief's `## Source`
  // block, and a JSON-parsed value can hold a real newline — so bounding only the
  // obvious one leaves three siblings able to break a line in a persisted file.
  // `oneLine` is not available at this point in the file, and would be the wrong
  // tool anyway: these are short identifiers, not prose.
  // Same class as boundText, not `\s` alone: these four land in a PERSISTED file,
  // and ESC is exactly what `\s` lets through. Not boundText itself — that returns
  // null on empty, and the `?? null` below depends on `undefined` passing through.
  const flat = (v, n) => (v === null || v === undefined ? v : String(v).replace(/[\p{Cc}\p{Cf}\u2028\u2029\s]+/gu, ' ').trim().slice(0, n));
  return {
    error: flat(err.error, 64) || 'api_error',
    // `?? null` so the key is always present: `flat` passes `undefined` through,
    // and `JSON.stringify` would then omit these two entirely, giving a machine
    // consumer a different `stopCause` shape per record.
    status: flat(err.apiErrorStatus, 16) ?? null,
    at: flat(err.timestamp, 40) ?? null,
    message: flat(msg, 2000) || '',
    final: laterTurns === 0,
    laterTurns,
    resumedUntil: lastTurnAt,
  };
}

// A stop reason travels from a third-party transcript into the verdict's reason
// string, which is printed, embedded in both briefs, and persisted outside every
// repository — so it is the one transcript-derived value here that a crafted
// record could aim at a reader. Every sibling extractor bounds its text through
// `oneLine`/`clip`; this one bounds by SHAPE instead, because the value is
// supposed to be an enum token. A value outside the shape is treated as absent,
// which resolves to "still working" — the conservative direction.
const STOP_REASON_SHAPE = /^[a-z_]{1,32}$/;

// Whether the process COULD act at all, which the transcript's file mtime cannot
// say. A completed assistant turn means it is waiting for its human. Measured on
// this machine: of 57 idle sessions 51 ended on `end_turn` or `stop_sequence`,
// and so did 4 of 10 sessions written to under three minutes ago — freshness and
// activity are different things. Anything else is treated as a turn in flight,
// including a sidechain record (a subagent is running) and an assistant record
// whose stop reason is null or absent (4 of 7320 sampled): uncertainty resolves
// towards "still working", which costs a question rather than a wrong takeover.
//
// `fromOffset` is where the caller's TAIL segment begins. On a truncated read the
// text is head+tail spliced together, so an unbounded backwards scan that found
// nothing in the tail would silently classify the session from a record at its
// START. Scanning only the tail makes that case return `unknown` instead, which
// is the honest answer: the last turn was not read.
function extractLastTurn(text, fromOffset = 0) {
  const lines = (fromOffset > 0 ? text.slice(fromOffset) : text).split('\n');
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i];
    if (!line) continue;
    if (line.indexOf('"type":"assistant"') === -1 && line.indexOf('"type":"user"') === -1) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    if (o.type !== 'assistant' && o.type !== 'user') continue;
    // An API-error record is not a turn. Skipping it is what keeps a session that
    // died on a rate limit from reading as "a turn is in flight — it is working",
    // which is exactly the session the usage-limit handover exists to take over.
    // `isRealTurn` and `extractAssistantTail` carry the same skip — as a substring
    // test, which cannot tell the FIELD from the same bytes appearing inside an
    // assistant's own text. This one is checked after the parse, so there is one
    // guard rather than two, and a fixture can discriminate it.
    if (o.isApiErrorMessage === true) continue;
    const sidechain = o.isSidechain === true;
    const sr = o.message && o.message.stop_reason;
    const stopReason = typeof sr === 'string' && STOP_REASON_SHAPE.test(sr) ? sr : null;
    const awaiting = o.type === 'assistant' && !sidechain && stopReason !== null && stopReason !== 'tool_use';
    return { kind: awaiting ? 'awaiting-input' : 'in-turn', stopReason, sidechain };
  }
  return { kind: 'unknown', stopReason: null, sidechain: false };
}

// `reliable` is false when the caller only had head+tail of the transcript: the
// depth is an enqueue/dequeue BALANCE, so a dequeue sitting in the unread middle
// leaves a phantom prompt pending forever. A depth derived from a partial read is
// not evidence of anything, and a verdict must not be built on it. The parameter
// carries NO default on purpose — only the reader knows whether it got the whole
// file, and defaulting it would let a future call site assert a completeness it
// never established.
// A partial read is not uniformly blind. Counted over the WHOLE spliced text the
// depth is a balance across an unread gap and proves nothing — but counted over
// the TAIL SLICE alone it is a LOWER BOUND: an enqueue inside the slice whose
// dequeue never follows it inside that same slice is genuinely pending, because
// everything after it was read. So a positive tail-slice depth is evidence and a
// zero one still is not. Without this, every transcript past 8 MB discarded a
// real queued prompt — the one hazard that acts without its human — as "not
// evidence", and reported PROBABLY_FREE for a session about to move on its own.
function extractPendingQueue(text, reliable, tailOffset = 0) {
  if (reliable !== true && tailOffset > 0) {
    const fromTail = scanQueue(text.slice(tailOffset));
    if (fromTail.pending > 0) return { ...fromTail, reliable: true };
    return { pending: 0, last: null, at: null, reliable: false };
  }
  return { ...scanQueue(text), reliable: reliable === true };
}

function scanQueue(text) {
  if (text.indexOf('"type":"queue-operation"') === -1) return { pending: 0, last: null, at: null };
  let depth = 0;
  let last = null;
  let at = null;
  for (const line of text.split('\n')) {
    if (line.indexOf('"type":"queue-operation"') === -1) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    if (o.operation === 'enqueue') {
      depth++;
      last = String(o.content || '').trim();
      at = o.timestamp || null;
    } else if (o.operation === 'dequeue') {
      depth = Math.max(0, depth - 1);
      if (depth === 0) { last = null; at = null; }
    }
  }
  return { pending: depth, last, at };
}

// Both thresholds are re-quoted as prose in SKILL.md's "Verified gotchas" and in
// the PROBABLY_FREE / BUSY rows of its flow-3 verdict table. Changing a number
// here without changing them there leaves the model reading one rule while this
// resolves another; test-session-trail-skill.sh T24 pins the two literals.
const BUSY_IDLE_MIN = 15;
// Under this, nothing about the last record is trusted: a turn that ends between
// two reads would otherwise read as idle while its process is mid-write.
const ACTIVE_GRACE_MIN = 2;

// The verdict is a hazard report, never a permission gate — nothing here refuses
// anything, and nothing in this script enforces exclusivity, because none exists
// (no lock in the gitdir; a registry entry is a registration, not a claim).
//
// `force` and the measurement are ORTHOGONAL and stay separate fields. `level` is
// what a reader should act on; `measuredLevel` is what was actually observed and
// never changes; `authorized` says only that `--force` was on this invocation.
// Collapsing them would hide the hazard from every machine consumer the moment
// someone passed the flag.
//
// The wording is deliberately provenance, not conclusion. This script cannot see
// a user: `--force` is a token its caller types, so "the user authorized this" is
// a claim it has no evidence for — and that sentence gets persisted into briefs
// which tell the next instance never to ask again.
function activityVerdict(r, force = false) {
  const v = measuredVerdict(r);
  // The flag alone is not enough: the row must BE the one a selector resolved.
  // That is what makes the survey rule structural — a command that resolves no
  // selector cannot authorize any row, whatever it passes, so a future
  // selector-less command cannot reintroduce the machine-wide stamp by calling
  // the wrong helper.
  const selected = SELECTED_SESSION_ID !== null && r.sessionId === SELECTED_SESSION_ID;
  const base = { ...v, measuredLevel: v.level, measuredReason: v.reason, authorized: force === true && selected };
  if (v.level !== 'BUSY' || !base.authorized) return base;
  return {
    ...base,
    level: 'CONTESTED',
    reason: `${v.reason} --force was passed on this invocation, which records an authorization this script cannot verify.`,
  };
}

// A command that takes no selector cannot carry an authorization: the user
// approved ONE session, and rendering that against every busy row on the machine
// turns one go/no-go into a blanket one. The rule belongs here, at the verdict
// boundary, rather than in each renderer — applying it to the text path alone
// left `list --json --force` stamping CONTESTED on every row while the visible
// output looked correct.
function surveyVerdict(r) {
  return activityVerdict(r, false);
}

// The doctrine, with ONE owner. It was hand-copied into three renderers with
// different wording and different coverage, so a level could be emitted with no
// advice attached and every check stayed green. Keyed by level; every level
// `measuredVerdict` or `activityVerdict` can emit must have an entry, which
// test-session-trail-skill.sh T18 asserts against the emitted set.
const ADVICE = {
  FREE: ['Nothing holds this worktree. Take it over.'],
  PROBABLY_FREE: ['Proceed, but tell the user not to type in that window, and check for dev servers it may still own.'],
  BUSY: [
    'This is a hazard report, not a refusal. State it to the user in one line, take a single',
    'go/no-go, and on yes re-run with --force to record the authorization and take it over.',
  ],
  CONTESTED: [
    'Authorized. Take it over, name the window the user must not type in, and check whether',
    'it still owns dev servers or ports.',
  ],
};

function measuredVerdict(r) {
  // FLOOR, not round: `Math.round` crosses each threshold half a minute early —
  // a transcript touched 95 s ago rounded to 2 and escaped the 2-minute grace
  // window the docs promise, and 14 min 30 s rounded to 15 and read as "silent
  // ≥15 min". An age is only past a threshold once it has actually passed it.
  const idleMin = Math.floor((Date.now() - r.mtime) / 60000);
  const q = r.queue || { pending: 0, at: null, reliable: false };
  const turn = r.lastTurn || { kind: 'unknown', stopReason: null };
  const qAt = q.at ? Date.parse(q.at) : NaN;
  // An unreadable enqueue timestamp counts as fresh: a real queued prompt is a
  // genuine hazard, and over-reporting it now costs one question, not a refusal.
  const queueFresh = !Number.isFinite(qAt) || (Date.now() - qAt) / 60000 < BUSY_IDLE_MIN;
  // `q.reliable === true` is DEFENCE IN DEPTH and currently unreachable as a
  // discriminator: since the tail-slice change, `extractPendingQueue` only ever
  // reports a positive depth it can stand behind, so `pending > 0` already
  // implies it. A mutation probe confirmed no fixture bites this conjunct — it is
  // kept rather than removed so a future change to that reader cannot silently
  // reopen the phantom-queue BUSY, and it is documented rather than left looking
  // like a tested guarantee.
  const queueCounts = q.pending > 0 && q.reliable === true && queueFresh;
  // "Nothing is queued" is a positive claim, so it may only be made from a read
  // that could have SEEN a queue. An unreliable read reports its own blindness
  // instead — including when the depth came back zero, which on a partial read
  // means nothing at all.
  let queueNote = q.reliable === true
    ? ' Nothing is queued.'
    : ' Its queue could not be measured — the transcript was read head+tail only.';
  if (q.pending > 0 && !queueCounts) {
    queueNote = q.reliable === true
      ? ` Its recorded queue depth of ${q.pending} last grew ${ago(qAt)} ago — a stale balance, not a waiting prompt.`
      : ` Its recorded queue depth of ${q.pending} comes from a partial head+tail transcript read, so it is not evidence.`;
  }
  if (r.app && r.app.archived) {
    // This branch runs BEFORE the liveness check, so `r.live` can still be set —
    // asserting "its process was stopped" there contradicts the STATUS line
    // printed directly above it, and both end up in the same persisted brief.
    return {
      level: 'FREE',
      idleMin,
      reason: r.live
        ? `the desktop app archived this session, though pid ${r.live.pid} is still registered and alive`
        : 'the desktop app archived this session — its process was stopped',
    };
  }
  if (!r.live) {
    return { level: 'FREE', idleMin, reason: 'no live process holds this worktree' };
  }
  if (queueCounts) {
    // `queueFresh` is true for an unparseable timestamp, so this branch is
    // reachable with qAt === NaN; `ago(NaN)` would render a bare "?".
    const when = Number.isFinite(qAt) ? `, last enqueued ${ago(qAt)} ago,` : ' (enqueue time not recorded)';
    return { level: 'BUSY', idleMin, reason: `pid ${r.live.pid} has ${q.pending} prompt(s) queued${when} and will act on its own.` };
  }
  if (idleMin < ACTIVE_GRACE_MIN) {
    return { level: 'BUSY', idleMin, reason: `pid ${r.live.pid} wrote to its transcript ${idleMin} min ago — too recent to judge, its turn may still be streaming.` };
  }
  if (turn.kind === 'awaiting-input') {
    return {
      level: 'PROBABLY_FREE',
      idleMin,
      reason: `pid ${r.live.pid} ended its last turn (${turn.stopReason}) ${ago(r.mtime)} ago, so it cannot act unless the user types in that window.${queueNote}`,
    };
  }
  if (idleMin < BUSY_IDLE_MIN) {
    // `unknown` is not `in-turn`: no last record was identified, so naming one
    // would assert a measurement that was never taken.
    const why = turn.kind === 'in-turn'
      ? 'and its last record is a turn in flight — it is working.'
      : 'and no assistant or user record could be read from it, so its state is unmeasured.';
    return { level: 'BUSY', idleMin, reason: `pid ${r.live.pid} wrote to its transcript ${idleMin} min ago ${why}` };
  }
  // `awaiting-input` returned above, so this is `in-turn` or `unknown`. Only the
  // second justifies "it cannot act unless the user types": a turn in flight that
  // has gone quiet for hours may still be blocked on a long tool call, and that
  // DOES act without its human when it returns.
  const silent = `pid ${r.live.pid} is alive but has been silent for ${ago(r.mtime)}`;
  return {
    level: 'PROBABLY_FREE',
    idleMin,
    reason: turn.kind === 'in-turn'
      ? `${silent}, and its last record is a turn in flight — most likely abandoned, but it could still be blocked on something that returns.${queueNote}`
      : `${silent} — it cannot act unless the user types in that window.${queueNote}`,
  };
}

function extractTasks(text) {
  if (text.indexOf('"name":"TaskCreate"') === -1) return [];
  const byToolUse = new Map();
  const tasks = new Map();
  const status = new Map();
  for (const line of text.split('\n')) {
    if (!line) continue;
    if (line.indexOf('"name":"TaskCreate"') !== -1) {
      let o; try { o = JSON.parse(line); } catch { continue; }
      const c = o && o.message && o.message.content;
      if (!Array.isArray(c)) continue;
      for (const b of c) if (b && b.type === 'tool_use' && b.name === 'TaskCreate') byToolUse.set(b.id, b.input || {});
      continue;
    }
    if (line.indexOf('"toolUseResult"') !== -1 && line.indexOf('"task"') !== -1) {
      let o; try { o = JSON.parse(line); } catch { continue; }
      const t = o && o.toolUseResult && o.toolUseResult.task;
      if (!t || !t.id) continue;
      const c = o.message && o.message.content;
      const tr = Array.isArray(c) ? c.find((x) => x && x.type === 'tool_result') : null;
      const input = tr && byToolUse.get(tr.tool_use_id);
      tasks.set(String(t.id), {
        id: String(t.id),
        subject: t.subject || (input && input.subject) || '(untitled)',
        description: (input && input.description) || '',
      });
      continue;
    }
    if (line.indexOf('"name":"TaskUpdate"') !== -1) {
      let o; try { o = JSON.parse(line); } catch { continue; }
      const c = o && o.message && o.message.content;
      if (!Array.isArray(c)) continue;
      for (const b of c) {
        if (b && b.type === 'tool_use' && b.name === 'TaskUpdate' && b.input && b.input.taskId) {
          status.set(String(b.input.taskId), b.input.status || 'unknown');
        }
      }
    }
  }
  return [...tasks.values()]
    .map((t) => ({ ...t, status: status.get(t.id) || 'pending' }))
    .sort((a, b) => Number(a.id) - Number(b.id));
}

function extractCompaction(text, limit) {
  const marker = 'This session is being continued from a previous conversation';
  if (text.indexOf(marker) === -1) return null;
  const lines = text.split('\n');
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].indexOf(marker) === -1) continue;
    let o; try { o = JSON.parse(lines[i]); } catch { continue; }
    const c = o && o.message && o.message.content;
    const t = typeof c === 'string'
      ? c
      : Array.isArray(c) ? c.filter((x) => x && x.type === 'text').map((x) => x.text).join('\n') : '';
    if (!t || t.indexOf(marker) === -1) continue;
    const clean = scrub(t);
    return { at: o.timestamp || null, text: clean.length > limit ? `${clean.slice(0, limit)}\n…[truncated]` : clean };
  }
  return null;
}

function extractTouchedFiles(text, limit) {
  const re = /"file_path":"((?:[^"\\]|\\.)*)"/g;
  const counts = new Map();
  let m;
  while ((m = re.exec(text)) !== null) {
    let p;
    try { p = JSON.parse(`"${m[1]}"`); } catch { continue; }
    counts.set(p, (counts.get(p) || 0) + 1);
  }
  return [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, limit).map(([p, n]) => ({ path: p, hits: n }));
}

// A pull-request record is transcript-derived, and both of its fields end up
// somewhere a shape matters: the URL as a markdown link target in two persisted
// briefs, the number in a command line the user is told to run. Anything that
// does not match is dropped rather than rendered — a missing PR row is a smaller
// loss than a link nobody chose.
const PR_URL_SHAPE = /^https:\/\/[A-Za-z0-9._-]+\/[A-Za-z0-9._\-/]+\/(?:pull|merge_requests|-\/merge_requests)\/\d{1,9}$/;
function safePr(rec) {
  const number = String(rec.prNumber ?? '');
  const url = String(rec.prUrl ?? '');
  if (!/^\d{1,9}$/.test(number) || !PR_URL_SHAPE.test(url)) return null;
  return { number, url, repository: oneLine(String(rec.prRepository ?? ''), 120) || null };
}

function summarize(file, size, deep) {
  const read = readTranscript(file, size);
  const text = read.text;
  const cwd = firstMatch(text, /"cwd":"((?:[^"\\]|\\.)*)"/g);
  const cwdLast = lastMatch(text, /"cwd":"((?:[^"\\]|\\.)*)"/g);
  const branch = lastValidBranch(text);
  const lastTs = lastMatch(text, /"timestamp":"([^"]+)"/g);
  const titles = collectTyped(text, 'custom-title');
  const prs = collectTyped(text, 'pr-link');
  const lastPrompts = collectTyped(text, 'last-prompt');
  const modes = collectTyped(text, 'mode');
  const out = {
    cwd: cwd ? unescapeJson(cwd) : null,
    cwdLast: cwdLast ? unescapeJson(cwdLast) : null,
    branch: branch ? unescapeJson(branch) : null,
    lastActivity: lastTs,
    title: titles.length ? titles[titles.length - 1].customTitle : null,
    lastPrompt: lastPrompts.length ? lastPrompts[lastPrompts.length - 1].lastPrompt : null,
    mode: modes.length ? modes[modes.length - 1].mode : null,
    // Bounded at the source like every other transcript-derived value. The URL is
    // rendered as a markdown LINK TARGET inside both persisted briefs, in the
    // block a reader treats as machine-derived provenance, and the number reaches
    // a printed command line — so both are shape-checked rather than trusted.
    pr: prs.length ? safePr(prs[prs.length - 1]) : null,
    truncated: !read.full,
    stopCause: extractStopCause(text, read.tailOffset),
    queue: extractPendingQueue(text, read.full, read.tailOffset),
    lastTurn: extractLastTurn(text, read.tailOffset),
  };
  if (deep) {
    out.prompts = extractPrompts(text);
    out.assistantTail = extractAssistantTail(text, 3);
    out.touched = extractTouchedFiles(text, 25);
    out.tasks = extractTasks(text);
    out.compaction = extractCompaction(text, 8000);
  }
  return out;
}

function unescapeJson(s) {
  try { return JSON.parse(`"${s}"`); } catch { return s; }
}

function gitState(cwd, full) {
  if (!dirExists(cwd)) return null;
  const branch = git(cwd, ['rev-parse', '--abbrev-ref', 'HEAD']);
  const porcelain = git(cwd, ['status', '--porcelain']) || '';
  const dirtyFiles = porcelain.split('\n').filter(Boolean);
  const base = detectBase(cwd);
  let ahead = null, behind = null;
  if (base) {
    const c = git(cwd, ['rev-list', '--left-right', '--count', `${base}...HEAD`]);
    if (c) {
      const parts = c.split(/\s+/);
      behind = Number(parts[0]);
      ahead = Number(parts[1]);
    }
  }
  const state = { branch, base, ahead, behind, dirty: dirtyFiles.length, dirtyFiles: dirtyFiles.slice(0, 25) };
  if (full) {
    state.head = git(cwd, ['rev-parse', '--short', 'HEAD']);
    state.headSubject = git(cwd, ['log', '-1', '--pretty=%s']);
    state.headWhen = git(cwd, ['log', '-1', '--pretty=%cI']);
    state.commits = base ? (git(cwd, ['log', '--oneline', '--no-decorate', `${base}..HEAD`]) || '').split('\n').filter(Boolean).slice(0, 30) : [];
    state.diffstat = base ? (git(cwd, ['diff', '--stat', `${base}...HEAD`]) || '').split('\n').filter(Boolean).slice(-30) : [];
  }
  return state;
}

function detectBase(cwd) {
  const r = git(cwd, ['symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD']);
  if (r) return r.replace('refs/remotes/', '');
  for (const cand of ['origin/main', 'origin/master', 'main', 'master']) {
    if (git(cwd, ['rev-parse', '--verify', '--quiet', cand])) return cand;
  }
  return null;
}

// Memoized on the options that actually decide the scan. One process runs one
// command, and a second identical pass fired every SKIPPED increment twice — so
// `show` reported double what `show --json` did for the same machine state.
const INDEX_CACHE = new Map();
function buildIndex(opts) {
  const key = JSON.stringify([opts.repo || null, opts.all, opts.days, opts.live, opts.git]);
  if (INDEX_CACHE.has(key)) return INDEX_CACHE.get(key);
  const built = buildIndexUncached(opts);
  INDEX_CACHE.set(key, built);
  return built;
}

function buildIndexUncached(opts) {
  const live = liveRegistry();
  const ctx = opts.all ? null : repoContext(opts.repo || process.cwd());
  if (!opts.all && !ctx) fail('not inside a git repository — use --all or --repo <path>');
  const prefix = ctx ? normSlug(ctx.root) : null;
  const cutoff = opts.days > 0 ? Date.now() - opts.days * 86400000 : 0;
  const rows = [];
  if (!dirExists(PROJECTS)) return { rows, ctx, live };
  let projectDirs;
  try { projectDirs = fs.readdirSync(PROJECTS); } catch { SKIPPED += 1; return { rows, ctx, live }; }
  for (const dir of projectDirs) {
    if (prefix && !dir.startsWith(prefix)) continue;
    const full = path.join(PROJECTS, dir);
    let st;
    try { st = fs.statSync(full); } catch { continue; }
    if (!st.isDirectory()) continue;
    let entries;
    try { entries = fs.readdirSync(full); } catch { SKIPPED += 1; continue; }
    for (const f of entries) {
      if (!f.endsWith('.jsonl')) continue;
      const file = path.join(full, f);
      let fst;
      try { fst = fs.statSync(file); } catch { continue; }
      const sessionId = f.replace(/\.jsonl$/, '');
      const isLive = live.has(sessionId);
      if (!isLive && cutoff && fst.mtimeMs < cutoff) continue;
      if (fst.size < 200) continue;
      let s;
      try { s = summarize(file, fst.size, false); } catch { SKIPPED += 1; continue; }
      const cwd = s.cwd || (live.get(sessionId) || {}).cwd || null;
      if (!cwd) continue;
      if (ctx && !inRepo(cwd, ctx)) continue;
      const wt = (dirExists(cwd) && worktreeRoot(cwd)) || cwd;
      const app = ccdIndex().get(sessionId) || null;
      const row = {
        sessionId,
        transcript: file,
        transcriptDir: dir,
        size: fst.size,
        mtime: fst.mtimeMs,
        cwd,
        wt,
        cwdExists: dirExists(cwd),
        worktree: path.basename(wt),
        live: isLive ? live.get(sessionId) : null,
        ...s,
        app,
      };
      if (!row.title && app && app.title) row.title = app.title;
      rows.push(row);
    }
  }
  rows.sort((a, b) => b.mtime - a.mtime);
  if (opts.live) return { rows: rows.filter((r) => r.live), ctx, live };
  return { rows, ctx, live };
}

function inRepo(cwd, ctx) {
  if (ctx.worktrees.has(cwd)) return true;
  // Normalised before comparing: this cwd is read out of another session's
  // transcript, and `/repo/../elsewhere` satisfies a raw `startsWith('/repo/')`
  // — which would fold an out-of-scope row into a listing the user asked to be
  // repo-scoped, and run a git subprocess in that directory on the way.
  const c = path.resolve(cwd);
  return c === ctx.root || c.startsWith(`${ctx.root}${path.sep}`);
}

function ago(ms) {
  if (!ms) return '?';
  const d = Math.max(0, Date.now() - ms);
  const m = Math.floor(d / 60000);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 48) return `${h}h ${m % 60}m`;
  return `${Math.floor(h / 24)}d ${h % 24}h`;
}

function statusOf(r) {
  if (r.live) return 'LIVE';
  if (!r.cwdExists) return 'GONE';
  return 'IDLE';
}

function rel(p, base) {
  return base && p.startsWith(`${base}${path.sep}`) ? p.slice(base.length + 1) : p;
}

// Delegates to the ledger module rather than re-spelling the bound: `\s` does not
// match ESC or the rest of Cc/Cf, so a private copy here disagreed with boundText
// about what can forge a line — and this is the bound on RENDERED terminal output,
// fed from third-party transcripts. boundText returns null on an empty result;
// this caller wants the empty string.
function oneLine(s, n) {
  // The falsy guard is kept rather than folded into boundText: boundText returns
  // "0" for the number 0 and "false" for false, where this renderer has always
  // produced the empty string. No call site passes either today -- every one
  // hands over a string or null -- so dropping it would have changed nothing
  // visible now and something visible later, which is the worse of the two.
  if (!s) return '';
  return boundText(s, n) || '';
}

function cmdList(opts) {
  const { rows: base, ctx } = buildIndex(opts);
  // The verdict travels in the payload rather than being left for a consumer to
  // recompute from the `queue`/`lastTurn` inputs the rows already carry — one
  // implementation of the policy, on every carrier.
  const rows = base.map((r) => ({ ...r, takeover: surveyVerdict(r) }));
  if (opts.json) return print(JSON.stringify({ repo: ctx && ctx.root, rows, skipped: SKIPPED }, null, 2));
  const scope = ctx ? `${ctx.name} (${ctx.root})` : 'ALL REPOS';
  const liveCount = rows.filter((r) => r.live).length;
  print(`SCOPE  ${scope}`);
  print(`WINDOW ${opts.days > 0 ? `${opts.days}d` : 'unbounded'}   SESSIONS ${rows.length}   LIVE ${liveCount}\n`);
  if (!rows.length) return print('no sessions found');
  for (const r of rows) {
    const g = opts.git ? gitState(r.wt, false) : null;
    const gitPart = g
      ? `${g.branch || '?'}  +${g.ahead ?? '?'}/-${g.behind ?? '?'}  dirty ${g.dirty}`
      : (r.branch || '?');
    const pr = r.pr ? `PR #${r.pr.number}` : 'PR —';
    // `measuredLevel`, not `level`: this command takes no selector, so rendering
    // an authorization here would show one session's approval against every busy
    // row in scope. A survey reports what was measured.
    const owner = r.live ? `pid ${r.live.pid} ${r.takeover.measuredLevel}` : '';
    print(`${statusOf(r).padEnd(4)}  ${r.sessionId.slice(0, 8)}  ${ago(r.mtime).padStart(8)} ago  ${r.worktree}`);
    print(`      ${gitPart}   ${pr}   ${owner}${r.app ? `   ${appTag(r.app)}` : ''}`);
    print(`      "${oneLine(r.title || r.lastPrompt || '(untitled)', 96)}"`);
    if (!r.cwdExists) print(`      !! worktree directory missing: ${r.cwd}`);
    print('');
  }
  print(`next: node ${scriptPath()} show <session-id|worktree|branch|PR#|text>`);
}

function cmdInstances(opts) {
  const live = liveRegistry();
  const rows = [...live.values()].sort((a, b) => (a.startedAt || 0) - (b.startedAt || 0));
  // The lineage is rendered HERE because the window that ran out of quota cannot
  // ask anything — one `instances` call from any working window has to answer
  // "where did that session go" for every session on the machine.
  const edges = dedupeEdges(ledgerRead());
  const lineageOf = (sessionId) => {
    const out = [];
    for (const e of edges) {
      if (e.from.sessionId === sessionId) out.push(`→ continued in ${e.to.sessionId.slice(0, 8)} (${endpointLabel(e.to)})${e.inferred ? ' [inferred]' : ''}`);
      if (e.to.sessionId === sessionId) out.push(`← taken over from ${e.from.sessionId.slice(0, 8)} (${endpointLabel(e.from)})${e.inferred ? ' [inferred]' : ''}`);
    }
    return out;
  };
  if (opts.json) {
    return print(JSON.stringify({
      rows: rows.map((r) => ({ ...r, lineage: lineageOf(r.sessionId) })),
      edgeCount: edges.length,
      ledgerError: LEDGER_DIR_ERROR,
      schemaNewer: LEDGER_SCHEMA_NEWER,
      skipped: SKIPPED,
    }, null, 2));
  }
  const memo = new Map();
  const groups = new Map();
  for (const s of rows) {
    const hasCwd = typeof s.cwd === 'string' && s.cwd !== '';
    const root = !hasCwd ? '(cwd not recorded)'
      : dirExists(s.cwd) ? (nearestRepoRoot(s.cwd, memo) || s.cwd) : path.dirname(s.cwd);
    if (!groups.has(root)) groups.set(root, []);
    groups.get(root).push(s);
  }
  const accounts = new Set();
  for (const s of rows) { const a = ccdIndex().get(s.sessionId); if (a && a.accountUuid) accounts.add(a.accountUuid); }
  print(`LIVE CLAUDE CODE SESSIONS: ${rows.length} (every session process on this machine)`);
  print(`ACCOUNTS INVOLVED: ${accounts.size}${accounts.size ? ` — ${[...accounts].map((i) => accountLabel(i)).join(', ')}` : ''}\n`);
  for (const [root, list] of [...groups.entries()].sort()) {
    print(`${root}  (${list.length})`);
    for (const s of list) {
      const wt = typeof s.cwd !== 'string' || s.cwd === '' ? '(cwd not recorded)'
        : s.cwd === root ? '(main checkout)' : path.relative(root, s.cwd);
      const app = ccdIndex().get(s.sessionId) || null;
      print(`  ${String(s.pid).padStart(6)}  ${String(s.sessionId).slice(0, 8)}  ${(oneLine(s.entrypoint, 40) || '?').padEnd(15)}  ${ago(s.startedAt).padStart(8)} old  ${wt}`);
      print(`          "${oneLine(s.name, 92)}"${app ? `   ${appTag(app)}` : ''}`);
      for (const l of lineageOf(s.sessionId)) print(`          ${l}`);
    }
    print('');
  }
}

// The one session a selector actually named. `activityVerdict` requires a row to
// BE it before `--force` can mean anything, which makes the survey rule
// structural rather than a convention about which helper each call site happens
// to call: a command that resolves no selector can never authorize a row, no
// matter what it passes.
let SELECTED_SESSION_ID = null;

function resolve(opts, selectorRaw) {
  const { rows } = buildIndex({ ...opts, live: false });
  const sel = String(selectorRaw || '').trim();
  if (!sel) fail('missing selector');
  const low = sel.toLowerCase();
  const tiers = [
    rows.filter((r) => r.sessionId === sel),
    rows.filter((r) => sel.length >= 6 && r.sessionId.startsWith(low)),
    rows.filter((r) => /^#?\d+$/.test(sel) && r.pr && String(r.pr.number) === sel.replace('#', '')),
    rows.filter((r) => r.worktree.toLowerCase() === low || r.cwd === sel),
    rows.filter((r) => (r.branch || '').toLowerCase() === low),
    rows.filter((r) => r.worktree.toLowerCase().includes(low) || (r.branch || '').toLowerCase().includes(low)),
    rows.filter((r) => `${r.title || ''} ${r.lastPrompt || ''}`.toLowerCase().includes(low)),
  ];
  const select = (row) => { SELECTED_SESSION_ID = row.sessionId; return row; };
  for (const t of tiers) {
    if (t.length === 1) return select(t[0]);
    if (t.length > 1) {
      const byWorktree = new Set(t.map((r) => r.cwd));
      if (byWorktree.size === 1) return select(t.sort((a, b) => b.mtime - a.mtime)[0]);
      print(`ambiguous selector "${sel}" — ${t.length} candidates:\n`);
      for (const r of t) print(`  ${r.sessionId.slice(0, 8)}  ${statusOf(r).padEnd(4)}  ${r.worktree}  "${oneLine(r.title || r.lastPrompt, 70)}"`);
      flush();
      process.exit(2);
    }
  }
  // Plain text: flush() has already put the NOTE on stdout, and this stderr
  // line repeats the count deliberately, because the two say different things
  // — the NOTE says the output is short, this says the thing you asked for may
  // be what went missing. Under --json the NOTE is suppressed and this is the
  // only carrier.
  fail(`no session matched "${sel}" (try --all or --days 0)${SKIPPED ? ` — NOTE ${SKIPPED} record(s) were unreadable and skipped, the target may be one of them` : ''}`, 2);
}

function hydrate(row) {
  let st;
  try { st = fs.statSync(row.transcript); } catch { return row; }
  try { return { ...row, ...summarize(row.transcript, st.size, true) }; } catch { SKIPPED += 1; return row; }
}

// Takes the rows the caller already built. A second buildIndex() pass fired every
// SKIPPED increment twice, so `show` reported double what `show --json` did for
// the identical machine state.
function siblings(rows, row) {
  return rows.filter((r) => r.wt === row.wt && r.sessionId !== row.sessionId);
}

function cmdShow(opts) {
  const base = resolve(opts, opts._[1]);
  const r = hydrate(base);
  const g = opts.git ? gitState(r.wt, true) : null;
  const v = activityVerdict(r, opts.force);
  if (opts.json) return print(JSON.stringify({ ...r, git: g, takeover: v, skipped: SKIPPED }, null, 2));
  print(`SESSION  ${r.sessionId}`);
  print(`TITLE    ${oneLine(r.title, 200) || '(none)'}`);
  // Bounded like every other third-party value: the registry record is another
  // instance's JSON, and a newline in `name` or `entrypoint` would fabricate a
  // line directly above the TAKEOVER verdict a reader acts on.
  print(`STATUS   ${statusOf(r)}${r.live ? `  pid ${r.live.pid}  ${oneLine(r.live.entrypoint, 40)}  name "${oneLine(r.live.name, 92)}"` : ''}`);
  if (r.app) {
    print(`OWNER    account ${r.app.accountUuid || '(not resolvable)'}${r.app.accountUuid ? ` (${accountLabel(r.app.accountUuid)})` : ''}${r.app.archived ? '   **ARCHIVED** (process stopped, worktree may have been cleaned up)' : ''}`);
    print(`CONFIG   model ${oneLine(r.app.model, 40) || '?'}   effort ${oneLine(r.app.effort, 40) || '?'}   permissions ${oneLine(r.app.permissionMode, 40) || '?'}`);
  }
  print(`WORKTREE ${r.wt}${r.cwdExists ? '' : '   !! MISSING'}`);
  if (r.cwd !== r.wt) print(`CWD      ${r.cwd}   (session started in a subdirectory)`);
  print(`BRANCH   ${oneLine((g && g.branch) || r.branch, 120) || '?'}`);
  print(`LAST     ${ago(r.mtime)} ago   transcript ${r.transcript}`);
  if (r.pr) print(`PR       #${r.pr.number}  ${r.pr.url}`);
  if (r.stopCause && r.stopCause.final) print(`STOPPED  ${r.stopCause.error}${r.stopCause.status ? ` (${r.stopCause.status})` : ''} at ${(r.stopCause.at || '').slice(0, 16)} — "${oneLine(r.stopCause.message, 90)}"`);
  else if (r.stopCause) print(`NOTE     hit ${r.stopCause.error} at ${(r.stopCause.at || '').slice(0, 16)} but recovered (${r.stopCause.laterTurns} turns after, last ${(r.stopCause.resumedUntil || '').slice(0, 16)})`);
  if (r.truncated) print('NOTE     transcript is large — head+tail only, middle not scanned');
  const sib = siblings(buildIndex({ ...opts, live: false }).rows, r);
  if (sib.length) print(`SIBLINGS ${sib.map((s) => `${s.sessionId.slice(0, 8)}(${statusOf(s)})`).join(' ')}  — same worktree, other sessions`);
  print('');
  print(`TAKEOVER ${v.level} — ${v.reason}`);
  for (const advice of (ADVICE[v.level] || ['No advice is registered for this verdict — treat it as BUSY and ask before editing.'])) {
    print(`         ${advice}`);
  }
  print('\n--- PROMPT TIMELINE ---');
  const ps = r.prompts || [];
  const shown = ps.slice(-Math.max(1, opts.prompts));
  if (ps.length > shown.length) print(`(${ps.length - shown.length} earlier prompts omitted — raise with --prompts N)`);
  for (const p of shown) print(`[${(p.at || '').slice(0, 16)}] ${oneLine(p.text, 300)}`);
  if (r.assistantTail && r.assistantTail.length) {
    print('\n--- LAST ASSISTANT OUTPUT ---');
    for (const a of r.assistantTail) print(`[${(a.at || '').slice(0, 16)}] ${oneLine(a.text, 400)}`);
  }
  if (g) {
    print('\n--- GIT ---');
    print(`base ${g.base || '?'}   ahead ${g.ahead ?? '?'}   behind ${g.behind ?? '?'}   dirty ${g.dirty}`);
    if (g.head) print(`HEAD ${g.head} ${g.headSubject || ''} (${(g.headWhen || '').slice(0, 16)})`);
    if (g.commits && g.commits.length) { print('commits:'); for (const c of g.commits) print(`  ${c}`); }
    if (g.dirtyFiles.length) { print('uncommitted:'); for (const d of g.dirtyFiles) print(`  ${d}`); }
    if (g.diffstat && g.diffstat.length) { print('diffstat:'); for (const d of g.diffstat) print(`  ${d}`); }
  }
  if (r.touched && r.touched.length) {
    print('\n--- FILES THE SESSION TOUCHED (from transcript) ---');
    for (const t of r.touched) print(`  ${String(t.hits).padStart(3)}x  ${rel(t.path, r.wt)}`);
  }
  print('\n--- CONTINUE ELSEWHERE ---');
  printResume(r);
}

function printResume(r) {
  print(`  cd ${r.cwd} && claude --resume ${r.sessionId}`);
  print(`  cd ${r.cwd} && claude --resume ${r.sessionId} --fork-session`);
  if (r.pr) print(`  claude --from-pr ${r.pr.number}`);
  if (!r.cwdExists) print('  # worktree missing — recreate it first: git worktree add <path> <branch>');
}

const PLAN_DIRS = ['.zensu/plans', 'docs/plans', '.claude/plans', 'plans'];

function findPlanDocs(wt, limit) {
  const out = [];
  for (const rel of PLAN_DIRS) {
    const dir = path.join(wt, rel);
    if (!dirExists(dir)) continue;
    let names;
    try { names = fs.readdirSync(dir); } catch { SKIPPED += 1; continue; }
    for (const n of names) {
      if (!n.endsWith('.md')) continue;
      const p = path.join(dir, n);
      try { out.push({ path: `${rel}/${n}`, mtime: fs.statSync(p).mtimeMs }); } catch { /* skip */ }
    }
  }
  return out.sort((a, b) => b.mtime - a.mtime).slice(0, limit);
}

function clip(s, n) {
  const t = String(s || '').trim();
  return t.length > n ? `${t.slice(0, n)}\n…[truncated]` : t;
}

function gitDiffText(cwd, base, maxLines) {
  if (!dirExists(cwd)) return null;
  const cut = (s) => {
    if (!s) return null;
    const lines = s.split('\n');
    return lines.length > maxLines ? `${lines.slice(0, maxLines).join('\n')}\n…[${lines.length - maxLines} more lines]` : s;
  };
  return {
    uncommitted: cut(git(cwd, ['diff'])),
    staged: cut(git(cwd, ['diff', '--cached'])),
    untracked: (git(cwd, ['ls-files', '--others', '--exclude-standard']) || '').split('\n').filter(Boolean).slice(0, 40),
    branchDiff: base ? cut(git(cwd, ['diff', `${base}...HEAD`])) : null,
  };
}

function cmdLimited(opts) {
  const { rows, ctx } = buildIndex({ ...opts, live: false });
  const hit = rows.filter((r) => r.stopCause);
  const verdicted = (list) => list.map((r) => ({ ...r, takeover: surveyVerdict(r) }));
  const stalled = verdicted(hit.filter((r) => r.stopCause.final));
  const recovered = verdicted(hit.filter((r) => !r.stopCause.final));
  if (opts.json) return print(JSON.stringify({ repo: ctx && ctx.root, stalled, recovered, skipped: SKIPPED }, null, 2));
  print(`SCOPE  ${ctx ? `${ctx.name} (${ctx.root})` : 'ALL REPOS'}`);
  print(`STALLED AT AN API LIMIT/ERROR: ${stalled.length}   RECOVERED AFTERWARDS: ${recovered.length}   (of ${rows.length} scanned)\n`);
  const line = (r) => {
    print(`${statusOf(r).padEnd(4)}  ${r.sessionId.slice(0, 8)}  ${ago(r.mtime).padStart(8)} ago  ${r.worktree}${r.live ? `   pid ${r.live.pid} ${r.takeover.measuredLevel}` : ''}`);
    print(`      cause: ${r.stopCause.error}${r.stopCause.status ? ` (${r.stopCause.status})` : ''} at ${(r.stopCause.at || '').slice(0, 16)}${r.truncated ? '   [transcript >8 MB — read head+tail only, this classification saw the tail]' : ''}`);
    if (r.app) print(`      ${appTag(r.app)}`);
    if (r.stopCause.message) print(`      "${oneLine(r.stopCause.message, 110)}"`);
    if (!r.stopCause.final) {
      print(`      RECOVERED: ${r.stopCause.laterTurns} further turn(s) after that, last at ${(r.stopCause.resumedUntil || '').slice(0, 16)} — this is NOT why it stopped`);
    }
    print(`      task:  "${oneLine(r.title || r.lastPrompt || '(untitled)', 96)}"`);
    print('');
  };
  if (stalled.length) {
    print('--- STALLED: the error is the last thing in the transcript ---\n');
    for (const r of stalled) line(r);
  }
  if (recovered.length) {
    print('--- RECOVERED: hit a limit earlier, then kept working. Do not treat these as dead. ---\n');
    for (const r of recovered) line(r);
  }
  if (!hit.length) return print('none found in this window — widen with --days 0 or --all');
  print(`next: node ${scriptPath()} takeover <session-id>`);
}

function cmdTakeover(opts) {
  const base = resolve(opts, opts._[1]);
  const r = hydrate(base);
  const g = gitState(r.wt, true);
  const d = g ? gitDiffText(r.wt, g.base, 400) : null;
  const ctx = opts.all ? null : repoContext(opts.repo || process.cwd());
  const target = handoffPath(r, ctx, g && g.branch).replace(/\.md$/, '.takeover.md');
  const tv = activityVerdict(r, opts.force);
  // Recorded before the --json branch on purpose: a caller that asked for JSON is
  // taking the session over just as much as one reading the markdown, and an edge
  // that only exists on the text path would be missing exactly when a tool drives
  // this command.
  const lineage = recordTakeoverEdge(opts, r);
  if (opts.json) return print(JSON.stringify({ ...r, git: g, diff: d, target, takeover: tv, lineage, skipped: SKIPPED }, null, 2));
  const L = [];
  L.push(`# Takeover: ${r.title || path.basename(r.wt)}`);
  L.push('');
  L.push('> Reconstructed from the source session\'s transcript on disk. That session contributed nothing to this document and did not need to be running.');
  L.push('');
  L.push('## Source');
  L.push(`- session: \`${r.sessionId}\` (${statusOf(r)}${r.live ? `, STILL RUNNING as pid ${r.live.pid}` : ''})`);
  if (r.app) L.push(`- owning account: \`${r.app.accountUuid || '(not resolvable)'}\`${r.app.archived ? ' — **ARCHIVED**: its process was stopped and the worktree may have been cleaned up' : ''}`);
  L.push(`- takeover verdict when this brief was written: **${tv.measuredLevel}** — ${tv.measuredReason}`);
  if (tv.authorized) {
    L.push(`- an authorization was recorded at ${new Date().toISOString()} by passing \`--force\` to the command that generated this file. It is bounded to that moment and to whoever gave it — this brief cannot carry it forward, so re-measure and take the go/no-go again before editing.`);
  }
  L.push(`- worktree: \`${r.wt}\`${r.cwdExists ? '' : '  **MISSING**'}`);
  L.push(`- branch: \`${(g && g.branch) || r.branch || '?'}\``);
  L.push(`- last activity: ${new Date(r.mtime).toISOString()} (${ago(r.mtime)} ago)`);
  if (r.pr) L.push(`- pull request: [#${r.pr.number}](${r.pr.url})`);
  if (r.stopCause && r.stopCause.final) {
    L.push(`- **stopped on: ${r.stopCause.error}${r.stopCause.status ? ` (HTTP ${r.stopCause.status})` : ''}** at ${r.stopCause.at || '?'}`);
    if (r.stopCause.message) L.push(`  - > ${r.stopCause.message}`);
  } else if (r.stopCause) {
    L.push(`- hit \`${r.stopCause.error}\` at ${r.stopCause.at || '?'} but **recovered** — ${r.stopCause.laterTurns} further turn(s) followed, last at ${r.stopCause.resumedUntil || '?'}. That error is not why it is idle now.`);
    if (r.stopCause.message) L.push(`  - > ${r.stopCause.message}`);
  }
  if (r.truncated) L.push('- ⚠️ transcript exceeds 8 MB — only head+tail were scanned, the middle is not represented below');
  L.push('');
  const first = (r.prompts || [])[0];
  L.push('## Original objective');
  L.push(first ? clip(first.text, 4000) : '_no user prompt found in the scanned range_');
  L.push('');
  if (r.compaction) {
    L.push(`## State at last compaction (${(r.compaction.at || '').slice(0, 16)})`);
    L.push(clip(r.compaction.text, 8000));
    L.push('');
  }
  const plans = r.cwdExists ? findPlanDocs(r.wt, 5) : [];
  if (plans.length) {
    const startedAt = first && first.at ? Date.parse(first.at) : null;
    const inWindow = (p) => startedAt !== null && p.mtime >= startedAt && p.mtime <= r.mtime + 60000;
    const own = plans.filter(inWindow);
    L.push('## Plan documents in the worktree');
    L.push('_Read these first — they are written plans on disk, independent of the transcript._');
    for (const p of (own.length ? own : plans.slice(0, 3))) {
      L.push(`- \`${p.path}\` (modified ${new Date(p.mtime).toISOString().slice(0, 16)}${inWindow(p) ? ', **touched during this session**' : ''})`);
    }
    if (!own.length) L.push('- _none of these fall inside the session\'s active window; they may belong to other work_');
    L.push('');
  }
  L.push('## Task list at the moment it stopped');
  const tasks = r.tasks || [];
  if (!tasks.length) L.push('_the session tracked no tasks_');
  for (const t of tasks) {
    L.push(`- [${oneLine(String(t.status ?? ''), 24)}] **#${oneLine(String(t.id ?? ''), 16)} ${oneLine(String(t.subject ?? ''), 200)}**`);
    if (t.description) L.push(`  - ${clip(t.description, 600)}`);
  }
  const open = tasks.filter((t) => t.status !== 'completed');
  if (open.length) L.push(`\n**${open.length} task(s) not completed: ${open.map((t) => `#${oneLine(String(t.id ?? ''), 16)}`).join(', ')}**`);
  L.push('');
  L.push('## Recent instructions (verbatim, newest last)');
  const recent = (r.prompts || []).slice(-Math.max(1, opts.prompts));
  for (const p of recent) {
    L.push(`### \`${(p.at || '').slice(0, 16)}\``);
    L.push(clip(p.text, 2500));
  }
  L.push('');
  L.push('## What it said last');
  for (const a of (r.assistantTail || [])) {
    L.push(`### \`${(a.at || '').slice(0, 16)}\``);
    L.push(clip(a.text, 6000));
  }
  L.push('');
  L.push('## Git state');
  if (!g) L.push('- worktree directory is gone; git state unavailable');
  else {
    L.push(`- base \`${g.base || '?'}\`, ahead ${g.ahead ?? '?'}, behind ${g.behind ?? '?'}, uncommitted ${g.dirty}`);
    if (g.head) L.push(`- HEAD \`${g.head}\` ${g.headSubject || ''}`);
    if (g.commits && g.commits.length) { L.push('- commits on this branch:'); for (const c of g.commits) L.push(`  - \`${c}\``); }
    if (g.dirtyFiles.length) { L.push('- uncommitted files:'); for (const x of g.dirtyFiles) L.push(`  - \`${x}\``); }
    if (d && d.untracked.length) { L.push('- untracked files:'); for (const x of d.untracked) L.push(`  - \`${x}\``); }
    if (d && d.staged) { L.push('\n### Staged diff'); L.push('```diff'); L.push(d.staged); L.push('```'); }
    if (d && d.uncommitted) { L.push('\n### Uncommitted diff'); L.push('```diff'); L.push(d.uncommitted); L.push('```'); }
  }
  L.push('');
  L.push('## Files the session touched');
  for (const t of (r.touched || [])) L.push(`- \`${rel(t.path, r.wt)}\` (${t.hits}x)`);
  L.push('');
  L.push('## How to continue');
  L.push(`1. \`cd ${r.wt}\` — work in this worktree, not a fresh checkout of the branch.`);
  L.push('2. Re-verify before trusting anything above: this is a snapshot, and the working tree may have moved since.');
  L.push('3. Restate the remaining work as a short plan and get the user\'s confirmation before editing.');
  if (tv.measuredLevel === 'BUSY') L.push(`4. ⚠️ **Hazard, not a veto** — ${tv.measuredReason} State it to the user in one line and take a single go/no-go before the first edit${tv.authorized ? ' — the authorization above was given when this brief was written, not here' : '; on yes, re-run this command with `--force`'}. Then take it over; tell the user not to type in that window, and check whether it still owns dev servers or ports.`);
  else if (tv.measuredLevel === 'PROBABLY_FREE') L.push(`4. ${tv.measuredReason} Taking over is fine; tell the user not to type in that window, and check whether it still owns dev servers or ports.`);
  print(`TAKEOVER_TARGET: ${target}`);
  // ABOVE the fence, with the other provenance lines. SKILL.md instructs the model
  // to treat anything after `--- END ---` as untrusted text that happened to be in
  // the stream, so a write announcement emitted there is one the reader is told to
  // disbelieve — and this tool announcing its own write is the one line that must
  // land.
  print(`LINEAGE  ${lineage.message}`);
  print('--- BEGIN TAKEOVER MARKDOWN ---');
  print(L.join('\n'));
  print('--- END TAKEOVER MARKDOWN ---');
}

// The edge is recorded HERE, automatically, because forgetting this step is the
// exact failure the ledger exists to fix — a takeover that leaves no trace is
// indistinguishable from one that never happened. It is announced on its own line
// rather than done quietly: a read command that writes must say so. `--no-record`
// opts out for a genuine read-only inspection, and a session with no
// CLAUDE_CODE_SESSION_ID (a bare `node trail.mjs` outside Claude Code) records
// nothing rather than inventing an endpoint.
function recordTakeoverEdge(opts, row) {
  if (!opts.record) return { recorded: false, reason: 'opted-out', message: 'not recorded (--no-record)' };
  const me = selfIdentity();
  if (!me.sessionId) {
    return { recorded: false, reason: 'no-self-session-id', message: 'not recorded — this process has no CLAUDE_CODE_SESSION_ID, so the continuing session cannot be named' };
  }
  if (me.sessionId === row.sessionId) {
    return { recorded: false, reason: 'self-target', message: 'not recorded — the target is this same session' };
  }
  const reason = opts.reason || (row.stopCause && row.stopCause.error) || 'manual';
  let file;
  try { file = ledgerWrite(buildEdge(row, me, reason, 'takeover', false)); } catch (e) {
    return { recorded: false, reason: 'write-failed', message: `NOT RECORDED — ${e && e.message ? e.message : 'write failed'}` };
  }
  return {
    recorded: true,
    reason,
    file: path.basename(file),
    message: `recorded ${row.sessionId.slice(0, 8)} → ${me.sessionId.slice(0, 8)} (reason: ${reason}) in ${path.basename(file)}`,
  };
}

function handoffPath(r, ctx, liveBranch) {
  const root = (r.cwdExists && nearestRepoRoot(r.wt, new Map())) || null;
  // `repo` is derived from a path this script did not choose — a `gitdir:` line in
  // a linked worktree's `.git` file, or the parent directory name under `--all`.
  // Both can spell `..`, and `path.join` would then normalise the target OUT of
  // the handoffs directory: the model is told to Write to whatever this prints.
  // Sanitising is not enough on its own, because `..` survives a character class
  // that permits dots — so the result is asserted to be inside HANDOFFS as well.
  const rawRepo = (root && path.basename(root)) || (ctx && ctx.name) || path.basename(path.dirname(r.wt));
  const safe = (s) => String(s || '').replace(/[^A-Za-z0-9._-]/g, '-');
  const repo = safe(rawRepo).replace(/^\.+$/, 'unknown-repo') || 'unknown-repo';
  const usable = (b) => (b && b !== 'HEAD' ? b : null);
  const branch = safe(usable(r.branch) || usable(liveBranch) || path.basename(r.wt)).replace(/^\.+$/, 'unknown-branch') || 'unknown-branch';
  const target = path.join(HANDOFFS, repo, `${branch}.md`);
  if (!path.resolve(target).startsWith(HANDOFFS + path.sep)) {
    fail(`refusing to name a brief target outside ${HANDOFFS}: ${target}`);
  }
  return target;
}

function cmdHandoff(opts) {
  const base = resolve(opts, opts._[1]);
  const r = hydrate(base);
  const g = gitState(r.wt, true);
  const ctx = opts.all ? null : repoContext(opts.repo || process.cwd());
  const target = handoffPath(r, ctx, g && g.branch);
  const L = [];
  L.push(`# Handoff: ${r.title || path.basename(r.cwd)}`);
  L.push('');
  L.push('## Source');
  L.push(`- session: \`${r.sessionId}\` (${statusOf(r)}${r.live ? `, pid ${r.live.pid}, ${oneLine(r.live.entrypoint, 40)}` : ''})`);
  L.push(`- worktree: \`${r.wt}\`${r.cwdExists ? '' : '  **MISSING**'}`);
  L.push(`- branch: \`${(g && g.branch) || r.branch || '?'}\``);
  L.push(`- transcript: \`${r.transcript}\``);
  L.push(`- last activity: ${new Date(r.mtime).toISOString()} (${ago(r.mtime)} ago)`);
  if (r.pr) L.push(`- pull request: [#${r.pr.number}](${r.pr.url})`);
  if (r.truncated) L.push('- note: transcript large, only head+tail scanned');
  L.push('');
  L.push('## What was asked');
  const hp = r.prompts || [];
  const hpShown = hp.slice(-30);
  if (hp.length > hpShown.length) L.push(`- _(${hp.length - hpShown.length} earlier prompts omitted)_`);
  for (const p of hpShown) L.push(`- \`${(p.at || '').slice(0, 16)}\` ${oneLine(p.text, 400)}`);
  L.push('');
  L.push('## Git state');
  if (!g) L.push('- worktree directory is gone; git state unavailable');
  else {
    L.push(`- base \`${g.base || '?'}\`, ahead ${g.ahead ?? '?'}, behind ${g.behind ?? '?'}, uncommitted ${g.dirty}`);
    if (g.head) L.push(`- HEAD \`${g.head}\` ${g.headSubject || ''}`);
    if (g.commits && g.commits.length) { L.push('- commits on this branch:'); for (const c of g.commits) L.push(`  - \`${c}\``); }
    if (g.dirtyFiles.length) { L.push('- uncommitted changes:'); for (const d of g.dirtyFiles) L.push(`  - \`${d}\``); }
    if (g.diffstat && g.diffstat.length) { L.push('- diffstat vs base:'); L.push('```'); for (const d of g.diffstat) L.push(d); L.push('```'); }
  }
  L.push('');
  L.push('## Files the session touched');
  for (const t of (r.touched || [])) L.push(`- \`${rel(t.path, r.wt)}\` (${t.hits}x)`);
  L.push('');
  L.push('## Open threads');
  L.push('<!-- FILL: unresolved questions, failing checks, decisions still pending -->');
  L.push('');
  L.push('## Next steps');
  L.push('<!-- FILL: concrete, ordered, executable by a fresh session with no prior context -->');
  L.push('');
  L.push('## Continue this work');
  L.push('```bash');
  L.push(`cd ${r.cwd} && claude --resume ${r.sessionId}`);
  L.push('```');
  if (r.live) {
    // `measuredReason`, not `reason`: a label that says "measured" must not carry
    // the authorization clause, whose "this invocation" is unresolvable in a file
    // a DIFFERENT instance reads later.
    const hv = activityVerdict(r, opts.force);
    L.push('');
    L.push(`> **Still running** in pid ${r.live.pid} — measured takeover verdict **${hv.measuredLevel}**: ${hv.measuredReason}`);
    if (hv.authorized) L.push(`> An authorization was recorded at ${new Date().toISOString()} by passing --force to the command that generated this file. It was bounded to that moment and to whoever gave it, and this file cannot carry it forward.`);
    L.push('> Nothing enforces exclusivity here; the hazard is a human typing in that window, not the process holding a claim.');
    L.push('> Re-measure before acting: this line is a snapshot, and any authorization behind it was bounded to the moment this file was written.');
  }
  print(`HANDOFF_TARGET: ${target}`);
  print('--- BEGIN HANDOFF MARKDOWN ---');
  print(L.join('\n'));
  print('--- END HANDOFF MARKDOWN ---');
}

// ── lineage / adopt / label ─────────────────────────────────────────────────

function cmdLabel(opts) {
  // `--self` is a parsed flag, so the label text is the FIRST positional there
  // and the SECOND when a key is named explicitly.
  const positional = opts._.slice(1);
  let target = '';
  let text = '';
  let kind = 'account';
  if (opts.self) {
    const me = selfIdentity();
    if (me.accountUuid) { target = me.accountUuid; kind = 'account'; }
    else if (me.appPid) { target = String(me.appPid); kind = 'window'; }
    if (!target) fail('--self could not resolve this session\'s account or window — run `lineage --diagnose`');
    text = positional.join(' ').trim();
  } else {
    target = String(positional[0] || '').trim();
    text = positional.slice(1).join(' ').trim();
    // A pid is not a uuid; the key kind is decided by shape rather than guessed.
    kind = /^\d+$/.test(target) ? 'window' : 'account';
  }
  if (!target) fail('usage: label <accountUuid|appPid|--self> <text>');
  if (target === '__proto__' || target === 'constructor' || target === 'prototype') {
    fail(`refusing "${target}" as a label key — it names an object member, not an account`);
  }
  if (!text) fail('usage: label <accountUuid|appPid|--self> <text>');
  // Bounded like every other rendered value: this label is machine-wide and is
  // interpolated into numbered chain lines every other session reads, so an
  // unbounded one could fabricate a line there.
  const bounded = boundLabel(text);
  if (!bounded) fail('label text is empty after trimming');
  const current = readLabels();
  // Refused rather than merged: the reader returns an EMPTY map for a file it
  // could not parse, so writing on top of that would replace every existing label
  // with the one being set.
  if (LABELS_UNREADABLE) {
    fail(`${LABELS_FILE} exists but could not be read — refusing to overwrite it; move it aside and re-run`);
  }
  // A newer schema reduces to an empty map on read, which is exactly what a write
  // would then replace the real labels with.
  if (LABELS_SCHEMA_MISMATCH) {
    fail(`${LABELS_FILE} was written by a different label schema — refusing to overwrite it; update the plugin or move it aside`);
  }
  // Object.assign onto the module's own maps: an object-literal spread would give
  // them Object.prototype back, and a `__proto__` key would then hit the inherited
  // setter, store nothing, and still be reported as written.
  const next = emptyLabels();
  Object.assign(next.accounts, current.accounts);
  Object.assign(next.windows, current.windows);
  // Two namespaces: an account uuid is stable, an OS pid is reused after its
  // process exits. One flat map let a pid-keyed label silently rename an
  // unrelated window later, with no way to tell the two kinds apart in the file.
  if (kind === 'window') next.windows[target] = bounded;
  else next.accounts[target] = bounded;
  try {
    writeLabels(LABELS_FILE, next, CONFIG_ROOT);
  } catch (e) {
    fail(`could not write ${LABELS_FILE}: ${e && e.message ? e.message : 'write failed'}`);
  }
  LABEL_CACHE = next;
  if (opts.json) return print(JSON.stringify({ labelled: target, kind, text: bounded, file: LABELS_FILE, skipped: SKIPPED }, null, 2));
  print(`labelled ${kind} ${target} → "${bounded}"   (${LABELS_FILE})`);
}

function cmdAdopt(opts) {
  const row = resolve(opts, opts._[1]);
  const me = selfIdentity();
  if (!me.sessionId) {
    fail('this process has no CLAUDE_CODE_SESSION_ID, so it cannot record itself as the continuing session');
  }
  if (me.sessionId === row.sessionId) fail('refusing to record a session as its own continuation');
  const edge = buildEdge(row, me, opts.reason || 'manual', 'adopt', false);
  // Guarded exactly as the takeover path is: the same unwritable-ledger condition
  // must not kill one verb with a stack trace while its sibling reports it.
  let file;
  try { file = ledgerWrite(edge); } catch (e) {
    fail(`could not record the handover: ${e && e.message ? e.message : 'write failed'}`);
  }
  if (opts.json) return print(JSON.stringify({ recorded: edge, file, skipped: SKIPPED }, null, 2));
  print(`RECORDED  ${row.sessionId.slice(0, 8)} (${endpointLabel(edge.from)}) → ${me.sessionId.slice(0, 8)} (${endpointLabel(edge.to)})`);
  print(`          reason: ${edge.reason}   worktree: ${edge.to.worktree || '(unknown)'}`);
  print(`          ${path.join(LEDGER_DIR, file ? path.basename(file) : '')}`);
}

function lineageDiagnose(opts) {
  const probes = ccdStoreCandidates().map((c) => ({ ...c, exists: dirExists(c.dir) }));
  const resolved = probes.find((p) => p.exists) || null;
  const edges = ledgerRead();
  if (opts.json) {
    return print(JSON.stringify({
      configRoot: CONFIG_ROOT,
      configRootSource: opts.configDir ? '--config-dir' : (process.env.CLAUDE_CONFIG_DIR ? 'CLAUDE_CONFIG_DIR' : 'default'),
      ledgerDir: LEDGER_DIR,
      labelsFile: LABELS_FILE,
      edgeCount: edges.length,
      ledgerError: LEDGER_DIR_ERROR,
      schemaNewer: LEDGER_SCHEMA_NEWER,
      store: resolved,
      probes,
      platform: process.platform,
      skipped: SKIPPED,
    }, null, 2));
  }
  print(`PLATFORM     ${process.platform}`);
  print(`CONFIG ROOT  ${CONFIG_ROOT}   (${opts.configDir ? '--config-dir' : (process.env.CLAUDE_CONFIG_DIR ? 'CLAUDE_CONFIG_DIR' : 'default ~/.claude')})`);
  print(`LEDGER       ${LEDGER_DIR}   (${edges.length} edge record(s))`);
  if (LEDGER_DIR_ERROR) print(`LEDGER ERROR ${LEDGER_DIR_ERROR} — the count above is NOT a measurement of what exists.`);
  if (LEDGER_SCHEMA_NEWER) print('LEDGER SCHEMA A record from a NEWER schema was refused; upgrade the plugin to read it.');
  print(`LABELS       ${LABELS_FILE}`);
  print('');
  print('DESKTOP STORE PROBES (first existing wins; only the macOS path is verified):');
  for (const p of probes) print(`  ${p.exists ? 'FOUND  ' : 'absent '} ${p.source}\n           ${p.dir}`);
  print('');
  if (!resolved) {
    print('No desktop store found, so no session can be attributed to an account.');
    print('Chains still render and still group by window (process ancestry).');
    print('If this machine DOES run the Claude desktop app, point ZENSU_CCD_STORE at its');
    print('claude-code-sessions directory — the Windows and Linux paths above are inferred,');
    print('not measured, and this is the command that shows which one was tried.');
  }
}

function lineageBackfill(opts) {
  // Unbounded unless the caller narrowed it explicitly. This verb exists to
  // reconstruct handovers from BEFORE the ledger, and the 21-day default excluded
  // exactly those while reporting "0 candidates" on a machine that has them.
  const days = opts.daysExplicit ? opts.days : 0;
  const { rows } = buildIndex({ ...opts, days, live: false });
  const existing = ledgerRead();
  const known = new Set(existing.map((e) => `${e.from.sessionId}>${e.to.sessionId}`));
  // The duplicate guard below is exactly as good as this read. An unreadable
  // directory yields an EMPTY `known` set, so every edge that IS already recorded
  // re-proposes and --apply mints a second copy machine-wide. The dry run still
  // renders — only the write is refused, and it says which half failed.
  // Per-RECORD refusals count too, not only the whole-directory failure: readEdges
  // drops an unreadable, malformed or wrong-schema record, and each one is a pair
  // missing from `known` above. The gate names which of the two it is, because the
  // remedies differ -- fix the directory, versus find the one bad record.
  const refusedCount = LEDGER_REFUSED;
  const applyBlocked = Boolean(opts.apply && (LEDGER_DIR_ERROR || refusedCount > 0));
  const applyRefusal = LEDGER_DIR_ERROR ? 'ledger-unreadable' : 'records-refused';
  const stalled = rows.filter((r) => r.stopCause && r.stopCause.final);
  const candidates = [];
  for (const s of stalled) {
    // Ordered by last activity, and there is deliberately NO start guard. An earlier
    // design ordered by START and skipped a successor whose start preceded the stall;
    // that argument used to stand here beside the code that replaced it, which left
    // the next reader to work out which paragraph was live -- and the natural repair
    // it invited would have restored the very defect the rule below fixes.
    // The rule: the start guard applies ONLY where a start is
    // actually observable. `r.live` is null for every finished session — the whole
    // population this verb reconstructs — so the previous `startedAt(r) >= s.mtime`
    // conjunct rejected nothing there while wrongly excluding a live window that
    // was already open when the stall happened. Stated rather than implied: a
    // transcript's first timestamp is not read here, so the "started after the
    // stall" claim is NOT established for finished sessions.
    const successor = rows
      .filter((r) => r.wt === s.wt && r.sessionId !== s.sessionId && r.mtime > s.mtime)
      .sort((a, b) => a.mtime - b.mtime)[0];
    if (!successor) continue;
    const fromAcct = (s.app && s.app.accountUuid) || null;
    const toAcct = (successor.app && successor.app.accountUuid) || null;
    // Same account is a resumption, not a handover — and two unknown accounts are
    // not evidence of a DIFFERENT one, so they are excluded too. A heuristic that
    // guessed here would mint edges nobody can distinguish from measured ones.
    if (!fromAcct || !toAcct || fromAcct === toAcct) continue;
    if (known.has(`${s.sessionId}>${successor.sessionId}`)) continue;
    candidates.push({ from: s, to: successor });
  }
  if (opts.json && !opts.apply) {
    return print(JSON.stringify({
      dryRun: true,
      windowDays: days,
      candidates: candidates.map((c) => ({
        from: c.from.sessionId, to: c.to.sessionId, worktree: c.to.wt,
        cause: c.from.stopCause.error || 'rate_limit',
      })),
      ledgerError: LEDGER_DIR_ERROR,
      schemaNewer: LEDGER_SCHEMA_NEWER,
      skipped: SKIPPED,
    }, null, 2));
  }
  if (!opts.apply) {
    print(`BACKFILL DRY RUN — ${candidates.length} candidate edge(s), nothing written.`);
    print(`WINDOW ${days > 0 ? `${days} day(s)` : 'unbounded'}`);
    print('Each is a GUESS: a session that stalled on an API limit, and the next session on the');
    print('same worktree under a different account. Re-run with --apply to record them; they are');
    print('then marked inferred and rendered as such, so a guess never reads like a measurement.\n');
    for (const c of candidates) {
      print(`  ${c.from.sessionId.slice(0, 8)} (${endpointLabel(endpointFromRow(c.from))}) → ${c.to.sessionId.slice(0, 8)} (${endpointLabel(endpointFromRow(c.to))})`);
      // The absolute worktree and the same cause fallback the write uses: this is
      // the only review surface before --apply mints machine-wide inferred edges,
      // so it has to show what will actually be recorded.
      print(`      worktree: ${c.to.wt}   cause: ${c.from.stopCause.error || 'rate_limit'}`);
    }
    if (!candidates.length) print('  (none)');
    return;
  }
  if (applyBlocked) {
    if (opts.json) {
      return print(JSON.stringify({
        dryRun: false, applied: false, refusal: applyRefusal,
        written: 0, files: [], writeError: null, refusedRecords: refusedCount,
        ledgerError: LEDGER_DIR_ERROR, schemaNewer: LEDGER_SCHEMA_NEWER, skipped: SKIPPED,
      }, null, 2));
    }
    if (LEDGER_DIR_ERROR) print(`BACKFILL REFUSED — the ledger could not be read (${LEDGER_DIR_ERROR}).`);
    else print(`BACKFILL REFUSED — ${refusedCount} ledger record(s) could not be read.`);
    print('Nothing was written. The already-recorded edges could not be listed in full, so a');
    print('candidate above may already exist and --apply would mint a duplicate of it.');
    print(`Fix the ledger (${LEDGER_DIR}) and re-run; \`lineage --diagnose\` names what failed.`);
    return;
  }
  const written = [];
  let writeError = null;
  for (const c of candidates) {
    // The successor's last activity is the closest observable instant to when the
    // handover it reconstructs actually happened. Falling back to now only when that
    // is unusable keeps the guess from silently outranking every measurement.
    const inferredAt = Number.isFinite(c.to.mtime) ? new Date(c.to.mtime).toISOString() : undefined;
    const edge = buildEdge(c.from, endpointFromRow(c.to), c.from.stopCause.error || 'rate_limit', 'backfill', true, inferredAt);
    // Reported, not abandoned: a batch that dies mid-way had already written real
    // records, and claiming none were written is the wrong half of the truth.
    try { written.push(path.basename(ledgerWrite(edge))); } catch (e) {
      writeError = e && e.message ? e.message : 'write failed';
      break;
    }
  }
  if (opts.json) return print(JSON.stringify({ dryRun: false, applied: true, refusal: null, written: written.length, files: written, writeError, refusedRecords: refusedCount, ledgerError: LEDGER_DIR_ERROR, schemaNewer: LEDGER_SCHEMA_NEWER, skipped: SKIPPED }, null, 2));
  print(`BACKFILL APPLIED — ${written.length} inferred edge(s) recorded in ${LEDGER_DIR}`);
  if (writeError) print(`BACKFILL INCOMPLETE — stopped after ${written.length} edge(s): ${writeError}`);
}

function cmdLineage(opts) {
  // Three modes with nothing in common ride on flags here: --diagnose reports on
  // desktop-store probing and not on lineage at all, --backfill --apply is a bulk
  // WRITE, and the default plus --where are reads. Dispatching on the first flag
  // that happens to be set meant `lineage --diagnose --backfill --apply` parsed
  // cleanly and silently ran the diagnostic, so a caller who asked for a write got
  // a report and no record -- a silent no-op on the one mode that mutates.
  const modes = [opts.diagnose && '--diagnose', opts.backfill && '--backfill', opts.where && '--where'].filter(Boolean);
  if (modes.length > 1) fail(`lineage takes one mode at a time; got ${modes.join(' and ')}`);
  if (opts.apply && !opts.backfill) fail('--apply belongs to lineage --backfill; it does nothing on its own');
  if (opts.diagnose) return lineageDiagnose(opts);
  if (opts.backfill) return lineageBackfill(opts);
  const edges = dedupeEdges(ledgerRead());
  const live = liveRegistry();
  const ctx = opts.all ? null : repoContext(opts.repo || process.cwd());
  // Absolute roots only. A basename arm made ~/work/clientA/api and
  // ~/work/clientB/api share one lineage scope — the collision SKILL.md already
  // documents for brief targets.
  // Canonicalized on both sides. A record stores the path as it was resolved when
  // the edge was written, and on macOS /var and /private/var name the same
  // directory — an uncanonical comparison silently scoped a repo's own handovers
  // out of its own listing.
  const canon = (v) => {
    if (!v) return null;
    try { return fs.realpathSync.native(v); } catch { return path.resolve(v); }
  };
  const ctxRoot = ctx ? canon(ctx.root) : null;
  const ctxTrees = ctx ? new Set([...ctx.worktrees].map(canon)) : null;
  const inScope = (e) => {
    if (!ctx) return true;
    if (!e.repo || !e.repo.root) return false;
    const r = canon(e.repo.root);
    // Containment as well as equality: nearestRepoRoot answers with a NESTED repo
    // or submodule when one exists, so an exact-match rule scoped a repo's own
    // handovers out of its own listing. The clientA/api vs clientB/api
    // discrimination survives, because both sides are absolute and canonical.
    return r === ctxRoot || ctxTrees.has(r) || (ctxRoot && r.startsWith(`${ctxRoot}${path.sep}`));
  };
  // Collapsed for every COUNT and every rendered line: the store is deliberately
  // append-only and re-running `takeover` is a documented routine step, so raw
  // record counts would report one handover twice.
  const scoped = dedupeEdges(edges.filter(inScope));
  const me = selfIdentity();

  if (opts.where) {
    const want = String(opts.where).trim().toLowerCase();
    // The same floor resolve() applies. Without it `--where " "` trims to an empty
    // prefix that startsWith matches for every edge, and the command then prints a
    // confident CONTINUED IN for a blank query.
    if (want.length < 6) fail('--where needs a session id or a prefix of at least 6 characters');
    const match = edges.filter((e) => e.from.sessionId.toLowerCase().startsWith(want) || e.to.sessionId.toLowerCase().startsWith(want));
    // Both endpoints per edge: preferring `from` hid the case where a single edge
    // has two endpoints sharing the queried prefix, and the walk then answered for
    // one of two candidates without saying so.
    const distinctSet = new Set();
    for (const e of match) {
      if (e.from.sessionId.toLowerCase().startsWith(want)) distinctSet.add(e.from.sessionId);
      if (e.to.sessionId.toLowerCase().startsWith(want)) distinctSet.add(e.to.sessionId);
    }
    const distinct = [...distinctSet];
    if (distinct.length > 1) {
      print(`ambiguous --where "${opts.where}" — ${distinct.length} candidates:\n`);
      for (const sid of distinct) print(`  ${sid}`);
      flush();
      process.exit(2);
    }
    if (!match.length) {
      if (opts.json) return print(JSON.stringify({ query: opts.where, found: false, ledgerError: LEDGER_DIR_ERROR, schemaNewer: LEDGER_SCHEMA_NEWER, skipped: SKIPPED }, null, 2));
      print(`No lineage recorded for "${opts.where}".`);
      // An empty match set has THREE causes and only one of them is "nothing was
      // recorded". The sibling branch below already refuses to read an unreadable
      // ledger as an empty history; this branch asserted the opposite for the same
      // state, and then sent the user to --backfill, which refuses on exactly that
      // condition. A confident wrong diagnosis is the one answer this feature exists
      // to prevent, so the cause is named before the conclusion is drawn.
      if (LEDGER_DIR_ERROR) {
        print(`The ledger could not be read (${LEDGER_DIR_ERROR}) — this is NOT evidence that it was never handed over.`);
        print(`Fix ${LEDGER_DIR}, then re-run. \`lineage --diagnose\` names what failed.`);
        return;
      }
      if (LEDGER_REFUSED) {
        print(`${LEDGER_REFUSED} ledger record(s) could not be read — one of them may name that session.`);
        print(`Fix or remove them in ${LEDGER_DIR}, then re-run before concluding anything.`);
        return;
      }
      print('Either that session was never handed over, or the handover predates the ledger.');
      print(`Try: node ${scriptPath()} lineage --backfill`);
      return;
    }
    // Walked from the QUERIED session, not from the predecessor of the matched
    // edge: starting at the `from` made a predecessor's newest branch the answer,
    // so a question about one session was answered with a sibling's continuation.
    const start = distinct[0];
    const walk = walkChain(start, edges);
    const links = walk.links;
    // A leaf has no outgoing edge, so the answer is the INCOMING edge's real
    // endpoint — a fabricated one printed "CONTINUED IN <the id you asked about>"
    // with an unknown worktree and no chain, discarding what the ledger holds.
    const incoming = edges.filter((e) => e.to.sessionId === start)
      .sort((a, b) => String(a.recordedAt || '').localeCompare(String(b.recordedAt || '')))
      .pop();
    const last = links.length ? links[links.length - 1].to
      : (incoming ? incoming.to : makeEndpoint({ sessionId: start }));
    const isLeaf = !links.length;
    if (opts.json) {
      return print(JSON.stringify({ query: opts.where, found: true, start, current: last, live: liveState(last.sessionId, live), links, forks: walk.forks, truncated: walk.truncated, ledgerError: LEDGER_DIR_ERROR, schemaNewer: LEDGER_SCHEMA_NEWER, skipped: SKIPPED }, null, 2));
    }
    print(`${isLeaf ? 'THIS IS THE END OF THE CHAIN' : 'CONTINUED IN'}  ${last.sessionId.slice(0, 8)}   ${endpointLabel(last)}   ${liveState(last.sessionId, live)}`);
    print(`WORKTREE      ${last.worktree || '(unknown)'}${last.branch ? `   branch ${last.branch}` : ''}`);
    if (last.pid) print(`PID           ${last.pid}${last.appPid ? `   window pid ${last.appPid}` : ''}`);
    print('');
    printChain(links, live, me, walk.forks);
    if (walk.truncated) print('  ! chain truncated at the hop bound — it is longer than shown');
    return;
  }

  if (opts.json) {
    const chains = chainRoots(scoped).map((root) => {
      const w = walkChain(root, scoped);
      return { root, links: w.links, forks: w.forks };
    });
    return print(JSON.stringify({ repo: ctx && ctx.root, chains, edgeCount: scoped.length, ledgerError: LEDGER_DIR_ERROR, schemaNewer: LEDGER_SCHEMA_NEWER, skipped: SKIPPED }, null, 2));
  }
  print(`SCOPE  ${ctx ? `${ctx.name} (${ctx.root})` : 'ALL REPOS'}`);
  print(`RECORDED HANDOVERS: ${scoped.length}\n`);
  if (!scoped.length) {
    if (LEDGER_DIR_ERROR) {
      print(`The ledger could not be read (${LEDGER_DIR_ERROR}) — this is NOT evidence that no handover was recorded.`);
      print(`Check ${LEDGER_DIR}, then re-run.`);
      return;
    }
    if (LEDGER_SCHEMA_NEWER) {
      print('The ledger holds records written by a NEWER schema than this build can read.');
      print('Update the plugin rather than treating this as an empty history.');
      return;
    }
    const siblings = siblingLedgerVersions(CONFIG_ROOT);
    if (siblings.length) {
      // Reached by an ordinary plugin upgrade, not by a rare condition: the store is
      // partitioned by schema version, so a bump makes every recorded handover read
      // as none. Saying so BEFORE the --backfill offer is the whole point -- the
      // offer invites the user to replace intact records with guesses.
      const total = siblings.reduce((n, v) => n + v.records, 0);
      print(`No handover is recorded under the schema this build reads (v${LEDGER_SCHEMA_VERSION}).`);
      print(`${total} record(s) exist under ${siblings.map((v) => `${v.version} (${v.records})`).join(', ')} in ${path.join(CONFIG_ROOT, 'zensu', 'session-lineage')}.`);
      print('That is your history, written by another build of this plugin. It is NOT lost, and');
      print('it is NOT reconstructable by --backfill — do not run that here, it would mint guesses');
      print('beside intact records. Use the build that wrote them, or move the records by hand.');
      return;
    }
    print('No handover has been recorded yet.');
    print(`Past ones can be reconstructed as GUESSES: node ${scriptPath()} lineage --backfill`);
    return;
  }
  for (const root of chainRoots(scoped)) {
    const { links, forks } = walkChain(root, scoped);
    if (!links.length) continue;
    const wt = links[0].to.worktree || links[0].from.worktree;
    print(`CHAIN  ${links[0].repo && links[0].repo.name ? links[0].repo.name : '(unknown repo)'}${wt ? `   ${path.basename(wt)}` : ''}`);
    printChain(links, live, me, forks);
    print('');
  }
}

function printChain(links, live, me, forks = []) {
  if (!links.length) return;
  for (const f of forks) {
    print(`  ! ${f.at.slice(0, 8)} was taken over more than once — following ${f.taken.slice(0, 8)}, also recorded: ${f.alsoTo.map((s2) => s2.slice(0, 8)).join(', ')}`);
  }
  const seq = [links[0].from, ...links.map((l) => l.to)];
  seq.forEach((ep, i) => {
    const edge = i === 0 ? null : links[i - 1];
    const here = me.sessionId && ep.sessionId === me.sessionId ? '   ← HERE' : '';
    const inferred = edge && edge.inferred ? '   [inferred — a guess from --backfill, not a recorded handover]' : '';
    print(`  ${String(i + 1).padStart(2)}. ${ep.sessionId.slice(0, 8)}   ${endpointLabel(ep).padEnd(26)} ${liveState(ep.sessionId, live).padEnd(12)}${here}`);
    if (ep.worktree) print(`      ${ep.worktree}${ep.branch ? `   ${ep.branch}` : ''}`);
    if (edge) print(`      handed over ${String(edge.recordedAt || '').slice(0, 16)}   reason: ${edge.reason}${inferred}`);
  });
}

let buffer = [];
function print(s) { buffer.push(s); }
// Emitted from the dispatcher, not from one command: every command path can
// increment SKIPPED, so surfacing it in cmdList alone would leave show,
// limited, takeover and handoff silently incomplete at exit 0.
// Never appended under --json: the payloads already carry a `skipped` field,
// and trailing prose would turn a degraded-but-parseable answer into a hard
// JSON.parse failure at exit 0.
function skippedNote() { return SKIPPED && !JSON_MODE ? `\nNOTE   ${SKIPPED} record(s) unreadable and skipped — this output is incomplete` : ''; }
function flush() {
  const note = skippedNote();
  if (!buffer.length && !note) return;
  process.stdout.write(`${buffer.join('\n')}${note}\n`);
  buffer = [];
}
// fileURLToPath, not URL.pathname: the latter is percent-encoded and carries a
// leading slash before a Windows drive letter, so the printed hint was unusable
// there and on any path containing a space.
function scriptPath() { return fileURLToPath(import.meta.url); }

const argv = process.argv.slice(2);
const opts = parseArgs(argv);
const cmd = opts._[0] || 'list';
// Keyed to whether a JSON payload is actually EMITTED, not to the flag:
// handoff ignores --json and always emits markdown, so suppressing the note
// there would drop the count on every channel at once.
JSON_MODE = opts.json && cmd !== 'handoff';
// Roots are resolved before any command runs, never at module load: --config-dir
// is only known once argv is parsed, and a command that read the default root first
// would write its ledger into ~/.claude while reading sessions from elsewhere.
resolveRoots(opts.configDir);
if (cmd === 'list') cmdList(opts);
else if (cmd === 'instances') cmdInstances(opts);
else if (cmd === 'show') cmdShow(opts);
else if (cmd === 'handoff') cmdHandoff(opts);
else if (cmd === 'limited') cmdLimited(opts);
else if (cmd === 'takeover') cmdTakeover(opts);
else if (cmd === 'lineage') cmdLineage(opts);
else if (cmd === 'adopt') cmdAdopt(opts);
else if (cmd === 'label') cmdLabel(opts);
// Deliberately absent from the help text and from the unknown-command list: it is a
// test seam, it reads its table from stdin rather than from the machine, and it
// writes nothing. SKILL.md DOES document it, marked as a seam and not for use --
// the structure suite pins that no dispatched command is undocumented, and that pin
// is right: a hidden verb is exactly what it exists to catch.
else if (cmd === 'window-probe') print(JSON.stringify({ ...windowProbe(fs.readFileSync(0, 'utf8')), skipped: SKIPPED }, null, 2));
else fail(`unknown command: ${cmd} (list | instances | show | handoff | limited | takeover | lineage | adopt | label)`);
flush();
