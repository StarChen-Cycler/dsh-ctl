# dsh-ctl

A loopback HTTP control plane for a long-running [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) process.

It turns a headless `dsh web` server into something you can drive from a script over SSH:
list the sessions that exist, see which ones are **actually running right now**, create one,
inject a prompt, watch it work, read back the exchange, cancel it, rename it.

```
ssh <host> ctl sessions --running
ssh <host> ctl prompt <session-id> "run the migration and report back"
ssh <host> ctl tail   <session-id>
```

---

## The problem this solves

DeepSeek Harness ships five profiles. Only one of them is a server that stays alive:

| profile | lifecycle | can host a persistent session? |
|---|---|---|
| `desktop` | Electron shell | yes, but talks to its host over **IPC**, invisible to any other process |
| `headless` | one task, then exits | no |
| `acp` | stdio JSON-RPC, **dies on stdin EOF** | no — your SSH disconnect kills the agent |
| `sdk` | stdio JSON-RPC, same | no |
| **`web`** | **HTTP server, runs until killed** | **yes** |

So `dsh web` is the only surface that can keep a session warm while you are not
connected. But its own `/api` surface is gated behind a browser launch token,
a signed cookie, and a `Host`/`Origin` trust fence — painful to drive from a shell.

A DSH bundle plugin, however, can register **first-class HTTP routes** through
`ctx.webServer`, and those routes sit **outside** that fence. This plugin uses that
seam to expose a small, boring JSON API on loopback. Pair it with SSH and you get a
remote agent you can control without exposing a single port to the network.

---

## Requirements

- DSH `0.1.5-rc.2` or newer (`dsh --version`). Verified against `0.1.5-rc.2`.
- A profile built on **`@deepseek-ai/dsh-web-app`** (the `web` template, or any
  custom profile derived from it).
- Node.js 18+ (DSH ships its own runtime; you do not need a system Node).

## Install

```sh
# create a dedicated profile from the shipped web template
dsh --profile fleet --from-default-profile web

# install this plugin (from a path, a tarball, or npm once published)
dsh plugin --profile fleet add link:/absolute/path/to/dsh-ctl

# it is written into the profile automatically:
#   dsh.profile.bundles = [dsh-base, dsh-web-app, dsh-ctl]
```

`dsh plugin` forwards its arguments to `pnpm` inside the profile directory and
records the bundle for you — no manual `package.json` editing required.

## Run

```sh
dsh --profile fleet --port 17390 --no-open
```

`--no-open` suppresses the browser launch. The port is yours to choose; keep the
bind address at the default loopback. Add `--patch` overlays for anything else you
want in the same process (feishu listeners, schedules, MCP servers, …).

To keep it alive, use your platform's service manager — `launchd` on macOS,
`systemd` on Linux, a scheduled task or NSSM on Windows. A minimal macOS example:

```xml
<!-- ~/Library/LaunchAgents/dev.dsh.fleet.plist -->
<key>ProgramArguments</key>
<array>
  <string>/bin/sh</string>
  <string>-lc</string>
  <string>dsh --profile fleet --port 17390 --no-open</string>
</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
```

## Use it

Everything below runs from any machine that can SSH to the host. No tunnel, no port
forward, no credentials beyond your SSH key.

```sh
# health
ssh <host> ctl health

# every session, newest first
ssh <host> ctl sessions --limit 20

# only the ones executing right now
ssh <host> ctl sessions --running

# create a session rooted at a workspace
ssh <host> ctl create --cwd /srv/work

# drive it
ssh <host> ctl prompt <session-id> "summarise the failing tests"

# read back what happened (history snapshot + up to N seconds of live frames)
ssh <host> ctl tail <session-id>

# stop the current turn
ssh <host> ctl cancel <session-id>
```

The `ctl` helper in [`scripts/`](scripts/) wraps `curl` so you do not have to quote
JSON through two shells. Copy it onto the host, or call it locally with `--host`.

## Driving a session that is already running

A session in the middle of a turn is not locked — you can still read it and you
still have both ways to inject work into it.

```sh
# 1. is it running, and what is queued on it?
ssh <host> ctl control

# 2. read its durable state without waking the agent
ssh <host> ctl inspect <session-id>

# 3a. queue: wait for the current turn to finish
ssh <host> ctl prompt <session-id> "then also update the changelog" --mode queue

# 3b. steer: splice into the turn already running
ssh <host> ctl prompt <session-id> "stop, use the staging branch instead" --mode steer
```

