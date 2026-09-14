#!/usr/bin/env node
'use strict';

const dns = require('node:dns');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');

const POLICY_ENV = 'ZENSU_VERIFY_NAVIGATION_POLICY_V1';
const MAX_MESSAGE_BYTES = 16 * 1024 * 1024;
const ALLOWED_TOOLS = Object.freeze([
  'browser_click',
  'browser_close',
  'browser_console_messages',
  'browser_drag',
  'browser_fill_form',
  'browser_handle_dialog',
  'browser_hover',
  'browser_navigate',
  'browser_network_requests',
  'browser_press_key',
  'browser_resize',
  'browser_select_option',
  'browser_snapshot',
  'browser_tabs',
  'browser_take_screenshot',
  'browser_type',
  'browser_wait_for',
]);
const ALLOWED_TOOL_SET = new Set(ALLOWED_TOOLS);

const {
  CONSENT_REMOTE_REASON,
  FLOOR_REASONS,
  checkNavigationTarget,
  classifyOrigin,
  isLoopbackHost,
  isPublicAddress,
  normalizeHostname,
  normalizeRoute,
  resolveRemoteHost,
} = require(path.join(__dirname, '..', 'hooks', 'lib', 'verify-navigation-floor-v1.js'));

// The three TOP-LEVEL guards below are a hand copy of policyContractFault in
// hooks/lib/verify-navigation-floor-v1.js, which the consent gate and /zensu:doctor call to
// decide whether a policy value is usable. The two must agree in both directions: widen one
// and the gate disarms the floor for a policy this broker refuses to start on; narrow one and
// the doctor reports a fault for a policy that works. They are held in step only by
// tests/structure/verify-navigation-floor-v1.test.js, so an edit HERE -- to a message, to the
// key set, or to the 1..8 target range -- turns a suite named for the floor module red.
async function parsePolicy(raw, resolver = dns.promises.lookup) {
  if (!raw) return {
    version: 1, mode: 'deny', targets: new Map(), pins: new Map(),
  };
  let value;
  try { value = JSON.parse(raw); }
  catch (_error) { throw new Error('navigation policy is not valid JSON'); }
  const keys = Object.keys(value || {}).sort();
  if (JSON.stringify(keys) !== JSON.stringify(['mode', 'targets', 'version'])) {
    throw new Error('navigation policy contains unknown or missing keys');
  }
  if (value.version !== 1 || !['local', 'remote'].includes(value.mode)
      || !Array.isArray(value.targets) || value.targets.length < 1 || value.targets.length > 8) {
    throw new Error('navigation policy contract is invalid');
  }
  const targets = new Map();
  const pins = new Map();
  for (const rawTarget of value.targets) {
    const targetKeys = Object.keys(rawTarget || {}).sort();
    if (JSON.stringify(targetKeys) !== JSON.stringify(['evidenceMode', 'origin', 'routes'])
        || rawTarget.evidenceMode !== 'declared-safe'
        || !Array.isArray(rawTarget.routes) || rawTarget.routes.length < 1
        || rawTarget.routes.length > 64) {
      throw new Error('navigation target contract is invalid; v1 supports declared-safe evidence only');
    }
    const routes = new Set();
    for (const route of rawTarget.routes) {
      const normalizedRoute = normalizeRoute(route);
      if (normalizedRoute === null) {
        throw new Error('evidence route must be an absolute query-free pathname');
      }
      if (routes.has(normalizedRoute)) {
        throw new Error('evidence routes must be normalized and unique');
      }
      routes.add(normalizedRoute);
    }
    const rawOrigin = rawTarget.origin;
    if (typeof rawOrigin !== 'string') throw new Error('navigation origin must be a string');
    let parsed;
    try { parsed = new URL(rawOrigin); }
    catch (_error) { throw new Error('navigation origin is invalid'); }
    if (parsed.username || parsed.password || parsed.search || parsed.hash || parsed.pathname !== '/') {
      throw new Error('navigation origin must not contain credentials, path, query, or fragment');
    }
    if (targets.has(parsed.origin)) throw new Error('navigation origins must be unique');
    const hostname = normalizeHostname(parsed.hostname);
    if (value.mode === 'local') {
      if (!['http:', 'https:'].includes(parsed.protocol) || !net.isIP(hostname)
          || !isLoopbackHost(hostname)) {
        throw new Error(FLOOR_REASONS.LOCAL_LITERAL_LOOPBACK);
      }
    } else {
      if (parsed.protocol !== 'https:' || isLoopbackHost(hostname)) {
        throw new Error(FLOOR_REASONS.REMOTE_HTTPS);
      }
      pins.set(hostname, await resolveRemoteHost(hostname, resolver));
    }
    targets.set(parsed.origin, { origin: parsed.origin, routes, evidenceMode: rawTarget.evidenceMode });
  }
  return { version: 1, mode: value.mode, targets, pins };
}

