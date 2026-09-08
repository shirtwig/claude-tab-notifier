# Claude Tab Notifier -- installer
# Deploys the hook, watcher, sound assets, and wires Claude Code hooks + settings +
# $PROFILE auto-start. Safe to run multiple times: every step checks for an existing
# installation before changing anything, and only backs up a file when it is actually
# about to be modified.
#
# The parameters below default to the exact real paths this installer has always
# used -- running it with no arguments is byte-identical to before. They exist
# solely so an isolated test harness can point every write at sandboxed paths
# instead of the real ~/.claude and %LOCALAPPDATA%, without changing any logic.
param(
    [string]$DeployDir     = (Join-Path $env:LOCALAPPDATA 'ClaudeTabNotifierPOC'),
    [string]$SettingsPath  = (Join-Path $env:USERPROFILE '.claude\settings.json'),
    [string]$ToolsDir      = (Join-Path $env:USERPROFILE '.claude\tools'),
    [string]$ProfilePath   = $PROFILE,
    # When given, skips the real "dotnet publish" build and deploys this file as
    # the hook exe instead -- lets a test harness verify deployment/wiring logic
    # without requiring/paying for a real .NET build on every test run.
    [string]$SourceExePath = $null
)

$ErrorActionPreference = 'Stop'

$deployDir       = $DeployDir
$soundsDeployDir = Join-Path $deployDir 'sounds'
$manifestPath    = Join-Path $deployDir 'install-manifest.json'
$settingsPath    = $SettingsPath
$toolsDir        = $ToolsDir
$exeDeployPath   = Join-Path $toolsDir 'ClaudeAttention.exe'

$envKeyName  = 'CLAUDE_CODE_DISABLE_TERMINAL_TITLE'
$envKeyValue = '1'

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

Write-Host "=== Claude Tab Notifier -- installer ===" -ForegroundColor Cyan
Write-Host ""

# --- 1. build and deploy the hook exe ---
if ($SourceExePath) {
    Write-Host "[1/5] Deploying provided hook exe (build skipped: -SourceExePath given) ..." -ForegroundColor Yellow
    if (-not (Test-Path $SourceExePath)) {
        Write-Host "[FAIL] -SourceExePath not found: $SourceExePath" -ForegroundColor Red
        exit 1
    }
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    Copy-Item -Path $SourceExePath -Destination $exeDeployPath -Force
    Unblock-File -Path $exeDeployPath
    Write-Host "  deployed: $exeDeployPath"
    Write-Host ""
} else {
    Write-Host "[1/5] Building ClaudeAttention.exe ..." -ForegroundColor Yellow
    $dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnetCmd) {
        Write-Host "[FAIL] dotnet CLI not found on PATH. Install the .NET SDK first." -ForegroundColor Red
        exit 1
    }

    Push-Location $PSScriptRoot
    try {
        dotnet publish -c Release | Out-Host
    } finally {
        Pop-Location
    }

    $publishedExe = Join-Path $PSScriptRoot 'bin\Release\net9.0-windows\win-x64\publish\ClaudeAttention.exe'
    if (-not (Test-Path $publishedExe)) {
        Write-Host "[FAIL] Expected published exe not found at: $publishedExe" -ForegroundColor Red
        exit 1
    }

    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    Copy-Item -Path $publishedExe -Destination $exeDeployPath -Force
    Unblock-File -Path $exeDeployPath
    Write-Host "  deployed: $exeDeployPath"
    Write-Host ""
}

# --- 2. deploy watcher, sound, config assets ---
Write-Host "[2/5] Deploying watcher and sound assets ..." -ForegroundColor Yellow
New-Item -ItemType Directory -Path $soundsDeployDir -Force | Out-Null

Copy-Item -Path (Join-Path $PSScriptRoot 'watcher-background.ps1') -Destination (Join-Path $deployDir 'watcher-background.ps1') -Force
Copy-Item -Path (Join-Path $PSScriptRoot 'test-sound.ps1')         -Destination (Join-Path $deployDir 'test-sound.ps1') -Force

$soundsSourceDir = Join-Path $PSScriptRoot 'sounds'
$soundAssets = Get-ChildItem -Path $soundsSourceDir -File
foreach ($asset in $soundAssets) {
    Copy-Item -Path $asset.FullName -Destination (Join-Path $soundsDeployDir $asset.Name) -Force
}
Write-Host "  deployed: watcher-background.ps1, test-sound.ps1, $($soundAssets.Count) files in sounds\ ($($soundAssets.Name -join ', '))"

