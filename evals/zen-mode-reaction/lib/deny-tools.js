'use strict';

const REASON = 'Tool calls are not available in this evaluation. Answer in prose instead.';

process.stdin.resume();
process.stdin.on('error', () => {});
process.stdin.on('end', () => {
  process.stdout.write(`${JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: REASON,
    },
  })}\n`);
});
