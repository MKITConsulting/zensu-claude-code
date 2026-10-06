'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const logFile = process.env.ZENSU_TEST_OWNER_OBSERVER_LOG;
const methods = [
  'inspectDeferredReviewOwner',
  'retireDeferredReviewOwner',
  'deferredReviewOwnedByOther',
];

function imageName(pid) {
  try {
    if (process.platform === 'win32') {
      const row = execFileSync('tasklist', ['/FI', `PID eq ${pid}`, '/FO', 'CSV', '/NH'], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
        timeout: 5000,
        windowsHide: true,
      }).trim();
      const match = /^"([^"]+)"/.exec(row);
      return match ? match[1] : 'unknown';
    }
    const name = execFileSync('/bin/ps', ['-p', String(pid), '-o', 'comm='], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 5000,
    }).trim();
    return name ? path.basename(name) : 'unknown';
  } catch (_) {
    return 'unknown';
  }
}

if (
  typeof logFile === 'string'
  && logFile !== ''
  && typeof process.env.CONTROL_CORE === 'string'
  && process.env.CONTROL_CORE !== ''
  && process.execArgv.some((value) => methods.some((method) => value.includes(`core.${method}`)))
) {
  const core = require(path.resolve(process.env.CONTROL_CORE));
  const observe = (method, options) => {
    try {
      const claim = JSON.parse(fs.readFileSync(options.claimFile, 'utf8'));
      if (!Number.isSafeInteger(claim.ownerPid) || claim.ownerPid <= 0) return;
      let alive = false;
      try {
        process.kill(claim.ownerPid, 0);
        alive = true;
      } catch (error) {
        alive = error.code === 'EPERM';
      }
      const record = {
        method,
        pid: claim.ownerPid,
        alive,
        image: alive ? imageName(claim.ownerPid) : '',
        handoff: claim.handoffEmitted === true,
        stored: claim.ownerProcessStartIdentity || null,
        actual: alive ? core.processStartIdentityForPid(claim.ownerPid) : null,
      };
      fs.appendFileSync(logFile, `${JSON.stringify(record)}\n`);
    } catch (_observationError) {
      try {
        fs.appendFileSync(logFile, `${JSON.stringify({ method, error: 'unobservable' })}\n`);
      } catch (_writeError) {}
    }
  };
  for (const method of methods) {
    const original = core[method];
    core[method] = function observedOwnerDecision(options) {
      observe(method, options || {});
      return original.call(this, options);
    };
  }
}
