import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const mod = await import(new URL('../../hooks/lib/session-hub-receipt-v1.mjs', import.meta.url));
const lineage = await import(new URL('../../skills/session-trail/scripts/session-lineage-v1.mjs', import.meta.url));
const contract = JSON.parse(fs.readFileSync(new URL('../../skills/session-trail/handover-contract.json', import.meta.url), 'utf8'));

const tmp = () => fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-receipt-unit-')));
const SID = '0f8fad5b-d9cb-469f-a165-70867728950e';
const TOKEN = '9b2c4e6a8d0f1b3c5e7a9c1e3f5b7d90';
const RAW = `/zensu:session-trail takeover ${SID} --all --receipt ${TOKEN}`;
const tagged = (args, name = '/zensu:session-trail') =>
  `<command-message>zensu:session-trail</command-message>\n<command-name>${name}</command-name>\n<command-args>${args}</command-args>`;
const payload = (prompt, extra = {}) => ({
  session_id: 'abc',
  cwd: '/tmp',
  hook_event_name: 'UserPromptSubmit',
  prompt,
  ...extra,
});
const NOW = Date.parse('2026-10-11T12:00:00.000Z');

test('the raw command the Session Hub types yields its token', () => {
  assert.equal(mod.receiptToken(RAW), TOKEN);
  assert.equal(mod.receiptToken(`  ${RAW}\n`), TOKEN);
});

test('the command-tag spelling yields the same token, in either tag order', () => {
  assert.equal(mod.receiptToken(tagged(`takeover ${SID} --all --receipt ${TOKEN}`)), TOKEN);
  const reordered = `<command-name>/zensu:session-trail</command-name>\n<command-args> takeover ${SID} --all --receipt ${TOKEN} </command-args>`;
  assert.equal(mod.receiptToken(reordered), TOKEN);
});

test('leading system reminders are skipped before the command is read', () => {
  const prompt = `<system-reminder>\nYou are operating in a git worktree.\n</system-reminder>\n\n<system-reminder>b</system-reminder>\n${RAW}`;
  assert.equal(mod.receiptToken(prompt), TOKEN);
  assert.equal(mod.receiptToken(`<system-reminder>never closed ${RAW}`), null);
});

test('every other shape yields no token', () => {
  const refused = [
    `please run ${RAW}`,
    `${RAW} now`,
    `${RAW}\nand more`,
    RAW.replace(TOKEN, TOKEN.toUpperCase()),
    RAW.replace(TOKEN, `${TOKEN}0`),
    RAW.replace(TOKEN, TOKEN.slice(1)),
    RAW.replace(SID, SID.toUpperCase()),
    RAW.replace(SID, SID.replace(/-/g, '')),
    RAW.replace(' --all', ''),
    RAW.replace(' --all', ' --all --force'),
    RAW.replace('takeover ', 'show '),
    RAW.replace('takeover ', 'takeover  '),
    RAW.replace('/zensu:session-trail', '/session-trail'),
    `${RAW} --receipt ${TOKEN}`,
    tagged(`takeover ${SID} --all --receipt ${TOKEN}`, '/zensu:other'),
    tagged(`takeover ${SID} --all`),
    `${tagged(`takeover ${SID} --all --receipt ${TOKEN}`)}\ntrailing text`,
    `${tagged(`takeover ${SID} --all --receipt ${TOKEN}`)}\n<command-args>x</command-args>`,
    '<command-message>zensu:session-trail</command-message>',
    '',
    `${'a'.repeat(300 * 1024)}${RAW}`,
  ];
  for (const prompt of refused) assert.equal(mod.receiptToken(prompt), null, prompt.slice(0, 80));
  for (const value of [undefined, null, 7, {}, [RAW]]) assert.equal(mod.receiptToken(value), null);
});

