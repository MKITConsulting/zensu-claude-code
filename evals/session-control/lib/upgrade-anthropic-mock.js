#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const http = require('node:http');

class UpgradeAnthropicMockError extends Error {}

const MAX_REQUEST_BYTES = 4 * 1024 * 1024;
const MAX_REQUESTS = 32;
const DEFAULT_SHUTDOWN_TIMEOUT_MS = 5000;
const TOKENS = Object.freeze([
  'OLD_ROOT_TURN_ONE_OK',
  'OLD_ROOT_TURN_TWO_OK',
  'OLD_ROOT_TURN_THREE_OK',
  'FRESH_CANDIDATE_OK',
]);
const BASH_COMMAND = "printf '%s\\n' ZENSU_UPGRADE_BASH_OK";
const BASH_OUTPUT = 'ZENSU_UPGRADE_BASH_OK';
const BASH_DESCRIPTION = 'Print the fixed harmless upgrade probe token';

function mockError(message) {
  return new UpgradeAnthropicMockError(`upgrade Anthropic mock: ${message}`);
}

function contentBlocks(message) {
  return Array.isArray(message?.content)
    ? message.content
    : typeof message?.content === 'string'
      ? [{ type: 'text', text: message.content }]
      : [];
}

function exactKeys(value, expected) {
  return value && typeof value === 'object' && !Array.isArray(value)
    && JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}

function validToolUseId(value) {
  return typeof value === 'string' && /^toolu_[a-f0-9]{24}$/.test(value);
}

function expectedToolUseId(secret, prompt, readPath, toolName) {
  if (!Buffer.isBuffer(secret) || secret.length !== 32) {
    throw mockError('tool identity key is invalid');
  }
  const digest = crypto.createHmac('sha256', secret)
    .update(JSON.stringify([prompt, readPath, toolName]), 'utf8')
    .digest('hex')
    .slice(0, 24);
  return `toolu_${digest}`;
}

function resultText(block) {
  return typeof block.content === 'string'
    ? block.content
    : JSON.stringify(block.content ?? '');
}

function validToolDeclarations(tools) {
  if (!Array.isArray(tools) || tools.length !== 2) return false;
  const names = tools.map((tool) => (
    tool && typeof tool === 'object' && !Array.isArray(tool)
      ? tool.name
      : null
  ));
  return names.every((name) => typeof name === 'string')
    && JSON.stringify(names.sort()) === JSON.stringify(['Bash', 'Read']);
}

function canonicalUpgradePrompt(text) {
  if (typeof text !== 'string'
      || !text.includes('reply with exactly the opaque token from the file')) {
    return null;
  }
  const match = text.match(/file_path ("(?:\\.|[^"\\])*")/);
  if (!match) throw mockError('prompt file path is missing');
  let readPath;
  try { readPath = JSON.parse(match[1]); }
  catch (_error) { throw mockError('prompt file path is invalid'); }
  if (typeof readPath !== 'string' || !readPath) {
    throw mockError('prompt file path is invalid');
  }
  const oldPrompt = `Use the Read tool exactly once with file_path ${JSON.stringify(readPath)}. The file contains one opaque token that is not present in this prompt. Use no other tool. After the successful Read result, reply with exactly the opaque token from the file and no other text.`;
  const candidatePrompt = `Use the Read tool exactly once with file_path ${JSON.stringify(readPath)}. The file contains one opaque token that is not present in this prompt. Then use the Bash tool exactly once with command ${JSON.stringify(BASH_COMMAND)}. The command is a harmless shell builtin and must not be changed. Use no other tool. After both successful tool results, reply with exactly the opaque token from the file and no other text.`;
  if (text === oldPrompt) return { candidate: false, readPath };
  if (text === candidatePrompt) return { candidate: true, readPath };
  return null;
}