| | `--mode queue` | `--mode steer` |
|---|---|---|
| response | `accepted: true` | `accepted: true` |
| queue `placement` | `queued` | `steering` |
| lands in | the **next** turn | the **current** turn |
| visible in `tail` before it lands | no | no |
| visible in `control` | yes | yes |

Both return before delivery, and neither writes to the durable log until the turn
claims the message — so `control` (live state) is where you watch them, not `tail`.

### Reading a running session

| want | endpoint | what you get |
|---|---|---|
| is it running | `GET /ctl/sessions?running=1` | live execution flag |
| live queue + stats | `GET /ctl/control` | per-item `placement`, turns/steps/llmMs/toolMs/ttftMs/decodeTokens |
| durable state, no wake | `GET /ctl/inspect?id=` | `meta` header plus the persisted event prefix |
| the actual messages | `GET /ctl/tail?sessionId=` | history snapshot, then live frames |

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/ctl` | route index |
| GET | `/ctl/health` | version, port, pid, platform, node, uptime, whether a secret is required |
| GET | `/ctl/sessions?limit=&running=1` | sessions with `sessionId`, `title`, `cwd`, `agentPreset`, `model`, **`running`**, `blank`, `lastUserInputAt` |
| GET | `/ctl/session?id=` | one session |
| GET | `/ctl/control?ms=&raw=1` | live queue (`placement`) and running stats |
| GET | `/ctl/inspect?id=` | durable header + event prefix without activating the agent |
| GET | `/ctl/tail?sessionId=&frames=&ms=` | history snapshot plus live frames, normalised |
| POST | `/ctl/create` | `{ cwd?, sessionId?, agentPreset? }` |
| POST | `/ctl/prompt` | `{ sessionId, text, mode?, requestId? }` — `mode`: `queue`/`steer` |
| POST | `/ctl/cancel` | `{ sessionId }` |
| POST | `/ctl/rename` | `{ sessionId, title }` |
| GET | `/ctl/schedules?sessionId=` | durable reminders bound to one session; `?all=1` lists every reminder on the host with its binding |
| POST | `/ctl/schedule` | `{ sessionId, title, prompt, daily\|cron\|weekly\|every_seconds\|at\|after_seconds }` — exactly one timing selector |
| POST | `/ctl/schedule/update` | `{ sessionId, id, title?, prompt?, change? }` |
| POST | `/ctl/schedule/delete` | `{ sessionId, id }` |
| GET | `/ctl/debug/shape?sessionId=&type=` | read-only schema introspection (see below) |

Full request/response shapes: [docs/API.md](docs/API.md).

### Why `running` matters

`GET /ctl/sessions?running=1` is the answer to "what is the agent doing *now*".
It reflects the owning process's live state, not the on-disk history, so it is the
one thing you cannot get by reading session archives. Verified to flip `true` within
~300 ms of a prompt and back to `false` when the turn settles.

### How to tell whether a session is alive

**Do not use a timestamp for this.** The listing carries `lastUserInputAt`, and the
name says exactly what it is: the host raises its `api-session/activity` signal —
the source of that field — **only for `user/message` events whose `source.kind` is
`user`** (`dsh-api-session-controller`, `lib/types/index.js`). Assistant messages,
tool calls and steps never advance it. An agent working autonomously for a day will
keep that timestamp frozen the whole time.

Before 0.1.1 this field was exported as `updatedAt`, which reads like a liveness
signal and misled the maintainer into diagnosing a healthy 24-hour autonomous run as
a stalled session. It is renamed.

Use instead:

| signal | endpoint | meaning |
|---|---|---|
| `running` | `/ctl/sessions` | host says the agent is executing |
| `time` of the newest record | `/ctl/tail` | when the log last actually moved |
| `stats.steps` | `/ctl/control` | monotonic in-memory step counter |

`/ctl/tail` records now carry `time` (0.1.1) so the second row is one call.
`/ctl/control` also reports `lastEventSeq`, but it is a **flush cursor**: it can sit
still for seconds while the agent is working, so a changing value proves progress
and an unchanged value proves nothing.

## Schedules (durable reminders)

`/ctl/schedules` and friends drive the host's `ctx.schedule` service. This is the
same mechanism the model-facing `schedule_create` tool uses: a reminder is bound
to one session and, when due, is injected into that session as a user message —
which wakes an idle session.

```sh
# everything scheduled on the host, with the session each task is bound to
ssh <host> 'curl -s http://127.0.0.1:17390/ctl/schedules?all=1'

