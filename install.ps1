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
    [string]$SourceExePath = $null,
    # Sound-selection controls (both optional; default behavior for a real
    # interactive user is unchanged -- they get prompted). -SelectedSound sets
    # the sound directly with no prompt at all (for scripts/tests). -SkipSoundPrompt
    # skips the prompt and keeps whatever is already configured (or the fresh
    # default) untouched -- for unattended/automated installs.
    [string]$SelectedSound = $null,
    [switch]$SkipSoundPrompt,
    # Same controls, for the attention emoji. -SelectedEmoji sets it directly
    # with no prompt at all; -SkipEmojiPrompt skips the prompt and keeps
    # whatever is already configured (or the fresh default). Independent of
    # the sound controls above -- either prompt can be skipped/scripted
    # without affecting the other.
    [string]$SelectedEmoji = $null,
    [switch]$SkipEmojiPrompt
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
    Write-Host "[1/7] Deploying provided hook exe (build skipped: -SourceExePath given) ..." -ForegroundColor Yellow
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
    Write-Host "[1/7] Building ClaudeAttention.exe ..." -ForegroundColor Yellow
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
Write-Host "[2/7] Deploying watcher and sound assets ..." -ForegroundColor Yellow
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

# --- 3. choose notification sound ---
Write-Host "[3/7] Choosing notification sound ..." -ForegroundColor Yellow

$soundCatalog = [ordered]@{
    classic = 'Classic -- two-tone chime'
    chime   = 'Chime -- soft bell'
    soft    = 'Soft -- gentle low tone'
    alert   = 'Alert -- sharp double pulse'
    retro   = 'Retro -- square-wave beep'
    magic   = 'Magic -- ascending arpeggio'
    digital = 'Digital -- quick double blip'
    double  = 'Double -- double beep'
    scifi   = 'Sci-Fi -- frequency sweep'
    success = 'Success -- victory fanfare'
}
$soundKeys = @($soundCatalog.Keys)
$testSoundPath = Join-Path $deployDir 'test-sound.ps1'

$soundConfig = $null
try {
    $soundConfig = Get-Content $deployedConfigPath -Raw | ConvertFrom-Json
} catch {
    Write-Host "  config.json is missing or invalid -- using defaults for sound selection" -ForegroundColor DarkYellow
}
if ($null -eq $soundConfig) {
    $soundConfig = [PSCustomObject]@{ soundEnabled = $true; selectedSound = 'classic'; customSoundFile = '' }
}
if (-not $soundConfig.PSObject.Properties['selectedSound'] -or -not $soundConfig.selectedSound) {
    $soundConfig | Add-Member -MemberType NoteProperty -Name 'selectedSound' -Value 'classic' -Force
}

$currentSelected = $soundConfig.selectedSound
if (-not ($soundKeys -contains $currentSelected) -and $currentSelected -ne 'custom') {
    $currentSelected = 'classic'
}
$soundEnabledForPreview = $true
if ($soundConfig.PSObject.Properties['soundEnabled']) { $soundEnabledForPreview = [bool]$soundConfig.soundEnabled }

$finalSound = $currentSelected

