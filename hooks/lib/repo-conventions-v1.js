'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PROVIDERS = Object.freeze(['github', 'gitlab', 'unknown']);
const SUBJECT_LIMIT = 20;
const SUBJECT_MAX_LENGTH = 200;
const LIST_LIMIT = 50;
const PACKAGE_JSON_MAX_BYTES = 1024 * 1024;
const TEMPLATE_MAX_BYTES = 64 * 1024;
const TEMPLATE_PATH_MAX_LENGTH = 1024;
const GIT_TIMEOUT_MS = 10000;
const GIT_MAX_BUFFER = 8 * 1024 * 1024;
const TRAILER_KEYS = Object.freeze(['Co-authored-by', 'Signed-off-by', 'Assisted-by']);
const CONVENTIONAL_SUBJECT = /^[a-z][a-z0-9-]*(?:\([^()\r\n]+\))?!?: \S/;
const UNSAFE_TEXT = new RegExp(`[\\u0000-\\u001f\\u007f-\\u009f${String.fromCodePoint(0x2028, 0x2029)}]`, 'g');
const READ_ONLY_GIT = Object.freeze(['--no-optional-locks', '-c', 'core.fsmonitor=false', '-c', 'diff.autoRefreshIndex=false']);
const GIT_ENV_SCRUB = Object.freeze(['GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY',
  'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_NAMESPACE', 'GIT_CEILING_DIRECTORIES', 'GIT_DISCOVERY_ACROSS_FILESYSTEM']);
const PATHSPECS = Object.freeze([
  ':(icase,glob)pull_request_template.*',
  ':(icase,glob).github/pull_request_template.*',
  ':(icase,glob)docs/pull_request_template.*',
  ':(icase,glob)pull_request_template/*',
  ':(icase,glob).github/pull_request_template/*',
  ':(icase,glob)docs/pull_request_template/*',
  ':(glob).gitlab/merge_request_templates/*',
  ':(glob)commitlint.config.*',
  ':(glob).commitlintrc',
  ':(glob).commitlintrc.*',
  ':(literal)package.json',
  ':(icase,glob)contributing',
  ':(icase,glob)contributing.*',
  ':(icase,glob).github/contributing',
  ':(icase,glob).github/contributing.*',
  ':(icase,glob)docs/contributing',
  ':(icase,glob)docs/contributing.*',
  ':(literal)AGENTS.md',
  ':(literal)CLAUDE.md',
  ':(literal).claude/CLAUDE.md',
]);
const SINGLE_TEMPLATE = /^(?:\.github\/|docs\/)?pull_request_template\.(?:md|txt)$/i;
const DIRECTORY_TEMPLATE = /^(?:\.github\/|docs\/)?pull_request_template\/[^/]+\.(?:md|txt)$/i;
const GITLAB_TEMPLATE = /^\.gitlab\/merge_request_templates\/[^/]+\.md$/;
const GITLAB_DEFAULT = /^\.gitlab\/merge_request_templates\/default\.md$/i;
const COMMITLINT_FILE = /^(?:\.commitlintrc(?:\.(?:json|ya?ml|[cm]?js|[cm]?ts))?|commitlint\.config\.(?:[cm]?js|[cm]?ts))$/;
const CONTRIBUTING_FILE = /^(?:\.github\/|docs\/)?contributing(?:\.[A-Za-z0-9]+)?$/i;
const AGENTS_FILE = /^AGENTS\.md$/;
const CLAUDE_FILE = /^(?:\.claude\/)?CLAUDE\.md$/;
const TEMPLATE_PATH = /^[A-Za-z0-9._/-]+$/;
const TEMPLATE_EXTENSION = /\.(?:md|txt)$/i;
const OVERRIDE_DIR = '.zensu/templates';
const OVERRIDE_NAME = /^[A-Za-z0-9._-]+\.md$/;

function noFollowFlag() {
  return process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW)
    ? fs.constants.O_NOFOLLOW
    : 0;
}

