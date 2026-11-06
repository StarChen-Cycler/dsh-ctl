# Deploying on macOS

Three things bite on macOS that do not bite on Linux, all of them discovered the
hard way while bringing up the `fleet` profile on an Apple Silicon machine running
macOS 15.1.1 and DSH `0.2.1-rc.5`. Each produces a failure that does not mention
its real cause.

---

## 1. `dsh plugin` needs an executable literally named `pnpm`

The DSH runtime ships pnpm as a JavaScript entry point
(`dependencies/pnpm/bin/pnpm.cjs`), so there is no `pnpm` on `PATH`. `dsh plugin`
shells out to `pnpm` by name and fails with:

```
dsh: pnpm was not found; install pnpm and make it available on PATH.
```

Fix: write a two-line shim into a directory that is on `PATH` (see
[`scripts/pnpm-shim.sh`](../scripts/pnpm-shim.sh)):

```sh
#!/bin/sh
R="$HOME/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies"
exec "$R/node/bin/node" "$R/pnpm/bin/pnpm.cjs" "$@"
```

Then install the plugin with `PNPM_HOME` and its `bin` directory on `PATH`, or pnpm
refuses to install globally:

```
[ERROR] The configured global bin directory "…/pnpm-global/bin" is not in PATH
```

## 2. The bundled Node refuses to load the native binding

`dsh` boots through `node-addon-require-builtin`, and the prebuilt `.node` file
comes from npm. On Apple Silicon that combination fails:

```
code signature in '…/darwin-arm64-napi-v9.node' not valid for use in process:
mapping process and mapped file (non-platform) have different Team IDs
```

Why:

| | signature |
|---|---|
| DSH-bundled `node` | Developer ID (vendor Team ID) with `flags=0x10000(runtime)` — hardened runtime |
| npm `.node` prebuild | `adhoc, linker-signed`, no Team ID |

Hardened runtime plus library validation rejects the ad-hoc addon.

Fix: run `dsh` with a **normal Node install** (Homebrew, nvm, nodejs.org) instead of
the vendor-bundled one. A plain Node loads the same addon without complaint. This
is what [`scripts/fleet-run.sh`](../scripts/fleet-run.sh) does — it prefers, in
order: `$DSH_NODE_BIN`, the newest `~/.nvm/versions/node/*/bin/node`,
`/opt/homebrew/bin/node`, `/usr/local/bin/node`, `/usr/bin/node`, and only then the
runtime binary.

Check the difference yourself:

```sh
codesign -dv --verbose=2 "$(command -v node)" | grep -E 'flags|TeamIdentifier'
```

## 3. A pnpm global install hides the platform package from the loader

pnpm's isolated layout puts each package in its own directory and links them. The
addon loader does `require('node-addon-require-builtin-darwin-arm64')`, and Node
resolves through the symlink to the realpath, where the platform package is not a
sibling. The package is installed, the `.node` file is on disk, and it still fails:

```
No usable native binding found for node-addon-require-builtin-darwin-arm64 (auto)
```

Fix: [`scripts/mac-link-native-binding.sh`](../scripts/mac-link-native-binding.sh)
builds a shim directory of symlinks and points `NODE_PATH` at it. `NODE_PATH` is
the CommonJS fallback resolution root, so the bare `require` resolves without
patching anyone's code or depending on pnpm hash directory names.

```sh
sh scripts/mac-link-native-binding.sh   # creates $PNPM_HOME/node-path
```

`fleet-run.sh` exports `NODE_PATH` automatically when that directory exists.

---

## End-to-end sequence

```sh
R="$HOME/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies"
export PNPM_HOME="$HOME/.dsh/pnpm-global"
export PATH="$PNPM_HOME/bin:$PATH"          # after installing scripts/pnpm-shim.sh

# 1. install the CLI
"$R/node/bin/node" "$R/pnpm/bin/pnpm.cjs" add -g @deepseek-ai/dsh@0.2.1-rc.5

# 2. fix native binding resolution
sh scripts/mac-link-native-binding.sh

# 3. create a profile and add this plugin
dsh fleet --from-default-profile web --dump-config
dsh plugin --profile fleet add link:"$HOME/dsh-plugins/dsh-ctl"

# 4. run it
sh scripts/fleet-run.sh
```

## Making `dsh` usable from an interactive shell

Two things make a naive `export PATH=...pnpm-global/bin:$PATH` a trap:

- **Node version.** The login shell here resolved `node` to nvm's default `v20`,
  and `dsh` 0.2.1-rc.5 **exits silently with no output** on v20 — it does not even
  print an error. A Node ≥ 22 is required.
- **Scope.** Prepending a Node to the global `PATH` changes `node` for every other
  project on the machine.

So use [`scripts/dsh-wrapper.sh`](../scripts/dsh-wrapper.sh) instead. Install it as
`~/.local/bin/dsh` (a directory most setups already have on `PATH`) and it picks a
suitable Node just for this one command:

