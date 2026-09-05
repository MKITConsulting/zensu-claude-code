'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const floor = require('./verify-navigation-floor-v1.js');

const CONSENT_MATCHER = 'mcp__(plugin_zensu_)?playwright__browser_(navigate|tabs)';
const NAVIGATION_TOOL_RE = /^mcp__(plugin_zensu_)?playwright__browser_(navigate|tabs)$/;
const MEMORY_VERSION = 1;
const MEMORY_NAME_RE = /^verify-consent-scv1_[a-f0-9]{64}\.json$/;
const MAX_MEMORY_BYTES = 65536;
const MAX_RECORDS = 512;
const DECIDED_BY = Object.freeze(['prompt', 'memory', 'policy']);

const REASONS = Object.freeze({
  NOT_A_NAVIGATION: 'not-a-navigation',
  POLICY_MODE: 'policy-mode',
  MEMORY_HIT: 'origin-and-route-in-session-memory',
  DECLARED_ROUTE: 'known-origin-declared-route',
  NEW_ORIGIN: 'new-origin-needs-consent',
  UNDECLARED_ROUTE: 'undeclared-route-needs-consent',
  REMOTE_NEEDS_POLICY: `remote-target-needs-parent-environment-policy: ${floor.CONSENT_REMOTE_REASON}`,
  PAYLOAD_UNREADABLE: 'hook-payload-unreadable',
  MEMORY_UNREADABLE: 'consent-memory-unreadable',
  MEMORY_PATH_REFUSED: 'consent-memory-path-refused',
});

const FOREIGN_SERVER_NOTE = 'This gate matches on the tool name alone, and the bare mcp__playwright__ spelling belongs to any MCP server keyed "playwright". If this navigation is not a /zensu:verify-feature run, the tool is served by a different server and this refusal is not about your request: ask the user to rename that server key, or to launch Claude Code with ZENSU_VERIFY_NAVIGATION_POLICY_V1 set in its environment. Never set that variable from a Bash call — it is read once when the browser broker starts.';

function payloadFromRaw(raw, accumulationFailed) {
  if (accumulationFailed) return null;
  try {
    return JSON.parse(raw || '{}');
  } catch (_error) {
    return null;
  }
}

function targetOf(toolName, toolInput) {
  if (typeof toolName !== 'string' || !NAVIGATION_TOOL_RE.test(toolName)) return null;
  const input = toolInput && typeof toolInput === 'object' ? toolInput : {};
  if (/browser_navigate$/.test(toolName)) {
    return typeof input.url === 'string' ? input.url : null;
  }
  if (input.action === 'new' && typeof input.url === 'string' && input.url) return input.url;
  return null;
}

function normalizeRoutes(declaredRoutes) {
  if (!Array.isArray(declaredRoutes)) return [];
  const routes = [];
  for (const route of declaredRoutes) {
    const normalized = floor.normalizeRoute(route);
    if (normalized !== null && !routes.includes(normalized)) routes.push(normalized);
  }
  return routes;
}

// Date.parse accepts "July 4, 2026" and "2026-02-31T00:00:00.000Z", so validity is not the
// same question as shape. Same predicate, and the same reason, as isIsoInstant in
// skills/session-trail/scripts/session-lineage-v1.mjs: a stamp only orders correctly for the
// fixed-width UTC spelling toISOString() produces, which is the only spelling this module writes.
const ISO_INSTANT_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

function isIsoInstant(value) {
  return typeof value === 'string' && ISO_INSTANT_RE.test(value)
    && new Date(value).toISOString() === value;
}

function validDeclaredRoutes(value) {
  if (value === undefined) return true;
  return Array.isArray(value) && value.length <= MAX_RECORDS
    && value.every((route) => typeof route === 'string' && floor.normalizeRoute(route) === route);
}

function validRecord(record) {
  return record && typeof record === 'object'
    && typeof record.origin === 'string' && record.origin.length > 0
    && typeof record.route === 'string' && record.route.startsWith('/')
    && DECIDED_BY.includes(record.decidedBy)
    && isIsoInstant(record.at)
    && validDeclaredRoutes(record.declaredRoutes);
}

