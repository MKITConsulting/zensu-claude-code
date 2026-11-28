import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import childProcess from 'node:child_process';

export const CONTRACT = 1;
export const PROTOCOL = 1;
export const POINTER_SCHEMA = 1;
export const POINTER = 'zensu/session-hub/v1/hub.json';
export const MAX_LINE_BYTES = 256 * 1024;
export const MAX_POINTER_BYTES = 64 * 1024;
export const MAX_SOCKET_BYTES = 103;
export const COURIER_EXECUTABLE = 'zensu-session-hub-courier';
export const COURIER_IDENTIFIER = 'dev.zensu.session-hub.courier';
export const TEAM = '3P6C5C4S5B';
export const COURIER_REQUIREMENT = `anchor apple generic and certificate leaf[subject.OU] = "${TEAM}" and identifier "${COURIER_IDENTIFIER}"`;
export const CODESIGN = '/usr/bin/codesign';
export const OPTION = 'allow_unsigned_courier';
export const OPTION_ENV = `CLAUDE_PLUGIN_OPTION_${OPTION.toUpperCase()}`;
export const DEFAULT_WAIT_SECONDS = 10;
export const MAX_WAIT_SECONDS = 3600;
export const VERIFY_TIMEOUT_MS = 10_000;
export const START_GRACE_MS = 5_000;

const EXITS = new Map([
  [64, 'usage'],
  [69, 'no-hub'],
  [74, 'transport'],
  [77, 'unverified'],
]);

function absolute(value) {
  return typeof value === 'string' && value.length > 0 && !value.includes('\0') && path.isAbsolute(value);
}

function plainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

export function configRoot(env = process.env, home = os.homedir()) {
  const configured = typeof env.CLAUDE_CONFIG_DIR === 'string' ? env.CLAUDE_CONFIG_DIR.trim() : '';
  if (configured) return path.isAbsolute(configured) ? path.resolve(configured) : null;
  return absolute(home) ? path.join(home, '.claude') : null;
}

export function pointerPath(root) {
  return absolute(root) ? path.join(root, ...POINTER.split('/')) : null;
}

export function unsignedAllowed(value) {
  return value === true || value === 'true';
}

export function pointerOf(value) {
  if (!plainObject(value)) return null;
  if (value.schemaVersion !== POINTER_SCHEMA || value.protocol !== PROTOCOL) return null;
  if (!absolute(value.socket) || Buffer.byteLength(value.socket, 'utf8') > MAX_SOCKET_BYTES) return null;
  if (!absolute(value.courier)) return null;
  return { socket: value.socket, courier: value.courier };
}

export function readPointer(file, uid = typeof process.getuid === 'function' ? process.getuid() : undefined) {
  if (!absolute(file)) return null;
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | (fs.constants.O_NONBLOCK || 0));
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.size > MAX_POINTER_BYTES) return null;
    if (uid !== undefined && stat.uid !== uid) return null;
    const buffer = Buffer.alloc(MAX_POINTER_BYTES + 1);
    let length = 0;
    while (length < buffer.length) {
      const read = fs.readSync(fd, buffer, length, buffer.length - length, null);
      if (read === 0) break;
      length += read;
    }
    if (length > MAX_POINTER_BYTES) return null;
    return pointerOf(JSON.parse(buffer.subarray(0, length).toString('utf8')));
  } catch {
    return null;
  } finally {
    if (fd !== undefined) {
      try { fs.closeSync(fd); } catch {}
    }
  }
}

export function requestLine(request) {
  if (!plainObject(request)) return null;
  if (Object.hasOwn(request, 'v') && request.v !== PROTOCOL) return null;
  let text;
  try {
    text = JSON.stringify({ v: PROTOCOL, ...request });
  } catch {
    return null;
  }
  if (typeof text !== 'string') return null;
  const line = `${text}\n`;
  return Buffer.byteLength(line, 'utf8') <= MAX_LINE_BYTES ? line : null;
}

