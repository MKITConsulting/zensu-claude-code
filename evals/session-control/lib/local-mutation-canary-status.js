#!/usr/bin/env node
'use strict';

const LISTENER_FORBIDDEN_EXIT_CODE = 77;
const LISTENER_FORBIDDEN_MARKER = 'local mutation canary: loopback-listener-forbidden EPERM listen 127.0.0.1';

function isLoopbackListenerForbiddenError(error) {
  return Boolean(error)
    && error.code === 'EPERM'
    && error.syscall === 'listen'
    && error.address === '127.0.0.1';
}

function isLoopbackListenerForbiddenProcessFailure({ exitCode, stderr } = {}) {
  return exitCode === LISTENER_FORBIDDEN_EXIT_CODE
    && String(stderr || '').trim() === LISTENER_FORBIDDEN_MARKER;
}

module.exports = {
  LISTENER_FORBIDDEN_EXIT_CODE,
  LISTENER_FORBIDDEN_MARKER,
  isLoopbackListenerForbiddenError,
  isLoopbackListenerForbiddenProcessFailure,
};
