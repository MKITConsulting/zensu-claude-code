'use strict';

const LINK_KEYS = Object.freeze(['autopilotRunId', 'autopilotAttempt', 'autopilotReturnStage', 'chainId', 'chainOutcome']);
const RETURN_STAGES = Object.freeze(['GATES', 'CONVERGE', 'FIX_FINDINGS', 'VALIDATE', 'COVER']);
const LINK_ID_RE = /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/;
const SESSION_PREFIX = 'scv1_';

function isDocument(state) {
  return !!state && typeof state === 'object' && !Array.isArray(state);
}

function linkId(value) {
  return typeof value === 'string' && value.length > 0 && value.length <= 128 && LINK_ID_RE.test(value);
}

function autopilotLink(state) {
  const count = LINK_KEYS.filter((key) => Object.prototype.hasOwnProperty.call(state, key)).length;
  if (count === 0) return { autopilot: null };
  const complete = count === LINK_KEYS.length
    && linkId(state.autopilotRunId)
    && Number.isInteger(state.autopilotAttempt)
    && state.autopilotAttempt >= 1 && state.autopilotAttempt <= 999
    && RETURN_STAGES.includes(state.autopilotReturnStage)
    && linkId(state.chainId)
    && state.chainOutcome === '';
  if (!complete) return null;
  return {
    autopilot: {
      runId: state.autopilotRunId,
      attempt: state.autopilotAttempt,
      returnStage: state.autopilotReturnStage,
      chainId: state.chainId,
      outcome: state.chainOutcome,
    },
  };
}

function claimContext(state, sessionKey) {
  if (!isDocument(state) || typeof sessionKey !== 'string') return null;
  const link = autopilotLink(state);
  if (!link) return null;
  const valid = state.session_id_hash === `sha256:${sessionKey.slice(SESSION_PREFIX.length)}`
    && typeof state.phase === 'string'
    && Array.isArray(state.history)
    && Array.isArray(state.bypasses)
    && state.active === true
    && typeof state.vanilla === 'boolean'
    && state.implComplete === true
    && state.chainDone === false
    && state.codeReviewDone === false
    && typeof state.selfReviewFixed === 'boolean'
    && typeof state.reviewTicket === 'string'
    && typeof state.reviewTicketConsumed === 'boolean'
    && Number.isSafeInteger(state.reviewRound) && state.reviewRound >= 0
    && state.reviewRound < Number.MAX_SAFE_INTEGER;
  return valid ? link : null;
}

function claimableTicket(state, sessionKey) {
  const context = claimContext(state, sessionKey);
  return context && state.reviewTicketConsumed === false ? state.reviewTicket : null;
}

module.exports = {
  LINK_KEYS,
  RETURN_STAGES,
  claimContext,
  claimableTicket,
};