const CONSENT_HOOK_FILE = 'pre-browser-navigation-consent.sh';
const CONSENT_RECORDER_FILE = 'post-browser-navigation-consent.sh';

// ONE lookup for both halves of the pair, because the two questions have different consumers
// and must not drift: the broker asks only about the GATE, since a missing recorder costs a
// prompt per navigation and never widens what is allowed, while /zensu:doctor asks about both
// — a green "consent mode ready" row over a missing recorder describes a session that prompts
// forever and remembers nothing.
function hookRegistered(pluginRoot, event, hookFile) {
  try {
    const hookPath = path.join(pluginRoot, 'hooks', hookFile);
    const hookInfo = fs.lstatSync(hookPath);
    if (!hookInfo.isFile() || hookInfo.isSymbolicLink()) return false;
    const modulePath = path.join(pluginRoot, 'hooks', 'lib', 'verify-consent-v1.js');
    const moduleInfo = fs.lstatSync(modulePath);
    if (!moduleInfo.isFile() || moduleInfo.isSymbolicLink()) return false;
    const { CONSENT_MATCHER } = require(modulePath);
    const registry = JSON.parse(fs.readFileSync(path.join(pluginRoot, 'hooks', 'hooks.json'), 'utf8'));
    const groups = (registry.hooks && registry.hooks[event]) || [];
    return groups.some((group) => group && group.matcher === CONSENT_MATCHER
      && Array.isArray(group.hooks)
      && group.hooks.some((hook) => typeof hook.command === 'string' && hook.command.includes(`/hooks/${hookFile}`)));
  } catch (_error) {
    return false;
  }
}

function consentHookRegistered(pluginRoot) {
  return hookRegistered(pluginRoot, 'PreToolUse', CONSENT_HOOK_FILE);
}

function consentRecorderRegistered(pluginRoot) {
  return hookRegistered(pluginRoot, 'PostToolUse', CONSENT_RECORDER_FILE);
}

function consentPolicy(pluginRoot, evidenceDir, projectRoot) {
  return {
    version: 1,
    mode: 'consent',
    targets: new Map(),
    pins: new Map(),
    approved: new Map(),
    pluginRoot,
    evidenceDir,
    // Carried so the granting read can apply the same directory-component walk the writer
    // applies. A previous revision passed it at the call site while this function took two
    // parameters, so it was silently dropped and the guard was inert on the one read that
    // authorizes an approval.
    projectRoot,
  };
}

