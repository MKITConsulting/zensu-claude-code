#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';

const HOME = os.homedir();
const PROJECTS = path.join(HOME, '.claude', 'projects');
const SESSIONS = path.join(HOME, '.claude', 'sessions');
const HANDOFFS = path.join(HOME, '.claude', 'handoffs');
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
  const out = { _: [], days: 21, prompts: 12, json: false, all: false, live: false, git: true, repo: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') out.json = true;
    else if (a === '--all') out.all = true;
    else if (a === '--live') out.live = true;
    else if (a === '--no-git') out.git = false;
    else if (a === '--days') out.days = Number(argv[++i]);
    else if (a === '--prompts') out.prompts = Number(argv[++i]);
    else if (a === '--repo') out.repo = argv[++i];
    else if (a.startsWith('--')) fail(`unknown flag: ${a}`);
    else out._.push(a);
  }
  return out;
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

const CCD_STORE = path.join(HOME, 'Library', 'Application Support', 'Claude', 'claude-code-sessions');
let CCD_CACHE = null;

function ccdIndex() {
  if (CCD_CACHE) return CCD_CACHE;
  const map = new Map();
  CCD_CACHE = map;
  if (!dirExists(CCD_STORE)) return map;
  const walk = (dir, depth, instance) => {
    if (depth > 3) return;
    let es;
    try { es = fs.readdirSync(dir, { withFileTypes: true }); } catch { SKIPPED += 1; return; }
    for (const e of es) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) { walk(p, depth + 1, instance || e.name); continue; }
      if (!/^local_.*\.json$/.test(e.name)) continue;
      let o;
      try { o = JSON.parse(fs.readFileSync(p, 'utf8')); } catch { continue; }
      if (!o || !o.cliSessionId) continue;
      map.set(o.cliSessionId, {
        instance: instance || '?',
        archived: o.isArchived === true,
        title: o.title || null,
        model: o.model || null,
        effort: o.effort || null,
        permissionMode: o.permissionMode || null,
        lastFocusedAt: o.lastFocusedAt || null,
      });
    }
  };
  walk(CCD_STORE, 0, null);
  return map;
}

