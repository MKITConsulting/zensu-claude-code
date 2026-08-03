#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { selectExplicitCredential } = require('../lib/upgrade-credentials.js');

test('prefers one API key when both supported credentials are configured', () => {
  assert.deepEqual(selectExplicitCredential({
    ANTHROPIC_API_KEY: 'api-value',
    CLAUDE_CODE_OAUTH_TOKEN: 'oauth-value',
  }), {
    name: 'ANTHROPIC_API_KEY',
    value: 'api-value',
  });
});

test('uses the OAuth token only when an API key is absent', () => {
  assert.deepEqual(selectExplicitCredential({
    CLAUDE_CODE_OAUTH_TOKEN: 'oauth-value',
  }), {
    name: 'CLAUDE_CODE_OAUTH_TOKEN',
    value: 'oauth-value',
  });
});

test('returns no credential when neither supported value is configured', () => {
  assert.equal(selectExplicitCredential({}), null);
});

test('rejects non-string or control-character credential values', () => {
  assert.throws(
    () => selectExplicitCredential({ ANTHROPIC_API_KEY: 'bad\nvalue' }),
    /credential value is invalid/,
  );
  assert.throws(
    () => selectExplicitCredential({ CLAUDE_CODE_OAUTH_TOKEN: 123 }),
    /credential value is invalid/,
  );
});
