#!/usr/bin/env node
import http from 'node:http';
import net from 'node:net';
import dgram from 'node:dgram';
import dns from 'node:dns';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const PLUGIN = path.resolve(HERE, '..', '..', '..');
const LIB = path.join(PLUGIN, 'hooks', 'lib');
const HELPER = path.join(PLUGIN, 'scripts', 'verify-browser-config.js');
const floor = require(path.join(LIB, 'verify-navigation-floor-v1.js'));
const consent = require(path.join(LIB, 'verify-consent-v1.js'));
const cliVersion = require(path.join(LIB, 'playwright-cli-version-v1.js'));

const USAGE = `usage: node tests/integration/verify-fence/probe.mjs <mode> [options]

modes:
  matrix [variant ...]   loopback servers and sinks; variants: fence, fence-alone (judged),
                         routes-only, legacy (reference columns). Default: fence fence-alone
  remote                 https://example.com approved and https://example.org not approved
  gated                  the run-config helper and the consent gate of this checkout on a
                         zensu-verify session, with the worker-update fixture
  pairing --released-root=<dir>
                         the run config of this checkout under the gate of another
                         installation, and the reverse

options:
  --browser=<channel>    browser channel handed to open (default: the CLI's own default);
                         headless-shell names the bundled shell binary, which the CLI
                         launches when a config names chromium without a channel
  --headed               open a visible browser window
  --out=<dir>            output directory (default: a fresh directory under the OS temp dir)
  --extra=<switch>       one more Chromium switch for a matrix or remote run, repeatable
  --budget=<ms>          time budget of one page check (default 6000); raise it on a slow host
                         to tell a slow request from a refused one
`;

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const NAMES = Object.freeze({ app: 'fence-app.test', leak: 'fence-leak.test', suffix: 'xfence-app.test', hint: 'fence-hint.test' });
const UNMAPPED_NAME = 'fence-unmapped.test';
const DEFAULT_BUDGET_MS = 6000;
const REMOTE = Object.freeze({ approved: 'example.com', unapproved: 'example.org', title: 'Example Domain' });
const FENCE_PROXY = 'http://zensu-fence.invalid:9';
const VARIANTS = Object.freeze({
  legacy: Object.freeze({ fence: false, serviceWorkers: 'block', routes: true, judged: false }),
  'routes-only': Object.freeze({ fence: false, serviceWorkers: 'allow', routes: true, judged: false }),
  fence: Object.freeze({ fence: true, serviceWorkers: 'allow', routes: true, judged: true }),
  'fence-alone': Object.freeze({ fence: true, serviceWorkers: 'allow', routes: false, judged: true }),
});
const CALL_TIMEOUT_MS = 90000;
const REPORT_TIMEOUT_MS = 60000;
const MEMORY_LEAF = `${consent.MEMORY_NAME_PREFIX}scv1_${'f'.repeat(64)}.json`;

function fenceArgs(origins, pins) {
  const bypass = ['<-loopback>'];
  const maps = [];
  const excludes = [];
  const hosts = new Set();
  for (const origin of origins) {
    const parsed = new URL(origin);
    const host = floor.normalizeHostname(parsed.hostname);
    const port = parsed.port || (['https:', 'wss:'].includes(parsed.protocol) ? '443' : '80');
    const entry = `${net.isIP(host) === 6 ? `[${host}]` : host}:${port}`;
    if (!bypass.includes(entry)) bypass.push(entry);
    if (hosts.has(host)) continue;
    hosts.add(host);
    if (net.isIP(host) || floor.isLocalHost(host)) {
      excludes.push(`EXCLUDE ${host}`);
    } else if (pins.has(host)) {
      const address = pins.get(host);
      maps.push(`MAP ${host} ${net.isIP(address) === 6 ? `[${address}]` : address}`);
    }
  }
  return [
    `--proxy-server=${FENCE_PROXY}`,
    `--proxy-bypass-list=${bypass.join(';')}`,
    `--host-resolver-rules=${[...maps, 'MAP * ^NOTFOUND', ...excludes].join(',')}`,
  ];
}

function legacyArgs(pins) {
  const rules = [...pins].map(([host, address]) => `MAP ${host} ${net.isIP(address) === 6 ? `[${address}]` : address}`);
  return rules.length > 0 ? ['--no-proxy-server', `--host-resolver-rules=${rules.join(',')}`] : ['--no-proxy-server'];
}

function parseOptions(argv) {
  const options = { mode: argv[0] || '', variants: [], browser: '', headed: false, out: '', extra: [], released: '', budget: DEFAULT_BUDGET_MS };
  for (const arg of argv.slice(1)) {
    if (arg === '--headed') options.headed = true;
    else if (arg.startsWith('--browser=')) options.browser = arg.slice('--browser='.length);
    else if (arg.startsWith('--out=')) options.out = arg.slice('--out='.length);
    else if (arg.startsWith('--extra=')) options.extra.push(arg.slice('--extra='.length));
    else if (arg.startsWith('--released-root=')) options.released = arg.slice('--released-root='.length);
    else if (/^--budget=[1-9][0-9]{2,5}$/.test(arg)) options.budget = Number(arg.slice('--budget='.length));
    else if (!arg.startsWith('--') && options.mode === 'matrix') options.variants.push(arg);
    else throw new Error(USAGE);
  }
  if (!['matrix', 'remote', 'gated', 'pairing'].includes(options.mode)) throw new Error(USAGE);
  if (options.variants.length === 0) options.variants = ['fence', 'fence-alone'];
  for (const name of options.variants) {
    if (!Object.prototype.hasOwnProperty.call(VARIANTS, name)) throw new Error(`unknown variant ${name}\n\n${USAGE}`);
  }
  if (options.mode === 'pairing' && !options.released) throw new Error(USAGE);
  return options;
}

function cleanEnv(extra = {}) {
  const env = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (/^(PLAYWRIGHT_MCP_|PWTEST_|PLAYWRIGHT_DISABLE_)/.test(key)) continue;
    if (['PLAYWRIGHT_CLI_SESSION', 'ZENSU_VERIFY_NAVIGATION_POLICY_V1', 'CLAUDE_AGENT_TYPE', 'ZENSU_VERIFY_CONSENT_MEMORY', 'ZENSU_VERIFY_PROJECT_ROOT'].includes(key)) continue;
    env[key] = value;
  }
  return { ...env, NO_UPDATE_NOTIFIER: '1', ...extra };
}

function probeEnv(out) {
  return cleanEnv({ PWTEST_CLI_GLOBAL_CONFIG: path.join(out, 'global-config-home') });
}

function run(file, args, options) {
  return new Promise((resolve) => {
    execFile(file, args, { env: options.env, cwd: options.cwd, timeout: options.timeoutMs || CALL_TIMEOUT_MS, maxBuffer: 16 * 1024 * 1024 }, (error, stdout, stderr) => {
      const code = error ? (typeof error.code === 'number' ? error.code : `err:${error.code || error.signal}`) : 0;
      resolve({ code, stdout: String(stdout), stderr: String(stderr) });
    });
  });
}

function brief(result) {
  const lines = `${result.stdout}\n${result.stderr}`.split('\n').map((line) => line.trim()).filter(Boolean);
  const keep = lines.filter((line) => /Page URL|Error|net::|ERR_|not open|Page Title|gate denied/i.test(line)).slice(0, 4);
  return { code: result.code, lines: keep.length > 0 ? keep : lines.slice(0, 3) };
}

function pause(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function listen(server, host) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, host, () => resolve(server.address().port));
  });
}

