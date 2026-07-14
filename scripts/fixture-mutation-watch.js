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

function main() {
  const [rootInput, marker, ready, option] = process.argv.slice(2);
  if (!rootInput || !marker || !ready) throw new Error('usage: fixture-mutation-watch.js <root> <marker> <ready>');
  if (option && option !== '--force-fallback') throw new Error('unknown fixture watcher option');
  const root = fs.realpathSync(rootInput);
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
        if (runOwned(relativePath)) return;
        if (relativePath === '.git' || relativePath.startsWith('.git/')) {
          try { if (digest(root) !== baseline) mark(relativePath); }
          catch (_error) { mark('manifest-unreadable'); }
          return;
        }
        mark(relativePath);
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
        const relativePath = String(filename).split(path.sep).join('/');
        if (!runOwned(relativePath)) mark(relativePath);
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

  if (!watchRecursive()) watchTree(root);
  pollTimer = setInterval(() => {
    if (stopping || polling) return;
    polling = true;
    try { if (digest(root) !== baseline) mark('manifest-change'); }
    catch (_error) { mark('manifest-unreadable'); }
    finally { polling = false; }
  }, 10);
  fs.writeFileSync(ready, 'ready\n', { mode: 0o600, flag: 'wx' });
}

try { main(); }
catch (error) {
  process.stderr.write(`fixture mutation watch: ${error.message}\n`);
  process.exit(1);
}
