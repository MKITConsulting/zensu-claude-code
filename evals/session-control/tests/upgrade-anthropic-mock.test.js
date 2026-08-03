#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const http = require('node:http');
const test = require('node:test');
const { EventEmitter } = require('node:events');
const {
  requestState: requestStateWithSecret,
  sseResponse,
  startUpgradeAnthropicMock,
} = require('../lib/upgrade-anthropic-mock.js');

const FILE = '/tmp/fixture.txt';
const ID_SECRET = Buffer.alloc(32, 0x5a);
const CURRENT_DATE = '2026-07-24';
const CURRENT_DATE_REMINDER = `<system-reminder>
As you answer the user's questions, you can use the following context:
# currentDate
Today's date is ${CURRENT_DATE}.

      IMPORTANT: this context may or may not be relevant to your tasks. You should not respond to this context unless it is highly relevant to your task.
</system-reminder>

`;
const OLD_PROMPT = `Use the Read tool exactly once with file_path ${JSON.stringify(FILE)}. The file contains one opaque token that is not present in this prompt. Use no other tool. After the successful Read result, reply with exactly the opaque token from the file and no other text.`;
const CANDIDATE_PROMPT = `Use the Read tool exactly once with file_path ${JSON.stringify(FILE)}. The file contains one opaque token that is not present in this prompt. Then use the Bash tool exactly once with command "printf '%s\\\\n' ZENSU_UPGRADE_BASH_OK". The command is a harmless shell builtin and must not be changed. Use no other tool. After both successful tool results, reply with exactly the opaque token from the file and no other text.`;

function requestState(value) {
  return requestStateWithSecret(value, { idSecret: ID_SECRET });
}

function body(messages) {
  return {
    model: 'claude-upgrade-mock',
    stream: true,
    tools: [{ name: 'Read' }, { name: 'Bash' }],
    messages,
  };
}

function fakeHttpRuntime({
  address = { address: '127.0.0.1', port: 43123 },
  listenError = null,
  closeHangs = false,
} = {}) {
  let handler = null;
  let closed = false;
  let forcedClosed = false;
  const server = new EventEmitter();
  server.listen = (_port, _host, callback) => {
    if (listenError) {
      process.nextTick(() => server.emit('error', listenError));
      return;
    }
    process.nextTick(callback);
  };
  server.address = () => address;
  server.close = (callback) => {
    closed = true;
    if (!closeHangs && callback) process.nextTick(() => callback(null));
  };
  server.closeAllConnections = () => { forcedClosed = true; };
  server.closeIdleConnections = () => {};
  return {
    runtime: {
      createServer(callback) {
        handler = callback;
        return server;
      },
    },
    get closed() { return closed; },
    get forcedClosed() { return forcedClosed; },
    dispatch({
      method = 'POST',
      url = '/v1/messages',
      headers = {},
      chunks = [],
    } = {}) {
      assert.equal(typeof handler, 'function');
      const request = new EventEmitter();
      request.method = method;
      request.url = url;
      request.headers = headers;
      request.setEncoding = () => {};
      request.destroyed = false;
      request.complete = false;
      request.destroy = () => {
        request.destroyed = true;
        request.emit('aborted');
        request.emit('close');
      };
      const response = {
        status: null,
        headers: null,
        body: '',
        writeHead(status, responseHeaders) {
          this.status = status;
          this.headers = responseHeaders || {};
          return this;
        },
        end(payload = '') {
          this.body += payload;
          return this;
        },
      };
      handler(request, response);
      for (const chunk of chunks) request.emit('data', chunk);
      if (!request.destroyed) {
        request.complete = true;
        request.emit('end');
        request.emit('close');
      }
      return { request, response };
    },
  };
}

