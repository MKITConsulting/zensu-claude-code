import type { EngineInterface, Register, SessionRateLimit, UsageUnit } from 'claude-code'

type RateLimitReading = {
  kind: string
  percentUsed: number
  resetsAt: string | null
}

const SCHEMA_VERSION = 1
const USAGE_DIRECTORY = 'zensu/session-hub/v1/usage'
const MAX_RATE_LIMITS = 8
const FRESH_READING: readonly UsageUnit[] = ['rateLimits', 'cost']
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

async function configRoot($: EngineInterface): Promise<string | undefined> {
  const configured = (await $.env.get('CLAUDE_CONFIG_DIR'))?.trim()
  if (configured) return configured.startsWith('/') ? configured.replace(/\/+$/, '') : undefined
  const home = await $.env.get('HOME')
  return home?.startsWith('/') ? `${home.replace(/\/+$/, '')}/.claude` : undefined
}

async function writeReading($: EngineInterface, limits: readonly SessionRateLimit[]): Promise<void> {
  const rateLimits = readingsOf(limits)
  if (rateLimits.length === 0) return
  const sessionId = await $.session.id()
  if (typeof sessionId !== 'string' || !SESSION_ID.test(sessionId)) return
  const root = await configRoot($)
  if (root === undefined) return
  const directory = `${root}/${USAGE_DIRECTORY}`
  if (!(await $.fs.exists(directory))) return
  const stat = await $.fs.stat(directory)
  if (stat.kind !== 'dir' || stat.isLink) return
  const observedAt = await $.clock.now()
  if (!Number.isSafeInteger(observedAt) || observedAt < 0) return
  const record = { schemaVersion: SCHEMA_VERSION, sessionId, observedAt, rateLimits }
  await $.fs.write(`${directory}/${sessionId}.json`, `${JSON.stringify(record)}\n`)
}

export const register: Register = on => {
  on('session.measure', async ($, e, next) => {
    const measured = await next(e)
    try {
      if (e.changed.some(unit => FRESH_READING.includes(unit))) await writeReading($, e.rateLimits)
    } catch {}
    return measured
  })
}
