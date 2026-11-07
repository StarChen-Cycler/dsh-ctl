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
session-AAAA…  "<desktop session 1>"   cordis  <home>/deepseek-harness/default-workspace
session-BBBB…  "<desktop session 2>"   cordis  <volume>/<projects>/<one project>
session-CCCC…  "<desktop session 3>"   cordis  <home>/deepseek-harness/default-workspace
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

## 11. Third deployment: Windows 10 22H2, DSH 0.2.1-rc.5

Clean Windows 10 (build 19045), PowerShell 5.1, Node v24.22.1, npm 11.19.1, no
prior dsh CLI. Installed with npm:

```
npm install -g pnpm @deepseek-ai/dsh@0.2.1-rc.5
dsh --version  ->  0.2.1-rc.5
```

### 11.1 No NODE_PATH workaround was needed

The macOS deployment requires a `NODE_PATH` shim because pnpm's isolated global
layout hides the platform native package. npm's global layout is flat, so on
Windows the addon resolved with no shim at all — the server booted on the first
attempt with only `fleet-run.ps1`.

### 11.2 The existing session store is visible

`GET /ctl/sessions` returned the 11 sessions already on the machine, with their
titles and workspace paths:

```
total=11 running=0
  session-…  [idle]  <session 1>    <home>\deepseek-harness\default-workspace
  session-…  [idle]  <session 2>    …
  session-…  [idle]  <session 3>    …
  session-…  [idle]  <session 4>    …
  session-…  [idle]  <session 5>    …
  session-…  [idle]  <session 6>    …
```

### 11.3 A process started over SSH does not survive the session

This is the Windows-specific finding, and it is not obvious from the macOS
experience:

```
starting: ...\fleet-run.ps1
launcher pid=5376
listening after 3s
{"ok":true,...,"pid":8552,...}      <- healthy while the SSH session is open
# ssh session closes
no response from http://127.0.0.1:17390/ctl/health
```

`Start-Process -WindowStyle Hidden` does not help: Windows OpenSSH tears down the
session's process tree. Persistence has to go through Task Scheduler.

### 11.4 Task Scheduler + supervisor loop works

`win-install-scheduledtask.ps1` registered task `DSH-Fleet` and started it:

```
State : Running
health: {"ok":true,...,"pid":13236,"platform":"win32","node":"v24.22.1"}
```

Then both behaviours were tested from a **fresh** SSH session:

| test | result |
|---|---|
| survived the session that started it | ✅ the same pid was still serving after reconnecting (`uptime` was only seconds, so this shows survival of the session, not uptime) |
| crash recovery | ✅ a new pid within ~10 s |

> Note for re-testing: that run killed the server by image name (`taskkill /IM
> node.exe /F`), which is unsafe on a machine running other Node services and
> proves nothing on its own. Kill the pid `/ctl/health` reports instead — see
> [WINDOWS.md](WINDOWS.md), "Verifying it actually self-heals".

### 11.5 A logon trigger still needs a login

```
AutoAdminLogon = 0
```

Unlike the macOS target (auto-login on), this machine does not sign itself in. An
at-logon task therefore will **not** start after an unattended reboot until someone
logs in. Documented rather than papered over; see
[docs/WINDOWS.md](WINDOWS.md) for the alternatives.

### 11.6 Quoting: a cmd remote shell mangles URLs

`ssh host 'curl -s http://127.0.0.1:17390/ctl/sessions?limit=5'` returns nothing —
no error, empty output — because `cmd.exe` consumes the `?`. Every probe was moved
into `win-verify-fleet.ps1`, which is why that script exists.

---

## 12. `updatedAt` is not a liveness signal (0.1.1)

A session on the macOS host had been working autonomously for ~24 hours. Its
listing entry showed `running: true` but `updatedAt` fixed at the previous day, so
it read as a stalled turn. It was not:

```
last event  tool/call  event.time = 1794031169401
wall clock            now          = 1794031171832     (~2 s apart)
tool/call   name = subagent   arguments {"description":"Audit v2 consistency and claims"}
stats.steps  745 -> 746 over 25 s
```

### 12.1 The cause, from the host source

`@deepseek-ai/dsh-api-session-controller@0.2.1-rc.5`, `lib/types/index.js`:

```js
ctx.on('session/event', (session, event) => {
    ...
    if (event.type !== 'user/message' || event.data.source.kind !== 'user')
        return;
    ctx.emit('api-session/activity', session.id, event.time);
});
```

