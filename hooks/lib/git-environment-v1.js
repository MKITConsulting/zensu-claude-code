'use strict';

const GIT_ENV_SCRUB = Object.freeze([
  'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR',
  'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES',
  'GIT_CEILING_DIRECTORIES', 'GIT_DISCOVERY_ACROSS_FILESYSTEM',
  'GIT_NAMESPACE', 'GIT_PREFIX', 'GIT_CONFIG', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM',
  'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS',
]);

function gitEnvironment(base) {
  const env = { ...(base || process.env) };
  for (const name of GIT_ENV_SCRUB) delete env[name];
  env.GIT_TERMINAL_PROMPT = '0';
  return env;
}

module.exports = {
  GIT_ENV_SCRUB,
  gitEnvironment,
};
