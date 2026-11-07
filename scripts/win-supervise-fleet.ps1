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

        # Wait for it to come up, but stop waiting the moment it came up and then
        # died again. Without that, a server that starts and immediately crashes
        # keeps the supervisor inside the grace window for its whole duration,
        # which delays recovery by up to StartupGraceSeconds.
        $everUp = $false
        $deadline = (Get-Date).AddSeconds($StartupGraceSeconds)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            $healthy = Test-FleetHealth
            if ($healthy) {
                $everUp = $true
                continue
            }
            if ($everUp) {
                Write-Log 'came up and went down again during startup; restarting now'
                break
            }
        }
        if ($everUp) { Write-Log 'control plane is up' }
        else { Write-Log "still not answering after ${StartupGraceSeconds}s; will retry" }
    }

    Start-Sleep -Seconds $RestartDelaySeconds
}
