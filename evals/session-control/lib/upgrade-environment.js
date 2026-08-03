#!/usr/bin/env node
'use strict';

const CLAUDE_CREDENTIAL_NAMES = Object.freeze([
  'ANTHROPIC_API_KEY',
  'CLAUDE_CODE_OAUTH_TOKEN',
]);

const HELPER_ENVIRONMENT_NAMES = Object.freeze([
  'PATH',
  'HOME',
  'TMPDIR',
  'TEMP',
  'TMP',
  'LANG',
  'LC_ALL',
  'SYSTEMROOT',
  'WINDIR',
  'COMSPEC',
  'PATHEXT',
  'NODE_V8_COVERAGE',
]);

function credentialFreeEnvironment(source = process.env, overrides = {}) {
  const environment = {};
  for (const name of HELPER_ENVIRONMENT_NAMES) {
    if (typeof source[name] === 'string' && source[name]) {
      environment[name] = source[name];
    }
  }
  for (const [name, value] of Object.entries(overrides)) {
    if (typeof value === 'string') environment[name] = value;
  }
  for (const name of CLAUDE_CREDENTIAL_NAMES) delete environment[name];
  return environment;
}

function withoutClaudeCredentials(source) {
  const environment = { ...source };
  for (const name of CLAUDE_CREDENTIAL_NAMES) delete environment[name];
  return environment;
}

module.exports = {
  CLAUDE_CREDENTIAL_NAMES,
  credentialFreeEnvironment,
  withoutClaudeCredentials,
};
