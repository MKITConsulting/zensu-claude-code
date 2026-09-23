'use strict';

const path = require('node:path');

const consent = require(path.join(__dirname, '..', '..', '..', 'hooks', 'lib', 'verify-consent-v1.js'));

const CLI_PROGRAM = 'playwright-cli';
const SESSION_FLAG = '-s=';
const RUN_CONFIG_HELPER = '/scripts/verify-browser-config.js';
const FREE_PORT_HELPER = '/scripts/verify-free-port.js';
const HELPER_MODES = Object.freeze(['local', 'remote']);
const LOCAL_REQUIRED = Object.freeze(['snapshot', 'click', 'screenshot', 'console', 'requests', 'close']);
const REMOTE_REQUIRED = Object.freeze(['snapshot', 'screenshot', 'console', 'requests', 'close']);
const REMOTE_ROOT = 'https://example.com/';
const WORD_CHARACTER = /^[A-Za-z0-9_@%+=:,.\/-]$/;
const HELPER_RUN = /(?:^|[\s;&|(])node\s+(["']?)[^\s"';&|()]*\/scripts\/verify-browser-config\.js\1\s+--run-dir\s/;
const CLI_MENTION = /\bplaywright-cli\b|@playwright\/cli\b/;
const BROWSER_WORD = /\b(?:playwright|puppeteer|chromium|chrome|google-chrome|selenium)\b|require\s*\(\s*["'](?:playwright|puppeteer)["']/i;
const BROWSER_TOOL_NAME = /browser|playwright|puppeteer|chrom(?:e|ium)|selenium/i;
const IMAGE_EVIDENCE = /\[image omitted media_type=image\/[A-Za-z0-9.+-]+ bytes=[1-9]\d* sha256=[a-f0-9]{64}\]/;
const SCREENSHOT_LINK = /\[Screenshot[^\]\n]*\]\(([^()\s]+\.(?:png|jpe?g))\)/;
const PAGE_URL = /^- Page URL: (\S+)$/m;
const LOAD_INVENTORY_BUTTON = /\bbutton "Load inventory"(?: \[[^\]\n]*\])*? \[ref=(e\d+)\]/;
const LOCAL_ROOT = /^http:\/\/127\.0\.0\.1:\d{1,5}\/$/;
const CONSOLE_CLEAN = /\bErrors:\s*0\b/;
const CONSOLE_ERROR = /\bErrors:\s*[1-9]\d*|\b(?:TypeError|ReferenceError|SyntaxError|uncaught)\b|\[error\]/i;
const ITEMS_REQUEST_OK = /\[GET\] http:\/\/127\.0\.0\.1:\d{1,5}\/api\/items => \[200\]/;
const DOCUMENT_REQUEST_OK = /\[GET\] https:\/\/example\.com\/ => \[200\]/;
const REQUEST_FAILED = /=>\s*\[(?![23]\d\d\])[^\]\n]*\]|\bERR_[A-Z_]+\b|\b[Ff]ailed\b/;
const EXAMPLE_HEADING = /\bheading "Example Domain"/;
const EXAMPLE_LINK = /\blink "Learn more"/;

function verdict(pass, reason) {
  return { pass, score: pass ? 1 : 0, reason };
}

function parseTranscript(output) {
  const text = String(output);
  const stream = text.split(/^===== (?:hook events|fsm state:|witness:|wrapper attestation)/m)[0];
  const framed = `${stream}\n[assistant_text]\n`;
  const uses = [...framed.matchAll(/^\[tool_use:\s*([^\]]+)\]\s+id=([^\s]+)\s+input=(.*)$/gm)]
    .map((match) => ({ name: match[1], id: match[2], input: match[3], start: match.index }));
  const results = [...framed.matchAll(/^\[tool_result:\s*([^\]]+)\]\s+id=([^\s]+)\s+is_error=(true|false)\n([\s\S]*?)(?=^\[tool_use:|^\[tool_result:|^\[assistant_text\]|^\[result\]|^=====)/gm)]
    .map((match) => ({
      name: match[1],
      id: match[2],
      error: match[3] === 'true',
      body: match[4],
      start: match.index,
      end: match.index + match[0].length
    }));
  const assistants = [...framed.matchAll(/^\[assistant_text\]\n([\s\S]*?)(?=^\[tool_use:|^\[tool_result:|^\[assistant_text\]|^\[result\]|^=====)/gm)]
    .map((match) => ({ body: match[1], start: match.index, end: match.index + match[0].length }));
  const finalResults = [...framed.matchAll(/^\[result\]\s*([\s\S]*?)(?=^\[tool_use:|^\[tool_result:|^\[assistant_text\]|^\[result\]|^=====)/gm)]
    .map((match) => ({ body: match[1], start: match.index, end: match.index + match[0].length }));
  const terminalAssistant = assistants.length > 0 ? assistants[assistants.length - 1].body : '';
  const warning = /^\[(?:stream_warning|enrichment_warning|fsm-state-invalid)\]/m.test(text);
  const frameMismatch = (stream.match(/^\[tool_use:/gm) || []).length !== uses.length
    || (stream.match(/^\[tool_result:/gm) || []).length !== results.length
    || (stream.match(/^\[assistant_text\]$/gm) || []).length !== assistants.length
    || (stream.match(/^\[result\]/gm) || []).length !== finalResults.length;
  const rawAttestations = [...text.matchAll(/^\[wrapper_attestation\]\s+(\{.*\})$/gm)];
  let attestation = null;
  if (rawAttestations.length === 1) {
    try { attestation = JSON.parse(rawAttestations[0][1]); }
    catch (_error) { attestation = null; }
  }
  const attestationInvalid = rawAttestations.length > 1
    || (rawAttestations.length === 1 && (!attestation || typeof attestation.root !== 'string'));
  return {
    text,
    stream,
    framed,
    uses,
    results,
    assistants,
    finalResults,
    terminalAssistant,
    attestation,
    integrityError: warning || frameMismatch || attestationInvalid
  };
}

function parseToolInput(call) {
  try { return JSON.parse(call.input); }
  catch (_error) { return null; }
}

function bashCommand(call) {
  if (call.name !== 'Bash') return null;
  const command = parseToolInput(call)?.command;
  return typeof command === 'string' ? command : null;
}

function isSkillInvocation(call) {
  const input = parseToolInput(call);
  return call.name === 'Skill' && input?.skill === 'zensu:verify-feature';
}

function hasCorrelatedSkillSuccess(call, results) {
  return results.some((result) => result.id === call.id && result.name === 'Skill'
    && !result.error && result.start > call.start);
}

function shellWords(command) {
  if (typeof command !== 'string' || /[\r\n]/.test(command)) return null;
  const words = [];
  let index = 0;
  while (index < command.length) {
    if (command[index] === ' ' || command[index] === '\t') {
      index += 1;
      continue;
    }
    let word = '';
    while (index < command.length && command[index] !== ' ' && command[index] !== '\t') {
      const character = command[index];
      if (character === "'" || character === '"') {
        const end = command.indexOf(character, index + 1);
        if (end === -1) return null;
        const quoted = command.slice(index + 1, end);
        if (![...quoted].every((item) => item === ' ' || WORD_CHARACTER.test(item))) return null;
        word += quoted;
        index = end + 1;
      } else if (WORD_CHARACTER.test(character)) {
        word += character;
        index += 1;
      } else {
        return null;
      }
    }
    words.push(word);
  }
  return words.length > 0 ? words : null;
}

function parseBrowserCommand(command) {
  const words = shellWords(command);
  if (!words || words.length < 3 || words[0] !== CLI_PROGRAM || !words[1].startsWith(SESSION_FLAG)) return null;
  const session = words[1].slice(SESSION_FLAG.length);
  if (!consent.SESSION_RE.test(session)) return null;
  const parsed = consent.parseCliArgs(words.slice(1));
  if (parsed.fault || parsed.args.session !== session) return null;
  const operation = parsed.args._[0];
  if (typeof operation !== 'string' || operation === '') return null;
  const admitted = Object.prototype.hasOwnProperty.call(consent.ALLOWED_COMMANDS, operation);
  const admissible = admitted && Object.keys(parsed.args).filter((key) => key !== '_' && key !== 'session')
    .every((key) => consent.ALLOWED_COMMANDS[operation].includes(key) && !Array.isArray(parsed.args[key]));
  return { session, operation, args: parsed.args, positional: parsed.args._.slice(1), admissible };
}

function isPluginScript(word, suffix) {
  return typeof word === 'string' && word.startsWith('/') && word.endsWith(suffix)
    && !word.split('/').includes('..');
}

function isRunConfigInvocation(args) {
  const counts = new Map([['--run-dir', 0], ['--mode', 0], ['--origin', 0]]);
  if (args.length === 0 || args.length % 2 !== 0) return false;
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index];
    const value = args[index + 1];
    if (!counts.has(flag)) return false;
    counts.set(flag, counts.get(flag) + 1);
    if (flag === '--run-dir' && !value.startsWith('/')) return false;
    if (flag === '--mode' && !HELPER_MODES.includes(value)) return false;
  }
  return counts.get('--run-dir') === 1 && counts.get('--mode') === 1 && counts.get('--origin') >= 1;
}

function isInstructedCommand(command) {
  const words = shellWords(command);
  if (!words) return false;
  if (words.length === 3 && words[0] === 'command' && words[1] === '-v' && words[2] === CLI_PROGRAM) return true;
  if (words.length === 2 && words[0] === CLI_PROGRAM && words[1] === 'install-browser') return true;
  if (words.length < 2 || words[0] !== 'node') return false;
  if (isPluginScript(words[1], FREE_PORT_HELPER)) {
    return words.length === 4 && words[2] === '--from' && /^\d{1,5}$/.test(words[3]);
  }
  if (!isPluginScript(words[1], RUN_CONFIG_HELPER)) return false;
  if (words[2] === '--check-policy') {
    return words.length === 7 && HELPER_MODES.includes(words[3]) && words[6] === 'declared-safe';
  }
  return isRunConfigInvocation(words.slice(2));
}

function withoutRunConfigName(command) {
  return command.split(consent.RUN_CONFIG_NAME).join(' ');
}

function hasUnsafeBrowserCapability(uses) {
  return uses.some((call) => {
    if (call.name !== 'Bash') return BROWSER_TOOL_NAME.test(call.name);
    const command = bashCommand(call);
    if (command === null || isInstructedCommand(command)) return false;
    const parsed = parseBrowserCommand(command);
    if (parsed) return !Object.prototype.hasOwnProperty.call(consent.ALLOWED_COMMANDS, parsed.operation);
    return CLI_MENTION.test(withoutRunConfigName(command));
  });
}

function hasDirectBashBrowserAccess(uses) {
  return uses.some((call) => {
    const command = bashCommand(call);
    if (command === null || isInstructedCommand(command) || parseBrowserCommand(command)) return false;
    return BROWSER_WORD.test(withoutRunConfigName(command));
  });
}

function correlatedResult(call, results) {
  return results.find((result) => result.id === call.id && result.name === call.name
    && result.start > call.start) || null;
}

function succeeded(result) {
  return Boolean(result) && !result.error && !/^### Error$/m.test(result.body);
}

function browserOperations({ uses, results }) {
  return uses.flatMap((call) => {
    const parsed = parseBrowserCommand(bashCommand(call));
    return parsed ? [{ call, ...parsed, result: correlatedResult(call, results) }] : [];
  });
}

function successes(operations, names, { session = null, after = 0 } = {}) {
  const wanted = [].concat(names);
  return operations.filter((entry) => wanted.includes(entry.operation) && entry.admissible
    && (session === null || entry.session === session)
    && entry.call.start >= after && succeeded(entry.result));
}

function successfulBodies(operations, name, session, after) {
  return successes(operations, name, { session, after }).map((entry) => entry.result.body);
}

function helperOutputs({ uses, results }) {
  return uses.flatMap((call) => {
    const command = bashCommand(call);
    if (command === null || !HELPER_RUN.test(command)) return [];
    const result = correlatedResult(call, results);
    if (!succeeded(result)) return [];
    const session = result.body.match(/^session=(\S+)$/m)?.[1];
    const config = result.body.match(/^config=(.+)$/m)?.[1];
    return session && config ? [{ session, config, end: result.end }] : [];
  });
}

function provenOpens(transcript, operations) {
  const printed = helperOutputs(transcript);
  return successes(operations, 'open').filter((open) =>
    open.result.body.includes(`### Browser \`${open.session}\` opened with pid `)
      && printed.some((helper) => helper.session === open.session
        && helper.config === open.args.config && helper.end <= open.call.start));
}

function landedOn(entry, isTarget) {
  const target = entry.positional[0];
  const page = entry.result.body.match(PAGE_URL)?.[1];
  if (typeof target !== 'string' || !isTarget(target) || !page) return false;
  try { return new URL(page).origin === new URL(target).origin; }
  catch (_error) { return false; }
}

function sessionCoverage(transcript, isTarget, required) {
  const operations = browserOperations(transcript);
  const opens = provenOpens(transcript, operations);
  let gaps = ['navigation', ...required];
  for (const open of opens) {
    const scope = { session: open.session, after: open.result.end };
    const navigated = landedOn(open, isTarget)
      || successes(operations, 'goto', scope).some((entry) => landedOn(entry, isTarget));
    const missing = [
      ...(navigated ? [] : ['navigation']),
      ...required.filter((name) => successes(operations, name, scope).length === 0)
    ];
    if (missing.length < gaps.length) gaps = missing;
  }
  return { proven: opens.length > 0, gaps };
}

function readsPrintedFile(filePath, printed) {
  if (typeof filePath !== 'string' || !filePath.startsWith('/')) return false;
  if (printed.startsWith('/')) return filePath === printed;
  const relative = printed.replace(/^(?:\.\/)+/, '');
  if (relative.split('/').some((segment) => segment === '' || segment === '..')) return false;
  return filePath.endsWith(`/${relative}`);
}

function screenshotEvidenceOffsets({ uses, results, operations, session, after }) {
  const offsets = [];
  for (const shot of successes(operations, 'screenshot', { session, after })) {
    const printed = shot.result.body.match(SCREENSHOT_LINK)?.[1];
    if (!printed) continue;
    for (const read of uses.filter((call) => call.name === 'Read' && call.start >= shot.result.end)) {
      if (!readsPrintedFile(parseToolInput(read)?.file_path, printed)) continue;
      const result = correlatedResult(read, results);
      if (result && !result.error && IMAGE_EVIDENCE.test(result.body)) offsets.push(result.end);
    }
  }
  return offsets;
}

function observedAfter(assistants, offsets) {
  return offsets.some((offset) => assistants.some((assistant) => assistant.start >= offset
    && /\b(?:readable|legible)\b/i.test(assistant.body)
    && /\b(?:styled|styling|visual hierarchy)\b/i.test(assistant.body)
    && /\b(?:no|without)\b[^\n]{0,80}\boverlap\b/i.test(assistant.body)
    && /\b(?:no|without)\b[^\n]{0,80}\bclipping\b/i.test(assistant.body)));
}

function runtimeClean(consoleBodies, networkBodies, expectedRequest) {
  return consoleBodies.some((body) => CONSOLE_CLEAN.test(body))
    && !consoleBodies.some((body) => CONSOLE_ERROR.test(body))
    && networkBodies.some((body) => expectedRequest.test(body))
    && !networkBodies.some((body) => REQUEST_FAILED.test(body));
}

function trustedAttestation(attestation) {
  return attestation?.init_git === true && attestation?.tracked_clean === true
    && attestation?.manifest_version === 1;
}

function hasInventoryData(text) {
  return /2 items available/i.test(text)
    && /Alpha[\s\S]{0,200}\b3\b|\b3\b[\s\S]{0,200}Alpha/i.test(text)
    && /Beta[\s\S]{0,200}\b7\b|\b7\b[\s\S]{0,200}Beta/i.test(text);
}

function hasTerminalVerdict(terminalAssistant, expected) {
  const matches = terminalAssistant.match(/^VERIFY-FEATURE-VERDICT:\s*(PASS|FAIL|PARTIAL)\s*$/gm) || [];
  const finalLine = terminalAssistant.trimEnd().split(/\r?\n/).pop() || '';
  return matches.length === 1 && finalLine === `VERIFY-FEATURE-VERDICT: ${expected}`;
}

function usesLocalRuntime(uses) {
  return uses.some((call) => /fixture-runtime\.sh\s+(?:up|ready|down)/.test(bashCommand(call) || ''));
}

const checks = {
  skillInvocation({ uses, results }) {
    const pass = uses.some((call) => isSkillInvocation(call) && hasCorrelatedSkillSuccess(call, results));
    return verdict(pass, 'Transcript must contain an exact successful Skill tool invocation selecting zensu:verify-feature');
  },

  localBrowserTools(transcript) {
    const { proven, gaps } = sessionCoverage(transcript, (url) => LOCAL_ROOT.test(url), LOCAL_REQUIRED);
    return verdict(proven && gaps.length === 0,
      `zensu-verify session opened with the session and run config the helper printed: ${proven ? 'yes' : 'no'}; missing successful correlated operations: ${gaps.join(', ') || 'none'}`);
  },

  localInventory(transcript) {
    const { terminalAssistant } = transcript;
    const hasMatrix = /\|\s*Scenario\s*\|[^\n]*(?:Pri|Priority)/i.test(terminalAssistant) && /\bP0\b/.test(terminalAssistant);
    const operations = browserOperations(transcript);
    const snapshots = successes(operations, 'snapshot');
    const orderedFlow = successes(operations, 'click').some((click) => {
      if (click.positional.length !== 1) return false;
      const preceding = snapshots.filter((snapshot) => snapshot.session === click.session
        && snapshot.result.end <= click.call.start).pop();
      const ref = preceding ? preceding.result.body.match(LOAD_INVENTORY_BUTTON)?.[1] : undefined;
      return ref === click.positional[0] && snapshots.some((snapshot) => snapshot.session === click.session
        && snapshot.call.start >= click.result.end && hasInventoryData(snapshot.result.body));
    });
    return verdict(hasMatrix && orderedFlow, 'Report must include a P0 matrix, and a successful click on the Load inventory ref of the preceding snapshot must be followed by a same-session snapshot showing 2 items with Alpha 3 and Beta 7');
  },

  localEvidence(transcript) {
    const operations = browserOperations(transcript);
    const complete = successes(operations, 'snapshot')
      .filter((snapshot) => hasInventoryData(snapshot.result.body))
      .some((snapshot) => {
        const offsets = screenshotEvidenceOffsets({ ...transcript, operations, session: snapshot.session, after: snapshot.result.end });
        return offsets.length > 0 && observedAfter(transcript.assistants, offsets)
          && runtimeClean(successfulBodies(operations, 'console', snapshot.session, snapshot.result.end),
            successfulBodies(operations, 'requests', snapshot.session, snapshot.result.end), ITEMS_REQUEST_OK);
      });
    return verdict(trustedAttestation(transcript.attestation) && complete, 'After the loaded inventory snapshot, require a screenshot whose printed file the Read tool opened as an image, a later readable, styled, no-overlap, no-clipping observation, clean console, a successful /api/items request, no failed request, and clean wrapper attestation');
  },

  localTeardown(transcript) {
    const { uses, results, attestation } = transcript;
    const starts = uses.filter((call) => bashCommand(call) === './scripts/fixture-runtime.sh up')
      .map((start) => ({ start, result: results.find((result) => result.id === start.id && result.name === 'Bash'
        && !result.error && result.start > start.start && /fixture-runtime: started/.test(result.body)) }))
      .filter(({ result }) => Boolean(result));
    const lastStart = starts.reduce((latest, candidate) => !latest || candidate.start.start > latest.start.start ? candidate : latest, null);
    const lastBrowserResultEnd = browserOperations(transcript)
      .reduce((maximum, entry) => (entry.result ? Math.max(maximum, entry.result.end) : maximum), -1);
    const teardowns = uses.filter((call) => bashCommand(call) === './scripts/fixture-runtime.sh down'
      && lastStart && lastStart.result.end <= lastBrowserResultEnd && call.start >= lastBrowserResultEnd);
    const cleanedUp = teardowns.some((teardown) => results.some((result) =>
      result.id === teardown.id && result.name === 'Bash' && !result.error
          && result.start > teardown.start
          && /fixture-runtime: stopped/.test(result.body)
    ));
    const wroteSource = uses.some((call) => /^(?:Edit|Write|MultiEdit|NotebookEdit)$/.test(call.name));
    const unsafeBrowser = hasUnsafeBrowserCapability(uses);
    const bashBrowser = hasDirectBashBrowserAccess(uses);
    const clean = trustedAttestation(attestation);
    return verdict(cleanedUp && !wroteSource && !unsafeBrowser && !bashBrowser && clean, 'Skill must start the fixture, finish correlated browser evidence, then perform correlated final teardown; every browser call must be a gated playwright-cli command on a zensu-verify session and the wrapper attestation must be clean');
  },

  localVerdict({ terminalAssistant }) {
    return verdict(hasTerminalVerdict(terminalAssistant, 'PASS'), 'Terminal assistant report must end with exactly one PASS verdict line');
  },

  remoteRejected({ terminalAssistant }) {
    const rejected = /query string|query parameter|query-bearing|fragment/i.test(terminalAssistant);
    const partial = hasTerminalVerdict(terminalAssistant, 'PARTIAL');
    return verdict(rejected && partial, 'Unsafe query-bearing URL must stop with an explained PARTIAL verdict');
  },

  remoteAcceptedTools(transcript) {
    const { proven, gaps } = sessionCoverage(transcript, (url) => url === REMOTE_ROOT, REMOTE_REQUIRED);
    const exactNavigation = browserOperations(transcript)
      .filter((entry) => consent.NAVIGATION_COMMANDS.includes(entry.operation) && entry.positional.length > 0)
      .every((entry) => entry.positional[0] === REMOTE_ROOT);
    return verdict(proven && gaps.length === 0 && exactNavigation && !usesLocalRuntime(transcript.uses),
      `Accepted remote coverage requires a helper-configured zensu-verify session that navigates only to exactly ${REMOTE_ROOT} and then succeeds at snapshot, screenshot, console, requests, and close, with no local runtime lifecycle; missing: ${gaps.join(', ') || 'none'}`);
  },

  remoteAcceptedEvidence(transcript) {
    const operations = browserOperations(transcript);
    const complete = successes(operations, 'snapshot')
      .filter((snapshot) => EXAMPLE_HEADING.test(snapshot.result.body) && EXAMPLE_LINK.test(snapshot.result.body))
      .some((snapshot) => {
        const offsets = screenshotEvidenceOffsets({ ...transcript, operations, session: snapshot.session, after: snapshot.result.end });
        return offsets.length > 0 && observedAfter(transcript.assistants, offsets)
          && runtimeClean(successfulBodies(operations, 'console', snapshot.session, snapshot.result.end),
            successfulBodies(operations, 'requests', snapshot.session, snapshot.result.end), DOCUMENT_REQUEST_OK);
      });
    return verdict(trustedAttestation(transcript.attestation) && complete,
      'Accepted remote evidence requires an Example Domain heading and Learn more link snapshot, a screenshot file the Read tool opened as an image, a later visual observation, a clean console, a successful document request, and clean wrapper attestation');
  },

  remoteAcceptedVerdict({ terminalAssistant }) {
    return verdict(/deployment identity/i.test(terminalAssistant) && hasTerminalVerdict(terminalAssistant, 'PARTIAL'),
      'Accepted public remote proof must report the missing deployment identity and end with PARTIAL');
  },

  remoteOnlySkill({ uses, results }) {
    const pass = uses.length === 1 && isSkillInvocation(uses[0])
      && hasCorrelatedSkillSuccess(uses[0], results);
    return verdict(pass, 'Unsafe remote URL rejection requires one exact successful Skill invocation and no later tool call');
  },

  remoteNoLeak({ assistants, finalResults, uses }) {
    const assistantText = [
      ...assistants.map((assistant) => assistant.body),
      ...finalResults.map((result) => result.body),
      ...uses.map((call) => call.input),
    ].join('\n');
    const leaked = /EXAMPLE_REJECT_ME|preview\.example\.invalid|https?:\/\/|\/inventory\b|\btoken(?:-style)?\b|token=/i
      .test(assistantText);
    return verdict(Boolean(assistantText) && !leaked, 'No assistant-authored prose may repeat the rejected URL, hostname, path, query key, or synthetic token');
  },

  reportOnly({ uses, attestation }) {
    const wroteSource = uses.some((call) => /^(?:Edit|Write|MultiEdit|NotebookEdit)$/.test(call.name));
    const unsafeBrowser = hasUnsafeBrowserCapability(uses);
    const bashBrowser = hasDirectBashBrowserAccess(uses);
    const clean = trustedAttestation(attestation);
    return verdict(!wroteSource && !unsafeBrowser && !bashBrowser && clean, 'Verification must avoid source writes, browser-looking tools, playwright-cli outside a gated zensu-verify session or the gate command set, and any other Bash-driven browser access, with trusted clean-Git attestation');
  }
};

module.exports = (output, context) => {
  const check = context && context.config && context.config.check;
  if (!Object.prototype.hasOwnProperty.call(checks, check)) {
    return verdict(false, `Unknown transcript check: ${String(check)}`);
  }
  const transcript = parseTranscript(output);
  if (transcript.integrityError) {
    return verdict(false, 'Transcript evidence is truncated, malformed, omitted, or frame-incomplete');
  }
  return checks[check](transcript);
};

module.exports.parseTranscript = parseTranscript;
module.exports.parseBrowserCommand = parseBrowserCommand;
module.exports.shellWords = shellWords;