test('a receipt carries exactly six fields and only for a UserPromptSubmit payload', () => {
  const receipt = mod.receiptFor(payload(RAW), '0.25.0', NOW);
  assert.deepEqual(receipt, {
    schemaVersion: 1,
    kind: 'session-hub-receipt',
    token: TOKEN,
    event: 'UserPromptSubmit',
    plugin: '0.25.0',
    recordedAt: '2026-10-11T12:00:00.000Z',
  });
  assert.equal(mod.receiptFor(payload(RAW, { hook_event_name: 'UserPromptExpansion' }), '0.25.0', NOW), null);
  assert.equal(mod.receiptFor([payload(RAW)], '0.25.0', NOW), null);
  assert.equal(mod.receiptFor(null, '0.25.0', NOW), null);
  assert.equal(mod.receiptFor(payload(RAW), 'not a version\n', NOW).plugin, null);
  assert.equal(mod.receiptFor(payload(RAW), null, NOW).plugin, null);
});

test('the module speaks the command and directory its handover contract declares', () => {
  assert.equal(contract.schemaVersion, 1);
  assert.equal(contract.takeover.contract, 1);
  assert.equal(contract.takeover.prefix, mod.TAKEOVER_PREFIX);
  assert.equal(contract.takeover.suffix, mod.TAKEOVER_SUFFIX);
  assert.equal(contract.takeover.receipt, mod.RECEIPT_FLAG);
  assert.equal(contract.receipts.directory, mod.RECEIPT_DIRECTORY);
  assert.equal(contract.receipts.schemaVersion, mod.RECEIPT_SCHEMA_VERSION);
  assert.equal(`${contract.takeover.prefix}${SID}${contract.takeover.suffix}${contract.takeover.receipt}${TOKEN}`, RAW);
});

test('the linked-sessions capability names the lineage ledger a takeover writes, beside an unchanged takeover contract', () => {
  assert.deepEqual(Object.keys(contract), ['schemaVersion', 'takeover', 'receipts', 'linkedSessions']);
  assert.equal(contract.takeover.contract, 1);
  assert.deepEqual(contract.linkedSessions, {
    contract: 1,
    lineage: { directory: 'zensu/session-lineage/v1/edges', schemaVersion: 1 },
  });
  const root = path.join(os.tmpdir(), 'zensu-receipt-unit-root');
  assert.equal(path.relative(root, lineage.ledgerPaths(root).edges).split(path.sep).join('/'), contract.linkedSessions.lineage.directory);
  assert.equal(contract.linkedSessions.lineage.schemaVersion, lineage.LEDGER_SCHEMA_VERSION);
});

test('the config root follows CLAUDE_CONFIG_DIR and falls back to ~/.claude', () => {
  assert.equal(mod.configRoot({ CLAUDE_CONFIG_DIR: ' /x/cfg ' }, '/home/u'), path.resolve('/x/cfg'));
  assert.equal(mod.configRoot({ CLAUDE_CONFIG_DIR: '   ' }, '/home/u'), path.join('/home/u', '.claude'));
  assert.equal(mod.configRoot({}, '/home/u'), path.join('/home/u', '.claude'));
});

test('a receipt lands once, private, and is never replaced', () => {
  const root = tmp();
  const receipt = mod.receiptFor(payload(RAW), '0.25.0', NOW);
  assert.equal(mod.landReceipt(root, receipt), true);
  const dir = mod.receiptsDir(root);
  const file = path.join(dir, `${TOKEN}.json`);
  assert.deepEqual(fs.readdirSync(dir), [`${TOKEN}.json`]);
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  for (const level of [dir, path.dirname(dir), path.dirname(path.dirname(dir)), path.join(root, 'zensu')]) {
    assert.equal(fs.statSync(level).mode & 0o777, 0o700, level);
  }
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), receipt);
  const later = { ...receipt, recordedAt: '2026-10-12T00:00:00.000Z' };
  assert.equal(mod.landReceipt(root, later), false);
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), receipt);
  assert.deepEqual(fs.readdirSync(dir), [`${TOKEN}.json`]);
});

