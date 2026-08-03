#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  CLAUDE_CREDENTIAL_NAMES,
  credentialFreeEnvironment,
  withoutClaudeCredentials,
} = require('../lib/upgrade-environment.js');

test('helper environments forward only operational metadata and never Claude credentials', () => {
  const environment = credentialFreeEnvironment({
    PATH: '/bin',
    HOME: '/home/test',
    TMPDIR: '/tmp/test',
    NODE_V8_COVERAGE: '/tmp/coverage',
    ANTHROPIC_API_KEY: 'api-secret',
    CLAUDE_CODE_OAUTH_TOKEN: 'oauth-secret',
    UNRELATED_SECRET: 'must-not-forward',
  }, {
    LANG: 'C',
    ANTHROPIC_API_KEY: 'override-must-not-forward',
  });
  assert.deepEqual(environment, {
    PATH: '/bin',
    HOME: '/home/test',
    TMPDIR: '/tmp/test',
    NODE_V8_COVERAGE: '/tmp/coverage',
    LANG: 'C',
  });
});

test('Claude probe environments remove both supported credential forms', () => {
  const source = {
    PATH: '/bin',
    ANTHROPIC_API_KEY: 'api-secret',
    CLAUDE_CODE_OAUTH_TOKEN: 'oauth-secret',
  };
  assert.deepEqual(withoutClaudeCredentials(source), { PATH: '/bin' });
  assert.deepEqual(source, {
    PATH: '/bin',
    ANTHROPIC_API_KEY: 'api-secret',
    CLAUDE_CODE_OAUTH_TOKEN: 'oauth-secret',
  });
  assert.deepEqual(
    [...CLAUDE_CREDENTIAL_NAMES],
    ['ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN'],
  );
});
