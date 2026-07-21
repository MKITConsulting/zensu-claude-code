'use strict';

const fs = require('node:fs');
const path = require('node:path');

const operation = process.env.ZENSU_TEST_RESET_INNER_RACE_OPERATION || 'cancel';
const methodNeedle = operation === 'clear'
  ? 'core.clearTerminalDeferredReviewClaim'
  : 'core.cancelDeferredReviewClaim';

if (
  process.env.ZENSU_TEST_RESET_INNER_RACE === '1'
  && typeof process.env.CONTROL_CORE === 'string'
  && process.env.CONTROL_CORE !== ''
  && process.execArgv.some((value) => value.includes(methodNeedle))
) {
  const core = require(path.resolve(process.env.CONTROL_CORE));
  let injected = false;

  const injectFreshBegin = (options) => {
    if (injected) return;
    injected = true;
    fs.writeFileSync(process.env.ZENSU_TEST_RESET_INNER_RACE_MARKER, 'entered\n');
    const state = core.readWorkflowState({
      projectRoot: options.projectRoot,
      sessionId: options.currentSessionId,
    });
    core.mutateWorkflowState({
      projectRoot: options.projectRoot,
      sessionId: options.currentSessionId,
      workflowState: 'red',
      event: 'tdd-begin',
      expectedRevision: state.revision,
    }, (draft) => ({
      ...draft,
      active: true,
      implComplete: false,
      chainDone: false,
      codeReviewDone: false,
      selfReviewFixed: false,
      workflowActive: false,
      workflowTools: [],
      bypasses: [],
      reviewTicket: '',
      reviewTicketConsumed: true,
      reviewRound: 0,
      stopBlockCount: 0,
      deferredReviewClaim: '',
      phase: 'UNINITIALIZED',
      step_id: '',
      history: [],
    }));
    fs.writeFileSync(process.env.ZENSU_TEST_RESET_INNER_RACE_MARKER, 'injected\n');
  };

  if (operation === 'clear') {
    const originalClear = core.clearTerminalDeferredReviewClaim;
    core.clearTerminalDeferredReviewClaim = function clearWithInnerBegin(options) {
      injectFreshBegin(options);
      return originalClear(options);
    };
  } else {
    const originalCancel = core.cancelDeferredReviewClaim;
    core.cancelDeferredReviewClaim = function cancelWithInnerBegin(options) {
      const result = originalCancel(options);
      if (result.status === 'cancelled' && result.mode === 'release-only') {
        injectFreshBegin(options);
      }
      return result;
    };
  }
}
