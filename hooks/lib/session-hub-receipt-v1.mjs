import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { ensureLedgerDir, ledgerPathUnlinked } from '../../skills/session-trail/scripts/session-lineage-v1.mjs';

export const RECEIPT_SCHEMA_VERSION = 1;
export const RECEIPT_KIND = 'session-hub-receipt';
export const RECEIPT_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
export const RECEIPT_SCAN_LIMIT = 512;
export const COMMAND_NAME = '/zensu:session-trail';
export const TAKEOVER_PREFIX = `${COMMAND_NAME} takeover `;
export const TAKEOVER_SUFFIX = ' --all';
export const RECEIPT_FLAG = ' --receipt ';
export const RECEIPT_DIRECTORY = `zensu/session-hub/v${RECEIPT_SCHEMA_VERSION}/receipts`;

const MAX_PAYLOAD_CHARS = 256 * 1024;
const MAX_MANIFEST_BYTES = 64 * 1024;
const SESSION_ID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const TOKEN = '[0-9a-f]{32}';
const REMINDER_OPEN = '<system-reminder>';
const REMINDER_CLOSE = '</system-reminder>';
const COMMAND_TAG = /<(command-message|command-name|command-args)>([\s\S]*?)<\/\1>/g;
const VERSION_SHAPE = /^[0-9A-Za-z.+-]{1,64}$/;
const RECEIPT_NAME = new RegExp(`^${TOKEN}\\.json$`);
const TEMP_NAME = /^\.receipt-\d{1,10}-[0-9a-f]{12}\.tmp$/;

function literal(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

const ARGUMENTS = new RegExp(
  `^${literal(TAKEOVER_PREFIX.slice(COMMAND_NAME.length + 1))}${SESSION_ID}${literal(TAKEOVER_SUFFIX)}${literal(RECEIPT_FLAG)}(${TOKEN})$`,
);

function withoutReminders(text) {
  let rest = text;
  for (;;) {
    rest = rest.replace(/^\s+/, '');
    if (!rest.startsWith(REMINDER_OPEN)) return rest;
    const end = rest.indexOf(REMINDER_CLOSE);
    if (end < 0) return rest;
    rest = rest.slice(end + REMINDER_CLOSE.length);
  }
}

function tokenOfArguments(text) {
  const match = ARGUMENTS.exec(text);
  return match ? match[1] : null;
}

function tokenOfTags(body) {
  const tags = new Map();
  for (const [, name, value] of body.matchAll(COMMAND_TAG)) {
    if (tags.has(name)) return null;
    tags.set(name, value);
  }
  if (body.replace(COMMAND_TAG, '').trim() !== '') return null;
  if (tags.get('command-name') !== COMMAND_NAME || !tags.has('command-args')) return null;
  return tokenOfArguments(tags.get('command-args').trim());
}

export function receiptToken(prompt) {
  if (typeof prompt !== 'string' || prompt.length > MAX_PAYLOAD_CHARS) return null;
  const body = withoutReminders(prompt).trim();
  if (body.startsWith(TAKEOVER_PREFIX)) return tokenOfArguments(body.slice(COMMAND_NAME.length + 1));
  if (body.startsWith('<command-')) return tokenOfTags(body);
  return null;
}

export function receiptFor(payload, plugin, now) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return null;
  if (payload.hook_event_name !== 'UserPromptSubmit') return null;
  const token = receiptToken(payload.prompt);
  if (!token) return null;
  return {
    schemaVersion: RECEIPT_SCHEMA_VERSION,
    kind: RECEIPT_KIND,
    token,
    event: payload.hook_event_name,
    plugin: typeof plugin === 'string' && VERSION_SHAPE.test(plugin) ? plugin : null,
    recordedAt: new Date(now).toISOString(),
  };
}

export function configRoot(env = process.env, home = os.homedir()) {
  const configured = typeof env.CLAUDE_CONFIG_DIR === 'string' ? env.CLAUDE_CONFIG_DIR.trim() : '';
  return configured ? path.resolve(configured) : path.join(home, '.claude');
}

export function receiptsDir(root) {
  return path.join(root, ...RECEIPT_DIRECTORY.split('/'));
}

export function landReceipt(root, receipt) {
  const dir = receiptsDir(root);
  ensureLedgerDir(dir, root);
  const file = path.join(dir, `${receipt.token}.json`);
  const tmp = path.join(dir, `.receipt-${process.pid}-${crypto.randomBytes(6).toString('hex')}.tmp`);
  fs.writeFileSync(tmp, `${JSON.stringify(receipt)}\n`, { flag: 'wx', mode: 0o600 });
  try {
    fs.linkSync(tmp, file);
    return true;
  } catch (error) {
    if (error && error.code === 'EEXIST') return false;
    throw error;
  } finally {
    try { fs.unlinkSync(tmp); } catch {}
  }
}

export function pruneReceipts(root, now, limit = RECEIPT_SCAN_LIMIT, retention = RECEIPT_RETENTION_MS) {
  const dir = receiptsDir(root);
  if (!ledgerPathUnlinked(dir, root)) return 0;
  let handle;
  try { handle = fs.opendirSync(dir); } catch { return 0; }
  let seen = 0;
  let removed = 0;
  try {
    for (let entry = handle.readSync(); entry !== null && seen < limit; entry = handle.readSync()) {
      seen += 1;
      if (!RECEIPT_NAME.test(entry.name) && !TEMP_NAME.test(entry.name)) continue;
      const file = path.join(dir, entry.name);
      try {
        const stat = fs.lstatSync(file);
        if (!stat.isFile() || now - stat.mtimeMs <= retention) continue;
        fs.unlinkSync(file);
        removed += 1;
      } catch {}
    }
  } finally {
    try { handle.closeSync(); } catch {}
  }
  return removed;
}

export function pluginRoot() {
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
}

export function skillPresent(root) {
  return ['skills/session-trail/SKILL.md', 'skills/session-trail/scripts/trail.mjs']
    .every((relative) => {
      try { return fs.statSync(path.join(root, relative)).isFile(); } catch { return false; }
    });
}

export function pluginVersion(root) {
  try {
    const file = path.join(root, '.claude-plugin', 'plugin.json');
    if (fs.statSync(file).size > MAX_MANIFEST_BYTES) return null;
    const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
    return manifest && typeof manifest.version === 'string' ? manifest.version : null;
  } catch {
    return null;
  }
}

export function record(text, env = process.env, now = Date.now(), root = pluginRoot()) {
  if (typeof text !== 'string' || text.length > MAX_PAYLOAD_CHARS) return null;
  let payload;
  try { payload = JSON.parse(text); } catch { return null; }
  if (!skillPresent(root)) return null;
  const receipt = receiptFor(payload, pluginVersion(root), now);
  if (!receipt) return null;
  const config = configRoot(env);
  const landed = landReceipt(config, receipt);
  pruneReceipts(config, now);
  return landed ? receipt : null;
}

function isEntryPoint() {
  const invoked = process.argv[1];
  if (typeof invoked !== 'string' || invoked === '') return false;
  const real = (file) => { try { return fs.realpathSync.native(file); } catch { return path.resolve(file); } };
  return real(invoked) === real(fileURLToPath(import.meta.url));
}

if (isEntryPoint()) {
  try { record(fs.readFileSync(0, 'utf8')); } catch {}
  process.exitCode = 0;
}
