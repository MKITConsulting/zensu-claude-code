#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');

const [portFile, handoffFile, acknowledgementFile, token] = process.argv.slice(2);
if (![portFile, handoffFile, acknowledgementFile].every((value) => value && path.isAbsolute(value))
    || !/^[a-f0-9]{32}$/.test(token || '')) {
  process.stderr.write('verify-feature port reservation: invalid parent contract\n');
  process.exit(2);
}

let targetPort;
const server = net.createServer((client) => {
  if (!targetPort) { client.destroy(); return; }
  const upstream = net.createConnection({ host: '127.0.0.1', port: targetPort });
  upstream.on('error', () => client.destroy());
  client.on('error', () => upstream.destroy());
  client.pipe(upstream);
  upstream.pipe(client);
});
let handedOff = false;
const timer = setInterval(() => {
  if (handedOff || !fs.existsSync(handoffFile)) return;
  let observed;
  try {
    const info = fs.lstatSync(handoffFile);
    if (!info.isFile() || info.isSymbolicLink()) return;
    observed = JSON.parse(fs.readFileSync(handoffFile, 'utf8'));
  }
  catch (_error) { return; }
  if (!observed || JSON.stringify(Object.keys(observed).sort()) !== JSON.stringify(['targetPort', 'token'])
      || observed.token !== token || !Number.isInteger(observed.targetPort)
      || observed.targetPort < 1024 || observed.targetPort > 65535) return;
  targetPort = observed.targetPort;
  handedOff = true;
  fs.writeFileSync(acknowledgementFile, `${JSON.stringify({ version: 1, targetPort })}\n`, { mode: 0o600, flag: 'wx' });
  clearInterval(timer);
}, 25);

server.listen(0, '127.0.0.1', () => {
  const address = server.address();
  fs.writeFileSync(portFile, `${address.port}\n`, { mode: 0o600, flag: 'wx' });
});

const shutdown = () => {
  clearInterval(timer);
  server.close(() => process.exit(0));
  if (typeof server.closeAllConnections === 'function') server.closeAllConnections();
  setTimeout(() => process.exit(0), 1000).unref();
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
