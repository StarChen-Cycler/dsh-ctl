#!/usr/bin/env pwsh
<#
.SYNOPSIS
    ctl — call the dsh-ctl control plane on the host that runs it.

.DESCRIPTION
    Talks to loopback on the machine running `dsh web` with the dsh-ctl plugin.
    For remote use, run it on the host:
        ssh <host> powershell -File ctl.ps1 sessions --running

    Compatible with Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER Port
    Port of the dsh web server. Default 17390, or $env:DSH_CTL_PORT.

.PARAMETER Secret
    Shared secret, when the plugin config sets one. Default $env:DSH_CTL_SECRET.
#>
[CmdletBinding()]
param(
    # Must stay first and positional: with -File, Windows PowerShell 5.1 binds the
    # leading token to position 0 before considering ValueFromRemainingArguments.
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Arguments,
    [int]$Port = $(if ($env:DSH_CTL_PORT) { [int]$env:DSH_CTL_PORT } else { 17390 }),
    [string]$Secret = $env:DSH_CTL_SECRET
)

$ErrorActionPreference = 'Stop'
$Base = "http://127.0.0.1:$Port"

function Get-CtlHeaders {
    $headers = @{ 'Accept' = 'application/json' }
    if ($Secret) { $headers['Authorization'] = "Bearer $Secret" }
    return $headers
}

function Read-ErrorBody {
    param($Exception)
    $response = $Exception.Response
    if (-not $response) { return $Exception.Message }
    $status = $null
    try { $status = [int]$response.StatusCode } catch { }
    $body = $null
    try {
        $stream = $response.GetResponseStream()
        if ($stream) {
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            $reader.Close()
        }
    }
    catch { }
    if (-not $body -and $Exception.ErrorDetails) { $body = $Exception.ErrorDetails.Message }
    if (-not $body) { $body = $Exception.Message }
    return (@{ ok = $false; status = $status; error = $body } | ConvertTo-Json -Compress)
}

function Invoke-Ctl {
    param(
        [string]$Method = 'GET',
        [string]$Path,
        $Body
    )
    $request = @{
        Uri         = "$Base$Path"
        Method      = $Method
        Headers     = Get-CtlHeaders
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $request['Body'] = ($Body | ConvertTo-Json -Compress)
        $request['ContentType'] = 'application/json'
    }
    try {
        return (Invoke-RestMethod @request | ConvertTo-Json -Depth 12)
    }
    catch {
        return (Read-ErrorBody $_.Exception)
    }
}

if (-not $Arguments -or $Arguments.Count -eq 0) {
    @"
usage: ctl.ps1 <command> [args]

  health
  sessions [--limit N] [--running]
  session <session-id>
  create [--cwd PATH] [--preset NAME]
  prompt <session-id> <text...>
  cancel <session-id>
  rename <session-id> <title...>
  tail <session-id> [--frames N] [--ms N]
  shape <session-id> [--type RECORD_TYPE]

Parameters: -Port (default 17390 / `$env:DSH_CTL_PORT), -Secret (default `$env:DSH_CTL_SECRET)
"@
    exit 1
}

$command = $Arguments[0]
$rest = @()
if ($Arguments.Count -gt 1) { $rest = $Arguments[1..($Arguments.Count - 1)] }

function Read-Flag {
    param([string[]]$List, [string]$Name, $Default)
    for ($i = 0; $i -lt $List.Count; $i++) {
        if ($List[$i] -eq $Name -and ($i + 1) -lt $List.Count) { return $List[$i + 1] }
    }
    return $Default
}
function Test-Flag {
    param([string[]]$List, [string]$Name)
    return ($List -contains $Name)
}

switch ($command) {
    'health' { Invoke-Ctl -Path '/ctl/health' }
    'sessions' {
        $limit = Read-Flag $rest '--limit' 50
        $running = if (Test-Flag $rest '--running') { 1 } else { 0 }
        Invoke-Ctl -Path "/ctl/sessions?limit=$limit&running=$running"
    }
    'session' {
        if ($rest.Count -lt 1) { throw 'ctl: session <session-id>' }
        $id = [uri]::EscapeDataString($rest[0])
        Invoke-Ctl -Path "/ctl/session?id=$id"
    }
    'create' {
        $body = @{}
        $cwd = Read-Flag $rest '--cwd' $null
        $preset = Read-Flag $rest '--preset' $null
        if ($cwd) { $body['cwd'] = $cwd }
        if ($preset) { $body['agentPreset'] = $preset }
        Invoke-Ctl -Method POST -Path '/ctl/create' -Body $body
    }
    'prompt' {
        if ($rest.Count -lt 2) { throw 'ctl: prompt <session-id> <text...>' }
        $body = @{ sessionId = $rest[0]; text = ($rest[1..($rest.Count - 1)] -join ' ') }
        Invoke-Ctl -Method POST -Path '/ctl/prompt' -Body $body
    }
    'cancel' {
        if ($rest.Count -lt 1) { throw 'ctl: cancel <session-id>' }
        Invoke-Ctl -Method POST -Path '/ctl/cancel' -Body @{ sessionId = $rest[0] }
    }
    'rename' {
        if ($rest.Count -lt 2) { throw 'ctl: rename <session-id> <title...>' }
        $body = @{ sessionId = $rest[0]; title = ($rest[1..($rest.Count - 1)] -join ' ') }
        Invoke-Ctl -Method POST -Path '/ctl/rename' -Body $body
    }
    'tail' {
        if ($rest.Count -lt 1) { throw 'ctl: tail <session-id> [--frames N] [--ms N]' }
        $frames = Read-Flag $rest '--frames' 40
        $ms = Read-Flag $rest '--ms' 3000
        $id = [uri]::EscapeDataString($rest[0])
        Invoke-Ctl -Path "/ctl/tail?sessionId=$id&frames=$frames&ms=$ms"
    }
    'shape' {
        if ($rest.Count -lt 1) { throw 'ctl: shape <session-id> [--type RECORD_TYPE]' }
        $type = Read-Flag $rest '--type' 'assistant/message'
        $id = [uri]::EscapeDataString($rest[0])
        $encoded = [uri]::EscapeDataString($type)
        Invoke-Ctl -Path "/ctl/debug/shape?sessionId=$id&type=$encoded"
    }
    default { throw "ctl: unknown command $command" }
}
