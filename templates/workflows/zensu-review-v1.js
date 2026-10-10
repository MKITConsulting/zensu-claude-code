export const meta = {
  name: 'zensu-review-v1',
  description: 'Zensu review of one change set: one finder per lens, cross-lens dedup, one refuter per CRITICAL or IMPORTANT finding, every agent outcome reported',
  whenToUse: 'The /zensu:tdd review step when a Workflow reviews the change, so that Zensu can import the result',
  phases: [
    { title: 'Find', detail: 'one read-only finder per lens' },
    { title: 'Refute', detail: 'one refuter per CRITICAL or IMPORTANT finding, CRITICAL first' },
  ],
}

const RESULT_SCHEMA = 'zensu-review-result/v1'
const SEVERITIES = ['CRITICAL', 'IMPORTANT', 'SUGGESTION']
const LENS_RE = /^[a-z][a-z0-9-]{0,31}$/
const TREE_RE = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/
const LINE_WINDOW = 3
const TITLE_SIMILARITY = 0.5
const REFUTER_RESERVE = 20000
const MAX_LENSES = 16
const MAX_CHANGED_FILES = 2000
const MAX_DEFERRED = 200
const MAX_CEILING = 200
const MAX_LENS_CAP = 100
const TEXT_LIMITS = { title: 300, evidence: 4000, failure_scenario: 2000, fix: 2000, reasoning: 2000 }

const LENS_GUIDE = {
  correctness: 'control flow, boundaries, null and error paths, races and resource handling, plus the assertions and coverage of the tests this change touches',
  design: 'dependency direction, layering, module boundaries and integration contracts, plus repository guidance, registration and file layout conventions, never formatting',
  conventions: 'repository guidance, i18n, registration, file and layout conventions',
  bugs: 'control flow, boundaries, null and error paths, races and resource handling',
  architecture: 'dependency direction, layering, module boundaries and integration contracts',
  tests: 'the assertions and coverage of the tests for the behavior this change adds or alters, and behavior it leaves untested',
  security: 'secrets, input validation, injection, permissions, sensitive output and dependency risk',
  contract: 'the interface this change shares with the client repository: request and response shapes, error codes and versioning',
}

const FINDINGS_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          title: { type: 'string' },
          severity: { type: 'string', enum: SEVERITIES },
          file: { type: 'string' },
          line: { type: 'integer', minimum: 0 },
          evidence: { type: 'string' },
          failure_scenario: { type: 'string' },
          fix: { type: 'string' },
          confidence: { type: 'integer', minimum: 0, maximum: 100 },
        },
        required: ['title', 'severity', 'file', 'line', 'evidence', 'failure_scenario', 'fix', 'confidence'],
      },
    },
  },
  required: ['findings'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    outcome: { type: 'string', enum: ['real', 'not-real'] },
    severity: { type: 'string', enum: SEVERITIES },
    reasoning: { type: 'string' },
  },
  required: ['outcome', 'severity', 'reasoning'],
}

function fail(message) {
  throw new Error(`zensu-review-v1: ${message}`)
}

function oneLine(value) {
  return typeof value === 'string' && value.trim() !== '' && !/[\0\r\n]/.test(value)
}

function clip(value, max) {
  const text = typeof value === 'string' ? value.trim() : ''
  return text.length > max ? `${text.slice(0, max)} [truncated]` : text
}

function textArg(value, label) {
  if (typeof value !== 'string' || value.trim() === '') fail(`args.${label} must be a non-empty string`)
  return value.trim()
}

function optionalPath(value, label) {
  if (value === undefined || value === null || value === '') return ''
  if (!oneLine(value)) fail(`args.${label} must be a one-line string`)
  return value.trim()
}

function listArg(value, label, max, required) {
  if (value === undefined || value === null) {
    if (required) fail(`args.${label} is required`)
    return []
  }
  if (!Array.isArray(value)) fail(`args.${label} must be an array`)
  if (value.length > max) fail(`args.${label} holds more than ${max} entries`)
  return value.map((entry) => {
    if (!oneLine(entry)) fail(`args.${label} holds an entry that is not a one-line string`)
    return entry.trim()
  })
}

function integerArg(value, label, fallback, min, max) {
  if (value === undefined || value === null) return fallback
  if (!Number.isInteger(value) || value < min || value > max) fail(`args.${label} must be an integer from ${min} to ${max}`)
  return value
}

