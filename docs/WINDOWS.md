# Deploying on Windows

Windows needs less environment surgery than macOS but introduces one problem
macOS does not have: **a process started over SSH is killed when that SSH session
ends.** That single fact decides the whole launch strategy.

Verified on Windows 10 22H2 (build 19045), PowerShell 5.1, Node v24.22.1,
DSH 0.2.1-rc.5.

---

## 1. No Native binding workarounds needed

On macOS the vendor runtime is hardened-runtime signed and refuses the
ad-hoc-signed npm native addon, which forces you onto a separate Node. Windows has
no such code-signature gate, so a normal `node` on `PATH` is enough — this
deployment used the system Node at `C:\Program Files\nodejs\node.exe`.

Requirement: **Node >= 22**. dsh 0.2.1 exits silently on older versions, with no
error message at all.

## 2. Install with npm, not pnpm — it avoids the NODE_PATH hack

On macOS, a pnpm *global* install hides the platform native package behind symlink
realpaths, so the addon loader's bare `require` fails and `NODE_PATH` has to be
injected. npm's global layout is flat, so the platform package sits as a real
sibling and resolves by itself.

```powershell
npm install -g pnpm @deepseek-ai/dsh@0.2.1-rc.5
dsh --version
```

`pnpm` is still needed even though you install with npm: `dsh plugin` shells out to
an executable named `pnpm`.

If you *do* install via pnpm and hit
`No usable native binding found for node-addon-require-builtin-win32-x64-msvc`,
set `DSH_NODE_PATH` to a directory containing the platform package; `fleet-run.ps1`
will put it on `NODE_PATH`.

## 3. The one that bites: SSH kills your background process

Starting the server from an SSH command line looks fine — it listens, `/ctl/health`
answers — and then it is **gone the moment that SSH session closes**:

```
starting: ...\fleet-run.ps1
launcher pid=5376
listening after 3s
{"ok":true,"port":17390,...}        <- healthy inside the session
# ssh exits
... next session ...
no response from http://127.0.0.1:17390/ctl/health
```

Windows OpenSSH tears down the process tree of the session. `Start-Process`,
`-WindowStyle Hidden`, and `nohup`-style detachment do not save it.

Two consequences:

- **Foreground is fine for a local terminal.** `fleet-run.ps1` blocks and runs until
  you stop it, which is correct when you are sitting at the machine or on RDP.
- **For anything that must outlive the session, register a scheduled task.**

## 4. Task Scheduler is not launchd

launchd's `KeepAlive` restarts the job whenever it exits. Task Scheduler's
"restart on failure" only fires on a non-zero exit, so a clean stop leaves the
service down.

This repo therefore supplies the loop itself:

- [`win-supervise-fleet.ps1`](../scripts/win-supervise-fleet.ps1) — probes
  `/ctl/health` every 10 s and starts a launcher whenever nothing answers. That
  is the `KeepAlive` behaviour.
- [`win-install-scheduledtask.ps1`](../scripts/win-install-scheduledtask.ps1) —
  registers task `DSH-Fleet` to run the supervisor at logon, with no execution
  time limit, then starts it and waits for `/ctl/health`.

```powershell
# registration needs elevation; -Limited decides what the task then runs as
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\win-install-scheduledtask.ps1 -Limited

# remove it
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\win-install-scheduledtask.ps1 -Uninstall
```

### 4.1 Supervise on health, never on a child process

The first version of the loop ran the launcher synchronously and restarted when
it exited:

```powershell
& powershell.exe -File fleet-run.ps1 *>> $log
```

That ties the supervisor's progress to one child's lifetime: it cannot start a
replacement until the call returns, and it never returns if the child wedges. The
supervisor then looks perfectly alive in `Get-Process` while keeping nothing
alive. That shape is what the health probe removes — the loop never waits on a
child, so no child's lifetime can stall it.

One detail worth knowing when reading the logs: while `dsh` boots, its HTTP server
listens before the plugin's routes are registered, so `/ctl/health` answers **404**
for a moment. The supervisor logs probe failures with their reason (once per
distinct message, not once per probe), which is how that surfaced.

### 4.2 Keep the console window off the desktop

Task Scheduler launches the action through a console host. Without a window-style
flag a visible PowerShell window — "Administrator: …" if the task runs elevated —
appears at logon and stays for as long as the task runs. It cannot be closed
without killing the supervisor, which is the opposite of what the task exists
for.