function nonBlockFlag() {
  return Number.isInteger(fs.constants.O_NONBLOCK) ? fs.constants.O_NONBLOCK : 0;
}

function gitEnvironment(env) {
  const childEnv = Object.assign({}, env);
  for (const name of GIT_ENV_SCRUB) delete childEnv[name];
  return childEnv;
}

function git(cwd, args, env) {
  const result = spawnSync('git', [...READ_ONLY_GIT, '-C', cwd, ...args], {
    env: gitEnvironment(env),
    encoding: 'utf8',
    timeout: GIT_TIMEOUT_MS,
    maxBuffer: GIT_MAX_BUFFER,
    stdio: ['ignore', 'pipe', 'ignore'],
    windowsHide: true,
  });
  if (result.error || result.status !== 0 || typeof result.stdout !== 'string') return null;
  return result.stdout;
}

function safeName(value) {
  return TEMPLATE_PATH.test(value) && value.split('/').every((part) => part !== '' && !part.startsWith('-'));
}

function plainEntry(top, rel) {
  const parts = rel.split('/');
  let current = top;
  let info = null;
  for (let index = 0; index < parts.length; index += 1) {
    current = path.join(current, parts[index]);
    try {
      info = fs.lstatSync(current);
    } catch (_error) {
      return null;
    }
    if (info.isSymbolicLink() || (index < parts.length - 1 && !info.isDirectory())) return null;
  }
  return info;
}

function plainFile(top, rel, maxBytes = Infinity) {
  const info = plainEntry(top, rel);
  return info !== null && info.isFile() && info.size <= maxBytes;
}

function readPlainFile(file, maxBytes) {
  let before;
  try {
    before = fs.lstatSync(file);
  } catch (_error) {
    return null;
  }
  if (!before.isFile() || before.isSymbolicLink() || before.size > maxBytes) return null;
  let fd = null;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | noFollowFlag() | nonBlockFlag());
    const opened = fs.fstatSync(fd);
    if (!opened.isFile() || opened.dev !== before.dev || opened.ino !== before.ino || opened.size > maxBytes) return null;
    const buffer = Buffer.alloc(opened.size);
    let offset = 0;
    while (offset < opened.size) {
      const read = fs.readSync(fd, buffer, offset, opened.size - offset, offset);
      if (read === 0) break;
      offset += read;
    }
    return buffer.subarray(0, offset).toString('utf8');
  } catch (_error) {
    return null;
  } finally {
    if (fd !== null) {
      try { fs.closeSync(fd); } catch (_error) {}
    }
  }
}

function packageDeclaresCommitlint(file) {
  const text = readPlainFile(file, PACKAGE_JSON_MAX_BYTES);
  if (text === null) return false;
  try {
    const parsed = JSON.parse(text);
    return parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)
      && Object.prototype.hasOwnProperty.call(parsed, 'commitlint');
  } catch (_error) {
    return false;
  }
}

function locationRank(rel) {
  if (rel.startsWith('.github/')) return 0;
  if (rel.toLowerCase().startsWith('docs/')) return 2;
  return 1;
}

function byLocation(a, b) {
  const rank = locationRank(a) - locationRank(b);
  if (rank !== 0) return rank;
  return a < b ? -1 : (a > b ? 1 : 0);
}

function trackedFiles(top, env) {
  const listed = git(top, ['ls-files', '-z', '--', ...PATHSPECS], env);
  if (listed === null) return null;
  return listed.split('\0').filter((rel) => rel !== '' && plainFile(top, rel));
}