# one session's tasks
ssh <host> 'curl -s "http://127.0.0.1:17390/ctl/schedules?sessionId=<id>"'

# a daily 20:00 reminder (time is HH:mm:ss — "20:00" is rejected by the host)
ssh <host> 'curl -s -X POST http://127.0.0.1:17390/ctl/schedule \
  -H "content-type: application/json" \
  -d "{\"sessionId\":\"<id>\",\"title\":\"nightly digest\",\"prompt\":\"run the digest\",\"daily\":{\"time\":\"20:00:00\",\"time_zone\":\"Asia/Shanghai\"}}"'
```

The `scripts/ctl.sh` / `scripts/ctl.ps1` helpers cover the session routes only, not
schedule — use `curl` (or any HTTP client) for these.

Timing selectors are mutually exclusive: `daily {time, time_zone}`,
`cron {expression, time_zone}`, `weekly {time, time_zone, weekdays}`,
`every_seconds`, `after_seconds`, or `at`. `time` is `HH:mm:ss` with optional
1–3 fractional digits; `"20:00"` is rejected.

**These routes return `501` unless the profile mounts the service.** The packages
are ordinary dependencies, not bundles, so `dsh plugin add` cannot wire them in —
it even warns "declares no dsh.bundle". Insert them in the profile's
`cordis.patch.yml` instead:

```yaml
- insert:
    - id: schedule
      name: '@deepseek-ai/dsh-schedule'
    - id: schedule-tools          # model-facing tools, separate package on 0.2.x
      name: '@deepseek-ai/dsh-tool-schedule'
```

Restart afterwards: an already-open session keeps the tool set it was built with.
The service enforces a 300 s minimum interval, and a task bound to a session owned
by a delegated subagent is rejected (`subagent_session`) because delivery could
never reach it.

## Security model

- **Loopback only.** Requests whose socket address is not `127.0.0.1` / `::1` are
  refused with `403`, independently of how the server was started.
- **No TLS, no user accounts.** `dsh web` itself has no TLS; these routes rely on
  SSH for transport security and authentication.
- **Never bind a public interface.** `dsh web --host 0.0.0.0` is unsupported
  upstream, and these control routes are deliberately outside the `/api` fence.
  Reach them through SSH (`ssh <host> ctl …`) or an SSH tunnel.
- **Optional shared secret.** Set `config.secret` in the profile patch to require
  `Authorization: Bearer <secret>` or `X-Dsh-Ctl-Secret: <secret>` on every request.

```yaml
- insert:
    - id: dsh-ctl
      name: dsh-ctl
      config:
        secret: change-me
