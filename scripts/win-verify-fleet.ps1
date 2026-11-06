<#
.SYNOPSIS
    Print the fleet control plane state: health, sessions, live queue.

.DESCRIPTION
    The Windows counterpart of mac-verify-fleet.sh. Kept as a script rather than
    an inline command because a Windows remote shell (cmd.exe) mangles the '?'
    and '&' in a URL — every URL probe has to go through PowerShell properly
    quoted, and a file is the only reliable way to get that right.

.PARAMETER Port
    Listen port (default 17390 / $env:DSH_FLEET_PORT).

.PARAMETER Limit
    How many sessions to list (default 10).
#>
[CmdletBinding()]
param(
    [int]$Port = $(if ($env:DSH_FLEET_PORT) { [int]$env:DSH_FLEET_PORT } else { 17390 }),
    [int]$Limit = 10
)

$ErrorActionPreference = 'Stop'
$base = "http://127.0.0.1:$Port"

function Get-Json {
    param([string]$Path)
    try {
        return Invoke-RestMethod -Uri "$base$Path" -TimeoutSec 10
    } catch {
        return $null
    }
}

Write-Host '== health =='
$health = Get-Json '/ctl/health'
if (-not $health) { throw "no response from $base/ctl/health" }
$health | ConvertTo-Json -Compress

Write-Host ''
Write-Host "== sessions (limit $Limit) =="
$sessions = Get-Json "/ctl/sessions?limit=$Limit"
if ($sessions) {
    Write-Host ("total={0} running={1}" -f $sessions.total, $sessions.running)
    $sessions.items | ForEach-Object {
        $title = if ($_.title) { $_.title } else { '(untitled)' }
        $running = if ($_.running) { 'RUNNING' } else { 'idle' }
        Write-Host ("  {0}  [{1}]  {2}  {3}" -f $_.sessionId, $running, $title, $_.cwd)
    }
}

Write-Host ''
Write-Host '== live control (queue + stats) =='
$control = Get-Json '/ctl/control?ms=2500'
if ($control) {
    $props = $control.sessions.PSObject.Properties
    if (-not $props) {
        Write-Host '  (no active sessions)'
    } else {
        foreach ($p in $props) {
            $q = if ($p.Value.queue) { $p.Value.queue.Count } else { 0 }
            Write-Host ("  {0}: queue={1} turns={2} steps={3}" -f $p.Name, $q, $p.Value.stats.turns, $p.Value.stats.steps)
        }
    }
}