function templateRefusal(top, rel, env) {
  const parts = rel.split('/');
  if (rel.length > TEMPLATE_PATH_MAX_LENGTH || path.posix.isAbsolute(rel) || path.win32.isAbsolute(rel)
    || parts.some((part) => part === '' || part === '.' || part === '..')) {
    return 'the path is not a relative path below the top level of the work tree';
  }
  if (!TEMPLATE_PATH.test(rel)) return 'the path holds a character other than a letter, a digit, a dot, an underscore, a dash or a slash';
  if (!safeName(rel)) return 'a path segment starts with a dash';
  if (!TEMPLATE_EXTENSION.test(rel)) return 'the path names no .md or .txt file';
  const listed = git(top, ['ls-files', '-z', '--', `:(literal)${rel}`], env);
  if (listed === null) return 'git ls-files failed';
  if (!listed.split('\0').includes(rel)) return 'git does not track the file';
  const info = plainEntry(top, rel);
  if (info === null || !info.isFile()) return 'the file or a directory on its path is a symlink, or the file is not a regular file';
  if (info.size > TEMPLATE_MAX_BYTES) return `the file is larger than ${TEMPLATE_MAX_BYTES} bytes`;
  return null;
}

function overrides(top) {
  const dir = plainEntry(top, OVERRIDE_DIR);
  if (dir === null || !dir.isDirectory()) return [];
  let names;
  try {
    names = fs.readdirSync(path.join(top, ...OVERRIDE_DIR.split('/')));
  } catch (_error) {
    return [];
  }
  return names.filter((name) => OVERRIDE_NAME.test(name))
    .map((name) => `${OVERRIDE_DIR}/${name}`)
    .filter((rel) => plainFile(top, rel, TEMPLATE_MAX_BYTES))
    .sort()
    .slice(0, LIST_LIMIT);
}

function templates(files, provider) {
  const single = files.filter((rel) => SINGLE_TEMPLATE.test(rel)).sort(byLocation);
  const directory = files.filter((rel) => DIRECTORY_TEMPLATE.test(rel)).sort(byLocation);
  const gitlab = files.filter((rel) => GITLAB_TEMPLATE.test(rel)).sort(byLocation);
  let preferred = null;
  if (provider === 'github' && single.length > 0) preferred = single[0];
  if (provider === 'gitlab') preferred = gitlab.find((rel) => GITLAB_DEFAULT.test(rel)) || null;
  return { prTemplate: preferred, prTemplates: [...single, ...directory, ...gitlab].filter(safeName).slice(0, LIST_LIMIT) };
}

function commitlintConfigs(files, top) {
  const found = files.filter((rel) => COMMITLINT_FILE.test(rel)).sort(byLocation);
  if (files.includes('package.json') && packageDeclaresCommitlint(path.join(top, 'package.json'))) found.push('package.json');
  return found;
}

function upstreamRemote(top, env) {
  const upstream = git(top, ['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'], env);
  const name = upstream === null ? '' : upstream.trim().split('/')[0];
  return /^[A-Za-z0-9._-]+$/.test(name) && !name.startsWith('-') ? name : 'origin';
}

function commitExists(top, ref, env) {
  return git(top, ['rev-parse', '--verify', '--quiet', `${ref}^{commit}`], env) !== null;
}

function historyRef(top, env) {
  const remote = upstreamRemote(top, env);
  const prefix = `refs/remotes/${remote}/`;
  const target = git(top, ['symbolic-ref', '--quiet', `${prefix}HEAD`], env);
  const full = target === null ? '' : target.trim();
  if (full.startsWith(prefix) && safeName(full.slice(prefix.length)) && commitExists(top, full, env)) {
    return { rev: full, ref: full.slice('refs/remotes/'.length), defaultBranch: full.slice(prefix.length) };
  }
  return { rev: 'HEAD', ref: 'HEAD', defaultBranch: null };
}

function cleanSubject(subject) {
  return Array.from(subject.replace(UNSAFE_TEXT, ' ').trim()).slice(0, SUBJECT_MAX_LENGTH).join('');
}

function emptyTrailers() {
  const counts = {};
  for (const key of TRAILER_KEYS) counts[key] = 0;
  return counts;
}

