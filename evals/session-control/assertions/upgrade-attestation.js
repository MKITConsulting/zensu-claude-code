'use strict';

const { parse } = require('../lib/upgrade-attestation.js');

module.exports = (output, context = {}) => {
  const vars = context.vars || context.test?.vars || {};
  try {
    const attestation = parse(output);
    const expectedRevision = String(
      vars.expected_source_revision || process.env.ZENSU_EXPECTED_SOURCE_REVISION || '',
    );
    if (!expectedRevision || attestation.source_git_revision !== expectedRevision) {
      return { pass: false, score: 0, reason: 'candidate source revision does not match the requested checkout' };
    }
    return {
      pass: true,
      score: 1,
      reason: 'side-by-side Claude upgrade lifecycle satisfies the contract',
    };
  } catch (error) {
    return { pass: false, score: 0, reason: error.message };
  }
};
