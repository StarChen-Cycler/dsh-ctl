<#
.SYNOPSIS
    Launch the DSH fleet profile (web app) on Windows.

.DESCRIPTION
    The Windows counterpart of fleet-run.sh. Both do the same two things:
    pick a suitable Node, then exec `dsh <profile> --port <port> --no-open`.

    Differences from the macOS script, and why:

    - macOS needs a Node other than the vendor runtime's, because that runtime is
      hardened-runtime signed and refuses npm's ad-hoc-signed native addon.
      Windows has no such gate, so a normal `node` on PATH is used directly.
    - macOS also needs NODE_PATH pointing at a shim directory, because a pnpm
      *global* install hides the platform package behind symlink realpaths.
      On Windows this deployment installs dsh with npm, whose global layout is
      flat, so the platform package is a real sibling and resolves normally.
      Set DSH_NODE_PATH if you installed via pnpm and hit
      "No usable native binding found".

    Run it from a terminal; it blocks until the server exits.

.PARAMETER Port
    Listen port. Default 17390, or $env:DSH_FLEET_PORT.

.PARAMETER Profile
    Profile name. Default fleet, or $env:DSH_FLEET_PROFILE.
#>
[CmdletBinding()]
param(
    [int]$Port = $(if ($env:DSH_FLEET_PORT) { [int]$env:DSH_FLEET_PORT } else { 17390 }),
    [string]$Profile = $(if ($env:DSH_FLEET_PROFILE) { $env:DSH_FLEET_PROFILE } else { 'fleet' })
)

$ErrorActionPreference = 'Stop'

# --- 1. a Node suitable for dsh (>= 22) -------------------------------------
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    throw 'dsh: node not found on PATH. Install Node.js 22 or newer.'
}

$rawVersion = (& node -v).Trim()
$version = $rawVersion.TrimStart('v')
$major = [int](($version -split '\.')[0])
if ($major -lt 22) {
    throw "dsh: Node $rawVersion is too old; dsh 0.2.1 needs 22 or newer."
}

# --- 2. make the npm global bin reachable ----------------------------------
$npmBin = Join-Path $env:APPDATA 'npm'
if ((Test-Path $npmBin) -and ($env:PATH -notlike "*$npmBin*")) {
    $env:PATH = "$npmBin;$env:PATH"
}

# --- 3. optional NODE_PATH for pnpm-style isolated installs -----------------
if ($env:DSH_NODE_PATH) {
    $env:NODE_PATH = if ($env:NODE_PATH) { "$env:DSH_NODE_PATH;$env:NODE_PATH" } else { $env:DSH_NODE_PATH }
}

$dsh = Get-Command dsh -ErrorAction SilentlyContinue
if (-not $dsh) {
    throw "dsh: the dsh CLI is not on PATH. Install it with: npm install -g @deepseek-ai/dsh@0.2.1-rc.5"
}

Write-Host "node: $rawVersion  ($($node.Source))"
Write-Host "dsh:  $($dsh.Source)"
Write-Host "port: $Port   profile: $Profile"

# --- 4. run ----------------------------------------------------------------
& dsh $Profile --port $Port --no-open
exit $LASTEXITCODE