function wsHello(socket, key, text) {
  const payload = Buffer.from(text);
  const accept = crypto.createHash('sha1').update(key + WS_GUID).digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  socket.write(Buffer.concat([Buffer.from([0x81, payload.length]), payload]));
}

const SHARED_HELPERS = `
const T = self.CFG.budget;
const timeout = (ms, v) => new Promise((r) => setTimeout(() => r(v), ms));
const tryFetch = (url) => Promise.race([
  fetch(url, { mode: 'no-cors', cache: 'no-store' }).then(() => 'reached', (e) => 'blocked ' + e.message),
  timeout(T, 'timeout'),
]);
const tryCors = (url) => Promise.race([
  fetch(url, { cache: 'no-store' }).then((r) => r.text()).then((t) => 'ok ' + t, (e) => 'failed ' + e.message),
  timeout(T, 'timeout'),
]);
const tryWs = (url) => Promise.race([
  new Promise((r) => {
    let ws;
    try { ws = new WebSocket(url); } catch (e) { r('blocked ' + e.message); return; }
    ws.onmessage = (m) => { r('reached ' + m.data); ws.close(); };
    ws.onerror = () => r('blocked error');
    ws.onclose = (e) => r('blocked close ' + e.code);
  }),
  timeout(T, 'timeout'),
]);
`;

const PAGE_HTML = (cfg) => `<!doctype html>
<html><head><meta charset="utf-8"><title>fence probe</title>
<link rel="dns-prefetch" href="//${NAMES.hint}">
<link rel="preconnect" href="http://127.0.0.1:${cfg.ports.CP}">
</head><body><p id="s">running</p>
<script src="/config.js"></script>
<script src="/page.js"></script>
</body></html>`;

const PAGE_JS = `${SHARED_HELPERS}
(async () => {
  const C = self.CFG;
  const U = C.unapproved;
  const W = C.unapprovedWs;
  const started = Date.now();
  const results = {};
  const checks = [];
  const add = (id, fn) => checks.push([id, fn]);
  const frame = (id, src) => add(id, () => Promise.race([new Promise((r) => { const f = document.createElement('iframe'); f.onload = () => r('load-event'); f.src = src; document.body.appendChild(f); }), timeout(T, 'timeout')]));

  add('p-fetch-ip', () => tryFetch(U.ip + '/p-fetch-ip'));
  add('p-fetch-localhost', () => tryFetch(U.localhost + '/p-fetch-localhost'));
  if (U.v6) add('p-fetch-v6', () => tryFetch(U.v6 + '/p-fetch-v6'));
  add('p-fetch-name', () => tryFetch(U.name + '/p-fetch-name'));
  add('p-fetch-suffix', () => tryFetch(U.suffix + '/p-fetch-suffix'));
  add('p-beacon', async () => String(navigator.sendBeacon(U.ip + '/p-beacon', 'x')));
  add('p-img', () => Promise.race([new Promise((r) => { const i = new Image(); i.onload = () => r('loaded'); i.onerror = () => r('error-event'); i.src = U.ip + '/p-img'; }), timeout(T, 'timeout')]));
  add('p-ws-ip', () => tryWs(W.ip + '/p-ws-ip'));
  add('p-fetch-https', () => tryFetch(C.unapprovedTls.https + '/p-fetch-https'));
  add('p-wss', () => tryWs(C.unapprovedTls.wss + '/p-wss'));
  add('p-ws-name', () => tryWs(W.name + '/p-ws-name'));
  add('p-ws-unmapped', () => tryWs(W.unmapped + '/p-ws-unmapped'));
  add('p-redirect-fetch', () => tryFetch('/redirect?to=' + encodeURIComponent(U.ip + '/p-redirect-fetch')));
  frame('p-iframe-nav', U.ip + '/p-iframe-nav');
  frame('p-iframe-redirect', '/redirect?to=' + encodeURIComponent(U.ip + '/p-iframe-redirect'));

  add('ok-fetch-self', () => tryCors('/approved'));
  for (const [id, key] of [['ok-fetch-l4', 'l4'], ['ok-fetch-l6', 'l6'], ['ok-fetch-v6', 'v6'], ['ok-fetch-name', 'name']]) {
    if (C.approved[key]) add(id, () => tryCors(C.approved[key] + '/approved'));
  }
  add('ok-ws-self', () => tryWs(C.approvedWs.self + '/ws'));
  if (C.approvedWs.name) add('ok-ws-name', () => tryWs(C.approvedWs.name + '/ws'));

  add('worker', () => Promise.race([new Promise((r) => { const w = new Worker('/worker.js'); w.onmessage = (e) => r(e.data); w.onerror = (e) => r({ 'w-error': String(e.message) }); w.postMessage('go'); }), timeout(T * 2 + 2000, { 'w-timeout': 'timeout' })]));
  add('shared', () => Promise.race([new Promise((r) => { const s = new SharedWorker('/shared.js'); s.onerror = (e) => r({ 's-error': String(e.message) }); s.port.onmessage = (e) => r(e.data); s.port.start(); s.port.postMessage('go'); }), timeout(T * 2 + 2000, { 's-timeout': 'timeout' })]));

  add('sw', async () => {
    if (!('serviceWorker' in navigator)) return { 'sw-register': 'unsupported' };
    let reg;
    try { reg = await Promise.race([navigator.serviceWorker.register('/sw.js'), timeout(T, 'TIMEOUT')]); } catch (e) { return { 'sw-register': 'failed ' + e.message }; }
    if (reg === 'TIMEOUT') return { 'sw-register': 'register-timeout' };
    if (!reg) return { 'sw-register': 'no-registration (resolved ' + String(reg) + ')' };
    const ready = await Promise.race([navigator.serviceWorker.ready, timeout(T, null)]);
    if (!ready) return { 'sw-register': 'registered-not-ready' };
    if (!navigator.serviceWorker.controller) {
      await Promise.race([new Promise((r) => navigator.serviceWorker.addEventListener('controllerchange', r, { once: true })), timeout(3000)]);
    }
    const out = { 'sw-register': 'registered controller=' + Boolean(navigator.serviceWorker.controller) };
    const reply = await Promise.race([new Promise((r) => { const ch = new MessageChannel(); ch.port1.onmessage = (e) => r(e.data); ready.active.postMessage('go', [ch.port2]); }), timeout(T * 4 + 3000, { 'sw-msg': 'timeout' })]);
    Object.assign(out, reply);
    out['sw-fetch-handler'] = await Promise.race([fetch('/via-sw?x=1').then((r) => r.text(), (e) => 'failed ' + e.message), timeout(T + 2000, 'timeout')]);
    return out;
  });

  const rtc = async (urls) => {
    if (typeof RTCPeerConnection !== 'function') return 'unsupported';
    const pc = new RTCPeerConnection({ iceServers: [{ urls, username: 'u', credential: 'c' }] });
    pc.createDataChannel('x');
    const done = new Promise((r) => { pc.onicegatheringstatechange = () => { if (pc.iceGatheringState === 'complete') r('gathering-complete'); }; });
    await pc.setLocalDescription(await pc.createOffer());
    const state = await Promise.race([done, timeout(T, 'gathering-timeout')]);
    const sdp = pc.localDescription ? pc.localDescription.sdp : '';
    const kinds = (sdp.match(/a=candidate:[^\\r\\n]*/g) || []).map((c) => (c.match(/ typ (\\w+)/) || [])[1]);
    pc.close();
    return state + ' candidates=' + JSON.stringify(kinds);
  };
  add('rtc-stun-udp', () => rtc('stun:127.0.0.1:' + C.ports.U));
  add('rtc-turn-tcp', () => rtc('turn:127.0.0.1:' + C.ports.CT + '?transport=tcp'));

  await Promise.all(checks.map(async ([id, fn]) => {
    try {
      const value = await fn();
      if (value && typeof value === 'object') Object.assign(results, value); else results[id] = value;
    } catch (e) { results[id] = 'threw ' + e.message; }
  }));
  results['user-agent'] = navigator.userAgent;
  results['elapsed-ms'] = Date.now() - started;
  document.getElementById('s').textContent = 'done';
  await fetch('/report', { method: 'POST', body: JSON.stringify(results) });
})();
`;

