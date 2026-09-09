# Claude Tab Notifier -- installer
# Deploys the hook, watcher, sound assets, and wires Claude Code hooks + settings +
# $PROFILE auto-start. Safe to run multiple times: every step checks for an existing
# installation before changing anything, and only backs up a file when it is actually
# about to be modified. Presented to an interactive user as a 4-step wizard (Environment,
# Sound, Emoji, Installing); the underlying actions and their order are unchanged from
# before the wizard UI existed -- this file only changes what gets printed and, for the
# emoji step, adds the same confirm-before-saving question the sound step already had.
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

# Whether THIS run could possibly need to read from the console at all. Both
# sound and emoji default to being genuinely interactive; either one becomes
# non-interactive the moment it's given an explicit selection or told to skip.
# Used only to decide whether to show the purely-cosmetic "press ENTER to
# continue" pause below -- never changes what gets installed.
$soundIsInteractive = (-not $SelectedSound) -and (-not $SkipSoundPrompt)
$emojiIsInteractive = (-not $SelectedEmoji) -and (-not $SkipEmojiPrompt)
$anyInteractive     = $soundIsInteractive -or $emojiIsInteractive

# Decorative glyphs built via ConvertFromUtf32/char-codes rather than embedded
# literally in this source file -- same reasoning as the emoji catalog below:
# avoids any source-encoding pitfall for a file that already has to handle a
# folder path with non-ASCII characters in it correctly.
$glyphCheck  = [char]0x2713   # check mark
$glyphCross  = [char]0x2717   # ballot X
$glyphPlay   = [char]0x25B6   # play triangle
$glyphBullet = [char]0x2022   # bullet
$glyphSparkle = [char]0x2728  # sparkle, decorative use only (banner text)
$glyphParty   = [System.Char]::ConvertFromUtf32(0x1F389) # party popper, banner only

function Write-Banner {
    param([string]$Line1, [string]$Line2)
    $h  = [char]0x2550   # =
    $v  = [char]0x2551   # |
    $tl = [char]0x2554   # top-left corner
    $tr = [char]0x2557   # top-right corner
    $bl = [char]0x255A   # bottom-left corner
    $br = [char]0x255D   # bottom-right corner
    $width = 56

    function Pad-Center([string]$Text, [int]$Width) {
        $total = $Width - $Text.Length
        if ($total -lt 0) { return $Text.Substring(0, $Width) }
        $left = [Math]::Floor($total / 2)
        $right = $total - $left
        return (' ' * $left) + $Text + (' ' * $right)
    }

    $hLine = "$h" * $width
    Write-Host ""
    Write-Host ("$tl" + $hLine + "$tr") -ForegroundColor Cyan
    Write-Host ("$v" + (' ' * $width) + "$v") -ForegroundColor Cyan
    Write-Host ("$v" + (Pad-Center $Line1 $width) + "$v") -ForegroundColor Cyan
    if ($Line2) {
        Write-Host ("$v" + (' ' * $width) + "$v") -ForegroundColor Cyan
        Write-Host ("$v" + (Pad-Center $Line2 $width) + "$v") -ForegroundColor Cyan
    }
    Write-Host ("$v" + (' ' * $width) + "$v") -ForegroundColor Cyan
    Write-Host ("$bl" + $hLine + "$br") -ForegroundColor Cyan
    Write-Host ""
}

function Write-StepHeader {
    param([int]$Step, [int]$Total, [string]$Title)
    Write-Host ""
    Write-Host "Step $Step of $Total $glyphBullet $Title" -ForegroundColor Cyan
    Write-Host ("-" * 50) -ForegroundColor DarkGray
    Write-Host ""
}

function Write-Box {
    # A simple fixed-width info box -- content lines are pre-formatted by the
    # caller (this just draws the border); used for the sound/emoji selection
    # confirmation screens.
    param([string[]]$Lines, [int]$Width = 54)
    $tl = [char]0x250C; $tr = [char]0x2510; $bl = [char]0x2514; $br = [char]0x2518
    $h = [char]0x2500; $v = [char]0x2502
    $hLine = "$h" * $Width
    Write-Host ("$tl" + $hLine + "$tr") -ForegroundColor DarkCyan
    foreach ($line in $Lines) {
        $padded = $line
        if ($padded.Length -gt $Width - 2) { $padded = $padded.Substring(0, $Width - 2) }
        $padded = $padded + (' ' * ($Width - 2 - $padded.Length))
        Write-Host ("$v " + $padded + " $v") -ForegroundColor DarkCyan
    }
    Write-Host ("$bl" + $hLine + "$br") -ForegroundColor DarkCyan
}

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

