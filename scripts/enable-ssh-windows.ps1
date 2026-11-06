#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Install and start the OpenSSH Server on Windows.

.DESCRIPTION
    Dry-run by default: prints the exact steps without changing anything.
    Pass -Apply to execute. Requires an elevated (Administrator) shell.

    Enabling a service is deliberately NOT something the dsh-ctl plugin does.
    Keep privileged, one-time machine setup out of the control plane.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$steps = @(
    @{ Description = 'Install the OpenSSH.Server capability'; Action = {
            $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
            if ($cap.State -eq 'Installed') {
                Write-Host "  already installed: $($cap.Name)"
            }
            else {
                Add-WindowsCapability -Online -Name $cap.Name | Out-Null
                Write-Host "  installed: $($cap.Name)"
            }
        }
    },
    @{ Description = 'Set the sshd service to start automatically'; Action = {
            Set-Service -Name sshd -StartupType Automatic
            Write-Host '  sshd startup type = Automatic'
        }
    },
    @{ Description = 'Start the sshd service'; Action = {
            if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd }
            Write-Host "  sshd status = $((Get-Service sshd).Status)"
        }
    },
    @{ Description = 'Allow TCP 22 inbound (if no rule exists)'; Action = {
            $rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
            if ($rule) {
                Write-Host '  firewall rule already present'
            }
            else {
                New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
                    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
                Write-Host '  firewall rule created'
            }
        }
    }
)

Write-Host 'OpenSSH Server setup plan:'
for ($i = 0; $i -lt $steps.Count; $i++) {
    Write-Host ("  {0}. {1}" -f ($i + 1), $steps[$i].Description)
}

if (-not $Apply) {
    Write-Host ''
    Write-Host 'Dry run. Re-run with -Apply from an elevated shell to execute.' -ForegroundColor Yellow
    exit 0
}

if (-not (Test-Admin)) {
    Write-Error 'This script must run in an elevated (Administrator) shell.'
    exit 1
}

foreach ($step in $steps) {
    Write-Host "-> $($step.Description)"
    & $step.Action
}

Write-Host ''
Write-Host 'Done. Verify from another machine:'
Write-Host '  ssh <user>@<this-host> hostname'