`api-session/activity` is emitted **only for user-typed messages**. Assistant
messages, tool calls and steps never raise it. So the value advances when a human
(or an injected prompt) speaks, and stays frozen through any amount of autonomous
work. Confirmed by comparison: the session's newest `user/message` had
`event.time = 1793945031830`, matching the reported `updatedAt` of `…832`.

### 12.2 A second candidate that also failed

`projections[<id>].asOfSeq` looked like a usable heartbeat. It is not:

```
asOfSeq 6196  ->  6196   (20 s later, while stats.steps advanced)
```

It is a durable flush cursor, not an in-memory state counter.

### 12.3 What changed

| change | why |
|---|---|
| `/ctl/sessions`, `/ctl/session`: `updatedAt` → **`lastUserInputAt`** | the old name invited exactly the misreading above |
| `/ctl/tail` records gain **`time`** | the only trustworthy activity timestamp; it was being dropped, forcing callers into `/ctl/debug/shape` |
| `/ctl/control` gains **`lastEventSeq`** | exposes the flush cursor, documented as "changing value proves progress; unchanged proves nothing" |

Liveness now has three usable signals: `running`, the `time` of the newest tail
record, and `stats.steps`.

---

## 13. Windows autostart: hidden, least-privilege, actually self-healing (0.1.1)

Registering task `DSH-Fleet` at logon was not enough to get a service that
survives a crash. Three defects surfaced while proving it — plus one recovery
route worth writing down — all on the same deployment, and each was only visible
by testing behaviour rather than reading state.

### 13.1 A supervisor that waits on its child cannot supervise

The original loop ran the launcher synchronously:

```powershell
& powershell.exe -File fleet-run.ps1 *>> $log
```

That ties the supervisor's progress to one child's lifetime: it cannot start a
replacement until the call returns, and if the child wedges instead of exiting the
call never returns at all. What was observed after killing the server process was
the service staying down while `Get-Process` still listed a supervisor. That is
consistent with a call that had not returned, but the run was also entangled with
the elevation problems in 13.3, so the mechanism was never isolated cleanly — the
fix is justified by the shape of the loop, not by a proven root cause.

Replaced with a health probe: the outer loop asks `/ctl/health` every 10 s and
starts a launcher when nothing answers. It never waits on a child, so no child's
lifetime can hold it up.

Worth knowing while reading those logs: during `dsh` boot the HTTP server is
already listening before the plugin's routes are registered, so `/ctl/health`
answers **404** for a moment. The supervisor now logs the probe failure reason
(once per distinct message, not once per probe), which is how that was found.

Measured recovery after `Stop-Process` on the serving pid, with the probe loop in
place: **10 s**, **19 s**, **23 s** and **38 s** across runs, i.e. one probe
interval plus dsh's boot time. The pessimistic bound is
`StartupGraceSeconds + RestartDelaySeconds` (70 s) and only applies when a launcher
never becomes healthy at all.

The grace loop must break on the first healthy probe. An earlier version recorded
"up" but kept looping until the deadline, which delayed both that log line and the
next crash check by up to 60 s — observed as `16:13:57 … starting launcher` →
`16:14:59 … control plane is up`. After the fix the same sequence takes 11 s
(`16:16:01` → `16:16:12`).

### 13.2 The task put a console window on the desktop

The registered action had no window-style flag, so an elevated
`Administrator: powershell.exe` window appeared at logon and stayed for the life
of the task. Closing it kills the supervisor, so it cannot simply be dismissed.

Two changes, deliberately redundant:

- task action gains `-WindowStyle Hidden -NonInteractive -NoLogo`
- the supervisor hides its own console via
  `ShowWindow(GetConsoleWindow(), SW_HIDE)` at startup

The second is what actually fixes an existing installation: the action flag only
applies on the next registration, whereas the script-level hide takes effect
immediately. Verified by starting the task through its *unmodified* action and
counting visible PowerShell windows: **0**.

### 13.3 `-RunLevel Highest` made the fleet unmanageable

`dsh web` needs no administrator rights, but the task was registered as highest,
so the whole fleet ran elevated. The damage is to verification and operability:

| symptom | cause |
|---|---|
| `Stop-Process` silently does nothing, so a recovery test "fails" | the victim is elevated; the call is denied |
| a `CommandLine` filter finds no node processes at all | the command line of an elevated process is unreadable to a normal caller |
| `/ctl/health` appears to report a stale pid | nothing was stale — the process was simply unkillable |

