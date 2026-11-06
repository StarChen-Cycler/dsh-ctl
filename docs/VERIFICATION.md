# Verification record

Everything below was executed against a live host before the plugin was published.
The point of recording it is that several of these facts contradict the shipped
documentation, so "it compiles" was not good enough.

**Environment:** DeepSeek Harness CLI `0.1.5-rc.2`, Node `v22.23.2`, Windows `win32/x64`.
Profile: a custom profile created with `--from-default-profile web`, so the bundle
list is `[@deepseek-ai/dsh-base, @deepseek-ai/dsh-web-app, dsh-ctl]`.

---

## 1. Only `web` is a long-running surface

Read from the shipped `dsh` CLI README and `dsh-acp-app` package documentation:

> The startup provider binds stdin EOF to the launcher's bounded successful shutdown.
> ACP connection close, SIGINT, and SIGTERM drain the bridge-owned agents and the
> root profile tree before exit.

Consequence: ACP and SDK are **remote controls**, not daemons. A dropped SSH session
ends the agent. `headless` runs exactly one task. Only `web` keeps sessions warm.

## 2. `dsh web` prints its launch token non-interactively

```
$ dsh web --port 17399 --no-open
dsh web: http://127.0.0.1:17399/?token=<32-byte-launch-token>
```

(The token is minted fresh per process and is redacted here.)

Useful, but not the path this plugin takes — see next.

## 3. The `/api` surface is fenced; plugin routes are not

| Request | Result |
|---|---|
| `GET /` (no cookie) | `401` |
| `GET /?token=…` | `303` + `set-cookie: dsh-auth-…` (`HttpOnly`, `SameSite=Strict`, 30 days) |
| `GET /api` (no cookie) | `401` |
| `GET /` with a forged `Host` | `401` |
| **`GET /ctl/probe` (bundle plugin route, no cookie)** | **`200 OK`** |
| `GET /ctl/nope` | `404` |

This is the load-bearing finding: a bundle plugin's `ctx.webServer.register()` route
sits outside the launch-token / trust-fence path, so a plain script can call it.

## 4. `dsh plugin add` writes the bundle list for you

After `dsh plugin --profile ctl-verify add link:…`, the profile's `package.json`
contained both the dependency and the bundle row:

```json
{
  "dependencies": { "dsh-ctl": "link:…" },
  "dsh": { "profile": { "bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "dsh-ctl"] } }
}
```

No manual editing required.

## 5. The runtime session shape differs from the declarations

The declarations describe `{ id, title, displayTitle, completed, origin, parentId }`.
The live object actually carried:

```
itemKeys: ["sessionId", "updatedAt", "running", "blank", "cwd", "projections"]
projections.keys: ["asOfSeq", "values"]
projections.values.keys: ["title", "goal", "tokenUsage", "contextPressure", …,
                          "agentPreset", "modelSelection", "sessionListMetadata", "imageLimits"]
```

`id` and `displayTitle` were `undefined` at runtime. The plugin therefore reads
`sessionId` → `id`, and `projections.values.title` → `title` → `displayTitle`.

## 6. Message text lives at two different paths

Discovered with `/ctl/debug/shape`, not from documentation:

```
user/message       event.data.content[0].text
assistant/message  event.data.message.content[0].text
```

Assistant records additionally carry `event.data.message.source.{provider,model}` and
`event.data.usage.{inputTokens,outputTokens,totalTokens,cacheReadTokens}`.

## 7. End-to-end run (real model call)

```
POST /ctl/create   {"cwd": "<temp>"}                     -> 200 {"sessionId":"session-1ad7fa71-…"}
POST /ctl/prompt   {"sessionId":"…","text":"Reply with exactly: PONG"}
                                                          -> 200 {"accepted":true}
GET  /ctl/sessions?running=1  (polled every 300 ms)       -> running=1 at t=300 ms
GET  /ctl/tail?sessionId=…                                -> cursor=19, records=20
```

Projected transcript:

```
seq  type               role       model           tokens  text
 8   user/message       user       -               -       Reply with exactly: PONG
17   assistant/message  assistant  deepseek-flash  20366   PONG
```

The turn settled and `running` returned to `0`.

## 8. Remaining endpoints

```
POST /ctl/rename  {"sessionId":"…","title":"dsh-ctl smoke test"}  -> {"renamed":true,"value":"dsh-ctl smoke test"}
GET  /ctl/session?id=…                                            -> title reflects the rename
POST /ctl/cancel  {"sessionId":"…"}                               -> {"accepted":true}
GET  /ctl/prompt                                   -> 405
GET  /ctl/session?id=nope                          -> 404
GET  /ctl/tail                                     -> 400
```

---

## 9. Controlling a session that is already running

A deliberately slow turn was created (a real `Start-Sleep` tool call) so there was
a ~25 s window to work inside, and every observation below was taken while
`running` was `true`.

### 9.1 State is readable while the turn is in flight

```
GET /ctl/sessions?running=1        -> running=1
GET /ctl/session?id=…              -> { "running": true, … }
GET /ctl/inspect?id=…              -> keys: [meta, inheritedEventCount, events]
GET /ctl/control?ms=3000           -> per-session queue + stats
```