Two independent defences:

| layer | mechanism |
|---|---|
| task action | `-NoProfile -NonInteractive -NoLogo -WindowStyle Hidden` |
| the script itself | `ShowWindow(GetConsoleWindow(), SW_HIDE)` at startup |

The script-level hide is the robust one: the action flag only takes effect the
next time the action is registered, so a task registered before the fix keeps
showing its window until someone re-registers it. Hiding from inside the script
covers every launch path — task, shortcut, another script. It is best effort: if
`Add-Type` is unavailable the supervisor runs with its window rather than failing
to start.

### 4.3 Register with the user token, not elevated

`-RunLevel Highest` makes the whole fleet run elevated. `dsh web` needs no
administrator rights, and the cost is practical rather than theoretical: the same
user's ordinary tooling can no longer manage the service (see 4.4). Pass
`-Limited`, which is what the command above does.

### 4.4 Elevation makes verification lie to you

Three false results, all from the fleet being a child of an elevated task:

| what the check said | what was true |
|---|---|
| a crash-recovery check reported no new pid after waiting | `Stop-Process` had been denied because the victim was elevated, so nothing was ever killed |
| "no node processes" | the process existed and was serving; its `CommandLine` was unreadable to a non-elevated caller, so a command-line filter matched nothing |
| "the health reply is stale" | nothing was stale — the process was simply unkillable |

All three vanish under `-Limited`. The general lesson: when a liveness or recovery
check fails, first confirm the action it depends on actually happened. A denied
operation swallowed by `-ErrorAction SilentlyContinue` turns into a confident,
wrong diagnosis.

Also worth knowing: `schtasks /end /tn DSH-Fleet` works **without** elevation and
terminates the task's process tree, which is the practical recovery route from a
mis-registered task.

Also worth knowing: `schtasks /end /tn DSH-Fleet` works **without** elevation and
terminates the task's process tree, which is the practical recovery route from a
mis-registered task.

## 5. A logon trigger still needs a login

Like a macOS LaunchAgent, an at-logon task runs inside a user session. If the
machine reboots to the login screen and nobody signs in, nothing starts.

Check it:

```powershell
(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon).AutoAdminLogon
```

`1` means the machine signs itself in and the task will start. `0` means an
unattended reboot leaves the service down until someone logs in — this deployment
reports `0`, so that is the current behaviour here.

The alternative is a task registered with `-AtStartup` running as `SYSTEM`, which
needs no login but runs with machine-wide privileges. Prefer auto-login unless the
machine must stay at the login screen.

## 6. Quoting: do not inline URL commands

The remote shell is `cmd.exe`, which eats `?` and `&` in a URL and mangles nested
quotes. `curl http://127.0.0.1:17390/ctl/sessions?limit=5` invoked over SSH returns
nothing at all — no error, just empty output.

Always drive the control plane from a script file:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\win-verify-fleet.ps1
```

That is why [`win-verify-fleet.ps1`](../scripts/win-verify-fleet.ps1) exists: it is
the Windows port of the `curl` probes used on macOS.

---

## 7. Pin the working directory in the launcher

`dsh` treats the **invoking directory** as the workspace root, and it refuses to
boot when that directory has a `.env` setting `DEEPSEEK_BASE_URL`:

```
Error: .env sets "DEEPSEEK_BASE_URL", which only the launching environment may set
```

A launcher started from a hidden window, a scheduled task, or another repository
inherits *that* directory. `fleet-run.ps1` therefore does `Set-Location $HOME`
before exec'ing dsh. Without it the server crash-loops with a stack trace pointing
at `dsh-app-boot/lib/index.js` and no useful message.

## 8. Autostart can be blocked outright

Two independent gates on a locked-down Windows box:

| attempt | result |
|---|---|
| `Register-ScheduledTask` (per-user, no elevation) | `Access is denied` (0x80070005) — tasks live in `%SystemRoot%\System32\Tasks`, which needs elevation |
| writing a `.vbs` / `.cmd` / `.ps1` into the Startup folder | `Access is denied`, while a `.txt` in the same folder succeeds |

The second one is not an ACL problem — the user has `FullControl` on the folder —
so it is an endpoint-protection rule blocking script files in an autostart
location. There is no supported way around it from an unelevated shell.

`win-install-scheduledtask.ps1` handles both: it registers the task when possible,
otherwise falls back to the Startup folder, and reports clearly if both are denied.
When that happens, either run it once from an **elevated** shell, or accept
launching by hand after a reboot.

## 9. Several dsh versions on one machine

Keep the profile's CLI explicit. `fleet-run.ps1` resolves in this order:

1. `$env:DSH_BIN` — an explicit path
2. `%USERPROFILE%\.dsh\cli\dsh.cmd` — per-user install convention
3. `dsh` on `PATH`

Step 2 exists because a launcher started by Windows cannot inherit `DSH_BIN`, and
`PATH` often still points at an older CLI. If you install with
`npm install -g --prefix %USERPROFILE%\.dsh\cli`, note that npm nests the whole
dependency tree under the package, so the usable entry point is
`.dsh\cli\node_modules\@deepseek-ai\dsh\lib\bin.js` and a small `dsh.cmd` shim is
worth writing next to it.

## Full sequence

```powershell
# 1. CLI
npm install -g pnpm @deepseek-ai/dsh@0.2.1-rc.5