All three false diagnoses were produced while the service was healthy. Fixed by
the `-Limited` switch, now the recommended registration in
[WINDOWS.md](WINDOWS.md) (the script still defaults to highest when run from an
elevated shell, so a profile that genuinely needs elevation is not broken
silently). After re-registering: `RunLevel=Limited`, `UserId` = the interactive
user, and the same session can list, kill and restart the fleet.

### 13.4 Recovery from a mis-registered task needs no elevation

`schtasks /end /tn DSH-Fleet` terminates the task's process tree as the owning
user. That is what cleared the unusable elevated instance without an
administrator prompt.

### 13.5 Final verified state

```
task       DSH-Fleet   state=Running   RunLevel=Limited   trigger=AtLogOn
action     ... -WindowStyle Hidden ... -File win-supervise-fleet.ps1
windows    visible PowerShell windows = 0
fleet      /ctl/health ok, plugin 0.1.1
recovery   kill serving pid -> new pid in 10 s / 38 s (two runs)
```

---

## 14. Schedule routes (0.1.2)

`/ctl/schedules`, `/ctl/schedule`, `/ctl/schedule/update` and
`/ctl/schedule/delete` drive the host's `ctx.schedule` service, the same one the
model-facing `schedule_create` tool uses.

### 14.1 The service is optional, and Cordis enforces it

Accessing `ctx.schedule` on a plugin that does not inject `schedule` throws at
request time: `cannot get property "schedule" without inject`. Adding it to
`inject` is the wrong fix — `inject` is a load requirement, so the whole plugin
would stop loading on any host whose profile does not mount the service.

`ctx.get('schedule')` answers `undefined` instead, which the routes turn into a
`501` carrying the exact `cordis.patch.yml` rows needed. Verified on a host with
the service mounted (all routes answer) and reasoned from the runtime error for
the unmounted case.

### 14.2 Mounting is a composition edit, not a plugin install

`dsh plugin --profile <p> add @deepseek-ai/dsh-schedule` installs the package and
then warns:

```
@deepseek-ai/dsh-schedule declares no dsh.bundle — installed as a plain
dependency, not a profile layer
```

So it never reaches `dsh.profile.bundles`. It has to be inserted in the profile's
`cordis.patch.yml`. On 0.2.x the model-facing tools live in a *second* package,
`@deepseek-ai/dsh-tool-schedule`; the older 0.1.5 line registered them from
`dsh-schedule` itself, which is why the `web` profile mounts only one row.

Verification gate: `dsh fleet --dump-config` must exit 0 and show both
`id: schedule` and `id: tool-schedule`. A bad patch fails here instead of during
a restart.

Restarting needs care on Windows: `schtasks /end` stops the supervisor but not the
already-detached `node`, so the old process keeps serving the port with the old
composition. Kill the pid `/ctl/health` reports instead.

### 14.3 Endpoints, exercised against a live host

| call | result |
|---|---|
| `GET /ctl/schedules?all=1` | `scope=host count=1`, the existing daily 20:00 reminder with its binding |
| `GET /ctl/schedules?sessionId=…` | `count=1`, same task |
| `POST /ctl/schedule` `after_seconds=86400` | `created=true`, `kind=after`, `state=scheduled` |
| `POST /ctl/schedule/update` (rename + `kind=every`, 2 days) | `updated=true`, new title, `kind=every` |
| `POST /ctl/schedule/delete` | `deleted=true` |
| `GET` again | back to `count=1` — only the real reminder, the test row is gone |
| `POST /ctl/schedule` with no timing selector | `400`, `selectors` list and examples returned |
| `POST /ctl/schedule/delete` with an unknown id | `delete` returned `deleted=false code=schedule_not_found` |

### 14.4 Two authoring hazards that cost time here

**UTF-8 BOM.** Rewriting `package.json` with PowerShell 5.1's
`Set-Content -Encoding UTF8` prefixes a BOM. The loader then reports

```
skipping profile bundle "dsh-ctl": SyntaxError: Unexpected token '锘?…
```

i.e. the plugin silently does not load, `/ctl` answers 404, and the supervisor
keeps restarting a server that looks broken. Write files as UTF-8 **without** BOM
(`[IO.File]::WriteAllText(path, text, UTF8Encoding($false))`).

**Silent mojibake from `Get-Content -Raw`.** The same round trip decodes non-ASCII
as the ANSI code page and re-encodes as UTF-8, turning Chinese comments into
`鈥?`. Both were repaired by restoring from git and re-applying edits with a
BOM-aware editor rather than text pipelines.

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
