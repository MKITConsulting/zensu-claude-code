#!/usr/bin/env node
'use strict';

// session-auto-adopt-v1.js — the ONE adoption ladder every hook-side caller runs
// when the executing installation cannot serve a session's Session Control
// record by version number: adoptableRecord -> adoptContext -> the superseded
// lease sweep, composed here so the binder (claude-hook-session-v1.js), the
// SessionStart adapter (claude-session-control-v1.js) and the manual entry point's
// --confirm path (session-adopt-report-v1.js) share one implementation instead of
// three. That report's READ-ONLY path asks adoptableRecord directly, because it has
// to print a refusal's remedy table rather than a verdict — and then asks
// previewAdoption the ONE question adoptableRecord cannot answer: whether a
// superseded record already blocks the adoption. That check lives in the preview,
// so the hook binder, the manual report and the adoption itself agree about it.
//
// Never throws out of adoptForHook / previewAdoption: every outcome is a typed
// verdict, because the caller is a PreToolUse hook whose own failure mode is a
// deny of the very call it was asked to judge.
//
// Requires the sweep at top level. That is acyclic FROM HERE (sweep -> lease ->
// binder -> core) and is exactly why the binder must require THIS module lazily
// inside its failure path: a top-level require from the binder would close the
// cycle. The SessionStart adapter and the report are leaves and may require it at
// the top.
//
// The opt-out `hooks.sessionAutoAdopt === false` is read HERE and only here, on
// the adoption path — never on the hot bind. The reader mirrors _ZENSU_CFG_JS in
// hooks/lib/zensu-config.sh in WHICH files it reads (ZENSU_CONFIG verbatim, else
// the global file and the project overlay) and deliberately NOT in how it combines
// them: for this one key `false` is STICKY, so the path is off when EITHER layer
// says so — see configLayers for why project-wins ran the unsafe way round here.
// It degrades to "enabled" on every fault, because the enabled state runs a REPAIR
// rather than a bypass. It applies msysDrivePrefix — the total rule, never the throwing
// normalizeHostPathInput — so a driveless MSYS spelling falls to "enabled"
// instead of raising inside a hook.
//
// KNOWN DIVERGENCE, recorded rather than closed: the project overlay is anchored
// on the AMBIENT CLAUDE_PROJECT_DIR, exactly as _ZENSU_CFG_JS anchors it, while
// every state writer in this plugin anchors on the record's project_root. Where the two
// differ — a session whose cwd is a worktree — the opt-out is read from the
// harness root. Anchoring on the record instead would make this reader disagree
// with the shell reader it mirrors, which is the worse of the two drifts.
//
// The opt-out is consulted AFTER adoptableRecord, never before it: `opted-out`
// therefore stands only for a record the ladder would otherwise have adopted. A
// record that is unreadable, foreign or a downgrade keeps its own refusal reason
// under the opt-out too, so a deny never blames the config for a state the config
// did not cause.
//
// The adoption NOTICE is rendered here as well, once, for the TWO places that
// speak about an adoption to a model or a user — the `.*` gate's allow-path
// announcement and the SessionStart/SubagentStart adapter's systemMessage plus
// additionalContext. The OPERATOR line is a second renderer, `operatorLine`, for
// every process that can perform an adoption and has no model or user channel:
// the CLI binder (on its success path AND when the strict re-read then fails), the
// in-process evidence hook, and the adapter's adopted-then-failed message. Both
// renderers consume the four SCREENS below (safeVersion, safeProvenance, keptName,
// leaseClause) so they cannot disagree about what is safe to print. The version screen consumes the core's
// ADOPTION_SAFE_VERSION_RE rather than re-spelling the alternation, and the lease
// clause distinguishes a clean sweep from a REFUSED one: a refused sweep may have
// left superseded leases in place, which is the opposite of "0 set aside".

const fs = require('node:fs');
const path = require('node:path');
const defaultCore = require('./session-control-core-v1.js');
const defaultSweep = require('./review-evidence-sweep-v1.js');
const hostPaths = require('./claude-path-v1.js');

