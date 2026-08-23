#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { digest } = require('./fixture-manifest.js');

const RUN_OWNED = Object.freeze([
  '.verify-runtime',
  '.verify-feature-runtime',
  '.zensu/hook-events.log',
  '.zensu/logs',
  '.zensu/state',
  '.zensu/verify-feature-runs',
]);
const MAX_WATCHERS = 128;

function runOwned(relativePath) {
  return RUN_OWNED.some((entry) => relativePath === entry || relativePath.startsWith(`${entry}/`));
}

function ownsDescendant(relativePath) {
  return RUN_OWNED.some((entry) => entry.startsWith(`${relativePath}/`));
}

function classifyFixtureEvent(relativePath, rootName) {
  if (relativePath === '' || relativePath === '.') return 'root-self';
  if (runOwned(relativePath)) return 'ignore';
  if (relativePath === '.git' || relativePath.startsWith('.git/')) return 'git-gated';
  if (rootName && relativePath === rootName) return 'root-named';
  if (ownsDescendant(relativePath)) return 'ancestor-gated';
  return 'mutation';
}

function main() {
  const startedAt = Date.now();
  const [rootInput, marker, ready, option] = process.argv.slice(2);
  if (!rootInput || !marker || !ready) throw new Error('usage: fixture-mutation-watch.js <root> <marker> <ready>');
  if (option && !['--force-fallback', '--test-polling'].includes(option)) {
    throw new Error('unknown fixture watcher option');
  }
  const root = fs.realpathSync(rootInput);
  const rootName = path.basename(root);
  const baseline = digest(root);
  const watchers = new Map();
  let stopping = false;
  let polling = false;
  let pollTimer;

  const mark = (relativePath) => {
    if (stopping || runOwned(relativePath)) return;
    try { fs.writeFileSync(marker, `${relativePath}\n`, { mode: 0o600, flag: 'wx' }); }
    catch (error) { if (error.code !== 'EEXIST') throw error; }
  };

  const gateOnManifest = (relativePath) => {
    try { if (digest(root) !== baseline) mark(relativePath); }
    catch (_error) { mark('manifest-unreadable'); }
  };

  const markIfTouchedSinceStart = (relativePath) => {
    let info;
    try { info = fs.lstatSync(path.join(root, relativePath)); }
    catch (_error) { mark(relativePath); return true; }
    if (info.ctimeMs < startedAt && info.mtimeMs < startedAt) return false;
    mark(relativePath);
    return true;
  };

  const handleEvent = (relativePath) => {
    switch (classifyFixtureEvent(relativePath, rootName)) {
      case 'ignore':
        return false;
      case 'root-self':
        gateOnManifest('.');
        return false;
      case 'root-named':
        if (!fs.existsSync(path.join(root, relativePath))) { gateOnManifest(relativePath); return false; }
        return markIfTouchedSinceStart(relativePath);
      case 'git-gated':
      case 'ancestor-gated':
        gateOnManifest(relativePath);
        return false;
      default:
        return markIfTouchedSinceStart(relativePath);
    }
  };

  const watchDirectory = (absoluteDirectory) => {
    if (watchers.has(absoluteDirectory)) return;
    if (watchers.size >= MAX_WATCHERS) throw new Error(`fixture watcher limit exceeded (${MAX_WATCHERS})`);
    const relativeDirectory = path.relative(root, absoluteDirectory).split(path.sep).join('/');
    if (runOwned(relativeDirectory)) return;
    let watcher;
    try {
      watcher = fs.watch(absoluteDirectory, (eventType, filename) => {
        if (!filename) { mark('unknown-watch-event'); return; }
        const relativePath = path.posix.join(relativeDirectory, String(filename));
        if (!handleEvent(relativePath)) return;
        if (eventType === 'rename') {
          const candidate = path.join(absoluteDirectory, String(filename));
          try { if (fs.lstatSync(candidate).isDirectory()) watchTree(candidate); }
          catch (_error) {}
        }
      });
    } catch (error) {
      mark(relativeDirectory || '.');
      throw error;
    }
    watcher.on('error', (error) => {
      mark('watch-error');
      process.stderr.write(`fixture mutation watch: ${error.message}\n`);
      stop(2);
    });
    watchers.set(absoluteDirectory, watcher);
  };

  const watchTree = (absoluteDirectory) => {
    watchDirectory(absoluteDirectory);
    for (const entry of fs.readdirSync(absoluteDirectory, { withFileTypes: true })) {
      if (!entry.isDirectory() || entry.isSymbolicLink()) continue;
      const child = path.join(absoluteDirectory, entry.name);
      const relativePath = path.relative(root, child).split(path.sep).join('/');
      if (!runOwned(relativePath)) watchTree(child);
    }
  };

  const watchRecursive = () => {
    if (option === '--force-fallback') return false;
    let watcher;
    try {
      watcher = fs.watch(root, { recursive: true }, (_eventType, filename) => {
        if (!filename) { mark('unknown-watch-event'); return; }
        handleEvent(String(filename).split(path.sep).join('/'));
      });
    } catch (error) {
      if (['ERR_FEATURE_UNAVAILABLE_ON_PLATFORM', 'ERR_INVALID_ARG_VALUE'].includes(error.code)) return false;
      throw error;
    }
    watcher.on('error', (error) => {
      mark('watch-error');
      process.stderr.write(`fixture mutation watch: ${error.message}\n`);
      stop(2);
    });
    watchers.set(root, watcher);
    return true;
  };

  const stop = (code = 0) => {
    stopping = true;
    if (pollTimer) clearInterval(pollTimer);
    for (const watcher of watchers.values()) watcher.close();
    try { fs.unlinkSync(ready); } catch (_error) {}
    process.exit(code);
  };
  process.on('SIGINT', () => stop(0));
  process.on('SIGTERM', () => stop(0));
  process.on('SIGHUP', () => stop(0));

  // The wrapper's explicit test mode exercises manifest attestation in managed
  // runners where the host may forbid every fs.watch backend. Production never
  // selects this polling-only path: it remains fail-closed when an event watcher
  // cannot be established.
  if (option !== '--test-polling' && !watchRecursive()) watchTree(root);
  pollTimer = setInterval(() => {
    if (stopping || polling) return;
    polling = true;
    try { if (digest(root) !== baseline) mark('manifest-change'); }
    catch (_error) { mark('manifest-unreadable'); }
    finally { polling = false; }
  }, 10);
  fs.writeFileSync(ready, 'ready\n', { mode: 0o600, flag: 'wx' });
}

module.exports = { RUN_OWNED, classifyFixtureEvent, runOwned };

if (require.main === module) {
  try { main(); }
  catch (error) {
    process.stderr.write(`fixture mutation watch: ${error.message}\n`);
    process.exit(1);
  }
}
