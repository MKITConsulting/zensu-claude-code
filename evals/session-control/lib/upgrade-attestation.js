'use strict';

const PREFIX = '[control-upgrade-attestation] ';
const HASH_RE = /^sha256:[a-f0-9]{64}$/;
const REVISION_RE = /^[a-f0-9]{40,64}$/;
const VERSION_RE = /^\d+\.\d+\.\d+$/;
const OLD_RELEASE_REVISION = '3e4f4ab4c1ea5c075effb743ae00af6f915ddb82';

const EXECUTION_MODES = Object.freeze({
  authoritative: 'authoritative-explicit-credential-isolated-home',
  diagnostic: 'local-diagnostic-existing-login',
  fake: 'deterministic-fake',
});

const REQUIRED_SEQUENCE = Object.freeze([
  `OldRuntime:git-tag:v0.16.1@${OLD_RELEASE_REVISION}`,
  'PermissionBoundary:dontAsk-four-read-one-bash',
  'OldTurn1:SessionStart:old-root',
  'OldTurn1:Read:success',
  'OldTurn1:Stop:old-root:exit-0',
  'CandidateInstall:side-by-side-create-once',
  'OldTurn2:Read:success',
  'OldTurn2:Stop:old-root:exit-0',
  'OldProcess:open-during-fresh-candidate',
  'FreshCandidate:SessionStart:main-v1',
  'FreshCandidate:PreToolUse:Read:exit-0',
  'FreshCandidate:Read:success',
  'FreshCandidate:PreToolUse:Bash:all-exit-0',
  'FreshCandidate:HarnessBashGuard:exact-command:exit-0',
  'FreshCandidate:Bash:success',
  'FreshCandidate:Stop:exit-0',
  'FreshCandidate:Record:exactly-one',
  'FreshCandidate:Baseline:exactly-one',
  'OldTurn3AfterCandidate:Read:success',
  'OldTurn3AfterCandidate:Stop:old-root:exit-0',
  'OldProcess:single-init-three-results',
  'OldRuntime:payload-byte-identical-lifecycle-markers-validated',
  'CandidateRuntime:payload-byte-identical-lifecycle-markers-validated',
  'SourceCheckout:unchanged',
  'HostConfigCache:canary-status-recorded',
  'FilesystemScope:isolated-plugin-config-cache-data',
]);

const KEYS = Object.freeze([
  'schema',
  'schema_version',
  'host',
  'gate',
  'execution_mode',
  'host_config_cache_canary_status',
  'claude_code_version',
  'source_git_revision',
  'old_release_ref',
  'old_release_revision',
  'old_version',
  'candidate_source_version',
  'candidate_installed_version',
  'candidate_version_synthetic',
  'old_runtime_digest',
  'candidate_runtime_digest',
  'old_session_id_hash',
  'candidate_session_id_hash',
  'old_process_result_count',
  'fresh_process_result_count',
  'hook_sequence',
]);

function fail(message) {
  throw new Error(`Session Control upgrade attestation: ${message}`);
}

function exactKeys(value) {
  return JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...KEYS].sort());
}

function parse(output) {
  if (typeof output !== 'string' || !output.startsWith(PREFIX)
      || output.slice(PREFIX.length).includes('\n')) {
    fail('output must contain exactly one prefixed JSON line');
  }
  let value;
  try { value = JSON.parse(output.slice(PREFIX.length)); }
  catch (_error) { fail('output JSON is malformed'); }
  return validate(value);
}

function validate(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || !exactKeys(value)) {
    fail('shape is invalid');
  }
  if (value.schema !== 'zensu.session-control-upgrade-evidence'
      || value.schema_version !== 1 || value.host !== 'claude' || value.gate !== 'passed') {
    fail('identity is invalid');
  }
  const canaryStatus = {
    [EXECUTION_MODES.authoritative]: 'not-applicable-isolated-home',
    [EXECUTION_MODES.diagnostic]: 'unchanged-local-diagnostic',
    [EXECUTION_MODES.fake]: 'not-applicable-test-mode',
  }[value.execution_mode];
  if (!canaryStatus || value.host_config_cache_canary_status !== canaryStatus) {
    fail('execution mode or host canary status is invalid');
  }
  if (!VERSION_RE.test(value.claude_code_version)) fail('Claude Code version evidence is invalid');
  if (!REVISION_RE.test(value.source_git_revision)
      || !REVISION_RE.test(value.old_release_revision)
      || value.source_git_revision === value.old_release_revision) {
    fail('source revisions are invalid or do not prove an upgrade');
  }
  if (value.old_release_ref !== 'v0.16.1'
      || value.old_release_revision !== OLD_RELEASE_REVISION
      || value.old_version !== '0.16.1') {
    fail('old release identity drifted');
  }
  if (!VERSION_RE.test(value.candidate_source_version)
      || !VERSION_RE.test(value.candidate_installed_version)
      || typeof value.candidate_version_synthetic !== 'boolean') {
    fail('candidate version evidence is invalid');
  }
  const oldParts = value.old_version.split('.').map(Number);
  const candidateParts = value.candidate_installed_version.split('.').map(Number);
  const greater = candidateParts.some((part, index) => (
    part > oldParts[index] && candidateParts.slice(0, index).every((prior, priorIndex) => prior === oldParts[priorIndex])
  ));
  if (!greater) fail('candidate install version must be greater than v0.16.1');
  if (value.candidate_version_synthetic
      ? value.candidate_installed_version === value.candidate_source_version
      : value.candidate_installed_version !== value.candidate_source_version) {
    fail('synthetic candidate version evidence is inconsistent');
  }
  for (const key of [
    'old_runtime_digest', 'candidate_runtime_digest',
    'old_session_id_hash', 'candidate_session_id_hash',
  ]) {
    if (!HASH_RE.test(value[key])) fail(`${key} is malformed`);
  }
  if (value.old_runtime_digest === value.candidate_runtime_digest) {
    fail('old and candidate runtime digests must differ');
  }
  if (value.old_session_id_hash === value.candidate_session_id_hash) {
    fail('old and fresh sessions must be distinct');
  }
  if (value.old_process_result_count !== 3 || value.fresh_process_result_count !== 1) {
    fail('process result cardinality is invalid');
  }
  if (!Array.isArray(value.hook_sequence)
      || JSON.stringify(value.hook_sequence) !== JSON.stringify(REQUIRED_SEQUENCE)) {
    fail('lifecycle evidence sequence is incomplete or out of order');
  }
  const serialized = JSON.stringify(value);
  if (/(?:\/private\/|\/Users\/|[A-Za-z]:\\|session_id"|ANTHROPIC|OAUTH|API_KEY)/.test(serialized)) {
    fail('attestation contains a path, raw session selector, or credential name');
  }
  return value;
}

function line(value) {
  return `${PREFIX}${JSON.stringify(validate(value))}`;
}

module.exports = {
  EXECUTION_MODES,
  KEYS,
  OLD_RELEASE_REVISION,
  PREFIX,
  REQUIRED_SEQUENCE,
  line,
  parse,
  validate,
};
