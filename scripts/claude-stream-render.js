#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');

const MAX_TEXT = 6000;
const MAX_EVENT_BYTES = 16 * 1024 * 1024;
const MAX_EVENTS = 5000;
const MAX_OUTPUT_BYTES = 3 * 1024 * 1024 - 128;

function sanitize(value) {
  let text;
  if (typeof value === 'string') text = value;
  else {
    try { text = JSON.stringify(value); }
    catch (_error) { text = String(value); }
  }

  text = text
    .replace(/(https?:\/\/)[^\s\/@"'<>?#]+(?::[^\s\/@"'<>?#]*)?@/gi, '$1[REDACTED]@')
    .replace(/(https?:\/\/[^\s"'<>?#]+)[?#][^\s"'<>]*/gi, '$1[REDACTED]')
    .replace(/(["']?(?:proxy-)?authorization["']?\s*[:=]\s*["']?)(?:(?:Basic|Bearer)\s+)?[^\r\n,;"'}]+/gi, '$1[REDACTED]')
    .replace(/(["']?(?:cookie|set-cookie)["']?\s*[:=]\s*["']?)[^\r\n"'}]+/gi, '$1[REDACTED]')
    .replace(/\bBearer\s+[^\s,"']+/gi, 'Bearer [REDACTED]')
    .replace(/(["']?(?:password|token|api[_-]?key|secret)["']?\s*[:=]\s*["']?)([^\s,;"'}]+)/gi, '$1[REDACTED]')
    .replace(/\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|(?:sk|rk)_live_[A-Za-z0-9]{12,})\b/g, '[REDACTED]')
    .replace(/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g, '[REDACTED]');

  if (text.length > MAX_TEXT) return `${text.slice(0, MAX_TEXT)}...[TRUNCATED]`;
  return text;
}

function protectFraming(text) {
  return text.replace(
    /(^|\n)(?=\[(?:assistant_text\]|tool_use:|tool_result:|result\]|stream_warning\]|enrichment_warning\]|fsm-state-(?:invalid|final)\]|fsm-history\]|wrapper_attestation\]|control-attestation\]|reset-review-limit-attestation\])|=====)/g,
    '$1[content] '
  );
}

function sanitizeToolInput(name, input) {
  if (name !== 'Skill' || !input || input.skill !== 'zensu:verify-feature'
      || typeof input.args !== 'string') return input || {};
  if (/--?mode(?:=|\s+)remote\b/i.test(input.args)) {
    return { ...input, args: '[REJECTED_REMOTE_TARGET]' };
  }
  const urls = input.args.match(/https?:\/\/[^\s"'`]+/gi) || [];
  const unsafeUrl = urls.some((raw) => {
    try {
      const url = new URL(raw.replace(/[),.;]+$/, ''));
      return Boolean(url.username || url.password || url.search || url.hash);
    } catch (_error) { return true; }
  });
  if (unsafeUrl) {
    return { ...input, args: '[REJECTED_REMOTE_TARGET]' };
  }
  return input;
}

function contentSummary(content) {
  if (!Array.isArray(content)) return protectFraming(sanitize(content ?? ''));
  return content.map((block) => {
    if (!block || typeof block !== 'object') return protectFraming(sanitize(block));
    if (block.type === 'text') return protectFraming(sanitize(block.text || ''));
    if (block.type === 'image') {
      const mediaType = block.source && block.source.media_type;
      const data = typeof block.source?.data === 'string' ? block.source.data : '';
      const bytes = Buffer.byteLength(data, 'base64');
      const sha256 = crypto.createHash('sha256').update(data, 'base64').digest('hex');
      return `[image omitted${mediaType ? ` media_type=${sanitize(mediaType)}` : ''} bytes=${bytes} sha256=${sha256}]`;
    }
    return protectFraming(sanitize(block));
  }).filter(Boolean).join('\n');
}

function runStream() {
  const toolNames = new Map();
  let eventCount = 0;
  let eventLimitExceeded = false;
  let outputBytes = 0;
  let outputCapped = false;
  let buffer = '';
  let droppingOversizedEvent = false;

  function emit(value) {
    if (!value || outputCapped) return;
    const line = `${value}\n`;
    const bytes = Buffer.byteLength(line);
    if (outputBytes + bytes > MAX_OUTPUT_BYTES) {
      process.stdout.write('[stream_warning] rendered output limit reached\n');
      outputCapped = true;
      return;
    }
    process.stdout.write(line);
    outputBytes += bytes;
  }

  function renderEvent(event) {
    if (event.type === 'assistant') {
      for (const block of event.message?.content || []) {
        if (block?.type === 'text' && block.text) emit(`[assistant_text]\n${protectFraming(sanitize(block.text))}`);
        else if (block?.type === 'tool_use') {
          if (block.id) toolNames.set(block.id, block.name || '?');
          const id = block.id ? ` id=${sanitize(block.id)}` : '';
          emit(`[tool_use: ${sanitize(block.name || '?')}]${id} input=${sanitize(sanitizeToolInput(block.name, block.input))}`);
        }
      }
    } else if (event.type === 'user') {
      for (const block of event.message?.content || []) {
        if (block?.type !== 'tool_result') continue;
        const name = toolNames.get(block.tool_use_id) || block.tool_use_id || '?';
        const summary = /storage[_-]?state/i.test(name) ? '[storage-state result omitted]' : contentSummary(block.content);
        const id = block.tool_use_id ? ` id=${sanitize(block.tool_use_id)}` : '';
        emit(`[tool_result: ${sanitize(name)}]${id} is_error=${block.is_error === true}\n${summary}`);
      }
    } else if (event.type === 'tool_use') {
      if (event.id) toolNames.set(event.id, event.name || '?');
      const id = event.id ? ` id=${sanitize(event.id)}` : '';
      emit(`[tool_use: ${sanitize(event.name || '?')}]${id} input=${sanitize(sanitizeToolInput(event.name, event.input))}`);
    } else if (event.type === 'tool_result') {
      const resultId = event.tool_use_id || event.id;
      const name = toolNames.get(resultId) || event.name || resultId || '?';
      const summary = /storage[_-]?state/i.test(name) ? '[storage-state result omitted]' : contentSummary(event.content);
      const id = resultId ? ` id=${sanitize(resultId)}` : '';
      emit(`[tool_result: ${sanitize(name)}]${id} is_error=${event.is_error === true}\n${summary}`);
    } else if (event.type === 'result') {
      emit(`[result] ${protectFraming(sanitize(event.result || ''))}`);
    }
  }

  function processLine(line) {
    if (!line) return;
    if (eventCount >= MAX_EVENTS) {
      eventLimitExceeded = true;
      return;
    }
    eventCount += 1;
    try { renderEvent(JSON.parse(line)); }
    catch (_error) { emit('[stream_warning] malformed event omitted'); }
  }

  function oversizedEventOmitted() {
    emit('[stream_warning] oversized event omitted');
  }

  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    let remaining = chunk;
    if (droppingOversizedEvent) {
      const newline = remaining.indexOf('\n');
      if (newline === -1) return;
      remaining = remaining.slice(newline + 1);
      droppingOversizedEvent = false;
      oversizedEventOmitted();
    }

    buffer += remaining;
    let newline;
    while ((newline = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, newline).replace(/\r$/, '');
      buffer = buffer.slice(newline + 1);
      if (Buffer.byteLength(line) > MAX_EVENT_BYTES) oversizedEventOmitted();
      else processLine(line);
    }

    if (Buffer.byteLength(buffer) > MAX_EVENT_BYTES) {
      buffer = '';
      droppingOversizedEvent = true;
    }
  });

  process.stdin.on('end', () => {
    if (droppingOversizedEvent) oversizedEventOmitted();
    else if (buffer) processLine(buffer.replace(/\r$/, ''));
    if (eventLimitExceeded) emit('[stream_warning] event limit reached');
  });
}

module.exports = { protectFraming, sanitize, sanitizeToolInput };

if (require.main === module) runStream();