# 2. plugin source
git clone https://github.com/StarChen-Cycler/dsh-ctl.git C:\Users\<you>\dsh-plugins\dsh-ctl

# 3. profile + plugin
dsh fleet --from-default-profile web --dump-config
dsh plugin --profile fleet add link:C:/Users/<you>/dsh-plugins/dsh-ctl

# 4. foreground run (local terminal)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fleet-run.ps1

# or: detached smoke test
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\win-start-fleet.ps1

# 5. make it survive logout/reboot (elevated; -Limited keeps the fleet unprivileged)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\win-install-scheduledtask.ps1 -Limited
```

## Verifying it actually self-heals

`Get-ScheduledTask` proves nothing about restarts, and neither does
`Scheduled Task State: Running`. Test the behaviour instead:

```powershell
# 1. the task, not a leftover manual process, owns the supervisor
Get-Content $env:USERPROFILE\dsh-fleet-supervisor.log -Tail 3

# 2. crash recovery: kill the pid /ctl/health reports, never a name pattern
$old = (Invoke-RestMethod http://127.0.0.1:17390/ctl/health).pid
Stop-Process -Id $old -Force        # must not raise Access is denied
# expect a different pid within ~40 s; worst case ~70 s

# 3. the same non-elevated user can stop it — this is the check that 4.4 fails
(Invoke-RestMethod http://127.0.0.1:17390/ctl/health).pid |
    ForEach-Object { Get-CimInstance Win32_Process -Filter "ProcessId = $_" } |
    Select-Object ProcessId, CommandLine        # readable only if not elevated
```

Watch the supervisor log (`dsh-fleet-supervisor.log`; the dsh process writes
`dsh-fleet.log`, and the launcher's stderr goes to `dsh-fleet.log.err`):

```
2026-11-07T16:16:01 [supervisor] probe failed: unable to connect to the remote server
2026-11-07T16:16:01 [supervisor] control plane not answering; starting launcher
2026-11-07T16:16:09 [supervisor] probe failed: the remote server returned an error: (404)
2026-11-07T16:16:12 [supervisor] control plane is up
```

Those are one real run (messages translated; the log itself is localized). The
`404` line is the plugin's routes not being registered yet during `dsh` boot, so it
is expected once per start and not a fault. `control plane is up` must follow the
launcher within seconds — if it only appears after ~60 s, the grace loop is running
the old code that waited out its full window.

## macOS vs Windows at a glance

| | macOS | Windows |
|---|---|---|
| launcher | `fleet-run.sh` | `fleet-run.ps1` |
| detached smoke test | `mac-start-fleet.sh` | `win-start-fleet.ps1` |
| persistence | `mac-install-launchd.sh` (LaunchAgent) | `win-install-scheduledtask.ps1` (task + supervisor loop) |
| keep-alive | built in (`KeepAlive`) | supplied by `win-supervise-fleet.ps1` |
| Node choice | a normal Node, **not** the vendor runtime | any Node >= 22, bundled runtime fine |
| native addon lookup | needs `NODE_PATH` shim for pnpm globals | resolves with npm globals |
| verify | `curl` against loopback | `win-verify-fleet.ps1` |