async function resolveStartupPolicy(raw, options = {}) {
  if (raw) return parsePolicy(raw, options.resolver);
  const pluginRoot = options.pluginRoot || path.join(__dirname, '..');
  if (consentHookRegistered(pluginRoot)) {
    // The broker has no Session Control record of its own, so it cannot resolve the RECORD's
    // project root the way the hook does. `scripts/playwright-mcp.sh` carries
    // ZENSU_VERIFY_PROJECT_ROOT through its `env -i` allowlist, so the value reaches this
    // process whenever something upstream sets it. Known bound, stated rather than papered
    // over: nothing in this plugin sets it for the MCP server, so in practice the anchor is
    // this process's cwd — and for a session whose cwd is a worktree while the record names
    // another tree the two anchors disagree. That refuses only when the cwd-anchored tree holds
    // no live marker for the origin: a loopback origin is the same string in every project and
    // this read carries no session key, so a marker written there by another session satisfies
    // it instead. `/zensu:doctor` reads under the RECORD's root, so its execution row can
    // report a gate that ran while this broker refuses.
    // CANONICALIZED before the directory is derived: the reader compares its own realpath of
    // this root against the directory it is handed, so a non-canonical spelling would make the
    // newly armed guard refuse every loopback origin. A root that cannot be canonicalized keeps
    // its literal spelling, and the refusal that follows is fail-closed — but name the arm
    // correctly, because an earlier wording named one that cannot fire: `liveEvidenceOrigins`
    // returns at its OWN realpath catch, before the equality test, so the state is `unread` and
    // not an equality mismatch. The refusal therefore names the anchor rather than only the
    // state directory, since the fault is in the root and not in `.zensu/state`.
    const rawRoot = options.projectRoot || process.env.ZENSU_VERIFY_PROJECT_ROOT || process.cwd();
    let projectRoot = rawRoot;
    try { projectRoot = fs.realpathSync.native(rawRoot); }
    catch (_error) { projectRoot = rawRoot; }
    let evidenceDir;
    try {
      evidenceDir = consentModule({ pluginRoot }).evidenceDirFor(projectRoot);
    } catch (_error) {
      // The module owns the `.zensu/state` layout. If it cannot be loaded the broker has no
      // way to find a marker, so it takes a directory it will never match rather than
      // re-spelling the layout here and drifting from the writer.
      evidenceDir = '';
    }
    return consentPolicy(pluginRoot, evidenceDir, projectRoot);
  }
  return parsePolicy('', options.resolver);
}

// Registration is a claim a file in this tree makes; EXECUTION is what the gate leaves behind.
// The module is RE-VERIFIED on every call rather than once at startup: this process outlives any
// number of navigations and can outlive the plugin tree it resolved its mode from, so a mode
// cached once would keep self-approving after the gate stopped running. Say re-VERIFIED, not
// re-read — `require` returns the cached module for an unchanged path, so what actually re-runs
// per call is the `lstat` and its plain-file test. Two consequences follow and both are wanted
// stated: the lstat is the only per-call verification there is, so deleting it as redundant
// removes the whole property; and a security fix shipped INTO the same path mid-session does not
// reach a broker already running, while a swapped plugin ROOT does change the path and is picked
// up. Every fault answers "unjudged" or "absent", which refuses — the evidence half of a
// fail-closed check must never read a fault as a pass.
function consentModule(policy) {
  const modulePath = path.join(policy && policy.pluginRoot ? policy.pluginRoot : path.join(__dirname, '..'), 'hooks', 'lib', 'verify-consent-v1.js');
  const info = fs.lstatSync(modulePath);
  if (!info.isFile() || info.isSymbolicLink()) throw new Error('consent module is not a plain file');
  return require(modulePath);
}