# --- Step 1 of 4: Environment ---
Write-Banner "$glyphSparkle CLAUDE TAB NOTIFIER $glyphSparkle" "Installation Wizard"
Write-StepHeader 1 4 "Environment"

Write-Host "Checking your environment..."
Write-Host ""

# Purely informational -- neither of these two checks blocks the install by
# itself. The one hard requirement (the .NET SDK, when no -SourceExePath is
# given) is still enforced exactly where it always was, at the actual build
# step below; $dotnetCmd is computed once, here, and reused there so the
# check itself isn't duplicated.
$dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
if ($SourceExePath -or $dotnetCmd) {
    Write-Host "  $glyphCheck .NET SDK detected" -ForegroundColor Green
} else {
    Write-Host "  $glyphCross .NET SDK not found on PATH" -ForegroundColor Red
}

$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeCmd) {
    Write-Host "  $glyphCheck Claude Code CLI detected" -ForegroundColor Green
} else {
    Write-Host "  $glyphCross Claude Code CLI not found on PATH (you can still install now and run 'claude' later)" -ForegroundColor DarkYellow
}

Write-Host "  $glyphCheck PowerShell $($PSVersionTable.PSVersion) detected" -ForegroundColor Green
Write-Host ""
Write-Host "Environment ready." -ForegroundColor Green

if ($anyInteractive) {
    try { Read-Host "Press ENTER to continue" | Out-Null } catch {}
}

# --- build and deploy the hook exe ---
if ($SourceExePath) {
    Write-Host ""
    Write-Host "Deploying provided hook exe (build skipped: -SourceExePath given) ..." -ForegroundColor Yellow
    if (-not (Test-Path $SourceExePath)) {
        Write-Host "$glyphCross -SourceExePath not found: $SourceExePath" -ForegroundColor Red
        exit 1
    }
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    Copy-Item -Path $SourceExePath -Destination $exeDeployPath -Force
    Unblock-File -Path $exeDeployPath
    Write-Host "  deployed: $exeDeployPath"
} else {
    Write-Host ""
    Write-Host "Building ClaudeAttention.exe ..." -ForegroundColor Yellow
    if (-not $dotnetCmd) {
        Write-Host "$glyphCross dotnet CLI not found on PATH. Install the .NET SDK first." -ForegroundColor Red
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
        Write-Host "$glyphCross Expected published exe not found at: $publishedExe" -ForegroundColor Red
        exit 1
    }

    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    Copy-Item -Path $publishedExe -Destination $exeDeployPath -Force
    Unblock-File -Path $exeDeployPath
    Write-Host "  deployed: $exeDeployPath"
}

# --- deploy watcher, sound, config assets ---
New-Item -ItemType Directory -Path $soundsDeployDir -Force | Out-Null

Copy-Item -Path (Join-Path $PSScriptRoot 'watcher-background.ps1') -Destination (Join-Path $deployDir 'watcher-background.ps1') -Force
Copy-Item -Path (Join-Path $PSScriptRoot 'test-sound.ps1')         -Destination (Join-Path $deployDir 'test-sound.ps1') -Force

$soundsSourceDir = Join-Path $PSScriptRoot 'sounds'
$soundAssets = Get-ChildItem -Path $soundsSourceDir -File
foreach ($asset in $soundAssets) {
    Copy-Item -Path $asset.FullName -Destination (Join-Path $soundsDeployDir $asset.Name) -Force
}

