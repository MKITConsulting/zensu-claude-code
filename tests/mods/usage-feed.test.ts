import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine, MockClock } from 'claude-code/testing'
import type { FsStat, On, SessionRateLimit, TurnCompleteInput, TurnUsage, UsageUnit } from 'claude-code'

const SESSION = '0f8fad5b-d9cb-469f-a165-70867728950e'
const CLEARED = '7c9e6679-7425-40de-944b-e07fc1f90ae7'
const HOME = '/Users/hub-user'
const USAGE = `${HOME}/.claude/zensu/session-hub/v1/usage`
const NOW = 1760792400000
const TWO_HOURS = 7200000
const CONTEXT = { window: 200000 }
const FIVE_HOUR = { kind: 'five_hour', percentUsed: 21, resetsAt: '2026-10-18T15:00:00.000Z' }
const SEVEN_DAY = { kind: 'seven_day', percentUsed: 55.5, resetsAt: '2026-10-22T08:00:00.000Z' }
const DIRECTORY: Pick<FsStat, 'kind' | 'isLink'> = { kind: 'dir', isLink: false }
const COUNTED: TurnUsage = {
  input_tokens: 1200,
  output_tokens: 80,
  cache_read_input_tokens: 0,
  cache_creation_input_tokens: 0,
  model: 'claude-test',
}

type Write = { path: string; text: string }

type State = {
  sessionId: string
  rateLimits: SessionRateLimit[]
  paths: Map<string, Pick<FsStat, 'kind' | 'isLink'>>
  failWrite: boolean
}

