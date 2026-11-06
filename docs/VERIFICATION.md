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

## Known unverified

- **0.2.1-rc.5.** The second target machine runs this version. The plugin is written
  defensively and ships `/ctl/debug/shape`, but the field paths above should be
  re-confirmed there after install.
- **Schedule delivery with an idle session.** `dsh-schedule` documents that delivery
  requires a live root agent and that closed sessions keep reminders overdue.
  Whether an *open but idle* session in a `web` process still qualifies was not
  measured; validate before relying on it.
- **Non-loopback rejection.** The `403` guard is code-reviewed but was only exercised
  on a loopback-only deployment, where it cannot trigger.