if ($SelectedSound) {
    if ($soundKeys -contains $SelectedSound) {
        $finalSound = $SelectedSound
        Write-Host "  sound set via -SelectedSound: $finalSound"
    } else {
        Write-Host "  -SelectedSound '$SelectedSound' is not a recognized sound name -- keeping '$currentSelected'" -ForegroundColor DarkYellow
    }
} elseif ($SkipSoundPrompt) {
    Write-Host "  sound prompt skipped (-SkipSoundPrompt) -- keeping '$currentSelected'"
} else {
    # No pre-check via [Console]::In.Peek() here on purpose -- Peek() reads
    # ahead into .NET's own Console.In buffer, which was observed to steal
    # bytes that Read-Host's own (separate) read path never sees afterward,
    # corrupting the very first prompt's answer. A try/catch around the whole
    # loop is the safe net instead: Read-Host throws a HostException on a
    # genuinely non-interactive host (e.g. -NonInteractive, no console at
    # all), which is caught below and falls back to keeping the current value.
    try {
        while ($true) {
            Write-Host ""
            Write-Host "  Choose a notification sound:"
            for ($i = 0; $i -lt $soundKeys.Count; $i++) {
                $key = $soundKeys[$i]
                $marker = if ($key -eq $currentSelected) { '  (current)' } else { '' }
                Write-Host ("    {0,2}. {1}{2}" -f ($i + 1), $soundCatalog[$key], $marker)
            }
            $raw = Read-Host "  Enter a number (1-$($soundKeys.Count)), or press Enter to keep '$currentSelected'"
            if ([string]::IsNullOrWhiteSpace($raw)) {
                $finalSound = $currentSelected
                break
            }

            $choiceNum = 0
            if (-not [int]::TryParse($raw.Trim(), [ref]$choiceNum) -or $choiceNum -lt 1 -or $choiceNum -gt $soundKeys.Count) {
                Write-Host "    Not a valid choice -- enter a number from 1 to $($soundKeys.Count)." -ForegroundColor Yellow
                continue
            }

            $candidate = $soundKeys[$choiceNum - 1]

            $shouldPreview = $soundEnabledForPreview
            if (-not $soundEnabledForPreview) {
                $previewAnswer = Read-Host "  Sound is currently disabled. Preview '$($soundCatalog[$candidate])' anyway? (y/N)"
                $shouldPreview = ($previewAnswer -match '^(y|yes)$')
            }
            if ($shouldPreview -and (Test-Path $testSoundPath)) {
                try {
                    & $testSoundPath -Sound $candidate | Out-Null
                } catch {
                    Write-Host "    (preview failed: $($_.Exception.Message))" -ForegroundColor DarkYellow
                }
            }

            $confirmAnswer = Read-Host "  Use '$($soundCatalog[$candidate])' for notifications? (Y/n)"
            if ($confirmAnswer -match '^(n|no)$') { continue }

            $finalSound = $candidate
            break
        }
    } catch {
        Write-Host "  no interactive input available -- keeping '$currentSelected'" -ForegroundColor DarkYellow
        $finalSound = $currentSelected
    }
}

if ($finalSound -ne $soundConfig.selectedSound) {
    $soundConfig.selectedSound = $finalSound
    $soundConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $deployedConfigPath -Encoding utf8
    Write-Host "  selectedSound set to '$finalSound'"
} else {
    Write-Host "  selectedSound unchanged ('$finalSound')"
}
Write-Host ""

# --- 4. choose attention emoji ---
Write-Host "[4/7] Choosing attention emoji ..." -ForegroundColor Yellow

# Display glyphs are built the same way as watcher-background.ps1 resolves
# them at runtime (ConvertFromUtf32 from a Codepoints array, almost always
# one value) -- see that file for why this catalog is duplicated there rather
# than shared, and why 'heart' needs two codepoints (U+FE0F forces the color
# emoji presentation instead of a plain text glyph).
$emojiCatalog = [ordered]@{
    sparkle = @{ Codepoints = @(0x2728);          Name = 'Sparkle' }
    star    = @{ Codepoints = @(0x2B50);          Name = 'Star' }
    bell    = @{ Codepoints = @(0x1F514);         Name = 'Bell' }
    bolt    = @{ Codepoints = @(0x26A1);          Name = 'Lightning bolt' }
    fire    = @{ Codepoints = @(0x1F525);         Name = 'Fire' }
    target  = @{ Codepoints = @(0x1F3AF);         Name = 'Target' }
    check   = @{ Codepoints = @(0x2705);          Name = 'Check mark' }
    reddot  = @{ Codepoints = @(0x1F534);         Name = 'Red dot' }
    eyes    = @{ Codepoints = @(0x1F440);         Name = 'Eyes' }
    chat    = @{ Codepoints = @(0x1F4AC);         Name = 'Chat bubble' }
    heart   = @{ Codepoints = @(0x2764, 0xFE0F);  Name = 'Heart' }
    music   = @{ Codepoints = @(0x1F3B5);         Name = 'Music note' }
}
$emojiKeys = @($emojiCatalog.Keys)

