'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const test = require('node:test');
const path = require('node:path');

const floor = require('../../hooks/lib/verify-navigation-floor-v1.js');
const {
  FLOOR_REASONS,
  MAX_POLICY_ROUTES,
  checkNavigationTarget,
  classifyOrigin,
  isLoopbackHost,
  isPublicAddress,
  normalizeHostname,
  normalizeRoute,
  parsePolicyTargets,
  policyContractFault,
  resolveRemoteHost,
} = floor;

test('the consent gate and the run-config helper require the floor module instead of carrying its own predicates', () => {
  const consentPath = path.resolve(__dirname, '../../hooks/lib/verify-consent-v1.js');
  const helperPath = path.resolve(__dirname, '../../scripts/verify-browser-config.js');
  for (const file of [consentPath, helperPath]) {
    const source = fs.readFileSync(file, 'utf8');
    assert.match(source, /verify-navigation-floor-v1\.js/, file);
    for (const own of ['function isPublicIpv4', 'function expandIpv6', 'function isLoopbackHost(', 'function isPublicAddress(',
      'function resolveRemoteHost(', 'function classifyOrigin(', 'function normalizeRoute(', 'function parsePolicyTargets(',
      'function policyContractFault(']) {
      assert.equal(source.includes(own), false, `${path.basename(file)}: ${own}`);
    }
  }
  const consent = require(consentPath);
  assert.equal(consent.REASONS.REMOTE_NEEDS_POLICY.endsWith(floor.CONSENT_REMOTE_REASON), true);
  const raw = JSON.stringify({ version: 1, mode: 'local', targets: [{ origin: 'http://127.0.0.1:4300', routes: ['/'], evidenceMode: 'declared-safe' }] });
  const parsed = parsePolicyTargets(raw);
  assert.deepEqual(consent.readPolicy({ ZENSU_VERIFY_NAVIGATION_POLICY_V1: raw }), { ok: true, mode: parsed.mode, targets: parsed.targets });
  assert.deepEqual(consent.readPolicy({ ZENSU_VERIFY_NAVIGATION_POLICY_V1: '{}' }), { ok: false, fault: policyContractFault('{}') });
});

test('loopback detection accepts every 127/8 address and ::1 and nothing else', () => {
  assert.equal(isLoopbackHost('127.0.0.1'), true);
  assert.equal(isLoopbackHost('127.255.0.9'), true);
  assert.equal(isLoopbackHost('[::1]'), true);
  assert.equal(isLoopbackHost('::1'), true);
  assert.equal(isLoopbackHost('localhost'), false);
  assert.equal(isLoopbackHost('128.0.0.1'), false);
  assert.equal(isLoopbackHost('::ffff:127.0.0.1'), false);
  assert.equal(normalizeHostname('[2001:DB8::1]'), '2001:db8::1');
});

test('public-address classification rejects private, reserved, loopback, mapped and documentation ranges', () => {
  for (const denied of ['10.1.2.3', '100.64.0.1', '127.0.0.1', '169.254.169.254', '172.16.0.1', '192.168.1.1', '192.0.2.1', '198.18.0.1', '203.0.113.5', '224.0.0.1', '0.0.0.0', '::1', 'fc00::1', 'fe80::1', '2001:db8::1', '::ffff:93.184.216.34', 'not-an-ip']) {
    assert.equal(isPublicAddress(denied), false, denied);
  }
  for (const allowed of ['93.184.216.34', '8.8.8.8', '2606:2800:220:1:248:1893:25c8:1946']) {
    assert.equal(isPublicAddress(allowed), true, allowed);
  }
});

test('navigation targets refuse credentials, query and fragment, and unknown schemes', () => {
  assert.equal(checkNavigationTarget('http://user:pw@127.0.0.1:5173/').reason, FLOOR_REASONS.CREDENTIALS);
  assert.equal(checkNavigationTarget('http://127.0.0.1:5173/?x=1').reason, FLOOR_REASONS.QUERY_OR_FRAGMENT);
  assert.equal(checkNavigationTarget('http://127.0.0.1:5173/#top').reason, FLOOR_REASONS.QUERY_OR_FRAGMENT);
  assert.equal(checkNavigationTarget('http://127.0.0.1:5173/api?x=1', false).ok, true);
  assert.equal(checkNavigationTarget('file:///etc/passwd').reason, FLOOR_REASONS.SCHEME);
  assert.equal(checkNavigationTarget('not a url').reason, FLOOR_REASONS.INVALID);
  assert.equal(checkNavigationTarget('ws://127.0.0.1:5173/events', false).origin, 'http://127.0.0.1:5173');
  assert.equal(checkNavigationTarget('wss://app.example.com/events', false).origin, 'https://app.example.com');
});