function history(top, rev, env) {
  const trailers = emptyTrailers();
  if (!commitExists(top, rev, env)) return { subjects: [], conventionalShare: null, trailers };
  const out = git(top, ['log', '-z', `-n${SUBJECT_LIMIT}`, '--no-merges', '--no-color', '--no-show-signature',
    '--format=%s%n%(trailers:only,unfold)', rev, '--'], env);
  if (out === null) return null;
  const subjects = [];
  let conventional = 0;
  for (const record of out.split('\0')) {
    if (record === '' || subjects.length >= SUBJECT_LIMIT) continue;
    const newline = record.indexOf('\n');
    const subject = newline === -1 ? record : record.slice(0, newline);
    const lines = (newline === -1 ? '' : record.slice(newline + 1)).split('\n').map((line) => line.toLowerCase());
    for (const key of TRAILER_KEYS) {
      const lead = `${key.toLowerCase()}:`;
      if (lines.some((line) => line.startsWith(lead))) trailers[key] += 1;
    }
    if (CONVENTIONAL_SUBJECT.test(subject)) conventional += 1;
    subjects.push(cleanSubject(subject));
  }
  const conventionalShare = subjects.length === 0 ? null : Math.round((conventional / subjects.length) * 100) / 100;
  return { subjects, conventionalShare, trailers };
}

function probe(options = {}) {
  const env = options.env || process.env;
  const provider = PROVIDERS.includes(options.provider) ? options.provider : 'unknown';
  const repo = typeof options.repo === 'string' && options.repo !== '' ? options.repo : process.cwd();
  const topText = git(repo, ['rev-parse', '--show-toplevel'], env);
  const top = topText === null ? '' : topText.trim();
  if (top === '') return { error: `${repo} is not inside a git work tree` };
  const files = trackedFiles(top, env);
  if (files === null) return { error: 'git ls-files failed' };
  const { rev, ref, defaultBranch } = historyRef(top, env);
  const log = history(top, rev, env);
  if (log === null) return { error: `git log failed for ${ref}` };
  const { prTemplate: found, prTemplates } = templates(files, provider);
  const candidate = typeof options.template === 'string' ? options.template : found;
  const refused = candidate === null ? null : templateRefusal(top, candidate, env);
  return {
    provider,
    prTemplate: refused === null ? candidate : null,
    prTemplateRefused: refused,
    prTemplates,
    overrides: overrides(top),
    commitlint: commitlintConfigs(files, top),
    ref,
    defaultBranch,
    subjects: log.subjects,
    conventionalShare: log.conventionalShare,
    trailers: log.trailers,
    contributing: files.filter((rel) => CONTRIBUTING_FILE.test(rel)).sort(byLocation),
    agents: files.filter((rel) => AGENTS_FILE.test(rel)),
    claude: files.filter((rel) => CLAUDE_FILE.test(rel)).sort((a, b) => a.length - b.length),
  };
}

function cliMain(argv, out, err, env = process.env) {
  let repo = null;
  let provider = null;
  let template = null;
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--repo' && typeof argv[index + 1] === 'string' && repo === null) {
      repo = argv[index + 1];
      index += 1;
    } else if (argv[index] === '--provider' && typeof argv[index + 1] === 'string' && provider === null) {
      provider = argv[index + 1];
      index += 1;
    } else if (argv[index] === '--template' && typeof argv[index + 1] === 'string' && template === null) {
      template = argv[index + 1];
      index += 1;
    } else {
      return 2;
    }
  }
  if (provider !== null && !PROVIDERS.includes(provider)) return 2;
  const result = probe({ repo: repo === null ? process.cwd() : repo, provider: provider || 'unknown', template, env });
  if (result.error) {
    err.write(`repo-conventions-v1: ${result.error}\n`);
    return 1;
  }
  out.write(`${JSON.stringify(result)}\n`);
  return 0;
}

module.exports = {
  CONVENTIONAL_SUBJECT,
  PROVIDERS,
  SUBJECT_LIMIT,
  SUBJECT_MAX_LENGTH,
  TEMPLATE_MAX_BYTES,
  TRAILER_KEYS,
  cliMain,
  probe,
};

if (require.main === module) {
  const code = cliMain(process.argv.slice(2), process.stdout, process.stderr);
  if (code === 2) process.stderr.write('usage: repo-conventions-v1.js [--repo <dir>] [--provider github|gitlab|unknown] [--template <path>]\n');
  process.exitCode = code;
}
