'use strict';

const BROWSER_NAMESPACES = Object.freeze(['mcp__playwright__', 'mcp__plugin_zensu_playwright__']);
const SAFE_BROWSER_OPERATIONS = new Set([
  'browser_click', 'browser_close', 'browser_console_messages', 'browser_drag', 'browser_fill_form',
  'browser_handle_dialog', 'browser_hover', 'browser_navigate', 'browser_network_requests',
  'browser_press_key', 'browser_resize', 'browser_select_option', 'browser_snapshot', 'browser_tabs',
  'browser_take_screenshot', 'browser_type', 'browser_wait_for'
]);

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

function isSkillInvocation(call) {
  const input = parseToolInput(call);
  return call.name === 'Skill' && input?.skill === 'zensu:verify-feature';
}

function hasCorrelatedSkillSuccess(call, results) {
  return results.some((result) => result.id === call.id && result.name === 'Skill'
    && !result.error && result.start > call.start);
}

function parseToolInput(call) {
  try { return JSON.parse(call.input); }
  catch (_error) { return null; }
}

function isBrowserOperation(name, operation) {
  return BROWSER_NAMESPACES.some((namespace) => name === `${namespace}${operation}`);
}

function browserOperation(name) {
  const namespace = BROWSER_NAMESPACES.find((candidate) => name.startsWith(candidate));
  return namespace ? name.slice(namespace.length) : null;
}

function hasUnsafeBrowserCapability(uses) {
  return uses.some((call) => {
    const operation = browserOperation(call.name);
    if (operation !== null) return !SAFE_BROWSER_OPERATIONS.has(operation);
    return /browser_|playwright|puppeteer|chrom(?:e|ium)|selenium/i.test(call.name);
  });
}