function localCalendarDate(now = new Date()) {
  const year = String(now.getFullYear()).padStart(4, '0');
  const month = String(now.getMonth() + 1).padStart(2, '0');
  const day = String(now.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

function currentDateReminder(currentDate) {
  if (typeof currentDate !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(currentDate)) {
    throw mockError('current date contract is invalid');
  }
  return `<system-reminder>
As you answer the user's questions, you can use the following context:
# currentDate
Today's date is ${currentDate}.

      IMPORTANT: this context may or may not be relevant to your tasks. You should not respond to this context unless it is highly relevant to your task.
</system-reminder>

`;
}

function requestState(body, {
  idSecret,
  currentDate = localCalendarDate(),
} = {}) {
  if (!body || typeof body !== 'object' || Array.isArray(body)
      || !Array.isArray(body.messages) || !Array.isArray(body.tools)
      || typeof body.model !== 'string' || !body.model
      || body.stream !== true) {
    throw mockError('request contract is invalid');
  }
  if (!validToolDeclarations(body.tools)) {
    throw mockError('tool declaration contract is invalid');
  }
  if (!Buffer.isBuffer(idSecret) || idSecret.length !== 32) {
    throw mockError('tool identity key is invalid');
  }
  const expectedCurrentDateReminder = currentDateReminder(currentDate);

  let prompt = '';
  let readPath = '';
  let readResult = '';
  let readUseId = '';
  let readResultSeen = false;
  let bashUseId = '';
  let bashResultSeen = false;
  let finalSeen = false;
  let candidate = false;
  const candidateTurn = () => candidate;
  const completedToolSequence = () => (
    readUseId
      && readResultSeen
      && readResult
      && (candidateTurn()
        ? bashUseId && bashResultSeen
        : !bashUseId && !bashResultSeen)
  );
  for (let messageIndex = 0; messageIndex < body.messages.length; messageIndex += 1) {
    const message = body.messages[messageIndex];
    const blocks = contentBlocks(message);
    if (blocks.length === 0) {
      throw mockError('empty or invalid message is present');
    }
    for (let blockIndex = 0; blockIndex < blocks.length; blockIndex += 1) {
      const block = blocks[blockIndex];
      if (!prompt && messageIndex === 0 && blockIndex === 0 && blocks.length === 2
          && message?.role === 'user' && block?.type === 'text'
          && block.text === expectedCurrentDateReminder) {
        continue;
      }
      const promptContract = block?.type === 'text' && message?.role === 'user'
        ? canonicalUpgradePrompt(block.text)
        : null;
      if (promptContract) {
        if (prompt && !finalSeen) {
          throw mockError('completed prior turn is missing its validated final text');
        }
        prompt = block.text;
        readPath = promptContract.readPath;
        candidate = promptContract.candidate;
        readResult = '';
        readUseId = '';
        readResultSeen = false;
        bashUseId = '';
        bashResultSeen = false;
        finalSeen = false;
        continue;
      }
      if (!prompt) throw mockError('unvalidated message prefix is present');
      if (block?.type === 'tool_use') {
        if (message?.role !== 'assistant' || !validToolUseId(block.id)) {
          throw mockError('tool sequence identity is invalid');
        }
        if (block.name === 'Read') {
          if (readUseId || readResultSeen || bashUseId || bashResultSeen
              || !exactKeys(block.input, ['file_path'])
              || block.input.file_path !== readPath
              || block.id !== expectedToolUseId(idSecret, prompt, readPath, 'Read')) {
            throw mockError('Read tool sequence is invalid or duplicated');
          }
          readUseId = block.id;
        } else if (block.name === 'Bash') {
          if (!readResultSeen || bashUseId || bashResultSeen
              || !exactKeys(block.input, ['command', 'description'])
              || block.input.command !== BASH_COMMAND
              || block.input.description !== BASH_DESCRIPTION
              || block.id !== expectedToolUseId(idSecret, prompt, readPath, 'Bash')) {
            throw mockError('Bash tool sequence is invalid or duplicated');
          }
          bashUseId = block.id;
        } else {
          throw mockError('unexpected tool use is present');
        }
      } else if (block?.type === 'tool_result') {
        if (message?.role !== 'user' || typeof block.tool_use_id !== 'string'
            || block.is_error === true) {
          throw mockError('tool result identity is invalid');
        }
        if (block.tool_use_id === readUseId && readUseId && !readResultSeen
            && !bashUseId && !bashResultSeen) {
          const raw = resultText(block);
          const matchingTokens = TOKENS.filter((candidate) => raw.includes(candidate));
          if (matchingTokens.length !== 1) throw mockError('Read result token is invalid');
          readResult = matchingTokens[0];
          readResultSeen = true;
        } else if (block.tool_use_id === bashUseId && bashUseId && !bashResultSeen) {
          if (!resultText(block).includes(BASH_OUTPUT)) {
            throw mockError('Bash result token is invalid');
          }
          bashResultSeen = true;
        } else {
          throw mockError('tool result is unmatched or duplicated');
        }
      } else if (block?.type === 'text' && typeof block.text === 'string' && block.text) {
        if (message?.role === 'assistant' && !finalSeen && completedToolSequence()) {
          if (block.text !== readResult) {
            throw mockError('completed prior turn final text is invalid');
          }
          finalSeen = true;
        } else {
          throw mockError('tool sequence contains unexpected text');
        }
      } else {
        throw mockError('tool sequence contains unsupported content');
      }
    }
  }
  if (!prompt || finalSeen || typeof readPath !== 'string' || !readPath) {
    throw mockError('request does not contain the active upgrade prompt');
  }
  const activeCandidate = candidateTurn();
  if (!readUseId) {
    return {
      content: {
        type: 'tool_use',
        id: expectedToolUseId(idSecret, prompt, readPath, 'Read'),
        name: 'Read',
        input: { file_path: readPath },
      },
      stopReason: 'tool_use',
    };
  }
  if (!readResultSeen || !readResult) throw mockError('Read result token is missing');
  if (!activeCandidate && (bashUseId || bashResultSeen)) {
    throw mockError('Bash tool sequence is unexpected');
  }
  if (activeCandidate && !bashUseId) {
    return {
      content: {
        type: 'tool_use',
        id: expectedToolUseId(idSecret, prompt, readPath, 'Bash'),
        name: 'Bash',
        input: {
          command: BASH_COMMAND,
          description: BASH_DESCRIPTION,
        },
      },
      stopReason: 'tool_use',
    };
  }
  if (activeCandidate && !bashResultSeen) throw mockError('Bash result token is missing');
  return {
    content: { type: 'text', text: readResult },
    stopReason: 'end_turn',
  };
}

function sseResponse(model, result) {
  const id = `msg_${crypto.randomBytes(12).toString('hex')}`;
  const start = {
    type: 'message_start',
    message: {
      id,
      type: 'message',
      role: 'assistant',
      model,
      content: [],
      stop_reason: null,
      stop_sequence: null,
      usage: {
        input_tokens: 1,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        output_tokens: 1,
      },
    },
  };
  const blockStart = {
    type: 'content_block_start',
    index: 0,
    content_block: result.content.type === 'tool_use'
      ? { ...result.content, input: {} }
      : { type: 'text', text: '' },
  };
  const delta = result.content.type === 'tool_use'
    ? {
      type: 'content_block_delta',
      index: 0,
      delta: {
        type: 'input_json_delta',
        partial_json: JSON.stringify(result.content.input),
      },
    }
    : {
      type: 'content_block_delta',
      index: 0,
      delta: { type: 'text_delta', text: result.content.text },
    };
  const events = [
    start,
    blockStart,
    delta,
    { type: 'content_block_stop', index: 0 },
    {
      type: 'message_delta',
      delta: { stop_reason: result.stopReason, stop_sequence: null },
      usage: { output_tokens: 1 },
    },
    { type: 'message_stop' },
  ];
  return events.map((event) => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join('');
}

async function startUpgradeAnthropicMock({
  host = '127.0.0.1',
  apiKey = `zensu-upgrade-dummy-${crypto.randomBytes(24).toString('hex')}`,
  shutdownTimeoutMs = DEFAULT_SHUTDOWN_TIMEOUT_MS,
  runtime = http,
} = {}) {
  if (host !== '127.0.0.1' || typeof apiKey !== 'string'
      || apiKey.length < 32 || /[\0\r\n]/.test(apiKey)
      || !Number.isInteger(shutdownTimeoutMs)
      || shutdownTimeoutMs < 10
      || shutdownTimeoutMs > DEFAULT_SHUTDOWN_TIMEOUT_MS
      || typeof runtime?.createServer !== 'function') {
    throw mockError('server policy is invalid');
  }
  let requests = 0;
  let failure = null;
  const idSecret = crypto.randomBytes(32);
  const currentDate = localCalendarDate();
  const sockets = new Set();
  const latchFailure = (error) => {
    if (!failure) failure = error instanceof UpgradeAnthropicMockError
      ? error : mockError('request transport failed');
  };
  const server = runtime.createServer((request, response) => {
    if (request.method === 'HEAD' && request.url === '/') {
      response.writeHead(200, {
        'cache-control': 'no-store',
        connection: 'close',
      });
      response.end();
      return;
    }
    requests += 1;
    if (requests > MAX_REQUESTS) {
      latchFailure(mockError('request bound was exceeded'));
      response.writeHead(429).end();
      return;
    }
    if (request.method !== 'POST' || !/^\/v1\/messages(?:\?.*)?$/.test(request.url || '')
        || request.headers['x-api-key'] !== apiKey) {
      latchFailure(mockError('request route or credential is invalid'));
      response.writeHead(404).end();
      return;
    }
    let raw = '';
    let rawBytes = 0;
    let ended = false;
    let rejected = false;
    request.setEncoding('utf8');
    request.on('data', (chunk) => {
      if (rejected) return;
      rawBytes += Buffer.byteLength(chunk);
      if (rawBytes > MAX_REQUEST_BYTES) {
        rejected = true;
        latchFailure(mockError('request is oversized'));
        request.destroy();
        return;
      }
      raw += chunk;
    });
    request.on('aborted', () => {
      if (!ended) latchFailure(mockError('request transport aborted'));
    });
    request.on('error', () => {
      if (!ended) latchFailure(mockError('request transport failed'));
    });
    request.on('close', () => {
      if (!ended) latchFailure(mockError('request transport closed before completion'));
    });
    request.on('end', () => {
      ended = true;
      if (rejected) return;
      try {
        const body = JSON.parse(raw);
        const result = requestState(body, { idSecret, currentDate });
        const payload = sseResponse(body.model, result);
        response.writeHead(200, {
          'content-type': 'text/event-stream',
          'cache-control': 'no-cache',
          connection: 'keep-alive',
        });
        response.end(payload);
      } catch (error) {
        latchFailure(error instanceof UpgradeAnthropicMockError
          ? error : mockError('request JSON is invalid'));
        response.writeHead(400, { 'content-type': 'application/json' });
        response.end('{"type":"error","error":{"type":"invalid_request_error","message":"rejected"}}');
      }
    });
  });
  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, host, resolve);
  });
  const address = server.address();
  if (!address || typeof address !== 'object' || address.address !== host
      || !Number.isInteger(address.port) || address.port <= 0) {
    server.close();
    throw mockError('loopback binding is invalid');
  }
  return {
    apiKey,
    url: `http://${host}:${address.port}`,
    get requestCount() { return requests; },
    assertHealthy() {
      if (failure) throw failure;
      if (requests === 0) throw mockError('received no model requests');
    },
    async close() {
      try {
        await new Promise((resolve, reject) => {
          let settled = false;
          const finish = (error = null) => {
            if (settled) return;
            settled = true;
            clearTimeout(timeout);
            if (error) reject(error);
            else resolve();
          };
          const timeout = setTimeout(() => {
            for (const socket of sockets) socket.destroy();
            server.closeAllConnections?.();
            finish(mockError('server shutdown exceeded its bound'));
          }, shutdownTimeoutMs);
          server.close((error) => finish(error));
          server.closeIdleConnections?.();
        });
      } finally {
        idSecret.fill(0);
      }
      if (failure) throw failure;
    },
  };
}

module.exports = {
  UpgradeAnthropicMockError,
  requestState,
  sseResponse,
  startUpgradeAnthropicMock,
};
