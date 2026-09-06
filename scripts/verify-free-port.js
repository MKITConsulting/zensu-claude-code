#!/usr/bin/env node
'use strict';
const net = require('node:net');

const MIN_PORT = 1024;
const MAX_PORT = 65535;
const MAX_ATTEMPTS = 200;

function parseArgs(argv) {
  const options = { from: null, exclude: new Set() };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--from') {
      const value = Number(argv[index + 1]);
      if (!Number.isInteger(value) || value < MIN_PORT || value > MAX_PORT) throw new Error('--from needs a port between 1024 and 65535');
      options.from = value;
      index += 1;
    } else if (arg === '--exclude') {
      for (const item of String(argv[index + 1] || '').split(',')) {
        const value = Number(item);
        if (Number.isInteger(value)) options.exclude.add(value);
      }
      index += 1;
    } else {
      throw new Error('usage: verify-free-port.js [--from <port>] [--exclude <port,port>]');
    }
  }
  return options;
}

function probe(port) {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once('error', () => resolve(null));
    server.listen(port, '127.0.0.1', () => {
      const bound = server.address().port;
      server.close(() => resolve(bound));
    });
  });
}

async function freePort(options) {
  if (options.from === null) {
    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt += 1) {
      const port = await probe(0);
      if (port !== null && !options.exclude.has(port)) return port;
    }
    throw new Error('no free loopback port was found');
  }
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt += 1) {
    const candidate = options.from + attempt;
    if (candidate > MAX_PORT) break;
    if (options.exclude.has(candidate)) continue;
    const port = await probe(candidate);
    if (port === candidate) return port;
  }
  throw new Error(`no free loopback port was found in ${MAX_ATTEMPTS} ports from ${options.from}`);
}

module.exports = { freePort, parseArgs, probe, MAX_ATTEMPTS };

if (require.main === module) {
  (async () => {
    const options = parseArgs(process.argv.slice(2));
    const port = await freePort(options);
    process.stdout.write(`${port}\n`);
  })().catch((error) => {
    process.stderr.write(`zensu verify free port: ${error.message}\n`);
    process.exitCode = 1;
  });
}
