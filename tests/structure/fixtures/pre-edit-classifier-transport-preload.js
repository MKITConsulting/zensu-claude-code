'use strict';

const fs = require('node:fs');

if (process.env.ZENSU_TEST_PRE_EDIT_CLASSIFIER_PROBE === '1') {
  const has = (name) => Object.prototype.hasOwnProperty.call(process.env, name);
  if (['CONTROL_CORE', 'PROJECT_ROOT', 'STATE_FILE'].some(has)) {
    process.exit(96);
  }
  const hasFilePath = has('FP');
  const hasStateDir = has('SD');

  if (hasFilePath || hasStateDir) {
    if (!(hasFilePath && hasStateDir)) process.exit(89);

    const exclusions = new Set(
      (process.env.MSYS2_ENV_CONV_EXCL || '').split(';').filter(Boolean),
    );
    const required = [
      ['EXISTING_SELECTOR', 90],
      ['FP=', 91],
      ['SD=', 92],
    ];
    for (const [name, exitCode] of required) {
      if (!exclusions.has(name)) process.exit(exitCode);
    }

    const marker = process.env.ZENSU_TEST_PRE_EDIT_CLASSIFIER_MARKER;
    if (!marker) process.exit(93);
    fs.writeFileSync(marker, process.env.MSYS2_ENV_CONV_EXCL || '', 'utf8');
  }
}