test('origin classification splits literal loopback from public https and refuses the rest', () => {
  assert.equal(classifyOrigin('http://127.0.0.1:5173/inventory').mode, 'local');
  assert.equal(classifyOrigin('https://[::1]:8443/').mode, 'local');
  assert.equal(classifyOrigin('https://app.example.com/dashboard').mode, 'remote');
  assert.equal(classifyOrigin('https://93.184.216.34/').mode, 'remote');
  assert.equal(classifyOrigin('http://localhost:5173/').reason, FLOOR_REASONS.LOCAL_LITERAL_LOOPBACK);
  assert.equal(classifyOrigin('http://app.example.com/').reason, FLOOR_REASONS.LOCAL_LITERAL_LOOPBACK);
  assert.equal(classifyOrigin('http://10.0.0.5/').reason, FLOOR_REASONS.REMOTE_HTTPS);
  assert.equal(classifyOrigin('https://10.0.0.5/').reason, FLOOR_REASONS.REMOTE_NOT_PUBLIC);
  assert.equal(classifyOrigin('https://169.254.169.254/latest/meta-data').reason, FLOOR_REASONS.REMOTE_NOT_PUBLIC);
  assert.equal(classifyOrigin('https://[::ffff:93.184.216.34]/').reason, FLOOR_REASONS.REMOTE_NOT_PUBLIC);
  assert.equal(classifyOrigin('http://user:pw@127.0.0.1:5173/').reason, FLOOR_REASONS.CREDENTIALS);
  assert.equal(classifyOrigin('http://127.0.0.1:5173/?q').reason, FLOOR_REASONS.QUERY_OR_FRAGMENT);
});

test('remote host resolution pins only globally routable answers', async () => {
  assert.deepEqual(await resolveRemoteHost('93.184.216.34', async () => []), ['93.184.216.34']);
  await assert.rejects(resolveRemoteHost('10.0.0.1', async () => []), /not globally routable/);
  const resolver = async () => [{ address: '93.184.216.34' }, { address: '93.184.216.34' }];
  assert.deepEqual(await resolveRemoteHost('app.example.com', resolver), ['93.184.216.34']);
  const mixed = async () => [{ address: '93.184.216.34' }, { address: '192.168.0.1' }];
  await assert.rejects(resolveRemoteHost('app.example.com', mixed), /non-public or unresolved/);
  await assert.rejects(resolveRemoteHost('app.example.com', async () => []), /non-public or unresolved/);
});

// A non-string target is refused rather than coerced. String(["http://127.0.0.1:9999"]) is the
// bare URL, so coercion would classify an array argument as loopback.
test('the navigation target refuses a non-string target instead of coercing it', () => {
  for (const value of [['http://127.0.0.1:9999/'], undefined, null, 42, { toString: () => 'http://127.0.0.1:9999/' }]) {
    assert.equal(checkNavigationTarget(value).reason, FLOOR_REASONS.INVALID);
    assert.equal(classifyOrigin(value).ok, false);
    assert.equal(classifyOrigin(value).mode, undefined);
  }
  assert.equal(classifyOrigin('http://127.0.0.1:9999/').mode, 'local');
});

// normalizeRoute's production consumers include normalizeRoutes() in hooks/lib/verify-consent-v1.js,
// which builds the route list the human reads in the consent prompt, parsePolicyTargets() in the
// floor module, which validates the navigation policy's declared routes, and checkPolicy() in
// scripts/verify-browser-config.js, which validates the route a --check-policy call names.
// Its own truth table was graded by nothing. The load-bearing conjunct is the final
// `normalized === route`: without it a declared `/a/../b` renders as written while naming a
// different path, and `//evil.example.com/x` -- which a URL parser reads as a host -- renders
// as a route.
//
// `/a%2e%2e/b` is ACCEPTED and that is correct rather than an oversight. WHATWG treats `%2e%2e`
// as a double-dot segment, but only when it is the WHOLE segment; here the segment is `a%2e%2e`.
// Two independent readers of this file got that boundary wrong, so the discriminating pair is
// pinned rather than left to be re-derived: `/%2e%2e/b` collapses to `/b` and is refused,
// `/a%2e%2e/b` does not collapse and is kept. Every encoded spelling of a whole dot segment --
// `%2e%2e`, `%2E%2E`, `%2e.`, `.%2e` and the single-dot forms -- is in the refused list below,
// so encoding a traversal token does not neutralize the check.
test('route normalization accepts only an absolute, query-free, already-normalized pathname', () => {
  for (const good of ['/', '/login', '/a/b/c', '/a//b', '/a%2e%2e/b', '/%41']) {
    assert.equal(normalizeRoute(good), good, good);
  }

  for (const bad of ['login', '', '/a?b=1', '/a#f', '/a/*', '/a/../b', '/a/./b', '/a b',
    '//evil.example.com/x', '/a\\b',
    '/%2e%2e/b', '/%2E%2E/b', '/%2e./b', '/.%2e/b', '/a/%2e%2e/b', '/%2e/b', '/a/%2e/b',
    42, null, undefined, ['/a'], { toString: () => '/a' }]) {
    assert.equal(normalizeRoute(bad), null, JSON.stringify(bad));
  }
});