# $soundConfig already reflects the latest on-disk state (including the
# selectedSound write just above) -- reused here rather than re-reading the
# file, so both steps write through the same in-memory object.
if (-not $soundConfig.PSObject.Properties['selectedEmoji'] -or -not $soundConfig.selectedEmoji) {
    $soundConfig | Add-Member -MemberType NoteProperty -Name 'selectedEmoji' -Value 'sparkle' -Force
}
$currentEmoji = $soundConfig.selectedEmoji
if (-not ($emojiKeys -contains $currentEmoji)) { $currentEmoji = 'sparkle' }

$finalEmoji = $currentEmoji

if ($SelectedEmoji) {
    if ($emojiKeys -contains $SelectedEmoji) {
        $finalEmoji = $SelectedEmoji
        Write-Host "  emoji set via -SelectedEmoji: $finalEmoji"
    } else {
        Write-Host "  -SelectedEmoji '$SelectedEmoji' is not a recognized emoji name -- keeping '$currentEmoji'" -ForegroundColor DarkYellow
    }
} elseif ($SkipEmojiPrompt) {
    Write-Host "  emoji prompt skipped (-SkipEmojiPrompt) -- keeping '$currentEmoji'"
} else {
    # Same try/catch safety net as the sound prompt above (no Console.In.Peek()
    # pre-check -- see its comment for why). No preview here: unlike sound,
    # there is nothing to play, and a glyph is either legible in this console
    # or it isn't -- an extra confirm step would just be friction.
    try {
        while ($true) {
            Write-Host ""
            Write-Host "  Choose an attention emoji:"
            for ($i = 0; $i -lt $emojiKeys.Count; $i++) {
                $key = $emojiKeys[$i]
                $glyph = -join ($emojiCatalog[$key].Codepoints | ForEach-Object { [System.Char]::ConvertFromUtf32($_) })
                $marker = if ($key -eq $currentEmoji) { '  (current)' } else { '' }
                Write-Host ("    {0,2}. {1}  {2}{3}" -f ($i + 1), $glyph, $emojiCatalog[$key].Name, $marker)
            }
            $rawEmoji = Read-Host "  Enter a number (1-$($emojiKeys.Count)), or press Enter to keep '$currentEmoji'"
            if ([string]::IsNullOrWhiteSpace($rawEmoji)) {
                $finalEmoji = $currentEmoji
                break
            }

            $emojiChoiceNum = 0
            if (-not [int]::TryParse($rawEmoji.Trim(), [ref]$emojiChoiceNum) -or $emojiChoiceNum -lt 1 -or $emojiChoiceNum -gt $emojiKeys.Count) {
                Write-Host "    Not a valid choice -- enter a number from 1 to $($emojiKeys.Count)." -ForegroundColor Yellow
                continue
            }

            $finalEmoji = $emojiKeys[$emojiChoiceNum - 1]
            break
        }
    } catch {
        Write-Host "  no interactive input available -- keeping '$currentEmoji'" -ForegroundColor DarkYellow
        $finalEmoji = $currentEmoji
    }
}

if ($finalEmoji -ne $soundConfig.selectedEmoji) {
    $soundConfig.selectedEmoji = $finalEmoji
    $soundConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $deployedConfigPath -Encoding utf8
    Write-Host "  selectedEmoji set to '$finalEmoji'"
} else {
    Write-Host "  selectedEmoji unchanged ('$finalEmoji')"
}
Write-Host ""

# --- 5. merge into settings.json (hooks + env), with manifest tracking for the env key ---
Write-Host "[5/7] Updating Claude Code settings.json ..." -ForegroundColor Yellow

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

# --- 6. add watcher auto-start to $PROFILE ---
Write-Host "[6/7] Updating PowerShell profile ..." -ForegroundColor Yellow

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

# --- 7. verify ---
Write-Host "[7/7] Verifying installation ..." -ForegroundColor Yellow
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