test('drives the exact old and candidate tool sequence', () => {
  const read = requestState(body([{ role: 'user', content: OLD_PROMPT }]));
  assert.equal(read.content.name, 'Read');
  assert.deepEqual(read.content.input, { file_path: FILE });

  const oldFinal = requestState(body([
    { role: 'user', content: OLD_PROMPT },
    { role: 'assistant', content: [read.content] },
    {
      role: 'user',
      content: [{
        type: 'tool_result',
        tool_use_id: read.content.id,
        content: 'OLD_ROOT_TURN_ONE_OK\n',
      }],
    },
  ]));
  assert.deepEqual(oldFinal, {
    content: { type: 'text', text: 'OLD_ROOT_TURN_ONE_OK' },
    stopReason: 'end_turn',
  });

  const candidateRead = requestState(body([{ role: 'user', content: CANDIDATE_PROMPT }]));
  const bash = requestState(body([
    { role: 'user', content: CANDIDATE_PROMPT },
    { role: 'assistant', content: [candidateRead.content] },
    {
      role: 'user',
      content: [{
        type: 'tool_result',
        tool_use_id: candidateRead.content.id,
        content: 'FRESH_CANDIDATE_OK\n',
      }],
    },
  ]));
  assert.equal(bash.content.name, 'Bash');
  assert.equal(bash.content.input.command, "printf '%s\\n' ZENSU_UPGRADE_BASH_OK");

  const final = requestState(body([
    { role: 'user', content: CANDIDATE_PROMPT },
    { role: 'assistant', content: [candidateRead.content] },
    {
      role: 'user',
      content: [{
        type: 'tool_result',
        tool_use_id: candidateRead.content.id,
        content: 'FRESH_CANDIDATE_OK\n',
      }],
    },
    { role: 'assistant', content: [bash.content] },
    {
      role: 'user',
      content: [{
        type: 'tool_result',
        tool_use_id: bash.content.id,
        content: 'ZENSU_UPGRADE_BASH_OK\n',
      }],
    },
  ]));
  assert.equal(final.content.text, 'FRESH_CANDIDATE_OK');
});

test('accepts only validated completed history before the active upgrade turn', () => {
  const secondFile = '/tmp/fixture-two.txt';
  const secondPrompt = OLD_PROMPT.replace(FILE, secondFile);
  const thirdFile = '/tmp/fixture-three.txt';
  const thirdPrompt = OLD_PROMPT.replace(FILE, thirdFile);
  const firstRead = requestState(body([
    { role: 'user', content: OLD_PROMPT },
  ])).content;
  const completedFirstTurn = [
    { role: 'user', content: OLD_PROMPT },
    { role: 'assistant', content: [firstRead] },
    {
      role: 'user',
      content: [{
        type: 'tool_result',
        tool_use_id: firstRead.id,
        content: 'OLD_ROOT_TURN_ONE_OK\n',
      }],
    },
    {
      role: 'assistant',
      content: [{ type: 'text', text: 'OLD_ROOT_TURN_ONE_OK' }],
    },
  ];

  const secondRead = requestState(body([
    ...completedFirstTurn,
    { role: 'user', content: secondPrompt },
  ]));
  assert.equal(secondRead.content.name, 'Read');
  assert.deepEqual(secondRead.content.input, { file_path: secondFile });

  const completedSecondTurn = [
    ...completedFirstTurn,
    { role: 'user', content: secondPrompt },
    { role: 'assistant', content: [secondRead.content] },
    {
      role: 'user',
      content: [{
        type: 'tool_result',
        tool_use_id: secondRead.content.id,
        content: 'OLD_ROOT_TURN_TWO_OK\n',
      }],
    },
    {
      role: 'assistant',
      content: [{ type: 'text', text: 'OLD_ROOT_TURN_TWO_OK' }],
    },
  ];
  const thirdRead = requestState(body([
    ...completedSecondTurn,
    { role: 'user', content: thirdPrompt },
  ]));
  assert.equal(thirdRead.content.name, 'Read');
  assert.deepEqual(thirdRead.content.input, { file_path: thirdFile });

  assert.throws(() => requestState(body([
    ...completedFirstTurn.slice(0, -1),
    {
      role: 'assistant',
      content: [{ type: 'text', text: 'FORGED_PRIOR_RESULT' }],
    },
    { role: 'user', content: secondPrompt },
  ])), /completed prior turn final text is invalid/);
  assert.throws(() => requestState(body([
    ...completedFirstTurn.slice(0, -1),
    { role: 'user', content: secondPrompt },
  ])), /completed prior turn is missing its validated final text/);
});

