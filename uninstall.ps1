# Claude Tab Notifier -- uninstaller
# Removes only what this project's installer added: the hook entries and env key it
# introduced into settings.json (never anything else the user has there), the watcher
# auto-start block from $PROFILE (never anything else in that file), the deployed
# watcher/sound/exe files, and the install manifest. Runtime state under
# %LOCALAPPDATA%\ClaudeTabNotifier\state\ is left alone -- it's debugging data, not
# installed files.
#
# The parameters below default to the exact real paths this uninstaller has always
# used -- running it with no arguments is byte-identical to before. They exist
# solely so an isolated test harness can point every write at sandboxed paths
# instead of the real ~/.claude and %LOCALAPPDATA%, without changing any logic.
param(
    [string]$DeployDir      = (Join-Path $env:LOCALAPPDATA 'ClaudeTabNotifierPOC'),
    [string]$SettingsPath   = (Join-Path $env:USERPROFILE '.claude\settings.json'),
    [string]$ExeDeployPath  = (Join-Path $env:USERPROFILE '.claude\tools\ClaudeAttention.exe'),
    [string]$ProfilePath    = $PROFILE
)

$ErrorActionPreference = 'Stop'

$deployDir       = $DeployDir
$soundsDeployDir = Join-Path $deployDir 'sounds'
$manifestPath    = Join-Path $deployDir 'install-manifest.json'
$settingsPath    = $SettingsPath
$exeDeployPath   = $ExeDeployPath

$envKeyName = 'CLAUDE_CODE_DISABLE_TERMINAL_TITLE'

$hookCommands = [ordered]@{
    'Notification'     = '& "$env:USERPROFILE\.claude\tools\ClaudeAttention.exe" alert'
    'Stop'             = '& "$env:USERPROFILE\.claude\tools\ClaudeAttention.exe" done'
    'UserPromptSubmit' = '& "$env:USERPROFILE\.claude\tools\ClaudeAttention.exe" clear'
}

$profileMarkerStart = '# --- Claude Tab Notifier: auto-start watcher ---'
$profileMarkerEnd   = '# --- end Claude Tab Notifier ---'

function Backup-FileIfExists {
    param([string]$Path)
    if (Test-Path $Path) {
        $backupPath = "$Path.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -Path $Path -Destination $backupPath -Force
        Write-Host "  backed up: $Path -> $backupPath"
        return $backupPath
    }
    return $null
}

Write-Host "=== Claude Tab Notifier -- uninstaller ===" -ForegroundColor Cyan
Write-Host ""

# --- 1. settings.json: remove our hook entries, restore/remove the env key ---
Write-Host "[1/4] Updating Claude Code settings.json ..." -ForegroundColor Yellow

if (Test-Path $settingsPath) {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    $settingsChanged = $false

    $manifest = $null
    if (Test-Path $manifestPath) {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    }

    if ($settings.PSObject.Properties['hooks']) {
        foreach ($eventName in $hookCommands.Keys) {
            $cmd = $hookCommands[$eventName]
            if ($settings.hooks.PSObject.Properties[$eventName]) {
                $groups = @($settings.hooks.$eventName)
                $newGroups = @()
                foreach ($group in $groups) {
                    $remainingHooks = @($group.hooks | Where-Object { $_.command -ne $cmd })
                    if ($remainingHooks.Count -gt 0) {
                        $group.hooks = $remainingHooks
                        $newGroups += $group
                    }
                }
                if (@($groups).Count -ne @($newGroups).Count) {
                    $settingsChanged = $true
                    Write-Host "  removed hook: $eventName"
                }
                $settings.hooks.$eventName = $newGroups
            }
        }
    }

    if ($settings.PSObject.Properties['env'] -and $settings.env.PSObject.Properties[$envKeyName]) {
        if ($null -ne $manifest -and $manifest.PSObject.Properties['envKeyExistedBefore']) {
            if ($manifest.envKeyExistedBefore) {
                if ($settings.env.$envKeyName -ne $manifest.envKeyPreviousValue) {
                    $settings.env.$envKeyName = $manifest.envKeyPreviousValue
                    $settingsChanged = $true
                    Write-Host "  restored env.$envKeyName to its original value: $($manifest.envKeyPreviousValue)"
                }
            } else {
                $settings.env.PSObject.Properties.Remove($envKeyName)
                $settingsChanged = $true
                Write-Host "  removed env.$envKeyName (installer had added it from nothing)"
            }
        } else {
            Write-Host "  [WARNING] no install manifest found -- leaving env.$envKeyName untouched (cannot safely determine its original state)" -ForegroundColor DarkYellow
        }
    }

    if ($settingsChanged) {
        Backup-FileIfExists $settingsPath
        $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath -Encoding utf8
        Write-Host "  settings.json updated"
    } else {
        Write-Host "  settings.json had nothing of ours to remove"
    }
} else {
    Write-Host "  settings.json does not exist -- nothing to do"
}
Write-Host ""

