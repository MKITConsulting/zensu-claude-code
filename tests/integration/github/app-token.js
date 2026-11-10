'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const PERMISSIONS = Object.freeze({ contents: 'write', metadata: 'read', pull_requests: 'write' });
const REPO = /^([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)$/;
const APP = /^[A-Za-z0-9.]{1,64}$/;
const TOKEN = /^[A-Za-z0-9_]{20,255}$/;

class Refusal extends Error {}

function base64url(value) {
  return Buffer.from(value).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function appJwt(appId, key, now) {
  const issuer = /^[0-9]+$/.test(appId) ? Number(appId) : appId;
  const header = base64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const payload = base64url(JSON.stringify({ iat: now - 60, exp: now + 540, iss: issuer }));
  const signature = crypto.sign('sha256', Buffer.from(`${header}.${payload}`), key);
  return `${header}.${payload}.${base64url(signature)}`;
}

function readKey(file) {
  let stat;
  try {
    stat = fs.lstatSync(file);
  } catch {
    throw new Refusal(`the App key file ${file} does not exist`);
  }
  if (!stat.isFile()) throw new Refusal(`the App key file ${file} is not a regular file`);
  if (process.platform !== 'win32' && (stat.mode & 0o077) !== 0) {
    throw new Refusal(`the App key file ${file} is readable by others; run chmod 600 on it`);
  }
  if (stat.size > 16384) throw new Refusal(`the App key file ${file} is larger than a PEM private key`);
  try {
    return crypto.createPrivateKey(fs.readFileSync(file, 'utf8'));
  } catch {
    throw new Refusal(`the App key file ${file} holds no PEM private key`);
  }
}

function detail(body) {
  return body && typeof body.message === 'string' ? `: ${body.message.replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, 200)}` : '';
}

async function call(api, route, bearer, init = {}) {
  const headers = {
    Accept: 'application/vnd.github+json',
    Authorization: `Bearer ${bearer}`,
    'User-Agent': 'zensu-github-live',
    'X-GitHub-Api-Version': '2022-11-28',
  };
  if (init.body !== undefined) headers['Content-Type'] = 'application/json';
  const response = await fetch(`${api}${route}`, {
    method: init.method || 'GET',
    headers,
    body: init.body,
    redirect: 'error',
    signal: AbortSignal.timeout(30000),
  });
  let body = null;
  try {
    body = await response.json();
  } catch {
    body = null;
  }
  return { status: response.status, body };
}

function sameKeys(actual, wanted) {
  if (!actual || typeof actual !== 'object' || Array.isArray(actual)) return false;
  const keys = Object.keys(actual).sort();
  return JSON.stringify(keys) === JSON.stringify(Object.keys(wanted).sort())
    && keys.every((key) => actual[key] === wanted[key]);
}

function writeSecret(file, text) {
  fs.rmSync(file, { force: true });
  const fd = fs.openSync(file, 'wx', 0o600);
  try {
    fs.writeSync(fd, text);
  } finally {
    fs.closeSync(fd);
  }
}

async function mint(options) {
  const { api, appId, keyFile, repo, out } = options;
  const match = REPO.exec(repo || '');
  if (!match) throw new Refusal(`'${repo}' is not an owner/name repository`);
  if (!APP.test(appId || '')) throw new Refusal(`'${appId}' is not a GitHub App ID or client ID`);
  const key = readKey(keyFile);
  const jwt = appJwt(appId, key, Math.floor(Date.now() / 1000));
  const installation = await call(api, `/repos/${match[1]}/${match[2]}/installation`, jwt);
  if (installation.status !== 200 || !Number.isSafeInteger(installation.body && installation.body.id)) {
    throw new Error(`the GitHub App has no installation on ${repo} (HTTP ${installation.status}${detail(installation.body)})`);
  }
  const granted = await call(api, `/app/installations/${installation.body.id}/access_tokens`, jwt, {
    method: 'POST',
    body: JSON.stringify({ repositories: [match[2]], permissions: PERMISSIONS }),
  });
  if (granted.status !== 201 || !granted.body) {
    throw new Error(`minting the installation token failed (HTTP ${granted.status}${detail(granted.body)})`);
  }
  const { token, expires_at: expiresAt, permissions, repositories } = granted.body;
  if (typeof token !== 'string' || !TOKEN.test(token)) throw new Error('the token response carries no token');
  if (!sameKeys(permissions, PERMISSIONS)) {
    throw new Error(`the token carries other permissions than requested: ${JSON.stringify(permissions)}`);
  }
  if (!Array.isArray(repositories) || repositories.length !== 1
    || String(repositories[0] && repositories[0].full_name).toLowerCase() !== repo.toLowerCase()) {
    throw new Error(`the token is not limited to ${repo}`);
  }
  if (process.env.GITHUB_ACTIONS === 'true') process.stdout.write(`::add-mask::${token}\n`);
  fs.mkdirSync(out, { recursive: true, mode: 0o700 });
  fs.chmodSync(out, 0o700);
  writeSecret(path.join(out, 'token'), token);
  writeSecret(path.join(out, 'header'), `Authorization: Bearer ${token}\n`);
  fs.writeFileSync(path.join(out, 'repo'), `${repo}\n`);
  fs.writeFileSync(path.join(out, 'api'), `${api}\n`);
  fs.writeFileSync(path.join(out, 'expires-at'), `${String(expiresAt)}\n`);
  return { repo, expiresAt: String(expiresAt) };
}

async function revoke({ api, state }) {
  const tokenFile = path.join(state, 'token');
  let token = '';
  try {
    token = fs.readFileSync(tokenFile, 'utf8').trim();
  } catch {
    token = '';
  }
  fs.rmSync(tokenFile, { force: true });
  fs.rmSync(path.join(state, 'header'), { force: true });
  if (!TOKEN.test(token)) return 'none';
  const result = await call(api, '/installation/token', token, { method: 'DELETE' });
  if (result.status === 204) return 'revoked';
  if (result.status === 401) return 'expired';
  throw new Error(`revoking the installation token failed (HTTP ${result.status}${detail(result.body)})`);
}

function options(argv) {
  const parsed = {};
  for (let i = 0; i < argv.length; i += 2) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (!/^--[a-z-]+$/.test(flag || '') || value === undefined) throw new Refusal(`unexpected argument '${flag}'`);
    parsed[flag.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = value;
  }
  return parsed;
}

async function main(argv) {
  const [verb, ...rest] = argv;
  const parsed = options(rest);
  if (!/^https?:\/\/[^\s/]+$/.test(parsed.api || '')) throw new Refusal(`'${parsed.api}' is not an API base URL`);
  if (verb === 'mint') {
    const minted = await mint(parsed);
    process.stderr.write(`github-token: minted an installation token for ${minted.repo}, valid until ${minted.expiresAt}\n`);
  } else if (verb === 'revoke') {
    const outcome = await revoke(parsed);
    process.stderr.write(`github-token: installation token ${outcome}\n`);
  } else {
    throw new Refusal('usage: app-token.js mint --api URL --app-id ID --key-file PEM --repo OWNER/NAME --out DIR | revoke --api URL --state DIR');
  }
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`github-token: ${error.message}\n`);
    process.exit(error instanceof Refusal ? 2 : 1);
  });
}

module.exports = { appJwt, mint, revoke, PERMISSIONS };