const WORKER_JS = `importScripts('/config.js');
${SHARED_HELPERS}
self.onmessage = async () => {
  const C = self.CFG;
  const out = {};
  out['w-fetch'] = await tryFetch(C.unapproved.ip + '/w-fetch');
  out['w-ws'] = await tryWs(C.unapprovedWs.ip + '/w-ws');
  self.postMessage(out);
};
`;

const SHARED_JS = `importScripts('/config.js');
${SHARED_HELPERS}
self.onconnect = (event) => {
  const port = event.ports[0];
  port.onmessage = async () => {
    const C = self.CFG;
    const out = {};
    out['s-fetch'] = await tryFetch(C.unapproved.ip + '/s-fetch');
    out['s-ws'] = await tryWs(C.unapprovedWs.ip + '/s-ws');
    out['s-ok-fetch'] = await tryCors(C.approved.self + '/approved');
    port.postMessage(out);
  };
  port.start();
};
`;

const SW_JS = `importScripts('/config.js');
${SHARED_HELPERS}
const C = self.CFG;
const startup = {};
try { importScripts(C.unapproved.ip + '/sw-import'); startup['sw-import'] = 'reached'; } catch (e) { startup['sw-import'] = 'blocked ' + e.message; }
const startupFetch = tryFetch(C.unapproved.ip + '/sw-startup-fetch');
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('message', (e) => {
  e.waitUntil((async () => {
    const out = Object.assign({}, startup);
    out['sw-startup-fetch'] = await startupFetch;
    out['sw-msg-fetch'] = await tryFetch(C.unapproved.ip + '/sw-msg-fetch');
    out['sw-msg-ws'] = await tryWs(C.unapprovedWs.ip + '/sw-msg-ws');
    out['sw-ok-fetch'] = await tryCors(C.approved.self + '/approved');
    out['sw-ok-ws'] = await tryWs(C.approvedWs.self + '/ws');
    if (C.pushKey) {
      out['sw-push'] = await Promise.race([
        self.registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: new Uint8Array(C.pushKey) })
          .then((s) => 'subscribed ' + new URL(s.endpoint).host, (err) => 'failed ' + err.name + ': ' + err.message),
        timeout(T, 'timeout'),
      ]);
    }
    e.ports[0].postMessage(out);
  })());
});
self.addEventListener('fetch', (e) => {
  const u = new URL(e.request.url);
  if (u.pathname === '/via-sw') {
    e.respondWith(fetch(C.unapproved.ip + '/sw-fetch-handler', { mode: 'no-cors' }).then(() => new Response('sw-reached'), (err) => new Response('sw-blocked ' + err.message)));
  }
});
`;

const APP_HTML = `<!doctype html>
<html><head><meta charset="utf-8"><title>fence probe app</title></head>
<body><h1>fence probe app</h1><p id="state">app-worker starting</p><p id="banner" hidden></p>
<script src="/app/app.js"></script>
</body></html>`;

const APP_JS = `(async () => {
  const state = document.getElementById('state');
  const banner = document.getElementById('banner');
  const ask = (worker) => new Promise((resolve) => {
    const channel = new MessageChannel();
    channel.port1.onmessage = (event) => resolve(event.data);
    worker.postMessage('version', [channel.port2]);
    setTimeout(() => resolve('no-reply'), 4000);
  });
  if (!('serviceWorker' in navigator)) { state.textContent = 'app-worker unsupported'; return; }
  let registration;
  try { registration = await navigator.serviceWorker.register('/app/sw.js', { scope: '/app/' }); } catch (error) { state.textContent = 'app-worker failed ' + error.message; return; }
  if (!registration) { state.textContent = 'app-worker none'; return; }
  const mine = (worker) => Boolean(worker) && new URL(worker.scriptURL).pathname === '/app/sw.js';
  const offer = async (worker) => { banner.textContent = 'app-update available v' + await ask(worker); banner.hidden = false; };
  const watch = (worker) => {
    if (!worker) return;
    const check = () => { if (worker.state === 'installed' && mine(navigator.serviceWorker.controller)) offer(worker); };
    worker.addEventListener('statechange', check);
    check();
  };
  registration.addEventListener('updatefound', () => watch(registration.installing));
  watch(registration.waiting);
  watch(registration.installing);
  await navigator.serviceWorker.ready;
  if (!mine(navigator.serviceWorker.controller)) {
    await new Promise((resolve) => { navigator.serviceWorker.addEventListener('controllerchange', resolve, { once: true }); setTimeout(resolve, 4000); });
  }
  const controller = navigator.serviceWorker.controller;
  state.textContent = mine(controller) ? 'app-worker v' + await ask(controller) + ' controls this page' : 'app-worker registered without control';
  registration.update().catch(() => {});
})();
`;

const APP_SW_JS = (version) => `const VERSION = ${version};
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));
self.addEventListener('message', (event) => { if (event.data === 'version' && event.ports[0]) event.ports[0].postMessage(VERSION); });
`;

