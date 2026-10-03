'use strict';
const net = require('node:net');

const FLOOR_REASONS = Object.freeze({
  INVALID: 'navigation target is invalid',
  CREDENTIALS: 'navigation target contains credentials',
  QUERY_OR_FRAGMENT: 'navigation target contains query or fragment',
  LOCAL_LOOPBACK_ONLY: 'local navigation policy accepts loopback origins only: 127.0.0.0/8, [::1] or localhost',
  REMOTE_HTTPS: 'remote navigation policy requires non-loopback HTTPS origins',
  REMOTE_NOT_PUBLIC: 'remote address is not globally routable',
  SCHEME: 'navigation target scheme is not http, https, ws, or wss',
  NETWORK_ONLY_HTTPS: 'a network-only origin outside loopback requires HTTPS',
  HOSTNAME_PATTERN: 'policy origin must name its host exactly: an IP literal, or a hostname of a-z, 0-9, ".", "-" and "_" only, never a wildcard or pattern',
});

const CONSENT_REMOTE_REASON = 'consent mode admits loopback origins only (127.0.0.0/8, [::1] or localhost); a remote target needs the parent-environment navigation policy';

const LOCALHOST_NAME = 'localhost';

function normalizeRoute(route) {
  if (typeof route !== 'string' || !route.startsWith('/')
      || route.includes('?') || route.includes('#') || route.includes('*')) return null;
  let normalized;
  try { normalized = new URL(route, 'https://zensu.invalid').pathname; }
  catch (_error) { return null; }
  return normalized === route ? route : null;
}

function normalizeHostname(hostname) {
  return String(hostname).toLowerCase().replace(/^\[|\]$/g, '');
}

function ipv4Number(address) {
  const parts = String(address).split('.').map(Number);
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) return null;
  return parts.reduce((value, part) => ((value << 8) | part) >>> 0, 0);
}

function inIpv4Range(value, base, bits) {
  const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
  return (value & mask) === (ipv4Number(base) & mask);
}

function isPublicIpv4(address) {
  const value = ipv4Number(address);
  if (value === null) return false;
  const denied = [
    ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8],
    ['169.254.0.0', 16], ['172.16.0.0', 12], ['192.0.0.0', 24], ['192.0.2.0', 24],
    ['192.88.99.0', 24], ['192.168.0.0', 16], ['198.18.0.0', 15], ['198.51.100.0', 24],
    ['203.0.113.0', 24], ['224.0.0.0', 4], ['240.0.0.0', 4],
  ];
  return !denied.some(([base, bits]) => inIpv4Range(value, base, bits));
}

function expandIpv6(address) {
  const zoneFree = String(address).toLowerCase().split('%')[0];
  if (zoneFree.includes('.')) return null;
  const halves = zoneFree.split('::');
  if (halves.length > 2) return null;
  const left = halves[0] ? halves[0].split(':') : [];
  const right = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const missing = 8 - left.length - right.length;
  if (missing < 0 || (halves.length === 1 && missing !== 0)) return null;
  const groups = [...left, ...Array(missing).fill('0'), ...right];
  if (groups.length !== 8 || groups.some((group) => !/^[0-9a-f]{1,4}$/.test(group))) return null;
  return groups.map((group) => Number.parseInt(group, 16));
}

function isPublicIpv6(address) {
  const groups = expandIpv6(address);
  if (!groups) return false;
  const value = groups.reduce((result, group) => (result << 16n) | BigInt(group), 0n);
  const inRange = (base, bits) => {
    const baseGroups = expandIpv6(base);
    const baseValue = baseGroups.reduce((result, group) => (result << 16n) | BigInt(group), 0n);
    const shift = 128n - BigInt(bits);
    return (value >> shift) === (baseValue >> shift);
  };
  if (!inRange('2000::', 3)) return false;
  const specialPurpose = [
    ['2001::', 32],
    ['2001:1::', 32],
    ['2001:2::', 48],
    ['2001:10::', 28],
    ['2001:20::', 28],
    ['2001:db8::', 32],
    ['2002::', 16],
    ['3fff::', 20],
  ];
  return !specialPurpose.some(([base, bits]) => inRange(base, bits));
}

function isPublicAddress(address) {
  const family = net.isIP(address);
  return family === 4 ? isPublicIpv4(address) : family === 6 ? isPublicIpv6(address) : false;
}

function isLoopbackHost(hostname) {
  const normalized = normalizeHostname(hostname);
  if (normalized === '::1') return true;
  const value = ipv4Number(normalized);
  return value !== null && inIpv4Range(value, '127.0.0.0', 8);
}

function isLocalHost(hostname) {
  return isLoopbackHost(hostname) || normalizeHostname(hostname) === LOCALHOST_NAME;
}

