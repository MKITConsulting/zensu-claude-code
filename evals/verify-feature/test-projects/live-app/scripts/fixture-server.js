#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const host = '127.0.0.1';
const publicDir = path.resolve(__dirname, '..', 'public');
const indexPath = path.join(publicDir, 'index.html');
const backendPortFile = process.env.ZENSU_FIXTURE_BACKEND_PORT_FILE;
const leaseFile = process.env.ZENSU_FIXTURE_LEASE_FILE;

if (!backendPortFile || !leaseFile) {
  process.stderr.write('fixture-server: backend-port and lease files are required\n');
  process.exit(2);
}

const inventory = {
  items: [
    { name: 'Alpha', quantity: 3 },
    { name: 'Beta', quantity: 7 },
  ],
};

function sendJson(response, status, payload) {
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  response.end(JSON.stringify(payload));
}

const server = http.createServer((request, response) => {
  const requestUrl = new URL(request.url || '/', `http://${host}`);

  if (request.method === 'GET' && requestUrl.pathname === '/health') {
    sendJson(response, 200, { status: 'ok' });
    return;
  }

  if (request.method === 'GET' && requestUrl.pathname === '/api/items') {
    sendJson(response, 200, inventory);
    return;
  }

  if (request.method === 'GET' && requestUrl.pathname === '/') {
    response.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store',
    });
    fs.createReadStream(indexPath).pipe(response);
    return;
  }

  sendJson(response, 404, { error: 'not found' });
});

let shuttingDown = false;
function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  clearInterval(leaseWatcher);
  server.close(() => process.exit(0));
  if (typeof server.closeAllConnections === 'function') server.closeAllConnections();
  setTimeout(() => process.exit(0), 1000).unref();
}

const leaseWatcher = setInterval(() => {
  if (!fs.existsSync(leaseFile)) shutdown();
}, 500);
leaseWatcher.unref();

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

server.listen(0, host, () => {
  const address = server.address();
  if (!address || typeof address === 'string') {
    process.stderr.write('fixture-server: failed to resolve listening address\n');
    process.exit(2);
  }

  const temporaryPortFile = `${backendPortFile}.${process.pid}.tmp`;
  fs.writeFileSync(temporaryPortFile, `${address.port}\n`, { mode: 0o600 });
  fs.renameSync(temporaryPortFile, backendPortFile);
  process.stdout.write(`fixture backend listening on ${host}:${address.port}\n`);
});