function consentedRoutes(records, origin) {
  const routes = [];
  for (const entry of records) {
    if (entry.origin !== origin || !Array.isArray(entry.declaredRoutes)) continue;
    for (const route of entry.declaredRoutes) if (!routes.includes(route)) routes.push(route);
  }
  return routes;
}

function emptyMemory() {
  return { version: MEMORY_VERSION, records: [] };
}

function readMemory(memoryPath) {
  if (typeof memoryPath !== 'string' || !memoryPath) return { ok: true, records: [], absent: true };
  let info;
  try { info = fs.lstatSync(memoryPath); }
  catch (error) {
    if (error && error.code === 'ENOENT') return { ok: true, records: [], absent: true };
    return { ok: false, reason: REASONS.MEMORY_UNREADABLE, records: [] };
  }
  if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1 || info.size > MAX_MEMORY_BYTES) {
    return { ok: false, reason: REASONS.MEMORY_UNREADABLE, records: [] };
  }
  let parsed;
  try { parsed = JSON.parse(fs.readFileSync(memoryPath, 'utf8')); }
  catch (_error) { return { ok: false, reason: REASONS.MEMORY_UNREADABLE, records: [] }; }
  if (!parsed || typeof parsed !== 'object' || parsed.version !== MEMORY_VERSION || !Array.isArray(parsed.records)
      || parsed.records.length > MAX_RECORDS || !parsed.records.every(validRecord)) {
    return { ok: false, reason: REASONS.MEMORY_UNREADABLE, records: [] };
  }
  return { ok: true, records: parsed.records, absent: false };
}

function memoryPathAllowed(memoryPath, projectRoot) {
  if (typeof memoryPath !== 'string' || !path.isAbsolute(memoryPath)) return { ok: false, reason: REASONS.MEMORY_PATH_REFUSED };
  if (typeof projectRoot !== 'string' || !path.isAbsolute(projectRoot)) return { ok: false, reason: REASONS.MEMORY_PATH_REFUSED };
  if (!MEMORY_NAME_RE.test(path.basename(memoryPath))) return { ok: false, reason: REASONS.MEMORY_PATH_REFUSED };
  let rootReal;
  try { rootReal = fs.realpathSync.native(projectRoot); }
  catch (_error) { return { ok: false, reason: REASONS.MEMORY_PATH_REFUSED }; }
  const stateDir = path.join(rootReal, '.zensu', 'state');
  if (path.dirname(memoryPath) !== stateDir) return { ok: false, reason: REASONS.MEMORY_PATH_REFUSED };
  for (const component of [path.join(rootReal, '.zensu'), stateDir]) {
    let info;
    try { info = fs.lstatSync(component); }
    catch (_error) { return { ok: false, reason: REASONS.MEMORY_PATH_REFUSED }; }
    if (!info.isDirectory() || info.isSymbolicLink()) return { ok: false, reason: REASONS.MEMORY_PATH_REFUSED };
  }
  let leaf = null;
  try { leaf = fs.lstatSync(memoryPath); }
  catch (error) {
    if (!error || error.code !== 'ENOENT') return { ok: false, reason: REASONS.MEMORY_PATH_REFUSED };
  }
  if (leaf && (!leaf.isFile() || leaf.isSymbolicLink() || leaf.nlink !== 1)) {
    return { ok: false, reason: REASONS.MEMORY_PATH_REFUSED };
  }
  return { ok: true, stateDir };
}