$deployedConfigPath = Join-Path $deployDir 'config.json'
if (-not (Test-Path $deployedConfigPath)) {
    Copy-Item -Path (Join-Path $PSScriptRoot 'config.json') -Destination $deployedConfigPath -Force
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

Write-Host "  watcher, sound files, and config deployed"

# --- Step 2 of 4: Notification Sound ---
Write-StepHeader 2 4 "Notification Sound"

Write-Host "Choose the sound you want to hear when Claude"
Write-Host "finishes and needs your attention."
Write-Host ""
Write-Host "You can preview any sound before choosing it."

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
    Write-Host ""
    Write-Host "  $glyphCross config.json is missing or invalid -- using defaults for sound selection" -ForegroundColor DarkYellow
}
if ($null -eq $soundConfig) {
    $soundConfig = [PSCustomObject]@{ soundEnabled = $true; selectedSound = 'classic'; customSoundFile = '' }
}
if (-not $soundConfig.PSObject.Properties['selectedSound'] -or -not $soundConfig.selectedSound) {
    $soundConfig | Add-Member -MemberType NoteProperty -Name 'selectedSound' -Value 'classic' -Force
}
# Captured before either step mutates $soundConfig, so Step 4 can tell whether
# a config.json write is actually needed -- exactly the same comparison basis
# the original (pre-wizard) code used for each field individually.
$originalSoundValue = $soundConfig.selectedSound

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
        Write-Host ""
        Write-Host "  $glyphCheck sound set via -SelectedSound: $finalSound" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "  $glyphCross -SelectedSound '$SelectedSound' is not a recognized sound name -- keeping '$currentSelected'" -ForegroundColor DarkYellow
    }
} elseif ($SkipSoundPrompt) {
    Write-Host ""
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
            Write-Host "  Available sounds:"
            Write-Host ""
            for ($i = 0; $i -lt $soundKeys.Count; $i++) {
                $key = $soundKeys[$i]
                $marker = if ($key -eq $currentSelected) { "  (current)" } else { '' }
                Write-Host ("    {0,2}. {1}{2}" -f ($i + 1), $soundCatalog[$key], $marker)
            }
            Write-Host ""
            $raw = Read-Host "  Enter a number (1-$($soundKeys.Count)), or press Enter to keep '$currentSelected'"
            if ([string]::IsNullOrWhiteSpace($raw)) {
                $finalSound = $currentSelected
                break
            }

            $choiceNum = 0
            if (-not [int]::TryParse($raw.Trim(), [ref]$choiceNum) -or $choiceNum -lt 1 -or $choiceNum -gt $soundKeys.Count) {
                Write-Host "  $glyphCross Not a valid choice -- enter a number from 1 to $($soundKeys.Count)." -ForegroundColor Yellow
                continue
            }

            $candidate = $soundKeys[$choiceNum - 1]
            $candidateLabel = $soundCatalog[$candidate]
            $candidateShortName = ($candidateLabel -split ' -- ')[0]

            $shouldPreview = $soundEnabledForPreview
            if (-not $soundEnabledForPreview) {
                Write-Host ""
                $previewAnswer = Read-Host "  Sound is currently disabled in config.json. Preview '$candidateShortName' anyway? (y/N)"
                $shouldPreview = ($previewAnswer -match '^(y|yes)$')
            }

            Write-Host ""
            Write-Box -Lines @(
                "Selected sound",
                "",
                "  $candidateShortName",
                ""
            )

            if ($shouldPreview -and (Test-Path $testSoundPath)) {
                Write-Host "  $glyphPlay Playing preview..." -ForegroundColor Cyan
                try {
                    & $testSoundPath -Sound $candidate | Out-Null
                } catch {
                    Write-Host "  (preview failed: $($_.Exception.Message))" -ForegroundColor DarkYellow
                }
            }

            Write-Host ""
            $confirmAnswer = Read-Host "  Use this sound for notifications? [Y] Yes   [N] Choose another"
            if ($confirmAnswer -match '^(n|no)$') { continue }

            $finalSound = $candidate
            break
        }
    } catch {
        Write-Host ""
        Write-Host "  no interactive input available -- keeping '$currentSelected'" -ForegroundColor DarkYellow
        $finalSound = $currentSelected
    }
}

if ($finalSound -ne $soundConfig.selectedSound) {
    $soundConfig.selectedSound = $finalSound
} else {
    Write-Host ""
    Write-Host "  selectedSound unchanged ('$finalSound')"
}

# --- Step 3 of 4: Attention Emoji ---
Write-StepHeader 3 4 "Attention Emoji"

Write-Host "Choose the emoji that will appear and pulse"
Write-Host "in your Windows Terminal tab when Claude"
Write-Host "needs your attention."

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

# $soundConfig already reflects the latest in-memory selection (including the
# selectedSound change just above, not yet written to disk) -- reused here
# rather than re-reading the file, so both steps update through the same
# object; the actual config.json write happens once, in Step 4, after both
# choices are final.
if (-not $soundConfig.PSObject.Properties['selectedEmoji'] -or -not $soundConfig.selectedEmoji) {
    $soundConfig | Add-Member -MemberType NoteProperty -Name 'selectedEmoji' -Value 'sparkle' -Force
}
# Same reasoning as $originalSoundValue above.
$originalEmojiValue = $soundConfig.selectedEmoji
$currentEmoji = $soundConfig.selectedEmoji
if (-not ($emojiKeys -contains $currentEmoji)) { $currentEmoji = 'sparkle' }

$finalEmoji = $currentEmoji

