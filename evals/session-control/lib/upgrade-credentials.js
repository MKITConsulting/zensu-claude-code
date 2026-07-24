#!/usr/bin/env node
'use strict';

function credentialError() {
  const error = new Error('upgrade credential value is invalid');
  error.name = 'UpgradeCredentialError';
  return error;
}

function readCredential(environment, name) {
  const value = environment?.[name];
  if (value === undefined || value === '') return null;
  if (typeof value !== 'string' || /[\0\r\n]/.test(value)) throw credentialError();
  return value;
}

function selectExplicitCredential(environment) {
  const apiKey = readCredential(environment, 'ANTHROPIC_API_KEY');
  const oauthToken = readCredential(environment, 'CLAUDE_CODE_OAUTH_TOKEN');
  if (apiKey !== null) return { name: 'ANTHROPIC_API_KEY', value: apiKey };
  if (oauthToken !== null) return { name: 'CLAUDE_CODE_OAUTH_TOKEN', value: oauthToken };
  return null;
}

module.exports = {
  selectExplicitCredential,
};