test('rejects every unvalidated message prefix before the first upgrade turn', () => {
  for (const prefix of [
    [{ role: 'user', content: 'unrelated prior request' }],
    [
      { role: 'user', content: 'unrelated prior request' },
      { role: 'assistant', content: 'unrelated prior response' },
    ],
  ]) {
    assert.throws(() => requestState(body([
      ...prefix,
      { role: 'user', content: OLD_PROMPT },
    ])), /unvalidated message prefix/);
  }
  assert.throws(() => requestState(body([{
    role: 'user',
    content: `unrelated prior request\n${OLD_PROMPT}`,
  }])), /unvalidated message prefix/);
});

test('accepts only the exact Claude currentDate preamble attached to the first prompt', () => {
  const withCurrentDate = (messages) => requestStateWithSecret(body(messages), {
    idSecret: ID_SECRET,
    currentDate: CURRENT_DATE,
  });
  const valid = withCurrentDate([{
    role: 'user',
    content: [
      { type: 'text', text: CURRENT_DATE_REMINDER },
      { type: 'text', text: OLD_PROMPT },
    ],
  }]);
  assert.equal(valid.content.name, 'Read');

  for (const messages of [
    [{
      role: 'user',
      content: [
        { type: 'text', text: CURRENT_DATE_REMINDER.replace(CURRENT_DATE, '2026-07-23') },
        { type: 'text', text: OLD_PROMPT },
      ],
    }],
    [
      { role: 'user', content: CURRENT_DATE_REMINDER },
      { role: 'user', content: OLD_PROMPT },
    ],
    [{
      role: 'user',
      content: [
        { type: 'text', text: CURRENT_DATE_REMINDER },
        { type: 'text', text: 'unvalidated extra context' },
        { type: 'text', text: OLD_PROMPT },
      ],
    }],
  ]) {
    assert.throws(() => withCurrentDate(messages), /unvalidated message prefix/);
  }
});

test('rejects zero-block and invalid messages at every history position', () => {
  for (const content of [[], null, {}]) {
    assert.throws(() => requestState(body([
      { role: 'user', content: OLD_PROMPT },
      { role: 'assistant', content },
    ])), /empty or invalid message/);
  }
});

test('requires the exact Read and Bash tool declaration set', () => {
  for (const tools of [
    [],
    [{ name: 'Write' }],
    [null],
    [{ name: 'Read' }],
    [{ name: 'Read' }, { name: 'Read' }],
    [{ name: 'Read' }, { name: 'Bash' }, { name: 'Write' }],
  ]) {
    assert.throws(() => requestState({
      ...body([{ role: 'user', content: OLD_PROMPT }]),
      tools,
    }), /tool declaration contract is invalid/);
  }
});

