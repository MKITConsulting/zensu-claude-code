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

const texts = (out) => out.prompts.map((p) => p.text);
const withdrawnTexts = (out) => out.withdrawn.map((p) => p.text);
const timesOf = (out, text) => out.prompts.filter((p) => p.text === text).map((p) => p.at);

test('the listing and the reach it pairs within are exported', () => {
  assert.equal(typeof mod.extractPrompts, 'function');
  assert.ok(Number.isInteger(REACH) && REACH > 0, `QUEUE_DELIVERY_REACH is ${REACH}`);
});

test('a reasonless remove with no credited delivery sets its copy apart as withdrawn on a full read only', () => {
  const t = transcript();
  t.user('the first question');
  t.enqueue('delivered');
  t.deliver('delivered');
  t.op('remove', 'delivered');
  t.enqueue('withdrawn');
  t.op('remove', 'withdrawn');
  t.pad(REACH);
  const full = mod.extractPrompts(t.text(), true);
  assert.deepEqual(texts(full), ['the first question', 'delivered']);
  assert.deepEqual(withdrawnTexts(full), ['withdrawn']);
  const cut = mod.extractPrompts(t.text(), false);
  assert.deepEqual(texts(cut), ['the first question', 'delivered', 'withdrawn']);
  assert.equal(cut.withdrawn, null);
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

test('a delivery is credited only to a remove that took a copy and carries no reason, however near another remove sits', () => {
  const arms = [
    ['a reasoned remove sits nearer the delivery', (t) => {
      t.user('asked between the copies');
      t.enqueue('delivered once');
      t.op('remove', 'delivered once', { reason: 'absorbed_mid_turn' });
    }],
    ['a remove that took nothing sits nearer the delivery', (t) => {
      t.op('remove', 'delivered once');
      t.user('asked between the copies');
      t.enqueue('delivered once');
    }],
  ];
  for (const [label, between] of arms) {
    const t = transcript();
    t.user('the session starts');
    const first = t.enqueue('delivered once');
    t.op('remove', 'delivered once');
    between(t);
    t.deliver('delivered once');
    t.pad(REACH);
    const out = mod.extractPrompts(t.text(), true);
    assert.deepEqual(timesOf(out, 'delivered once'), [first], label);
    assert.deepEqual(withdrawnTexts(out), [], label);
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
  t.user('the first build asks again', '9.1.1');
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
  t.user('the first build asks again', '9.2.1');
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

test('a remove followed by a record of another build is judged under both builds', () => {
  const opensSecond = (t) => {
    t.enqueue('opens the second build');
    t.deliver('opens the second build', '9.4.2');
    t.op('remove', 'opens the second build');
  };
  const arms = [
    ['the next record is of the same build', (t) => t.user('the first build asks again', '9.4.1'), true],
    ['the next build delivers nothing', (t) => t.user('the second build asks', '9.4.2'), false],
    ['the next build is open', (t) => opensSecond(t), true],
    ['the next build is open and vetoed', (t) => { opensSecond(t); t.attach({ type: 'queued_command', prompt: { reshaped: true } }, '9.4.2'); }, false],
  ];
  for (const [label, next, withdrawn] of arms) {
    const t = transcript();
    t.user('the first build asks', '9.4.1');
    t.enqueue('opens the first build');
    t.deliver('opens the first build', '9.4.1');
    t.op('remove', 'opens the first build');
    t.enqueue('removed at the boundary');
    t.op('remove', 'removed at the boundary');
    next(t);
    t.pad(REACH);
    const out = mod.extractPrompts(t.text(), true);
    assert.equal(withdrawnTexts(out).includes('removed at the boundary'), withdrawn, label);
    assert.equal(texts(out).includes('removed at the boundary'), !withdrawn, label);
  }
});

test('a record without a version leaves the build in effect rather than starting one', () => {
  const arms = [
    ['the next versioned record is of the open build', '9.6.1', true],
    ['the next versioned record is of a closed build', '9.6.2', false],
  ];
  const unversioned = [
    ['a user record', (t) => t.user('a record without a version', null)],
    ['an attachment', (t) => t.attach({ type: 'queued_prompt', prompt: 'an attachment without a version' }, null)],
  ];
  for (const [kind, record] of unversioned) {
    for (const [arm, nextBuild, withdrawn] of arms) {
      const label = `${kind}: ${arm}`;
      const t = transcript();
      t.enqueue('opens the unversioned build');
      t.deliver('opens the unversioned build', null);
      t.op('remove', 'opens the unversioned build');
      t.user('the first build asks', '9.6.1');
      t.enqueue('opens the first build');
      t.deliver('opens the first build', '9.6.1');
      t.op('remove', 'opens the first build');
      t.enqueue('removed before an unversioned record');
      t.op('remove', 'removed before an unversioned record');
      record(t);
      t.user('the next versioned record', nextBuild);
      t.pad(REACH);
      const out = mod.extractPrompts(t.text(), true);
      assert.equal(withdrawnTexts(out).includes('removed before an unversioned record'), withdrawn, label);
      assert.equal(texts(out).includes('removed before an unversioned record'), !withdrawn, label);
    }
  }
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

test('each pull-back withdraws the copy it names on a full read only', () => {
  for (const operation of ['popAll', 'popOne']) {
    const t = transcript();
    t.user('the session starts');
    t.enqueue('pulled back');
    t.op(operation, 'pulled back');
    t.enqueue('still waiting');
    const full = mod.extractPrompts(t.text(), true);
    assert.deepEqual(texts(full), ['the session starts', 'still waiting'], operation);
    assert.deepEqual(withdrawnTexts(full), ['pulled back'], operation);
    const cut = mod.extractPrompts(t.text(), false);
    assert.deepEqual(texts(cut), ['the session starts', 'pulled back', 'still waiting'], operation);
    assert.equal(cut.withdrawn, null, operation);
  }
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

test('a remove the pairing credited nothing to keeps its copy listed, by the keep-one fallback or by the veto an unmatched delivery raises', () => {
  for (const delivered of ['delivered far from its remove', 'another delivered text']) {
    const t = transcript();
    t.user('the session starts');
    t.enqueue('delivered far from its remove');
    t.op('remove', 'delivered far from its remove');
    t.pad(REACH);
    t.deliver(delivered);
    t.pad(REACH);
    const out = mod.extractPrompts(t.text(), true);
    assert.equal(timesOf(out, 'delivered far from its remove').length, 1, `delivered text: ${delivered}`);
    assert.deepEqual(withdrawnTexts(out), [], `delivered text: ${delivered}`);
  }
});

test('a readable delivery whose text no enqueued copy carries vetoes its build even when a matched delivery opened it', () => {
  for (const [unmatched, withdrawn] of [[null, ['removed beside a delivery']], ['a delivery whose text no enqueue carries', []]]) {
    const t = transcript();
    t.user('the session starts');
    t.enqueue('opens the channel');
    t.deliver('opens the channel');
    t.op('remove', 'opens the channel');
    t.enqueue('removed beside a delivery');
    t.op('remove', 'removed beside a delivery');
    if (unmatched) t.deliver(unmatched);
    t.pad(REACH);
    const out = mod.extractPrompts(t.text(), true);
    assert.deepEqual(withdrawnTexts(out), withdrawn, `unmatched delivery: ${unmatched}`);
    assert.equal(texts(out).includes('removed beside a delivery'), !withdrawn.length, `unmatched delivery: ${unmatched}`);
  }
});

test('the keep-one fallback restores the newest copy when every copy of a delivered text was withdrawn', () => {
  const t = transcript();
  t.user('the session starts');
  t.enqueue('opens the channel');
  t.deliver('opens the channel');
  t.op('remove', 'opens the channel');
  t.enqueue('withdrawn twice, delivered far away');
  t.op('remove', 'withdrawn twice, delivered far away');
  t.user('asked between the copies');
  const newest = t.enqueue('withdrawn twice, delivered far away');
  t.op('remove', 'withdrawn twice, delivered far away');
  t.pad(REACH);
  t.deliver('withdrawn twice, delivered far away');
  t.pad(REACH);
  const out = mod.extractPrompts(t.text(), true);
  assert.deepEqual(timesOf(out, 'withdrawn twice, delivered far away'), [newest]);
  assert.equal(withdrawnTexts(out).includes('withdrawn twice, delivered far away'), false);
});

test('a text listed as sent never appears among the withdrawn', () => {
  const t = transcript();
  t.user('the session starts');
  t.enqueue('delivered');
  t.deliver('delivered');
  t.op('remove', 'delivered');
  const first = t.enqueue('typed twice, removed once');
  t.enqueue('typed twice, removed once');
  t.op('remove', 'typed twice, removed once');
  t.pad(REACH);
  const out = mod.extractPrompts(t.text(), true);
  assert.deepEqual(timesOf(out, 'typed twice, removed once'), [first]);
  assert.deepEqual(withdrawnTexts(out), []);
});