// Answers WHY, not just whether, so the refusal can name the cause. `expired` exists because the
// marker's window covers the human's deliberation on the ask path: a slow answer is a real,
// blameless way to arrive here, and reporting it as "the gate never ran" sends the reader after
// a fault that did not happen.
function consentEvidenceState(policy, origin) {
  // `unjudged` is separate from `absent` for the reason the doctor's own row family is: a module
  // that will not load, or one missing the reader, is a fault in the plugin tree, and reporting
  // it as "the gate never ran" sends the reader after a gate that is working.
  if (!policy) return 'unjudged';
  // The ROOT travels with the read, so the reader applies the same directory-component walk the
  // writer applies. Without it the one read that GRANTS access was the only one exempt from it —
  // and an ANCHORLESS policy REFUSES rather than reading unguarded, because `liveEvidenceOrigins`
  // runs that walk only when a root is supplied, so dropping the anchor silently disabled the
  // guard in the fail-open direction on the one read that writes into the approved set.
  if (typeof policy.projectRoot !== 'string' || policy.projectRoot === '') return 'unjudged';
  const options = { projectRoot: policy.projectRoot };
  try {
    const mod = consentModule(policy);
    if (typeof mod.executionEvidencePresent !== 'function') return 'unjudged';
    // DERIVED HERE, not taken from the policy's startup value. `consentModule` is re-read on
    // every call on purpose — this process outlives any number of navigations and can outlive the
    // plugin tree it resolved its mode from — but the directory derived from that module was
    // resolved ONCE at startup, so a module fault in that one window disabled consent approval
    // for the life of the MCP server and emitted "reinstall the plugin" for a plugin that had
    // recovered. The startup value stays as the fallback for a module that cannot join the
    // layout itself; an empty result still refuses.
    let evidenceDir = typeof policy.evidenceDir === 'string' ? policy.evidenceDir : '';
    if (typeof mod.evidenceDirFor === 'function') {
      try { evidenceDir = mod.evidenceDirFor(policy.projectRoot); }
      catch (_error) { /* keep the startup value */ }
    }
    if (typeof evidenceDir !== 'string' || evidenceDir === '') return 'unjudged';
    policy = Object.assign({}, policy, { evidenceDir });
    // `executionEvidenceSeen` carries the two facts a boolean cannot: whether the directory was
    // READ at all, and whether the walk FINISHED. Collapsing those into `absent` made the refusal
    // name a gate that had run — a state directory that could not be opened and a walk that hit
    // MAX_EVIDENCE_FILES both rendered as "no in-session evidence". The older reader is still
    // honoured, so a module that predates the split degrades to the boolean rather than refusing.
    if (typeof mod.executionEvidenceSeen === 'function') {
      const seen = mod.executionEvidenceSeen(policy.evidenceDir, Object.assign({}, options, { wantOrigin: origin }));
      if (seen && seen.present === true && seen.origin === origin) return 'present';
      if (seen && seen.read === false) return 'unread';
      if (seen && seen.truncated === true) return 'truncated';
    } else if (mod.executionEvidencePresent(policy.evidenceDir, origin, options) === true) {
      return 'present';
    }
    // The expired probe supplies its OWN window and never reads MAX_EVIDENCE_AGE_MS, so gating
    // this arm on that export degraded a real expiry to `absent` and emitted the wrong cause for
    // a module missing nothing the call needs.
    if (mod.executionEvidencePresent(policy.evidenceDir, origin, Object.assign({}, options, { maxAgeMs: Number.MAX_SAFE_INTEGER })) === true) {
      return 'expired';
    }
    return 'absent';
  } catch (_error) {
    return 'unjudged';
  }
}

// ONE owner for the evidence-state vocabulary, and one renderer for the refusal each state
// produces. The approval ladder used to re-spell the set as four `if` arms plus a catch-all that
// ASSERTED a cause — "no in-session evidence that the Zensu consent gate ran for this origin" —
// so a seventh state would have fallen into that arm and named a fact the probe never
// established. That is the same conflation the unread/truncated split removed one layer down,
// and the sibling doctor renderer already carries an explicit unrecognized-state row. `present`
// is not a refusal and renders the empty string.
// The one member that decides pass versus refuse, named so the approval path compares against an
// owner rather than a bare literal. It stays a SEPARATE constant from the renderer's own `present`
// arm on purpose: the approval test must remain an INEQUALITY against this member, because routing
// the decision through the renderer's empty-string return would make any future state whose text
// is empty approve silently — a fail-closed test turned fail-open.
const CONSENT_EVIDENCE_PRESENT = 'present';
const CONSENT_EVIDENCE_STATES = Object.freeze([
  CONSENT_EVIDENCE_PRESENT, 'expired', 'truncated', 'unread', 'unjudged', 'absent',
]);

