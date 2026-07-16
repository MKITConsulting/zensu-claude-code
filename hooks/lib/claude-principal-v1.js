'use strict';

const PRINCIPALS = Object.freeze({
  MAIN: 'main-v1',
  REVIEWER: 'reviewer-readonly-v1',
  HOST: 'host-profile-v1',
});

// Claude Code's SubagentStart and PreToolUse payloads report plugin agents by
// their bare frontmatter `name`. Keep this allowlist exact: aliases, paths,
// namespace-looking strings, and repository-defined custom agents are neutral.
const REVIEWER_TYPES = new Set(['code-reviewer', 'review-aspect', 'review-judge']);

function boundedIdentity(value) {
  return typeof value === 'string'
    && value.trim() !== ''
    && value.length <= 512
    && !/[\0\r\n]/.test(value);
}

function classifySubagent(agentType, agentId) {
  // Claude's documented security-relevant discriminator is the bare
  // `agent_type`; `agent_id` is useful correlation metadata but is not
  // guaranteed on every hook payload. Never let a missing correlation id turn
  // an exact read-only reviewer into the broader neutral capability profile.
  if (!boundedIdentity(agentType)) return PRINCIPALS.HOST;
  if (agentId !== undefined && !boundedIdentity(agentId)) return PRINCIPALS.HOST;
  if (REVIEWER_TYPES.has(agentType)) return PRINCIPALS.REVIEWER;
  return PRINCIPALS.HOST;
}

function classifyPreToolPayload(payload) {
  const hasAgentId = Object.prototype.hasOwnProperty.call(payload, 'agent_id');
  const hasAgentType = Object.prototype.hasOwnProperty.call(payload, 'agent_type');
  // The interactive host process has neither subagent field. This is the only
  // implicit main identity; every reported or partial subagent identity goes
  // through the exact allowlists above.
  if (!hasAgentId && !hasAgentType) return PRINCIPALS.MAIN;
  return classifySubagent(payload.agent_type, payload.agent_id);
}

module.exports = {
  PRINCIPALS,
  REVIEWER_TYPES,
  classifySubagent,
  classifyPreToolPayload,
};
