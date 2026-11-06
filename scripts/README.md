# scripts

Two kinds of helpers live here.

## 1. Calling the control plane

| File | Platform |
|---|---|
| `ctl.sh` | POSIX shell (macOS, Linux, WSL) |
| `ctl.ps1` | Windows PowerShell |

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

## 2. Enabling SSH on a target machine

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