// The doctor RENDERS this string to an operator and the consent gate decides on it being
// empty, so the three causes have to stay tellable apart: a conflated one sends the reader to
// the wrong half of the policy.
test('the contract check names which guard refused and keeps the three causes distinct', () => {
  const target = { origin: 'http://127.0.0.1:4300', routes: ['/'], evidenceMode: 'declared-safe' };
  const causes = [
    ['{oops', 'policy is not valid JSON'],
    ['{}', 'policy contains unknown or missing keys'],
    [JSON.stringify({ version: 1 }), 'policy contains unknown or missing keys'],
    [JSON.stringify({ version: 1, mode: 'local', targets: [target], extra: 1 }), 'policy contains unknown or missing keys'],
    [JSON.stringify({ version: 2, mode: 'local', targets: [target] }), 'policy contract is invalid'],
    [JSON.stringify({ version: 1, mode: 'sideways', targets: [target] }), 'policy contract is invalid'],
    [JSON.stringify({ version: 1, mode: 'local', targets: [] }), 'policy contract is invalid'],
    [JSON.stringify({ version: 1, mode: 'local', targets: Array.from({ length: 9 }, () => target) }), 'policy contract is invalid'],
  ];
  for (const [raw, expected] of causes) assert.equal(policyContractFault(raw), expected, raw.slice(0, 48));
  assert.equal(new Set(causes.map(([, expected]) => expected)).size, 3);
  assert.equal(policyContractFault(JSON.stringify({ version: 1, mode: 'local', targets: [target] })), '');
});

const POLICY_TARGET = Object.freeze({ origin: 'http://127.0.0.1:4300', routes: ['/'], evidenceMode: 'declared-safe' });

function policyOf(mode, targets) {
  return JSON.stringify({ version: 1, mode, targets });
}

test('parsePolicyTargets maps each target to its canonical origin, hostname and route set', () => {
  const local = parsePolicyTargets(policyOf('local', [
    { origin: 'http://127.0.0.1:4300', routes: ['/', '/login'], evidenceMode: 'declared-safe' },
    { origin: 'http://[::1]:4301', routes: ['/a'], evidenceMode: 'declared-safe' },
  ]));
  assert.equal(local.ok, true);
  assert.equal(local.mode, 'local');
  assert.deepEqual([...local.targets.keys()], ['http://127.0.0.1:4300', 'http://[::1]:4301']);
  const first = local.targets.get('http://127.0.0.1:4300');
  assert.equal(first.origin, 'http://127.0.0.1:4300');
  assert.equal(first.hostname, '127.0.0.1');
  assert.deepEqual([...first.routes], ['/', '/login']);
  assert.equal(local.targets.get('http://[::1]:4301').hostname, '::1');

  const remote = parsePolicyTargets(policyOf('remote', [
    { origin: 'https://App.Example.com', routes: ['/'], evidenceMode: 'declared-safe' },
    { origin: 'https://93.184.216.34:8443', routes: ['/x'], evidenceMode: 'declared-safe' },
  ]));
  assert.equal(remote.ok, true);
  assert.equal(remote.mode, 'remote');
  assert.deepEqual([...remote.targets.keys()], ['https://app.example.com', 'https://93.184.216.34:8443']);
  assert.equal(remote.targets.get('https://app.example.com').hostname, 'app.example.com');
  assert.deepEqual([...remote.targets.get('https://93.184.216.34:8443').routes], ['/x']);
});

test('parsePolicyTargets refuses a top-level contract fault with the shared check\'s own reason', () => {
  const refused = ['', '{oops', '{}', 'null', '[]',
    JSON.stringify({ version: 1 }),
    JSON.stringify({ version: 1, mode: 'local', targets: [POLICY_TARGET], extra: 1 }),
    JSON.stringify({ version: 2, mode: 'local', targets: [POLICY_TARGET] }),
    JSON.stringify({ version: 1, mode: 'sideways', targets: [POLICY_TARGET] }),
    JSON.stringify({ version: 1, mode: 'local', targets: 'http://127.0.0.1:4300' }),
    policyOf('local', []),
    policyOf('local', Array.from({ length: 9 }, (_unused, index) => ({ ...POLICY_TARGET, origin: `http://127.0.0.1:${4300 + index}` }))),
  ];
  for (const raw of refused) {
    const fault = policyContractFault(raw);
    assert.notEqual(fault, '', raw.slice(0, 48));
    assert.deepEqual(parsePolicyTargets(raw), { ok: false, fault }, raw.slice(0, 48));
  }
  const eight = parsePolicyTargets(policyOf('local', Array.from({ length: 8 }, (_unused, index) => ({ ...POLICY_TARGET, origin: `http://127.0.0.1:${4300 + index}` }))));
  assert.equal(eight.ok, true);
  assert.equal(eight.targets.size, 8);
});

