/**
 * dsh-ctl — a loopback HTTP control plane for a long-running DeepSeek Harness
 * (`dsh web`) process.
 *
 * Why it exists: the `web` profile is the only shipped DSH profile that stays
 * alive as a server, so it is the only one that can hold sessions warm. Its own
 * `/api` surface is gated behind a browser launch-token cookie and a Host/Origin
 * trust fence, which makes it awkward to drive from a script. A bundle plugin
 * can register first-class routes through `ctx.webServer`, which are NOT behind
 * that fence. This plugin uses that seam to expose a small, boring JSON API over
 * loopback, intended to be reached through SSH.
 *
 * Design rules:
 *  - Loopback only. Requests from a non-loopback socket are refused.
 *  - Optional shared secret (config.secret) for defence in depth.
 *  - Every field is read defensively, because the published type declarations
 *    and the runtime object have been observed to disagree across versions
 *    (e.g. `id` vs `sessionId`, `displayTitle` vs `projections.values.title`).
 *  - No filesystem paths, identities, or machine names are hardcoded anywhere.
 */

import { randomUUID } from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

export const name = 'dsh-ctl'
export const inject = ['webServer', 'sessionController']

export const VERSION = '0.1.4'

const LOOPBACK = new Set(['127.0.0.1', '::1', '::ffff:127.0.0.1'])
/** JSON response helper. */
function send(res, status, payload) {
  let body
  try {
    body = JSON.stringify(payload)
  } catch {
    body = JSON.stringify({ ok: false, error: 'response was not serialisable' })
    status = 500
  }
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store',
  })
  res.end(body)
}

/** Read and parse a JSON request body with a hard size cap. */
async function readJson(req, maxBytes = 1_000_000) {
  const chunks = []
  let size = 0
  for await (const chunk of req) {
    size += chunk.length
    if (size > maxBytes) throw new Error(`request body exceeds ${maxBytes} bytes`)
    chunks.push(chunk)
  }
  const raw = Buffer.concat(chunks).toString('utf8')
  if (raw.trim() === '') return {}
  return JSON.parse(raw)
}

/* ------------------------------------------------------------------ *
 * Defensive readers
 *
 * These tolerate schema drift so the same build runs on several DSH
 * versions. Observed on 0.1.5-rc.2: the .d.ts advertises
 * { id, displayTitle, completed, origin }, while the runtime object
 * carries { sessionId, projections: { values: { title, ... } } }.
 * ------------------------------------------------------------------ */

function readId(summary) {
  if (typeof summary?.sessionId === 'string') return summary.sessionId
  if (typeof summary?.id === 'string') return summary.id
  return null
}

function readTitle(summary) {
  const values = summary?.projections?.values
  if (typeof values?.title === 'string') return values.title
  if (typeof summary?.title === 'string') return summary.title
  if (typeof summary?.displayTitle === 'string') return summary.displayTitle
  return null
}

function readPreset(summary) {
  const preset = summary?.projections?.values?.agentPreset
  if (typeof preset === 'string') return preset
  if (typeof preset?.name === 'string') return preset.name
  return null
}

function readModel(summary) {
  const sel = summary?.projections?.values?.modelSelection
  if (!sel || typeof sel !== 'object') return null
  return {
    provider: typeof sel.provider === 'string' ? sel.provider : null,
    model: typeof sel.model === 'string' ? sel.model : null,
    reasoningEffort: typeof sel.reasoningEffort === 'string' ? sel.reasoningEffort : null,
  }
}

/** Project one runtime session summary onto leaf scalars only. */
function projectSession(summary) {
  return {
    sessionId: readId(summary),
    title: readTitle(summary),
    agentPreset: readPreset(summary),
    model: readModel(summary),
    cwd: typeof summary?.cwd === 'string' ? summary.cwd : null,
    running: summary?.running === true,
    blank: summary?.blank === true,
    completed: summary?.completed === true,
    /**
     * NOT a liveness signal. The host emits `api-session/activity` — the source
     * of this field — only for `user/message` events whose `source.kind` is
     * `user` (dsh-api-session-controller, lib/types/index.js). Assistant
     * messages, tool calls and steps never advance it, so an autonomous run can
     * continue for hours while this timestamp stays fixed. Use `running` plus
     * the `time` of the newest record from `/ctl/tail`, or `stats.steps` from
     * `/ctl/control`, to judge whether a session is alive.
     */
    lastUserInputAt: typeof summary?.updatedAt === 'number' ? summary.updatedAt : null,
  }
}

