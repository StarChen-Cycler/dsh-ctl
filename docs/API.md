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
      "updatedAt": 1793940385717
    }
  ]
}
```

`total` is the number of sessions the host knows about, `running` the number
executing at the moment of the call, `returned` how many are in `items`.

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
    { "seq": 8,  "type": "user/message",      "role": "user",      "text": "Reply with exactly: PONG", "provider": null, "model": null, "usage": null },
    { "seq": 17, "type": "assistant/message", "role": "assistant", "text": "PONG", "provider": "deepseek-official", "model": "deepseek-flash",
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
