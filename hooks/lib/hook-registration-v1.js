'use strict';

const REGISTRATION = Object.freeze({ REGISTERED: 'registered', UNREGISTERED: 'unregistered', UNKNOWN: 'unknown' });
const READINGS = Object.freeze({ HOST: 'host', REGEX: 'regex' });

function hostMatcherCovers(matcher, tool) {
  if (matcher === undefined || matcher === '' || matcher === '*') return REGISTRATION.REGISTERED;
  if (typeof matcher !== 'string') return REGISTRATION.UNKNOWN;
  const answers = new Set();
  if (/^[A-Za-z0-9_|]+$/.test(matcher)) {
    answers.add(matcher.split('|').includes(tool));
  } else {
    if (/^[A-Za-z0-9_|, -]+$/.test(matcher)) answers.add(matcher.split(/[|,]/).map((name) => name.trim()).includes(tool));
    try {
      answers.add(new RegExp(matcher).test(tool));
      answers.add(new RegExp(`^(?:${matcher})$`).test(tool));
    } catch (_error) {
      return REGISTRATION.UNKNOWN;
    }
  }
  if (answers.size !== 1) return REGISTRATION.UNKNOWN;
  return answers.has(true) ? REGISTRATION.REGISTERED : REGISTRATION.UNREGISTERED;
}

function hostCovers(matcher, tools) {
  const answers = tools.map((tool) => hostMatcherCovers(matcher, tool));
  if (answers.includes(REGISTRATION.UNKNOWN)) return REGISTRATION.UNKNOWN;
  return answers.every((answer) => answer === REGISTRATION.REGISTERED) ? REGISTRATION.REGISTERED : REGISTRATION.UNREGISTERED;
}

function regexCovers(matcher, tools) {
  let pattern;
  try { pattern = new RegExp(typeof matcher === 'string' && matcher ? matcher : '.*'); }
  catch (_error) { return REGISTRATION.UNREGISTERED; }
  return tools.every((tool) => pattern.test(tool)) ? REGISTRATION.REGISTERED : REGISTRATION.UNREGISTERED;
}

function eventGroups(manifest, event, reading) {
  if (reading === READINGS.HOST) {
    if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) return null;
    if (manifest.hooks === undefined) return [];
    if (!manifest.hooks || typeof manifest.hooks !== 'object' || Array.isArray(manifest.hooks)) return null;
    const groups = manifest.hooks[event] === undefined ? [] : manifest.hooks[event];
    return Array.isArray(groups) ? groups : null;
  }
  if (!manifest || typeof manifest !== 'object') return null;
  const groups = (manifest.hooks && manifest.hooks[event]) || [];
  return Array.isArray(groups) ? groups : null;
}

function registration(manifest, options) {
  const groups = eventGroups(manifest, options.event, options.reading);
  if (groups === null) return REGISTRATION.UNKNOWN;
  let undecided = false;
  for (const group of groups) {
    if (!group || !Array.isArray(group.hooks)) continue;
    if (!group.hooks.some((hook) => hook && typeof hook.command === 'string' && options.names(hook.command))) continue;
    const covers = options.reading === READINGS.HOST
      ? hostCovers(group.matcher, options.tools)
      : regexCovers(group.matcher, options.tools);
    if (covers === REGISTRATION.REGISTERED) return REGISTRATION.REGISTERED;
    if (covers === REGISTRATION.UNKNOWN) undecided = true;
  }
  return undecided ? REGISTRATION.UNKNOWN : REGISTRATION.UNREGISTERED;
}

module.exports = {
  READINGS,
  REGISTRATION,
  hostMatcherCovers,
  registration,
};