test('rejects malformed, duplicated, and incomplete sequences', () => {
  assert.throws(() => requestState({}), /request contract is invalid/);
  assert.throws(() => requestState(body([{ role: 'user', content: 'unrelated' }])),
    /unvalidated message prefix/);
  assert.throws(() => requestState(body([
    { role: 'user', content: OLD_PROMPT },
    { role: 'assistant', content: [
      {
        type: 'tool_use',
        id: 'toolu_111111111111111111111111',
        name: 'Read',
        input: { file_path: FILE },
      },
      {
        type: 'tool_use',
        id: 'toolu_222222222222222222222222',
        name: 'Read',
        input: { file_path: FILE },
      },
    ] },
  ])), /Read tool sequence is invalid or duplicated/);
  assert.throws(() => requestState(body([
    { role: 'user', content: OLD_PROMPT },
    { role: 'assistant', content: [{
      type: 'tool_use',
      id: requestState(body([{ role: 'user', content: OLD_PROMPT }])).content.id,
      name: 'Read',
      input: { file_path: FILE },
    }] },
  ])), /Read result token is missing/);
  const prematureCandidateRead = requestState(body([
    { role: 'user', content: CANDIDATE_PROMPT },
  ])).content;
  assert.throws(() => requestState(body([
    { role: 'user', content: CANDIDATE_PROMPT },
    { role: 'assistant', content: [
      prematureCandidateRead,
      {
        type: 'tool_use',
        id: 'toolu_222222222222222222222222',
        name: 'Bash',
        input: {
          command: "printf '%s\\n' ZENSU_UPGRADE_BASH_OK",
          description: 'Print the fixed harmless upgrade probe token',
        },
      },
    ] },
  ])), /Bash tool sequence is invalid or duplicated/);
  assert.throws(() => requestState(body([{
    role: 'user',
    content: 'reply with exactly the opaque token from the file; file_path "\\x"',
  }])), /prompt file path is invalid/);
});

test('binds every tool result to the exact emitted ID and sequence', () => {
  const read = requestState(body([{ role: 'user', content: CANDIDATE_PROMPT }])).content;
  const readResult = {
    type: 'tool_result',
    tool_use_id: read.id,
    content: 'FRESH_CANDIDATE_OK\n',
  };
  const bash = requestState(body([
    { role: 'user', content: CANDIDATE_PROMPT },
    { role: 'assistant', content: [read] },
    { role: 'user', content: [readResult] },
  ])).content;
  const prefix = [
    { role: 'user', content: CANDIDATE_PROMPT },
    { role: 'assistant', content: [read] },
  ];

  assert.throws(() => requestState(body([
    ...prefix,
    {
      role: 'user',
      content: [{
        ...readResult,
        tool_use_id: 'toolu_ffffffffffffffffffffffff',
      }],
    },
  ])), /tool result is unmatched or duplicated/);
  assert.throws(() => requestState(body([
    ...prefix,
    { role: 'user', content: [readResult, readResult] },
  ])), /tool result is unmatched or duplicated/);
  assert.throws(() => requestState(body([
    ...prefix,
    {
      role: 'user',
      content: [{
        ...readResult,
        content: 'OLD_ROOT_TURN_ONE_OK FRESH_CANDIDATE_OK',
      }],
    },
  ])), /Read result token is invalid/);
  assert.throws(() => requestState(body([
    ...prefix,
    { role: 'user', content: [readResult] },
    { role: 'assistant', content: [bash] },
    {
      role: 'user',
      content: [{
        type: 'tool_result',
        tool_use_id: read.id,
        content: 'ZENSU_UPGRADE_BASH_OK\n',
      }],
    },
  ])), /tool result is unmatched or duplicated/);
  assert.throws(() => requestState(body([
    ...prefix,
    { role: 'user', content: [readResult] },
    { role: 'assistant', content: [bash] },
    {
      role: 'user',
      content: [{
        type: 'tool_result',
        tool_use_id: bash.id,
        content: 'wrong Bash output',
      }],
    },
  ])), /Bash result token is invalid/);
  assert.throws(() => requestState(body([
    ...prefix,
    { role: 'user', content: [readResult] },
    { role: 'assistant', content: [bash] },
  ])), /Bash result token is missing/);
});

test('rejects forged tool-use shape, role, input, and unrelated tools', () => {
  const read = requestState(body([{ role: 'user', content: OLD_PROMPT }])).content;
  for (const forged of [
    { ...read, id: 'forged-id' },
    { ...read, id: 'toolu_111111111111111111111111' },
    { ...read, input: { file_path: '/tmp/wrong.txt' } },
    { ...read, input: { file_path: FILE, extra: true } },
    { ...read, name: 'Write' },
  ]) {
    assert.throws(() => requestState(body([
      { role: 'user', content: OLD_PROMPT },
      { role: 'assistant', content: [forged] },
    ])), /identity|sequence|unexpected tool/);
  }
  assert.throws(() => requestState(body([
    { role: 'user', content: OLD_PROMPT },
    { role: 'user', content: [read] },
  ])), /tool sequence identity is invalid/);
  assert.throws(() => requestState(body([
    { role: 'user', content: OLD_PROMPT },
    { role: 'assistant', content: [{ type: 'text', text: 'extra model text' }] },
  ])), /tool sequence contains unexpected text/);
});

