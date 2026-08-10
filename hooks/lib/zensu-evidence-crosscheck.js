#!/usr/bin/env node
// zensu-evidence-crosscheck.js — the witness cross-check, as code.
//
// A structured-evidence claim (`CHECKPOINT — cmd="X" exit=0 result="PASS"`) is
// only worth the witness line that corroborates it. The check used to live as
// prose in skills/tdd/SKILL.md: "for each cmd="X" claim, run
// grep -F -q 'cmd="X"' witness.log", plus a hand-executed tail scan.
//
// That recipe is not itself known to be wrong — the witness JSON-encodes the
// recorded command, so the escaping happens to defeat the obvious attack where
// the printf that WROTE a claim corroborates it. What went wrong in a real
// session on this repository was the execution: the procedure was run by hand,
// every claim came back `verified`, and the verdict was reported to a human
// before anyone noticed it had not actually been established. A procedure that
// must be re-derived and re-executed by hand each run has no failure mode
// anyone can test, and no exit code any gate can consume.
//
// So this is the same move zensu-edit-landing.sh already made for the Edit
// Landing Audit: the recipe becomes a library. Along the way it gains the
// properties the prose never had — witness entries that are themselves log
// writes cannot corroborate anything, matching is equality rather than
// containment, the format is decoded rather than pattern-scraped, a missing
// witness log fails closed, and the verdict is a deterministic exit code.
//
// Result-corroboration is deliberately the weaker half: it reads only the
// decoded tail, and a claimed pass is contradicted only when EVERY matching
// witness entry failed. A command that failed, got fixed and re-ran green is a
// normal cycle, not a false claim. The equality match is the gate.
//
// CLI:
//   node zensu-evidence-crosscheck.js --log <run-log> --witness <witness-log>
//                                     [--allow-missing-log]
//
// Exit 0 iff every claim is verified and none is contradicted. Exit 1 on any
// gap or contradiction, exit 2 on a usage or input error.

'use strict';

const fs = require('fs');
const path = require('path');

const CLAIM_MARKER = /(?:CHECKPOINT|AUDIT)\s*[-–—]+\s/;
const LOG_WRITE_MARKER = /(?:CHECKPOINT|AUDIT)\s*[-–—]+\s*(?:cmd=|via=)|EVIDENCE (?:GAP|CONTRADICTION)/;
const WITNESS_MARKER = 'BASH cmd=';
const LOG_DIR_FRAGMENT = '.zensu/logs';

function readJsonString(text, start) {
  if (text[start] !== '"') return null;
  let out = '';
  for (let i = start + 1; i < text.length; i += 1) {
    const ch = text[i];
    if (ch === '\\') {
      const next = text[i + 1];
      if (next === undefined) return null;
      out += ch + next;
      i += 1;
      continue;
    }
    if (ch === '"') {
      try {
        return { value: JSON.parse('"' + out + '"'), end: i + 1 };
      } catch (_) {
        return null;
      }
    }
    out += ch;
  }
  return null;
}

function extractQuoted(line, key, stopMarker) {
  const at = line.indexOf(key + '="');
  if (at === -1) return null;
  const from = at + key.length + 2;
  if (stopMarker) {
    const stop = line.lastIndexOf('" ' + stopMarker);
    if (stop > from - 1) return line.slice(from, stop);
  }
  const tail = line.lastIndexOf('"');
  if (tail <= from - 1) return null;
  return line.slice(from, tail);
}

function parseClaims(logText) {
  const claims = [];
  const lines = logText.split('\n');
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (!CLAIM_MARKER.test(line)) continue;
    const via = line.indexOf('cmd="') === -1 ? line.match(/\bvia=(\S+)/) : null;
    if (via) {
      claims.push({
        kind: 'via',
        tool: via[1],
        claim: extractQuoted(line, 'claim') || '',
        line: i + 1,
      });
      continue;
    }
    const cmd = extractQuoted(line, 'cmd', 'exit=');
    if (cmd === null) continue;
    claims.push({
      kind: 'cmd',
      cmd,
      result: extractQuoted(line, 'result') || '',
      line: i + 1,
    });
  }
  return claims;
}

