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

## Keeping it running with launchd

```xml
<!-- ~/Library/LaunchAgents/dev.dsh.fleet.plist -->
<key>ProgramArguments</key>
<array>
  <string>/bin/sh</string>
  <string>REPLACE_WITH_HOME/.dsh/fleet-run.sh</string>
</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>REPLACE_WITH_HOME/Library/Logs/dsh-fleet.log</string>
<key>StandardErrorPath</key><string>REPLACE_WITH_HOME/Library/Logs/dsh-fleet.log</string>
```

`launchctl bootstrap gui/"$(id -u)" ~/Library/LaunchAgents/dev.dsh.fleet.plist`

Note that launchd does not read your shell profile, which is exactly why every bit
of environment wiring lives inside `fleet-run.sh` instead of in `.zshrc`.

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