if ($SelectedEmoji) {
    if ($emojiKeys -contains $SelectedEmoji) {
        $finalEmoji = $SelectedEmoji
        Write-Host ""
        Write-Host "  $glyphCheck emoji set via -SelectedEmoji: $finalEmoji" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "  $glyphCross -SelectedEmoji '$SelectedEmoji' is not a recognized emoji name -- keeping '$currentEmoji'" -ForegroundColor DarkYellow
    }
} elseif ($SkipEmojiPrompt) {
    Write-Host ""
    Write-Host "  emoji prompt skipped (-SkipEmojiPrompt) -- keeping '$currentEmoji'"
} else {
    # Same try/catch safety net as the sound prompt above (no Console.In.Peek()
    # pre-check -- see its comment for why).
    try {
        while ($true) {
            Write-Host ""
            Write-Host "  Available emoji:"
            Write-Host ""
            for ($i = 0; $i -lt $emojiKeys.Count; $i++) {
                $key = $emojiKeys[$i]
                $glyph = -join ($emojiCatalog[$key].Codepoints | ForEach-Object { [System.Char]::ConvertFromUtf32($_) })
                $marker = if ($key -eq $currentEmoji) { "  (current)" } else { '' }
                Write-Host ("    {0,2}. {1}  {2}{3}" -f ($i + 1), $glyph, $emojiCatalog[$key].Name, $marker)
            }
            Write-Host ""
            $rawEmoji = Read-Host "  Enter a number (1-$($emojiKeys.Count)), or press Enter to keep '$currentEmoji'"
            if ([string]::IsNullOrWhiteSpace($rawEmoji)) {
                $finalEmoji = $currentEmoji
                break
            }

            $emojiChoiceNum = 0
            if (-not [int]::TryParse($rawEmoji.Trim(), [ref]$emojiChoiceNum) -or $emojiChoiceNum -lt 1 -or $emojiChoiceNum -gt $emojiKeys.Count) {
                Write-Host "  $glyphCross Not a valid choice -- enter a number from 1 to $($emojiKeys.Count)." -ForegroundColor Yellow
                continue
            }

            $candidateKey = $emojiKeys[$emojiChoiceNum - 1]
            $candidateGlyph = -join ($emojiCatalog[$candidateKey].Codepoints | ForEach-Object { [System.Char]::ConvertFromUtf32($_) })
            $candidateName = $emojiCatalog[$candidateKey].Name

            Write-Host ""
            Write-Box -Lines @(
                "Selected emoji",
                "",
                "  $candidateGlyph  $candidateName",
                "",
                "This emoji will appear and pulse in your tab",
                "title while Claude needs your attention.",
                ""
            )

            Write-Host ""
            $confirmAnswer = Read-Host "  Use this emoji? [Y] Yes   [N] Choose another"
            if ($confirmAnswer -match '^(n|no)$') { continue }

            $finalEmoji = $candidateKey
            break
        }
    } catch {
        Write-Host ""
        Write-Host "  no interactive input available -- keeping '$currentEmoji'" -ForegroundColor DarkYellow
        $finalEmoji = $currentEmoji
    }
}

if ($finalEmoji -ne $soundConfig.selectedEmoji) {
    $soundConfig.selectedEmoji = $finalEmoji
} else {
    Write-Host ""
    Write-Host "  selectedEmoji unchanged ('$finalEmoji')"
}

# --- Step 4 of 4: Installing ---
Write-StepHeader 4 4 "Installing"

# The exe and watcher/sound/config assets were already deployed earlier (they
# have to be, so Step 2's sound preview has something to play) -- their
# checkmarks below report on that real, already-completed work via the same
# Test-Path checks the old, non-wizard "verify" step always used; nothing
# here re-deploys them or changes when they were written.
$allOk = $true
$verifyResults = New-Object System.Collections.Generic.List[PSCustomObject]

function Test-Step {
    param([string]$Label, [bool]$Condition)
    $script:verifyResults.Add([PSCustomObject]@{ Label = $Label; Ok = $Condition })
    if (-not $Condition) { $script:allOk = $false }
}

function Write-GroupResult {
    # Prints one checklist line for a group of underlying Test-Step results.
    # On success: just the summary line, to keep this screen readable. On
    # failure: the summary line PLUS every failing member's own detail line,
    # so a real problem is never hidden behind a clean-looking summary.
    param([string]$GroupLabel, [string[]]$MemberLabels)
    $members = $verifyResults | Where-Object { $MemberLabels -contains $_.Label }
    $failing = @($members | Where-Object { -not $_.Ok })
    if ($failing.Count -eq 0) {
        Write-Host "  $glyphCheck $GroupLabel" -ForegroundColor Green
    } else {
        Write-Host "  $glyphCross $GroupLabel" -ForegroundColor Red
        foreach ($m in $failing) {
            Write-Host "      $glyphCross $($m.Label)" -ForegroundColor Red
        }
    }
}