// `anchor` is the project root the broker actually read under, and it is only ever interpolated
// into a refusal that would otherwise send the reader to a directory in a tree they are not
// working in. It is optional: a caller with no anchor gets the same sentence without the path
// rather than a placeholder that names nothing.
function consentRefusalFor(state, anchor) {
  const under = typeof anchor === 'string' && anchor !== '' ? ` (${anchor.slice(0, 200)})` : '';
  switch (state) {
    case CONSENT_EVIDENCE_PRESENT:
      return '';
    // BOTH causes, and a diagnostic. A slow human answer is the blameless one and a retry fixes
    // it; a gate that has STOPPED running — hooks disabled host-side, a broker launched from a
    // different tree, a plugin swap — leaves a permanently expired marker that nothing writes and
    // therefore nothing reaps, so the retry the first wording prescribed re-entered this arm
    // forever while blaming the clock.
    case 'expired':
      return 'the Zensu consent gate recorded a decision for this origin, but its execution marker is older than the accepted window; either the answer took longer than the window, in which case retrying records a fresh marker, or the gate has stopped running in this session — run /zensu:doctor and read its "verify-feature gate:" row before retrying';
    // SCOPED to the marker glob, and that is a safety bound rather than precision. This sentence
    // is read by the MODEL, which holds Bash and reaches `.zensu/state/` ungated, and that
    // directory also holds the CAS workflow documents `skills/doctor/SKILL.md` forbids deleting —
    // removing one makes every tool deny until the session is adopted again. Both sibling
    // carriers, the doctor's could-not-judge row and its skill bullet, already scope it this way.
    case 'truncated':
      return `this project holds too many execution markers for the consent gate's read to finish, so no decision for this origin could be established; remove stale verify-consent-exec-* files from .zensu/state${under} — and nothing else in that directory, which also holds this session's workflow document — then run /zensu:doctor`;
    // NAMES THE ANCHOR, because the likeliest cause is not an unreadable directory. The broker's
    // anchor is its own cwd unless something upstream sets ZENSU_VERIFY_PROJECT_ROOT, and an
    // ordinary project with no `.zensu/state` yet produces the same ENOENT — so "check
    // .zensu/state" alone sent the reader to a directory in a tree they are not working in.
    case 'unread':
      return `the consent gate's state directory could not be read under the tree this broker is anchored to${under}, so no execution evidence could be judged; it may not exist there at all. /zensu:doctor reads under the session record's own project root, which is not always the same tree — its "verify-feature gate:" row reports what the gate left there`;
    case 'unjudged':
      return 'the Zensu consent gate\'s decision module could not be read from this plugin root, so no execution evidence could be judged; reinstall the plugin or run /zensu:doctor';
    case 'absent':
      return 'no in-session evidence that the Zensu consent gate ran for this origin; consent mode will not self-approve it';
    default:
      // STATE-NEUTRAL on purpose: it names what it could not interpret and claims nothing about
      // whether the gate ran. Asserting a cause here is the defect this renderer exists to remove.
      return `the Zensu consent gate reported an evidence state this broker has no refusal for (${String(state).slice(0, 64)}); consent mode will not self-approve this origin — run /zensu:doctor`;
  }
}

function approveConsentOrigin(policy, rawUrl) {
  if (policy.mode !== 'consent') throw new Error('consent approval requires consent mode');
  const classified = classifyOrigin(rawUrl, true);
  if (!classified.ok) throw new Error(classified.reason);
  if (classified.mode !== 'local') throw new Error(CONSENT_REMOTE_REASON);
  if (!policy.approved.has(classified.origin)) {
    const state = consentEvidenceState(policy, classified.origin);
    // INEQUALITY against the owner, never a truthiness test on the rendered refusal: only the
    // exact member approves, so a state whose text is empty refuses rather than passing.
    if (state !== CONSENT_EVIDENCE_PRESENT) throw new Error(consentRefusalFor(state, policy.projectRoot));
    policy.approved.set(classified.origin, { origin: classified.origin, approvedAt: new Date().toISOString() });
  }
  return classified;
}

