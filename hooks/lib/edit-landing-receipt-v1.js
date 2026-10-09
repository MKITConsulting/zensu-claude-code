'use strict';

const fs = require('node:fs');
const path = require('node:path');

const RECEIPT_SCHEMAS = Object.freeze({ 'edit-landing-v1': 1, 'edit-landing-v2': 2 });
const MAX_RECEIPT_BYTES = 4 * 1024 * 1024;
const EXIT = Object.freeze({ ok: 0, usage: 2, none: 3 });

function readBoundedJson(filePath, maxBytes) {
  let descriptor;
  let before;
  try {
    before = fs.lstatSync(filePath);
    if (before.isSymbolicLink()) return { invalid: 'unreadable (symlink)' };
    const noFollow = process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW) ? fs.constants.O_NOFOLLOW : 0;
    const flags = fs.constants.O_RDONLY | noFollow | (fs.constants.O_NONBLOCK || 0);
    descriptor = fs.openSync(filePath, flags);
  } catch (error) {
    if (error && error.code === 'ENOENT') return { absent: true };
    return { invalid: `unreadable (${(error && error.code) || 'error'})` };
  }
  try {
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile()) return { invalid: 'not a regular file' };
    if (stat.dev !== before.dev || stat.ino !== before.ino) return { invalid: 'unreadable (replaced)' };
    if (stat.size > maxBytes) return { invalid: 'oversized' };
    const buffer = Buffer.alloc(stat.size);
    let offset = 0;
    while (offset < stat.size) {
      const read = fs.readSync(descriptor, buffer, offset, stat.size - offset, offset);
      if (read <= 0) break;
      offset += read;
    }
    if (offset !== stat.size) return { invalid: 'short read' };
    return { value: JSON.parse(buffer.toString('utf8')) };
  } catch (error) {
    return { invalid: error && error.code ? `unreadable (${error.code})` : 'unparseable' };
  } finally {
    try { fs.closeSync(descriptor); } catch { }
  }
}

function canonical(target) {
  try {
    return fs.realpathSync(target);
  } catch {
    return path.resolve(target);
  }
}

function isOutside(relative) {
  return relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative);
}

function resolveRunLog(projectRoot, logValue) {
  if (typeof projectRoot !== 'string' || projectRoot === '') return { reason: 'no project root is bound' };
  if (typeof logValue !== 'string' || logValue === '') return { reason: 'no run log was named' };
  const root = canonical(path.resolve(projectRoot));
  const logsDirRaw = path.join(root, '.zensu', 'logs');
  try {
    if (fs.lstatSync(logsDirRaw).isSymbolicLink()) return { reason: 'the project .zensu/logs directory is a symlink' };
  } catch { }
  const logsDir = canonical(logsDirRaw);
  if (isOutside(path.relative(root, logsDir))) return { reason: 'the project .zensu/logs directory resolves outside the project root' };
  const raw = path.resolve(root, logValue);
  const resolved = path.join(canonical(path.dirname(raw)), path.basename(raw));
  const relative = path.relative(logsDir, resolved);
  if (relative === '' || isOutside(relative)) return { reason: 'the run log is not inside the project .zensu/logs directory' };
  if (!resolved.endsWith('.log')) return { reason: 'the run log does not end in .log' };
  return {
    root,
    logRel: path.relative(root, resolved).split(path.sep).join('/'),
    stem: path.basename(resolved, '.log'),
  };
}

function receiptRunLog(options) {
  const loaded = readBoundedJson(options.receiptPath, options.maxBytes || MAX_RECEIPT_BYTES);
  if (loaded.absent) return { status: 'absent' };
  if (loaded.invalid) return { status: 'invalid', reason: `the edit-landing receipt is ${loaded.invalid}` };
  const receipt = loaded.value;
  const version = receipt && typeof receipt === 'object' && Object.prototype.hasOwnProperty.call(RECEIPT_SCHEMAS, receipt.schema)
    ? RECEIPT_SCHEMAS[receipt.schema]
    : 0;
  if (!version || typeof receipt.log !== 'string' || receipt.log === '') {
    return { status: 'invalid', reason: 'the edit-landing receipt names no run log under a known schema' };
  }
  const resolved = resolveRunLog(options.projectRoot, receipt.log);
  if (resolved.reason) return { status: 'invalid', reason: resolved.reason };
  return { status: 'ok', root: resolved.root, logRel: resolved.logRel, stem: resolved.stem };
}

function main(argv, env = process.env, stdout = process.stdout, stderr = process.stderr) {
  if (argv[0] !== 'receipt-log') {
    stderr.write('usage: edit-landing-receipt-v1.js receipt-log\n');
    return EXIT.usage;
  }
  const receipt = receiptRunLog({ receiptPath: env.ZENSU_ELR_RECEIPT || '', projectRoot: env.ZENSU_ELR_PROJECT_ROOT || '' });
  if (receipt.status !== 'ok') return EXIT.none;
  stdout.write(receipt.logRel);
  return EXIT.ok;
}

module.exports = {
  RECEIPT_SCHEMAS,
  MAX_RECEIPT_BYTES,
  EXIT,
  readBoundedJson,
  canonical,
  isOutside,
  resolveRunLog,
  receiptRunLog,
  main,
};

if (require.main === module) {
  process.exitCode = main(process.argv.slice(2));
}
