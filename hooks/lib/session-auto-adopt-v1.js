#!/usr/bin/env node
'use strict';

// session-auto-adopt-v1.js — the ONE adoption ladder every hook-side caller runs
// when the executing installation cannot serve a session's Session Control
// record by version number: adoptableRecord -> adoptContext -> the superseded
// lease sweep, composed here so the binder (claude-hook-session-v1.js), the
// SessionStart adapter (claude-session-control-v1.js) and the manual entry point
// (session-adopt-report-v1.js) share one implementation instead of three.
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
// hooks/lib/zensu-config.sh (ZENSU_CONFIG verbatim, else the global file deep-
// merged with the project overlay, project winning per key) and degrades to
// "enabled" on every fault, because the enabled state runs a REPAIR rather than
// a bypass. It applies msysDrivePrefix — the total rule, never the throwing
// normalizeHostPathInput — so a driveless MSYS spelling falls to "enabled"
// instead of raising inside a hook.

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
const LOCK_TIMEOUT_RE = /timed out acquiring per-session lock/;
const REQUIRED_REQUEST_FIELDS = Object.freeze(['executingPluginRoot', 'pluginData', 'recordsDir', 'sessionId']);

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

function effectiveConfig(environment, platform = process.platform, fsModule = fs) {
  const spell = (value) => hostPaths.msysDrivePrefix(value, platform);
  const explicit = environment.ZENSU_CONFIG;
  if (typeof explicit === 'string' && explicit !== '') return readJsonObject(spell(explicit), fsModule);
  const home = typeof environment.HOME === 'string' ? environment.HOME : '';
  const global = readJsonObject(path.join(spell(home), '.zensu', 'config.json'), fsModule);
  const projectDir = environment.CLAUDE_PROJECT_DIR;
  const overlay = typeof projectDir === 'string' && projectDir !== ''
    ? readJsonObject(path.join(spell(projectDir), '.zensu', 'config.json'), fsModule)
    : {};
  return deepMerge(global, overlay);
}

function disabledByConfig(config) {
  return Boolean(config) && isPlainObject(config.hooks) && config.hooks[CONFIG_KEY] === false;
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

// Best-effort version pair for a verdict that carries no adoptable record: the
// deny that follows a refusal still has to name both versions. Every reader is
// tried in the same order as adoptableRecord's own ladder and every fault is
// absorbed — a null here costs a name in a message, never the verdict.
function versionPair(core, request) {
  const readerOptions = { recordsDir: request.recordsDir, sessionId: request.sessionId, expectedHost: request.host };
  let recorded = null;
  for (const reader of ['readContext', 'readOrphanedProjectRootContext', 'readPrunedPluginRootContext']) {
    if (typeof core[reader] !== 'function') continue;
    try {
      const context = core[reader](readerOptions);
      if (context && typeof context.plugin_version === 'string') {
        recorded = context.plugin_version;
        break;
      }
    } catch {
      // The next reader in the ladder may still answer.
    }
  }
  let executing = null;
  try {
    const version = core.executingPluginVersion(request.executingPluginRoot, request.host);
    executing = typeof version === 'string' ? version : null;
  } catch {
    executing = null;
  }
  return { recorded, executing };
}

function createAutoAdopter(deps) {
  const options = isPlainObject(deps) ? deps : {};
  const core = options.core || defaultCore;
  const sweep = options.sweep || defaultSweep;
  const fsModule = options.fs || fs;
  const platform = options.platform || process.platform;
  const readConfig = typeof options.readConfig === 'function'
    ? options.readConfig
    : (environment) => effectiveConfig(environment, platform, fsModule);

  function enabled(environment) {
    try {
      return !disabledByConfig(readConfig(environment));
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

  function previewAdoption(rawRequest) {
    const normalized = normalizeRequest(rawRequest);
    if (!normalized.ok) {
      return verdict(AUTO_ADOPT_OUTCOMES.UNAVAILABLE, AUTO_ADOPT_REASONS.INVALID_REQUEST, {
        error: `request field ${normalized.missing} must be a non-empty string`,
      });
    }
    const request = normalized.request;
    if (request.respectOptOut && !enabled(request.environment)) {
      return verdict(AUTO_ADOPT_OUTCOMES.OPTED_OUT, AUTO_ADOPT_REASONS.OPTED_OUT, versionPair(core, request));
    }
    let probe;
    try {
      probe = core.adoptableRecord(coreOptions(request));
    } catch (error) {
      return verdict(AUTO_ADOPT_OUTCOMES.UNAVAILABLE, AUTO_ADOPT_REASONS.PROBE_FAILED, {
        ...versionPair(core, request),
        error: errorMessage(error),
      });
    }
    if (!probe || probe.ok !== true) {
      const reason = probe && typeof probe.reason === 'string' ? probe.reason : AUTO_ADOPT_REASONS.PROBE_FAILED;
      const outcome = reason === 'already-served' ? AUTO_ADOPT_OUTCOMES.ALREADY_SERVED : AUTO_ADOPT_OUTCOMES.REFUSED;
      return verdict(outcome, reason, versionPair(core, request));
    }
    return verdict(AUTO_ADOPT_OUTCOMES.ADOPTABLE, AUTO_ADOPT_REASONS.ADOPTABLE, {
      recorded: typeof probe.recorded === 'string' ? probe.recorded : null,
      executing: typeof probe.executing === 'string' ? probe.executing : null,
      orphanedProjectRoot: Boolean(probe.orphanedProjectRoot),
      prunedPluginRoot: Boolean(probe.prunedPluginRoot),
    });
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
      if (LOCK_TIMEOUT_RE.test(errorMessage(error))) {
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
};