async function createFixture() {
  const state = { hits: [], approved: [], udp: [], report: null, waiter: null, phase: 'page', cfg: null, workerVersion: 1 };

  const sink = (label) => net.createServer((socket) => {
    const record = { sink: label, first: null, id: null, host: null, phase: state.phase };
    state.hits.push(record);
    socket.on('error', () => {});
    socket.once('data', (buffer) => {
      const text = buffer.toString('latin1');
      const line = text.split('\r\n')[0];
      if (/^[A-Z]+ \S+ HTTP\/1\.[01]$/.test(line)) {
        record.first = line;
        const id = line.match(/^[A-Z]+ \/([A-Za-z0-9_-]+)/);
        record.id = id ? id[1] : null;
        record.host = (text.match(/\r\nhost: ([^\r\n]+)/i) || [])[1] || null;
        const key = (text.match(/\r\nsec-websocket-key: ([^\r\n]+)/i) || [])[1];
        if (key) {
          wsHello(socket, key.trim(), `sink-${label}`);
        } else {
          const body = `self.__sink = ${JSON.stringify(label)};`;
          socket.end(`HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nContent-Type: text/javascript\r\nContent-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\n\r\n${body}`);
        }
      } else {
        record.first = `bytes:${buffer.subarray(0, 12).toString('hex')}`;
        socket.end();
      }
    });
    setTimeout(() => { if (record.first === null) record.first = 'no-data'; }, 1500);
  });

  const approvedServer = (label) => {
    const server = http.createServer((req, res) => {
      const url = new URL(req.url, 'http://x');
      state.approved.push({ listener: label, host: req.headers.host, path: url.pathname });
      const send = (status, type, body) => {
        res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store', 'Access-Control-Allow-Origin': '*' });
        res.end(body);
      };
      if (url.pathname === '/probe.html') return send(200, 'text/html', PAGE_HTML(state.cfg));
      if (url.pathname === '/config.js') return send(200, 'text/javascript', `self.CFG = ${JSON.stringify(state.cfg)};`);
      if (url.pathname === '/page.js') return send(200, 'text/javascript', PAGE_JS);
      if (url.pathname === '/worker.js') return send(200, 'text/javascript', WORKER_JS);
      if (url.pathname === '/shared.js') return send(200, 'text/javascript', SHARED_JS);
      if (url.pathname === '/sw.js') return send(200, 'text/javascript', SW_JS);
      if (url.pathname === '/app/') return send(200, 'text/html', APP_HTML);
      if (url.pathname === '/app/app.js') return send(200, 'text/javascript', APP_JS);
      if (url.pathname === '/app/sw.js') return send(200, 'text/javascript', APP_SW_JS(state.workerVersion));
      if (url.pathname === '/approved') return send(200, 'text/plain', `approved-${label}`);
      if (url.pathname === '/via-sw') return send(200, 'text/plain', 'network-not-sw');
      if (url.pathname === '/redirect') {
        res.writeHead(302, { Location: url.searchParams.get('to'), 'Cache-Control': 'no-store' });
        return res.end();
      }
      if (url.pathname === '/report' && req.method === 'POST') {
        let body = '';
        req.on('data', (chunk) => { body += chunk; });
        req.on('end', () => {
          state.report = JSON.parse(body);
          send(200, 'text/plain', 'ok');
          if (state.waiter) state.waiter();
        });
        return undefined;
      }
      return send(404, 'text/plain', 'nope');
    });
    server.on('upgrade', (req, socket) => {
      state.approved.push({ listener: label, host: req.headers.host, path: req.url, ws: true });
      socket.on('error', () => {});
      wsHello(socket, req.headers['sec-websocket-key'], `approved-${label}`);
    });
    return server;
  };

  const servers = [];
  const ports = {};
  const open = async (key, server, host) => {
    ports[key] = await listen(server, host);
    servers.push(server);
  };
  await open('A', approvedServer('A'), '127.0.0.1');
  await open('L4', approvedServer('L4'), '127.0.0.1');
  await open('H', approvedServer('H'), '127.0.0.1');
  for (const key of ['C4', 'CS', 'CH', 'CT', 'CP']) await open(key, sink(key), '127.0.0.1');
  let v6 = true;
  try {
    await open('L6', approvedServer('L6'), '::1');
    await open('V6', approvedServer('V6'), '::1');
    await open('C6', sink('C6'), '::1');
  } catch (_error) {
    v6 = false;
  }
  const udp = dgram.createSocket('udp4');
  udp.on('message', (message, remote) => state.udp.push({ bytes: message.length, from: remote.port }));
  await new Promise((resolve) => udp.bind(0, '127.0.0.1', resolve));
  ports.U = udp.address().port;

  const reset = () => {
    state.hits.length = 0;
    state.approved.length = 0;
    state.udp.length = 0;
    state.report = null;
    state.waiter = null;
    state.phase = 'page';
    state.workerVersion = 1;
  };
  const close = () => {
    for (const server of servers) {
      server.close();
      if (typeof server.closeAllConnections === 'function') server.closeAllConnections();
    }
    udp.close();
  };
  return { state, ports, v6, reset, close };
}

function pageConfig(fixture, options) {
  const P = fixture.ports;
  const named = options.named;
  return {
    ports: P,
    unapproved: {
      ip: `http://127.0.0.1:${P.C4}`,
      localhost: `http://localhost:${P.C4}`,
      v6: fixture.v6 ? `http://[::1]:${P.C6}` : '',
      name: `http://${NAMES.leak}:${P.CH}`,
      suffix: `http://${NAMES.suffix}:${P.H}`,
    },
    unapprovedWs: { ip: `ws://127.0.0.1:${P.C4}`, name: `ws://${NAMES.leak}:${P.CH}`, unmapped: `ws://${UNMAPPED_NAME}:${P.CH}` },
    unapprovedTls: { https: `https://127.0.0.1:${P.CS}`, wss: `wss://127.0.0.1:${P.CS}` },
    approved: {
      self: `http://127.0.0.1:${P.A}`,
      l4: `http://localhost:${P.L4}`,
      l6: fixture.v6 ? `http://localhost:${P.L6}` : '',
      v6: fixture.v6 ? `http://[::1]:${P.V6}` : '',
      name: named ? `http://${NAMES.app}:${P.H}` : '',
    },
    approvedWs: { self: `ws://127.0.0.1:${P.A}`, name: named ? `ws://${NAMES.app}:${P.H}` : '' },
    pushKey: options.push ? [...crypto.createECDH('prime256v1').generateKeys()] : null,
    budget: options.budget,
  };
}

function approvedOrigins(fixture, named) {
  const P = fixture.ports;
  const origins = [`http://127.0.0.1:${P.A}`, `http://localhost:${P.L4}`];
  if (fixture.v6) origins.push(`http://localhost:${P.L6}`, `http://[::1]:${P.V6}`);
  if (named) origins.push(`http://${NAMES.app}:${P.H}`);
  return origins;
}

function allowedEndpoints(origins, pins) {
  const hosts = new Set();
  const endpoints = new Set();
  for (const origin of origins) {
    const parsed = new URL(origin);
    const host = floor.normalizeHostname(parsed.hostname);
    const port = parsed.port || (['https:', 'wss:'].includes(parsed.protocol) ? '443' : '80');
    hosts.add(host);
    const addresses = floor.isLocalHost(host) && !net.isIP(host) ? ['127.0.0.1', '::1'] : [pins.has(host) ? pins.get(host) : host];
    for (const address of addresses) {
      hosts.add(address);
      endpoints.add(`${net.isIP(address) === 6 ? `[${address}]` : address}:${port}`);
    }
  }
  return { hosts, endpoints };
}

function readNetlog(file) {
  let raw;
  try { raw = fs.readFileSync(file, 'utf8'); } catch (_error) { return null; }
  for (const text of [raw, `${raw.replace(/,\s*$/, '')}]}`]) {
    try { return JSON.parse(text); } catch (_error) { continue; }
  }
  return null;
}

function requestHost(value) {
  try {
    const parsed = new URL(value);
    if (['http:', 'https:', 'ws:', 'wss:'].includes(parsed.protocol)) return floor.normalizeHostname(parsed.hostname);
  } catch (_error) {
    return floor.normalizeHostname(String(value).replace(/:\d+$/, ''));
  }
  return floor.normalizeHostname(String(value).replace(/:\d+$/, ''));
}

function netlogFacts(file, allowed) {
  const data = readNetlog(file);
  if (!data) return { readable: false };
  const names = {};
  for (const [name, id] of Object.entries((data.constants && data.constants.logEventTypes) || {})) names[id] = name;
  const requests = {};
  const attempts = {};
  const lookups = {};
  const resolverTypes = {};
  let udpBytesSent = 0;
  for (const event of data.events || []) {
    const type = names[event.type] || '';
    const params = event.params || {};
    if (/^(HOST_RESOLVER|DNS_TRANSACTION)/.test(type)) resolverTypes[type] = (resolverTypes[type] || 0) + 1;
    if (type === 'HOST_RESOLVER_MANAGER_REQUEST' && typeof params.host === 'string') {
      const host = requestHost(params.host);
      requests[host] = (requests[host] || 0) + 1;
    }
    if (/^(DNS_TRANSACTION|HOST_RESOLVER_DNS_TASK|HOST_RESOLVER_SYSTEM_TASK|HOST_RESOLVER_MANAGER_JOB)$/.test(type)) {
      const host = String(params.hostname || params.host || '(unnamed)');
      lookups[host] = (lookups[host] || 0) + 1;
    }
    if (type === 'TCP_CONNECT_ATTEMPT' && typeof params.address === 'string') attempts[params.address] = (attempts[params.address] || 0) + 1;
    if (type === 'UDP_BYTES_SENT') udpBytesSent += 1;
  }
  const client = (data.constants && data.constants.clientInfo) || {};
  const commandLine = String(client.command_line || '');
  return {
    readable: true,
    binary: path.basename(commandLine.split(' --')[0]),
    headless: /(^| )--headless/.test(commandLine),
    events: (data.events || []).length,
    browser: [client.name, client.version].filter(Boolean).join(' '),
    os: String(client.os_type || ''),
    requests,
    strangerRequests: Object.keys(requests).filter((host) => !allowed.hosts.has(host)),
    lookups,
    attempts,
    strangerAttempts: Object.keys(attempts).filter((address) => !allowed.endpoints.has(address)),
    resolverTypes,
    udpBytesSent,
  };
}