function redirectTargets(command) {
  const targets = [];
  const redirect = /(?:>>?|\|\s*tee(?:\s+-\w+)*)\s*("[^"]*"|'[^']*'|[^\s;|&<>]+)/g;
  let hit;
  while ((hit = redirect.exec(command)) !== null) {
    targets.push(hit[1].replace(/^["']|["']$/g, ''));
  }
  const tee = /\btee\b(?:\s+-\w+)*\s+("[^"]*"|'[^']*'|[^\s;|&<>]+)/g;
  while ((hit = tee.exec(command)) !== null) {
    targets.push(hit[1].replace(/^["']|["']$/g, ''));
  }
  return targets;
}

function isLogWritingCommand(command, logPath) {
  if (LOG_WRITE_MARKER.test(command)) return true;
  const base = path.basename(logPath);
  for (const target of redirectTargets(command)) {
    const normalized = target.split(path.sep).join('/');
    if (normalized.includes(LOG_DIR_FRAGMENT)) return true;
    if (base && normalized.endsWith(base)) return true;
  }
  return false;
}

function parseWitness(witnessText, logPath) {
  const entries = [];
  const lines = witnessText.split('\n');
  for (const line of lines) {
    const at = line.indexOf(WITNESS_MARKER);
    if (at === -1) continue;
    const cmdRead = readJsonString(line, at + WITNESS_MARKER.length);
    if (!cmdRead) continue;
    const tailAt = line.indexOf(' tail=', cmdRead.end);
    if (tailAt === -1) continue;
    const tailRead = readJsonString(line, tailAt + ' tail='.length);
    if (!tailRead) continue;
    const interrupted = /\binterrupted=true\b/.test(line.slice(tailRead.end));
    entries.push({
      cmd: cmdRead.value,
      tail: tailRead.value,
      interrupted,
      logWriting: isLogWritingCommand(cmdRead.value, logPath),
    });
  }
  return entries;
}

function isGreen(result) {
  if (!result) return false;
  if (/\b(fail|failed|failing|error|errors|red)\b/i.test(result)) return false;
  return /\b(pass|passed|ok|green|success|succeeded)\b/i.test(result);
}

function failureMarker(entry) {
  if (entry.interrupted) return 'interrupted=true';
  const scrubbed = entry.tail
    .replace(/\b0\s+(?:FAIL|FAILED|failures?|failing|errors?)\b/gi, ' ')
    .replace(/\b(?:fail(?:ures)?|errors?)\s*[:=]?\s*0\b/gi, ' ');
  const markers = [
    [/\bFAIL\b/, 'FAIL'],
    [/\bfailed\b/i, 'failed'],
    [/\bError\b/, 'Error'],
    [/\b[1-9]\d*\s+(?:failing|failures?|failed)\b/i, 'a non-zero failure count'],
    [/\b(?:fail(?:ures)?|errors?)\s*[:=]?\s*[1-9]\d*/i, 'a non-zero failure count'],
  ];
  for (const [pattern, label] of markers) {
    if (pattern.test(scrubbed)) return label;
  }
  return null;
}

function crossCheck(claims, entries, witnessAvailable) {
  const usable = entries.filter((e) => !e.logWriting);
  return claims.map((claim) => {
    if (claim.kind === 'via') return { claim, verdict: 'via' };
    if (!witnessAvailable) return { claim, verdict: 'gap' };
    const wanted = claim.cmd.trim();
    const matches = usable.filter((e) => e.cmd.trim() === wanted);
    if (matches.length === 0) return { claim, verdict: 'gap' };
    if (isGreen(claim.result)) {
      const markers = matches.map((e) => failureMarker(e));
      if (markers.every((m) => m !== null)) {
        return { claim, verdict: 'contradiction', marker: markers[0] };
      }
    }
    return { claim, verdict: 'verified' };
  });
}

function render(results) {
  const lines = [];
  for (const r of results) {
    if (r.verdict === 'via') {
      lines.push(
        `via=${r.claim.tool} claim="${r.claim.claim}" (known limitation — no witness cross-check possible)`
      );
    } else if (r.verdict === 'verified') {
      lines.push(`verified cmd="${r.claim.cmd}"`);
    } else if (r.verdict === 'gap') {
      lines.push(`EVIDENCE GAP — cmd="${r.claim.cmd}" claimed but not in witness log`);
    } else {
      lines.push(
        `EVIDENCE CONTRADICTION — cmd="${r.claim.cmd}" claimed PASS but witness tail shows ${r.marker}`
      );
    }
  }
  return lines;
}

function parseArgv(argv) {
  const opts = { log: '', witness: '', allowMissingLog: false };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--log') { opts.log = argv[i + 1] || ''; i += 1; }
    else if (argv[i] === '--witness') { opts.witness = argv[i + 1] || ''; i += 1; }
    else if (argv[i] === '--allow-missing-log') { opts.allowMissingLog = true; }
  }
  return opts;
}

function run(argv) {
  const opts = parseArgv(argv);
  if (!opts.log || !opts.witness) {
    return { code: 2, out: ['EVIDENCE CROSS-CHECK UNAVAILABLE — usage: --log <run-log> --witness <witness-log> [--allow-missing-log]'] };
  }

  let logText;
  try {
    logText = fs.readFileSync(opts.log, 'utf8');
  } catch (_) {
    if (opts.allowMissingLog) {
      return { code: 0, out: ['EVIDENCE CROSS-CHECK — no evidence claims to cross-check (no run log)'] };
    }
    return { code: 2, out: [`EVIDENCE CROSS-CHECK UNAVAILABLE — run log unreadable: ${opts.log}`] };
  }

  const claims = parseClaims(logText);
  if (claims.length === 0) {
    return { code: 0, out: ['EVIDENCE CROSS-CHECK — no evidence claims to cross-check'] };
  }

  let witnessText = null;
  try {
    witnessText = fs.readFileSync(opts.witness, 'utf8');
  } catch (_) {
    witnessText = null;
  }

  const entries = witnessText === null ? [] : parseWitness(witnessText, opts.log);
  const results = crossCheck(claims, entries, witnessText !== null);

  const out = [`EVIDENCE CROSS-CHECK — log=${opts.log} witness=${opts.witness}`];
  if (witnessText === null) {
    out.push(`EVIDENCE CROSS-CHECK — witness log unreadable: ${opts.witness} (every claim is a gap)`);
  }
  out.push(...render(results));

  const counts = { verified: 0, gap: 0, contradiction: 0, via: 0 };
  for (const r of results) counts[r.verdict] += 1;
  out.push(
    `EVIDENCE CROSS-CHECK SUMMARY — claims=${results.length} verified=${counts.verified} gaps=${counts.gap} contradictions=${counts.contradiction} via=${counts.via}`
  );

  return { code: counts.gap + counts.contradiction > 0 ? 1 : 0, out };
}

module.exports = {
  parseClaims,
  parseWitness,
  isLogWritingCommand,
  isGreen,
  failureMarker,
  crossCheck,
  render,
  run,
};

if (require.main === module) {
  let result;
  try {
    result = run(process.argv.slice(2));
  } catch (err) {
    result = { code: 2, out: [`EVIDENCE CROSS-CHECK UNAVAILABLE — ${err && err.message ? err.message : 'internal error'}`] };
  }
  process.stdout.write(result.out.join('\n') + '\n');
  process.exit(result.code);
}
