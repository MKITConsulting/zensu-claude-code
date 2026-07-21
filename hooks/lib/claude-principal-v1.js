'use strict';

const PRINCIPALS = Object.freeze({
  MAIN: 'main-v1',
  REVIEWER: 'reviewer-readonly-v1',
  EVIDENCE_WORKER: 'evidence-worker-v1',
  HOST: 'host-profile-v1',
});

// Claude Code reports plugin-shipped agents with the plugin-scoped identifier.
// Bare names remain exact read-only identities for the --agents evaluation
// fixtures and same-named project agents; neither form grants main authority.
const REVIEWER_TYPES = new Set([
  'zensu:code-reviewer',
  'zensu:review-aspect',
  'zensu:review-judge',
  'code-reviewer',
  'review-aspect',
  'review-judge',
]);
const PLM_TYPES = new Set(['zensu:zensu-plm', 'zensu-plm']);
const EVIDENCE_WORKER_TYPES = new Set([
  'zensu:plan-review-worker',
  'zensu:pr-review-worker',
]);

function boundedIdentity(value) {
  return typeof value === 'string'
    && value.trim() !== ''
    && value.length <= 512
    && !/[\0\r\n]/.test(value);
}

function classifySubagent(agentType, agentId) {
  // Claude's documented security-relevant discriminator is `agent_type`;
  // plugin-shipped agents use scoped identifiers while explicit --agents test
  // fixtures may use the exact bare names above. `agent_id` is correlation
  // metadata and is not guaranteed on every hook payload. Never let a missing
  // correlation id broaden an exact read-only identity.
  if (!boundedIdentity(agentType)) return PRINCIPALS.HOST;
  if (agentId !== undefined && !boundedIdentity(agentId)) return PRINCIPALS.HOST;
  if (EVIDENCE_WORKER_TYPES.has(agentType)) return PRINCIPALS.EVIDENCE_WORKER;
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
  EVIDENCE_WORKER_TYPES,
  PLM_TYPES,
  REVIEWER_TYPES,
  classifySubagent,
  classifyPreToolPayload,
};
