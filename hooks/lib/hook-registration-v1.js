'use strict';

const REGISTRATION = Object.freeze({ REGISTERED: 'registered', UNREGISTERED: 'unregistered', UNKNOWN: 'unknown' });
const READINGS = Object.freeze({ HOST: 'host', REGEX: 'regex' });
const DISPATCHER_MODULE = 'hooks/lib/hook-dispatch-v1.js';
const DISPATCH_EVENTS = Object.freeze({ pre: 'PreToolUse', post: 'PostToolUse' });
const DISPATCHED_CHECKS = Object.freeze([
  Object.freeze({ event: 'PreToolUse', name: 'reviewer-capability', matcher: '.*', script: 'pre-reviewer-capability-gate.sh', body: null, failure: 'closed' }),
  Object.freeze({ event: 'PreToolUse', name: 'zensu-cli-gate', matcher: 'Bash|PowerShell', script: 'pre-bash-zensu-gate.sh', body: 'checks/pre-bash-zensu-gate.sh', failure: 'open' }),
  Object.freeze({ event: 'PreToolUse', name: 'source-write-gate', matcher: 'Bash|PowerShell', script: 'pre-bash-source-write-gate.sh', body: 'checks/pre-bash-source-write-gate.sh', failure: 'closed' }),
  Object.freeze({ event: 'PreToolUse', name: 'secret-scan', matcher: 'Bash|PowerShell', script: 'pre-write-secret-scan.sh', body: 'checks/pre-write-secret-scan.sh', failure: 'open' }),
  Object.freeze({ event: 'PreToolUse', name: 'browser-consent', matcher: 'Bash|PowerShell', script: 'pre-browser-navigation-consent.sh', body: 'checks/pre-browser-navigation-consent.sh', failure: 'closed' }),
  Object.freeze({ event: 'PreToolUse', name: 'work-order-gate', matcher: '.*', script: 'pre-work-order-gate.sh', body: 'checks/pre-work-order-gate.sh', failure: 'open' }),
  Object.freeze({ event: 'PreToolUse', name: 'reviewer-spawn-allow', matcher: 'Agent|Task', script: 'pre-agent-reviewer-allow.sh', body: null, failure: 'open' }),
  Object.freeze({ event: 'PreToolUse', name: 'plugin-data-guard', matcher: 'Edit|Write|MultiEdit', script: 'pre-write-plugin-data-guard.sh', body: null, failure: 'open' }),
  Object.freeze({ event: 'PreToolUse', name: 'tdd-edit-gate', matcher: 'Edit|Write|MultiEdit', script: 'pre-edit-tdd-reminder.sh', body: 'checks/pre-edit-tdd-reminder.sh', failure: 'open' }),
  Object.freeze({ event: 'PreToolUse', name: 'secret-scan-write', matcher: 'Edit|Write|MultiEdit', script: 'pre-write-secret-scan.sh', body: 'checks/pre-write-secret-scan.sh', failure: 'open' }),
  Object.freeze({ event: 'PreToolUse', name: 'plugin-data-guard-notebook', matcher: 'NotebookEdit', script: 'pre-write-plugin-data-guard.sh', body: null, failure: 'open' }),
  Object.freeze({ event: 'PreToolUse', name: 'secret-scan-notebook', matcher: 'NotebookEdit', script: 'pre-write-secret-scan.sh', body: 'checks/pre-write-secret-scan.sh', failure: 'open' }),
  Object.freeze({ event: 'PostToolUse', name: 'artifact-redact', matcher: 'Bash|PowerShell', script: 'post-artifact-redact.sh', body: null, failure: 'open' }),
  Object.freeze({ event: 'PostToolUse', name: 'browser-consent-recorder', matcher: 'Bash|PowerShell', script: 'post-browser-navigation-consent.sh', body: 'checks/post-browser-navigation-consent.sh', failure: 'open' }),
  Object.freeze({ event: 'PostToolUse', name: 'work-order-post', matcher: '.*', script: 'post-work-order.sh', body: 'checks/post-work-order.sh', failure: 'open' }),
  Object.freeze({ event: 'PostToolUse', name: 'artifact-redact-write', matcher: 'Edit|Write|MultiEdit', script: 'post-artifact-redact.sh', body: null, failure: 'open' }),
]);

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

