'use strict';

const fs = require('node:fs');

const marker = process.env.ZENSU_TEST_LEASE_ACQUIRE_MARKER;
const corePath = process.argv[1];

if (
  typeof marker === 'string'
  && marker !== ''
  && typeof corePath === 'string'
  && corePath.endsWith('session-control-core-v1.js')
  && process.execArgv.some((value) => value.includes('acquireExternalProcessLock'))
) {
  const core = require(corePath);
  const acquire = core.acquireExternalProcessLock;
  core.acquireExternalProcessLock = function acquireWithEntryMarker(options) {
    fs.writeFileSync(marker, `${process.pid}\n`, { flag: 'a' });
    return acquire.call(this, options);
  };
}