$deployedConfigPath = Join-Path $deployDir 'config.json'
if (-not (Test-Path $deployedConfigPath)) {
    Copy-Item -Path (Join-Path $PSScriptRoot 'config.json') -Destination $deployedConfigPath -Force
    Write-Host "  deployed: config.json (fresh copy)"
} else {
    Write-Host "  config.json already exists at deployment location -- left untouched (preserves any customization)"
}

# A user who installs from a downloaded GitHub ZIP (rather than a git clone)
# gets every extracted file tagged with Windows' "Mark of the Web" (a
# Zone.Identifier NTFS stream, ZoneId=3 "Internet"). Copy-Item preserves that
# tag onto the deployed copies. Under the common RemoteSigned execution
# policy, an internet-zone-tagged .ps1 must be signed to run -- ours isn't,
# so the watcher would silently fail to auto-start with "is not digitally
# signed" (confirmed via a real install from a downloaded ZIP). Unblock-File
# strips that tag from everything just deployed; it's a safe no-op on files
# that were never tagged (e.g. a git-clone install), and does not touch the
# user's system-wide execution policy at all.
Get-ChildItem -Path $deployDir -Recurse -File | Unblock-File
Write-Host "  unblocked deployed files (removes 'Mark of the Web' from a downloaded ZIP, if present)"
Write-Host ""

# --- 3. merge into settings.json (hooks + env), with manifest tracking for the env key ---
Write-Host "[3/5] Updating Claude Code settings.json ..." -ForegroundColor Yellow

$settings = $null
if (Test-Path $settingsPath) {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
} else {
    $settings = [PSCustomObject]@{}
}

if (-not $settings.PSObject.Properties['hooks']) {
    $settings | Add-Member -MemberType NoteProperty -Name 'hooks' -Value ([PSCustomObject]@{})
}

$hooksChanged = $false
foreach ($eventName in $hookCommands.Keys) {
    $cmd = $hookCommands[$eventName]

    if (-not $settings.hooks.PSObject.Properties[$eventName]) {
        $settings.hooks | Add-Member -MemberType NoteProperty -Name $eventName -Value @()
    }

    $existingGroups = @($settings.hooks.$eventName)
    $alreadyPresent = $false
    foreach ($group in $existingGroups) {
        foreach ($h in @($group.hooks)) {
            if ($h.command -eq $cmd) { $alreadyPresent = $true }
        }
    }

    if (-not $alreadyPresent) {
        $newGroup = [PSCustomObject]@{
            hooks = @(
                [PSCustomObject]@{
                    type    = 'command'
                    command = $cmd
                    shell   = 'powershell'
                }
            )
        }
        $settings.hooks.$eventName = @($existingGroups) + $newGroup
        $hooksChanged = $true
        Write-Host "  added hook: $eventName"
    } else {
        Write-Host "  hook already present: $eventName (skipped)"
    }
}

if (-not $settings.PSObject.Properties['env']) {
    $settings | Add-Member -MemberType NoteProperty -Name 'env' -Value ([PSCustomObject]@{})
}

$currentEnvValue = $null
if ($settings.env.PSObject.Properties[$envKeyName]) {
    $currentEnvValue = $settings.env.$envKeyName
}

# Only capture the pre-installation history ONCE. On a re-install, the manifest
# already reflects the true original state -- never overwrite it with what is by
# then our own "1" value, or the original would be lost.
$manifest = $null
if (Test-Path $manifestPath) {
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
} else {
    $manifest = [PSCustomObject]@{
        installedAt         = (Get-Date -Format o)
        envKey               = $envKeyName
        envKeyExistedBefore  = ($null -ne $currentEnvValue)
        envKeyPreviousValue  = $currentEnvValue
    }
}

$envChanged = $false
if ($currentEnvValue -ne $envKeyValue) {
    if ($settings.env.PSObject.Properties[$envKeyName]) {
        $settings.env.$envKeyName = $envKeyValue
    } else {
        $settings.env | Add-Member -MemberType NoteProperty -Name $envKeyName -Value $envKeyValue
    }
    $envChanged = $true
    Write-Host "  set env.$envKeyName = $envKeyValue"
} else {
    Write-Host "  env.$envKeyName already = $envKeyValue (skipped)"
}