async function resolveRemoteHost(hostname, resolver) {
  const normalized = normalizeHostname(hostname);
  if (net.isIP(normalized)) {
    if (!isPublicAddress(normalized)) throw new Error(FLOOR_REASONS.REMOTE_NOT_PUBLIC);
    return [normalized];
  }
  const records = await resolver(normalized, { all: true, verbatim: true });
  const addresses = [...new Set(records.map((record) => record.address))];
  if (addresses.length === 0 || addresses.some((address) => !isPublicAddress(address))) {
    throw new Error('remote DNS includes a non-public or unresolved address');
  }
  return addresses;
}

function comparisonOrigin(parsed) {
  if (parsed.protocol === 'ws:') return `http://${parsed.host}`;
  if (parsed.protocol === 'wss:') return `https://${parsed.host}`;
  return parsed.origin;
}

function checkNavigationTarget(rawUrl, navigation = true) {
  // A non-string target is refused, never coerced. String(["http://127.0.0.1:9999"])
  // is the bare URL, so coercion would let an array argument classify as loopback.
  if (typeof rawUrl !== 'string') return { ok: false, reason: FLOOR_REASONS.INVALID };
  let parsed;
  try { parsed = new URL(rawUrl); }
  catch (_error) { return { ok: false, reason: FLOOR_REASONS.INVALID }; }
  if (!['http:', 'https:', 'ws:', 'wss:'].includes(parsed.protocol)) {
    return { ok: false, reason: FLOOR_REASONS.SCHEME };
  }
  if (parsed.username || parsed.password) return { ok: false, reason: FLOOR_REASONS.CREDENTIALS };
  if (navigation && (parsed.search || parsed.hash)) return { ok: false, reason: FLOOR_REASONS.QUERY_OR_FRAGMENT };
  return { ok: true, parsed, origin: comparisonOrigin(parsed), pathname: parsed.pathname };
}

function classifyOrigin(rawUrl, navigation = true) {
  const target = checkNavigationTarget(rawUrl, navigation);
  if (!target.ok) return target;
  const { parsed } = target;
  const hostname = normalizeHostname(parsed.hostname);
  const secure = parsed.protocol === 'https:' || parsed.protocol === 'wss:';
  if (isLocalHost(hostname)) {
    return { ...target, mode: 'local', hostname };
  }
  if (net.isIP(hostname)) {
    if (!secure) return { ok: false, reason: FLOOR_REASONS.REMOTE_HTTPS, origin: target.origin };
    if (!isPublicAddress(hostname)) return { ok: false, reason: FLOOR_REASONS.REMOTE_NOT_PUBLIC, origin: target.origin };
    return { ...target, mode: 'remote', hostname };
  }
  if (!secure) return { ok: false, reason: FLOOR_REASONS.LOCAL_LOOPBACK_ONLY, origin: target.origin };
  return { ...target, mode: 'remote', hostname };
}

const POLICY_KEYS = Object.freeze(['mode', 'targets', 'version']);
const NETWORK_ONLY_POLICY_KEYS = Object.freeze(['mode', 'networkOnlyOrigins', 'targets', 'version']);
const MAX_NETWORK_ONLY_ORIGINS = 8;
const NETWORK_ONLY_LIST_FAULT = `policy networkOnlyOrigins must be a list of 1 to ${MAX_NETWORK_ONLY_ORIGINS} origins`;
const NETWORK_ONLY_OVERLAP_FAULT = 'policy origin must not be both a target and network-only';
const HOSTNAME_RE = /^[a-z0-9._-]+$/;

// The TOP-LEVEL guards of a navigation policy. It answers '' for a policy whose contract
// holds and a short reason otherwise, so a caller renders the reason it was given rather than
// inventing one.
//
// An EMPTY raw is not judged here: a caller asking "is a policy present" must decide absence
// itself. Answering '' for '' would tell such a caller that the empty string is an acceptable
// policy.
function policyContractFault(raw) {
  let value;
  try { value = JSON.parse(raw); }
  catch (_error) { return 'policy is not valid JSON'; }
  const keys = JSON.stringify(Object.keys(value || {}).sort());
  if (keys !== JSON.stringify(POLICY_KEYS) && keys !== JSON.stringify(NETWORK_ONLY_POLICY_KEYS)) {
    return 'policy contains unknown or missing keys';
  }
  if (value.version !== 1 || !['local', 'remote'].includes(value.mode)
      || !Array.isArray(value.targets) || value.targets.length < 1 || value.targets.length > 8) {
    return 'policy contract is invalid';
  }
  if (Object.prototype.hasOwnProperty.call(value, 'networkOnlyOrigins')
      && (!Array.isArray(value.networkOnlyOrigins) || value.networkOnlyOrigins.length < 1
        || value.networkOnlyOrigins.length > MAX_NETWORK_ONLY_ORIGINS)) {
    return NETWORK_ONLY_LIST_FAULT;
  }
  return '';
}

function policyOriginEntry(rawOrigin, label) {
  if (typeof rawOrigin !== 'string') return { fault: `${label} must be a string` };
  let parsed;
  try { parsed = new URL(rawOrigin); }
  catch (_error) { return { fault: `${label} is invalid` }; }
  if (parsed.username || parsed.password || parsed.search || parsed.hash || parsed.pathname !== '/'
      || rawOrigin.includes('?') || rawOrigin.includes('#')) {
    return { fault: `${label} must not contain credentials, path, query, or fragment` };
  }
  return { origin: parsed.origin, protocol: parsed.protocol, hostname: normalizeHostname(parsed.hostname) };
}