function assertAllowedUrl(policy, rawUrl, navigation = true) {
  if (policy.mode === 'deny') throw new Error('navigation policy is not configured');
  const target = checkNavigationTarget(rawUrl, navigation);
  if (!target.ok) throw new Error(target.reason);
  if (policy.mode === 'consent') {
    if (!policy.approved.has(target.origin)) throw new Error('navigation target origin is not approved');
    return target.parsed;
  }
  const known = policy.targets.get(target.origin);
  if (!known) throw new Error('navigation target origin is not approved');
  if (navigation && !known.routes.has(target.parsed.pathname)) {
    throw new Error('navigation target route is not approved for evidence');
  }
  return target.parsed;
}

function chromiumResolverRules(policy) {
  const rules = [];
  for (const [hostname, addresses] of policy.pins) {
    const address = addresses.find((candidate) => net.isIP(candidate) === 4) || addresses[0];
    const target = net.isIP(address) === 6 ? `[${address}]` : address;
    rules.push(`MAP ${hostname} ${target}`);
  }
  return rules.length > 0 ? `--host-resolver-rules=${rules.join(',')}` : null;
}

function deniedToolResult(reason) {
  return {
    content: [{ type: 'text', text: `Zensu browser broker rejected the operation: ${reason}` }],
    isError: true,
  };
}

function assertActiveUrls(policy, urls, allowInitialBlank = false) {
  for (const url of urls) {
    if (url === 'about:blank') {
      if (allowInitialBlank && urls.length === 1) continue;
      throw new Error('about:blank is allowed only as the single initial page before navigation');
    }
    assertAllowedUrl(policy, url, true);
  }
}

function installCapabilityBoundary(server, policy, closeOwned = async () => {}, currentUrls = () => []) {
  const listHandler = server._requestHandlers.get('tools/list');
  const callHandler = server._requestHandlers.get('tools/call');
  if (typeof listHandler !== 'function' || typeof callHandler !== 'function') {
    throw new Error('locked Playwright MCP request handlers are unavailable');
  }
  server._requestHandlers.set('tools/list', async (...args) => {
    const response = await listHandler(...args);
    return { ...response, tools: response.tools.filter((tool) => ALLOWED_TOOL_SET.has(tool.name)) };
  });
  server._requestHandlers.set('tools/call', async (request, ...args) => {
    const name = request?.params?.name;
    if (!ALLOWED_TOOL_SET.has(name)) {
      return deniedToolResult('tool capability is not allowlisted');
    }
    try {
      if (name !== 'browser_close') {
        assertActiveUrls(policy, await currentUrls(), name === 'browser_navigate');
      }
      const opensUrl = name === 'browser_navigate'
        || (name === 'browser_tabs' && request.params.arguments?.action === 'new' && request.params.arguments?.url);
      // A new tab that names no url opened at about:blank with nothing judged — neither the
      // consent approval nor the floor — and the tab survived the post-call refusal. From then
      // on two pages were open, so assertActiveUrls' allowInitialBlank escape (exactly one page)
      // could not fire for any tool but browser_close: the session was wedged with no recovery.
      // Refusing here, inside the try, returns deniedToolResult and opens nothing.
      if (name === 'browser_tabs' && request.params.arguments?.action === 'new' && !opensUrl) {
        throw new Error('a new tab must name the url it opens');
      }
      if (opensUrl) {
        const url = request.params.arguments?.url;
        // The refusal sits INSIDE the block on purpose. Moving this test into opensUrl
        // would drop control to callHandler with nothing judged, turning today's deny
        // for a non-loopback coercion into a silent pass. Since checkNavigationTarget
        // refuses a non-string itself, this line changes no verdict today except the deny
        // REASON in deny mode; it is the belt against a floor regression at the one site
        // whose consequence is a write to policy.approved. No test can bite it.
        if (typeof url !== 'string') throw new Error(FLOOR_REASONS.INVALID);
        if (policy.mode === 'consent') approveConsentOrigin(policy, url);
        assertAllowedUrl(policy, url, true);
      }
      if (name === 'browser_take_screenshot'
          && Object.prototype.hasOwnProperty.call(request.params.arguments || {}, 'filename')) {
        throw new Error('screenshot filenames are broker-owned; omit filename and inspect the returned image');
      }
    } catch (error) {
      return deniedToolResult(error.message);
    }
    if (name === 'browser_close') {
      try { return await callHandler(request, ...args); }
      finally { await closeOwned(); }
    }
    const result = await callHandler(request, ...args);
    try {
      assertActiveUrls(policy, await currentUrls());
    } catch (error) {
      return deniedToolResult(error.message);
    }
    return result;
  });
}