function evalResult(stdout) {
  const match = stdout.match(/### Result\n([\s\S]*?)\n### /);
  if (!match) return null;
  try { return JSON.parse(match[1]); } catch (_error) { return null; }
}

function quote(arg) {
  return /^[A-Za-z0-9_./:=@%+,-]+$/.test(arg) ? arg : `'${arg}'`;
}

function plainDriver(session, env, cwd) {
  return {
    session,
    gated: false,
    call: (args, timeoutMs) => run('playwright-cli', [`-s=${session}`, ...args], { env, cwd, timeoutMs }),
  };
}

function gatedDriver(session, env, root) {
  const memory = path.join(root, '.zensu', 'state', MEMORY_LEAF);
  const hookEnv = { ...env, ZENSU_VERIFY_CONSENT_MEMORY: memory, ZENSU_VERIFY_PROJECT_ROOT: root };
  const payload = (command, event) => ({ hook_event_name: event, tool_name: 'Bash', tool_input: { command }, permission_mode: 'default', cwd: root });
  const silent = { write: () => true };
  const judge = (command) => {
    const written = [];
    const decided = consent.runPre(payload(command, 'PreToolUse'), hookEnv, { write: (chunk) => { written.push(String(chunk)); return true; } }, silent);
    if (!decided) return { decision: 'allow', reason: '' };
    const output = JSON.parse(written.join('')).hookSpecificOutput;
    return { decision: output.permissionDecision, reason: output.permissionDecisionReason };
  };
  return {
    session,
    gated: true,
    judge,
    call: async (args, timeoutMs) => {
      const command = `playwright-cli -s=${session} ${args.map(quote).join(' ')}`;
      const verdict = judge(command);
      if (verdict.decision === 'deny') return { code: 'gate-deny', stdout: '', stderr: `gate denied: ${verdict.reason}`, gate: verdict };
      const result = await run('/bin/bash', ['-c', command], { env, cwd: root, timeoutMs });
      if (result.code === 0) {
        consent.runPost({ ...payload(command, 'PostToolUse'), tool_response: { stdout: result.stdout, stderr: result.stderr, interrupted: false } }, hookEnv, silent);
      }
      return { ...result, gate: verdict };
    },
  };
}

let activeDriver = null;

async function closeActive() {
  if (!activeDriver) return;
  const driver = activeDriver;
  activeDriver = null;
  await driver.call(['close'], 45000);
}

function channelMissing(result) {
  const text = `${result.stdout}\n${result.stderr}`;
  return !text.includes('- Page URL:') && /is not found|executable doesn't exist|not installed|install-browser|distribution .* is not/i.test(text);
}

async function waitForReport(fixture) {
  const state = fixture.state;
  const waited = await Promise.race([
    new Promise((resolve) => { if (state.report) resolve('report'); else state.waiter = () => resolve('report'); }),
    pause(Math.max(REPORT_TIMEOUT_MS, state.cfg.budget * 10)).then(() => 'no-report-timeout'),
  ]);
  state.waiter = null;
  return waited === 'report' ? state.report : { error: waited };
}

async function workerUpdate(driver, fixture, origin) {
  const state = fixture.state;
  const out = { first: '', second: '', updated: false, registered: false };
  const snapshot = async (pattern) => {
    let text = '';
    for (let attempt = 0; attempt < 8; attempt += 1) {
      const result = await driver.call(['snapshot']);
      text = `${result.stdout}\n${result.stderr}`;
      if (pattern.test(text)) return text;
      await pause(1500);
    }
    return text;
  };
  const marker = (text) => (text.match(/app-worker [^"'\n]*|app-update [^"'\n]*/g) || []).join(' | ');
  const opened = await driver.call(['goto', `${origin}/app/`]);
  out.goto = brief(opened);
  if (opened.code !== 0) return out;
  const first = await snapshot(/app-worker (v\d+ controls|none|unsupported|failed|registered without)/);
  out.first = marker(first);
  out.registered = /app-worker v1 controls this page/.test(first);
  if (!out.registered) return out;
  state.workerVersion = 2;
  const reloaded = await driver.call(['reload']);
  out.reload = brief(reloaded);
  if (reloaded.code !== 0) return out;
  const second = await snapshot(/app-update available v\d+/);
  out.second = marker(second);
  out.updated = /app-update available v2/.test(second);
  return out;
}

async function runLoopback(name, variant, driver, fixture, openArgs, options) {
  const P = fixture.ports;
  const state = fixture.state;
  const result = { variant: name, session: driver.session, serviceWorkers: variant.serviceWorkers, routes: variant.routes };
  activeDriver = driver;
  try {
    const opened = await driver.call(['open', ...openArgs, `http://127.0.0.1:${P.A}/probe.html`]);
    result.open = brief(opened);
    if (opened.gate) result.openGate = opened.gate.decision;
    if (opened.code !== 0) {
      result.skip = channelMissing(opened) ? `the browser could not be launched: ${`${opened.stdout} ${opened.stderr}`.trim().slice(0, 240)}` : '';
      return result;
    }
    result.page = await waitForReport(fixture);
    await pause(1800);
    result.pageHits = state.hits.map((hit) => ({ sink: hit.sink, id: hit.id, first: hit.first, host: hit.host }));
    result.udpDatagrams = state.udp.length;
    result.suffixLeakRequests = state.approved.filter((entry) => String(entry.host || '').startsWith(NAMES.suffix)).length;
    state.hits.length = 0;
    state.phase = 'pre-nav';
    await pause(2500);
    result.lateHits = state.hits.map((hit) => ({ sink: hit.sink, id: hit.id, first: hit.first }));
    state.hits.length = 0;
    const navs = [
      ['nav-unapproved-ip', `http://127.0.0.1:${P.C4}/nav-unapproved-ip`, false],
      ['nav-unapproved-name', `http://${NAMES.leak}:${P.CH}/nav-unapproved-name`, false],
      ['nav-redirect', `http://127.0.0.1:${P.A}/redirect?to=${encodeURIComponent(`http://127.0.0.1:${P.C4}/nav-redirect`)}`, false],
      ['nav-ok-l4', `http://localhost:${P.L4}/approved`, true],
    ];
    if (options.named) navs.push(['nav-ok-name', `http://${NAMES.app}:${P.H}/approved`, true]);
    if (fixture.v6) navs.push(['nav-ok-v6', `http://[::1]:${P.V6}/approved`, true], ['nav-ok-l6', `http://localhost:${P.L6}/approved`, true]);
    result.nav = {};
    for (const [id, url, approved] of navs) {
      state.phase = id;
      const went = await driver.call(['goto', url], 45000);
      result.nav[id] = { ...brief(went), approved, url };
      await pause(700);
    }
    state.phase = 'after-nav';
    await pause(1200);
    result.navHits = state.hits.map((hit) => ({ sink: hit.sink, id: hit.id, first: hit.first, phase: hit.phase }));
    state.hits.length = 0;
    state.phase = 'worker-update';
    result.update = await workerUpdate(driver, fixture, `http://localhost:${P.L4}`);
    await pause(800);
    result.updateHits = state.hits.map((hit) => ({ sink: hit.sink, id: hit.id, first: hit.first }));
  } finally {
    const closed = await driver.call(['close'], 45000);
    result.close = { code: closed.code };
    activeDriver = null;
  }
  return result;
}

function judgeLoopback(result, variant, fixture, options) {
  const problems = [];
  const page = result.page || {};
  if (result.open && result.open.code !== 0) problems.push(`open failed: ${JSON.stringify(result.open.lines)}`);
  if (page.error) problems.push(`the probe page never reported: ${page.error}`);
  const expected = ['ok-fetch-self', 'ok-fetch-l4', 'ok-ws-self', 's-ok-fetch'];
  if (fixture.v6) expected.push('ok-fetch-l6', 'ok-fetch-v6');
  if (options.named) expected.push('ok-fetch-name', 'ok-ws-name');
  if (variant.serviceWorkers === 'allow') expected.push('sw-ok-fetch', 'sw-ok-ws');
  const worked = expected.filter((id) => /^(ok |reached )/.test(String(page[id] || '')));
  for (const id of expected) if (!worked.includes(id)) problems.push(`approved check ${id} did not work: ${JSON.stringify(page[id])}`);
  if (variant.serviceWorkers === 'allow' && page['sw-register'] !== 'registered controller=true') {
    problems.push(`the service worker did not register and take control: ${JSON.stringify(page['sw-register'])}`);
  }
  const sinkHits = [...(result.pageHits || []), ...(result.lateHits || []), ...(result.navHits || []), ...(result.updateHits || [])];
  for (const hit of sinkHits) problems.push(`sink ${hit.sink} logged a connection: ${hit.id || hit.first}`);
  if (result.suffixLeakRequests) problems.push(`${result.suffixLeakRequests} request(s) for the suffix hostname reached an approved listener`);
  for (const [id, nav] of Object.entries(result.nav || {})) {
    if (nav.approved && nav.code !== 0) problems.push(`approved navigation ${id} failed: ${JSON.stringify(nav.lines)}`);
    if (!nav.approved && nav.code === 0) problems.push(`navigation ${id} to a target outside the run config succeeded`);
  }
  if (variant.serviceWorkers === 'allow' && result.update) {
    if (!result.update.registered) problems.push(`the fixture worker did not take control: ${JSON.stringify(result.update.first)}`);
    if (!result.update.updated) problems.push(`the worker update was not observed: ${JSON.stringify(result.update.second)}`);
  }
  if (result.netlog) {
    if (!result.netlog.readable) {
      problems.push('the net-log could not be read');
    } else {
      if (Object.keys(result.netlog.requests).length === 0) problems.push('the net-log shows no resolver request at all, so the resolver count is not visible on this platform');
      for (const host of result.netlog.strangerRequests) problems.push(`resolver request for a name outside the run config: ${host}`);
      for (const [host, count] of Object.entries(result.netlog.lookups)) problems.push(`resolver lookup left the browser: ${host} (${count} event(s))`);
      for (const address of result.netlog.strangerAttempts) problems.push(`TCP connect attempt outside the run config: ${address}`);
    }
  }
  return { expected: expected.length, worked: worked.length, sinkHits: sinkHits.length, problems };
}

function printLoopback(result, verdict, variant) {
  console.log(`\n===== ${result.variant} =====`);
  if (result.args) console.log(`args: ${JSON.stringify(result.args)}`);
  console.log(`session=${result.session} serviceWorkers=${result.serviceWorkers} routes=${result.routes} open=${JSON.stringify(result.open)}${result.openGate ? ` gate=${result.openGate}` : ''}`);
  if (!result.page) return;
  const hitIds = new Map();
  for (const hit of result.pageHits || []) {
    const key = hit.id || `${hit.sink}:${hit.first}`;
    hitIds.set(key, (hitIds.get(key) || 0) + 1);
  }
  const ids = Object.keys(result.page).sort();
  for (const id of ids) console.log(`  ${id.padEnd(22)} page=${JSON.stringify(result.page[id])}${hitIds.has(id) ? `  SINK-HIT x${hitIds.get(id)}` : ''}`);
  console.log(`  sink hits without page id: ${JSON.stringify([...hitIds.entries()].filter(([id]) => !ids.includes(id)))}`);
  console.log(`  udp datagrams at the unapproved STUN sink: ${result.udpDatagrams}; suffix-leak requests: ${result.suffixLeakRequests}`);
  for (const [id, nav] of Object.entries(result.nav || {})) console.log(`  ${id.padEnd(22)} ${JSON.stringify({ code: nav.code, lines: nav.lines })}`);
  console.log(`  late hits before navigation: ${JSON.stringify(result.lateHits)}`);
  console.log(`  navigation sink hits: ${JSON.stringify(result.navHits)}`);
  console.log(`  worker update: ${JSON.stringify(result.update)}; sink hits: ${JSON.stringify(result.updateHits)}`);
  if (result.netlog && result.netlog.readable) {
    const log = result.netlog;
    console.log(`  net-log: ${log.events} events, ${log.browser || 'browser unnamed'} on ${log.os || 'os unnamed'}, binary ${log.binary || 'unnamed'}, headless switch ${log.headless}`);
    console.log(`  net-log resolver requests: ${JSON.stringify(log.requests)}; outside the run config: ${JSON.stringify(log.strangerRequests)}`);
    console.log(`  net-log resolver lookups (jobs, DNS transactions, system tasks): ${JSON.stringify(log.lookups)}`);
    console.log(`  net-log resolver event types: ${JSON.stringify(log.resolverTypes)}`);
    console.log(`  net-log TCP connect attempts: ${JSON.stringify(log.attempts)}; outside the run config: ${JSON.stringify(log.strangerAttempts)}`);
    console.log(`  net-log UDP sends: ${log.udpBytesSent}`);
  } else if (result.netlog) {
    console.log('  net-log: unreadable');
  } else {
    console.log('  net-log: not written (a gated run config admits no net-log argument)');
  }
  if (!variant.judged) {
    console.log('  verdict: reference column, not judged');
    return;
  }
  console.log(`  approved checks: ${verdict.worked}/${verdict.expected} worked; sink connections: ${verdict.sinkHits}`);
  console.log(`  verdict: ${verdict.problems.length === 0 ? 'PASS' : 'FAIL'}`);
  for (const problem of verdict.problems) console.log(`    - ${problem}`);
}

function header(options, out) {
  const installed = cliVersion.installedVersion(cleanEnv());
  console.log(`fence-probe: mode=${options.mode} playwright-cli=${installed.version || installed.source} measured-pin=${consent.PLAYWRIGHT_CLI_SOURCE_VERSION} node=${process.version} platform=${process.platform}/${process.arch} browser-flag=${options.browser || '(default)'} headed=${options.headed} budget=${options.budget}ms`);
  console.log(`fence-probe: output in ${out}`);
  return installed;
}

const SHELL_CHANNEL = 'headless-shell';

function openFlags(options) {
  const flags = [];
  if (options.browser && options.browser !== SHELL_CHANNEL) flags.push(`--browser=${options.browser}`);
  if (options.headed) flags.push('--headed');
  return flags;
}

function probeConfig(options, variant, args, origins, netlog, outputDir) {
  const browser = { isolated: true, launchOptions: { args: [...args, `--log-net-log=${netlog}`, ...options.extra] }, contextOptions: { serviceWorkers: variant.serviceWorkers } };
  if (options.browser === SHELL_CHANNEL) browser.browserName = 'chromium';
  const config = { browser, outputDir };
  if (variant.routes) config.network = { allowedOrigins: origins };
  return config;
}

async function modeMatrix(options, out) {
  const fixture = await createFixture();
  const env = probeEnv(out);
  const pins = new Map(Object.values(NAMES).map((name) => [name, '127.0.0.1']));
  const outcomes = [];
  try {
    if (!fixture.v6) console.log('fence-probe: no IPv6 loopback here, so the [::1] listeners and their checks are left out');
    for (const name of options.variants) {
      const variant = VARIANTS[name];
      fixture.reset();
      fixture.state.cfg = pageConfig(fixture, { named: true, push: variant.fence, budget: options.budget });
      const origins = approvedOrigins(fixture, true);
      const netlog = path.join(out, `${name}.netlog.json`);
      const fencePins = new Map([[NAMES.app, '127.0.0.1']]);
      const args = variant.fence ? fenceArgs(origins, fencePins) : legacyArgs(pins);
      const config = probeConfig(options, variant, args, origins, netlog, path.join(out, `${name}-browser`));
      const configPath = path.join(out, `${name}.config.json`);
      fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);
      const driver = plainDriver(`fenceprobe-${name}-${process.pid}`, env, out);
      const result = await runLoopback(name, variant, driver, fixture, [`--config=${configPath}`, ...openFlags(options)], { named: true });
      result.args = [...args, ...options.extra];
      if (result.skip) return { skip: result.skip };
      await pause(800);
      result.netlog = netlogFacts(netlog, allowedEndpoints(origins, variant.fence ? fencePins : pins));
      const verdict = judgeLoopback(result, variant, fixture, { named: true });
      fs.writeFileSync(path.join(out, `${name}.result.json`), `${JSON.stringify({ result, verdict }, null, 2)}\n`);
      printLoopback(result, verdict, variant);
      if (variant.judged) outcomes.push(verdict.problems.length === 0);
    }
  } finally {
    fixture.close();
  }
  return { pass: outcomes.every(Boolean), judged: outcomes.length };
}

async function modeRemote(options, out) {
  const fixture = await createFixture();
  const env = probeEnv(out);
  const outcomes = [];
  try {
    let addresses;
    try { addresses = await floor.resolveRemoteHost(REMOTE.approved, dns.promises.lookup); }
    catch (error) { return { skip: `${REMOTE.approved} could not be resolved to public addresses: ${error.message}` }; }
    const address = addresses.find((candidate) => net.isIP(candidate) === 4) || addresses[0];
    const origins = [`https://${REMOTE.approved}`];
    const pins = new Map([[REMOTE.approved, address]]);
    const P = fixture.ports;
    const checks = `async () => {
      const timeout = (ms, v) => new Promise((r) => setTimeout(() => r(v), ms));
      const tryFetch = (url) => Promise.race([fetch(url, { mode: 'no-cors', cache: 'no-store' }).then(() => 'reached', (e) => 'blocked ' + e.message), timeout(6000, 'timeout')]);
      const tryWs = (url) => Promise.race([new Promise((r) => { let ws; try { ws = new WebSocket(url); } catch (e) { r('blocked ' + e.message); return; } ws.onopen = () => { r('reached open'); ws.close(); }; ws.onerror = () => r('blocked error'); ws.onclose = (e) => r('blocked close ' + e.code); }), timeout(6000, 'timeout')]);
      const out = {};
      out['r-fetch-self'] = await fetch('/', { cache: 'no-store' }).then((r) => 'ok ' + r.status, (e) => 'failed ' + e.message);
      out['r-fetch-https'] = await tryFetch('https://${REMOTE.unapproved}/r-fetch-https');
      out['r-wss'] = await tryWs('wss://${REMOTE.unapproved}/r-wss');
      out['r-fetch-sink'] = await tryFetch('http://127.0.0.1:${P.C4}/r-fetch-sink');
      out['r-ws-sink'] = await tryWs('ws://127.0.0.1:${P.C4}/r-ws-sink');
      return out;
    }`.replace(/\s*\n\s*/g, ' ');
    for (const name of ['fence', 'fence-alone']) {
      const variant = VARIANTS[name];
      fixture.reset();
      const netlog = path.join(out, `remote-${name}.netlog.json`);
      const args = fenceArgs(origins, pins);
      const config = probeConfig(options, variant, args, origins, netlog, path.join(out, `remote-${name}-browser`));
      const configPath = path.join(out, `remote-${name}.config.json`);
      fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);
      const driver = plainDriver(`fenceprobe-remote-${name}-${process.pid}`, env, out);
      const result = { variant: `remote ${name}`, session: driver.session, args, pin: `${REMOTE.approved} -> ${address}` };
      activeDriver = driver;
      try {
        const opened = await driver.call(['open', `--config=${configPath}`, ...openFlags(options), `https://${REMOTE.approved}/`]);
        result.open = brief(opened);
        if (opened.code !== 0 && channelMissing(opened)) return { skip: `the browser could not be launched: ${`${opened.stdout} ${opened.stderr}`.trim().slice(0, 240)}` };
        result.loaded = opened.code === 0 && opened.stdout.includes(`- Page URL: https://${REMOTE.approved}/`) && opened.stdout.includes(`- Page Title: ${REMOTE.title}`);
        if (opened.code === 0) {
          const evaluated = await driver.call(['eval', checks]);
          result.page = evalResult(evaluated.stdout) || { error: brief(evaluated).lines.join(' ') };
          await pause(1500);
          result.pageHits = fixture.state.hits.map((hit) => ({ sink: hit.sink, id: hit.id, first: hit.first }));
          fixture.state.hits.length = 0;
          const went = await driver.call(['goto', `https://${REMOTE.unapproved}/`], 45000);
          result.nav = brief(went);
          await pause(1000);
          result.navHits = fixture.state.hits.map((hit) => ({ sink: hit.sink, id: hit.id, first: hit.first }));
        }
      } finally {
        const closed = await driver.call(['close'], 45000);
        result.close = { code: closed.code };
        activeDriver = null;
      }
      await pause(800);
      result.netlog = netlogFacts(netlog, allowedEndpoints(origins, pins));
      const problems = [];
      const page = result.page || {};
      if (!result.loaded) problems.push(`the approved page did not load: ${JSON.stringify(result.open)}`);
      if (!/^ok 200$/.test(String(page['r-fetch-self']))) problems.push(`the approved same-origin request did not work: ${JSON.stringify(page['r-fetch-self'])}`);
      for (const id of ['r-fetch-https', 'r-wss', 'r-fetch-sink', 'r-ws-sink']) {
        if (!/^blocked /.test(String(page[id]))) problems.push(`unapproved check ${id} was not refused: ${JSON.stringify(page[id])}`);
      }
      for (const hit of [...(result.pageHits || []), ...(result.navHits || [])]) problems.push(`sink ${hit.sink} logged a connection: ${hit.id || hit.first}`);
      if (!result.nav || result.nav.code === 0) problems.push('the navigation to the unapproved host succeeded');
      if (!result.netlog.readable) {
        problems.push('the net-log could not be read');
      } else {
        if (Object.keys(result.netlog.requests).length === 0) problems.push('the net-log shows no resolver request at all');
        for (const host of result.netlog.strangerRequests) problems.push(`resolver request for a name outside the run config: ${host}`);
        for (const [host, count] of Object.entries(result.netlog.lookups)) problems.push(`resolver lookup left the browser: ${host} (${count} event(s))`);
        for (const attempt of result.netlog.strangerAttempts) problems.push(`TCP connect attempt outside the run config: ${attempt}`);
      }
      fs.writeFileSync(path.join(out, `remote-${name}.result.json`), `${JSON.stringify({ result, problems }, null, 2)}\n`);
      console.log(`\n===== remote ${name} =====`);
      console.log(`args: ${JSON.stringify(args)}`);
      console.log(`pin: ${result.pin}; open=${JSON.stringify(result.open)}; loaded with its certificate: ${result.loaded}`);
      for (const id of Object.keys(page).sort()) console.log(`  ${id.padEnd(16)} page=${JSON.stringify(page[id])}`);
      console.log(`  goto https://${REMOTE.unapproved}/ ${JSON.stringify(result.nav)}`);
      console.log(`  sink hits: ${JSON.stringify([...(result.pageHits || []), ...(result.navHits || [])])}`);
      if (result.netlog.readable) {
        console.log(`  net-log: ${result.netlog.events} events, ${result.netlog.browser} on ${result.netlog.os}`);
        console.log(`  net-log resolver requests: ${JSON.stringify(result.netlog.requests)}; lookups: ${JSON.stringify(result.netlog.lookups)}`);
        console.log(`  net-log TCP connect attempts: ${JSON.stringify(result.netlog.attempts)}; outside the run config: ${JSON.stringify(result.netlog.strangerAttempts)}`);
      }
      console.log(`  verdict: ${problems.length === 0 ? 'PASS' : 'FAIL'}`);
      for (const problem of problems) console.log(`    - ${problem}`);
      outcomes.push(problems.length === 0);
    }
  } finally {
    fixture.close();
  }
  return { pass: outcomes.length > 0 && outcomes.every(Boolean), judged: outcomes.length };
}

async function modeGated(options, out) {
  if (process.platform === 'win32' || !fs.existsSync('/bin/bash')) return { skip: 'the gated run needs /bin/bash to run the judged command text' };
  if (options.browser === SHELL_CHANNEL) return { skip: 'a gated run config names no browser, so the shell binary is measured in matrix mode' };
  const fixture = await createFixture();
  const env = probeEnv(out);
  try {
    const root = fs.realpathSync.native(fs.mkdtempSync(path.join(out, 'gated-project-')));
    const runDir = path.join(root, '.zensu', 'verify-feature-runs', `fenceprobe-${process.pid}`);
    fs.mkdirSync(runDir, { recursive: true });
    fs.mkdirSync(path.join(root, '.zensu', 'state'), { mode: 0o700 });
    fixture.state.cfg = pageConfig(fixture, { named: false, push: false, budget: options.budget });
    const origins = approvedOrigins(fixture, false);
    const helperArgs = [HELPER, '--run-dir', runDir, '--mode', 'local'];
    for (const origin of origins) helperArgs.push('--origin', origin);
    const helper = await run(process.execPath, helperArgs, { env, cwd: root });
    if (helper.code !== 0) return { pass: false, judged: 1, note: `the run-config helper refused: ${helper.stderr.trim()}` };
    const printed = Object.fromEntries(helper.stdout.trim().split('\n').map((line) => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]));
    const config = JSON.parse(fs.readFileSync(printed.config, 'utf8'));
    const variant = { fence: true, serviceWorkers: config.browser.contextOptions.serviceWorkers, routes: true, judged: true };
    const driver = gatedDriver(printed.session, env, root);
    const result = await runLoopback('gated', variant, driver, fixture, [`--config=${printed.config}`, ...openFlags(options)], { named: false });
    result.args = config.browser.launchOptions.args;
    if (result.skip) return { skip: result.skip };
    const verdict = judgeLoopback(result, variant, fixture, { named: false });
    if (!['ask', 'allow'].includes(result.openGate)) verdict.problems.push(`the gate did not admit open: ${JSON.stringify(result.open)}`);
    fs.writeFileSync(path.join(out, 'gated.result.json'), `${JSON.stringify({ result, verdict }, null, 2)}\n`);
    console.log(`helper: session=${printed.session} mode=${printed.mode}`);
    printLoopback(result, verdict, variant);
    return { pass: verdict.problems.length === 0, judged: 1 };
  } finally {
    fixture.close();
  }
}

function modePairing(options, out) {
  const releasedRoot = path.resolve(options.released);
  const releasedConsent = require(path.join(releasedRoot, 'hooks', 'lib', 'verify-consent-v1.js'));
  const releasedHelper = require(path.join(releasedRoot, 'scripts', 'verify-browser-config.js'));
  const builtHelper = require(HELPER);
  const version = (root) => {
    try { return JSON.parse(fs.readFileSync(path.join(root, '.claude-plugin', 'plugin.json'), 'utf8')).version; } catch (_error) { return 'unknown'; }
  };
  const runDir = fs.realpathSync.native(fs.mkdtempSync(path.join(out, 'pairing-')));
  const file = path.join(runDir, consent.RUN_CONFIG_NAME);
  const origins = ['http://127.0.0.1:4200', 'http://localhost:9090'];
  const forward = releasedConsent.runConfigShape(builtHelper.buildConfig(runDir, origins, []), file);
  const reverse = consent.runConfigShape(releasedHelper.buildConfig(runDir, origins, []), file);
  console.log(`\n===== pairing =====`);
  console.log(`this checkout: ${version(PLUGIN)}; other installation: ${version(releasedRoot)} at ${releasedRoot}`);
  console.log(`  config of this checkout under the other gate: ${forward.ok ? 'ACCEPTED' : `refused: ${forward.fault}`}`);
  console.log(`  config of the other installation under this gate: ${reverse.ok ? 'ACCEPTED' : `refused: ${reverse.fault}`}`);
  const pass = !forward.ok && !reverse.ok;
  console.log(`  verdict: ${pass ? 'PASS' : 'FAIL'}${pass ? '' : ' (an installation accepts the run config of the other)'}`);
  return { pass, judged: 1 };
}

async function main() {
  let options;
  try { options = parseOptions(process.argv.slice(2)); }
  catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(2);
  }
  const out = options.out ? path.resolve(options.out) : fs.mkdtempSync(path.join(fs.realpathSync.native(os.tmpdir()), 'zensu-fence-probe-'));
  fs.mkdirSync(out, { recursive: true });
  const installed = header(options, out);
  let outcome;
  if (options.mode === 'pairing') {
    outcome = modePairing(options, out);
  } else if (process.platform === 'win32') {
    outcome = { skip: 'the probe has not been run on Windows' };
  } else if (installed.source === 'absent') {
    outcome = { skip: 'playwright-cli is not on PATH' };
  } else if (options.mode === 'matrix') {
    outcome = await modeMatrix(options, out);
  } else if (options.mode === 'remote') {
    outcome = await modeRemote(options, out);
  } else {
    outcome = await modeGated(options, out);
  }
  if (outcome.note) console.log(`fence-probe: ${outcome.note}`);
  if (outcome.skip) {
    console.log(`\nfence-probe: SKIP ${outcome.skip}`);
    process.exit(0);
  }
  if (outcome.judged === 0) {
    console.log('\nfence-probe: reference columns only, nothing judged');
    process.exit(0);
  }
  console.log(`\nfence-probe: ${outcome.pass ? 'PASS' : 'FAIL'} (${outcome.judged} judged run(s))`);
  process.exit(outcome.pass ? 0 : 1);
}

for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.once(signal, () => {
    closeActive().finally(() => process.exit(130));
  });
}

main().catch(async (error) => {
  console.error(error);
  await closeActive().catch(() => {});
  process.exit(1);
});
