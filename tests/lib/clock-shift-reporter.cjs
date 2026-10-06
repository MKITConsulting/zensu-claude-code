'use strict';

const MAX_MESSAGE = 400;

function flagged(value) {
  return value !== undefined && value !== null && value !== false;
}

function messageOf(details) {
  const error = details && details.error;
  if (!error) return null;
  const source = error.cause && typeof error.cause.message === 'string' ? error.cause.message : error.message;
  if (typeof source !== 'string' || source === '') return null;
  const flat = source.replace(/\s+/g, ' ').trim();
  return flat.length > MAX_MESSAGE ? `${flat.slice(0, MAX_MESSAGE - 1)}…` : flat;
}

module.exports = async function* clockShiftReporter(source) {
  const nestedFailure = new Map();
  for await (const event of source) {
    if (event.type !== 'test:pass' && event.type !== 'test:fail') continue;
    const data = event.data || {};
    const file = typeof data.file === 'string' ? data.file : null;
    if (data.nesting !== 0) {
      if (event.type === 'test:fail' && !flagged(data.todo) && !nestedFailure.has(file)) {
        const message = messageOf(data.details);
        if (message !== null) nestedFailure.set(file, `${String(data.name)}: ${message}`);
      }
      continue;
    }
    let outcome;
    if (event.type === 'test:fail') outcome = flagged(data.todo) ? 'todo' : 'fail';
    else outcome = flagged(data.skip) ? 'skip' : (flagged(data.todo) ? 'todo' : 'pass');
    const error = data.details && data.details.error;
    const failureType = error && typeof error.failureType === 'string' ? error.failureType : null;
    let message = null;
    if (outcome === 'fail') {
      message = failureType === 'subtestsFailed' && nestedFailure.has(file) ? nestedFailure.get(file) : messageOf(data.details);
    }
    nestedFailure.delete(file);
    yield `${JSON.stringify({ outcome, file, name: String(data.name), failureType, message })}\n`;
  }
};
