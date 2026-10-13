'use strict';

const fs = require('fs');
const { REGISTRATION, hostMatcherCovers } = require('./hook-registration-v1.js');

const SHELL_TOOLS = Object.freeze(['Bash', 'PowerShell']);
const TOOL_EVENTS = Object.freeze(['PreToolUse', 'PostToolUse']);
const POWERSHELL_STATES = Object.freeze({ ON: 'on', OFF: 'off', DEFAULT: 'default', ABSENT: 'absent' });
const POWERSHELL_STATE_VALUES = Object.freeze(Object.values(POWERSHELL_STATES));
const TRUTHY = new Set(['1', 'true', 'yes', 'on']);
const FALSY = new Set(['0', 'false', 'no', 'off']);
const RANK = Object.freeze({
  [REGISTRATION.UNREGISTERED]: 0,
  [REGISTRATION.UNKNOWN]: 1,
  [REGISTRATION.REGISTERED]: 2,
});
const REMEDY = 'set CLAUDE_CODE_USE_POWERSHELL_TOOL=0 in your environment or in the env block of ~/.claude/settings.json, then start a new session';

function powershellToolState(environment, platform) {
  const value = environment && typeof environment.CLAUDE_CODE_USE_POWERSHELL_TOOL === 'string'
    ? environment.CLAUDE_CODE_USE_POWERSHELL_TOOL.trim().toLowerCase()
    : '';
  if (TRUTHY.has(value)) return POWERSHELL_STATES.ON;
  if (FALSY.has(value)) return POWERSHELL_STATES.OFF;
  return platform === 'win32' ? POWERSHELL_STATES.DEFAULT : POWERSHELL_STATES.ABSENT;
}

function mayRunPowerShell(state) {
  return state === POWERSHELL_STATES.ON || state === POWERSHELL_STATES.DEFAULT;
}

function hookFile(command) {
  const found = /\/hooks\/([A-Za-z0-9._-]+\.sh)/.exec(typeof command === 'string' ? command : '');
  return found ? found[1] : null;
}

function shellCoverage(manifest) {
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) return null;
  if (manifest.hooks === undefined) return { hooks: [], gaps: [] };
  if (!manifest.hooks || typeof manifest.hooks !== 'object' || Array.isArray(manifest.hooks)) return null;
  const seen = new Map();
  for (const event of TOOL_EVENTS) {
    const groups = manifest.hooks[event] === undefined ? [] : manifest.hooks[event];
    if (!Array.isArray(groups)) return null;
    for (const group of groups) {
      if (!group || !Array.isArray(group.hooks)) continue;
      const [bash, powershell] = SHELL_TOOLS.map((tool) => hostMatcherCovers(group.matcher, tool));
      for (const hook of group.hooks) {
        const file = hookFile(hook && hook.command);
        if (!file) continue;
        const key = `${event}\t${file}`;
        const entry = seen.get(key) || {
          event,
          hook: file,
          bash: REGISTRATION.UNREGISTERED,
          powershell: REGISTRATION.UNREGISTERED,
        };
        if (RANK[bash] > RANK[entry.bash]) entry.bash = bash;
        if (RANK[powershell] > RANK[entry.powershell]) entry.powershell = powershell;
        seen.set(key, entry);
      }
    }
  }
  const hooks = [...seen.values()].filter((entry) => entry.bash !== REGISTRATION.UNREGISTERED);
  const gaps = hooks.filter((entry) => entry.powershell !== REGISTRATION.REGISTERED);
  return { hooks, gaps };
}

function gapNames(coverage) {
  return [...new Set(coverage.gaps.map((entry) => entry.hook))].sort();
}

function readManifest(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_error) {
    return null;
  }
}

function bannerText(state, coverage) {
  const lead = state === POWERSHELL_STATES.ON
    ? "Claude Code's PowerShell tool is enabled here (CLAUDE_CODE_USE_POWERSHELL_TOOL)"
    : 'Claude Code may run shell commands through its PowerShell tool here, because on Windows it is on by default for claude.ai and Console accounts';
  const gap = coverage === null
    ? 'Zensu could not read hooks/hooks.json to check which of its hooks see PowerShell commands'
    : `${gapNames(coverage).length} of Zensu's hooks that inspect shell commands match only the Bash tool, so the commands Claude runs through PowerShell skip them`;
  return `zensu: ⚠ PowerShell tool — ${lead}, and ${gap}. To keep Claude on the Bash tool, ${REMEDY}; /zensu:doctor names the hooks.`;
}

function bannerLine(manifest, environment, platform) {
  const state = powershellToolState(environment, platform);
  if (!mayRunPowerShell(state)) return '';
  const coverage = shellCoverage(manifest);
  if (coverage !== null && coverage.gaps.length === 0) return '';
  return bannerText(state, coverage);
}

if (require.main === module) {
  const [mode, file] = process.argv.slice(2);
  if (mode === 'banner' && typeof file === 'string' && file !== '') {
    const text = bannerLine(readManifest(file), process.env, process.platform);
    if (text) process.stdout.write(`${text}\n`);
  }
} else {
  module.exports = {
    POWERSHELL_STATES,
    POWERSHELL_STATE_VALUES,
    REMEDY,
    SHELL_TOOLS,
    bannerLine,
    gapNames,
    mayRunPowerShell,
    powershellToolState,
    shellCoverage,
  };
}