export function replyOf(output) {
  if (typeof output !== 'string' || !output.endsWith('\n')) return null;
  if (Buffer.byteLength(output, 'utf8') > MAX_LINE_BYTES) return null;
  const body = output.slice(0, -1);
  if (body.includes('\n')) return null;
  let value;
  try {
    value = JSON.parse(body);
  } catch {
    return null;
  }
  return plainObject(value) && value.v === PROTOCOL ? value : null;
}

export function codesignArguments(courier) {
  return ['--verify', '--strict', `-R=${COURIER_REQUIREMENT}`, courier];
}

export function verifyCourier(courier, execFile = childProcess.execFile) {
  return new Promise((resolve) => {
    if (!absolute(courier)) {
      resolve(false);
      return;
    }
    try {
      execFile(CODESIGN, codesignArguments(courier), { timeout: VERIFY_TIMEOUT_MS, env: {}, windowsHide: true }, (error) => resolve(!error));
    } catch {
      resolve(false);
    }
  });
}

export async function courierTrust(courier, { allowUnsigned = false, verify = verifyCourier } = {}) {
  if (!absolute(courier)) return null;
  let signed = false;
  try {
    signed = (await verify(courier)) === true;
  } catch {
    signed = false;
  }
  if (signed) return 'signed';
  return unsignedAllowed(allowUnsigned) && path.basename(courier) === COURIER_EXECUTABLE ? 'unsigned' : null;
}

function exchange(spawn, pointer, line, wait, grace) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(pointer.courier, ['--socket', pointer.socket, '--wait', String(wait)], {
        stdio: ['pipe', 'pipe', 'ignore'],
        env: {},
        windowsHide: true,
      });
    } catch {
      resolve({ ok: false, reason: 'spawn' });
      return;
    }
    const chunks = [];
    let size = 0;
    let tooLong = false;
    let settled = false;
    let timer;
    const finish = (outcome) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(outcome);
    };
    const stop = () => {
      try { child.kill('SIGKILL'); } catch {}
    };
    timer = setTimeout(() => {
      stop();
      finish({ ok: false, reason: 'timeout' });
    }, wait * 1000 + grace);
    child.on('error', () => finish({ ok: false, reason: 'spawn' }));
    child.stdout.on('data', (chunk) => {
      if (tooLong) return;
      size += chunk.length;
      if (size > MAX_LINE_BYTES) {
        tooLong = true;
        stop();
        return;
      }
      chunks.push(chunk);
    });
    child.on('close', (code) => {
      if (tooLong) {
        finish({ ok: false, reason: 'reply' });
        return;
      }
      if (code !== 0) {
        finish({ ok: false, reason: EXITS.get(code) || 'exit' });
        return;
      }
      const reply = replyOf(Buffer.concat(chunks).toString('utf8'));
      finish(reply ? { ok: true, reply } : { ok: false, reason: 'reply' });
    });
    child.stdin.on('error', () => {});
    child.stdin.end(line);
  });
}

export async function relay(request, settings = {}) {
  const {
    root = configRoot(),
    allowUnsigned = false,
    wait = DEFAULT_WAIT_SECONDS,
    grace = START_GRACE_MS,
    verify = verifyCourier,
    spawn = childProcess.spawn,
  } = settings;
  const line = requestLine(request);
  if (line === null || !Number.isInteger(wait) || wait < 1 || wait > MAX_WAIT_SECONDS) {
    return { ok: false, reason: 'request' };
  }
  const pointer = readPointer(pointerPath(root));
  if (!pointer) return { ok: false, reason: 'no-pointer' };
  const trust = await courierTrust(pointer.courier, { allowUnsigned, verify });
  if (!trust) return { ok: false, reason: 'untrusted' };
  const outcome = await exchange(spawn, pointer, line, wait, Number.isInteger(grace) && grace >= 0 ? grace : START_GRACE_MS);
  return outcome.ok ? { ok: true, reply: outcome.reply, trust } : outcome;
}
