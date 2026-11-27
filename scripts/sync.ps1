<#
.SYNOPSIS
    Idempotent multi-runtime symlink manager for AXN on Windows.
.EXAMPLE
    .\scripts\sync.ps1 -DryRun
    .\scripts\sync.ps1 -Claude -Codex
    .\scripts\sync.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$Claude,
    [switch]$Cursor,
    [switch]$Codex,
    [ValidateSet('minimal', 'core', 'developer', 'security', 'full')]
    [string]$Profile = 'full'
)

$ErrorActionPreference = 'Stop'

if (-not $Claude -and -not $Cursor -and -not $Codex) {
    $Claude = $true
    $Cursor = $true
    $Codex  = $true
}

$AxnRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Timestamp = Get-Date -Format 'yyyyMMddHHmmss'

function Write-Action {
    param([string]$Message)
    if ($DryRun) {
        Write-Host "[dry-run] $Message"
    } else {
        Write-Host $Message
    }
}

function Test-ManagedSymlink {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $target = $item.Target
    if ($target -is [array]) { $target = $target[0] }
    return ($null -ne $target -and $target.StartsWith($AxnRoot, [StringComparison]::OrdinalIgnoreCase))
}

function Link-Item {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source)) { return }

    $parent = Split-Path -Parent $Destination
    if (Test-Path -LiteralPath $Destination) {
        $item = Get-Item -LiteralPath $Destination -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $curTarget = $item.Target
            if ($curTarget -is [array]) { $curTarget = $curTarget[0] }
            if ($curTarget -and $curTarget.Equals($Source, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Host "[ok] already linked: $Destination"
                return
            }
            if ($curTarget -and $curTarget.StartsWith($AxnRoot, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Action "[update] $Destination -> $Source"
                if (-not $DryRun) {
                    Remove-Item -LiteralPath $Destination -Force
                    New-Item -ItemType SymbolicLink -Path $Destination -Target $Source | Out-Null
                }
                return
            }
        }
        $backup = "$Destination.bak.$Timestamp"
        Write-Action "[backup] $Destination -> $backup"
        if (-not $DryRun) {
            Move-Item -LiteralPath $Destination -Destination $backup -Force
        }
    }

    Write-Action "[link] $Destination -> $Source"
    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        try {
            New-Item -ItemType SymbolicLink -Path $Destination -Target $Source -ErrorAction Stop | Out-Null
        } catch {
            Write-Error "Failed to create symlink '$Destination' -> '$Source'. Enable Windows Developer Mode or run as Administrator. Details: $_"
        }
    }
}

function Unlink-Item {
    param([string]$Destination)
    if (Test-ManagedSymlink -Path $Destination) {
        Write-Action "[unlink] $Destination"
        if (-not $DryRun) {
            Remove-Item -LiteralPath $Destination -Force
        }
    }
}

function Test-IncludeAgents {
    return ($Profile -in @('core', 'developer', 'full'))
}

function Test-IncludeSkills {
    return ($Profile -ne 'minimal')
}

function Test-SkillAllowed {
    param([string]$Name)
    if ($Profile -eq 'core') {
        return ($Name -in @('repo-map-compressor', 'adversarial-diff-audit', 'roi-loop-orchestrator', 'software-architect'))
    }
    if ($Profile -eq 'security') {
        return ($Name -in @('repo-map-compressor', 'adversarial-diff-audit', 'agent-security-hardening'))
    }
    return $true
}

function Sync-Skills {
    param([string]$TargetDir)
    if (-not (Test-IncludeSkills) -and -not $Uninstall) { return }
    $skillsRoot = Join-Path $AxnRoot 'skills'
    if (-not (Test-Path -LiteralPath $skillsRoot)) { return }
    foreach ($dir in Get-ChildItem -LiteralPath $skillsRoot -Directory) {
        $dst = Join-Path $TargetDir $dir.Name
        if ($Uninstall) {
            Unlink-Item -Destination $dst
        } elseif (Test-SkillAllowed -Name $dir.Name) {
            Link-Item -Source $dir.FullName -Destination $dst
        }
    }
}