function appendRecord(memoryPath, record, options = {}) {
  if (!validRecord(record)) return { ok: false, reason: 'record-invalid' };
  const allowed = memoryPathAllowed(memoryPath, options.projectRoot);
  if (!allowed.ok) return allowed;
  const current = readMemory(memoryPath);
  const records = current.ok ? current.records.slice() : [];
  if (records.some((entry) => entry.origin === record.origin && entry.route === record.route)) {
    return { ok: true, records, duplicate: true };
  }
  if (records.length >= MAX_RECORDS) return { ok: false, reason: 'memory-full' };
  const entry = { origin: record.origin, route: record.route, decidedBy: record.decidedBy, at: record.at };
  if (Array.isArray(record.declaredRoutes)) entry.declaredRoutes = normalizeRoutes(record.declaredRoutes);
  records.push(entry);
  const body = `${JSON.stringify({ version: MEMORY_VERSION, records })}\n`;
  const temp = path.join(allowed.stateDir, `.${path.basename(memoryPath)}.${process.pid}.${crypto.randomBytes(6).toString('hex')}.tmp`);
  try {
    const fd = fs.openSync(temp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
    try {
      fs.writeSync(fd, body);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(temp, memoryPath);
  } catch (error) {
    try { fs.unlinkSync(temp); } catch (_ignore) { /* nothing to remove */ }
    return { ok: false, reason: `memory-write-failed:${error && error.code ? error.code : 'unknown'}` };
  }
  return { ok: true, records, duplicate: false };
}

function promptText({ kind, origin, route, mode, declaredRoutes }) {
  const routes = normalizeRoutes(declaredRoutes);
  const modeWord = mode === 'remote' ? 'a deployed (remote) target' : 'a local loopback target';
  const lines = [];
  if (kind === 'route') {
    lines.push(`Zensu verify-feature wants to open the route ${route} on ${origin}, which the runtime recipe does not declare as synthetic-safe.`);
  } else {
    lines.push(`Zensu verify-feature wants to open the browser on ${origin} (${modeWord}), starting with the route ${route}.`);
    if (routes.length > 0) lines.push(`Declared synthetic-safe routes for this run: ${routes.join(', ')}.`);
    else lines.push('No runtime recipe declares synthetic-safe routes for this run; every further route will ask again.');
  }
  lines.push(`Answering Yes lets the model open and read any page on ${origin}, screenshots included, for the rest of this session: once an origin is approved the browser does not check routes again.`);
  lines.push('Answer No to keep the browser closed for this origin; the run then reports PARTIAL.');
  return lines.join(' ');
}

function decide({ toolName, toolInput, records, declaredRoutes, policyPresent }) {
  const target = targetOf(toolName, toolInput);
  if (target === null) return { verdict: 'allow', reason: REASONS.NOT_A_NAVIGATION };
  if (policyPresent) return { verdict: 'allow', reason: REASONS.POLICY_MODE, target };
  const classified = floor.classifyOrigin(target, true);
  if (!classified.ok) {
    return { verdict: 'deny', reason: classified.reason, target, origin: classified.origin || null };
  }
  const { origin, pathname: route, mode } = classified;
  if (mode !== 'local') {
    return { verdict: 'deny', reason: REASONS.REMOTE_NEEDS_POLICY, target, origin, route, mode };
  }
  const known = Array.isArray(records) ? records : [];
  const originKnown = known.some((entry) => entry.origin === origin);
  const routeKnown = known.some((entry) => entry.origin === origin && entry.route === route);
  if (routeKnown) return { verdict: 'allow', reason: REASONS.MEMORY_HIT, target, origin, route, mode, decidedBy: 'memory' };
  const routes = normalizeRoutes(declaredRoutes);
  if (originKnown && consentedRoutes(known, origin).includes(route)) {
    return { verdict: 'allow', reason: REASONS.DECLARED_ROUTE, target, origin, route, mode, decidedBy: 'memory' };
  }
  const kind = originKnown ? 'route' : 'origin';
  return {
    verdict: 'ask',
    reason: originKnown ? REASONS.UNDECLARED_ROUTE : REASONS.NEW_ORIGIN,
    target, origin, route, mode, decidedBy: 'prompt',
    prompt: promptText({ kind, origin, route, mode, declaredRoutes: routes }),
  };
}

function preEnvelope(decision) {
  if (decision.verdict === 'allow') return null;
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: decision.verdict,
      permissionDecisionReason: decision.verdict === 'ask'
        ? decision.prompt
        : `Zensu browser consent gate denied the navigation: ${decision.reason} ${FOREIGN_SERVER_NOTE}`,
    },
  };
}

const MAX_RECIPE_BYTES = 262144;
const RECIPE_NAMES = Object.freeze(['runtime.yaml', 'autopilot.yaml']);

