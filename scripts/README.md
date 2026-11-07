# scripts

Everything here is grouped by purpose first, then by platform. **Pick the platform
directory section that matches the machine you are deploying to** — the macOS and
Windows launchers are not interchangeable.

| | macOS / Linux | Windows |
|---|---|---|
| Foreground launcher | `fleet-run.sh` | `fleet-run.ps1` |
| Detached smoke test | `mac-start-fleet.sh` | `win-start-fleet.ps1` |
| Persistence | `mac-install-launchd.sh` | `win-install-scheduledtask.ps1` |
| Keep-alive helper | — (launchd `KeepAlive`) | `win-supervise-fleet.ps1` |
| Verify the control plane | `curl` / `mac-verify` snippets in docs | `win-verify-fleet.ps1` |
| Client helpers | `ctl.sh` | `ctl.ps1` |

---

## 1. Calling the control plane

| File | Platform |
|---|---|
| `ctl.sh` | POSIX shell (macOS, Linux, WSL) |
| `ctl.ps1` | Windows PowerShell 5.1+ |

Both talk to `http://127.0.0.1:<port>` on the machine that runs `dsh web`, which is
why remote use stays simple:

```sh
ssh <host> ctl sessions --running
```

The remote command runs on the host, inside its own shell, so no JSON ever has to
survive being quoted through SSH. That is the whole point of shipping these instead
of teaching you an `ssh host 'curl -d "{...}"'` incantation.

Configuration:

```sh
export DSH_CTL_PORT=17390      # default
export DSH_CTL_SECRET=...      # only when the plugin config sets a secret
```

```powershell
$env:DSH_CTL_PORT = 17390
$env:DSH_CTL_SECRET = '...'
```

---

## 2. macOS deployment

Read [docs/MACOS.md](../docs/MACOS.md) first — three environment traps explain why
these exist.

| File | Purpose |
|---|---|
| `fleet-run.sh` | foreground launcher; picks a Node >= 22 (not the vendor runtime), sets `NODE_PATH` |
| `mac-start-fleet.sh` | starts it detached with `nohup`, waits for `/ctl/health` |
| `mac-install-launchd.sh` | LaunchAgent `dev.dsh.fleet`, `RunAtLoad` + `KeepAlive`; `--uninstall` removes it |
| `mac-link-native-binding.sh` | builds the `NODE_PATH` shim directory for the native addon |
| `mac-inventory.sh` | reports every DSH install, profile and session on the box |
| `dsh-wrapper.sh` | install as `~/.local/bin/dsh` so `dsh` works in a login shell without changing the global `node` |
| `pnpm-shim.sh` | provides an executable named `pnpm` for `dsh plugin` |

```sh
sh scripts/mac-link-native-binding.sh
sh scripts/mac-install-launchd.sh
```

## 3. Windows deployment

Read [docs/WINDOWS.md](../docs/WINDOWS.md) first. The headline: **a process started
over SSH is killed when the SSH session ends**, so persistence must go through Task
Scheduler.

| File | Purpose |
|---|---|
| `fleet-run.ps1` | foreground launcher; validates Node >= 22, then runs `dsh <profile> --port <port> --no-open` |
| `win-start-fleet.ps1` | starts it detached and waits for `/ctl/health` — smoke test only, it will NOT outlive the session |
| `win-supervise-fleet.ps1` | health-probe loop: starts a launcher whenever `/ctl/health` stops answering. Supplies the `KeepAlive` that Task Scheduler lacks, and hides its own console window |
| `win-install-scheduledtask.ps1` | registers task `DSH-Fleet` at logon and starts it (add `-Limited` to avoid running the fleet elevated); `-Uninstall` removes it |
| `win-verify-fleet.ps1` | prints health, sessions and live queue (a Windows remote shell mangles URLs, so this must be a script) |

```powershell
# elevated shell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\win-install-scheduledtask.ps1
```

---

## 4. Enabling SSH on a target machine

| File | Platform |
|---|---|
| `enable-ssh-windows.ps1` | Windows (OpenSSH Server capability + service + firewall rule) |
| `enable-ssh-macos.sh` | macOS (`systemsetup -setremotelogin on`) |
| `enable-ssh-linux.sh` | Linux (systemd `ssh`/`sshd` unit) |

**All three are dry-run by default.** They print the plan and change nothing until
you pass `-Apply` (PowerShell) or `--apply` (shell). All require elevation.

They are kept out of the plugin on purpose: enabling a system service is privileged,
one-time machine setup, and the control plane should never do that on your behalf.

### The chicken-and-egg

You cannot use SSH to turn SSH on. Run these helpers with physical or console access
once, or use a management channel you already trust (a hypervisor console, a remote
KVM, an existing orchestration agent, or a VPN appliance's shell). After that, the
`ctl` helpers take over.
