import type { EngineInterface, Register, SessionRateLimit } from 'claude-code'

type RateLimitReading = {
  kind: string
  percentUsed: number
  resetsAt: string | null
}

const SCHEMA_VERSION = 1
const USAGE_DIRECTORY = 'zensu/session-hub/v1/usage'
const MAX_RATE_LIMITS = 8
const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const KIND = /^[a-z][a-z0-9_]{0,31}$/
const RESETS_AT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/

function readingsOf(limits: readonly SessionRateLimit[]): RateLimitReading[] {
  const readings: RateLimitReading[] = []
  if (!Array.isArray(limits)) return readings
  for (const limit of limits) {
    if (readings.length === MAX_RATE_LIMITS) break
    if (typeof limit?.kind !== 'string' || !KIND.test(limit.kind)) continue
    if (readings.some(reading => reading.kind === limit.kind)) continue
    if (typeof limit.percentUsed !== 'number' || !Number.isFinite(limit.percentUsed) || limit.percentUsed < 0) continue
    const resetsAt =
      typeof limit.resetsAt === 'string' && RESETS_AT.test(limit.resetsAt) && Number.isFinite(Date.parse(limit.resetsAt))
        ? limit.resetsAt
        : null
    readings.push({ kind: limit.kind, percentUsed: limit.percentUsed, resetsAt })
  }
  return readings
}

function moved(before: readonly RateLimitReading[], after: readonly RateLimitReading[]): boolean {
  return after.some(reading => {
    const earlier = before.find(window => window.kind === reading.kind)
    return earlier?.percentUsed !== reading.percentUsed || earlier?.resetsAt !== reading.resetsAt
  })
}

async function moment($: EngineInterface): Promise<number | undefined> {
  const now = await $.clock.now()
  return Number.isSafeInteger(now) && now >= 0 ? now : undefined
}

async function configRoot($: EngineInterface): Promise<string | undefined> {
  const configured = (await $.env.get('CLAUDE_CONFIG_DIR'))?.trim()
  if (configured) return configured.startsWith('/') ? configured.replace(/\/+$/, '') : undefined
  const home = await $.env.get('HOME')
  return home?.startsWith('/') ? `${home.replace(/\/+$/, '')}/.claude` : undefined
}

async function writeReading($: EngineInterface, rateLimits: readonly RateLimitReading[], observedAt: number): Promise<boolean> {
  if (rateLimits.length === 0) return false
  const sessionId = await $.session.id()
  if (typeof sessionId !== 'string' || !SESSION_ID.test(sessionId)) return false
  const root = await configRoot($)
  if (root === undefined) return false
  const directory = `${root}/${USAGE_DIRECTORY}`
  if (!(await $.fs.exists(directory))) return false
  const stat = await $.fs.stat(directory)
  if (stat.kind !== 'dir' || stat.isLink) return false
  const record = { schemaVersion: SCHEMA_VERSION, sessionId, observedAt, rateLimits }
  await $.fs.write(`${directory}/${sessionId}.json`, `${JSON.stringify(record)}\n`)
  return true
}

export const register: Register = on => {
  let measured: readonly RateLimitReading[] | undefined
  let freshAt: number | undefined
  let writtenAt: number | undefined
  on('turn.complete', async ($, e, next) => {
    const completed = await next(e)
    try {
      if (e.reason === 'answer' && e.usage !== undefined) freshAt = (await moment($)) ?? freshAt
    } catch {}
    return completed
  })
  on('session.measure', async ($, e, next) => {
    const result = await next(e)
    try {
      const readings = readingsOf(e.rateLimits)
      if (measured !== undefined && moved(measured, readings)) freshAt = (await moment($)) ?? freshAt
      measured = readings
      const observedAt = freshAt
      if (observedAt !== undefined && (writtenAt === undefined || observedAt > writtenAt)) {
        if (await writeReading($, readings, observedAt)) writtenAt = observedAt
      }
    } catch {}
    return result
  })
}