test('renders a bounded Anthropic streaming response', () => {
  const payload = sseResponse('claude-upgrade-mock', {
    content: {
      type: 'tool_use',
      id: 'toolu_fixture',
      name: 'Read',
      input: { file_path: FILE },
    },
    stopReason: 'tool_use',
  });
  assert.match(payload, /event: message_start/);
  assert.match(payload, /event: content_block_delta/);
  assert.equal(
    payload.includes('"partial_json":"{\\"file_path\\":\\"/tmp/fixture.txt\\"}"'),
    true,
  );
  assert.match(payload, /event: message_stop/);
});

test('serves only authenticated loopback message requests and reports failures', async (context) => {
  let mock;
  try {
    mock = await startUpgradeAnthropicMock({ apiKey: 'x'.repeat(32) });
  } catch (error) {
    if (error?.code === 'EPERM') {
      context.skip('managed host forbids loopback listeners');
      return;
    }
    throw error;
  }
  const payload = JSON.stringify(body([{ role: 'user', content: OLD_PROMPT }]));
  const result = await new Promise((resolve, reject) => {
    const request = http.request(`${mock.url}/v1/messages`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(payload),
        'x-api-key': mock.apiKey,
      },
    }, (response) => {
      let raw = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => { raw += chunk; });
      response.on('end', () => resolve({ status: response.statusCode, raw }));
    });
    request.on('error', reject);
    request.end(payload);
  });
  assert.equal(result.status, 200);
  assert.match(result.raw, /event: message_stop/);
  assert.equal(mock.requestCount, 1);
  mock.assertHealthy();
  await mock.close();
});

test('enforces route credentials and JSON contracts without a real listener', async () => {
  const key = 'k'.repeat(32);

  const validRuntime = fakeHttpRuntime();
  const validMock = await startUpgradeAnthropicMock({
    apiKey: key,
    runtime: validRuntime.runtime,
  });
  const health = validRuntime.dispatch({ method: 'HEAD', url: '/' });
  assert.equal(health.response.status, 200);
  assert.equal(health.response.headers['cache-control'], 'no-store');
  assert.equal(health.response.body, '');
  assert.equal(validMock.requestCount, 0);
  const validPayload = JSON.stringify(body([{ role: 'user', content: OLD_PROMPT }]));
  const valid = validRuntime.dispatch({
    url: '/v1/messages?beta=true',
    headers: { 'x-api-key': key },
    chunks: [validPayload.slice(0, 17), validPayload.slice(17)],
  });
  assert.equal(valid.response.status, 200);
  assert.match(valid.response.body, /event: message_stop/);
  validMock.assertHealthy();
  await validMock.close();
  assert.equal(validRuntime.closed, true);

  const wrongCredentialRuntime = fakeHttpRuntime();
  const wrongCredentialMock = await startUpgradeAnthropicMock({
    apiKey: key,
    runtime: wrongCredentialRuntime.runtime,
  });
  const rejected = wrongCredentialRuntime.dispatch({
    headers: { 'x-api-key': 'forged-key' },
    chunks: [validPayload],
  });
  assert.equal(rejected.response.status, 404);
  assert.throws(() => wrongCredentialMock.assertHealthy(), /route or credential is invalid/);
  await assert.rejects(wrongCredentialMock.close(), /route or credential is invalid/);

  const invalidJsonRuntime = fakeHttpRuntime();
  const invalidJsonMock = await startUpgradeAnthropicMock({
    apiKey: key,
    runtime: invalidJsonRuntime.runtime,
  });
  const invalidJson = invalidJsonRuntime.dispatch({
    headers: { 'x-api-key': key },
    chunks: ['{'],
  });
  assert.equal(invalidJson.response.status, 400);
  assert.equal(
    invalidJson.response.body,
    '{"type":"error","error":{"type":"invalid_request_error","message":"rejected"}}',
  );
  await assert.rejects(invalidJsonMock.close(), /request JSON is invalid/);
});