/** Bounded recursive key walk: paths, types, and short scalar previews. */
function walk(value, depth = 0, prefix = '', out = [], seen = new Set()) {
  if (out.length > 300 || depth > 8) return out
  if (value === null || value === undefined) return out
  const type = typeof value
  if (type === 'string' || type === 'number' || type === 'boolean') {
    out.push({ path: prefix, type, preview: type === 'string' ? value.slice(0, 80) : value })
    return out
  }
  if (type !== 'object') return out
  if (seen.has(value)) return out
  seen.add(value)
  let keys
  try {
    keys = Object.keys(value)
  } catch {
    return out
  }
  for (const key of keys) {
    let child
    try {
      child = value[key]
    } catch {
      continue
    }
    walk(child, depth + 1, prefix === '' ? key : `${prefix}.${key}`, out, seen)
  }
  return out
}

/**
 * Lift one durable history record into a stable shape.
 *
 * The message parts live at DIFFERENT paths depending on the record type, which
 * is not obvious from the type declarations:
 *   user/message       -> event.data.content[]
 *   assistant/message  -> event.data.message.content[]
 * Both were confirmed against a live 0.1.5-rc.2 host. Assistant records also
 * carry token usage and the provider/model that produced them.
 */
function projectRecord(record) {
  const event = record?.event ?? record
  const seq = typeof event?.seq === 'number' ? event.seq : typeof record?.seq === 'number' ? record.seq : null
  const type = typeof event?.type === 'string' ? event.type : null
  const data = event?.data
  const message = data?.message && typeof data.message === 'object' ? data.message : data

  const role =
    typeof message?.role === 'string' ? message.role : typeof data?.role === 'string' ? data.role : null

  let text = null
  const content = message?.content
  if (Array.isArray(content)) {
    const parts = content.filter((p) => p && p.type === 'text' && typeof p.text === 'string').map((p) => p.text)
    if (parts.length > 0) text = parts.join('\n')
  }
  if (text === null && typeof data?.text === 'string') text = data.text

  const usage = data?.usage && typeof data.usage === 'object'
    ? {
        inputTokens: typeof data.usage.inputTokens === 'number' ? data.usage.inputTokens : null,
        outputTokens: typeof data.usage.outputTokens === 'number' ? data.usage.outputTokens : null,
        totalTokens: typeof data.usage.totalTokens === 'number' ? data.usage.totalTokens : null,
        contextTokens: typeof data.usage.cacheReadTokens === 'number' ? data.usage.cacheReadTokens : null,
      }
    : null

  const source = message?.source && typeof message.source === 'object' && typeof message.source.kind === 'string' ? message.source : null

  return {
    seq,
    time: typeof event?.time === 'number' ? event.time : null,
    type,
    role,
    text: typeof text === 'string' ? text.slice(0, 8000) : null,
    provider: typeof source?.provider === 'string' ? source.provider : null,
    model: typeof source?.model === 'string' ? source.model : null,
    usage,
  }
}

/* ------------------------------------------------------------------ *
 * Plugin
 * ------------------------------------------------------------------ */

