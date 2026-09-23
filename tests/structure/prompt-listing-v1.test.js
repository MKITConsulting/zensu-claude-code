import test from 'node:test';
import assert from 'node:assert/strict';

const mod = await import(new URL('../../skills/session-trail/scripts/trail.mjs', import.meta.url));
const REACH = mod.QUEUE_DELIVERY_REACH;

function transcript() {
  const lines = [];
  let clock = 0;
  const stamp = () => new Date(Date.UTC(2026, 0, 1) + (clock += 1000)).toISOString();
  const push = (record) => {
    const at = stamp();
    lines.push(JSON.stringify({ ...record, timestamp: at }));
    return at;
  };
  return {
    user: (text, version = '9.0.0') => push({ type: 'user', message: { role: 'user', content: text }, version }),
    enqueue: (text) => push({ type: 'queue-operation', operation: 'enqueue', content: text }),
    op: (operation, text, extra = {}) => push({ type: 'queue-operation', operation, ...(text === undefined ? {} : { content: text }), ...extra }),
    deliver: (text, version = '9.0.0') => push({ type: 'attachment', attachment: { type: 'queued_command', prompt: text, commandMode: 'prompt' }, version }),
    attach: (attachment, version = '9.0.0') => push({ type: 'attachment', attachment, version }),
    pad: (count) => {
      for (let i = 0; i < count; i += 1) lines.push(JSON.stringify({ type: 'padding' }));
    },
    text: () => `${lines.join('\n')}\n`,
  };
}

const texts = (out) => out.map((p) => p.text);
const timesOf = (out, text) => out.filter((p) => p.text === text).map((p) => p.at);

test('the listing and the reach it pairs within are exported', () => {
  assert.equal(typeof mod.extractPrompts, 'function');
  assert.ok(Number.isInteger(REACH) && REACH > 0, `QUEUE_DELIVERY_REACH is ${REACH}`);
});

test('a reasonless remove with no credited delivery withdraws its copy on a full read only', () => {
  const t = transcript();
  t.user('the first question');
  t.enqueue('delivered');
  t.deliver('delivered');
  t.op('remove', 'delivered');
  t.enqueue('withdrawn');
  t.op('remove', 'withdrawn');
  t.pad(REACH);
  assert.deepEqual(texts(mod.extractPrompts(t.text(), true)), ['the first question', 'delivered']);
  assert.deepEqual(texts(mod.extractPrompts(t.text(), false)), ['the first question', 'delivered', 'withdrawn']);
});

test('the pairing window reaches exactly QUEUE_DELIVERY_REACH records before a remove and no farther', () => {
  for (const [padding, credited] of [[REACH - 1, true], [REACH, false]]) {
    const t = transcript();
    t.user('the session starts');
    const first = t.enqueue('resent');
    t.deliver('resent');
    t.pad(padding);
    t.op('remove', 'resent');
    t.user('asked between the copies');
    const second = t.enqueue('resent');
    t.pad(REACH);
    assert.deepEqual(timesOf(mod.extractPrompts(t.text(), true), 'resent'), [credited ? first : second], `distance ${padding + 1}`);
  }
});

test('the pairing window reaches exactly QUEUE_DELIVERY_REACH records after a remove and no farther', () => {
  for (const [padding, credited] of [[REACH - 1, true], [REACH, false]]) {
    const t = transcript();
    t.user('the session starts');
    const first = t.enqueue('resent');
    t.op('remove', 'resent');
    t.pad(padding);
    t.deliver('resent');
    t.user('asked between the copies');
    const second = t.enqueue('resent');
    t.pad(REACH);
    assert.deepEqual(timesOf(mod.extractPrompts(t.text(), true), 'resent'), [credited ? first : second], `distance ${padding + 1}`);
  }
});

test('a reasonless remove withdraws only when at least QUEUE_DELIVERY_REACH records follow it', () => {
  for (const [after, withdrawn] of [[REACH - 1, false], [REACH, true]]) {
    const t = transcript();
    t.user('the session starts');
    t.enqueue('delivered');
    t.deliver('delivered');
    t.op('remove', 'delivered');
    t.enqueue('withdrawn');
    t.op('remove', 'withdrawn');
    t.pad(after);
    assert.equal(texts(mod.extractPrompts(t.text(), true)).includes('withdrawn'), !withdrawn, `${after} records after the remove`);
  }
});