function world(on: On, env: Record<string, string> = { HOME }): { writes: Write[]; state: State; clock: MockClock } {
  const writes: Write[] = []
  const state: State = {
    sessionId: SESSION,
    rateLimits: [FIVE_HOUR, SEVEN_DAY],
    paths: new Map([[USAGE, DIRECTORY]]),
    failWrite: false,
  }
  mock.env(on, env)
  const clock = mock.clock(on, { now: NOW })
  on('session.id', () => ({ value: state.sessionId }))
  on('session.usage', () => ({
    value: { startedAt: NOW - 60000, context: CONTEXT, rateLimits: state.rateLimits },
  }))
  on('fs.exists', ($, e) => ({ value: state.paths.has(e.path) }))
  on('fs.stat', ($, e) => {
    const entry = state.paths.get(e.path)
    if (entry === undefined) return { deny: `ENOENT: ${e.path}` }
    return { value: { kind: entry.kind, size: 0, mtimeMs: NOW, isLink: entry.isLink } }
  })
  on('fs.write', ($, e) => {
    if (state.failWrite) return { deny: `EACCES: ${e.path}` }
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.measure', ($, e) => ({ changed: [...e.changed] }))
  on('turn.complete', ($, e) => ({ text: e.answer }))
  return { writes, state, clock }
}

function start($: Engine) {
  return $.session.start({ cwd: '/work', surface: null, isInteractive: false })
}

function measure($: Engine, changed: UsageUnit[], rateLimits: SessionRateLimit[] = [FIVE_HOUR, SEVEN_DAY]) {
  return $.session.measure({ context: CONTEXT, rateLimits, changed })
}

function complete($: Engine, turn: Partial<TurnCompleteInput> = {}) {
  const input = { answer: 'done', durationMs: 1200, isAborted: false, turnId: 'turn-1', reason: 'answer', usage: COUNTED, ...turn }
  return $.turn.complete(input as TurnCompleteInput)
}

function observedAt(writes: Write[]): number[] {
  return writes.map(write => JSON.parse(write.text).observedAt)
}

describe('usage feed', () => {
  test('a measure after an answered turn writes one record holding exactly the documented fields, stamped when the turn ended', async ($, on) => {
    const { writes, clock } = world(on)
    expect(await complete($)).toEqual({ text: 'done' })
    await clock.set(NOW + 1500)
    expect(await measure($, ['context', 'cost'])).toEqual({ changed: ['context', 'cost'] })
    expect(writes).toHaveLength(1)
    expect(writes[0]?.path).toBe(`${USAGE}/${SESSION}.json`)
    expect(writes[0]?.text).toEndWith('\n')
    const record = JSON.parse(writes[0]?.text ?? '')
    expect(Object.keys(record)).toEqual(['schemaVersion', 'sessionId', 'observedAt', 'rateLimits'])
    expect(record).toEqual({ schemaVersion: 1, sessionId: SESSION, observedAt: NOW, rateLimits: [FIVE_HOUR, SEVEN_DAY] })
    for (const limit of record.rateLimits) expect(Object.keys(limit)).toEqual(['kind', 'percentUsed', 'resetsAt'])
  })

  test('session.start writes nothing, because an idle engine still holds its last response', async ($, on) => {
    const { writes } = world(on)
    expect(await start($)).toEqual({ cwd: '/work' })
    expect(writes).toHaveLength(0)
  })

  test('a measure that follows no answered turn and no moved window writes nothing, so an old reading is never stamped as new', async ($, on) => {
    const { writes, clock } = world(on)
    await measure($, ['context', 'rateLimits', 'cost'])
    expect(writes).toHaveLength(0)
    await complete($)
    await measure($, ['context', 'cost'])
    expect(writes).toHaveLength(1)
    await clock.set(NOW + TWO_HOURS)
    expect(await measure($, ['rateLimits'])).toEqual({ changed: ['rateLimits'] })
    await measure($, ['cost'])
    await measure($, ['context', 'rateLimits', 'cost'])
    expect(observedAt(writes)).toEqual([NOW])
  })

  test('a window that moved, appeared or reset is a new reading stamped as the measure arrives, and one that only left is not', async ($, on) => {
    const { writes, clock } = world(on)
    await measure($, ['rateLimits'])
    expect(writes).toHaveLength(0)
    await clock.set(NOW + 60000)
    const moved = { ...FIVE_HOUR, percentUsed: 22 }
    await measure($, ['rateLimits'], [moved, SEVEN_DAY])
    await clock.set(NOW + 120000)
    await measure($, ['rateLimits'], [SEVEN_DAY])
    await clock.set(NOW + 180000)
    const renewed = { kind: 'five_hour', percentUsed: 3, resetsAt: '2026-10-18T20:00:00.000Z' }
    await measure($, ['rateLimits'], [renewed, SEVEN_DAY])
    await clock.set(NOW + 240000)
    const rolled = { ...SEVEN_DAY, resetsAt: '2026-10-29T08:00:00.000Z' }
    await measure($, ['rateLimits'], [renewed, rolled])
    expect(observedAt(writes)).toEqual([NOW + 60000, NOW + 180000, NOW + 240000])
    expect(writes.map(write => JSON.parse(write.text).rateLimits)).toEqual([
      [moved, SEVEN_DAY],
      [renewed, SEVEN_DAY],
      [renewed, rolled],
    ])
  })

  test('every later answered turn writes again, a subagent turn as well, whether or not a window moved', async ($, on) => {
    const { writes, clock } = world(on)
    await complete($)
    await measure($, ['context', 'cost'])
    await clock.set(NOW + 60000)
    await complete($, { turnId: 'turn-2', agentId: 'agent-1' })
    await measure($, ['context'])
    await clock.set(NOW + 120000)
    await complete($, { turnId: 'turn-3' })
    await measure($, ['cost'])
    expect(observedAt(writes)).toEqual([NOW, NOW + 60000, NOW + 120000])
  })

  test('a turn that was interrupted, failed, refused or counted no usage proves nothing', async ($, on) => {
    const { writes } = world(on)
    await complete($, { isAborted: true, reason: 'aborted' })
    await complete($, { reason: 'error' })
    await complete($, { reason: 'refusal', refusal: { category: null, explanation: null } })
    await complete($, { usage: undefined })
    await measure($, ['context', 'rateLimits', 'cost'])
    expect(writes).toHaveLength(0)
  })

  test('after /clear the reading reaches the new session id only once a new turn was answered', async ($, on) => {
    const { writes, state, clock } = world(on)
    await complete($)
    await measure($, ['context', 'cost'])
    state.sessionId = CLEARED
    await clock.set(NOW + 30000)
    await measure($, ['context', 'rateLimits', 'cost'])
    expect(writes.map(write => write.path)).toEqual([`${USAGE}/${SESSION}.json`])
    await complete($)
    await measure($, ['context', 'cost'])
    expect(writes.map(write => write.path)).toEqual([`${USAGE}/${SESSION}.json`, `${USAGE}/${CLEARED}.json`])
    expect(observedAt(writes)).toEqual([NOW, NOW + 30000])
  })

  test('nothing is written while the Session Hub directory is missing, and the reading keeps its time once it exists', async ($, on) => {
    const { writes, state, clock } = world(on)
    state.paths.clear()
    expect(await start($)).toEqual({ cwd: '/work' })
    await complete($)
    expect(await measure($, ['rateLimits'])).toEqual({ changed: ['rateLimits'] })
    expect(writes).toHaveLength(0)
    state.paths.set(USAGE, DIRECTORY)
    await clock.set(NOW + 90000)
    await measure($, ['context'])
    expect(observedAt(writes)).toEqual([NOW])
  })

  test('a usage path that is a file or a symbolic link is refused', async ($, on) => {
    const { writes, state } = world(on)
    await complete($)
    state.paths.set(USAGE, { kind: 'file', isLink: false })
    await measure($, ['rateLimits'])
    state.paths.set(USAGE, { kind: 'dir', isLink: true })
    await measure($, ['rateLimits'])
    state.paths.set(USAGE, { kind: 'other', isLink: true })
    await measure($, ['rateLimits'])
    expect(writes).toHaveLength(0)
  })

  test('a session id of any other shape never becomes a file name', async ($, on) => {
    const { writes, state } = world(on)
    await complete($)
    for (const sessionId of [
      '../../../../tmp/escape',
      SESSION.toUpperCase(),
      `${SESSION}.json`,
      `${SESSION}\n`,
      `${SESSION}/x`,
      '',
    ]) {
      state.sessionId = sessionId
      await measure($, ['rateLimits'])
    }
    expect(writes).toHaveLength(0)
    state.sessionId = SESSION
    await measure($, ['rateLimits'])
    expect(writes.map(write => write.path)).toEqual([`${USAGE}/${SESSION}.json`])
  })

  test('an absolute CLAUDE_CONFIG_DIR replaces HOME, as the receipt hook resolves it', async ($, on) => {
    const root = '/srv/claude-b'
    const { writes, state } = world(on, { HOME, CLAUDE_CONFIG_DIR: ` ${root}/ ` })
    state.paths.set(`${root}/zensu/session-hub/v1/usage`, DIRECTORY)
    await complete($)
    await measure($, ['rateLimits'])
    expect(writes.map(write => write.path)).toEqual([`${root}/zensu/session-hub/v1/usage/${SESSION}.json`])
  })

  test('a relative CLAUDE_CONFIG_DIR writes nothing and never falls back to HOME', async ($, on) => {
    const { writes, state } = world(on, { HOME, CLAUDE_CONFIG_DIR: 'claude-b' })
    state.paths.set('claude-b/zensu/session-hub/v1/usage', DIRECTORY)
    await complete($)
    await measure($, ['rateLimits'])
    expect(writes).toHaveLength(0)
  })

  test('without HOME and without CLAUDE_CONFIG_DIR nothing is written', async ($, on) => {
    const { writes } = world(on, {})
    await start($)
    await complete($)
    await measure($, ['rateLimits'])
    expect(writes).toHaveLength(0)
  })

  test('malformed windows are dropped, and a reading left with none writes nothing', async ($, on) => {
    const { writes } = world(on)
    await complete($)
    await measure($, ['rateLimits'], [])
    await measure($, ['rateLimits'], [{ kind: 'Five Hour', percentUsed: 3, resetsAt: FIVE_HOUR.resetsAt }])
    expect(writes).toHaveLength(0)
    await measure($, ['rateLimits'], [
      { kind: 'five_hour', percentUsed: 21, resetsAt: 'tomorrow' },
      { kind: 'five_hour', percentUsed: 30, resetsAt: FIVE_HOUR.resetsAt },
      { kind: 'Seven Day', percentUsed: 5, resetsAt: SEVEN_DAY.resetsAt },
      { kind: 'spend_limit', percentUsed: -1, resetsAt: SEVEN_DAY.resetsAt },
      { kind: 'seven_day', percentUsed: 104.5 },
    ])
    expect(writes).toHaveLength(1)
    expect(JSON.parse(writes[0]?.text ?? '').rateLimits).toEqual([
      { kind: 'five_hour', percentUsed: 21, resetsAt: null },
      { kind: 'seven_day', percentUsed: 104.5, resetsAt: null },
    ])
  })

  test('a failing write leaves the events answered as the engine answered them, and the next measure writes the reading', async ($, on) => {
    const { writes, state } = world(on)
    state.failWrite = true
    expect(await start($)).toEqual({ cwd: '/work' })
    expect(await complete($)).toEqual({ text: 'done' })
    expect(await measure($, ['rateLimits'])).toEqual({ changed: ['rateLimits'] })
    expect(writes).toHaveLength(0)
    state.failWrite = false
    await measure($, ['context'])
    expect(observedAt(writes)).toEqual([NOW])
  })
})