function dispatcherEvent(hook) {
  if (!hook || typeof hook !== 'object' || hook.command !== 'node' || !Array.isArray(hook.args)) return null;
  const [module, event] = hook.args;
  if (hook.args.length !== 2 || typeof module !== 'string' || !module.endsWith(`/${DISPATCHER_MODULE}`)) return null;
  return Object.prototype.hasOwnProperty.call(DISPATCH_EVENTS, event) ? DISPATCH_EVENTS[event] : null;
}

function hookEntries(hook, event) {
  const dispatched = dispatcherEvent(hook);
  if (dispatched !== null) {
    if (dispatched !== event) return [];
    return DISPATCHED_CHECKS
      .filter((check) => check.event === event)
      .map((check) => ({ command: `bash "\${CLAUDE_PLUGIN_ROOT}/hooks/${check.script}"`, matcher: check.matcher }));
  }
  return hook && typeof hook.command === 'string' ? [{ command: hook.command, matcher: undefined }] : [];
}

function bothCover(first, second) {
  if (first === REGISTRATION.UNKNOWN || second === REGISTRATION.UNKNOWN) return REGISTRATION.UNKNOWN;
  return first === REGISTRATION.REGISTERED && second === REGISTRATION.REGISTERED ? REGISTRATION.REGISTERED : REGISTRATION.UNREGISTERED;
}

function entryMatcherCovers(groupMatcher, entryMatcher, tool) {
  const group = hostMatcherCovers(groupMatcher, tool);
  return entryMatcher === undefined ? group : bothCover(group, hostMatcherCovers(entryMatcher, tool));
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

function effectiveMatcher(groupMatcher, entryMatcher) {
  if (entryMatcher === undefined) return groupMatcher;
  if (groupMatcher === undefined || groupMatcher === '' || groupMatcher === '*' || groupMatcher === '.*') return entryMatcher;
  return null;
}

function registeredHooks(manifest, event) {
  const groups = eventGroups(manifest, event, READINGS.HOST);
  if (groups === null) return null;
  const hooks = [];
  for (const group of groups) {
    if (!group || !Array.isArray(group.hooks)) continue;
    for (const hook of group.hooks) {
      const dispatched = dispatcherEvent(hook) !== null;
      for (const entry of hookEntries(hook, event)) {
        hooks.push({
          command: entry.command,
          matcher: effectiveMatcher(group.matcher, entry.matcher),
          timeout: hook.timeout,
          dispatched,
        });
      }
    }
  }
  return hooks;
}

function registration(manifest, options) {
  const groups = eventGroups(manifest, options.event, options.reading);
  if (groups === null) return REGISTRATION.UNKNOWN;
  let undecided = false;
  const covering = (matcher) => (options.reading === READINGS.HOST
    ? hostCovers(matcher, options.tools)
    : regexCovers(matcher, options.tools));
  for (const group of groups) {
    if (!group || !Array.isArray(group.hooks)) continue;
    const entries = group.hooks.flatMap((hook) => hookEntries(hook, options.event))
      .filter((entry) => options.names(entry.command));
    for (const entry of entries) {
      const covers = entry.matcher === undefined
        ? covering(group.matcher)
        : bothCover(covering(group.matcher), covering(entry.matcher));
      if (covers === REGISTRATION.REGISTERED) return REGISTRATION.REGISTERED;
      if (covers === REGISTRATION.UNKNOWN) undecided = true;
    }
  }
  return undecided ? REGISTRATION.UNKNOWN : REGISTRATION.UNREGISTERED;
}

module.exports = {
  DISPATCHED_CHECKS,
  DISPATCHER_MODULE,
  READINGS,
  REGISTRATION,
  dispatcherEvent,
  entryMatcherCovers,
  hookEntries,
  hostMatcherCovers,
  registeredHooks,
  registration,
};