async function configureContext(context, policy) {
  await context.route('**/*', async (route) => {
    const request = route.request();
    try {
      assertAllowedUrl(policy, request.url(), request.isNavigationRequest());
      await route.continue();
    } catch (_error) {
      await route.abort('blockedbyclient');
    }
  });
  await context.routeWebSocket('**/*', async (webSocket) => {
    try {
      assertAllowedUrl(policy, webSocket.url(), false);
      webSocket.connectToServer();
    } catch (_error) {
      await webSocket.close({ code: 1008, reason: 'origin rejected by Zensu browser broker' });
    }
  });
}

async function openOwnedContext(chromium, policy) {
  const resolverRule = chromiumResolverRules(policy);
  const args = ['--no-proxy-server'];
  if (resolverRule) args.push(resolverRule);
  const browser = await chromium.launch({ headless: false, args });
  try {
    const context = await browser.newContext({ serviceWorkers: 'block' });
    await configureContext(context, policy);
    return { browser, context };
  } catch (error) {
    await browser.close().catch(() => {});
    throw error;
  }
}

class JsonLineTransport {
  constructor(input = process.stdin, output = process.stdout) {
    this.input = input;
    this.output = output;
    this.buffer = '';
    this.closed = false;
  }

  async start() {
    this.input.setEncoding('utf8');
    this.input.on('data', (chunk) => {
      if (this.closed) return;
      this.buffer += chunk;
      if (Buffer.byteLength(this.buffer) > MAX_MESSAGE_BYTES) {
        this.buffer = '';
        this.onerror?.(new Error('MCP message limit exceeded'));
        this.close();
        this.input.destroy?.();
        return;
      }
      let newline;
      while ((newline = this.buffer.indexOf('\n')) !== -1) {
        const line = this.buffer.slice(0, newline).replace(/\r$/, '');
        this.buffer = this.buffer.slice(newline + 1);
        if (!line) continue;
        try { this.onmessage?.(JSON.parse(line)); }
        catch (error) { this.onerror?.(error); }
      }
    });
    this.input.on('error', (error) => this.onerror?.(error));
    this.input.on('end', () => this.close());
  }

  async send(message) {
    if (!this.closed) this.output.write(`${JSON.stringify(message)}\n`);
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    this.onclose?.();
  }
}