function readArgs(raw) {
  let value = raw
  if (typeof value === 'string') {
    try {
      value = JSON.parse(value)
    } catch {
      fail('args is a string that does not parse as JSON')
    }
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail('args must be an object')
  const tree = textArg(value.tree, 'tree')
  if (!TREE_RE.test(tree)) fail('args.tree must be the tree id that --external-review --tree printed')
  const lenses = listArg(value.lenses, 'lenses', MAX_LENSES, true)
  if (lenses.length === 0) fail('args.lenses is empty')
  for (const lens of lenses) {
    if (!LENS_RE.test(lens)) fail(`args.lenses holds an invalid lens name: ${lens}`)
  }
  if (new Set(lenses).size !== lenses.length) fail('args.lenses names a lens twice')
  const changedFiles = listArg(value.changedFiles, 'changedFiles', MAX_CHANGED_FILES, true)
  if (changedFiles.length === 0) fail('args.changedFiles is empty')
  const ceiling = integerArg(value.ceiling, 'ceiling', 10, 1, MAX_CEILING)
  if (ceiling < lenses.length) fail(`args.ceiling ${ceiling} is below the ${lenses.length} finders the lenses need`)
  return {
    tree,
    root: optionalPath(value.root, 'root'),
    lenses,
    changedFiles,
    diffPath: optionalPath(value.diffPath, 'diffPath'),
    ceiling,
    perLensCap: integerArg(value.perLensCap, 'perLensCap', 8, 1, MAX_LENS_CAP),
    knownDeferred: listArg(value.knownDeferred, 'knownDeferred', MAX_DEFERRED, false),
    evidenceDiscipline: textArg(value.evidenceDiscipline, 'evidenceDiscipline'),
    severityRubric: textArg(value.severityRubric, 'severityRubric'),
  }
}

function bullets(items) {
  return items.map((item) => `- ${item}`).join('\n')
}

function contextBlock(input) {
  const lines = [input.evidenceDiscipline, '', input.severityRubric, '']
  if (input.root) lines.push(`Project root: ${input.root}`)
  lines.push('Changed files:', bullets(input.changedFiles))
  if (input.diffPath) lines.push(`The diff of the change is in ${input.diffPath}. Read it first.`)
  return lines.join('\n')
}

const READ_ONLY = 'You are read-only. Read files; never edit or write a file, and never run a command that changes the repository or its state.'

function finderPrompt(input, lens) {
  const guide = LENS_GUIDE[lens] || `the ${lens} lens as the main thread named it`
  const parts = [
    `You are the ${lens} finder of a Zensu review. Review the change below from that one lens: ${guide}.`,
    READ_ONLY,
    '',
    contextBlock(input),
  ]
  if (input.knownDeferred.length > 0) {
    parts.push('', 'An earlier review deferred these findings. Report one of them again only with new evidence:', bullets(input.knownDeferred))
  }
  parts.push(
    '',
    'Read every changed file this lens concerns. Report each finding of this lens with confidence 80 or higher: a one-line title, the severity the rubric gives it, the repository-relative file, the 1-based line (0 when no line applies), the code evidence you read, a concrete failure scenario, a concrete fix and your confidence from 0 to 100. Report every such finding, not a selection. Return an empty findings list when the lens finds nothing.',
  )
  return parts.join('\n')
}

function refuterPrompt(input, finding) {
  const location = finding.file === '' ? '(no file)' : `${finding.file}${finding.line > 0 ? `:${finding.line}` : ''}`
  return [
    `You are a refuter in a Zensu review. Try to refute finding ${finding.id} of the ${finding.lens} lens by reading the code it cites.`,
    READ_ONLY,
    '',
    contextBlock(input),
    '',
    `Finding ${finding.id}: ${finding.title}`,
    `Claimed severity: ${finding.severity}`,
    `Location: ${location}`,
    `Evidence: ${finding.evidence}`,
    `Failure scenario: ${finding.failure_scenario}`,
    `Proposed fix: ${finding.fix}`,
    '',
    'Read the cited code and everything the failure scenario depends on. Answer the outcome real when the code shows the failure can happen as described, and not-real when the code shows it cannot. When the code cannot settle it, answer real and name what you could not check, because an unsettled finding stays open for the main thread. Give the severity you would rate it with the rubric, and your reasoning with the lines you read.',
  ].join('\n')
}

function rank(severity) {
  return SEVERITIES.indexOf(severity)
}

function byPriority(a, b) {
  return rank(a.severity) - rank(b.severity) || b.confidence - a.confidence || a.lensIndex - b.lensIndex || a.n - b.n
}

function words(value) {
  return new Set(String(value).toLowerCase().split(/[^a-z0-9]+/).filter((word) => word.length > 2))
}

function similarTitles(a, b) {
  const left = words(a)
  const right = words(b)
  if (left.size === 0 || right.size === 0) return false
  let shared = 0
  for (const word of left) {
    if (right.has(word)) shared += 1
  }
  return shared / (left.size + right.size - shared) >= TITLE_SIMILARITY
}

function sameIssue(a, b) {
  return a.file !== '' && a.file === b.file && Math.abs(a.line - b.line) <= LINE_WINDOW && similarTitles(a.title, b.title)
}

function normalizeFinding(raw, lens) {
  if (!raw || typeof raw !== 'object' || !SEVERITIES.includes(raw.severity)) return null
  const file = typeof raw.file === 'string' ? raw.file.trim().replace(/\\/g, '/').replace(/^\.\//, '') : ''
  return {
    lens,
    title: clip(raw.title, TEXT_LIMITS.title) || '(untitled)',
    severity: raw.severity,
    file: /[\0\r\n]/.test(file) ? '' : file,
    line: Number.isInteger(raw.line) && raw.line > 0 ? raw.line : 0,
    evidence: clip(raw.evidence, TEXT_LIMITS.evidence),
    failure_scenario: clip(raw.failure_scenario, TEXT_LIMITS.failure_scenario),
    fix: clip(raw.fix, TEXT_LIMITS.fix),
    confidence: Number.isInteger(raw.confidence) ? Math.min(100, Math.max(0, raw.confidence)) : 0,
  }
}

const input = readArgs(args)
const agents = { started: 0, finished: 0, failed: 0 }
const dropped = []
const shortfall = new Map()

function budgetLow(reserve) {
  return Boolean(budget) && typeof budget.total === 'number' && budget.remaining() < reserve
}

async function run(prompt, options) {
  if (budgetLow(1)) return { state: 'skipped' }
  agents.started += 1
  let value = null
  try {
    value = await agent(prompt, options)
  } catch {
    value = null
  }
  if (value === null || value === undefined) {
    agents.failed += 1
    return { state: 'failed' }
  }
  agents.finished += 1
  return { state: 'done', value }
}

function leaveUnverified(kind, finding, reason) {
  finding.verification.reason = reason
  const key = `${kind}|${finding.lens}`
  const entry = shortfall.get(key) || { kind, lens: finding.lens, count: 0, reason }
  entry.count += 1
  shortfall.set(key, entry)
}

phase('Find')
const finderRuns = await parallel(input.lenses.map((lens) => () => run(finderPrompt(input, lens), {
  label: `find:${lens}`,
  phase: 'Find',
  schema: FINDINGS_SCHEMA,
})))

const found = []
input.lenses.forEach((lens, lensIndex) => {
  const outcome = finderRuns[lensIndex] || { state: 'failed' }
  if (outcome.state !== 'done' || !outcome.value || !Array.isArray(outcome.value.findings)) {
    const reason = outcome.state === 'skipped'
      ? 'the token budget was spent before the finder started'
      : outcome.state === 'done' ? 'the finder returned no findings list' : 'the finder agent failed'
    dropped.push({ kind: 'finder-failed', lens, count: 0, reason })
    log(`finder-failed: ${lens}, ${reason}; this lens is a review gap`)
    return
  }
  const normalized = []
  let malformed = 0
  for (const raw of outcome.value.findings) {
    const finding = normalizeFinding(raw, lens)
    if (finding) normalized.push(finding)
    else malformed += 1
  }
  if (malformed > 0) {
    dropped.push({ kind: 'malformed-finding', lens, count: malformed, reason: 'an entry with no rubric severity' })
    log(`malformed-finding: ${lens} returned ${malformed} entries with no rubric severity`)
  }
  normalized.sort((a, b) => rank(a.severity) - rank(b.severity) || b.confidence - a.confidence)
  normalized.forEach((finding, index) => {
    finding.n = index + 1
    finding.id = `${lens}-${index + 1}`
    finding.lensIndex = lensIndex
    finding.capped = index >= input.perLensCap
  })
  const over = normalized.length - input.perLensCap
  if (over > 0) {
    dropped.push({ kind: 'over-cap', lens, count: over, reason: `the lens cap is ${input.perLensCap}; the rest stay unverified` })
    log(`over-cap: ${lens} found ${normalized.length}, so ${over} stay unverified`)
  }
  found.push(...normalized)
})

found.sort(byPriority)
const kept = []
for (const finding of found) {
  const keeper = kept.find((candidate) => sameIssue(candidate, finding))
  if (keeper) {
    keeper.duplicates.push(finding.id)
    keeper.capped = keeper.capped && finding.capped
    continue
  }
  finding.duplicates = []
  finding.verification = { status: 'unverified', reason: '', votes: [] }
  kept.push(finding)
}
if (kept.length !== found.length) log(`dedup: ${found.length} findings, ${kept.length} distinct`)

const selected = []
let slots = input.ceiling - input.lenses.length
for (const finding of kept) {
  if (finding.severity === 'SUGGESTION') {
    finding.verification.reason = 'a SUGGESTION gets no verifier by design'
    continue
  }
  if (finding.capped) {
    finding.verification.reason = `over the lens cap of ${input.perLensCap}`
    continue
  }
  if (slots <= 0) {
    leaveUnverified('over-ceiling', finding, `over the agent ceiling of ${input.ceiling}`)
    continue
  }
  if (budgetLow(REFUTER_RESERVE)) {
    leaveUnverified('over-budget', finding, 'the token budget ran low before its refuter')
    continue
  }
  slots -= 1
  selected.push(finding)
}

if (selected.length > 0) phase('Refute')
const refuterRuns = await parallel(selected.map((finding) => () => (budgetLow(REFUTER_RESERVE)
  ? Promise.resolve({ state: 'skipped' })
  : run(refuterPrompt(input, finding), {
    label: `refute:${finding.lens}#${finding.n}`,
    phase: 'Refute',
    schema: VERDICT_SCHEMA,
  }))))

selected.forEach((finding, index) => {
  const outcome = refuterRuns[index] || { state: 'failed' }
  if (outcome.state === 'skipped') {
    leaveUnverified('over-budget', finding, 'the token budget ran low before its refuter')
    return
  }
  const verdict = outcome.state === 'done' ? outcome.value : null
  if (!verdict || !['real', 'not-real'].includes(verdict.outcome)) {
    finding.verification.votes.push({ verifier: 'refute', outcome: 'failed', severity: '', reasoning: '' })
    finding.verification.reason = outcome.state === 'done' ? 'the refuter returned no verdict' : 'the refuter agent failed'
    return
  }
  finding.verification.votes.push({
    verifier: 'refute',
    outcome: verdict.outcome,
    severity: SEVERITIES.includes(verdict.severity) ? verdict.severity : '',
    reasoning: clip(verdict.reasoning, TEXT_LIMITS.reasoning),
  })
  finding.verification.status = verdict.outcome === 'real' ? 'upheld' : 'refuted'
  finding.verification.reason = verdict.outcome === 'real' ? 'the refuter could not refute it' : 'the refuter refuted it'
})

for (const entry of shortfall.values()) {
  dropped.push(entry)
  log(`${entry.kind}: ${entry.lens} has ${entry.count} findings left unverified`)
}

const findings = kept.map((finding) => ({
  id: finding.id,
  lens: finding.lens,
  title: finding.title,
  severity: finding.severity,
  file: finding.file,
  line: finding.line,
  evidence: finding.evidence,
  failure_scenario: finding.failure_scenario,
  fix: finding.fix,
  confidence: finding.confidence,
  duplicates: finding.duplicates,
  verification: finding.verification,
}))

log(`result: ${findings.length} findings; ${agents.finished} of ${agents.started} agents finished, ${agents.failed} failed`)

return {
  schema: RESULT_SCHEMA,
  tree: input.tree,
  lenses: input.lenses,
  ceiling: input.ceiling,
  agents: { started: agents.started, finished: agents.finished, failed: agents.failed },
  dropped,
  findings,
}