const AUTO_ADOPT_OUTCOMES = Object.freeze({
  ADOPTED: 'adopted',
  ADOPTABLE: 'adoptable',
  ALREADY_SERVED: 'already-served',
  REFUSED: 'refused',
  OPTED_OUT: 'opted-out',
  UNAVAILABLE: 'unavailable',
});

// Entry-level reasons, distinct from core.ADOPTION_REFUSALS: they describe how
// THIS ladder ended rather than why the record was refused.
const AUTO_ADOPT_REASONS = Object.freeze({
  ADOPTED: 'adopted',
  ADOPTABLE: 'adoptable',
  OPTED_OUT: 'opted-out',
  ADOPTED_CONCURRENTLY: 'adopted-concurrently',
  LOCK_TIMEOUT: 'lock-timeout',
  SUPERSEDED_EXISTS: 'superseded-record-exists',
  ADOPTION_FAILED: 'adoption-failed',
  PROBE_FAILED: 'probe-failed',
  INVALID_REQUEST: 'invalid-request',
  NOT_COMPLETED: 'not-completed',
});

const CONFIG_KEY = 'sessionAutoAdopt';
const CONFIG_MAX_BYTES = 1024 * 1024;
// Fallback for a core that predates LOCK_TIMEOUT_CODE / isLockTimeout; the typed
// predicate is consulted first whenever the core exports it.
const LOCK_TIMEOUT_RE = /timed out acquiring per-session lock/;
const REQUIRED_REQUEST_FIELDS = Object.freeze(['executingPluginRoot', 'pluginData', 'recordsDir', 'sessionId']);

// Refusal reasons that establish NO named state: the record could not be read by
// any reader, belongs to another store, or the request itself was unusable. A
// consumer rendering a lineage or pruned CAUSE must not take one of these for it.
const STATE_NEUTRAL_REASONS = Object.freeze([
  'record-unreadable',
  'plugin-data-mismatch',
  'invalid-request',
  'probe-failed',
]);