function hasDirectBashBrowserAccess(uses) {
  return uses.some((call) => {
    if (call.name !== 'Bash') return false;
    const command = parseToolInput(call)?.command;
    if (typeof command !== 'string') return false;
    const launcher = String.raw`(?:"[^"\n]*playwright-mcp\.sh"|'[^'\n]*playwright-mcp\.sh'|[^\s;&|]*playwright-mcp\.sh)`;
    const argument = String.raw`(?:"[^"\n]+"|'[^'\n]+'|[^\s;&|]+)`;
    const safeInstall = new RegExp(`^\\s*bash\\s+${launcher}\\s+install-browser\\s*$`);
    const safeCheck = new RegExp(`^\\s*bash\\s+${launcher}\\s+--check-policy\\s+(?:local|remote)\\s+${argument}\\s+${argument}\\s+declared-safe\\s*$`);
    if (safeInstall.test(command) || safeCheck.test(command)) return false;
    return /\b(?:playwright|puppeteer|chromium|chrome|google-chrome|selenium)\b|require\s*\(\s*["'](?:playwright|puppeteer)["']/i.test(command);
  });
}

function correlatedSuccesses(uses, results, operation, after = 0) {
  return uses.filter((call) => isBrowserOperation(call.name, operation) && call.start >= after)
    .flatMap((call) => results.filter((result) => result.id === call.id
      && isBrowserOperation(result.name, operation) && !result.error && result.start > call.start));
}

function trustedAttestation(attestation) {
  return attestation?.init_git === true && attestation?.tracked_clean === true
    && attestation?.manifest_version === 1;
}

function screenshotEvidenceOffsets({ uses, results, after }) {
  const imageEvidence = /\[image omitted media_type=[^\s\]]+ bytes=[1-9]\d* sha256=[a-f0-9]{64}\]/;
  const offsets = [];
  for (const call of uses.filter((candidate) =>
    isBrowserOperation(candidate.name, 'browser_take_screenshot') && candidate.start >= after
  )) {
    const input = parseToolInput(call);
    if (!input || Object.prototype.hasOwnProperty.call(input, 'filename')) continue;
    const result = results.find((candidate) =>
      candidate.id === call.id && isBrowserOperation(candidate.name, 'browser_take_screenshot')
        && !candidate.error && candidate.start > call.start
    );
    if (result && imageEvidence.test(result.body)) offsets.push(result.end);
  }
  return offsets;
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

const checks = {
  skillInvocation({ uses, results }) {
    const pass = uses.some((call) => isSkillInvocation(call) && hasCorrelatedSkillSuccess(call, results));
    return verdict(pass, 'Transcript must contain an exact successful Skill tool invocation selecting zensu:verify-feature');
  },

  localBrowserTools({ uses, results }) {
    const required = [
      'browser_navigate',
      'browser_snapshot',
      'browser_click',
      'browser_take_screenshot',
      'browser_console_messages',
      'browser_network_requests',
      'browser_close'
    ];
    const selected = required.map((suffix) => ({
      suffix,
      calls: uses.filter((candidate) => isBrowserOperation(candidate.name, suffix))
    }));
    const missingCalls = selected.filter(({ calls }) => calls.length === 0).map(({ suffix }) => suffix);
    const missingResults = selected.filter(({ calls, suffix }) => calls.length > 0 && !calls.some((call) =>
      results.some((result) => result.id === call.id && isBrowserOperation(result.name, suffix)
        && !result.error && result.start > call.start)
    )).map(({ suffix }) => suffix);
    const pass = missingCalls.length === 0 && missingResults.length === 0;
    return verdict(pass, `Missing calls: ${missingCalls.join(', ') || 'none'}; missing successful correlated results: ${missingResults.join(', ') || 'none'}`);
  },

  localInventory({ terminalAssistant, uses, results }) {
    const hasMatrix = /\|\s*Scenario\s*\|[^\n]*(?:Pri|Priority)/i.test(terminalAssistant) && /\bP0\b/.test(terminalAssistant);
    const initialSnapshots = correlatedSuccesses(uses, results, 'browser_snapshot')
      .filter((result) => /Load inventory/i.test(result.body));
    const orderedFlow = initialSnapshots.some((initial) => {
      const click = uses.find((call) => isBrowserOperation(call.name, 'browser_click')
        && call.start >= initial.end && /Load inventory/i.test(call.input));
      if (!click) return false;
      const clickResult = results.find((result) => result.id === click.id
        && isBrowserOperation(result.name, 'browser_click') && !result.error && result.start > click.start);
      return Boolean(clickResult && correlatedSuccesses(uses, results, 'browser_snapshot', clickResult.end)
        .some((result) => hasInventoryData(result.body)));
    });
    return verdict(hasMatrix && orderedFlow, 'Report must include a P0 matrix and correlated initial Load inventory snapshot, successful button click, then loaded Alpha/Beta snapshot');
  },

  localEvidence({ uses, results, assistants, attestation }) {
    const loadedSnapshots = correlatedSuccesses(uses, results, 'browser_snapshot')
      .filter((result) => hasInventoryData(result.body));
    const evidenceComplete = loadedSnapshots.some((snapshot) => {
      const screenshotOffsets = screenshotEvidenceOffsets({ uses, results, root: attestation?.root, after: snapshot.end });
      const visualObservation = screenshotOffsets.some((offset) => assistants.some((assistant) =>
        assistant.start >= offset
          && /\b(?:readable|legible)\b/i.test(assistant.body)
          && /\b(?:styled|styling|visual hierarchy)\b/i.test(assistant.body)
          && /\b(?:no|without)\b[^\n]{0,80}\boverlap\b/i.test(assistant.body)
          && /\b(?:no|without)\b[^\n]{0,80}\bclipping\b/i.test(assistant.body)
      ));
      const consoleBodies = correlatedSuccesses(uses, results, 'browser_console_messages', snapshot.end)
        .map((result) => result.body);
      const consoleResult = consoleBodies.some((body) =>
        /(?:Errors:\s*0|0\s+(?:console\s+)?messages|no console)/i.test(body));
      const consoleError = consoleBodies.some((body) =>
        /Errors:\s*[1-9]\d*|\b(?:TypeError|ReferenceError|uncaught|console error)\b/i.test(body));
      const networkBodies = correlatedSuccesses(uses, results, 'browser_network_requests', snapshot.end)
        .map((result) => result.body);
      const networkResult = networkBodies.some((body) => /\/api\/items[\s\S]{0,300}(?:200|OK)/i.test(body));
      const failedRequest = networkBodies.some((body) => /\b[45]\d{2}\b|\b(?:failed|failure|ERR_[A-Z_]+)\b/i.test(body));
      return screenshotOffsets.length > 0 && visualObservation && consoleResult && !consoleError
        && networkResult && !failedRequest;
    });
    const pass = trustedAttestation(attestation) && evidenceComplete;
    return verdict(pass, 'After loaded inventory snapshot evidence, require an inline inspected screenshot plus later readable, styled, no-overlap, no-clipping observation, clean console, successful /api/items request, no failed request, and clean wrapper attestation');
  },

  localTeardown({ uses, results, attestation }) {
    const starts = uses.filter((call) => {
      if (call.name !== 'Bash') return false;
      const input = parseToolInput(call);
      return input && input.command === './scripts/fixture-runtime.sh up';
    }).map((start) => ({ start, result: results.find((result) => result.id === start.id && result.name === 'Bash'
      && !result.error && result.start > start.start && /fixture-runtime: started/.test(result.body)) }))
      .filter(({ result }) => Boolean(result));
    const lastStart = starts.reduce((latest, candidate) => !latest || candidate.start.start > latest.start.start ? candidate : latest, null);
    const browserResults = results.filter((result) => browserOperation(result.name) !== null
      && uses.some((call) => call.id === result.id && call.name === result.name && result.start > call.start));
    const lastBrowserResultEnd = browserResults.reduce((maximum, result) => Math.max(maximum, result.end), -1);
    const teardowns = uses.filter((call) => {
      if (call.name !== 'Bash') return false;
      const input = parseToolInput(call);
      return input && input.command === './scripts/fixture-runtime.sh down'
        && lastStart && lastStart.result.end <= lastBrowserResultEnd && call.start >= lastBrowserResultEnd;
    });
    const cleanedUp = teardowns.some((teardown) => results.some((result) =>
      result.id === teardown.id && result.name === 'Bash' && !result.error
          && result.start > teardown.start
          && /fixture-runtime: stopped/.test(result.body)
    ));
    const wroteSource = uses.some((call) => /^(?:Edit|Write|MultiEdit|NotebookEdit)$/.test(call.name));
    const unsafeBrowser = hasUnsafeBrowserCapability(uses);
    const bashBrowser = hasDirectBashBrowserAccess(uses);
    const clean = trustedAttestation(attestation);
    return verdict(cleanedUp && !wroteSource && !unsafeBrowser && !bashBrowser && clean, 'Skill must start the fixture, finish correlated browser evidence, then perform correlated final teardown; browser access must use only the exact broker namespaces and the wrapper attestation must be clean');
  },

  localVerdict({ terminalAssistant }) {
    return verdict(hasTerminalVerdict(terminalAssistant, 'PASS'), 'Terminal assistant report must end with exactly one PASS verdict line');
  },

  remoteRejected({ terminalAssistant }) {
    const rejected = /query string|query parameter|query-bearing|fragment/i.test(terminalAssistant);
    const partial = hasTerminalVerdict(terminalAssistant, 'PARTIAL');
    return verdict(rejected && partial, 'Unsafe query-bearing URL must stop with an explained PARTIAL verdict');
  },

  remoteAcceptedTools({ uses, results }) {
    const required = [
      'browser_navigate', 'browser_snapshot', 'browser_take_screenshot',
      'browser_console_messages', 'browser_network_requests', 'browser_close'
    ];
    const successful = required.every((operation) => correlatedSuccesses(uses, results, operation).length > 0);
    const navigate = uses.find((call) => isBrowserOperation(call.name, 'browser_navigate'));
    const input = navigate && parseToolInput(navigate);
    const noLocalRuntime = !uses.some((call) => call.name === 'Bash'
      && /fixture-runtime\.sh\s+(?:up|ready|down)/.test(String(parseToolInput(call)?.command || '')));
    return verdict(successful && input?.url === 'https://example.com/' && noLocalRuntime,
      'Accepted remote coverage requires exact example.com navigation, snapshot, inline screenshot, console, network, close, and no local runtime lifecycle');
  },

  remoteAcceptedEvidence({ uses, results, assistants, attestation }) {
    const snapshots = correlatedSuccesses(uses, results, 'browser_snapshot')
      .filter((result) => /Example Domain/i.test(result.body) && /More information/i.test(result.body));
    const complete = snapshots.some((snapshot) => {
      const screenshots = screenshotEvidenceOffsets({ uses, results, after: snapshot.end });
      const visual = screenshots.some((offset) => assistants.some((assistant) => assistant.start >= offset
        && /\b(?:readable|legible)\b/i.test(assistant.body)
        && /\b(?:styled|styling|visual hierarchy)\b/i.test(assistant.body)
        && /\b(?:no|without)\b[^\n]{0,80}\boverlap\b/i.test(assistant.body)
        && /\b(?:no|without)\b[^\n]{0,80}\bclipping\b/i.test(assistant.body)));
      const consoleBodies = correlatedSuccesses(uses, results, 'browser_console_messages', snapshot.end)
        .map((result) => result.body);
      const networkBodies = correlatedSuccesses(uses, results, 'browser_network_requests', snapshot.end)
        .map((result) => result.body);
      const consoleClean = consoleBodies.some((body) => /Errors:\s*0|no console|0\s+(?:console\s+)?messages/i.test(body))
        && !consoleBodies.some((body) => /Errors:\s*[1-9]\d*|\b(?:TypeError|ReferenceError|uncaught)\b/i.test(body));
      const networkClean = networkBodies.some((body) => /example\.com\/[\s\S]{0,200}(?:200|OK)/i.test(body))
        && !networkBodies.some((body) => /\b[45]\d{2}\b|\b(?:failed|failure|ERR_[A-Z_]+)\b/i.test(body));
      return screenshots.length > 0 && visual && consoleClean && networkClean;
    });
    return verdict(trustedAttestation(attestation) && complete,
      'Accepted remote evidence requires Example Domain/link snapshot, inline inspected visual proof, clean console/network, and clean wrapper attestation');
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
    return verdict(!wroteSource && !unsafeBrowser && !bashBrowser && clean, 'Verification must avoid source writes, non-broker browser namespaces, and Bash-driven browser access, with trusted clean-Git attestation');
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
