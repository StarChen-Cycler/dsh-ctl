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

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/ctl` | route index |
| GET | `/ctl/health` | version, port, pid, platform, node, uptime, whether a secret is required |
| GET | `/ctl/sessions?limit=&running=1` | sessions with `sessionId`, `title`, `cwd`, `agentPreset`, `model`, **`running`**, `blank`, `updatedAt` |
| GET | `/ctl/session?id=` | one session |
| GET | `/ctl/tail?sessionId=&frames=&ms=` | history snapshot plus live frames, normalised |
| POST | `/ctl/create` | `{ cwd?, sessionId?, agentPreset? }` |
| POST | `/ctl/prompt` | `{ sessionId, text, mode?, requestId? }` |
| POST | `/ctl/cancel` | `{ sessionId }` |
| POST | `/ctl/rename` | `{ sessionId, title }` |
| GET | `/ctl/debug/shape?sessionId=&type=` | read-only schema introspection (see below) |

Full request/response shapes: [docs/API.md](docs/API.md).

### Why `running` matters

`GET /ctl/sessions?running=1` is the answer to "what is the agent doing *now*".
It reflects the owning process's live state, not the on-disk history, so it is the
one thing you cannot get by reading session archives. Verified to flip `true` within
~300 ms of a prompt and back to `false` when the turn settles.

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

This plugin reads every field defensively (old name, new name, then absent) and, when
something still does not line up, exposes `/ctl/debug/shape` so you can see the real
key paths on your build instead of guessing. That is how the paths above were found.

## Compatibility

| DSH version | Status |
|---|---|
| `0.1.5-rc.2` | verified — every endpoint exercised against a live host (see [docs/VERIFICATION.md](docs/VERIFICATION.md)) |
| `0.2.1-rc.5` | target for the second deployment; re-run `/ctl/debug/shape` after upgrading |

## Limitations

- Schedules and other live-owner features only fire while the process holds a live
  agent for that session; a closed session keeps its reminders overdue until resumed.
  Keep the daemon running if you depend on them.
- `tail` is a bounded read: it opens a follow stream, collects the opening snapshot,
  waits up to `ms` for new frames, then closes. It is not a persistent subscription.
- Session deletion and forking are not exposed.
- The plugin does not manage MCP servers or other plugins; it only controls sessions.

## Enabling SSH on the target

If a machine has no SSH server yet, see [`scripts/`](scripts/) for per-platform
helpers. They are deliberately separate from the plugin: enabling a service needs
elevation, and the plugin must never do that on your behalf.

## License

MIT — see [LICENSE](LICENSE).
