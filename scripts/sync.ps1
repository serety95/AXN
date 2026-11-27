<#
.SYNOPSIS
    Idempotent multi-runtime symlink manager for AXN on Windows.
.EXAMPLE
    .\scripts\sync.ps1 -DryRun
    .\scripts\sync.ps1 -Claude -WireHooks
    .\scripts\sync.ps1 -Profile full
    .\scripts\sync.ps1 -Uninstall -WireHooks
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$WireHooks,
    [switch]$Claude,
    [switch]$Cursor,
    [switch]$Codex,
    [ValidateSet('minimal', 'core', 'developer', 'security', 'full')]
    [string]$Profile = 'core'
)

$ErrorActionPreference = 'Stop'

if (-not $Claude -and -not $Cursor -and -not $Codex) {
    $Claude = $true
    $Cursor = $true
    $Codex  = $true
}

$AxnRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Timestamp = Get-Date -Format 'yyyyMMddHHmmss'

function Get-ManifestPlan {
    $profilesPath = Join-Path $AxnRoot 'manifests\install-profiles.json'
    $modulesPath = Join-Path $AxnRoot 'manifests\install-modules.json'
    $profilesDoc = Get-Content -LiteralPath $profilesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $modulesDoc = Get-Content -LiteralPath $modulesPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $profileObj = $profilesDoc.profiles.$Profile
    if ($null -eq $profileObj) {
        throw "Profile '$Profile' not found in $profilesPath"
    }

    $activeMods = @($profileObj.modules)
    $modMap = @{}
    foreach ($m in $modulesDoc.modules) {
        $modMap[$m.id] = $m
    }

    $skillsMode = 'none'
    $allowedSkills = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($mid in $activeMods) {
        $mod = $modMap[$mid]
        if ($null -eq $mod) { continue }
        $paths = @($mod.paths)
        if ($mid -eq 'all-skills' -or ($paths -contains 'skills/')) {
            $skillsMode = 'all'
        } elseif ($mod.kind -eq 'skill') {
            if ($skillsMode -ne 'all') { $skillsMode = 'list' }
            foreach ($p in $paths) {
                if ($p -is [string] -and $p.StartsWith('skills/')) {
                    $sname = $p.Substring('skills/'.Length).Trim('/')
                    if ($sname) { [void]$allowedSkills.Add($sname) }
                }
            }
        }
    }

    return @{
        Modules = $activeMods
        SkillsMode = $skillsMode
        AllowedSkills = $allowedSkills
    }
}

$Plan = Get-ManifestPlan

function Test-HasModule {
    param([string]$ModuleId)
    return ($Plan.Modules -contains $ModuleId)
}

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

function Test-SkillAllowed {
    param([string]$Name)
    if ($Plan.SkillsMode -eq 'all') { return $true }
    if ($Plan.SkillsMode -eq 'list') { return $Plan.AllowedSkills.Contains($Name) }
    return $false
}

