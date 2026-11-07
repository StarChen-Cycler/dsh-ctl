# API reference

Base URL: `http://127.0.0.1:<port>` — the port you passed to `dsh web`.
All responses are `application/json; charset=utf-8` with `cache-control: no-store`.

Every route is guarded: non-loopback socket addresses get `403`, and a wrong or
missing secret (when configured) gets `401`.

---

## `GET /ctl`

Route index.

```json
{
  "ok": true,
  "name": "dsh-ctl",
  "version": "0.1.0",
  "routes": [
    "GET  /ctl/sessions?limit=&running=1",
    "POST /ctl/prompt   {sessionId, text, mode?}"
  ]
}
```

## `GET /ctl/health`

```json
{
  "ok": true,
  "name": "dsh-ctl",
  "version": "0.1.0",
  "port": 17390,
  "pid": 18260,
  "platform": "win32",
  "arch": "x64",
  "node": "v22.23.2",
  "uptimeMs": 1465,
  "secretRequired": false
}
```

## `GET /ctl/sessions`

Query: `limit` (1–1000, default 50), `running=1` to filter to executing sessions only.

```json
{
  "ok": true,
  "total": 248,
  "running": 1,
  "returned": 2,
  "items": [
    {
      "sessionId": "session-1ad7fa71-…",
      "title": "dsh-ctl smoke test",
      "agentPreset": "standard",
      "model": { "provider": null, "model": null, "reasoningEffort": null },
      "cwd": "/srv/work",
      "running": false,
      "blank": false,
      "completed": false,
      "lastUserInputAt": 1793940385717
    }
  ]
}
```

`total` is the number of sessions the host knows about, `running` the number
executing at the moment of the call, `returned` how many are in `items`.

> **`lastUserInputAt` is not a liveness signal.** The host raises
> `api-session/activity` — the only source of this value — exclusively for
> `user/message` events whose `source.kind` is `user`, so assistant messages, tool
> calls and steps never move it. An agent working autonomously keeps it frozen.
> Use `running`, the `time` of the newest `/ctl/tail` record, or `stats.steps`
> from `/ctl/control` instead. (Before 0.1.1 this field was called `updatedAt`.)

## `GET /ctl/session?id=<session-id>`

One session, or `404 { "ok": false, "error": "unknown session id" }`.

## `GET /ctl/tail?sessionId=&frames=&ms=`

Opens a follow stream, returns the opening history snapshot, waits up to `ms`
(100–30000, default 3000) for live frames, then closes.

- `frames` caps `records + events` (1–500, default 40).

```json
{
  "ok": true,
  "cursor": 19,
  "hasMore": false,
  "records": [
    { "seq": 8,  "time": 1793940195129, "type": "user/message",      "role": "user",      "text": "Reply with exactly: PONG", "provider": null, "model": null, "usage": null },
    { "seq": 17, "time": 1793940387408, "type": "assistant/message", "role": "assistant", "text": "PONG", "provider": "deepseek-official", "model": "deepseek-flash",
      "usage": { "inputTokens": 19211, "outputTokens": 3, "totalTokens": 20366, "contextTokens": 1152 } }
  ],
  "events": []
}
```

`cursor` is the inclusive log cut at which the snapshot was taken. `events`
carries live frames that arrived during the call. Records that are not messages
(`request/header`, `session/title`, `turn/end`, …) have `text: null` and are still
returned in order so you can reason about turn boundaries.

## `POST /ctl/create`

```json
{ "cwd": "/srv/work", "agentPreset": "standard", "sessionId": "optional-explicit-id" }
```

All fields are optional. `cwd` must be absolute when given.

```json
{ "ok": true, "sessionId": "session-1ad7fa71-…", "agentPreset": "standard" }
```

## `POST /ctl/prompt`

```json
{ "sessionId": "session-…", "text": "run the tests", "mode": "queue", "requestId": "optional-uuid" }
```

- `mode`: `queue` (default) or `steer`.
- `requestId` defaults to a fresh UUID. Reusing one makes the call idempotent at the
  host, which is what you want when a retry might be needed.
- `text` must contain non-whitespace.

```json
{ "ok": true, "accepted": true }
```

Acceptance means the host admitted the message, not that the turn finished.
Poll `/ctl/sessions?running=1` or call `/ctl/tail` to observe progress.

## `POST /ctl/cancel`

```json
{ "sessionId": "session-…" }
```

```json
{ "ok": true, "accepted": true }
```

Cancels the in-flight turn. With no turn running it is a no-op that still returns
`accepted: true`.

## `GET /ctl/control?ms=&raw=1`

Live state of every session the host tracks, read from the process-wide control
stream. This is the endpoint to use **while a turn is in flight**.

`ms` bounds how long to wait for the opening baseline (100–30000, default 2500).
`raw=1` returns the full key-path dump instead of the projection.

```json
{
  "ok": true,
  "sessions": {
    "session-65b44335-…": {
      "queue": [
        { "id": "25df4ced-…", "placement": "queued",   "rpcId": "f9db0b14-…", "text": "QUEUE-DEMO wait your turn" },
        { "id": "ae8e2419-…", "placement": "steering", "rpcId": "a1c4f0e2-…", "text": "STEER-DEMO act now" }
      ],
      "lastEventSeq": 6196,
      "stats": { "turns": 5, "steps": 8, "llmMs": 19847, "toolMs": 49966, "ttftMs": 8662, "decodeTokens": 2032 },
      "planPending": false
    }
  }
}
```