test('the delivery channel is judged per build: a closed build and a reshaped build withdraw nothing', () => {
  const t = transcript();
  t.user('the first build asks', '9.1.1');
  t.enqueue('delivered in the first build');
  t.deliver('delivered in the first build', '9.1.1');
  t.op('remove', 'delivered in the first build');
  t.enqueue('withdrawn in the first build');
  t.op('remove', 'withdrawn in the first build');
  t.user('the closed build asks', '9.1.2');
  t.enqueue('removed in a build that delivered nothing');
  t.op('remove', 'removed in a build that delivered nothing');
  t.user('the reshaped build asks', '9.1.3');
  t.enqueue('delivered in the reshaped build');
  t.deliver('delivered in the reshaped build', '9.1.3');
  t.op('remove', 'delivered in the reshaped build');
  t.attach({ type: 'queued_command', prompt: { reshaped: true } }, '9.1.3');
  t.enqueue('removed in the reshaped build');
  t.op('remove', 'removed in the reshaped build');
  t.pad(REACH);
  const out = texts(mod.extractPrompts(t.text(), true));
  assert.equal(out.includes('withdrawn in the first build'), false);
  assert.equal(out.includes('removed in a build that delivered nothing'), true);
  assert.equal(out.includes('removed in the reshaped build'), true);
  assert.equal(out.includes('delivered in the first build'), true);
  assert.equal(out.includes('delivered in the reshaped build'), true);
});

test('a foreign attachment carrying an enqueued text opens the build it names and vetoes that build alone', () => {
  const t = transcript();
  t.user('the first build asks', '9.2.1');
  t.enqueue('delivered in the first build');
  t.deliver('delivered in the first build', '9.2.1');
  t.op('remove', 'delivered in the first build');
  t.enqueue('withdrawn in the first build');
  t.op('remove', 'withdrawn in the first build');
  t.enqueue('handed over by a renamed attachment');
  t.attach({ type: 'queued_prompt', prompt: 'handed over by a renamed attachment' }, '9.2.2');
  t.op('remove', 'handed over by a renamed attachment');
  t.enqueue('delivered in the second build');
  t.deliver('delivered in the second build', '9.2.2');
  t.op('remove', 'delivered in the second build');
  t.enqueue('removed in the vetoed build');
  t.op('remove', 'removed in the vetoed build');
  t.pad(REACH);
  const out = texts(mod.extractPrompts(t.text(), true));
  assert.equal(out.includes('withdrawn in the first build'), false);
  assert.equal(out.includes('removed in the vetoed build'), true);
  assert.equal(out.includes('delivered in the second build'), true);
});

test('an attachment with neither a queued_command type nor a prompt field starts no build', () => {
  const t = transcript();
  t.user('the first build asks', '9.3.1');
  t.enqueue('delivered');
  t.deliver('delivered', '9.3.1');
  t.op('remove', 'delivered');
  t.attach({ type: 'hook_success', hookName: 'Stop' }, '9.3.9');
  t.enqueue('withdrawn after a hook attachment');
  t.op('remove', 'withdrawn after a hook attachment');
  t.pad(REACH);
  assert.equal(texts(mod.extractPrompts(t.text(), true)).includes('withdrawn after a hook attachment'), false);
});

test('a pull-back withdraws the copy it names on a full read only', () => {
  const t = transcript();
  t.user('the session starts');
  t.enqueue('pulled back');
  t.op('popOne', 'pulled back');
  t.enqueue('still waiting');
  assert.deepEqual(texts(mod.extractPrompts(t.text(), true)), ['the session starts', 'still waiting']);
  assert.deepEqual(texts(mod.extractPrompts(t.text(), false)), ['the session starts', 'pulled back', 'still waiting']);
});

test('a remove carrying a reason and a remove naming nothing withdraw nothing', () => {
  const t = transcript();
  t.user('the session starts');
  t.enqueue('delivered');
  t.deliver('delivered');
  t.op('remove', 'delivered');
  t.enqueue('removed with a reason');
  t.op('remove', 'removed with a reason', { reason: 'absorbed_mid_turn' });
  t.enqueue('waiting when a remove naming nothing came');
  t.op('remove');
  t.pad(REACH);
  const out = texts(mod.extractPrompts(t.text(), true));
  assert.equal(out.includes('removed with a reason'), true);
  assert.equal(out.includes('waiting when a remove naming nothing came'), true);
});

test('a text a readable delivery carries keeps one copy listed when the pairing credited that delivery to no remove', () => {
  for (const [delivered, kept] of [['delivered far from its remove', 1], ['another delivered text', 0]]) {
    const t = transcript();
    t.user('the session starts');
    t.enqueue('delivered far from its remove');
    t.op('remove', 'delivered far from its remove');
    t.pad(REACH);
    t.deliver(delivered);
    t.pad(REACH);
    assert.equal(timesOf(mod.extractPrompts(t.text(), true), 'delivered far from its remove').length, kept, `delivered text: ${delivered}`);
  }
});
