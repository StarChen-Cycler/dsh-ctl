<#
.SYNOPSIS
    Supervise the fleet server by probing its control plane, not by waiting on a
    child process.

.DESCRIPTION
    The Windows counterpart of launchd's KeepAlive.

    An earlier version ran the launcher synchronously and restarted when it
    exited:

        & powershell.exe -File fleet-run.ps1 *>> $log

    That blocks for as long as the child lives, and it stays blocked if the child
    wedges — observed in practice as "kill the server, nothing ever comes back"
    while the supervisor process was still alive. Supervising on *health* avoids
    the whole class: the loop never waits on a child, it just asks the control
    plane whether something is answering and starts a launcher when nothing is.

    Logs are split so neither stream clobbers the other:
      %USERPROFILE%\dsh-fleet-supervisor.log   this loop
      %USERPROFILE%\dsh-fleet.log              the current dsh process

.PARAMETER RestartDelaySeconds
    Pause between health probes (default 10).

.PARAMETER StartupGraceSeconds
    How long to give a freshly started launcher before probing again (default 60).
#>
[CmdletBinding()]
param(
    [int]$RestartDelaySeconds = 10,
    [int]$StartupGraceSeconds = 60
)

$ErrorActionPreference = 'Stop'

# Hide our own console window. -WindowStyle Hidden on the task action is the
# primary mechanism, but it only takes effect the next time the task action is
# registered; doing it from inside means any launch - task, shortcut, another
# script - leaves no window on the desktop. Best effort: a host without its own
# console simply has nothing to hide.
try {
    Add-Type -Namespace DshCtl -Name ConsoleWindow -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
    $handle = [DshCtl.ConsoleWindow]::GetConsoleWindow()
    if ($handle -ne [IntPtr]::Zero) { $null = [DshCtl.ConsoleWindow]::ShowWindow($handle, 0) }
} catch {
    Write-Verbose "could not hide the console window: $($_.Exception.Message)"
}

$launcher = Join-Path $PSScriptRoot 'fleet-run.ps1'
if (-not (Test-Path $launcher)) { throw "missing launcher: $launcher" }

$port = if ($env:DSH_FLEET_PORT) { [int]$env:DSH_FLEET_PORT } else { 17390 }
$logFile = if ($env:DSH_FLEET_LOG) { $env:DSH_FLEET_LOG } else { Join-Path $env:USERPROFILE 'dsh-fleet.log' }
$supLog = Join-Path $env:USERPROFILE 'dsh-fleet-supervisor.log'

# Only one supervisor may run; two would race to start servers on one port.
# Local\ rather than Global\: Global\ needs SeCreateGlobalPrivilege and throws
# for an unelevated shell, which would kill the supervisor before it started.
$acquired = $true
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\DSH-Fleet-Supervisor')
    try { $acquired = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $acquired = $true }
} catch {
    Write-Host "supervisor: mutex unavailable ($($_.Exception.Message)); continuing without it"
    $acquired = $true
}
if (-not $acquired) {
    Write-Host 'another DSH fleet supervisor is already running; exiting.'
    exit 0
}

function Write-Log {
    param([string]$Message)
    $line = '{0} [supervisor] {1}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Message
    Write-Host $line
    Add-Content -Path $supLog -Value $line -ErrorAction SilentlyContinue
}

function Test-FleetHealth {
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$port/ctl/health" -TimeoutSec 5
        return ($r.ok -eq $true)
    } catch {
        # Log the reason, but only when it changes, so a long outage does not
        # fill the log with one identical line per probe.
        $reason = $_.Exception.Message
        if ($reason -ne $script:lastProbeError) {
            Write-Log ("probe failed: {0}" -f $reason)
            $script:lastProbeError = $reason
        }
        return $false
    }
}

function Start-Launcher {
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher `
        -WindowStyle Hidden `
        -WorkingDirectory $env:USERPROFILE `
        -RedirectStandardOutput $logFile `
        -RedirectStandardError "$logFile.err" | Out-Null
}

Write-Log "supervisor start (pid $PID, port $port, probe every ${RestartDelaySeconds}s)"

while ($true) {
    if (-not (Test-FleetHealth)) {
        Write-Log 'control plane not answering; starting launcher'
        try { Start-Launcher } catch { Write-Log "launcher start failed: $($_.Exception.Message)" }

        # Wait for it to come up, then hand control back to the outer probe loop.
        # Breaking on the first healthy probe matters: continuing inside the grace
        # window would delay both the 'control plane is up' line and the next
        # crash check by up to StartupGraceSeconds. A server that comes up and
        # immediately dies is caught by the next outer probe, so it needs no
        # special case here.
        $recovered = $false
        $deadline = (Get-Date).AddSeconds($StartupGraceSeconds)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            if (Test-FleetHealth) { $recovered = $true; break }
        }
        if ($recovered) { Write-Log 'control plane is up' }
        else { Write-Log "still not answering after ${StartupGraceSeconds}s; will retry" }
    }

    Start-Sleep -Seconds $RestartDelaySeconds
}