```sh
install -m 755 scripts/dsh-wrapper.sh ~/.local/bin/dsh
zsh -lic 'command -v dsh; dsh --version'      # -> ~/.local/bin/dsh, 0.2.1-rc.5
```

Verify a build actually **boots**, not just that `--version` prints — `--version`
never loads the native addon, so it passes on configurations that fail at boot.

## Migrating plugins from the desktop profile

The desktop app's plugins live in `$DSH_HOME/profiles/desktop/package.json` and are
**not** shared with other profiles. Re-declare them per profile:

```sh
dsh plugin --profile fleet add "link:$HOME/dsh-plugins/dsh-feishu-steer"
dsh plugin --profile fleet add "link:$HOME/dsh-plugins/dsh-mcp-chrome-devtools"
dsh plugin --profile fleet add "link:$HOME/dsh-plugins/dsh-mcp-context7-codegraph"
dsh plugin --profile fleet add "octie-cli@^1.3.2"
```

Each `add` appends to `dsh.profile.bundles` as well as `dependencies`, so no manual
`package.json` editing is needed:

```json
"bundles": [
  "@deepseek-ai/dsh-base",
  "@deepseek-ai/dsh-web-app",
  "dsh-ctl",
  "dsh-feishu-steer",
  "@local/dsh-mcp-chrome-devtools",
  "@local/dsh-mcp-context7-codegraph",
  "octie-cli"
]
```

A successful boot logs the MCP servers starting (`Context7 Documentation MCP Server
… running on stdio`, `Starting CodeGraph MCP server`, the `chrome-devtools-mcp`
banner). If one of those is absent from `dsh-fleet.log`, that plugin did not mount.

## Keeping it running with launchd

Use the installer; it is idempotent and verifies the result.

```sh
sh scripts/mac-install-launchd.sh              # install + start
sh scripts/mac-install-launchd.sh --uninstall  # stop + remove
```

It stops any hand-started instance (which would otherwise fight for the port),
writes `~/Library/LaunchAgents/dev.dsh.fleet.plist`, replaces the existing job, and
polls the control plane until it answers.

| key | value | effect |
|---|---|---|
| `RunAtLoad` | `true` | starts when the agent loads |
| `KeepAlive` | `true` | restarts on any exit |
| `ThrottleInterval` | `10` | a crash loop restarts at most every 10 s |
| `Standard{Out,Error}Path` | `~/Library/Logs/dsh-fleet.log` | one log for both streams |

launchd does not read your shell profile, which is exactly why every bit of
environment wiring lives inside `fleet-run.sh` rather than in `.zshrc`.

### The catch: a LaunchAgent loads at user login, not at boot

A LaunchAgent in `~/Library/LaunchAgents` runs in the user's GUI session. If the
machine reboots to the login window and nobody logs in, **nothing starts**.

Two ways to cover that:

- **Auto-login enabled** (System Settings → Users & Groups → Automatically log in
  as…). Check with `defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser`.
  This deployment has auto-login on, so a reboot does self-heal.
- **A LaunchDaemon instead**, at `/Library/LaunchDaemons/`, which runs before any
  login. That needs `sudo` and the job then runs as root — a bigger blast radius
  for an agent that already has shell access, so prefer auto-login unless the
  machine must stay at the login window.

### Verifying it actually self-heals

`launchctl print` alone proves nothing about restarts. Test the two behaviours:

```sh
# crash recovery
pid=$(curl -s http://127.0.0.1:17390/ctl/health | sed -n 's/.*"pid":\([0-9]*\).*/\1/p')
kill -9 "$pid"
# a new pid within a few seconds, `runs` incremented in `launchctl print`

# fresh-load startup (proxy for a login/reboot)
launchctl bootout gui/$(id -u)/dev.dsh.fleet
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.dsh.fleet.plist
# comes up with no manual `dsh` invocation
```

## Version differences seen on 0.2.1-rc.5

Bringing the same plugin up on a newer DSH surfaced changes worth knowing about:

| | 0.1.5-rc.2 | 0.2.1-rc.5 |
|---|---|---|
| `session/list` item shape | `sessionId` + `projections.values.title` | same — still works |
| session `meta.version` | 3 | 4 |
| `control()` baseline keys | `projections`, `queues` | **`projections` only** |
| queue `placement` (`queued`/`steering`) | readable from the baseline | **not exposed** |
| `projections.values` | title, agentPreset, sessionStats, … | adds `tokenUsage`, `contextPressure`, `contextBreakdown` |

So `POST /ctl/prompt` with `mode: "steer"` is still accepted on 0.2.1, but the
`/ctl/control` queue listing comes back empty because the host no longer publishes
that field. Use `/ctl/debug/shape` and `/ctl/control?raw=1` to re-confirm on any new
version before relying on a field.

## Shared session store

The CLI and the desktop app read the same `$DSH_HOME/sessions` tree. After starting
the `fleet` profile on this machine, `GET /ctl/sessions` returned all seven sessions
the desktop app had created, with their real titles — no migration, no import.
