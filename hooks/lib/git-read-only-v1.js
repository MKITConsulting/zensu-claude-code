'use strict';

const READ_ONLY_GIT = Object.freeze([
  '--no-optional-locks',
  '-c',
  'core.fsmonitor=false',
  '-c',
  'diff.autoRefreshIndex=false',
]);

const GIT_SCRUBBED_ENV = Object.freeze([
  'GIT_DIR',
  'GIT_WORK_TREE',
  'GIT_INDEX_FILE',
  'GIT_COMMON_DIR',
  'GIT_OBJECT_DIRECTORY',
  'GIT_ALTERNATE_OBJECT_DIRECTORIES',
  'GIT_CEILING_DIRECTORIES',
  'GIT_DISCOVERY_ACROSS_FILESYSTEM',
  'GIT_NAMESPACE',
  'GIT_PREFIX',
  'GIT_CONFIG',
  'GIT_CONFIG_GLOBAL',
  'GIT_CONFIG_SYSTEM',
  'GIT_CONFIG_COUNT',
  'GIT_CONFIG_PARAMETERS',
]);

const GIT_PATHSPEC_ENV = Object.freeze([
  'GIT_LITERAL_PATHSPECS',
  'GIT_GLOB_PATHSPECS',
  'GIT_NOGLOB_PATHSPECS',
  'GIT_ICASE_PATHSPECS',
]);

function gitEnvironment(extra) {
  const env = { ...process.env };
  for (const name of GIT_SCRUBBED_ENV) delete env[name];
  for (const name of GIT_PATHSPEC_ENV) delete env[name];
  env.GIT_OPTIONAL_LOCKS = '0';
  env.LC_ALL = 'C';
  env.LANG = 'C';
  delete env.LANGUAGE;
  env.GIT_TERMINAL_PROMPT = '0';
  return { ...env, ...(extra || {}) };
}

function readOnlyGitArgs(args) {
  return [...READ_ONLY_GIT, ...args];
}

module.exports = {
  READ_ONLY_GIT,
  GIT_SCRUBBED_ENV,
  GIT_PATHSPEC_ENV,
  gitEnvironment,
  readOnlyGitArgs,
};
