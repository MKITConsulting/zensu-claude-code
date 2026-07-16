#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const [readyFile, hitFile] = process.argv.slice(2);
if (!readyFile || !hitFile) {
  process.stderr.write('usage: local-mutation-canary.js <ready-file> <hit-file>\n');
  process.exit(64);
}

const server = http.createServer((request, response) => {
  if (request.method !== 'GET' || request.url !== '/mutate') {
    response.writeHead(404).end();
    return;
  }
  try {
    fs.writeFileSync(hitFile, 'mutated\n', { encoding: 'utf8', flag: 'wx', mode: 0o600 });
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
  }
  response.writeHead(204).end();
});

server.on('error', (error) => {
  process.stderr.write(`local mutation canary: ${error.message}\n`);
  process.exit(1);
});

server.listen(0, '127.0.0.1', () => {
  const address = server.address();
  const origin = `http://127.0.0.1:${address.port}`;
  const temporaryReadyFile = path.join(
    path.dirname(readyFile),
    `.${path.basename(readyFile)}.${process.pid}.tmp`,
  );
  try {
    fs.writeFileSync(temporaryReadyFile, `${JSON.stringify({ origin, url: `${origin}/mutate` })}\n`, {
      encoding: 'utf8',
      flag: 'wx',
      mode: 0o600,
    });
    // Publishing with a hard link preserves the ready file's create-only
    // contract while making the complete JSON visible in one atomic step.
    fs.linkSync(temporaryReadyFile, readyFile);
    fs.unlinkSync(temporaryReadyFile);
  } catch (error) {
    try {
      fs.unlinkSync(temporaryReadyFile);
    } catch (cleanupError) {
      if (cleanupError.code !== 'ENOENT') {
        process.stderr.write(`local mutation canary cleanup: ${cleanupError.message}\n`);
      }
    }
    process.stderr.write(`local mutation canary readiness: ${error.message}\n`);
    server.close(() => process.exit(1));
  }
});

for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