test('fails closed on oversized input and request flooding', async () => {
  const key = 'b'.repeat(32);
  const oversizedRuntime = fakeHttpRuntime();
  const oversizedMock = await startUpgradeAnthropicMock({
    apiKey: key,
    runtime: oversizedRuntime.runtime,
  });
  const oversized = oversizedRuntime.dispatch({
    headers: { 'x-api-key': key },
    chunks: ['x'.repeat((4 * 1024 * 1024) + 1)],
  });
  assert.equal(oversized.request.destroyed, true);
  assert.equal(oversized.response.status, null);
  assert.throws(() => oversizedMock.assertHealthy(), /request is oversized/);
  await assert.rejects(oversizedMock.close(), /request is oversized/);

  const boundedRuntime = fakeHttpRuntime();
  const boundedMock = await startUpgradeAnthropicMock({
    apiKey: key,
    runtime: boundedRuntime.runtime,
  });
  const payload = JSON.stringify(body([{ role: 'user', content: OLD_PROMPT }]));
  for (let index = 0; index < 32; index += 1) {
    const accepted = boundedRuntime.dispatch({
      headers: { 'x-api-key': key },
      chunks: [payload],
    });
    assert.equal(accepted.response.status, 200);
  }
  const excess = boundedRuntime.dispatch({
    headers: { 'x-api-key': key },
    chunks: [payload],
  });
  assert.equal(excess.response.status, 429);
  assert.equal(boundedMock.requestCount, 33);
  await assert.rejects(boundedMock.close(), /request bound was exceeded/);
});

test('bounds mock shutdown and force-closes a stuck server', async () => {
  const hangingRuntime = fakeHttpRuntime({ closeHangs: true });
  const hangingMock = await startUpgradeAnthropicMock({
    apiKey: 's'.repeat(32),
    shutdownTimeoutMs: 10,
    runtime: hangingRuntime.runtime,
  });
  await assert.rejects(
    hangingMock.close(),
    /server shutdown exceeded its bound/,
  );
  assert.equal(hangingRuntime.closed, true);
  assert.equal(hangingRuntime.forcedClosed, true);

  await assert.rejects(
    startUpgradeAnthropicMock({
      apiKey: 's'.repeat(32),
      shutdownTimeoutMs: 0,
      runtime: hangingRuntime.runtime,
    }),
    /server policy is invalid/,
  );
});

test('rejects unsafe server policies and non-loopback bind results', async () => {
  await assert.rejects(
    startUpgradeAnthropicMock({ host: '0.0.0.0', apiKey: 'x'.repeat(32) }),
    /server policy is invalid/,
  );
  await assert.rejects(
    startUpgradeAnthropicMock({ apiKey: 'short' }),
    /server policy is invalid/,
  );
  const badAddressRuntime = fakeHttpRuntime({
    address: { address: '0.0.0.0', port: 43123 },
  });
  await assert.rejects(
    startUpgradeAnthropicMock({
      apiKey: 'x'.repeat(32),
      runtime: badAddressRuntime.runtime,
    }),
    /loopback binding is invalid/,
  );
  assert.equal(badAddressRuntime.closed, true);

  const listenError = Object.assign(new Error('listen denied'), { code: 'EPERM' });
  await assert.rejects(
    startUpgradeAnthropicMock({
      apiKey: 'x'.repeat(32),
      runtime: fakeHttpRuntime({ listenError }).runtime,
    }),
    /listen denied/,
  );
});