function policyFloorFault(entry, mode, networkOnly) {
  const { protocol, hostname } = entry;
  if (mode === 'local' && (!networkOnly || isLocalHost(hostname))) {
    if (!['http:', 'https:'].includes(protocol) || !isLocalHost(hostname)) return FLOOR_REASONS.LOCAL_LOOPBACK_ONLY;
  } else if (protocol !== 'https:' || isLocalHost(hostname)) {
    return mode === 'local' ? FLOOR_REASONS.NETWORK_ONLY_HTTPS : FLOOR_REASONS.REMOTE_HTTPS;
  } else if (net.isIP(hostname) && !isPublicAddress(hostname)) {
    return FLOOR_REASONS.REMOTE_NOT_PUBLIC;
  }
  if (!net.isIP(hostname) && !HOSTNAME_RE.test(hostname)) return FLOOR_REASONS.HOSTNAME_PATTERN;
  return '';
}

const MAX_POLICY_ROUTES = 64;
const POLICY_TARGET_KEYS = Object.freeze(['evidenceMode', 'origin']);
const LEGACY_POLICY_TARGET_KEYS = Object.freeze(['evidenceMode', 'origin', 'routes']);
const TARGET_CONTRACT_FAULT = 'policy target contract is invalid; v1 supports declared-safe evidence only';

function legacyRoutesFault(rawRoutes) {
  if (!Array.isArray(rawRoutes) || rawRoutes.length < 1 || rawRoutes.length > MAX_POLICY_ROUTES) return TARGET_CONTRACT_FAULT;
  const routes = new Set();
  for (const route of rawRoutes) {
    const normalizedRoute = normalizeRoute(route);
    if (normalizedRoute === null) return 'policy route must be an absolute query-free pathname';
    if (routes.has(normalizedRoute)) return 'policy routes must be normalized and unique';
    routes.add(normalizedRoute);
  }
  return '';
}

function parsePolicyTargets(raw) {
  const fault = policyContractFault(raw);
  if (fault) return { ok: false, fault };
  const value = JSON.parse(raw);
  const targets = new Map();
  for (const rawTarget of value.targets) {
    const targetKeys = JSON.stringify(Object.keys(rawTarget || {}).sort());
    const legacy = targetKeys === JSON.stringify(LEGACY_POLICY_TARGET_KEYS);
    if ((!legacy && targetKeys !== JSON.stringify(POLICY_TARGET_KEYS)) || rawTarget.evidenceMode !== 'declared-safe') {
      return { ok: false, fault: TARGET_CONTRACT_FAULT };
    }
    const routesFault = legacy ? legacyRoutesFault(rawTarget.routes) : '';
    if (routesFault) return { ok: false, fault: routesFault };
    const entry = policyOriginEntry(rawTarget.origin, 'policy origin');
    if (entry.fault) return { ok: false, fault: entry.fault };
    if (targets.has(entry.origin)) return { ok: false, fault: 'policy origins must be unique' };
    const floorFault = policyFloorFault(entry, value.mode, false);
    if (floorFault) return { ok: false, fault: floorFault };
    targets.set(entry.origin, { origin: entry.origin, hostname: entry.hostname });
  }
  const networkOnly = new Map();
  for (const rawOrigin of value.networkOnlyOrigins || []) {
    const entry = policyOriginEntry(rawOrigin, 'policy network-only origin');
    if (entry.fault) return { ok: false, fault: entry.fault };
    if (networkOnly.has(entry.origin)) return { ok: false, fault: 'policy network-only origins must be unique' };
    if (targets.has(entry.origin)) return { ok: false, fault: NETWORK_ONLY_OVERLAP_FAULT };
    const floorFault = policyFloorFault(entry, value.mode, true);
    if (floorFault) return { ok: false, fault: floorFault };
    networkOnly.set(entry.origin, { origin: entry.origin, hostname: entry.hostname });
  }
  return { ok: true, mode: value.mode, targets, networkOnly };
}

module.exports = {
  CONSENT_REMOTE_REASON,
  FLOOR_REASONS,
  LEGACY_POLICY_TARGET_KEYS,
  LOCALHOST_NAME,
  MAX_NETWORK_ONLY_ORIGINS,
  MAX_POLICY_ROUTES,
  NETWORK_ONLY_POLICY_KEYS,
  POLICY_KEYS,
  POLICY_TARGET_KEYS,
  checkNavigationTarget,
  parsePolicyTargets,
  policyContractFault,
  classifyOrigin,
  expandIpv6,
  inIpv4Range,
  ipv4Number,
  isLocalHost,
  isLoopbackHost,
  isPublicAddress,
  isPublicIpv4,
  isPublicIpv6,
  normalizeHostname,
  normalizeRoute,
  resolveRemoteHost,
};