Test-Step "ClaudeAttention.exe deployed"      (Test-Path $exeDeployPath)
Write-GroupResult "Installing ClaudeAttention" @("ClaudeAttention.exe deployed")

Test-Step "watcher-background.ps1 deployed"   (Test-Path (Join-Path $deployDir 'watcher-background.ps1'))
Test-Step "test-sound.ps1 deployed"           (Test-Path (Join-Path $deployDir 'test-sound.ps1'))
foreach ($asset in $soundAssets) {
    Test-Step "sounds\$($asset.Name) deployed" (Test-Path (Join-Path $soundsDeployDir $asset.Name))
}
Test-Step "config.json deployed"              (Test-Path $deployedConfigPath)
Write-GroupResult "Installing watcher" (@("watcher-background.ps1 deployed", "test-sound.ps1 deployed", "config.json deployed") + @($soundAssets | ForEach-Object { "sounds\$($_.Name) deployed" }))

# --- merge into settings.json (hooks + env), with manifest tracking for the env key ---
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
}

if ($hooksChanged -or $envChanged) {
    Backup-FileIfExists $settingsPath
    $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath -Encoding utf8
}

# manifest is written/refreshed regardless (safe: history fields are only ever set once)
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding utf8

$verifySettingsForHooks = Get-Content $settingsPath -Raw | ConvertFrom-Json
$hooksOk = $true
foreach ($eventName in $hookCommands.Keys) {
    $cmd = $hookCommands[$eventName]
    $found = $false
    foreach ($group in @($verifySettingsForHooks.hooks.$eventName)) {
        foreach ($h in @($group.hooks)) {
            if ($h.command -eq $cmd) { $found = $true }
        }
    }
    if (-not $found) { $hooksOk = $false }
}
Test-Step "settings.json contains all 3 hooks" $hooksOk
Write-GroupResult "Installing hooks" @("settings.json contains all 3 hooks")

# Now that both the sound and emoji choices are final, write config.json once
# with both fields together -- but only if something actually changed, exactly
# like the original (pre-wizard) code: an unchanged re-install must leave
# config.json completely untouched (no rewrite, no touched mtime), not just
# unchanged in value.
if ($finalSound -ne $originalSoundValue -or $finalEmoji -ne $originalEmojiValue) {
    $soundConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $deployedConfigPath -Encoding utf8
}

$verifySettings = Get-Content $settingsPath -Raw | ConvertFrom-Json
Test-Step "settings.json env.$envKeyName = $envKeyValue" ($verifySettings.env.$envKeyName -eq $envKeyValue)
Write-GroupResult "Updating configuration" @("settings.json env.$envKeyName = $envKeyValue")

# --- add watcher auto-start to $PROFILE ---
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
}

$verifyProfileContent = Get-Content $ProfilePath -Raw
Test-Step "`$PROFILE contains watcher auto-start block" ($verifyProfileContent -like "*$profileMarkerStart*")
Write-GroupResult "Configuring PowerShell auto-start" @("`$PROFILE contains watcher auto-start block")

# --- final verification ---
if ($allOk) {
    Write-Host "  $glyphCheck Verifying installation" -ForegroundColor Green
} else {
    Write-Host "  $glyphCross Verifying installation" -ForegroundColor Red
}

if ($allOk) {
    Write-Banner "$glyphParty ALL DONE!" "Claude Tab Notifier is installed"
    $soundDisplayName = if ($soundCatalog.Contains($finalSound)) { ($soundCatalog[$finalSound] -split ' -- ')[0] } else { $finalSound }
    Write-Host "Selected sound: $soundDisplayName"
    Write-Host "Selected emoji: $($emojiCatalog[$finalEmoji].Name)"
    Write-Host ""
    Write-Host "Open a NEW Windows Terminal tab and run:"
    Write-Host ""
    Write-Host "    claude" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "You'll see the tab title pulse with your chosen emoji, and hear your"
    Write-Host "chosen sound, whenever Claude finishes responding or needs your input."
    exit 0
} else {
    Write-Host ""
    Write-Host "=== Install FAILED -- see the details above ===" -ForegroundColor Red
    exit 1
}