test('parsePolicyTargets refuses a target outside the declared-safe contract and bounds its routes at MAX_POLICY_ROUTES', () => {
  assert.equal(MAX_POLICY_ROUTES, 64);
  const contract = { ok: false, fault: 'policy target contract is invalid; v1 supports declared-safe evidence only' };
  const refused = [
    { ...POLICY_TARGET, evidenceMode: 'other' },
    { origin: POLICY_TARGET.origin, routes: POLICY_TARGET.routes },
    { ...POLICY_TARGET, extra: true },
    { ...POLICY_TARGET, routes: [] },
    { ...POLICY_TARGET, routes: '/' },
    null,
    'http://127.0.0.1:4300',
  ];
  for (const target of refused) {
    assert.deepEqual(parsePolicyTargets(policyOf('local', [target])), contract, JSON.stringify(target));
  }
  const routes = (count) => Array.from({ length: count }, (_unused, index) => `/r${index}`);
  const atBound = parsePolicyTargets(policyOf('local', [{ ...POLICY_TARGET, routes: routes(MAX_POLICY_ROUTES) }]));
  assert.equal(atBound.ok, true);
  assert.equal(atBound.targets.get(POLICY_TARGET.origin).routes.size, MAX_POLICY_ROUTES);
  assert.deepEqual(parsePolicyTargets(policyOf('local', [{ ...POLICY_TARGET, routes: routes(MAX_POLICY_ROUTES + 1) }])), contract);
});

test('parsePolicyTargets names the route or origin fault it met', () => {
  const route = 'policy route must be an absolute query-free pathname';
  const shape = 'policy origin must not contain credentials, path, query, or fragment';
  const cases = [
    [{ routes: ['login'] }, route],
    [{ routes: ['/a?b=1'] }, route],
    [{ routes: ['/a/../b'] }, route],
    [{ routes: ['/a/*'] }, route],
    [{ routes: [42] }, route],
    [{ routes: ['/', '/'] }, 'policy routes must be normalized and unique'],
    [{ origin: 4300 }, 'policy origin must be a string'],
    [{ origin: 'not a url' }, 'policy origin is invalid'],
    [{ origin: 'http://user:pw@127.0.0.1:4300' }, shape],
    [{ origin: 'http://127.0.0.1:4300/app' }, shape],
    [{ origin: 'http://127.0.0.1:4300/?x=1' }, shape],
    [{ origin: 'http://127.0.0.1:4300/#top' }, shape],
    [{ origin: 'http://127.0.0.1:4300/?' }, shape],
  ];
  for (const [override, fault] of cases) {
    assert.deepEqual(parsePolicyTargets(policyOf('local', [{ ...POLICY_TARGET, ...override }])), { ok: false, fault }, JSON.stringify(override));
  }
  assert.deepEqual(parsePolicyTargets(policyOf('local', [POLICY_TARGET, { ...POLICY_TARGET, origin: 'http://127.0.0.1:4300/' }])),
    { ok: false, fault: 'policy origins must be unique' });
});

test('parsePolicyTargets admits only literal loopback in local mode and only non-loopback https in remote mode', () => {
  const single = (mode, origin) => parsePolicyTargets(policyOf(mode, [{ ...POLICY_TARGET, origin }]));
  for (const origin of ['http://127.0.0.1:4300', 'https://127.0.0.2:8443', 'http://[::1]:4300']) {
    assert.equal(single('local', origin).ok, true, origin);
  }
  for (const origin of ['http://localhost:4300', 'http://10.0.0.5:4300', 'https://app.example.com', 'ws://127.0.0.1:4300']) {
    assert.deepEqual(single('local', origin), { ok: false, fault: FLOOR_REASONS.LOCAL_LITERAL_LOOPBACK }, origin);
  }
  for (const origin of ['https://app.example.com', 'https://93.184.216.34', 'https://[2606:2800:220:1:248:1893:25c8:1946]']) {
    assert.equal(single('remote', origin).ok, true, origin);
  }
  for (const origin of ['http://app.example.com', 'https://127.0.0.1', 'https://[::1]:8443', 'ws://app.example.com']) {
    assert.deepEqual(single('remote', origin), { ok: false, fault: FLOOR_REASONS.REMOTE_HTTPS }, origin);
  }
  for (const origin of ['https://10.0.0.5', 'https://169.254.169.254', 'https://[fc00::1]']) {
    assert.deepEqual(single('remote', origin), { ok: false, fault: FLOOR_REASONS.REMOTE_NOT_PUBLIC }, origin);
  }
});