// The ONE resolution of which recipe governs a project. Both hooks and the doctor row
// used to spell this ladder themselves, so a one-sided edit could make the pre hook
// decide against one file while the post hook recorded against another, or make the
// doctor report a recipe the hooks never load.
function resolveRecipeFile(projectRoot) {
  if (typeof projectRoot !== 'string' || !projectRoot) return '';
  for (const name of RECIPE_NAMES) {
    const candidate = path.join(projectRoot, '.zensu', name);
    let info;
    try { info = fs.lstatSync(candidate); }
    catch (_error) { continue; }
    if (info.isFile() && !info.isSymbolicLink()) return candidate;
  }
  return '';
}

function declaredRoutesFromRecipe(text) {
  const lines = String(text).split(/\r?\n/);
  // Anchored on the validate: parent and on depth, so one file cannot mean two things to this
  // reader and to a YAML parser: a stray evidenceSafety: at another level is not this key.
  const validateAt = lines.findIndex((line) => /^validate:\s*$/.test(line));
  if (validateAt === -1) return [];
  const validateIndent = 0;
  let start = -1;
  for (let index = validateAt + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (!line.trim()) continue;
    const indent = (line.match(/^\s*/) || [''])[0].length;
    if (indent <= validateIndent) break;
    if (/^\s*evidenceSafety:\s*$/.test(line)) { start = index; break; }
  }
  if (start === -1) return [];
  const blockIndent = (lines[start].match(/^\s*/) || [''])[0].length;
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (!line.trim()) continue;
    const indent = (line.match(/^\s*/) || [''])[0].length;
    if (indent <= blockIndent) break;
    const flow = line.match(/^\s*routes:\s*\[(.*)\]\s*$/);
    if (flow) {
      return normalizeRoutes(flow[1].split(',').map((item) => item.trim().replace(/^["']|["']$/g, '')).filter(Boolean));
    }
    if (/^\s*routes:\s*$/.test(line)) {
      const routes = [];
      for (let inner = index + 1; inner < lines.length; inner += 1) {
        const item = lines[inner].match(/^\s*-\s*(.+?)\s*$/);
        if (!item) break;
        routes.push(item[1].replace(/^["']|["']$/g, ''));
      }
      return normalizeRoutes(routes);
    }
  }
  return [];
}

function readRecipeRoutes(recipeFile) {
  if (typeof recipeFile !== 'string' || !recipeFile) return [];
  let info;
  try { info = fs.lstatSync(recipeFile); }
  catch (_error) { return []; }
  if (!info.isFile() || info.isSymbolicLink() || info.size > MAX_RECIPE_BYTES) return [];
  try {
    return declaredRoutesFromRecipe(fs.readFileSync(recipeFile, 'utf8'));
  } catch (_error) {
    return [];
  }
}

// The declared routes come from the guarded recipe read and from nowhere else. An
// environment override sat here and short-circuited the branch carrying the lstat,
// symlink and size guards, with no production producer and no hook clearing it — an
// inherited value from the launching shell would have widened the silent-allow set.
function readInputs(env) {
  const projectRoot = env.ZENSU_VERIFY_PROJECT_ROOT || '';
  const declared = readRecipeRoutes(resolveRecipeFile(projectRoot));
  return {
    memoryPath: env.ZENSU_VERIFY_CONSENT_MEMORY || '',
    projectRoot,
    declaredRoutes: declared,
    policyPresent: Boolean(env.ZENSU_VERIFY_NAVIGATION_POLICY_V1),
  };
}

function responseFailed(toolResponse) {
  if (!toolResponse || typeof toolResponse !== 'object') return false;
  if (toolResponse.isError === true) return true;
  const content = Array.isArray(toolResponse.content) ? toolResponse.content : [];
  return content.some((item) => item && typeof item.text === 'string' && item.text.startsWith('Zensu browser broker rejected the operation'));
}

function runPre(payload, env, out, err) {
  if (!payload || typeof payload !== 'object') {
    out.write(JSON.stringify(preEnvelope({ verdict: 'deny', reason: REASONS.PAYLOAD_UNREADABLE })));
    return;
  }
  const inputs = readInputs(env);
  // The same containment the writer applies, so a read and a write can never disagree about
  // which file is this session's memory.
  const allowed = memoryPathAllowed(inputs.memoryPath, inputs.projectRoot);
  const memory = allowed.ok ? readMemory(inputs.memoryPath) : { ok: false, reason: allowed.reason, records: [] };
  if (!memory.ok) err.write(`zensu: verify consent memory ignored (${memory.reason}); the navigation will ask again\n`);
  const decision = decide({
    toolName: payload.tool_name,
    toolInput: payload.tool_input,
    records: memory.records,
    declaredRoutes: inputs.declaredRoutes,
    policyPresent: inputs.policyPresent,
  });
  const envelope = preEnvelope(decision);
  if (envelope) out.write(JSON.stringify(envelope));
}

function runPost(payload, env, err) {
  if (!payload || typeof payload !== 'object') return { ok: false, reason: REASONS.PAYLOAD_UNREADABLE };
  if (responseFailed(payload.tool_response)) return { ok: true, skipped: 'navigation-rejected-by-broker' };
  const inputs = readInputs(env);
  const memory = readMemory(inputs.memoryPath);
  const decision = decide({
    toolName: payload.tool_name,
    toolInput: payload.tool_input,
    records: memory.records,
    declaredRoutes: inputs.declaredRoutes,
    policyPresent: inputs.policyPresent,
  });
  if (decision.reason === REASONS.NOT_A_NAVIGATION || decision.verdict === 'deny') {
    return { ok: true, skipped: decision.reason };
  }
  let decidedBy = decision.decidedBy || 'prompt';
  let origin = decision.origin;
  let route = decision.route;
  if (decision.reason === REASONS.POLICY_MODE) {
    const classified = floor.classifyOrigin(decision.target, true);
    if (!classified.ok) return { ok: true, skipped: classified.reason };
    decidedBy = 'policy';
    origin = classified.origin;
    route = classified.pathname;
  }
  const result = appendRecord(
    inputs.memoryPath,
    { origin, route, decidedBy, at: new Date().toISOString(), declaredRoutes: normalizeRoutes(inputs.declaredRoutes) },
    { projectRoot: inputs.projectRoot },
  );
  if (!result.ok) err.write(`zensu: verify consent memory not written (${result.reason})\n`);
  return result;
}

module.exports = {
  CONSENT_MATCHER,
  DECIDED_BY,
  FOREIGN_SERVER_NOTE,
  MAX_MEMORY_BYTES,
  MAX_RECIPE_BYTES,
  MAX_RECORDS,
  MEMORY_NAME_RE,
  MEMORY_VERSION,
  NAVIGATION_TOOL_RE,
  REASONS,
  RECIPE_NAMES,
  appendRecord,
  consentedRoutes,
  decide,
  declaredRoutesFromRecipe,
  emptyMemory,
  isIsoInstant,
  memoryPathAllowed,
  normalizeRoutes,
  payloadFromRaw,
  preEnvelope,
  promptText,
  readInputs,
  readMemory,
  readRecipeRoutes,
  resolveRecipeFile,
  responseFailed,
  runPost,
  runPre,
  targetOf,
  validRecord,
};

if (require.main === module) {
  const mode = process.argv[2];
  if (mode !== 'pre' && mode !== 'post') {
    process.stderr.write('usage: verify-consent-v1.js pre|post\n');
    process.exitCode = 2;
  } else {
    let raw = '';
    let accumulationFailed = false;
    let settled = false;
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => {
      if (accumulationFailed) return;
      try { raw += chunk; } catch (_error) { accumulationFailed = true; raw = ''; }
    });
    const finalize = () => {
      if (settled) return;
      settled = true;
      const payload = payloadFromRaw(raw, accumulationFailed);
      try {
        if (mode === 'pre') runPre(payload, process.env, process.stdout, process.stderr);
        else runPost(payload, process.env, process.stderr);
      } catch (error) {
        if (mode === 'pre') {
          process.stdout.write(JSON.stringify(preEnvelope({ verdict: 'deny', reason: `hook-failed:${error && error.code ? error.code : 'unknown'}` })));
        } else {
          process.stderr.write('zensu: verify consent memory not written (hook failed)\n');
        }
      }
    };
    process.stdin.on('error', () => { accumulationFailed = true; raw = ''; finalize(); });
    process.stdin.on('end', finalize);
    process.stdin.on('close', finalize);
  }
}
