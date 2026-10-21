import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { FsStat, On, SessionRateLimit, UsageUnit } from 'claude-code'

const SESSION = '0f8fad5b-d9cb-469f-a165-70867728950e'
const HOME = '/Users/hub-user'
const USAGE = `${HOME}/.claude/zensu/session-hub/v1/usage`
const NOW = 1760792400000
const CONTEXT = { window: 200000 }
const FIVE_HOUR = { kind: 'five_hour', percentUsed: 21, resetsAt: '2026-10-18T15:00:00.000Z' }
const SEVEN_DAY = { kind: 'seven_day', percentUsed: 55.5, resetsAt: '2026-10-22T08:00:00.000Z' }
const DIRECTORY: Pick<FsStat, 'kind' | 'isLink'> = { kind: 'dir', isLink: false }

type Write = { path: string; text: string }

type State = {
  sessionId: string
  rateLimits: SessionRateLimit[]
  paths: Map<string, Pick<FsStat, 'kind' | 'isLink'>>
  failWrite: boolean
}

function world(on: On, env: Record<string, string> = { HOME }): { writes: Write[]; state: State } {
  const writes: Write[] = []
  const state: State = {
    sessionId: SESSION,
    rateLimits: [FIVE_HOUR, SEVEN_DAY],
    paths: new Map([[USAGE, DIRECTORY]]),
    failWrite: false,
  }
  mock.env(on, env)
  mock.clock(on, { now: NOW })
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
  return { writes, state }
}

function start($: Engine) {
  return $.session.start({ cwd: '/work', surface: null, isInteractive: false })
}

function measure($: Engine, changed: UsageUnit[], rateLimits: SessionRateLimit[] = [FIVE_HOUR, SEVEN_DAY]) {
  return $.session.measure({ context: CONTEXT, rateLimits, changed })
}

describe('usage feed', () => {
  test('a measure at the end of a turn writes one record holding exactly the documented fields', async ($, on) => {
    const { writes } = world(on)
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

  test('nothing is written while the Session Hub directory is missing', async ($, on) => {
    const { writes, state } = world(on)
    state.paths.clear()
    expect(await start($)).toEqual({ cwd: '/work' })
    expect(await measure($, ['rateLimits'])).toEqual({ changed: ['rateLimits'] })
    expect(writes).toHaveLength(0)
  })

  test('a usage path that is a file or a symbolic link is refused', async ($, on) => {
    const { writes, state } = world(on)
    state.paths.set(USAGE, { kind: 'file', isLink: false })
    await measure($, ['rateLimits'])
    state.paths.set(USAGE, { kind: 'dir', isLink: true })
    await measure($, ['rateLimits'])
    state.paths.set(USAGE, { kind: 'other', isLink: true })
    await measure($, ['rateLimits'])
    expect(writes).toHaveLength(0)
  })

  test('a measure that names the cost or the rate limits writes, one where only the context moved does not', async ($, on) => {
    const { writes } = world(on)
    expect(await measure($, ['context'])).toEqual({ changed: ['context'] })
    expect(writes).toHaveLength(0)
    await measure($, ['cost'])
    await measure($, ['context', 'cost'])
    expect(writes).toHaveLength(2)
    const moved = { ...FIVE_HOUR, percentUsed: 22 }
    await measure($, ['rateLimits'], [moved, SEVEN_DAY])
    expect(writes).toHaveLength(3)
    expect(JSON.parse(writes[2]?.text ?? '').rateLimits).toEqual([moved, SEVEN_DAY])
  })

  test('a session id of any other shape never becomes a file name', async ($, on) => {
    const { writes, state } = world(on)
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
    await measure($, ['rateLimits'])
    expect(writes.map(write => write.path)).toEqual([`${root}/zensu/session-hub/v1/usage/${SESSION}.json`])
  })

  test('a relative CLAUDE_CONFIG_DIR writes nothing and never falls back to HOME', async ($, on) => {
    const { writes, state } = world(on, { HOME, CLAUDE_CONFIG_DIR: 'claude-b' })
    state.paths.set('claude-b/zensu/session-hub/v1/usage', DIRECTORY)
    await measure($, ['rateLimits'])
    expect(writes).toHaveLength(0)
  })

  test('without HOME and without CLAUDE_CONFIG_DIR nothing is written', async ($, on) => {
    const { writes } = world(on, {})
    await start($)
    await measure($, ['rateLimits'])
    expect(writes).toHaveLength(0)
  })

  test('malformed windows are dropped, and a reading left with none writes nothing', async ($, on) => {
    const { writes } = world(on)
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
    await measure($, ['rateLimits'], [])
    await measure($, ['rateLimits'], [{ kind: 'Five Hour', percentUsed: 3, resetsAt: FIVE_HOUR.resetsAt }])
    expect(writes).toHaveLength(1)
  })

  test('a failing write leaves both events answered as the engine answered them', async ($, on) => {
    const { writes, state } = world(on)
    state.failWrite = true
    expect(await start($)).toEqual({ cwd: '/work' })
    expect(await measure($, ['rateLimits'])).toEqual({ changed: ['rateLimits'] })
    expect(writes).toHaveLength(0)
  })
})