function Sync-Skills {
    param([string]$TargetDir)
    if ($Plan.SkillsMode -eq 'none' -and -not $Uninstall) { return }
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
    if (-not (Test-HasModule 'core-agents') -and -not $Uninstall) { return }
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

function Invoke-WireClaudeHooks {
    $settingsPath = Join-Path $HOME '.claude\settings.json'
    if (Test-Path -LiteralPath $settingsPath) {
        $item = Get-Item -LiteralPath $settingsPath -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Write-Warning "Refusing to modify symlinked $settingsPath"
            return
        }
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $python) {
        Write-Warning "python/python3 not found; skipping -WireHooks for $settingsPath"
        return
    }

    $pyScript = @'
import json, os, shutil, sys, tempfile

settings_path, uninstall_flag, dry_run_flag, ts = sys.argv[1:5]
uninstall = uninstall_flag == "1"
dry_run = dry_run_flag == "1"

AXN_HOOKS = [
    ("PreToolUse", "Bash|Write|Edit|Read", "~/.claude/hooks/pre-tool-use/blast-radius-guard.sh"),
    ("PreToolUse", "Write|Edit", "~/.claude/hooks/pre-tool-use/config-protection.sh"),
    ("PreToolUse", "Read|Bash", "~/.claude/hooks/pre-tool-use/token-budget-guard.sh"),
    ("PostToolUse", "Edit|Write", "~/.claude/hooks/post-tool-use/auto-verify-loop.sh"),
    ("Stop", None, "~/.claude/hooks/stop/stop-gate-verifier.sh"),
    ("Stop", None, "~/.claude/hooks/stop/orchestrator-feedback.sh"),
]
AXN_COMMANDS = {cmd for _, _, cmd in AXN_HOOKS}

if os.path.isfile(settings_path):
    with open(settings_path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError(f"{settings_path} must contain a JSON object")
else:
    if uninstall:
        print(f"[ok] no settings.json to unwire: {settings_path}")
        sys.exit(0)
    data = {}

hooks_obj = data.setdefault("hooks", {})
changed = 0

if uninstall:
    for event in ("PreToolUse", "PostToolUse", "Stop"):
        entries = hooks_obj.get(event)
        if not isinstance(entries, list):
            continue
        kept = []
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
                kept.append(entry)
                continue
            new_hooks = [h for h in entry["hooks"] if not (isinstance(h, dict) and h.get("command") in AXN_COMMANDS)]
            changed += len(entry["hooks"]) - len(new_hooks)
            if new_hooks:
                u = dict(entry)
                u["hooks"] = new_hooks
                kept.append(u)
        if kept:
            hooks_obj[event] = kept
        else:
            hooks_obj.pop(event, None)
    if not hooks_obj:
        data.pop("hooks", None)
    action_label = "unwired"
else:
    for event, matcher, cmd in AXN_HOOKS:
        entries = hooks_obj.setdefault(event, [])
        exists = any(
            isinstance(e, dict) and any(isinstance(h, dict) and h.get("command") == cmd for h in e.get("hooks", []))
            for e in entries
        )
        if exists:
            continue
        if matcher is None:
            stop_entry = next((e for e in entries if isinstance(e, dict) and "matcher" not in e and isinstance(e.get("hooks"), list)), None)
            item = {"type": "command", "command": cmd}
            if stop_entry is not None:
                stop_entry["hooks"].append(item)
            else:
                entries.append({"hooks": [item]})
        else:
            entries.append({"matcher": matcher, "hooks": [{"type": "command", "command": cmd}]})
        changed += 1
    action_label = "wired"

if changed == 0:
    print(f"[ok] hooks already {action_label}: {settings_path}")
    sys.exit(0)

prefix = "[dry-run] " if dry_run else ""
if os.path.isfile(settings_path):
    bak_path = f"{settings_path}.bak.{ts}"
    print(f"{prefix}[backup] {settings_path} -> {bak_path}")
    if not dry_run:
        shutil.copy2(settings_path, bak_path)

print(f"{prefix}[wire-hooks] {action_label} {changed} hook(s) in {settings_path}")
if not dry_run:
    parent = os.path.dirname(settings_path)
    os.makedirs(parent, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".settings-", suffix=".tmp", dir=parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        os.replace(tmp_path, settings_path)
    except Exception:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise
'@
    $pyScript | & $python.Source - $settingsPath ($(if ($Uninstall) { '1' } else { '0' })) ($(if ($DryRun) { '1' } else { '0' })) $Timestamp
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to wire hooks into $settingsPath"
    }
}

Write-Host "AXN Root: $AxnRoot (profile=$Profile, dry_run=$DryRun, uninstall=$Uninstall, wire_hooks=$WireHooks)"

if ($Claude) {
    $base = Join-Path $HOME '.claude'
    Write-Host "=== Claude Code ($base) ==="
    if ($Uninstall) {
        Unlink-Item (Join-Path $base 'CLAUDE.md')
        Unlink-Item (Join-Path $base 'cost-tiers.yaml')
        Unlink-Item (Join-Path $base 'hooks')
        Unlink-Item (Join-Path $base 'commands')
        Unlink-Item (Join-Path $base 'rules')
        Unlink-Item (Join-Path $base 'contexts')
        Sync-Skills (Join-Path $base 'skills')
        Sync-Agents (Join-Path $base 'agents') 'md'
    } else {
        Link-Item (Join-Path $AxnRoot 'templates\GLOBAL_AGENTS.md') (Join-Path $base 'CLAUDE.md')
        Link-Item (Join-Path $AxnRoot 'config\cost-tiers.yaml') (Join-Path $base 'cost-tiers.yaml')
        Link-Item (Join-Path $AxnRoot 'hooks') (Join-Path $base 'hooks')
        if (Test-HasModule 'core-commands') {
            Link-Item (Join-Path $AxnRoot 'commands') (Join-Path $base 'commands')
        }
        if (Test-HasModule 'core-rules') {
            Link-Item (Join-Path $AxnRoot 'rules') (Join-Path $base 'rules')
        }
        if (Test-HasModule 'core-contexts') {
            Link-Item (Join-Path $AxnRoot 'contexts') (Join-Path $base 'contexts')
        }
        Sync-Skills (Join-Path $base 'skills')
        Sync-Agents (Join-Path $base 'agents') 'md'
    }
    if ($WireHooks) {
        Invoke-WireClaudeHooks
    }
}

if ($Cursor) {
    $base = Join-Path $HOME '.cursor'
    Write-Host "=== Cursor ($base) ==="
    if ($Uninstall) {
        Unlink-Item (Join-Path $base 'rules\global.mdc')
        Unlink-Item (Join-Path $base 'cost-tiers.yaml')
        Unlink-Item (Join-Path $base 'hooks')
        Unlink-Item (Join-Path $base 'commands')
        Sync-Skills (Join-Path $base 'skills')
        Sync-Agents (Join-Path $base 'rules') 'mdc'
    } else {
        Link-Item (Join-Path $AxnRoot 'templates\GLOBAL_AGENTS.md') (Join-Path $base 'rules\global.mdc')
        Link-Item (Join-Path $AxnRoot 'config\cost-tiers.yaml') (Join-Path $base 'cost-tiers.yaml')
        Link-Item (Join-Path $AxnRoot 'hooks') (Join-Path $base 'hooks')
        if (Test-HasModule 'core-commands') {
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
        Unlink-Item (Join-Path $base 'cost-tiers.yaml')
        Sync-Skills (Join-Path $base 'skills')
    } else {
        Link-Item (Join-Path $AxnRoot 'templates\GLOBAL_AGENTS.md') (Join-Path $base 'AGENTS.md')
        Link-Item (Join-Path $AxnRoot 'config\cost-tiers.yaml') (Join-Path $base 'cost-tiers.yaml')
        Sync-Skills (Join-Path $base 'skills')
    }
}

if (-not $Uninstall) {
    Write-Host ""
    Write-Host "=== 4-Tier Multi-Provider Cost Routing Hints (optional env/profile setup) ==="
    Write-Host '  Claude Code : $env:CLAUDE_CODE_SUBAGENT_MODEL = "haiku" (and alias cc -> claude --model opusplan)'
    Write-Host '  Codex CLI   : T1=gpt-6-luna | T2=gpt-6-sol (default) | T3=gpt-6-astra'
    Write-Host '  Cursor      : T1=cost (Composer 2.5) | T2=balance (sonnet) | T3=intelligence (opus / Grok 4.7)'
    Write-Host '  Gemini CLI  : T1=flash-lite/flash | T2=pro/medium | T3=pro/deep'
    Write-Host '  OpenCode    : T1=fast | T2=standard | T3=frontier'
    Write-Host '  Local ($0)  : MLX / LM Studio Qwen3.5-9B or Ollama (http://localhost:1234/v1)'
}

Write-Host 'Done.'
