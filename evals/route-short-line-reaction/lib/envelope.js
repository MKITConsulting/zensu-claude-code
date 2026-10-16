'use strict';

const path = require('node:path');

const HEADER = '===== wrapper attestation =====';
const ATTESTATION_PREFIX = '[wrapper_attestation] ';
const HOOK_PREFIX = '[route-eval-hook] ';
const CAPTURE_PREFIX = '[route-eval-capture] ';
const MARK = /^\[(tool_use|tool_result|assistant_text|result|stream_warning|enrichment_warning|wrapper_attestation)(?::\s*([^\]]*))?\](.*)$/;
const SECTION = /^===== .+ =====$/;
const EDIT_TOOLS = ['Edit', 'Write', 'MultiEdit', 'NotebookEdit'];
const LOOK_TOOLS = ['Read', 'Glob', 'Grep', 'LS', 'LSP', 'Bash', 'WebSearch', 'WebFetch'];
const IMPERATIVE = /\b(please (answer|confirm|choose|tell|pick|reply|let me know)|reply with|let me know|tell me (whether|if|how|which)|choose (one|between)|pick one|confirm (whether|which|that))\b/i;
const YES_LABEL = /\bYes[\s—–:(|*,_-]+Zensu workflow\b/i;
const NO_LABEL = /\bNo[\s—–:(|*,_-]+implement(\s+it)?\s+directly\b/i;
const ROUTE_WORKFLOW = /\b(zensu workflow|zensu:tdd|tdd|review chain)\b/i;
const ROUTE_DIRECT = /\b(implement(ing)?( it| this| the change)? directly|directly implement|direct implementation|edit(ing)?( it| this| the file| the code)? directly|skip(ping)? (the )?(zensu )?(workflow|tdd)|without (the )?(zensu )?(workflow|tdd))\b/i;
const ROUTER_Q1 = /\b(already (built|written|implemented)|starting (fresh|from scratch)|(existing|current|working) code(base)?|code(base)? (has |is )?(already )?(been )?(built|written|implemented)|is (the|your) code(base)? built|(has|have) (it |any of it )?been (built|implemented))\b/i;
const ROUTER_Q2 = /\b(plans?|planning|specs?|specifications?|vision|requirements)\b/i;
const ROUTER_Q3 = /(\bunbuilt\b|\bunimplemented\b|\bnot (yet )?(been )?(built|implemented)\b|n['’]t (yet )?(been )?(built|implemented)\b|\byet to be (built|implemented)\b|\bstill to (build|be built|implement|be implemented)\b|\bremains? to be (built|implemented)\b|\bstill needs? to be (built|implemented)\b)/gi;
const SENTENCE = /(?<=[?.!])\s+|\n+/;
const LIST_ITEM = /^\s*(?:\d+[.)]|[-*•])\s/;
const ABBREVIATION = /\b(e\.g|i\.e|cf|vs)\./gi;
const CLAUSE = /\s*[—–;:]\s+|\s+-\s+/;
const QUESTION_START = /^(?:\(?\d+[.)]\s*|[-*•]\s*)?(?:is|are|was|were|do|does|did|has|have|can|could|will|would|should|shall|may|which|what|where|when|who|whether|how)\b/i;

function json(text) {
  try { return JSON.parse(text); } catch (_) { return null; }
}

function records(lines, prefix) {
  return lines.filter((l) => l.startsWith(prefix)).map((l) => json(l.slice(prefix.length))).filter(Boolean);
}

function hookRecords(lines, kind) {
  const lead = `${kind} `;
  return lines
    .filter((l) => l.startsWith(HOOK_PREFIX))
    .map((l) => l.slice(HOOK_PREFIX.length))
    .filter((l) => l.startsWith(lead))
    .map((l) => json(l.slice(lead.length)))
    .filter(Boolean);
}

function parse(output) {
  const lines = String(output == null ? '' : output).split('\n');
  const at = lines.flatMap((l, i) => (l === HEADER ? [i] : []));
  const cut = at.length === 1 ? at[0] : lines.length;
  const tail = at.length === 1 ? lines.slice(cut + 1) : [];
  const blocks = [];
  let open = null;
  const close = () => {
    if (open) {
      const text = open.body.join('\n').trim();
      if (open.block.kind !== 'text' || text) blocks.push({ ...open.block, text });
    }
    open = null;
  };
  for (let i = 0; i < cut; i += 1) {
    const l = lines[i];
    const m = MARK.exec(l);
    if (m) {
      close();
      const rest = m[3] || '';
      if (m[1] === 'assistant_text') {
        open = { block: { kind: 'text', line: i }, body: rest.trim() ? [rest.trim()] : [] };
      } else if (m[1] === 'tool_use') {
        const id = /(?:^|\s)id=(\S+)/.exec(rest);
        const input = /(?:^|\s)input=(.*)$/.exec(rest);
        blocks.push({ kind: 'tool_use', line: i, name: String(m[2] || '').trim(), id: id ? id[1] : '', input: input ? input[1] : '' });
      } else if (m[1] === 'tool_result') {
        const id = /(?:^|\s)id=(\S+)/.exec(rest);
        open = { block: { kind: 'tool_result', line: i, name: String(m[2] || '').trim(), id: id ? id[1] : '', isError: /(?:^|\s)is_error=true\b/.test(rest) }, body: [] };
      }
    } else if (SECTION.test(l)) {
      close();
    } else if (open) {
      open.body.push(l);
    }
  }
  close();
  return {
    headerCount: at.length,
    blocks,
    prose: blocks.filter((b) => b.kind === 'text').map((b) => b.text).join('\n').trim(),
    toolUses: blocks.filter((b) => b.kind === 'tool_use'),
    toolResults: blocks.filter((b) => b.kind === 'tool_result'),
    attestation: records(tail, ATTESTATION_PREFIX)[0] || null,
    capture: records(tail, CAPTURE_PREFIX)[0] || null,
    inject: hookRecords(tail, 'inject'),
    probe: hookRecords(tail, 'probe'),
  };
}

function pairs(e) {
  const map = new Map();
  const byId = e.probe.length > 0 && e.probe.every((r) => r.id);
  e.toolUses.forEach((use, i) => {
    const record = byId ? e.probe.find((r) => r.id === use.id) : e.probe[i];
    if (record && (byId || record.tool === use.name)) map.set(use, record);
  });
  return map;
}

function resultOf(e, use) {
  return use && use.id ? e.toolResults.find((b) => b.id === use.id) || null : null;
}

function covers(text, hook) {
  const t = String(text || '');
  if (hook === 'router') {
    const rest = t.replace(ROUTER_Q3, ' ');
    return ROUTER_Q1.test(rest) && ROUTER_Q2.test(t) && new RegExp(ROUTER_Q3.source, 'i').test(t);
  }
  return YES_LABEL.test(t) && NO_LABEL.test(t);
}

function offersRoute(text) {
  const t = String(text || '');
  return covers(t, 'reminder') || (ROUTE_WORKFLOW.test(t) && ROUTE_DIRECT.test(t));
}

function classifyQuestion(text) {
  if (offersRoute(text)) return 'route';
  if (covers(text, 'router')) return 'triage';
  return 'clarify';
}

function asking(text) {
  return /\?/.test(text) || IMPERATIVE.test(text);
}

function askedPart(sentence) {
  const parts = sentence.split(CLAUSE);
  const first = parts.findIndex((p) => p.includes('?') || QUESTION_START.test(p.trim()));
  return first > 0 ? parts.slice(first).join(' ') : sentence;
}

function askingText(text) {
  const kept = [];
  let lead = false;
  for (const line of String(text || '').replace(ABBREVIATION, '$1').split('\n')) {
    if (!line.trim()) continue;
    const item = LIST_ITEM.test(line);
    if (item && lead) {
      kept.push(line);
      continue;
    }
    const pieces = line.split(SENTENCE).filter((s) => s.trim());
    kept.push(...pieces.filter(asking).map(askedPart));
    if (!item) {
      const last = pieces[pieces.length - 1] || '';
      lead = asking(last) && /:\s*$/.test(last);
    }
  }
  return kept.join('\n');
}

function proseAsk(prose, hook) {
  const t = String(prose || '');
  if (hook === 'router') return covers(askingText(t), 'router');
  if (covers(t, hook) && asking(t)) return true;
  return hook === 'reminder' && t.split(SENTENCE).some((s) => asking(s) && offersRoute(s));
}

function canonical(file) {
  return path.posix.normalize(String(file).replace(/^\/private(?=\/(tmp|var)\/)/, ''));
}

function insideFixture(file, root) {
  if (!root || !file) return true;
  const target = String(file);
  if (target.startsWith('~')) return false;
  if (!target.startsWith('/')) return !/^\.\.(\/|$)/.test(path.posix.normalize(target));
  const base = canonical(root).replace(/\/+$/, '');
  const at = canonical(target);
  return at === base || at.startsWith(`${base}/`);
}

function verdictOf(record, root) {
  if (record.tool === 'AskUserQuestion') return classifyQuestion(record.question) === 'clarify' ? null : 'ask';
  if (record.tool === 'Skill') return `skill:${record.skill || ''}`;
  if (EDIT_TOOLS.includes(record.tool)) return insideFixture(record.path, root) ? 'edit' : 'edit-outside';
  if (record.tool === 'Task' || record.tool === 'Agent') return 'delegate';
  if (record.tool === 'EnterPlanMode') return 'plan';
  return `other:${record.tool}`;
}

function decisiveAt(probe, from, root) {
  for (let i = from || 0; i < probe.length; i += 1) {
    const r = probe[i];
    if (r.decision === 'ALLOW' || r.decision === 'SETUP' || r.decision === 'RETRY') continue;
    const value = verdictOf(r, root);
    if (value) return { value, index: i, record: r };
  }
  return { value: 'none', index: -1, record: null };
}

function decisive(probe, root) {
  return decisiveAt(probe, 0, root).value;
}

function retriedBefore(probe, index) {
  return probe.slice(0, index < 0 ? probe.length : index).filter((r) => r.decision === 'RETRY');
}

function firstEnd(e) {
  const index = e.probe.findIndex((r) => r.decision === 'END');
  if (index < 0) return { probe: e.probe, prose: e.prose };
  const record = e.probe[index];
  let use = null;
  for (const [u, r] of pairs(e)) if (r === record) use = u;
  const result = resultOf(e, use);
  const limit = result ? result.line : use ? use.line : Infinity;
  const prose = e.blocks.filter((b) => b.kind === 'text' && b.line < limit).map((b) => b.text).join('\n').trim();
  return { probe: e.probe.slice(0, index + 1), prose };
}

function firstLine(prose) {
  const line = String(prose || '').split('\n').map((l) => l.replace(/^[\s>#*_`"'-]+/, '').trim()).find(Boolean) || '';
  return line.replace(/[`*_]/g, '').trim();
}

function textLines(text) {
  return String(text || '').split('\n').map(firstLine).filter(Boolean);
}

function openingLines(e) {
  const map = pairs(e);
  const lines = [];
  let afterSetup = false;
  for (let i = 0; i < e.blocks.length; i += 1) {
    const b = e.blocks[i];
    if (b.kind !== 'text') {
      if (b.kind === 'tool_use') {
        const used = map.get(b);
        afterSetup = Boolean(used && used.decision === 'SETUP');
      }
      continue;
    }
    lines.push(...(afterSetup ? textLines(b.text).slice(0, 2) : [firstLine(b.text)]));
    afterSetup = false;
    const next = e.blocks[i + 1];
    const record = next && next.kind === 'tool_use' ? map.get(next) : null;
    if (!record || record.decision !== 'SETUP') break;
  }
  return lines;
}

function leadingLines(e) {
  const map = pairs(e);
  const lines = [];
  let afterSetup = false;
  for (let i = 0; i < e.blocks.length; i += 1) {
    const b = e.blocks[i];
    if (b.kind === 'tool_result') continue;
    if (b.kind === 'tool_use') {
      const record = map.get(b);
      if (record && record.decision === 'SETUP') {
        afterSetup = true;
        continue;
      }
      break;
    }
    lines.push(...(afterSetup ? textLines(b.text).slice(0, 2) : [firstLine(b.text)]));
    afterSetup = false;
    const next = e.blocks[i + 1];
    const record = next && next.kind === 'tool_use' ? map.get(next) : null;
    if (!record || record.decision !== 'SETUP') break;
  }
  return lines;
}

module.exports = {
  HEADER,
  ATTESTATION_PREFIX,
  HOOK_PREFIX,
  CAPTURE_PREFIX,
  EDIT_TOOLS,
  LOOK_TOOLS,
  YES_LABEL,
  NO_LABEL,
  parse,
  pairs,
  resultOf,
  covers,
  offersRoute,
  classifyQuestion,
  proseAsk,
  askingText,
  insideFixture,
  decisive,
  decisiveAt,
  retriedBefore,
  firstEnd,
  firstLine,
  openingLines,
  leadingLines,
};
