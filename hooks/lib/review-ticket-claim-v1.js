'use strict';

// The ONE implementation of the review-ticket claim predicate. Two `node -e`
// programs consume it — the claim transaction in `hooks/lib/zensu-tdd-phase.sh`
// and the disclosure arming read in `hooks/post-review-tdd-delegate.sh` — and
// each carried its own hand-written copy before this extraction. The dangerous
// drift direction is a hook STRICTER than the claim: it answers "no ticket
// outstanding" for a chain the claim would accept, `decline()` returns at its
// first guard, and every disclosure in that file goes silent with the whole
// test surface green.
//
// Zero-dependency and host-neutral: it requires nothing, names no environment
// variable, and takes every anchor as an argument.

const TICKET_RE = /^[A-Za-z0-9_-]{1,96}$/;
const SESSION_KEY_RE = /^scv1_[a-f0-9]{64}$/;
const SESSION_KEY_PREFIX = 'scv1_';

function reviewTicketShapeOk(ticket) {
  return typeof ticket === 'string' && TICKET_RE.test(ticket);
}

function sessionHash(sessionKey) {
  if (typeof sessionKey !== 'string' || !SESSION_KEY_RE.test(sessionKey)) return '';
  return 'sha256:' + sessionKey.slice(SESSION_KEY_PREFIX.length);
}

function chainLiveForClaim(state, sessionKey) {
  const hash = sessionHash(sessionKey);
  if (hash === '') return false;
  const s = state;
  return !!s && typeof s === 'object' && !Array.isArray(s)
    && s.session_id_hash === hash
    && typeof s.phase === 'string'
    && Array.isArray(s.history)
    && Array.isArray(s.bypasses)
    && typeof s.active === 'boolean' && s.active === true
    && typeof s.vanilla === 'boolean'
    && typeof s.implComplete === 'boolean' && s.implComplete === true
    && typeof s.chainDone === 'boolean' && s.chainDone === false
    && typeof s.codeReviewDone === 'boolean' && s.codeReviewDone === false
    && typeof s.selfReviewFixed === 'boolean'
    && Number.isSafeInteger(s.reviewRound) && s.reviewRound >= 0
    && s.reviewRound < Number.MAX_SAFE_INTEGER;
}

function ticketSlotOutstanding(state) {
  const s = state;
  return !!s && typeof s === 'object' && !Array.isArray(s)
    && reviewTicketShapeOk(s.reviewTicket)
    && typeof s.reviewTicketConsumed === 'boolean'
    && s.reviewTicketConsumed === false;
}

function outstandingTicket(state, sessionKey) {
  if (!chainLiveForClaim(state, sessionKey)) return '';
  if (!ticketSlotOutstanding(state)) return '';
  return state.reviewTicket;
}

function claimableWith(state, sessionKey, ticket) {
  if (!reviewTicketShapeOk(ticket)) return false;
  if (!chainLiveForClaim(state, sessionKey)) return false;
  if (!ticketSlotOutstanding(state)) return false;
  return state.reviewTicket === ticket;
}

module.exports = {
  TICKET_RE,
  SESSION_KEY_RE,
  reviewTicketShapeOk,
  chainLiveForClaim,
  ticketSlotOutstanding,
  outstandingTicket,
  claimableWith,
};
