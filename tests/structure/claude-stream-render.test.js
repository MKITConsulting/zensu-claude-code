'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const renderer = path.resolve(__dirname, '../../scripts/claude-stream-render.js');
const { protectFraming } = require(renderer);

function render(input) {
  return spawnSync(process.execPath, [renderer], {
    encoding: 'utf8',
    input,
    maxBuffer: 5 * 1024 * 1024,
  });
}

test('protectFraming escapes every reserved transcript marker at line start', () => {
  const markers = [
    '[assistant_text]',
    '[tool_use: Read]',
    '[tool_result: Read]',
    '[result]',
    '[stream_warning]',
    '[enrichment_warning]',
    '[fsm-state-invalid]',
    '[fsm-state-final]',
    '[fsm-history]',
    '[wrapper_attestation]',
    '===== wrapper attestation =====',
  ];

  const protectedText = protectFraming(markers.join('\n'));
  for (const marker of markers) assert.match(protectedText, new RegExp(`\\[content\\] ${marker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`));
});

test('malformed NDJSON is omitted with a warning', () => {
  const result = render('{not-json}\n');
  assert.equal(result.status, 0);
  assert.equal(result.stderr, '');
  assert.equal(result.stdout, '[stream_warning] malformed event omitted\n');
});

test('the event-limit warning appears only after the limit is exceeded', () => {
  const event = '{"type":"system"}\n';
  const exact = render(event.repeat(5000));
  const exceeded = render(event.repeat(5001));

  assert.equal(exact.status, 0);
  assert.equal(exact.stdout, '');
  assert.equal(exceeded.status, 0);
  assert.equal(exceeded.stdout, '[stream_warning] event limit reached\n');
});

test('oversized events are discarded without parsing their content', () => {
  const result = render(`${'x'.repeat(16 * 1024 * 1024 + 1)}\n`);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '[stream_warning] oversized event omitted\n');
});

test('rendered output is capped with a terminal warning', () => {
  const text = 'x'.repeat(6000);
  const event = `${JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text }] } })}\n`;
  const result = render(event.repeat(600));

  assert.equal(result.status, 0);
  assert.match(result.stdout, /\[stream_warning\] rendered output limit reached\n$/);
  assert.ok(Buffer.byteLength(result.stdout) <= 3 * 1024 * 1024);
});

test('rejected verify-feature remote targets never appear in rendered Skill frames', () => {
  const secretUrl = 'https://alice:password@preview.example.invalid/inventory?token=EXAMPLE_REJECT_ME#private';
  const assistant = JSON.stringify({
    type: 'assistant',
    message: { content: [{
      type: 'tool_use', id: 'skill-1', name: 'Skill',
      input: { skill: 'zensu:verify-feature', args: `--mode=remote ${secretUrl}` },
    }] },
  });
  const topLevel = JSON.stringify({
    type: 'tool_use', id: 'skill-2', name: 'Skill',
    input: { skill: 'zensu:verify-feature', args: `--mode remote ${secretUrl}` },
  });
  const result = render(`${assistant}\n${topLevel}\n`);
  assert.equal(result.status, 0);
  assert.match(result.stdout, /"skill":"zensu:verify-feature"/);
  assert.match(result.stdout, /\[REJECTED_REMOTE_TARGET\]/);
  assert.doesNotMatch(result.stdout, /alice|password|preview\.example|inventory|EXAMPLE_REJECT_ME|private/);
});