`lastEventSeq` is the durable log position the projection has folded up to. It is a
**flush cursor, not a heartbeat**: it can sit still for seconds while the agent is
actively working. A changing value proves progress; an unchanged value proves
nothing. `stats.steps` is the better in-memory liveness counter.

### `placement` is how `queue` and `steer` differ

| injection `mode` | `placement` | meaning |
|---|---|---|
| `queue` (default) | `queued` | held until the current turn ends, then delivered as the next turn |
| `steer` | `steering` | spliced into the turn that is already running |

Both produce `accepted: true` and **neither appears in the durable log until the
turn claims it**, so `tail` is the wrong place to look — use this endpoint.

> **Version caveat.** `placement` comes from the host's `queues` projection, which
> `0.2.1-rc.5` no longer publishes: on that version the field is absent and this
> endpoint cannot distinguish queue from steer. `accepted: true` still means the
> injection was taken; it says nothing about where it landed. Verified on
> `0.1.5-rc.2` only — see [VERIFICATION.md](VERIFICATION.md) 9.2, 9.3 and 10.3.

## `GET /ctl/inspect?id=<session-id>`

Inspects one session without activating its agent: attached state plus the
persisted header and event prefix.

```json
{
  "ok": true,
  "keys": ["meta", "inheritedEventCount", "events"],
  "shape": [
    { "path": "meta.id", "type": "string", "preview": "session-65b44335-…" },
    { "path": "meta.cwd", "type": "string", "preview": "/srv/work" },
    { "path": "events.3.data.target", "type": "string", "preview": "next-turn" }
  ]
}
```

`shape` is a bounded key-path walk (max 300 entries, depth 8). Useful when a
field you depend on comes back empty on a new DSH version — compare the paths
here against what this plugin expects.

## `POST /ctl/rename`

```json
{ "sessionId": "session-…", "title": "nightly migration" }
```

```json
{ "ok": true, "renamed": true, "value": "nightly migration" }
```

## `GET /ctl/debug/shape?sessionId=&type=`

Read-only schema introspection. Returns key paths, types and 80-character previews
for the most recent record of `type` (default `assistant/message`).

Use it when a DSH upgrade changes the runtime shape and a field comes back `null`:

```sh
curl -s "http://127.0.0.1:17390/ctl/debug/shape?sessionId=session-…&type=assistant/message"
```

It reports paths only — it never returns a full message body.

---

## `GET /ctl/schedules?sessionId=<id>` (or `?all=1`)

Durable reminders stored by the host's `ctx.schedule` service. `?sessionId=` reads
one session's tasks; `?all=1` returns the whole host's catalog, each entry
carrying the session it is bound to.

```json
{
  "ok": true, "scope": "host", "count": 1,
  "items": [
    { "id": "schedule-9c2d1bfb-…", "kind": "daily",
      "title": "nightly digest", "prompt": "run the digest",
      "time": "20:00:00.000", "timeZone": "Asia/Shanghai",
      "scheduledAt": "2026-11-08T12:00:00.000Z",
      "sessionId": "session-…", "status": "active", "state": "scheduled" }
  ]
}
```

`state` is `scheduled` or `overdue`, derived from `scheduledAt` and the clock on
this endpoint's side. `status` (`active`/`inactive`) only appears in the host
catalog, where inactive reminders remain visible but never fire again.

**`501` means the profile does not mount the service.** See the README section
"Schedules" for the two `cordis.patch.yml` rows; neither package declares
`dsh.bundle`, so they cannot live in `dsh.profile.bundles`.

## `POST /ctl/schedule`

```json
{ "sessionId": "session-…", "title": "nightly digest", "prompt": "run the digest",
  "daily": { "time": "20:00", "time_zone": "Asia/Shanghai" } }
```

Exactly one timing selector is required:

| selector | shape |
|---|---|
| `daily` | `{ time, time_zone }` |
| `cron` | `{ expression, time_zone }` — five-field Vixie cron |
| `weekly` | `{ time, time_zone, weekdays }` — ISO 1=Mon … 7=Sun |
| `every_seconds` | number, minimum 300 |
| `after_seconds` | number, one-shot relative delay |
| `at` | ISO instant, or `{ date, time, time_zone }` |

Omitting the selector, or sending two, returns `400` with the accepted list and
examples. The host rejects a blank or over-120-character `title`
(`invalid_prompt`), a session owned by a delegated subagent (`subagent_session`),
and a recurrence faster than the minimum (`frequency_too_high`).

## `POST /ctl/schedule/update`

```json
{ "sessionId": "session-…", "id": "schedule-…",
  "title": "new name", "change": { "kind": "cron",
    "cron": { "expression": "0 21 * * *", "time_zone": "Asia/Shanghai" } } }
```

The host's update is compare-and-update: it commits only if the record you
observed is still current. Rather than making callers round-trip the whole
record, this endpoint reads it (`list`) and passes it as `expected`, so the
comparison still happens host-side. `ok: true` with `updated: false` plus
`code: schedule_conflict` means the task changed between the read and the write —
retry.

## `POST /ctl/schedule/delete`

```json
{ "sessionId": "session-…", "id": "schedule-…" }
```

`{ "ok": true, "deleted": true }`, or `deleted: false` with
`code: "schedule_not_found"`. Queued inbox messages are left intact.

## Error shape

Every failure uses the same envelope:

```json
{ "ok": false, "error": "sessionId is required" }
```

| Status | When |
|---|---|
| `400` | missing or invalid parameter |
| `401` | secret configured but absent or wrong |
| `403` | caller socket is not loopback |
| `404` | unknown session id |
| `405` | non-`POST` call to a mutating route |
| `500` | unexpected host failure (message included) |
