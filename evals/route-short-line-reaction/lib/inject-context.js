'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

function main(dir, hook) {
  if (!dir) return '';
  let text;
  try {
    text = fs.readFileSync(path.join(dir, 'inject.txt'), 'utf8');
  } catch (_) {
    return '';
  }
  if (!text) return '';
  const sha256 = crypto.createHash('sha256').update(text, 'utf8').digest('hex');
  try {
    fs.appendFileSync(path.join(dir, 'hook.log'), `inject ${JSON.stringify({ hook: hook || '', sha256, chars: text.length })}\n`, { mode: 0o600 });
  } catch (_) {
    return '';
  }
  return JSON.stringify({ hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: text } });
}

if (require.main === module) {
  process.stdin.resume();
  process.stdin.on('data', () => {});
  process.stdin.on('end', () => {
    const out = main(process.env.ZENSU_ROUTE_EVAL_DIR || '', process.env.ZENSU_ROUTE_EVAL_HOOK || '');
    if (out) process.stdout.write(`${out}\n`);
  });
}

module.exports = { main };