# --- 2. $PROFILE: remove exactly our marker block ---
Write-Host "[2/4] Updating PowerShell profile ..." -ForegroundColor Yellow

if (Test-Path $ProfilePath) {
    $profileContent = Get-Content $ProfilePath -Raw
    if ($profileContent -like "*$profileMarkerStart*") {
        Backup-FileIfExists $ProfilePath
        $pattern = "\r?\n?" + [regex]::Escape($profileMarkerStart) + "(?s:.*?)" + [regex]::Escape($profileMarkerEnd) + "\r?\n?"
        $newContent = [regex]::Replace($profileContent, $pattern, '')
        Set-Content -Path $ProfilePath -Value $newContent -Encoding utf8 -NoNewline
        Write-Host "  removed watcher auto-start block from `$PROFILE"
    } else {
        Write-Host "  `$PROFILE has no watcher auto-start block -- nothing to do"
    }
} else {
    Write-Host "  `$PROFILE does not exist -- nothing to do"
}
Write-Host ""

# --- 3. remove deployed assets ---
Write-Host "[3/4] Removing deployed files ..." -ForegroundColor Yellow

$knownSoundNames = @('classic','chime','soft','alert','retro','magic','digital','double','scifi','success')
$soundFilesToRemove = @($knownSoundNames | ForEach-Object { Join-Path $soundsDeployDir "$_.wav" })
$soundFilesToRemove += (Join-Path $soundsDeployDir 'SOUNDS.md')

$filesToRemove = @(
    (Join-Path $deployDir 'watcher-background.ps1'),
    (Join-Path $deployDir 'taskbar-badge.ps1'),
    (Join-Path $deployDir 'test-sound.ps1'),
    (Join-Path $deployDir 'config.json'),
    $manifestPath,
    $exeDeployPath
) + $soundFilesToRemove

foreach ($f in $filesToRemove) {
    if (Test-Path $f) {
        Remove-Item $f -Force
        Write-Host "  removed: $f"
    }
}

if ((Test-Path $soundsDeployDir) -and (@(Get-ChildItem $soundsDeployDir -Force).Count -eq 0)) {
    Remove-Item $soundsDeployDir -Force
    Write-Host "  removed empty directory: $soundsDeployDir"
}
if ((Test-Path $deployDir) -and (@(Get-ChildItem $deployDir -Force).Count -eq 0)) {
    Remove-Item $deployDir -Force
    Write-Host "  removed empty directory: $deployDir"
} elseif (Test-Path $deployDir) {
    Write-Host "  left in place (contains other files not installed by us): $deployDir"
}
Write-Host ""

# --- 4. verify ---
Write-Host "[4/4] Verifying removal ..." -ForegroundColor Yellow
$allOk = $true

function Test-Step {
    param([string]$Label, [bool]$Condition)
    if ($Condition) {
        Write-Host "  [OK] $Label"
    } else {
        Write-Host "  [FAIL] $Label" -ForegroundColor Red
        $script:allOk = $false
    }
}

Test-Step "ClaudeAttention.exe removed" (-not (Test-Path $exeDeployPath))
Test-Step "watcher-background.ps1 removed" (-not (Test-Path (Join-Path $deployDir 'watcher-background.ps1')))
Test-Step "taskbar-badge.ps1 removed" (-not (Test-Path (Join-Path $deployDir 'taskbar-badge.ps1')))

$settingsOk = $true
if (Test-Path $settingsPath) {
    $verifySettings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    foreach ($eventName in $hookCommands.Keys) {
        $cmd = $hookCommands[$eventName]
        foreach ($group in @($verifySettings.hooks.$eventName)) {
            foreach ($h in @($group.hooks)) {
                if ($h.command -eq $cmd) { $settingsOk = $false }
            }
        }
    }
}
Test-Step "settings.json no longer contains our hooks" $settingsOk

$profileOk = $true
if (Test-Path $ProfilePath) {
    $verifyProfileContent = Get-Content $ProfilePath -Raw
    if ($verifyProfileContent -like "*$profileMarkerStart*") { $profileOk = $false }
}
Test-Step "`$PROFILE no longer contains the watcher block" $profileOk

Write-Host ""
if ($allOk) {
    Write-Host "=== Uninstall SUCCEEDED ===" -ForegroundColor Green
    exit 0
} else {
    Write-Host "=== Uninstall FAILED -- see [FAIL] lines above ===" -ForegroundColor Red
    exit 1
}
