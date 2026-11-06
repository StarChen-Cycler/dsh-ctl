<#
.SYNOPSIS
    Start the DSH fleet server detached, then verify its control plane answers.

.DESCRIPTION
    The Windows counterpart of mac-start-fleet.sh. Starts fleet-run.ps1 in a
    hidden window, waits for /ctl/health, and prints the result plus the tail of
    the log. Use it for a first smoke test; for production use
    win-install-scheduledtask.ps1 so it survives a reboot.

.PARAMETER Port
    Listen port (default 17390 / $env:DSH_FLEET_PORT).

.PARAMETER TimeoutSeconds
    How long to wait for the control plane (default 40).
#>
[CmdletBinding()]
param(
    [int]$Port = $(if ($env:DSH_FLEET_PORT) { [int]$env:DSH_FLEET_PORT } else { 17390 }),
    [int]$TimeoutSeconds = 40
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $PSScriptRoot 'fleet-run.ps1'
if (-not (Test-Path $launcher)) { throw "missing launcher: $launcher" }

$log = if ($env:DSH_FLEET_LOG) { $env:DSH_FLEET_LOG } else { Join-Path $env:USERPROFILE 'dsh-fleet.log' }

# Stop a previously started instance; it would fight for the port.
Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'bin\.js\s+\w+' -and $_.CommandLine -match 'dsh' } |
    ForEach-Object {
        Write-Host "stopping previous instance pid=$($_.ProcessId)"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
Start-Sleep -Seconds 1

Write-Host "starting: $launcher"
$proc = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher `
    -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $log -RedirectStandardError "$log.err"
Write-Host "launcher pid=$($proc.Id)"

$ok = $false
for ($i = 1; $i -le $TimeoutSeconds; $i++) {
    Start-Sleep -Seconds 1
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/ctl/health" -TimeoutSec 2
        Write-Host "listening after ${i}s"
        $ok = $true
        break
    } catch { }
}

Write-Host '== log head =='
Get-Content $log -TotalCount 4 -ErrorAction SilentlyContinue

if (-not $ok) {
    Write-Host '== log tail ==' -ForegroundColor Red
    Get-Content $log -Tail 20 -ErrorAction SilentlyContinue
    throw "fleet did not come up on port $Port within $TimeoutSeconds s"
}

Write-Host '== health =='
Invoke-RestMethod -Uri "http://127.0.0.1:$Port/ctl/health" -TimeoutSec 5 | ConvertTo-Json -Compress
Write-Host "log: $log"
