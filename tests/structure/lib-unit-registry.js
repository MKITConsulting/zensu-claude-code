'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const REGISTRY_REL = 'tests/profiles/unit-files.v1.json';
const MANIFEST_REL = 'tests/profiles/promptfoo-local-only.v1.json';
const OVERVIEW_REL = 'tests/SUITE-OVERVIEW.md';
const RENDER_COMMAND = 'node tests/structure/lib-unit-registry.js render --write';
const HOST_CLASSES = ['darwin', 'linux', 'root', 'win32'];
const ENTRY_KEYS = new Set(['path', 'registered', 'skips', 'guards', 'runs', 'summary']);
const RUN_KEYS = new Set(['driver', 'mode']);
const UNIT_PATH = /^tests\/(?:[A-Za-z0-9._-]+\/)*[A-Za-z0-9._-]+\.test\.js$/;
const DRIVER_PATH = /^tests\/(?:[A-Za-z0-9._-]+\/)*[A-Za-z0-9._-]+\.sh$/;
const MODE = /^[a-z][a-z0-9-]*$/;
const REGISTRATION = /^test(?:\.(?:skip|todo|only))?\(/gm;
const INDENTED_REGISTRATION = /^[ \t]+test(?:\.(?:skip|todo|only))?\(/m;
const CONTEXT_PARAMETER = /(?:\(\s*([A-Za-z_$][\w$]*)\s*\)|([A-Za-z_$][\w$]*))\s*=>\s*\{?\s*$|\bfunction\b[^(]*\(\s*([A-Za-z_$][\w$]*)\s*\)\s*\{?\s*$/;
const SUITE_IMPORT = /(?:\{([^}]*)\}\s*=\s*require\(\s*['"]node:test['"]\s*\)|import\s*\{([^}]*)\}\s*from\s*['"]node:test['"])/g;
const UNIT_CALL = /\bunit_(?:run|check|grade|not_run)\b/;
const DONE_CALL = /\bunit_(?:registry_done|check_done)\b/;
const COMMAND_POSITION = '(?:^|[;&|(`!]|\\$\\(|\\b(?:if|elif|while|until|then|do|else|exec|command|env|nice|time)\\b|\\btimeout(?:[ \\t]+-\\S+)*[ \\t]+\\S+)[ \\t]*(?:[A-Za-z_][A-Za-z0-9_]*=\\S*[ \\t]+)*';
const NODE_TEST_SPAWN = new RegExp(`${COMMAND_POSITION}(?:node|"?\\$\\{?NODE[A-Za-z0-9_]*\\}?"?)(?:[ \\t]+(?!--test(?![\\w-]))\\S+)*[ \\t]+--test(?![\\w-])`);
const SHELL_CALL = new RegExp(`${COMMAND_POSITION}(?:bash|sh)\\b`);
const SOURCE_CALL = /(?:^|[;&|]|\b(?:then|do|else)\b)[ \t]*(?:\.|source)[ \t]+/;
const ASSIGNMENT = /^[ \t]*(?:(?:local|export|readonly|declare)[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)=/;
const GRADE_CALL = /^[ \t]*(?:[A-Za-z_][A-Za-z0-9_]*=\S*[ \t]+)*unit_grade\b/;
const EARLY_EXIT = /^[ \t]*exit 0\b/;
const REGIONS = ['totals', 'section-4'];

const exitCodes = { pass: 0, verdict: 1, plumbing: 2 };

function hostClass(platform = process.platform, getuid = process.getuid) {
  if (typeof getuid === 'function' && getuid.call(process) === 0) return 'root';
  return platform;
}

function isInteger(value, minimum) {
  return Number.isInteger(value) && value >= minimum;
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function validateEntry(entry, index, root) {
  const at = `entry ${index}`;
  if (!isPlainObject(entry)) return [`${at}: must be an object`];
  const problems = [];
  for (const key of Object.keys(entry)) {
    if (!ENTRY_KEYS.has(key)) problems.push(`${at}: unknown key "${key}"`);
  }
  const label = typeof entry.path === 'string' ? `${at} (${entry.path})` : at;
  if (typeof entry.path !== 'string' || !UNIT_PATH.test(entry.path) || entry.path.split('/').includes('..')) {
    problems.push(`${label}: path must be a repo-relative tests/**/*.test.js path`);
  } else if (!fs.existsSync(path.join(root, entry.path))) {
    problems.push(`${label}: the file does not exist`);
  }
  if (!isInteger(entry.registered, 1)) {
    problems.push(`${label}: registered must be an integer of at least 1, got ${JSON.stringify(entry.registered)}`);
  }
  if (entry.skips !== undefined) {
    if (!isPlainObject(entry.skips) || Object.keys(entry.skips).length === 0) {
      problems.push(`${label}: skips must be a non-empty object keyed by host class`);
    } else {
      for (const [host, ceiling] of Object.entries(entry.skips)) {
        if (!HOST_CLASSES.includes(host)) problems.push(`${label}: skips names unknown host class "${host}"; use ${HOST_CLASSES.join(', ')}`);
        else if (!isInteger(ceiling, 1)) problems.push(`${label}: skips.${host} must be an integer of at least 1; omit the host for 0`);
        else if (isInteger(entry.registered, 1) && ceiling > entry.registered) problems.push(`${label}: skips.${host} exceeds registered`);
      }
    }
  }
  if (entry.guards !== undefined) {
    if (!Array.isArray(entry.guards) || entry.guards.length === 0
        || entry.guards.some((title) => typeof title !== 'string' || title.length === 0 || /[\r\n]/.test(title))) {
      problems.push(`${label}: guards must be a non-empty list of single-line titles`);
    } else if (new Set(entry.guards).size !== entry.guards.length) {
      problems.push(`${label}: guards lists a title twice`);
    }
  }
  if (!Array.isArray(entry.runs) || entry.runs.length === 0) {
    problems.push(`${label}: runs must list at least one { driver, mode? } pair`);
  } else {
    const seen = new Set();
    entry.runs.forEach((run, runIndex) => {
      if (!isPlainObject(run) || Object.keys(run).some((key) => !RUN_KEYS.has(key))
          || typeof run.driver !== 'string' || !DRIVER_PATH.test(run.driver)
          || (run.mode !== undefined && (typeof run.mode !== 'string' || !MODE.test(run.mode)))) {
        problems.push(`${label}: runs[${runIndex}] must be { driver: tests/**/*.sh, mode?: lowercase word }`);
        return;
      }
      const pair = `${run.driver}#${run.mode || ''}`;
      if (seen.has(pair)) problems.push(`${label}: runs lists ${run.driver}${run.mode ? ` mode ${run.mode}` : ''} twice`);
      seen.add(pair);
      if (!fs.existsSync(path.join(root, run.driver))) problems.push(`${label}: runs[${runIndex}] names a driver that does not exist: ${run.driver}`);
    });
  }
  if (typeof entry.summary !== 'string' || entry.summary.trim().length === 0 || /[\r\n|]/.test(entry.summary)) {
    problems.push(`${label}: summary must be one non-empty line without "|"`);
  }
  return problems;
}

function loadRegistry(root, registryFile) {
  const file = registryFile || path.join(root, REGISTRY_REL);
  const shown = registryFile || REGISTRY_REL;
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (error) {
    return { entries: null, errors: [`${shown}: unreadable (${error.code || error.message})`] };
  }
  let doc;
  try {
    doc = JSON.parse(text);
  } catch (error) {
    return { entries: null, errors: [`${shown}: not JSON (${error.message})`] };
  }
  if (!isPlainObject(doc) || doc.schemaVersion !== 1 || !Array.isArray(doc.files)
      || Object.keys(doc).some((key) => key !== 'schemaVersion' && key !== 'files')) {
    return { entries: null, errors: [`${shown}: must be { "schemaVersion": 1, "files": [...] } and nothing else`] };
  }
  const errors = [];
  const firstIndex = new Map();
  doc.files.forEach((entry, index) => {
    for (const problem of validateEntry(entry, index, root)) errors.push(`${shown}: ${problem}`);
    if (isPlainObject(entry) && typeof entry.path === 'string') {
      if (firstIndex.has(entry.path)) {
        errors.push(`${shown}: duplicate path ${entry.path} at entries ${firstIndex.get(entry.path)} and ${index}`);
      } else {
        firstIndex.set(entry.path, index);
      }
    }
  });
  return { entries: doc.files, errors };
}

function gitListedUnitFiles(root) {
  const git = (args) => spawnSync('git', ['-C', root, ...args], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  const failure = (run) => {
    if (run.error) return run.error.code || run.error.message;
    if (run.status === 0) return null;
    return String(run.stderr || '').trim().split('\n')[0] || `git exited ${run.status}`;
  };
  const top = git(['rev-parse', '--show-toplevel']);
  let reason = failure(top);
  if (!reason) {
    let same = false;
    try {
      same = path.relative(fs.realpathSync.native(top.stdout.trim()), fs.realpathSync.native(root)) === '';
    } catch {
      same = false;
    }
    if (!same) return { files: null, gitFailure: null };
    const listing = git(['-c', 'core.fsmonitor=false', 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', 'tests']);
    reason = failure(listing);
    if (!reason) {
      const found = new Set();
      for (const file of listing.stdout.split('\0')) {
        if (file.endsWith('.test.js') && !file.split('/').includes('node_modules') && fs.existsSync(path.join(root, file))) found.add(file);
      }
      return { files: [...found].sort(), gitFailure: null };
    }
  }
  return { files: null, gitFailure: fs.existsSync(path.join(root, '.git')) ? reason : null };
}

function walkUnitFiles(root) {
  const listed = gitListedUnitFiles(root);
  if (listed.files) return listed;
  const found = [];
  const visit = (relative) => {
    let names;
    try {
      names = fs.readdirSync(path.join(root, relative), { withFileTypes: true });
    } catch {
      return;
    }
    for (const dirent of names) {
      if (dirent.name === 'node_modules') continue;
      const child = `${relative}/${dirent.name}`;
      if (dirent.isDirectory()) visit(child);
      else if (dirent.isFile() && dirent.name.endsWith('.test.js')) found.push(child);
    }
  };
  visit('tests');
  return { files: found.sort(), gitFailure: listed.gitFailure };
}

function countMessage(unitPath, registered, declared, source) {
  if (registered < declared) {
    return `${unitPath}: ${source} ${registered}, the registry declares ${declared}; ${declared - registered} case(s) were removed; lower registered only if the removal was intended`;
  }
  return `${unitPath}: ${source} ${registered}, the registry declares ${declared}; raise registered to ${registered} in ${REGISTRY_REL}`;
}

function staticRegistrations(source) {
  return (source.match(REGISTRATION) || []).length;
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function nestedRegistration(source) {
  if (INDENTED_REGISTRATION.test(source)) return true;
  const contexts = new Set();
  for (const line of source.split('\n')) {
    if (!/^test(?:\.(?:skip|todo|only))?\(/.test(line)) continue;
    const parameter = CONTEXT_PARAMETER.exec(line.replace(/\r$/, ''));
    if (parameter) contexts.add(parameter[1] || parameter[2] || parameter[3]);
  }
  for (const name of contexts) {
    if (new RegExp(`^[ \\t]*(?:(?:await|return|void)[ \\t]+)?${escapeRegExp(name)}\\.test\\(`, 'm').test(source)) return true;
  }
  const imported = new Set();
  for (const match of source.matchAll(SUITE_IMPORT)) {
    for (const binding of (match[1] || match[2]).split(',')) {
      const [exported, local = exported] = binding.split(/:|\s+as\s+/).map((part) => part.trim());
      if (['describe', 'it', 'suite'].includes(exported)) imported.add(local);
    }
  }
  for (const name of imported) {
    if (new RegExp(`^[ \\t]*${escapeRegExp(name)}(?:\\.(?:skip|todo|only))?\\(`, 'm').test(source)) return true;
  }
  return false;
}

function census(root, registryFile) {
  const { entries, errors } = loadRegistry(root, registryFile);
  const problems = [...errors];
  if (!entries) return problems;
  const listed = new Set(entries.filter(isPlainObject).map((entry) => entry.path));
  const { files, gitFailure } = walkUnitFiles(root);
  const unlisted = files.filter((unitPath) => !listed.has(unitPath));
  for (const unitPath of unlisted) problems.push(`${unitPath}: no entry in ${REGISTRY_REL}; add one`);
  if (gitFailure && unlisted.length) {
    problems.push(`tests: git could not list this work tree (${gitFailure}), so the census walked tests/ and may name files that git ignores`);
  }
  for (const entry of entries) {
    if (!isPlainObject(entry) || typeof entry.path !== 'string' || !isInteger(entry.registered, 1)) continue;
    let source;
    try {
      source = fs.readFileSync(path.join(root, entry.path), 'utf8');
    } catch {
      continue;
    }
    if (nestedRegistration(source)) {
      problems.push(`${entry.path}: registers a case below column 0, as a subtest, or through describe or it; register every case with a column-0 test( call so the static count holds`);
      continue;
    }
    const registered = staticRegistrations(source);
    if (registered !== entry.registered) problems.push(countMessage(entry.path, registered, entry.registered, 'registers'));
  }
  return problems;
}

function unescapeTap(name) {
  return name.replace(/\\(.)/g, '$1');
}

function splitDirective(rest) {
  const match = /^(.*?)(?<!\\) # (SKIP|TODO)\b(.*)$/i.exec(rest);
  if (!match) return { name: unescapeTap(rest.trim()), directive: null };
  return { name: unescapeTap(match[1].trim()), directive: match[2].toUpperCase() };
}

function parseTap(text) {
  const summary = {};
  const points = [];
  for (const line of String(text).replace(/\r/g, '').split('\n')) {
    const field = /^# (tests|suites|pass|fail|cancelled|skipped|todo) (\d+)$/.exec(line);
    if (field) {
      summary[field[1]] = Number(field[2]);
      continue;
    }
    const point = /^(not ok|ok) \d+ - (.*)$/.exec(line);
    if (point) points.push({ ok: point[1] === 'ok', ...splitDirective(point[2]) });
  }
  return { summary, points };
}

function isFileLevelOnly(points, summary, unitPath) {
  if (summary.tests !== 1 || points.length !== 1) return false;
  const base = path.posix.basename(unitPath);
  const name = points[0].name.split('\\').join('/');
  return name === unitPath || name === base || name.endsWith(`/${base}`);
}

function verify(entry, text, rc, host, staticCount) {
  const unitPath = entry.path;
  const { summary, points } = parseTap(text);
  if (summary.tests === undefined || summary.pass === undefined || summary.fail === undefined) {
    return { ok: false, message: `${unitPath}: no TAP summary was read; the run was truncated or the reporter changed` };
  }
  const cancelled = summary.cancelled || 0;
  if (rc !== 0 || summary.fail > 0 || cancelled > 0) {
    return { ok: false, message: `${unitPath}: node exited ${rc} with ${summary.fail} failing and ${cancelled} cancelled case(s)` };
  }
  if (isFileLevelOnly(points, summary, unitPath)) {
    return { ok: false, message: `${unitPath}: registers no case of its own; node counted the file itself, so the file is empty or failed to load` };
  }
  if (summary.tests !== entry.registered) {
    if (staticCount === entry.registered) {
      return {
        ok: false,
        message: `${unitPath}: node registered ${summary.tests} but the file's column-0 test( calls number ${staticCount}, which the registry declares; register every case with its own column-0 test( call so both counts agree`,
      };
    }
    return { ok: false, message: countMessage(unitPath, summary.tests, entry.registered, 'node registered') };
  }
  const skipped = (summary.skipped || 0) + (summary.todo || 0);
  const ceiling = (entry.skips && entry.skips[host]) || 0;
  if (skipped > ceiling) {
    const names = points.filter((point) => point.directive).map((point) => point.name);
    return {
      ok: false,
      message: `${unitPath}: ${skipped} case(s) skipped or todo on ${host}; the registry allows ${ceiling}${names.length ? ` (${names.join('; ')})` : ''}`,
    };
  }
  for (const guard of entry.guards || []) {
    if (!points.some((point) => point.ok && !point.directive && point.name === guard)) {
      return { ok: false, message: `${unitPath}: guarded case "${guard}" did not pass` };
    }
  }
  return { ok: true, message: `${unitPath}: ${summary.pass}/${summary.tests} passed, ${skipped} skipped (ceiling ${ceiling} on ${host})` };
}

function toRepoPath(root, cwd, given) {
  const absolute = path.resolve(cwd || root, given);
  let real = absolute;
  try {
    real = fs.realpathSync(absolute);
  } catch {
    return null;
  }
  const relative = path.relative(fs.realpathSync(root), real);
  if (relative === '' || relative.startsWith('..') || path.isAbsolute(relative)) return null;
  return relative.split(path.sep).join('/');
}

function runsFor(entry, driver, mode) {
  return Array.isArray(entry.runs) && entry.runs.some((run) => run.driver === driver && (run.mode || '') === (mode || ''));
}

function owned(entries, driver, mode) {
  return entries.filter((entry) => isPlainObject(entry) && runsFor(entry, driver, mode)).map((entry) => entry.path);
}

function readManifest(root) {
  return JSON.parse(fs.readFileSync(path.join(root, MANIFEST_REL), 'utf8'));
}

function driverLabel(driver) {
  return driver.startsWith('tests/structure/') ? driver.slice('tests/structure/'.length) : driver.slice('tests/'.length);
}

function renderSection4(entries) {
  const rows = [...entries].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0)).map((entry) => {
    const skips = entry.skips
      ? HOST_CLASSES.filter((host) => entry.skips[host]).map((host) => `${host} ${entry.skips[host]}`).join(', ')
      : '–';
    const byDriver = new Map();
    for (const run of entry.runs) {
      if (!byDriver.has(run.driver)) byDriver.set(run.driver, []);
      if (run.mode) byDriver.get(run.driver).push(run.mode);
    }
    const drivers = [...byDriver].map(([driver, modes]) => `\`${driverLabel(driver)}\`${modes.length ? ` (${modes.join(', ')})` : ''}`).join(', ');
    return `| \`${entry.path.slice('tests/'.length)}\` | ${entry.registered} | ${skips} | ${drivers} | ${entry.summary} |`;
  });
  return [
    `Generated from \`${REGISTRY_REL}\` by \`${RENDER_COMMAND}\`; edit the registry, never this table. Registered is node's exact total, Skips the per-host ceiling of skipped or todo cases (absent means 0).`,
    '',
    '| Unit file | Registered | Skips | Driven by | Summary |',
    '|---|---|---|---|---|',
    ...rows,
  ].join('\n');
}

function renderTotals(root, entries) {
  const manifest = readManifest(root);
  const ci = manifest.ciStructureTests.length;
  const local = manifest.localStructureTests.length;
  const offline = manifest.ciOfflineSuites.length;
  return [
    `Generated by \`${RENDER_COMMAND}\` from \`${MANIFEST_REL}\` and \`${REGISTRY_REL}\`; edit those files, never these lines.`,
    '',
    `- \`tests/structure/test-*.sh\`: **${ci + local}** suites, ${ci} CI-blocking + ${local} Promptfoo local-only. A \`--ci\` run executes ${ci} structure suites + ${offline} offline evals = ${ci + offline}; the ${local} local-only suites are skipped as \`LOCAL\`.`,
    `- \`node --test\` unit files: **${entries.length}**, each with exactly one entry in \`${REGISTRY_REL}\` (§4).`,
    `- Offline eval suites (\`ciOfflineSuites\`): **${offline}**.`,
  ].join('\n');
}

function render(root, registryFile) {
  const { entries, errors } = loadRegistry(root, registryFile);
  if (errors.length) return { errors };
  return { errors: [], regions: { totals: renderTotals(root, entries), 'section-4': renderSection4(entries) } };
}

function regionPattern(name) {
  return new RegExp(`(<!-- unit-registry:begin ${name} -->\\n)([\\s\\S]*?)(<!-- unit-registry:end ${name} -->)`);
}

function checkOverview(root, regions, overviewText) {
  const problems = [];
  for (const name of REGIONS) {
    const match = regionPattern(name).exec(overviewText);
    if (!match) problems.push(`${OVERVIEW_REL}: the ${name} region markers are missing; restore them and run ${RENDER_COMMAND}`);
    else if (match[2] !== `${regions[name]}\n`) problems.push(`${OVERVIEW_REL}: the ${name} region differs from its sources; run ${RENDER_COMMAND}`);
  }
  return problems;
}

function writeOverview(overviewText, regions) {
  let text = overviewText;
  for (const name of REGIONS) {
    if (!regionPattern(name).test(text)) return { problems: [`${OVERVIEW_REL}: the ${name} region markers are missing; restore them and run ${RENDER_COMMAND}`] };
    text = text.replace(regionPattern(name), (whole, open, body, close) => `${open}${regions[name]}\n${close}`);
  }
  return { problems: [], text };
}

function shellLines(source) {
  const result = [];
  const stack = [{ kind: 'code', depth: 0, closer: null }];
  let heredoc = null;
  for (const raw of source.split('\n')) {
    const line = raw.endsWith('\r') ? raw.slice(0, -1) : raw;
    if (heredoc) {
      result.push({ code: '', text: '' });
      if ((heredoc.strip ? line.replace(/^\t+/, '') : line) === heredoc.word) heredoc = null;
      continue;
    }
    let code = '';
    let end = line.length;
    let opened = null;
    for (let index = 0; index < line.length; index += 1) {
      const top = stack[stack.length - 1];
      const char = line[index];
      const next = line[index + 1];
      if (top.kind === 'single' || top.kind === 'ansi') {
        if (top.kind === 'ansi' && char === '\\' && next !== undefined) {
          code += '  ';
          index += 1;
        } else if (char === "'") {
          stack.pop();
          code += char;
        } else {
          code += ' ';
        }
        continue;
      }
      if (top.kind === 'double') {
        if (char === '\\' && next !== undefined) {
          code += '  ';
          index += 1;
          continue;
        }
        if (char === '"') {
          stack.pop();
          code += char;
          continue;
        }
        if (char === '$' && next === '(') {
          stack.push({ kind: 'code', depth: 0, closer: ')' });
          code += '$(';
          index += 1;
          continue;
        }
        if (char === '`') {
          stack.push({ kind: 'code', depth: 0, closer: '`' });
          code += char;
          continue;
        }
        const expansion = /^\$(?:\{[^}"]*\}|[A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-])/.exec(line.slice(index));
        if (expansion) {
          code += expansion[0];
          index += expansion[0].length - 1;
          continue;
        }
        code += ' ';
        continue;
      }
      if (char === '\\' && next !== undefined) {
        code += char + next;
        index += 1;
        continue;
      }
      if (char === '`' && top.closer === '`') {
        stack.pop();
        code += char;
        continue;
      }
      if (char === "'") {
        stack.push({ kind: 'single' });
        code += char;
        continue;
      }
      if (char === '$' && next === "'") {
        stack.push({ kind: 'ansi' });
        code += "$'";
        index += 1;
        continue;
      }
      if (char === '"') {
        stack.push({ kind: 'double' });
        code += char;
        continue;
      }
      if (char === '`') {
        stack.push({ kind: 'code', depth: 0, closer: '`' });
        code += char;
        continue;
      }
      if (char === '#' && (index === 0 || /[\s;&|()]/.test(line[index - 1]))) {
        end = index;
        break;
      }
      if (char === '$' && next === '(') {
        stack.push({ kind: 'code', depth: 0, closer: ')' });
        code += '$(';
        index += 1;
        continue;
      }
      if (top.closer === ')' && char === '(') top.depth += 1;
      if (top.closer === ')' && char === ')') {
        if (top.depth === 0) {
          stack.pop();
          code += char;
          continue;
        }
        top.depth -= 1;
      }
      if (char === '<' && next === '<' && line[index + 2] !== '<') {
        const marker = /^<<(-?)[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\2/.exec(line.slice(index));
        if (marker) {
          opened = { strip: marker[1] === '-', word: marker[3] };
          code += marker[0];
          index += marker[0].length - 1;
          continue;
        }
      }
      code += char;
    }
    result.push({ code, text: line.slice(0, end) });
    if (opened) heredoc = opened;
  }
  return result;
}

function runsScript(lines, relative) {
  const names = new Set();
  for (const { code, text } of lines) {
    const assigned = ASSIGNMENT.exec(code);
    if (assigned && text.slice(assigned[0].length).includes(relative)) names.add(assigned[1]);
  }
  return lines.some(({ code, text }) => {
    const call = SHELL_CALL.exec(code);
    if (!call) return false;
    const rest = text.slice(call.index + call[0].length);
    return rest.includes(relative) || [...names].some((name) => new RegExp(`\\$\\{?${name}(?![A-Za-z0-9_])`).test(rest));
  });
}

function driverProblems(root, registryFile) {
  const { entries, errors } = loadRegistry(root, registryFile);
  if (errors.length) return errors;
  const manifest = readManifest(root);
  const ciSuites = new Set(manifest.ciStructureTests.map((name) => `tests/structure/${name}`));
  const drivers = new Map();
  for (const entry of entries) {
    for (const run of entry.runs) {
      if (!drivers.has(run.driver)) drivers.set(run.driver, new Set());
      drivers.get(run.driver).add(entry.path);
    }
  }
  const problems = [];
  const sources = new Map();
  const read = (relative) => {
    if (!sources.has(relative)) sources.set(relative, fs.readFileSync(path.join(root, relative), 'utf8'));
    return sources.get(relative);
  };
  const lexed = new Map();
  const shell = (relative) => {
    if (!lexed.has(relative)) lexed.set(relative, shellLines(read(relative)));
    return lexed.get(relative);
  };
  for (const [driver, files] of drivers) {
    const source = read(driver);
    const lines = shell(driver);
    const reachedBy = ciSuites.has(driver)
      ? driver
      : [...ciSuites].find((suite) => runsScript(shell(suite), driver.slice('tests/'.length)));
    if (!reachedBy) problems.push(`${driver}: no CI structure suite runs it; add it to ciStructureTests or run it with bash from one`);
    const sourced = lines.some(({ code, text }) => {
      const call = SOURCE_CALL.exec(code);
      return Boolean(call) && /lib-unit-registry\.sh/.test(text.slice(call.index + call[0].length));
    });
    if (!sourced) problems.push(`${driver}: does not source tests/structure/lib-unit-registry.sh`);
    for (const file of files) {
      if (!source.includes(path.posix.basename(file))) problems.push(`${driver}: never names ${file}, which the registry says it runs`);
    }
    if (!lines.some(({ code }) => DONE_CALL.test(code))) problems.push(`${driver}: never calls unit_registry_done or unit_check_done`);
    const firstUnit = lines.findIndex(({ code }) => UNIT_CALL.test(code));
    if (firstUnit >= 0) {
      const early = lines.slice(0, firstUnit).findIndex(({ code }) => EARLY_EXIT.test(code));
      if (early >= 0) problems.push(`${driver}: "${lines[early].text.trim()}" at line ${early + 1} comes before its first unit call at line ${firstUnit + 1}; drive the unit files first`);
    }
  }
  const scanned = new Set([
    ...fs.readdirSync(path.join(root, 'tests/structure')).filter((name) => /^test-.*\.sh$/.test(name)).map((name) => `tests/structure/${name}`),
    ...drivers.keys(),
  ]);
  for (const suite of [...scanned].sort()) {
    const lines = shell(suite);
    const spawns = lines.filter(({ code }) => NODE_TEST_SPAWN.test(code)).length;
    const grades = lines.filter(({ code }) => GRADE_CALL.test(code)).length;
    if (spawns > grades) problems.push(`${suite}: spawns node --test itself ${spawns} time(s) but calls unit_grade ${grades} time(s); run unit files through unit_run, or grade each run through unit_grade`);
  }
  return problems;
}

function parseArgs(argv) {
  const options = { positional: [] };
  const flags = new Set(['--check', '--write']);
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--') {
      options.positional = argv.slice(index + 1);
      break;
    }
    if (flags.has(arg)) {
      options[arg.slice(2)] = true;
    } else if (arg.startsWith('--')) {
      if (index + 1 >= argv.length) throw new Error(`${arg} needs a value`);
      options[arg.slice(2)] = argv[index + 1];
      index += 1;
    } else {
      throw new Error(`unexpected argument ${arg}`);
    }
  }
  return options;
}

function main(argv, out = process.stdout) {
  const [command, ...rest] = argv;
  let options;
  try {
    options = parseArgs(rest);
  } catch (error) {
    out.write(`lib-unit-registry: ${error.message}\n`);
    return exitCodes.plumbing;
  }
  const root = path.resolve(options.root || path.join(__dirname, '..', '..'));
  const registryFile = options.registry ? path.resolve(options.registry) : null;
  const report = (problems) => {
    for (const problem of problems) out.write(`${problem}\n`);
    return problems.length ? exitCodes.verdict : exitCodes.pass;
  };
  if (command === 'census') return report(census(root, registryFile));
  if (command === 'drivers') return report(driverProblems(root, registryFile));
  if (command === 'render') {
    const rendered = render(root, registryFile);
    if (rendered.errors.length) return report(rendered.errors);
    const overviewFile = options.overview ? path.resolve(options.overview) : path.join(root, OVERVIEW_REL);
    const overview = fs.readFileSync(overviewFile, 'utf8');
    if (options.write) {
      const written = writeOverview(overview, rendered.regions);
      if (written.problems.length) return report(written.problems);
      fs.writeFileSync(overviewFile, written.text);
      return exitCodes.pass;
    }
    return report(checkOverview(root, rendered.regions, overview));
  }
  if (command === 'verify' || command === 'owned') {
    const { entries, errors } = loadRegistry(root, registryFile);
    if (errors.length) {
      out.write(`${errors.join('; ')}\n`);
      return exitCodes.plumbing;
    }
    const driver = options.driver ? toRepoPath(root, options.cwd, options.driver) : null;
    if (!driver) {
      out.write(`lib-unit-registry: the calling driver ${options.driver || '(none)'} is not a file inside ${root}\n`);
      return exitCodes.plumbing;
    }
    const mode = options.mode || '';
    if (command === 'owned') {
      const graded = new Set(options.positional.map((given) => toRepoPath(root, options.cwd, given)).filter(Boolean));
      const missing = owned(entries, driver, mode).filter((unitPath) => !graded.has(unitPath));
      if (missing.length === 0) {
        out.write(`${driver}${mode ? ` mode ${mode}` : ''}: every unit file it is registered for was graded\n`);
        return exitCodes.pass;
      }
      out.write(`${driver}${mode ? ` mode ${mode}` : ''}: never ran or graded ${missing.join(', ')}, which the registry says it runs\n`);
      return exitCodes.verdict;
    }
    const unitPath = options.path ? toRepoPath(root, options.cwd, options.path) : null;
    const entry = unitPath && entries.find((candidate) => candidate.path === unitPath);
    if (!entry) {
      out.write(`${unitPath || options.path || '(no path)'}: no entry in ${REGISTRY_REL}; add one\n`);
      return exitCodes.plumbing;
    }
    if (!runsFor(entry, driver, mode)) {
      out.write(`${unitPath}: ${driver}${mode ? ` mode ${mode}` : ''} is not a registered driver of this file; add it to the entry's runs in ${REGISTRY_REL}\n`);
      return exitCodes.plumbing;
    }
    let text;
    try {
      text = fs.readFileSync(options.output, 'utf8');
    } catch (error) {
      out.write(`${unitPath}: the captured output is unreadable (${error.code || error.message})\n`);
      return exitCodes.plumbing;
    }
    let staticCount = null;
    try {
      staticCount = staticRegistrations(fs.readFileSync(path.join(root, unitPath), 'utf8'));
    } catch {
      staticCount = null;
    }
    const rc = Number(options.rc);
    const verdict = verify(entry, text, Number.isInteger(rc) ? rc : -1, options.host || hostClass(), staticCount);
    out.write(`${verdict.message}\n`);
    return verdict.ok ? exitCodes.pass : exitCodes.verdict;
  }
  out.write('usage: lib-unit-registry.js census|drivers|render --check|render --write|verify|owned [--root <dir>] [--registry <file>]\n');
  return exitCodes.plumbing;
}

module.exports = {
  REGISTRY_REL,
  RENDER_COMMAND,
  HOST_CLASSES,
  hostClass,
  loadRegistry,
  walkUnitFiles,
  census,
  parseTap,
  verify,
  render,
  checkOverview,
  writeOverview,
  driverProblems,
  shellLines,
  owned,
  main,
};

if (require.main === module) process.exitCode = main(process.argv.slice(2));