function appTag(app) {
  if (!app) return '';
  return `${app.archived ? '[ARCHIVED] ' : ''}inst ${app.instance.slice(0, 8)}`;
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

function readTranscript(file, size) {
  if (size <= FULL_READ_LIMIT) return fs.readFileSync(file, 'utf8');
  const fd = fs.openSync(file, 'r');
  try {
    const head = Buffer.alloc(HEAD_BYTES);
    fs.readSync(fd, head, 0, HEAD_BYTES, 0);
    const tail = Buffer.alloc(TAIL_BYTES);
    fs.readSync(fd, tail, 0, TAIL_BYTES, size - TAIL_BYTES);
    return `${head.toString('utf8')}\n${tail.toString('utf8')}`;
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

function extractStopCause(text) {
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
  return {
    error: err.error || 'api_error',
    status: err.apiErrorStatus || null,
    at: err.timestamp || null,
    message: String(msg || '').trim(),
    final: laterTurns === 0,
    laterTurns,
    resumedUntil: lastTurnAt,
  };
}

function extractPendingQueue(text) {
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

const BUSY_IDLE_MIN = 15;

function activityVerdict(r) {
  const idleMin = Math.round((Date.now() - r.mtime) / 60000);
  const q = r.queue || { pending: 0 };
  if (r.app && r.app.archived) {
    return { level: 'FREE', idleMin, reason: 'the desktop app archived this session — its process was stopped' };
  }
  if (!r.live) {
    return { level: 'FREE', idleMin, reason: 'no live process holds this worktree' };
  }
  if (q.pending > 0) {
    return { level: 'BUSY', idleMin, reason: `pid ${r.live.pid} has ${q.pending} prompt(s) queued and will act on its own` };
  }
  if (idleMin < BUSY_IDLE_MIN) {
    return { level: 'BUSY', idleMin, reason: `pid ${r.live.pid} wrote to its transcript ${idleMin} min ago — it is actively working` };
  }
  return {
    level: 'PROBABLY_FREE',
    idleMin,
    reason: `pid ${r.live.pid} is alive but has been silent for ${ago(r.mtime)} with nothing queued — it cannot act unless the user types in that window`,
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

function summarize(file, size, deep) {
  const text = readTranscript(file, size);
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
    pr: prs.length ? { number: prs[prs.length - 1].prNumber, url: prs[prs.length - 1].prUrl, repository: prs[prs.length - 1].prRepository } : null,
    truncated: size > FULL_READ_LIMIT,
    stopCause: extractStopCause(text),
    queue: extractPendingQueue(text),
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

function buildIndex(opts) {
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
  return cwd === ctx.root || cwd.startsWith(`${ctx.root}${path.sep}`);
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

function oneLine(s, n) {
  if (!s) return '';
  const t = String(s).replace(/\s+/g, ' ').trim();
  return t.length > n ? `${t.slice(0, n - 1)}…` : t;
}

function cmdList(opts) {
  const { rows, ctx } = buildIndex(opts);
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
    const owner = r.live ? `pid ${r.live.pid} ${activityVerdict(r).level}` : '';
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
  if (opts.json) return print(JSON.stringify({ rows, skipped: SKIPPED }, null, 2));
  const memo = new Map();
  const groups = new Map();
  for (const s of rows) {
    const hasCwd = typeof s.cwd === 'string' && s.cwd !== '';
    const root = !hasCwd ? '(cwd not recorded)'
      : dirExists(s.cwd) ? (nearestRepoRoot(s.cwd, memo) || s.cwd) : path.dirname(s.cwd);
    if (!groups.has(root)) groups.set(root, []);
    groups.get(root).push(s);
  }
  const insts = new Set();
  for (const s of rows) { const a = ccdIndex().get(s.sessionId); if (a) insts.add(a.instance); }
  print(`LIVE CLAUDE CODE SESSIONS: ${rows.length} (every session process on this machine)`);
  print(`DESKTOP INSTANCES INVOLVED: ${insts.size}${insts.size ? ` — ${[...insts].map((i) => i.slice(0, 8)).join(', ')}` : ''}\n`);
  for (const [root, list] of [...groups.entries()].sort()) {
    print(`${root}  (${list.length})`);
    for (const s of list) {
      const wt = typeof s.cwd !== 'string' || s.cwd === '' ? '(cwd not recorded)'
        : s.cwd === root ? '(main checkout)' : path.relative(root, s.cwd);
      const app = ccdIndex().get(s.sessionId) || null;
      print(`  ${String(s.pid).padStart(6)}  ${s.sessionId.slice(0, 8)}  ${(s.entrypoint || '?').padEnd(15)}  ${ago(s.startedAt).padStart(8)} old  ${wt}`);
      print(`          "${oneLine(s.name, 92)}"${app ? `   ${appTag(app)}` : ''}`);
    }
    print('');
  }
}

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
  for (const t of tiers) {
    if (t.length === 1) return t[0];
    if (t.length > 1) {
      const byWorktree = new Set(t.map((r) => r.cwd));
      if (byWorktree.size === 1) return t.sort((a, b) => b.mtime - a.mtime)[0];
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

function siblings(opts, row) {
  const { rows } = buildIndex({ ...opts, live: false });
  return rows.filter((r) => r.wt === row.wt && r.sessionId !== row.sessionId);
}

function cmdShow(opts) {
  const base = resolve(opts, opts._[1]);
  const r = hydrate(base);
  const g = opts.git ? gitState(r.wt, true) : null;
  if (opts.json) return print(JSON.stringify({ ...r, git: g, skipped: SKIPPED }, null, 2));
  print(`SESSION  ${r.sessionId}`);
  print(`TITLE    ${r.title || '(none)'}`);
  print(`STATUS   ${statusOf(r)}${r.live ? `  pid ${r.live.pid}  ${r.live.entrypoint}  name "${r.live.name}"` : ''}`);
  if (r.app) {
    print(`OWNER    desktop instance ${r.app.instance}${r.app.archived ? '   **ARCHIVED** (process stopped, worktree may have been cleaned up)' : ''}`);
    print(`CONFIG   model ${r.app.model || '?'}   effort ${r.app.effort || '?'}   permissions ${r.app.permissionMode || '?'}`);
  }
  print(`WORKTREE ${r.wt}${r.cwdExists ? '' : '   !! MISSING'}`);
  if (r.cwd !== r.wt) print(`CWD      ${r.cwd}   (session started in a subdirectory)`);
  print(`BRANCH   ${(g && g.branch) || r.branch || '?'}`);
  print(`LAST     ${ago(r.mtime)} ago   transcript ${r.transcript}`);
  if (r.pr) print(`PR       #${r.pr.number}  ${r.pr.url}`);
  if (r.stopCause && r.stopCause.final) print(`STOPPED  ${r.stopCause.error}${r.stopCause.status ? ` (${r.stopCause.status})` : ''} at ${(r.stopCause.at || '').slice(0, 16)} — "${oneLine(r.stopCause.message, 90)}"`);
  else if (r.stopCause) print(`NOTE     hit ${r.stopCause.error} at ${(r.stopCause.at || '').slice(0, 16)} but recovered (${r.stopCause.laterTurns} turns after, last ${(r.stopCause.resumedUntil || '').slice(0, 16)})`);
  if (r.truncated) print('NOTE     transcript is large — head+tail only, middle not scanned');
  const sib = siblings(opts, r);
  if (sib.length) print(`SIBLINGS ${sib.map((s) => `${s.sessionId.slice(0, 8)}(${statusOf(s)})`).join(' ')}  — same worktree, other sessions`);
  const v = activityVerdict(r);
  print('');
  print(`TAKEOVER ${v.level} — ${v.reason}`);
  if (v.level === 'FREE') print('         Nothing holds this worktree. Take it over.');
  if (v.level === 'PROBABLY_FREE') print('         Proceed, but tell the user not to type in that window, and check for dev servers it may still own.');
  if (v.level === 'BUSY') print('         Do NOT edit this worktree. Read-only follow, or ask the user to park that window.');
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
  const stalled = hit.filter((r) => r.stopCause.final);
  const recovered = hit.filter((r) => !r.stopCause.final);
  if (opts.json) return print(JSON.stringify({ repo: ctx && ctx.root, stalled, recovered, skipped: SKIPPED }, null, 2));
  print(`SCOPE  ${ctx ? `${ctx.name} (${ctx.root})` : 'ALL REPOS'}`);
  print(`STALLED AT AN API LIMIT/ERROR: ${stalled.length}   RECOVERED AFTERWARDS: ${recovered.length}   (of ${rows.length} scanned)\n`);
  const line = (r) => {
    print(`${statusOf(r).padEnd(4)}  ${r.sessionId.slice(0, 8)}  ${ago(r.mtime).padStart(8)} ago  ${r.worktree}`);
    print(`      cause: ${r.stopCause.error}${r.stopCause.status ? ` (${r.stopCause.status})` : ''} at ${(r.stopCause.at || '').slice(0, 16)}`);
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
  if (opts.json) return print(JSON.stringify({ ...r, git: g, diff: d, target, skipped: SKIPPED }, null, 2));
  const L = [];
  L.push(`# Takeover: ${r.title || path.basename(r.wt)}`);
  L.push('');
  L.push('> Reconstructed from the source session\'s transcript on disk. That session contributed nothing to this document and did not need to be running.');
  L.push('');
  L.push('## Source');
  L.push(`- session: \`${r.sessionId}\` (${statusOf(r)}${r.live ? `, STILL RUNNING as pid ${r.live.pid}` : ''})`);
  if (r.app) L.push(`- owning desktop instance: \`${r.app.instance}\`${r.app.archived ? ' — **ARCHIVED**: its process was stopped and the worktree may have been cleaned up' : ''}`);
  L.push(`- takeover verdict: **${activityVerdict(r).level}** — ${activityVerdict(r).reason}`);
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
    L.push(`- [${t.status}] **#${t.id} ${t.subject}**`);
    if (t.description) L.push(`  - ${clip(t.description, 600)}`);
  }
  const open = tasks.filter((t) => t.status !== 'completed');
  if (open.length) L.push(`\n**${open.length} task(s) not completed: ${open.map((t) => `#${t.id}`).join(', ')}**`);
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
  const tv = activityVerdict(r);
  if (tv.level === 'BUSY') L.push(`4. ⚠️ **STOP** — ${tv.reason}. Do not edit this worktree.`);
  else if (tv.level === 'PROBABLY_FREE') L.push(`4. ${tv.reason}. Taking over is fine; tell the user not to type in that window, and check whether it still owns dev servers or ports.`);
  print(`TAKEOVER_TARGET: ${target}`);
  print('--- BEGIN TAKEOVER MARKDOWN ---');
  print(L.join('\n'));
  print('--- END TAKEOVER MARKDOWN ---');
}

function handoffPath(r, ctx, liveBranch) {
  const root = (r.cwdExists && nearestRepoRoot(r.wt, new Map())) || null;
  const repo = (root && path.basename(root)) || (ctx && ctx.name) || path.basename(path.dirname(r.wt));
  const usable = (b) => (b && b !== 'HEAD' ? b : null);
  const branch = (usable(r.branch) || usable(liveBranch) || path.basename(r.wt)).replace(/[^A-Za-z0-9._-]/g, '-');
  return path.join(HANDOFFS, repo, `${branch}.md`);
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
  L.push(`- session: \`${r.sessionId}\` (${statusOf(r)}${r.live ? `, pid ${r.live.pid}, ${r.live.entrypoint}` : ''})`);
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
    L.push('');
    L.push(`> **Still running** in pid ${r.live.pid}. Stop that instance before editing this worktree.`);
  }
  print(`HANDOFF_TARGET: ${target}`);
  print('--- BEGIN HANDOFF MARKDOWN ---');
  print(L.join('\n'));
  print('--- END HANDOFF MARKDOWN ---');
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
function scriptPath() { return new URL(import.meta.url).pathname; }

const argv = process.argv.slice(2);
const opts = parseArgs(argv);
const cmd = opts._[0] || 'list';
// Keyed to whether a JSON payload is actually EMITTED, not to the flag:
// handoff ignores --json and always emits markdown, so suppressing the note
// there would drop the count on every channel at once.
JSON_MODE = opts.json && cmd !== 'handoff';
if (cmd === 'list') cmdList(opts);
else if (cmd === 'instances') cmdInstances(opts);
else if (cmd === 'show') cmdShow(opts);
else if (cmd === 'handoff') cmdHandoff(opts);
else if (cmd === 'limited') cmdLimited(opts);
else if (cmd === 'takeover') cmdTakeover(opts);
else fail(`unknown command: ${cmd} (list | instances | show | handoff | limited | takeover)`);
flush();