```

## Cross-version robustness

The published TypeScript declarations and the runtime objects disagree in places.
On `0.1.5-rc.2` the declarations advertise `id`, `displayTitle` and `completed`,
while the runtime summary actually carries:

```
{ sessionId, updatedAt, running, blank, cwd, projections: { values: { title, agentPreset, … } } }
```

and message parts live at **different paths** per record type:

```
user/message       -> event.data.content[]
assistant/message  -> event.data.message.content[]
```

This plugin reads the shapes it knows about defensively — every field access is
guarded, and a missing field comes back as `null` rather than throwing. It does not
guess at alternative names: when something does not line up, it exposes
`/ctl/debug/shape` so you can see the real key paths on your build instead of
guessing. That is how the paths above were found.

## Compatibility

| DSH version | Platform | Status |
|---|---|---|
| `0.1.5-rc.2` | Windows 10/11 | verified — every endpoint exercised against a live host (see [docs/VERIFICATION.md](docs/VERIFICATION.md)) |
| `0.2.1-rc.5` | macOS arm64 | verified — sessions, create, prompt, inspect, tail |
| `0.2.1-rc.5` | Windows 10 22H2 | verified — sessions, control plane, scheduled-task persistence |

That table is the **DSH** version, not the plugin's own version (`0.1.1`). After any
DSH upgrade, re-run `/ctl/debug/shape` and `/ctl/control?raw=1` before trusting a
field.

## Limitations

- **Queue visibility is version-dependent.** `GET /ctl/control` reports each
  pending item's `placement` (`queued` vs `steering`) on `0.1.5-rc.2`. On
  `0.2.1-rc.5` the host stopped publishing that field, so the queue comes back
  empty even though `mode: "steer"` is still accepted. Use
  `/ctl/control?raw=1` and `/ctl/debug/shape` to re-confirm on any new version.
- Schedules and other live-owner features only fire while the process holds a live
  agent for that session; a closed session keeps its reminders overdue until resumed.
  Keep the daemon running if you depend on them.
- `tail` is a bounded read: it opens a follow stream, collects the opening snapshot,
  waits up to `ms` for new frames, then closes. It is not a persistent subscription.
- Session deletion and forking are not exposed.
- The plugin does not manage MCP servers or other plugins; it only controls sessions.
- Sessions owned by subagent routing cannot be prompted; `POST /ctl/prompt` rejects
  them with `is owned by subagent routing`. Target root sessions.

## Platform notes

Both platforms need the same two things — a Node >= 22 and a running `dsh web` — but
the wiring differs, so each has its own launcher and persistence installer.

| | macOS | Windows |
|---|---|---|
| Foreground launcher | [`fleet-run.sh`](scripts/fleet-run.sh) | [`fleet-run.ps1`](scripts/fleet-run.ps1) |
| Detached smoke test | [`mac-start-fleet.sh`](scripts/mac-start-fleet.sh) | [`win-start-fleet.ps1`](scripts/win-start-fleet.ps1) |
| Persistence | [`mac-install-launchd.sh`](scripts/mac-install-launchd.sh) (LaunchAgent) | [`win-install-scheduledtask.ps1`](scripts/win-install-scheduledtask.ps1) + [`win-supervise-fleet.ps1`](scripts/win-supervise-fleet.ps1) |
| Keep-alive | built in (`KeepAlive`) | supplied by the supervisor loop |
| Verify | `curl` against loopback | [`win-verify-fleet.ps1`](scripts/win-verify-fleet.ps1) |
| Guide | [docs/MACOS.md](docs/MACOS.md) | [docs/WINDOWS.md](docs/WINDOWS.md) |

### macOS specifics

Three deployment traps, all covered in [docs/MACOS.md](docs/MACOS.md):

1. `dsh plugin` needs an executable literally named `pnpm` — see
   [`pnpm-shim.sh`](scripts/pnpm-shim.sh).
2. The vendor-bundled Node is hardened-runtime signed and refuses npm's
   ad-hoc-signed native addon (`different Team IDs`). Use a normal Node.
3. A pnpm-global install hides the platform package behind symlink realpaths —
   [`mac-link-native-binding.sh`](scripts/mac-link-native-binding.sh) builds a
   `NODE_PATH` shim.

### Windows specifics

1. **A process started over SSH dies when that session closes.** Task Scheduler,
   not `nohup`, is the answer. This is the one Windows behaviour that catches
   everyone.
2. Task Scheduler has no `KeepAlive`; the supervisor loop supplies it — it probes
   `/ctl/health` rather than waiting on a child process, so a wedged server cannot
   stall it.
3. Register the task with `-Limited`. Running the fleet elevated buys nothing and
   makes it unmanageable from the same user's normal tooling — see
   [docs/WINDOWS.md](docs/WINDOWS.md) 4.3 and 4.4.
4. The task action and the supervisor both hide the console window. Without that,
   an `Administrator: powershell.exe` window sits on the desktop for the life of
   the task and cannot be closed without killing the supervisor.
5. Install with **npm**, not pnpm: the flat global layout removes the need for the
   `NODE_PATH` shim entirely.
6. The remote shell is `cmd.exe`, which eats `?` and `&` in URLs — always drive the
   control plane from a script, never an inline `curl`.

Details: [docs/WINDOWS.md](docs/WINDOWS.md).

## Agent skill

[`skills/dsh-ctl/SKILL.md`](skills/dsh-ctl/SKILL.md) teaches an agent to use this
tool without being told the commands: it covers the loopback/SSH model, how to
survey an unfamiliar machine (process → profile → port → plugin present? → what
supervises it), how to inspect what is running now, and the three judgements that
follow (is it alive, is it stuck, will an injection queue or steer).

The skill deliberately contains **no hostnames, addresses, users or local paths**,
so it can be shared as-is. Which machines exist is the operator's business: it
asks for that at run time, or reads a personal registry file outside the repo.

```sh
# after cloning, point your agent's skill directory at it
cp -r skills/dsh-ctl ~/.agents/skills/          # or ~/.codex/skills/
```

## Enabling SSH on the target

If a machine has no SSH server yet, see [`scripts/`](scripts/) for per-platform
helpers. They are deliberately separate from the plugin: enabling a service needs
elevation, and the plugin must never do that on your behalf.

## License

MIT — see [LICENSE](LICENSE).
