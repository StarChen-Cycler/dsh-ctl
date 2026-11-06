<#
.SYNOPSIS
    Supervise the fleet server: run it, and restart it whenever it exits.

.DESCRIPTION
    Windows Task Scheduler has no direct equivalent of launchd's KeepAlive, so
    this loop supplies it. The scheduled task runs this script once; the script
    keeps dsh alive for as long as the task is allowed to run.

    Restart delay is fixed and short (default 5 s) so a crash loop cannot spin
    but a transient failure recovers quickly — the same intent as launchd's
    ThrottleInterval.

    Do not run this in a foreground terminal you intend to Ctrl-C: stop the
    scheduled task instead (win-install-scheduledtask.ps1 -Uninstall).

.PARAMETER RestartDelaySeconds
    Wait between restarts (default 5).
#>
[CmdletBinding()]
param(
    [int]$RestartDelaySeconds = 5
)

$ErrorActionPreference = 'Stop'

$launcher = Join-Path $PSScriptRoot 'fleet-run.ps1'
if (-not (Test-Path $launcher)) { throw "missing launcher: $launcher" }

$log = if ($env:DSH_FLEET_LOG) { $env:DSH_FLEET_LOG } else { Join-Path $env:USERPROFILE 'dsh-fleet.log' }

# Only one supervisor may run. Two of them would race to restart dsh and fight
# over the listen port. A named mutex makes that impossible, so starting the
# task twice (or a task plus a manual run) is harmless.
#
# Scope is Local\, not Global\: Global\ needs SeCreateGlobalPrivilege, and an
# unelevated shell throws on construction — which would kill the supervisor
# before it ever started dsh. Everything here lives in one user session anyway.
$acquired = $true
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\DSH-Fleet-Supervisor')
    try {
        $acquired = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    }
} catch {
    # Could not create or acquire the mutex: proceed rather than refuse to run.
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
    Add-Content -Path $log -Value $line -ErrorAction SilentlyContinue
}

Write-Log "supervisor start (pid $PID)"

while ($true) {
    Write-Log 'starting fleet-run.ps1'
    $started = Get-Date
    try {
        # -WorkingDirectory matters: dsh refuses to boot from a directory whose
        # .env sets DEEPSEEK_BASE_URL, so never inherit an arbitrary cwd here.
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher *>> $log
        $code = $LASTEXITCODE
    } catch {
        Write-Log "launcher threw: $($_.Exception.Message)"
        $code = -1
    }

    $ranFor = (Get-Date) - $started
    Write-Log ("fleet-run.ps1 exited code={0} after {1:n0}s" -f $code, $ranFor.TotalSeconds)

    Start-Sleep -Seconds $RestartDelaySeconds
    Write-Log 'restarting'
}
