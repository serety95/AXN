<#
.SYNOPSIS
    PowerShell validation wrapper for AXN on Windows.
    Runs native JSON, personal-path, Unicode safety, frontmatter, and secret checks,
    plus bash -n if bash is available.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$AxnRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }

$validateSh = Join-Path $PSScriptRoot 'validate.sh'
$bash = Get-Command bash -ErrorAction SilentlyContinue

if ($bash) {
    Write-Host "Running validate.sh via bash..."
    & $bash.Source $validateSh
    exit $LASTEXITCODE
}

if (-not $python) {
    Write-Error "Neither bash nor python was found on PATH to run AXN validation."
    exit 1
}

Write-Error "bash not found; please run ./scripts/validate.sh from Git Bash or WSL."
exit 1