function Sync-Agents {
    param([string]$TargetDir, [string]$Ext)
    if (-not (Test-IncludeAgents) -and -not $Uninstall) { return }
    $agentsRoot = Join-Path $AxnRoot 'agents'
    if (-not (Test-Path -LiteralPath $agentsRoot)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $agentsRoot -Filter '*.md' -File) {
        $dst = Join-Path $TargetDir "$($file.BaseName).$Ext"
        if ($Uninstall) {
            Unlink-Item -Destination $dst
        } else {
            Link-Item -Source $file.FullName -Destination $dst
        }
    }
}

Write-Host "AXN Root: $AxnRoot (profile=$Profile, dry_run=$DryRun, uninstall=$Uninstall)"

if ($Claude) {
    $base = Join-Path $HOME '.claude'
    Write-Host "=== Claude Code ($base) ==="
    if ($Uninstall) {
        Unlink-Item (Join-Path $base 'CLAUDE.md')
        Unlink-Item (Join-Path $base 'hooks')
        Unlink-Item (Join-Path $base 'commands')
        Unlink-Item (Join-Path $base 'rules')
        Unlink-Item (Join-Path $base 'contexts')
        Sync-Skills (Join-Path $base 'skills')
        Sync-Agents (Join-Path $base 'agents') 'md'
    } else {
        Link-Item (Join-Path $AxnRoot 'templates\GLOBAL_AGENTS.md') (Join-Path $base 'CLAUDE.md')
        Link-Item (Join-Path $AxnRoot 'hooks') (Join-Path $base 'hooks')
        if ($Profile -in @('developer', 'full')) {
            Link-Item (Join-Path $AxnRoot 'commands') (Join-Path $base 'commands')
        }
        if ($Profile -ne 'minimal') {
            Link-Item (Join-Path $AxnRoot 'rules') (Join-Path $base 'rules')
        }
        if ($Profile -in @('core', 'developer', 'full')) {
            Link-Item (Join-Path $AxnRoot 'contexts') (Join-Path $base 'contexts')
        }
        Sync-Skills (Join-Path $base 'skills')
        Sync-Agents (Join-Path $base 'agents') 'md'
    }
}

if ($Cursor) {
    $base = Join-Path $HOME '.cursor'
    Write-Host "=== Cursor ($base) ==="
    if ($Uninstall) {
        Unlink-Item (Join-Path $base 'rules\global.mdc')
        Unlink-Item (Join-Path $base 'hooks')
        Unlink-Item (Join-Path $base 'commands')
        Sync-Skills (Join-Path $base 'skills')
        Sync-Agents (Join-Path $base 'rules') 'mdc'
    } else {
        Link-Item (Join-Path $AxnRoot 'templates\GLOBAL_AGENTS.md') (Join-Path $base 'rules\global.mdc')
        Link-Item (Join-Path $AxnRoot 'hooks') (Join-Path $base 'hooks')
        if ($Profile -in @('developer', 'full')) {
            Link-Item (Join-Path $AxnRoot 'commands') (Join-Path $base 'commands')
        }
        Sync-Skills (Join-Path $base 'skills')
        Sync-Agents (Join-Path $base 'rules') 'mdc'
    }
}

if ($Codex) {
    $base = Join-Path $HOME '.codex'
    Write-Host "=== Codex CLI ($base) ==="
    if ($Uninstall) {
        Unlink-Item (Join-Path $base 'AGENTS.md')
        Sync-Skills (Join-Path $base 'skills')
    } else {
        Link-Item (Join-Path $AxnRoot 'templates\GLOBAL_AGENTS.md') (Join-Path $base 'AGENTS.md')
        Sync-Skills (Join-Path $base 'skills')
    }
}

Write-Host 'Done.'
