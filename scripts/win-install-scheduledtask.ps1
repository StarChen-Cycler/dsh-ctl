<#
.SYNOPSIS
    Register (or remove) a Windows scheduled task that keeps the fleet server
    running. The Windows counterpart of mac-install-launchd.sh.

.DESCRIPTION
    Registers a task named DSH-Fleet that starts win-supervise-fleet.ps1 at logon
    and lets it run without a time limit. The supervisor restarts dsh if it
    exits, which is what supplies launchd's KeepAlive behaviour.

    A scheduled task at logon — like a macOS LaunchAgent — only runs once a user
    signs in. If this machine reboots to the login screen and nobody logs in,
    nothing starts. Enable auto-login, or register the task at startup as SYSTEM,
    if it must survive an unattended reboot.

.PARAMETER Uninstall
    Stop the task and remove it.

.PARAMETER NoStart
    Register the task but do not start it now.
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

$TaskName = 'DSH-Fleet'
$supervisor = Join-Path $PSScriptRoot 'win-supervise-fleet.ps1'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    # Registering a machine-level task needs elevation.
    throw 'This script must run in an elevated (Administrator) shell.'
}

if ($Uninstall) {
    Write-Host "== stopping and removing task $TaskName =="
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'bin\.js' -and $_.CommandLine -match 'dsh' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Host 'removed'
    return
}

if (-not (Test-Path $supervisor)) { throw "missing supervisor: $supervisor" }

Write-Host "== registering task $TaskName =="
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $supervisor)

$triggers = @(New-ScheduledTaskTrigger -AtLogOn)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
    -Settings $settings -RunLevel Highest -Force | Out-Null

if ($NoStart) {
    Write-Host 'registered (not started)'
    return
}

Write-Host '== starting task =='
Start-ScheduledTask -TaskName $TaskName

$port = if ($env:DSH_FLEET_PORT) { [int]$env:DSH_FLEET_PORT } else { 17390 }
$ok = $false
for ($i = 1; $i -le 40; $i++) {
    Start-Sleep -Seconds 1
    try {
        $null = Invoke-RestMethod -Uri "http://127.0.0.1:$port/ctl/health" -TimeoutSec 2
        Write-Host "listening after ${i}s"
        $ok = $true
        break
    } catch { }
}

Write-Host '== task state =='
Get-ScheduledTask -TaskName $TaskName |
    Select-Object TaskName, State |
    Format-List
Get-ScheduledTaskInfo -TaskName $TaskName |
    Select-Object LastRunTime, LastTaskResult, NumberOfMissedRuns |
    Format-List

if (-not $ok) {
    Write-Host 'task did not bring the control plane up; check the fleet log' -ForegroundColor Red
    exit 1
}

Write-Host '== health =='
Invoke-RestMethod -Uri "http://127.0.0.1:$port/ctl/health" -TimeoutSec 5 | ConvertTo-Json -Compress

Write-Host ''
$autologon = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
    -Name AutoAdminLogon -ErrorAction SilentlyContinue).AutoAdminLogon
Write-Host "AutoAdminLogon = $autologon  (a logon trigger needs a session to start in)"