// Provenance is one of `recorded`, `no-workflow-document` or `unavailable: <why>`;
// the third carries an error message, so it is bounded to a printable class
// rather than trusted into a notice verbatim. The class admits NO slash: an error
// message is where a filesystem path arrives, and a path in a user-facing notice
// is the one thing this screen exists to keep out. Such a message renders as
// `(unrenderable)` here, and /zensu:doctor carries the detail.
const SAFE_PROVENANCE = /^[A-Za-z0-9 .,:;_()'-]{1,200}$/;
// The token grammar every adoption token is held to before it is rendered. ONE
// JavaScript owner: the `.*` gate consumes this export for refusal tokens rather
// than spelling the class again. The shell twin is ZENSU_SAFE_REFUSAL_RE in
// hooks/lib/zensu-session.sh, which no `require` can reach.
const SAFE_TOKEN = /^[a-z][a-z0-9-]{0,63}$/;
const versionShape = defaultCore.ADOPTION_SAFE_VERSION_RE instanceof RegExp
  ? defaultCore.ADOPTION_SAFE_VERSION_RE
  : null;

function safeVersion(value) {
  return typeof value === 'string' && versionShape !== null && versionShape.test(value) ? value : '(unreadable)';
}

function safeProvenance(value) {
  return typeof value === 'string' && SAFE_PROVENANCE.test(value) ? value : '(unrenderable)';
}

// The FOURTH shared screen: the kept record's BASENAME, never its path. It was
// derived by hand at three sites — the notice below, the SessionStart adapter's
// adopted-then-failed message and the binder's operator line — and it is the one
// value of the three that names the session, so its rendering must not drift.
function keptName(adoption) {
  return adoption && typeof adoption.supersededFile === 'string'
    ? path.basename(adoption.supersededFile)
    : '(unknown)';
}

function establishesNamedState(verdict) {
  return Boolean(verdict)
    && typeof verdict.recorded === 'string'
    && !STATE_NEUTRAL_REASONS.includes(verdict.reason);
}

// ONE sentence about the sweep, for every renderer. `leases.unsafe` is a refusal
// token: `source`, `locked` and `destination` are the sweep's own, and
// `sweep-failed` is minted by THIS module's catch around the sweep call. A refusal
// does not imply that nothing moved — the destination guard refuses per lease, so
// a sweep can set some aside and then stop — which is why the count is read before
// the sentence is chosen. A bare count of 0 over a refused sweep would misreport
// an unswept store as a clean one.
function leaseClause(leases) {
  if (!leases || typeof leases !== 'object') {
    return 'no review-evidence lease sweep result was recorded, so run /zensu:adopt-session --confirm to sweep the lease store';
  }
  const discarded = Number.isInteger(leases.discarded) ? leases.discarded : 0;
  const unsafe = typeof leases.unsafe === 'string' && leases.unsafe !== ''
    ? (SAFE_TOKEN.test(leases.unsafe) ? leases.unsafe : '(unrenderable)')
    : '';
  if (unsafe !== '') {
    const tail = 'so review-evidence operations may keep failing for this session until /zensu:adopt-session --confirm repairs the lease store';
    return discarded > 0
      ? `the review-evidence lease sweep set aside ${discarded} lease(s) and was then REFUSED (${unsafe}), ${tail}`
      : `the review-evidence lease sweep was REFUSED (${unsafe}) and set aside nothing, ${tail}`;
  }
  const stuck = Array.isArray(leases.failed) ? leases.failed.length : 0;
  if (stuck > 0) {
    return `${discarded} review-evidence lease(s) from before the update set aside and ${stuck} left STUCK in the records directory, so review-evidence operations keep failing until they are moved by hand; /zensu:adopt-session --confirm re-runs the sweep and names them`;
  }
  return `${discarded} review-evidence lease(s) from before the update set aside, so a review that was in flight must be re-gathered`;
}

// The adoption notice, rendered once for every channel. `where` is the phrase that
// names the event ("on this tool call", "at this SessionStart"). An ALREADY_SERVED
// verdict reached after a failed strict bind means a sibling hook adopted the
// record during the same event, and the user is told that too — the announcement
// must not depend on which of two racing hooks won the lock.
//
// That verdict's `recorded` is NULL unless the caller observed the previous
// version itself: by the time the probe answers `already-served` the record on
// disk is the RE-MINTED one, so its plugin_version is the executing version and
// "updated from X to X" would be the result. The sentence drops the first half of
// the pair rather than printing a number nobody measured.
// ONE operator-facing sentence about an adoption THIS process performed, for every
// process that can perform one. The CLI binder printed it on its success path
// only, so an adoption whose strict re-read then failed — a vanished project root
// — and an adoption the in-process evidence hook performed left no line at all:
// the record was re-minted, a superseded copy written and the lease store swept,
// with the superseded filename as the only trace. No prefix and no newline: each
// caller owns its own lead-in.
function operatorLine(adoption) {
  return `adopted the Session Control record (${safeVersion(adoption && adoption.recorded)} -> ${safeVersion(adoption && adoption.executing)}); `
    + `previous record kept as ${keptName(adoption)}; provenance ${safeProvenance(adoption && adoption.provenance)}; `
    + `${leaseClause(adoption && adoption.leases)}`;
}

// What /zensu:doctor can show about THIS adoption, stated per provenance. The
// doctor's adoption row reads the RUNTIME_ADOPTED history entry and nothing else,
// so it exists only when a workflow document recorded one. The notice used to
// close on an unconditional "/zensu:doctor shows the details", which sent a user
// whose worktree is gone — the `no-workflow-document` case — to a report that says
// nothing about the adoption at all. A sibling's adoption carries no provenance
// here, and neither does a core that predates the vocabulary, so both take the
// conditional wording rather than a claim this process cannot back.
function doctorPointer(adoption) {
  const vocabulary = defaultCore.ADOPTION_PROVENANCE;
  const performed = Boolean(adoption) && adoption.outcome === AUTO_ADOPT_OUTCOMES.ADOPTED;
  if (!performed || !vocabulary || typeof vocabulary.RECORDED !== 'string') {
    return '/zensu:doctor shows the adoption when a workflow document recorded it';
  }
  return adoption.provenance === vocabulary.RECORDED
    ? '/zensu:doctor shows the adoption in its session-state block'
    : 'no workflow document recorded this adoption, so /zensu:doctor has no entry for it and the kept record is its evidence';
}

function renderAdoptionNotice(adoption, options) {
  const where = options && typeof options.where === 'string' && options.where !== '' ? options.where : 'on this hook';
  const executing = safeVersion(adoption && adoption.executing);
  if (adoption && adoption.outcome === AUTO_ADOPT_OUTCOMES.ALREADY_SERVED) {
    const span = typeof adoption.recorded === 'string'
      ? `from ${safeVersion(adoption.recorded)} to ${executing}`
      : `to ${executing}`;
    return `zensu: the Zensu plugin was updated ${span} while this session was running; its Session Control record was adopted automatically by a sibling hook ${where}, and this hook serves the adopted record. ${doctorPointer(adoption)}; nothing else to do.`;
  }
  const recorded = safeVersion(adoption && adoption.recorded);
  const kept = keptName(adoption);
  const orphan = adoption && adoption.orphanedProjectRoot
    ? ' The recorded project root is still gone, so Edit, Write, MultiEdit and any writing Bash command stay denied until that exact directory is re-created.'
    : '';
  return `zensu: the Zensu plugin was updated from ${recorded} to ${executing} while this session was running; its Session Control record was adopted automatically ${where} (previous record kept beside it as ${kept}; provenance ${safeProvenance(adoption && adoption.provenance)}; ${leaseClause(adoption && adoption.leases)}).${orphan} ${doctorPointer(adoption)}; nothing else to do.`;
}

function errorMessage(error) {
  if (error && typeof error.message === 'string' && error.message !== '') return error.message;
  return String(error);
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function readJsonObject(file, fsModule) {
  try {
    const stat = fsModule.statSync(file);
    if (!stat.isFile() || stat.size > CONFIG_MAX_BYTES) return {};
    const parsed = JSON.parse(fsModule.readFileSync(file, 'utf8'));
    return isPlainObject(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function deepMerge(base, overlay) {
  if (!isPlainObject(overlay)) return overlay;
  const result = isPlainObject(base) ? Object.assign({}, base) : {};
  for (const key of Object.keys(overlay)) {
    if (key === '__proto__' || key === 'constructor' || key === 'prototype') continue;
    result[key] = Object.prototype.hasOwnProperty.call(result, key)
      ? deepMerge(result[key], overlay[key])
      : overlay[key];
  }
  return result;
}

// The MERGED view — the precedence every other Zensu reader applies, project over
// global per key. Built from configLayers below, so WHERE the two files live is
// spelled once; the two functions used to resolve the same three paths separately.
function effectiveConfig(environment, platform = process.platform, fsModule = fs) {
  return configLayers(environment, platform, fsModule)
    .reduce((merged, layer) => deepMerge(merged, layer), {});
}

function disabledByConfig(config) {
  return Boolean(config) && isPlainObject(config.hooks) && config.hooks[CONFIG_KEY] === false;
}

// The two layers effectiveConfig merges, separately. `enabled` needs them apart for
// ONE reason: for this key `false` is STICKY — the automatic path is off when EITHER
// layer says so. Everywhere else in Zensu the project overlay wins per key, and for
// this key that precedence ran the unsafe way round: the overlay lives in a
// directory a session can write while no chain is armed, so a seeded
// `sessionAutoAdopt: true` there silently overrode an operator's GLOBAL false and
// the next plugin update adopted unprompted. "Enabled" is the state that acts
// without asking, so most-restrictive-wins is the fail-closed direction. No shell
// reader consumes this key, so diverging from _ZENSU_CFG_JS costs nothing at run
// time. An explicit ZENSU_CONFIG is one layer and is read verbatim.
function configLayers(environment, platform = process.platform, fsModule = fs) {
  const spell = (value) => hostPaths.msysDrivePrefix(value, platform);
  const explicit = environment.ZENSU_CONFIG;
  if (typeof explicit === 'string' && explicit !== '') return [readJsonObject(spell(explicit), fsModule)];
  const home = typeof environment.HOME === 'string' ? environment.HOME : '';
  const layers = [readJsonObject(path.join(spell(home), '.zensu', 'config.json'), fsModule)];
  const projectDir = environment.CLAUDE_PROJECT_DIR;
  if (typeof projectDir === 'string' && projectDir !== '') {
    layers.push(readJsonObject(path.join(spell(projectDir), '.zensu', 'config.json'), fsModule));
  }
  return layers;
}

function verdict(outcome, reason, extra) {
  return Object.assign({
    outcome,
    reason,
    recorded: null,
    executing: null,
    projectRoot: null,
    orphanedProjectRoot: false,
    prunedPluginRoot: false,
    supersededFile: null,
    provenance: null,
    leases: null,
    error: null,
  }, extra || {});
}

function normalizeRequest(request) {
  const source = isPlainObject(request) ? request : {};
  for (const field of REQUIRED_REQUEST_FIELDS) {
    if (typeof source[field] !== 'string' || source[field] === '') {
      return { ok: false, missing: field };
    }
  }
  return {
    ok: true,
    request: {
      executingPluginRoot: source.executingPluginRoot,
      pluginData: source.pluginData,
      recordsDir: source.recordsDir,
      sessionId: source.sessionId,
      host: typeof source.host === 'string' && source.host !== '' ? source.host : 'claude',
      environment: isPlainObject(source.environment) ? source.environment : process.env,
      respectOptOut: source.respectOptOut !== false,
      // The version the CALLER read before anyone adopted. Only a caller can know
      // it, and only this module may put it on a verdict — see the already-served
      // arm of previewAdoption.
      observedRecorded: typeof source.observedRecorded === 'string' && source.observedRecorded !== ''
        ? source.observedRecorded
        : null,
    },
  };
}

function coreOptions(request) {
  return {
    executingPluginRoot: request.executingPluginRoot,
    pluginData: request.pluginData,
    recordsDir: request.recordsDir,
    sessionId: request.sessionId,
    host: request.host,
  };
}

// The four state fields a verdict carries, READ OFF THE PROBE and never re-derived.
// adoptableRecord attaches them to a refusal as well as to an accepting verdict, so
// the deny that follows a refusal names both versions and the reader that answered
// from the very walk that produced the refusal. This module used to walk condition
// 1's reader ladder a second time to get them — a hand copy that could answer
// differently from the walk it was describing. A probe that carries none (an older
// core, or `record-unreadable`) yields the empty state, which every consumer reads
// as "no named state was established".
function probeState(probe) {
  const source = isPlainObject(probe) ? probe : {};
  return {
    recorded: typeof source.recorded === 'string' ? source.recorded : null,
    executing: typeof source.executing === 'string' ? source.executing : null,
    orphanedProjectRoot: source.orphanedProjectRoot === true,
    prunedPluginRoot: source.prunedPluginRoot === true,
  };
}

function createAutoAdopter(deps) {
  const options = isPlainObject(deps) ? deps : {};
  const core = options.core || defaultCore;
  const sweep = options.sweep || defaultSweep;
  const fsModule = options.fs || fs;
  const platform = options.platform || process.platform;
  // An injected reader answers ONE merged config (the unit seam); the default
  // reader answers the layers, so a `false` in either one switches the path off.
  const readLayers = typeof options.readConfig === 'function'
    ? (environment) => [options.readConfig(environment)]
    : (environment) => configLayers(environment, platform, fsModule);

  function enabled(environment) {
    try {
      return !readLayers(environment).some(disabledByConfig);
    } catch {
      return true;
    }
  }

  function isRefusal(error) {
    return typeof core.isAdoptionRefusal === 'function' && core.isAdoptionRefusal(error);
  }

  function isConflict(error) {
    return typeof core.isSupersededRecordConflict === 'function' && core.isSupersededRecordConflict(error);
  }

  // The typed code first; the message match only for a core that predates it.
  function isLockTimeout(error) {
    if (typeof core.isLockTimeout === 'function') return core.isLockTimeout(error);
    return LOCK_TIMEOUT_RE.test(errorMessage(error));
  }

  // The path of a superseded record that already blocks this adoption, or null.
  // lstat, never existsSync or stat: adoptContext's own check is COPYFILE_EXCL,
  // which a DANGLING link at that name trips as well, and a followed link would
  // answer "absent" for exactly the file that refuses the copy. A core that
  // predates the shared name, a version the name refuses, and any read fault all
  // answer null — the retry token is then the honest one.
  function supersededConflict(request, recorded) {
    if (typeof recorded !== 'string'
        || typeof core.supersededRecordFile !== 'function'
        || typeof core.sessionKey !== 'function') return null;
    try {
      const file = core.supersededRecordFile(request.recordsDir, core.sessionKey(request.sessionId), recorded);
      fsModule.lstatSync(file);
      return file;
    } catch {
      return null;
    }
  }

  function previewAdoption(rawRequest) {
    const normalized = normalizeRequest(rawRequest);
    if (!normalized.ok) {
      return verdict(AUTO_ADOPT_OUTCOMES.UNAVAILABLE, AUTO_ADOPT_REASONS.INVALID_REQUEST, {
        error: `request field ${normalized.missing} must be a non-empty string`,
      });
    }
    const request = normalized.request;
    let probe;
    try {
      probe = core.adoptableRecord(coreOptions(request));
    } catch (error) {
      // No state: the probe is documented never to throw, so a throw means nothing
      // about the record was established, and `probe-failed` is state-neutral.
      return verdict(AUTO_ADOPT_OUTCOMES.UNAVAILABLE, AUTO_ADOPT_REASONS.PROBE_FAILED, {
        error: errorMessage(error),
      });
    }
    const state = probeState(probe);
    if (!probe || probe.ok !== true) {
      const reason = probe && typeof probe.reason === 'string' ? probe.reason : AUTO_ADOPT_REASONS.PROBE_FAILED;
      if (reason === 'already-served') {
        // The record on disk already serves, so its plugin_version is whatever the
        // adopting sibling re-minted it under — not the version this session was
        // updated FROM, and this verdict must not pass the re-minted one off as
        // that. A caller that observed the previous version itself hands it in on
        // the request, and THIS is the one place it reaches the field: the caller
        // used to patch the returned verdict, which left three layers writing one
        // field that meant two different things.
        return verdict(AUTO_ADOPT_OUTCOMES.ALREADY_SERVED, reason, { ...state, recorded: request.observedRecorded });
      }
      return verdict(AUTO_ADOPT_OUTCOMES.REFUSED, reason, state);
    }
    // The crash-resume shape, asked HERE so every consumer of this preview agrees
    // about it. The record is adoptable, yet a superseded file from an interrupted
    // adoption already sits at the name adoptContext would copy to, and its
    // COPYFILE_EXCL refuses every later attempt until the file is moved — so
    // "retry" would be a loop. It used to be asked by the hook binder alone, which
    // left the read-only report answering ADOPTABLE for a state the deny named as
    // a refusal. Above the opt-out for the reason the opt-out comment gives: a
    // refusal keeps its own reason under the opt-out too.
    const blocking = supersededConflict(request, state.recorded);
    if (blocking !== null) {
      return verdict(AUTO_ADOPT_OUTCOMES.REFUSED, AUTO_ADOPT_REASONS.SUPERSEDED_EXISTS, {
        ...state,
        supersededFile: blocking,
      });
    }
    // The opt-out is asked LAST, so it only ever overrides an adoption that would
    // have happened: a refusal above keeps its own reason under the opt-out too.
    if (request.respectOptOut && !enabled(request.environment)) {
      return verdict(AUTO_ADOPT_OUTCOMES.OPTED_OUT, AUTO_ADOPT_REASONS.OPTED_OUT, state);
    }
    return verdict(AUTO_ADOPT_OUTCOMES.ADOPTABLE, AUTO_ADOPT_REASONS.ADOPTABLE, state);
  }

  function adoptForHook(rawRequest) {
    const preview = previewAdoption(rawRequest);
    if (preview.outcome !== AUTO_ADOPT_OUTCOMES.ADOPTABLE) return preview;
    const request = normalizeRequest(rawRequest).request;
    const carried = {
      recorded: preview.recorded,
      executing: preview.executing,
      orphanedProjectRoot: preview.orphanedProjectRoot,
      prunedPluginRoot: preview.prunedPluginRoot,
    };
    let adopted;
    try {
      adopted = core.adoptContext(coreOptions(request));
    } catch (error) {
      const failed = { ...carried, error: errorMessage(error) };
      if (isRefusal(error)) {
        if (error.reason === 'already-served') {
          return verdict(AUTO_ADOPT_OUTCOMES.ALREADY_SERVED, AUTO_ADOPT_REASONS.ADOPTED_CONCURRENTLY, failed);
        }
        return verdict(AUTO_ADOPT_OUTCOMES.REFUSED, error.reason, failed);
      }
      if (isConflict(error)) {
        return verdict(AUTO_ADOPT_OUTCOMES.REFUSED, AUTO_ADOPT_REASONS.SUPERSEDED_EXISTS, {
          ...failed,
          supersededFile: typeof error.supersededFile === 'string' ? error.supersededFile : null,
        });
      }
      if (isLockTimeout(error)) {
        return verdict(AUTO_ADOPT_OUTCOMES.UNAVAILABLE, AUTO_ADOPT_REASONS.LOCK_TIMEOUT, failed);
      }
      return verdict(AUTO_ADOPT_OUTCOMES.UNAVAILABLE, AUTO_ADOPT_REASONS.ADOPTION_FAILED, failed);
    }
    // The sweep is what completes an adoption (see the note at the end of
    // core.adoptContext); its result is carried, never absorbed, because a lease
    // it could not set aside keeps wedging every later lease operation.
    let leases;
    try {
      leases = sweep.discardSupersededLeases(request.pluginData, core.sessionKey(request.sessionId), adopted.context.plugin_root);
    } catch (error) {
      leases = { discarded: 0, failed: [], unsafe: 'sweep-failed', unsafeAt: '', error: errorMessage(error) };
    }
    return verdict(AUTO_ADOPT_OUTCOMES.ADOPTED, AUTO_ADOPT_REASONS.ADOPTED, {
      recorded: typeof adopted.recorded === 'string' ? adopted.recorded : carried.recorded,
      executing: typeof adopted.executing === 'string' ? adopted.executing : carried.executing,
      projectRoot: typeof adopted.projectRoot === 'string' ? adopted.projectRoot : null,
      orphanedProjectRoot: Boolean(adopted.orphanedProjectRoot),
      prunedPluginRoot: Boolean(adopted.prunedPluginRoot),
      supersededFile: typeof adopted.supersededFile === 'string' ? adopted.supersededFile : null,
      provenance: typeof adopted.provenance === 'string' ? adopted.provenance : null,
      leases,
    });
  }

  return { previewAdoption, adoptForHook, autoAdoptEnabled: enabled };
}

const defaultAdopter = createAutoAdopter();

module.exports = {
  AUTO_ADOPT_OUTCOMES,
  AUTO_ADOPT_REASONS,
  CONFIG_KEY,
  createAutoAdopter,
  autoAdoptEnabled: defaultAdopter.autoAdoptEnabled,
  previewAdoption: defaultAdopter.previewAdoption,
  adoptForHook: defaultAdopter.adoptForHook,
  // Exported for the unit layer: the config reader is a hand mirror of
  // _ZENSU_CFG_JS in hooks/lib/zensu-config.sh and the precedence it encodes has
  // to be pinnable without a plugin tree.
  effectiveConfig,
  deepMerge,
  STATE_NEUTRAL_REASONS,
  establishesNamedState,
  SAFE_TOKEN,
  SAFE_PROVENANCE,
  safeProvenance,
  safeVersion,
  keptName,
  leaseClause,
  operatorLine,
  doctorPointer,
  configLayers,
  renderAdoptionNotice,
};