if ($hooksChanged -or $envChanged) {
    Backup-FileIfExists $settingsPath
    $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath -Encoding utf8
    Write-Host "  settings.json updated"
} else {
    Write-Host "  settings.json already up to date -- no changes made"
}

# manifest is written/refreshed regardless (safe: history fields are only ever set once)
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding utf8
Write-Host ""

# --- 4. add watcher auto-start to $PROFILE ---
Write-Host "[4/5] Updating PowerShell profile ..." -ForegroundColor Yellow

$profileBlockLines = @(
    $profileMarkerStart,
    'if (-not $global:ClaudeTabNotifierWatcherStarted) {',
    '    $global:ClaudeTabNotifierWatcherStarted = $true',
    '    try {',
    "        `$claudeTabNotifierWatcherScript = Join-Path `$env:LOCALAPPDATA 'ClaudeTabNotifierPOC\watcher-background.ps1'",
    '        if (Test-Path $claudeTabNotifierWatcherScript) {',
    '            & $claudeTabNotifierWatcherScript',
    '        }',
    '    } catch {',
    '        Write-Host "Claude Tab Notifier: watcher failed to start ($($_.Exception.Message))" -ForegroundColor DarkYellow',
    '    }',
    '}',
    $profileMarkerEnd
)
$profileBlock = $profileBlockLines -join "`r`n"

$profileExists = Test-Path $ProfilePath
$profileContent = if ($profileExists) { Get-Content $ProfilePath -Raw } else { '' }
$profileHasMarker = $profileContent -like "*$profileMarkerStart*"

if (-not $profileHasMarker) {
    Backup-FileIfExists $ProfilePath
    $profileDir = Split-Path $ProfilePath -Parent
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    if (-not $profileExists -or $profileContent.Trim().Length -eq 0) {
        Set-Content -Path $ProfilePath -Value $profileBlock -Encoding utf8
    } else {
        Add-Content -Path $ProfilePath -Value "`r`n$profileBlock" -Encoding utf8
    }
    Write-Host "  added watcher auto-start block to `$PROFILE"
} else {
    Write-Host "  `$PROFILE already contains the watcher auto-start block (skipped)"
}
Write-Host ""

# --- 5. verify ---
Write-Host "[5/5] Verifying installation ..." -ForegroundColor Yellow
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

Test-Step "ClaudeAttention.exe deployed"      (Test-Path $exeDeployPath)
Test-Step "watcher-background.ps1 deployed"   (Test-Path (Join-Path $deployDir 'watcher-background.ps1'))
Test-Step "test-sound.ps1 deployed"           (Test-Path (Join-Path $deployDir 'test-sound.ps1'))
foreach ($asset in $soundAssets) {
    Test-Step "sounds\$($asset.Name) deployed" (Test-Path (Join-Path $soundsDeployDir $asset.Name))
}
Test-Step "config.json deployed"              (Test-Path $deployedConfigPath)

$verifySettings = Get-Content $settingsPath -Raw | ConvertFrom-Json
$hooksOk = $true
foreach ($eventName in $hookCommands.Keys) {
    $cmd = $hookCommands[$eventName]
    $found = $false
    foreach ($group in @($verifySettings.hooks.$eventName)) {
        foreach ($h in @($group.hooks)) {
            if ($h.command -eq $cmd) { $found = $true }
        }
    }
    if (-not $found) { $hooksOk = $false }
}
Test-Step "settings.json contains all 3 hooks" $hooksOk
Test-Step "settings.json env.$envKeyName = $envKeyValue" ($verifySettings.env.$envKeyName -eq $envKeyValue)

$verifyProfileContent = Get-Content $ProfilePath -Raw
Test-Step "`$PROFILE contains watcher auto-start block" ($verifyProfileContent -like "*$profileMarkerStart*")

Write-Host ""
if ($allOk) {
    Write-Host "=== Install SUCCEEDED ===" -ForegroundColor Green
    exit 0
} else {
    Write-Host "=== Install FAILED -- see [FAIL] lines above ===" -ForegroundColor Red
    exit 1
}