test('a symlinked component below the config root is refused and nothing lands behind it', () => {
  const root = tmp();
  const elsewhere = tmp();
  fs.symlinkSync(elsewhere, path.join(root, 'zensu'));
  const receipt = mod.receiptFor(payload(RAW), '0.25.0', NOW);
  assert.throws(() => mod.landReceipt(root, receipt), /symlinked/);
  assert.deepEqual(fs.readdirSync(elsewhere), []);
});

test('pruning removes only old receipts and temps, within its scan bound', () => {
  const root = tmp();
  const dir = mod.receiptsDir(root);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const old = NOW - mod.RECEIPT_RETENTION_MS - 60_000;
  const put = (name, at) => {
    const file = path.join(dir, name);
    fs.writeFileSync(file, '{}\n', { mode: 0o600 });
    fs.utimesSync(file, at / 1000, at / 1000);
    return file;
  };
  put(`${'a'.repeat(32)}.json`, old);
  put('.receipt-123-abcdefabcdef.tmp', old);
  put(`${'b'.repeat(32)}.json`, NOW - 1000);
  put('notes.json', old);
  put(`${'C'.repeat(32)}.json`, old);
  assert.equal(mod.pruneReceipts(root, NOW), 2);
  assert.deepEqual(fs.readdirSync(dir).sort(), [`${'C'.repeat(32)}.json`, `${'b'.repeat(32)}.json`, 'notes.json'].sort());
  for (const name of fs.readdirSync(dir)) fs.unlinkSync(path.join(dir, name));
  for (let i = 0; i < 6; i += 1) put(`${String(i).repeat(32)}.json`, old);
  assert.equal(mod.pruneReceipts(root, NOW, 2), 2);
  assert.equal(fs.readdirSync(dir).length, 4);
});

test('pruning never follows a symlinked receipts directory', () => {
  const root = tmp();
  const elsewhere = tmp();
  fs.mkdirSync(path.dirname(mod.receiptsDir(root)), { recursive: true, mode: 0o700 });
  fs.symlinkSync(elsewhere, mod.receiptsDir(root));
  const victim = path.join(elsewhere, `${'d'.repeat(32)}.json`);
  fs.writeFileSync(victim, '{}\n');
  fs.utimesSync(victim, 1, 1);
  assert.equal(mod.pruneReceipts(root, NOW), 0);
  assert.equal(fs.existsSync(victim), true);
});

test('recording needs the skill on disk and writes nothing for any other prompt', () => {
  const plugin = tmp();
  const config = tmp();
  const env = { CLAUDE_CONFIG_DIR: config };
  const text = JSON.stringify(payload(RAW));
  assert.equal(mod.record(text, env, NOW, plugin), null);
  assert.equal(fs.existsSync(path.join(config, 'zensu')), false);
  fs.mkdirSync(path.join(plugin, 'skills', 'session-trail', 'scripts'), { recursive: true });
  fs.mkdirSync(path.join(plugin, '.claude-plugin'), { recursive: true });
  fs.writeFileSync(path.join(plugin, 'skills', 'session-trail', 'SKILL.md'), '# skill\n');
  fs.writeFileSync(path.join(plugin, 'skills', 'session-trail', 'scripts', 'trail.mjs'), '\n');
  fs.writeFileSync(path.join(plugin, '.claude-plugin', 'plugin.json'), '{"name":"zensu","version":"9.8.7"}\n');
  assert.equal(mod.record(JSON.stringify(payload(`run ${RAW}`)), env, NOW, plugin), null);
  assert.equal(mod.record('{not json', env, NOW, plugin), null);
  assert.equal(fs.existsSync(path.join(config, 'zensu')), false);
  const landed = mod.record(text, env, NOW, plugin);
  assert.equal(landed.plugin, '9.8.7');
  assert.deepEqual(fs.readdirSync(mod.receiptsDir(config)), [`${TOKEN}.json`]);
  assert.equal(mod.record(text, env, NOW, plugin), null);
});