export function apply(ctx, config = {}) {
  const controller = ctx.sessionController
  const secret = typeof config?.secret === 'string' && config.secret !== '' ? config.secret : null
  const startedAt = Date.now()

  /** Reject anything that is not a loopback caller, and enforce the secret. */
  function guard(req, res) {
    const remote = req.socket?.remoteAddress ?? ''
    if (!LOOPBACK.has(remote)) {
      send(res, 403, { ok: false, error: 'loopback callers only' })
      return false
    }
    if (secret !== null) {
      const header = req.headers['authorization']
      const bearer = typeof header === 'string' && header.toLowerCase().startsWith('bearer ') ? header.slice(7).trim() : null
      const direct = req.headers['x-dsh-ctl-secret']
      if (bearer !== secret && direct !== secret) {
        send(res, 401, { ok: false, error: 'missing or wrong control secret' })
        return false
      }
    }
    return true
  }

  /** Wrap a handler with the guard plus uniform error reporting. */
  function route(path, handler) {
    return ctx.effect(() =>
      ctx.webServer.register({
        kind: 'exact',
        path,
        handler: async (req, res) => {
          if (!guard(req, res)) return
          try {
            await handler(req, res)
          } catch (err) {
            send(res, 500, { ok: false, error: String(err?.message ?? err) })
          }
        },
      }),
    )
  }

  function requirePost(req, res) {
    if (req.method === 'POST') return true
    send(res, 405, { ok: false, error: 'POST required' })
    return false
  }

  route('/ctl', (req, res) =>
    send(res, 200, {
      ok: true,
      name,
      version: VERSION,
      routes: [
        'GET  /ctl',
        'GET  /ctl/health',
        'GET  /ctl/sessions?limit=&running=1',
        'GET  /ctl/session?id=',
        'GET  /ctl/control?ms=&raw=1',
        'GET  /ctl/inspect?id=',
        'GET  /ctl/tail?sessionId=&frames=&ms=',
        'GET  /ctl/schedules?sessionId=   (or all=1 for the whole host)',
        'POST /ctl/create   {cwd?, preset?, agentPreset?, sessionId?}   preset pins read-only|workspace-write|danger-full-access',
          'GET  /ctl/presets  available permission presets and the composed default',
        'GET  /ctl/hypo-checkpoint    sessions opted into dsh-hypo-before-compact',
        'POST /ctl/hypo-checkpoint  {sessionId, enabled}  opt a session in or out',
        'POST /ctl/prompt   {sessionId, text, mode?}',
        'POST /ctl/cancel   {sessionId}',
        'POST /ctl/rename   {sessionId, title}',
        'POST /ctl/schedule {sessionId, title, prompt, daily|cron|weekly|every_seconds|at|after_seconds}',
        'POST /ctl/schedule/update {sessionId, id, title?, prompt?, change?}',
        'POST /ctl/schedule/delete {sessionId, id}',
      ],
    }),
  )

  route('/ctl/health', (req, res) =>
    send(res, 200, {
      ok: true,
      name,
      version: VERSION,
      port: ctx.webServer.port,
      pid: process.pid,
      platform: process.platform,
      arch: process.arch,
      node: process.version,
      uptimeMs: Date.now() - startedAt,
      secretRequired: secret !== null,
    }),
  )

  route('/ctl/sessions', async (req, res) => {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1')
    const limit = Math.min(Math.max(Number(url.searchParams.get('limit') ?? 50) || 50, 1), 1000)
    const onlyRunning = url.searchParams.get('running') === '1'
    const abort = new AbortController()
    const value = await controller.list({}, abort.signal)
    let items = value.items.map(projectSession)
    const running = items.filter((i) => i.running).length
    if (onlyRunning) items = items.filter((i) => i.running)
    send(res, 200, { ok: true, total: value.items.length, running, returned: Math.min(items.length, limit), items: items.slice(0, limit) })
  })

  route('/ctl/session', async (req, res) => {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1')
    const id = url.searchParams.get('id')
    if (!id) return send(res, 400, { ok: false, error: 'id is required' })
    const abort = new AbortController()
    const value = await controller.list({}, abort.signal)
    const found = value.items.map(projectSession).find((s) => s.sessionId === id)
    if (!found) return send(res, 404, { ok: false, error: 'unknown session id' })
    send(res, 200, { ok: true, session: found })
  })

  route('/ctl/tail', async (req, res) => {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1')
    const sessionId = url.searchParams.get('sessionId')
    if (!sessionId) return send(res, 400, { ok: false, error: 'sessionId is required' })
    const frames = Math.min(Math.max(Number(url.searchParams.get('frames') ?? 40) || 40, 1), 500)
    const ms = Math.min(Math.max(Number(url.searchParams.get('ms') ?? 3000) || 3000, 100), 30_000)

    const out = { ok: true, cursor: null, hasMore: false, records: [], events: [] }
    const abort = new AbortController()
    const timer = setTimeout(() => abort.abort(), ms)
    try {
      for await (const frame of controller.follow(
        { address: { kind: 'session', sessionId }, maxMessages: 20 },
        abort.signal,
      )) {
        if (frame?.type === 'snapshot') {
          out.cursor = typeof frame.cursor === 'number' ? frame.cursor : null
          out.hasMore = frame.hasMore === true
          if (Array.isArray(frame.records)) out.records = frame.records.map(projectRecord)
        } else if (frame?.type === 'event') {
          out.events.push(projectRecord(frame))
        }
        if (out.records.length + out.events.length >= frames) break
      }
    } catch (err) {
      if (!abort.signal.aborted) throw err
    } finally {
      clearTimeout(timer)
    }
    send(res, 200, out)
  })

  // Read-only schema introspection. Exists because the published type
  // declarations and the runtime record shape disagree across DSH versions;
  // this route reports key paths (with short previews) instead of guessing.
  route('/ctl/debug/shape', async (req, res) => {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1')
    const sessionId = url.searchParams.get('sessionId')
    if (!sessionId) return send(res, 400, { ok: false, error: 'sessionId is required' })
    const wanted = url.searchParams.get('type') ?? 'assistant/message'

    const abort = new AbortController()
    const timer = setTimeout(() => abort.abort(), 4000)
    let shapes = []
    try {
      for await (const frame of controller.follow({ address: { kind: 'session', sessionId }, maxMessages: 20 }, abort.signal)) {
        if (frame?.type === 'snapshot' && Array.isArray(frame.records)) {
          shapes = frame.records
            .filter((r) => (r?.event?.type ?? r?.type) === wanted)
            .slice(-1)
            .map((r) => walk(r))
        }
        if (shapes.length > 0) break
      }
    } catch (err) {
      if (!abort.signal.aborted) throw err
    } finally {
      clearTimeout(timer)
    }
    send(res, 200, { ok: true, type: wanted, found: shapes.length, paths: shapes[0] ?? [] })
  })

  // Live per-session state: the pending queue (each item carries a `placement`,
  // which is exactly how `queue` and `steer` injection differ) plus running
  // stats. `control()` is a process-wide stream, not per-session.
  //
  //   placement 'queued'   -> the message waits for the next turn
  //   placement 'steering' -> the message was spliced into the turn in flight
  //
  // The baseline arrives as one live object; only leaf scalars are read out.
  // Pass ?raw=1 for the full key-path dump when a version changes shape.
  route('/ctl/control', async (req, res) => {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1')
    const ms = Math.min(Math.max(Number(url.searchParams.get('ms') ?? 2500) || 2500, 100), 30_000)
    const raw = url.searchParams.get('raw') === '1'

    const abort = new AbortController()
    const timer = setTimeout(() => abort.abort(), ms)
    let baseline = null
    let rawFrame = null
    try {
      for await (const frame of controller.control(abort.signal)) {
        if (frame?.type === 'baseline') {
          baseline = frame.value
          rawFrame = frame
          break
        }
      }
    } catch (err) {
      if (!abort.signal.aborted) throw err
    } finally {
      clearTimeout(timer)
    }

    if (baseline === null) return send(res, 200, { ok: true, sessions: {}, note: 'no baseline within timeout' })
    if (raw) {
      const own = baseline && typeof baseline === 'object' ? Object.getOwnPropertyNames(baseline) : []
      let proto = []
      try {
        proto = baseline ? Object.getOwnPropertyNames(Object.getPrototypeOf(baseline) ?? {}) : []
      } catch {
        proto = []
      }
      const describeValue = (v) => {
        if (v === null || v === undefined) return { ctor: String(v), isMap: false, isArray: false, ownKeys: [], size: null }
        const ctor = v?.constructor?.name ?? 'null-proto'
        const isMap = v instanceof Map
        const isArray = Array.isArray(v)
        let ownKeys = []
        try {
          ownKeys = isMap ? [] : Object.getOwnPropertyNames(v)
        } catch {
          ownKeys = ['<unreadable>']
        }
        let size = null
        try {
          if (isMap || v instanceof Set) size = v.size
        } catch {
          size = null
        }
        return { ctor, isMap, isArray, ownKeys, size }
      }
      const details = {}
      for (const key of own) {
        let child
        try {
          child = baseline[key]
        } catch {
          details[key] = { error: 'getter threw' }
          continue
        }
        const d = describeValue(child)
        if (d.isMap) {
          const entries = []
          let i = 0
          try {
            for (const [k, val] of child) {
              if (i++ >= 3) break
              entries.push({ key: String(k), valueShape: walk(val).slice(0, 40) })
            }
          } catch {
            entries.push({ error: 'iteration failed' })
          }
          details[key] = { ...d, entries }
        } else {
          details[key] = d
        }
      }
      return send(res, 200, {
        ok: true,
        ctor: baseline?.constructor?.name ?? null,
        ownKeys: own,
        protoKeys: proto,
        frameKeys: Object.keys(rawFrame ?? {}),
        details,
        sample: (() => {
          try {
            const p = baseline.projections
            if (p instanceof Map) {
              const first = [...p.keys()][0]
              return { firstKey: String(first), shape: walk(p.get(first)).slice(0, 60) }
            }
            return { shape: walk(p).slice(0, 60) }
          } catch (err) {
            return { error: String(err?.message ?? err) }
          }
        })(),
      })
    }

    const sessions = {}
    const ensure = (id) => {
      if (!sessions[id]) sessions[id] = { queue: [], lastEventSeq: null, stats: null, planPending: null }
      return sessions[id]
    }

    const queues = baseline.queues
    if (queues && typeof queues === 'object') {
      let ids = []
      try {
        ids = Object.keys(queues)
      } catch {
        ids = []
      }
      for (const id of ids) {
        let list = []
        try {
          list = Array.isArray(queues[id]) ? queues[id] : []
        } catch {
          list = []
        }
        const entry = ensure(id)
        for (const item of list) {
          const content = item?.message?.content
          let text = null
          if (Array.isArray(content)) {
            const parts = content.filter((p) => p && p.type === 'text' && typeof p.text === 'string').map((p) => p.text)
            if (parts.length > 0) text = parts.join('\n')
          }
          entry.queue.push({
            id: typeof item?.id === 'string' ? item.id : null,
            placement: typeof item?.placement === 'string' ? item.placement : null,
            rpcId: typeof item?.rpcId === 'string' ? item.rpcId : null,
            text: text === null ? null : text.slice(0, 2000),
          })
        }
      }
    }

    const projections = baseline.projections
    if (projections && typeof projections === 'object') {
      let ids = []
      try {
        ids = Object.keys(projections)
      } catch {
        ids = []
      }
      for (const id of ids) {
        const entry = ensure(id)
        let values = null
        let asOfSeq = null
        try {
          const projection = projections[id]
          values = projection?.values ?? null
          // Durable log position the projection has folded up to. It advances
          // with writes, but it is a *flush* cursor: it can sit still for
          // seconds while the agent is actively working, so treat a changing
          // value as proof of progress and an unchanged value as no evidence
          // either way. `stats.steps` is the better in-memory heartbeat.
          asOfSeq = typeof projection?.asOfSeq === 'number' ? projection.asOfSeq : null
        } catch {
          values = null
          asOfSeq = null
        }
        entry.lastEventSeq = asOfSeq
        if (!values) continue
        const stats = values.sessionStats
        if (stats && typeof stats === 'object') {
          entry.stats = {
            turns: typeof stats.turns === 'number' ? stats.turns : null,
            steps: typeof stats.steps === 'number' ? stats.steps : null,
            llmMs: typeof stats.llmMs === 'number' ? stats.llmMs : null,
            toolMs: typeof stats.toolMs === 'number' ? stats.toolMs : null,
            ttftMs: typeof stats.ttftMs === 'number' ? stats.ttftMs : null,
            decodeTokens: typeof stats.decodeTokens === 'number' ? stats.decodeTokens : null,
          }
        }
        if (values.plan && typeof values.plan.pending === 'boolean') entry.planPending = values.plan.pending
      }
    }

    send(res, 200, { ok: true, sessions })
  })

  // Inspect one session without activating its agent: attached state plus the
  // persisted header and event prefix. Useful while a turn is in flight.
  route('/ctl/inspect', async (req, res) => {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1')
    const id = url.searchParams.get('id')
    if (!id) return send(res, 400, { ok: false, error: 'id is required' })
    const abort = new AbortController()
    const value = await controller.inspect(id, abort.signal)
    send(res, 200, { ok: true, keys: value ? Object.keys(value) : [], shape: walk(value) })
  })

  route('/ctl/create', async (req, res) => {
    if (!requirePost(req, res)) return
    const body = await readJson(req)
    const request = {}
    if (typeof body.cwd === 'string' && body.cwd !== '') request.cwd = body.cwd
    if (typeof body.sessionId === 'string' && body.sessionId !== '') request.sessionId = body.sessionId
    if (typeof body.agentPreset === 'string' && body.agentPreset !== '') request.agentPreset = body.agentPreset
    const value = await controller.create(request)
    const sessionId = typeof value?.sessionId === 'string' ? value.sessionId : readId(value)
    const payload = {
      ok: true,
      sessionId,
      agentPreset: typeof value?.agentPreset === 'string' ? value.agentPreset : null,
      preset: null,
    }
    // An unknown preset name must fail loudly but must not look like a failed
    // creation: the session exists either way, and a caller that retries would
    // leak one session per attempt.
    if (typeof body.preset === 'string' && body.preset !== '') {
      try {
        payload.preset = pinPermission(sessionId, body.preset)
      } catch (err) {
        payload.presetError = String(err?.message ?? err)
      }
    }
    send(res, 200, payload)
  })

  route('/ctl/presets', (req, res) => {
    const permission = typeof ctx.get === 'function' ? ctx.get('permissionPresets') : undefined
    if (!permission || typeof permission.resolve !== 'function') {
      return send(res, 501, {
        ok: false,
        error: 'the permission presets service is not mounted in this profile',
        hint: 'The `permission` row (@deepseek-ai/dsh-permission-presets) ships with the base bundle; a profile that removed it cannot pin presets.',
      })
    }
    let names = []
    try {
      names = Array.isArray(permission.names) ? permission.names.slice() : []
    } catch {
      names = []
    }
    const items = names.map((name) => {
      try {
        const spec = permission.resolve(name)
        return {
          name,
          sandbox: typeof spec?.sandbox === 'string' ? spec.sandbox : null,
          approval: typeof spec?.approval === 'string' ? spec.approval : null,
          description: typeof spec?.description === 'string' ? spec.description : null,
        }
      } catch {
        return { name, sandbox: null, approval: null, description: null }
      }
    })
    let defaultPreset = null
    try {
      if (typeof permission.defaultPreset === 'string') defaultPreset = permission.defaultPreset
    } catch {
      defaultPreset = null
    }
    send(res, 200, { ok: true, defaultPreset, items })
  })

  route('/ctl/prompt', async (req, res) => {
    if (!requirePost(req, res)) return
    const body = await readJson(req)
    if (typeof body.sessionId !== 'string' || body.sessionId === '') {
      return send(res, 400, { ok: false, error: 'sessionId is required' })
    }
    if (typeof body.text !== 'string' || body.text.trim() === '') {
      return send(res, 400, { ok: false, error: 'text must be a non-empty string' })
    }
    const abort = new AbortController()
    const value = await controller.prompt(
      {
        requestId: typeof body.requestId === 'string' && body.requestId !== '' ? body.requestId : randomUUID(),
        sessionId: body.sessionId,
        mode: body.mode === 'steer' ? 'steer' : 'queue',
        content: [{ type: 'text', text: body.text }],
        ...(typeof body.clientTimeZone === 'string' ? { clientTimeZone: body.clientTimeZone } : {}),
      },
      abort.signal,
    )
    send(res, 200, { ok: true, accepted: value?.accepted === true })
  })

  route('/ctl/cancel', async (req, res) => {
    if (!requirePost(req, res)) return
    const body = await readJson(req)
    if (typeof body.sessionId !== 'string' || body.sessionId === '') {
      return send(res, 400, { ok: false, error: 'sessionId is required' })
    }
    const value = controller.cancel({ sessionId: body.sessionId })
    send(res, 200, { ok: true, accepted: value?.accepted === true })
  })

  route('/ctl/rename', async (req, res) => {
    if (!requirePost(req, res)) return
    const body = await readJson(req)
    if (typeof body.sessionId !== 'string' || body.sessionId === '') {
      return send(res, 400, { ok: false, error: 'sessionId is required' })
    }
    if (typeof body.title !== 'string') return send(res, 400, { ok: false, error: 'title must be a string' })
    const value = await controller.rename({ sessionId: body.sessionId, title: body.title })
    send(res, 200, { ok: true, renamed: true, value: typeof value?.title === 'string' ? value.title : null })
  })

  /* ------------------------------------------------------------------ *
   * Schedule (durable reminders)
   *
   * `schedule` is deliberately NOT in `inject`: the service exists only when the
   * profile mounts @deepseek-ai/dsh-schedule, and a required inject would stop
   * this whole plugin from loading on a host that does not. ctx.get() answers
   * undefined instead of throwing, which is what the 501 path below needs.
   *
   * That package declares no dsh.bundle, so it cannot go into package.json's
   * dsh.profile.bundles — it is inserted through the profile's
   * cordis.patch.yml. On 0.2.x the model-facing tools live in a second package,
   * @deepseek-ai/dsh-tool-schedule.
   * ------------------------------------------------------------------ */

  const TIMING_KEYS = ['after_seconds', 'at', 'every_seconds', 'daily', 'weekly', 'cron']

  function scheduleService(res) {
    const svc = typeof ctx.get === 'function' ? ctx.get('schedule') : undefined
    if (!svc || typeof svc.create !== 'function') {
      send(res, 501, {
        ok: false,
        error: 'the schedule service is not mounted in this profile',
        hint:
          'Insert {"id":"schedule","name":"@deepseek-ai/dsh-schedule"} into the profile cordis.patch.yml and restart. For the model-facing tools (schedule_create and friends) also insert @deepseek-ai/dsh-tool-schedule: on 0.2.x they are separate packages, and neither can live in dsh.profile.bundles.',
      })
      return null
    }
    return svc
  }

  /**
   * Pin a permission preset onto a freshly created session.
   *
   * The host's `session.create` request accepts only `sessionId`, `cwd` /
   * `workspaceId` and `agentPreset` — there is no permission field. A preset is
   * durable once written to the session log, and a fresh session otherwise
   * inherits whatever the process environment (`DSH_PERMISSION_MODE`) implied at
   * load time. That is why `/ctl/create` used to always produce a workspace-write
   * session no matter what the caller wanted.
   *
   * We write the same three durable events the permission service writes when a
   * user switches preset by hand, right after creation:
   *   permission/preset  — the durable identity `current()`/`derive()` fold
   *   sandbox/mode       — what the tool runner enforces
   *   approval/policy    — what the approval service folds on each request
   *
   * Writing them here rather than calling `permissionPresets.apply()` is
   * deliberate: `apply()` needs the live Agent (its third argument mutates the
   * agent's approval policy), and this route only ever holds a Session.
   */
  function pinPermission(sessionId, preset) {
    const permission = typeof ctx.get === 'function' ? ctx.get('permissionPresets') : undefined
    if (!permission || typeof permission.resolve !== 'function') {
      throw new Error(
        'the permission presets service is not mounted in this profile (expected @deepseek-ai/dsh-permission-presets)',
      )
    }
    const sessions = typeof ctx.get === 'function' ? ctx.get('sessions') : undefined
    const session = sessions && typeof sessions.get === 'function' ? sessions.get(sessionId) : undefined
    if (!session || typeof session.append !== 'function') {
      throw new Error(`session "${sessionId}" is not in the live sessions registry yet; the preset was not pinned`)
    }
    const spec = permission.resolve(preset) // throws on an unknown preset
    session.append('permission/preset', { preset })
    if (typeof spec?.sandbox === 'string') session.append('sandbox/mode', { mode: spec.sandbox })
    if (typeof spec?.approval === 'string') session.append('approval/policy', { policy: spec.approval })
    return { preset, sandbox: typeof spec?.sandbox === 'string' ? spec.sandbox : null, approval: typeof spec?.approval === 'string' ? spec.approval : null }
  }

  /** Leaf scalars only, same rule as the session projection. */
  function projectSchedule(record) {
    if (!record || typeof record !== 'object') return null
    const out = {
      id: typeof record.id === 'string' ? record.id : null,
      kind: typeof record.kind === 'string' ? record.kind : null,
      title: typeof record.title === 'string' ? record.title : null,
      prompt: typeof record.prompt === 'string' ? record.prompt : null,
      scheduledAt: typeof record.scheduledAt === 'string' ? record.scheduledAt : null,
    }
    if (typeof record.time === 'string') out.time = record.time
    if (typeof record.timeZone === 'string') out.timeZone = record.timeZone
    if (Array.isArray(record.weekdays)) out.weekdays = record.weekdays.slice()
    if (typeof record.expression === 'string') out.expression = record.expression
    if (typeof record.afterSeconds === 'number') out.afterSeconds = record.afterSeconds
    if (typeof record.sessionId === 'string') out.sessionId = record.sessionId
    if (record.status === 'active' || record.status === 'inactive') out.status = record.status
    if (record.state === 'scheduled' || record.state === 'overdue') out.state = record.state
    else if (out.scheduledAt) out.state = Date.parse(out.scheduledAt) > Date.now() ? 'scheduled' : 'overdue'
    return out
  }

  // GET /ctl/schedules?sessionId=<id>   one session's tasks
  // GET /ctl/schedules?all=1            every reminder on this host, with bindings
  route('/ctl/schedules', async (req, res) => {
    const svc = scheduleService(res)
    if (!svc) return
    const url = new URL(req.url ?? '/', 'http://127.0.0.1')
    const sessionId = url.searchParams.get('sessionId')
    const all = url.searchParams.get('all') === '1'
    if (all) {
      if (typeof svc.catalog !== 'function') {
        return send(res, 501, { ok: false, error: 'this host exposes no schedule catalog()' })
      }
      const rows = await svc.catalog()
      return send(res, 200, { ok: true, scope: 'host', count: rows.length, items: rows.map(projectSchedule) })
    }
    if (!sessionId) {
      return send(res, 400, { ok: false, error: 'sessionId is required (or pass all=1 for the whole host)' })
    }
    const rows = await svc.list({ sessionId })
    send(res, 200, { ok: true, scope: 'session', sessionId, count: rows.length, items: rows.map(projectSchedule) })
  })

  // POST /ctl/schedule {sessionId, title, prompt, + exactly one timing selector}
  route('/ctl/schedule', async (req, res) => {
    if (!requirePost(req, res)) return
    const svc = scheduleService(res)
    if (!svc) return
    const body = await readJson(req)
    if (typeof body.sessionId !== 'string' || body.sessionId === '') {
      return send(res, 400, { ok: false, error: 'sessionId is required' })
    }
    if (typeof body.title !== 'string' || body.title.trim() === '') {
      return send(res, 400, { ok: false, error: 'title is required and must not be blank' })
    }
    if (typeof body.prompt !== 'string' || body.prompt.trim() === '') {
      return send(res, 400, { ok: false, error: 'prompt is required and must not be blank' })
    }
    const present = TIMING_KEYS.filter((k) => body[k] !== undefined && body[k] !== null)
    if (present.length !== 1) {
      return send(res, 400, {
        ok: false,
        error: 'exactly one timing selector is required',
        selectors: TIMING_KEYS,
        received: present,
        examples: {
          daily: { daily: { time: '20:00', time_zone: 'Asia/Shanghai' } },
          cron: { cron: { expression: '0 20 * * *', time_zone: 'Asia/Shanghai' } },
          weekly: { weekly: { time: '09:30', time_zone: 'Asia/Shanghai', weekdays: [1, 3, 5] } },
          every_seconds: { every_seconds: 900 },
          after_seconds: { after_seconds: 60 },
        },
      })
    }
    const request = { title: body.title, prompt: body.prompt }
    request[present[0]] = body[present[0]]
    let record
    try {
      record = await svc.create(body.sessionId, request)
    } catch (err) {
      // The host validates the shape far more strictly than this endpoint can
      // (time format, title length, subagent-bound sessions, rate floor). Those
      // are caller mistakes, so surface them as 400 rather than a blanket 500.
      return send(res, 400, { ok: false, error: String(err?.message ?? err), rejected_by: 'host' })
    }
    send(res, 200, { ok: true, created: true, schedule: projectSchedule(record) })
  })

  // POST /ctl/schedule/delete {sessionId, id}
  route('/ctl/schedule/delete', async (req, res) => {
    if (!requirePost(req, res)) return
    const svc = scheduleService(res)
    if (!svc) return
    const body = await readJson(req)
    if (typeof body.sessionId !== 'string' || body.sessionId === '') {
      return send(res, 400, { ok: false, error: 'sessionId is required' })
    }
    if (typeof body.id !== 'string' || body.id === '') {
      return send(res, 400, { ok: false, error: 'id is required' })
    }
    const value = await svc.delete({ sessionId: body.sessionId, id: body.id })
    send(res, 200, { ok: true, id: body.id, deleted: value?.deleted === true, code: value?.code ?? null })
  })

  // POST /ctl/schedule/update {sessionId, id, title?, prompt?, change?}
  // The service is compare-and-update: it wants the record you observed. Read it
  // first so callers do not have to round-trip the whole record themselves.
  route('/ctl/schedule/update', async (req, res) => {
    if (!requirePost(req, res)) return
    const svc = scheduleService(res)
    if (!svc) return
    const body = await readJson(req)
    if (typeof body.sessionId !== 'string' || body.sessionId === '') {
      return send(res, 400, { ok: false, error: 'sessionId is required' })
    }
    if (typeof body.id !== 'string' || body.id === '') {
      return send(res, 400, { ok: false, error: 'id is required' })
    }
    const rows = await svc.list({ sessionId: body.sessionId })
    const expected = rows.find((r) => r?.id === body.id)
    if (!expected) {
      return send(res, 404, { ok: false, error: 'schedule not found in that session', id: body.id })
    }
    const request = { sessionId: body.sessionId, id: body.id, expected }
    if (typeof body.title === 'string') request.title = body.title
    if (typeof body.prompt === 'string') request.prompt = body.prompt
    if (body.change && typeof body.change === 'object') request.change = body.change
    let value
    try {
      value = await svc.update(request)
    } catch (err) {
      return send(res, 400, { ok: false, error: String(err?.message ?? err), rejected_by: 'host' })
    }
    send(res, 200, {
      ok: true,
      id: body.id,
      updated: value?.updated === true,
      code: value?.code ?? null,
      schedule: value?.record ? projectSchedule(value.record) : null,
    })
  })

  /* ------------------------------------------------------------------ *
   * Hypomnesis checkpoint allowlist
   *
   * dsh-hypo-before-compact serves only sessions that opted in. The file is the
   * shared contract between three writers — the plugin (reader), its CLI
   * (`hypo-checkpoint enable --self`, run inside a session), and these routes
   * (driven from outside). Keeping one format here avoids a second source of
   * truth; the plugin tolerates a missing file and reloads on mtime change, so a
   * write through this route takes effect without a restart.
   *
   * Shape: {"version":1,"sessions":["session-..."]}
   */
  function hypoAllowlistPath() {
    if (typeof config?.hypoAllowlistFile === 'string' && config.hypoAllowlistFile !== '') {
      return path.resolve(config.hypoAllowlistFile)
    }
    const home =
      typeof process.env.DSH_HOME === 'string' && process.env.DSH_HOME !== ''
        ? process.env.DSH_HOME
        : path.join(os.homedir(), '.dsh')
    return path.join(home, 'hypo-checkpoint-sessions.json')
  }

  function readHypoAllowlist(file) {
    try {
      const raw = fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '')
      const doc = JSON.parse(raw)
      const list = Array.isArray(doc) ? doc : Array.isArray(doc?.sessions) ? doc.sessions : []
      return [...new Set(list.filter((id) => typeof id === 'string' && id !== ''))].sort()
    } catch (err) {
      if (err?.code === 'ENOENT') return []
      throw err
    }
  }

  function writeHypoAllowlist(file, sessions) {
    const payload = { version: 1, sessions: [...new Set(sessions)].sort() }
    fs.mkdirSync(path.dirname(file), { recursive: true })
    const tmp = `${file}.${process.pid}.tmp`
    fs.writeFileSync(tmp, `${JSON.stringify(payload, null, 2)}\n`, 'utf8')
    fs.renameSync(tmp, file)
  }

  route('/ctl/hypo-checkpoint', async (req, res) => {
    const file = hypoAllowlistPath()
    if (req.method === 'GET') {
      let sessions
      try {
        sessions = readHypoAllowlist(file)
      } catch (err) {
        return send(res, 500, { ok: false, error: String(err?.message ?? err), file })
      }
      return send(res, 200, { ok: true, file, count: sessions.length, sessions })
    }
    if (!requirePost(req, res)) return
    const body = await readJson(req)
    if (typeof body.sessionId !== 'string' || body.sessionId === '') {
      return send(res, 400, { ok: false, error: 'sessionId is required' })
    }
    if (typeof body.enabled !== 'boolean') {
      return send(res, 400, { ok: false, error: 'enabled must be a boolean' })
    }
    let sessions
    try {
      sessions = readHypoAllowlist(file)
    } catch (err) {
      return send(res, 500, { ok: false, error: String(err?.message ?? err), file })
    }
    const before = sessions.includes(body.sessionId)
    const next = body.enabled ? [...sessions, body.sessionId] : sessions.filter((id) => id !== body.sessionId)
    if (before !== body.enabled) {
      try {
        writeHypoAllowlist(file, next)
      } catch (err) {
        return send(res, 500, { ok: false, error: String(err?.message ?? err), file })
      }
    }
    send(res, 200, {
      ok: true,
      file,
      sessionId: body.sessionId,
      enabled: body.enabled,
      changed: before !== body.enabled,
      count: new Set(next).size,
    })
  })
}