`inspect` returned the durable header without activating the agent, including
`meta.id`, `meta.cwd`, `meta.agentPreset` and the event prefix.

### 9.2 `mode: "queue"` really queues

```
POST /ctl/prompt {"mode":"queue","text":"QUEUE-MARKER …"}
  -> {"accepted":true}

GET /ctl/control
  value.queues.<sessionId>.0.placement = "queued"
  value.queues.<sessionId>.0.message.content.0.text = "QUEUE-MARKER …"
```

In the durable log the message appears only **after** the current `turn/end`, as
part of the following turn.

### 9.3 `mode: "steer"` really steers

```
POST /ctl/prompt {"mode":"steer","text":"STEER-MARKER …"}
  -> {"accepted":true}

GET /ctl/control
  value.queues.<sessionId>.1.placement = "steering"
```

The durable log proves it landed inside the running turn rather than waiting:

```
seq 17  assistant/message  "I'll run that exact command now."
seq 25  user/message       "STEER-MARKER: stop counting and reply STEER-OK immediately"
seq 27  assistant/message  "DONE"
seq 29  turn/end
seq 30  turn/start
seq 33  user/message       "QUEUED-MARKER: after you finish, also reply QUEUE-OK"
seq 35  assistant/message  "QUEUE-OK"
```

The steer message sits between the assistant step and `turn/end`; the queued
message sits after a `turn/end`, inside the next turn. That is the difference the
UI's steer button makes, reproduced over the API.

The final projection from `/ctl/control`:

```
placement  text
---------  ----
queued     QUEUE-DEMO wait your turn
steering   STEER-DEMO act now

stats: {"turns":5,"steps":8,"llmMs":19847,"toolMs":49966,"ttftMs":8662,"decodeTokens":2032}
```

### 9.4 Note for anyone re-testing this

Neither injected message is written to the durable log at acceptance time — they
are live in-memory placements until the turn claims them. Watching `tail` to
verify an injection will show nothing; watch `/ctl/control` instead. This cost one
dead end during verification.

---

## 10. Second deployment: macOS arm64, DSH 0.2.1-rc.5

Same plugin, different OS and a newer DSH. Three deployment failures had to be
fixed first; they are written up in [MACOS.md](MACOS.md). Once the server boots:

### 10.1 The CLI reads the desktop app's sessions

`GET /ctl/sessions` returned **all seven** sessions the Electron desktop app had
created on that machine, with their real titles and working directories — no
migration, no export, no import:

```
session-AAAA…  "Research agent 飞书上线"        cordis  <home>/deepseek-harness/default-workspace
session-BBBB…  "项目 agent 过度到 消费 agent"   cordis  <volume>/zyc_projects/panel-deck
session-CCCC…  "Check IP address online"        cordis  <home>/deepseek-harness/default-workspace
…
```

This settles the original question: the CLI and the desktop app share
`$DSH_HOME/sessions`, and a plugin on the CLI side can enumerate what the desktop
side produced.

### 10.2 Session control still works

```
POST /ctl/create  {"cwd":"…"}  -> {"sessionId":"session-XXXXXXXX-…","agentPreset":"standard"}
POST /ctl/prompt  {…}          -> {"accepted":true}
GET  /ctl/sessions?limit=1     -> title "Use the pwsh tool to", running flag, cwd
GET  /ctl/inspect?id=…         -> meta.version 4, meta.cwd, events[…]
```

`session/list` still carries `sessionId` and `projections.values.title`, so the
defensive field readers needed no change.

### 10.3 Regression: the control baseline lost `queues`

| | 0.1.5-rc.2 | 0.2.1-rc.5 |
|---|---|---|
| baseline own keys | `projections`, `queues` | **`projections` only** |
| queue `placement` | readable | **not published** |
| `projections.values` | title, agentPreset, sessionStats | adds `tokenUsage`, `contextPressure`, `contextBreakdown` |

`POST /ctl/prompt` with `mode: "steer"` is still accepted, but `/ctl/control`
cannot show where the message landed. Documented as a known limitation rather than
guessed at; `/ctl/control?raw=1` prints the current key list so the next version
can be re-checked in one call.

### 10.4 Version-specific shape confirmed again

`meta.version` was 3 on Windows `0.1.5-rc.2` and 4 here, matching the changed
on-disk layout (`session.v4.jsonl.zstd` under `<workspace>/<session-uuid>/` on
macOS versus a flatter tree on the older Windows build). This is why the plugin
never hardcodes a single field name.

---

## Known unverified

- **Queue placement on 0.2.1-rc.5.** Accepted but not observable: the host no longer
  publishes `queues` in the control baseline. Needs a different signal (the durable
  `agent/inbox/spliced` record may carry it) before queue-versus-steer can be
  demonstrated there.
- **Schedule delivery with an idle session.** `dsh-schedule` documents that delivery
  requires a live root agent and that closed sessions keep reminders overdue.
  Whether an *open but idle* session in a `web` process still qualifies was not
  measured; validate before relying on it.
- **Non-loopback rejection.** The `403` guard is code-reviewed but was only exercised
  on a loopback-only deployment, where it cannot trigger.