async function run(runtimeDir, dependencies = {}) {
  const policy = await resolveStartupPolicy(process.env[POLICY_ENV], { pluginRoot: dependencies.pluginRoot });
  const chromium = dependencies.chromium
    || require(path.join(runtimeDir, 'node_modules/playwright')).chromium;
  const createConnection = dependencies.createConnection
    || require(path.join(runtimeDir, 'node_modules/@playwright/mcp')).createConnection;
  let browser;
  let context;
  const outputDir = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-playwright-output-'));
  process.once('exit', () => fs.rmSync(outputDir, { recursive: true, force: true }));
  const closeOwned = async () => {
    const ownedContext = context;
    const ownedBrowser = browser;
    context = undefined;
    browser = undefined;
    await ownedContext?.close().catch(() => {});
    await ownedBrowser?.close().catch(() => {});
  };
  let server;
  try {
    server = await createConnection({ browser: { isolated: false }, outputDir }, async () => {
      await closeOwned();
      ({ browser, context } = await openOwnedContext(chromium, policy));
      return context;
    });
  } catch (error) {
    fs.rmSync(outputDir, { recursive: true, force: true });
    throw error;
  }
  installCapabilityBoundary(server, policy, closeOwned, () => context?.pages().map((page) => page.url()) || []);
  const previousClose = server.onclose;
  server.onclose = async () => {
    previousClose?.();
    await closeOwned();
    fs.rmSync(outputDir, { recursive: true, force: true });
  };
  try {
    await server.connect(new JsonLineTransport(dependencies.input, dependencies.output));
  } catch (error) {
    await closeOwned();
    fs.rmSync(outputDir, { recursive: true, force: true });
    throw error;
  }
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes('--print-allowlist')) {
    process.stdout.write(`${ALLOWED_TOOLS.join('\n')}\n`);
    return;
  }
  const checkIndex = args.indexOf('--check-policy');
  if (checkIndex !== -1) {
    const policy = await resolveStartupPolicy(process.env[POLICY_ENV]);
    const [mode, origin, route, evidenceMode] = args.slice(checkIndex + 1, checkIndex + 5);
    if (!mode || !origin || !route || !evidenceMode || args.length !== checkIndex + 5) {
      throw new Error('usage: --check-policy <local|remote> <origin> <route> declared-safe');
    }
    if (policy.mode === 'consent') {
      if (mode !== 'local') throw new Error(CONSENT_REMOTE_REASON);
      if (evidenceMode !== 'declared-safe') throw new Error('navigation target contract is invalid; v1 supports declared-safe evidence only');
      const classified = classifyOrigin(new URL(route, `${origin}/`).href, true);
      if (!classified.ok) throw new Error(classified.reason);
      if (classified.mode !== 'local') throw new Error(CONSENT_REMOTE_REASON);
      if (classified.origin !== origin) {
        throw new Error('navigation origin does not match the route it was checked with');
      }
      process.stdout.write('consent\n');
      return;
    }
    if (policy.mode !== mode) throw new Error('navigation policy mode does not match');
    const target = policy.targets.get(new URL(origin).origin);
    if (!target || target.origin !== origin || target.evidenceMode !== evidenceMode) {
      throw new Error('navigation policy target does not match');
    }
    assertAllowedUrl(policy, new URL(route, `${origin}/`).href, true);
    return;
  }
  const runtimeIndex = args.indexOf('--runtime-dir');
  if (runtimeIndex === -1 || !args[runtimeIndex + 1]) throw new Error('missing locked runtime directory');
  await run(path.resolve(args[runtimeIndex + 1]));
}

module.exports = {
  ALLOWED_TOOLS,
  CONSENT_REMOTE_REASON,
  approveConsentOrigin,
  assertActiveUrls,
  assertAllowedUrl,
  chromiumResolverRules,
  configureContext,
  consentEvidenceState,
  CONSENT_EVIDENCE_PRESENT,
  CONSENT_EVIDENCE_STATES,
  consentRefusalFor,
  consentHookRegistered,
  consentRecorderRegistered,
  installCapabilityBoundary,
  isPublicAddress,
  JsonLineTransport,
  openOwnedContext,
  parsePolicy,
  resolveStartupPolicy,
  run,
};

if (require.main === module) {
  main().catch((error) => {
    process.stderr.write(`zensu Playwright broker: ${error.message}\n`);
    process.exitCode = 1;
  });
}
