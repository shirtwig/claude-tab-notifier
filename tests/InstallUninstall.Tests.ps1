Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

# Tests install.ps1 / uninstall.ps1 as black boxes against a FULLY isolated
# sandbox: fake settings.json, fake $PROFILE, fake deploy dir, fake tools dir.
# Never touches the real ~/.claude or %LOCALAPPDATA%. Enabled by the minimal
# -DeployDir/-SettingsPath/-ToolsDir/-ExeDeployPath/-ProfilePath/-SourceExePath
# parameters added to both scripts -- all default to the exact real paths used
# before, so ordinary no-args invocation is unchanged.
#
# Both scripts call `exit`, so they are ALWAYS invoked as a separate process
# here (never dot-sourced/called in-process), which would otherwise kill the
# test runner itself.

$projectRoot = Split-Path $PSScriptRoot -Parent
$installScript = Join-Path $projectRoot 'install.ps1'
$uninstallScript = Join-Path $projectRoot 'uninstall.ps1'

function New-InstallSandbox {
    $id = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $root = Join-Path $env:TEMP "ClaudeTabNotifierInstallTests\$id"
    $deployDir = Join-Path $root 'deploy'
    $claudeDir = Join-Path $root 'claude'
    $toolsDir = Join-Path $claudeDir 'tools'
    New-Item -ItemType Directory -Path $root, $claudeDir -Force | Out-Null

    $fakeExePath = Join-Path $root 'FakeClaudeAttention.exe'
    Set-Content -Path $fakeExePath -Value 'fake exe content -- never executed, only copied' -Encoding utf8

    [PSCustomObject]@{
        Root          = $root
        DeployDir     = $deployDir
        SettingsPath  = Join-Path $claudeDir 'settings.json'
        ToolsDir      = $toolsDir
        ExeDeployPath = Join-Path $toolsDir 'ClaudeAttention.exe'
        ProfilePath   = Join-Path $root 'profile.ps1'
        FakeExePath   = $fakeExePath
    }
}

function Remove-InstallSandbox {
    param($Sandbox)
    try { Remove-Item -Path $Sandbox.Root -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

function ConvertTo-QuotedArgString {
    # Start-Process -ArgumentList, given a string ARRAY, does not quote
    # elements containing spaces -- and this project's own directory name
    # ("פיצר לקלוד") has one, which would otherwise split -File's own value
    # into two broken arguments. Build one pre-quoted string instead.
    param([string[]]$Parts)
    ($Parts | ForEach-Object { '"' + $_ + '"' }) -join ' '
}

function New-StagedInstallScript {
    # Simulates a real "downloaded GitHub ZIP" install: copies install.ps1
    # and everything it deploys (watcher-background.ps1, test-sound.ps1,
    # sounds\, config.json) into an isolated staging directory. install.ps1
    # locates all of these via $PSScriptRoot, which resolves to wherever the
    # invoked script FILE itself lives -- so running this staged copy makes
    # its Copy-Item calls read from these staged (taggable) sources instead
    # of the real repo files. A synthetic Mark-of-the-Web tag applied here
    # therefore never touches the real watcher-background.ps1/test-sound.ps1
    # that every other test file in this suite invokes directly.
    param($Sandbox)
    $stageDir = Join-Path $Sandbox.Root 'stage'
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
    Copy-Item -Path $installScript -Destination (Join-Path $stageDir 'install.ps1') -Force
    Copy-Item -Path (Join-Path $projectRoot 'watcher-background.ps1') -Destination (Join-Path $stageDir 'watcher-background.ps1') -Force
    Copy-Item -Path (Join-Path $projectRoot 'test-sound.ps1') -Destination (Join-Path $stageDir 'test-sound.ps1') -Force
    Copy-Item -Path (Join-Path $projectRoot 'config.json') -Destination (Join-Path $stageDir 'config.json') -Force
    Copy-Item -Path (Join-Path $projectRoot 'sounds') -Destination (Join-Path $stageDir 'sounds') -Recurse -Force
    Join-Path $stageDir 'install.ps1'
}

function Add-MarkOfTheWeb {
    # Simulates the Zone.Identifier NTFS alternate data stream ("Mark of the
    # Web") Windows stamps on every file extracted from a downloaded ZIP.
    # Confirmed empirically on a real GitHub-ZIP install: [ZoneTransfer] /
    # ZoneId=3 is exactly what a real downloaded+extracted file carries.
    param([string]$Path)
    Set-Content -Path $Path -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=3" -Encoding ASCII
}

function Test-HasMarkOfTheWeb {
    param([string]$Path)
    $null -ne (Get-Item -Path $Path -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue)
}

function Invoke-InstallScript {
    # -SkipSoundPrompt by default -- this and every other existing test in this
    # file predates the interactive sound-selection step and runs with no stdin
    # redirected, so without this the new Read-Host prompt would hang forever.
    # The dedicated sound-selection tests below override sound-related behavior
    # explicitly (either -SelectedSound, or simulated keystrokes via -InputLines)
    # instead of relying on this default.
    #
    # Uses System.Diagnostics.Process directly (like TestHelpers.psm1's
    # Start-IsolatedProcess) rather than the Start-Process cmdlet: Start-Process
    # -PassThru without -Wait was observed to return a Process object whose
    # .ExitCode comes back blank even after WaitForExit() succeeds -- a known
    # quirk of that specific combination, not present when using Process
    # directly, which also gives clean, real StandardInput access for feeding
    # simulated answers to Read-Host.
    # -InputLines is compared via $null (not plain truthiness) throughout --
    # PowerShell unwraps a SINGLE-element array in a boolean test and evaluates
    # that one element's own truthiness instead of the array's Count, so
    # -InputLines @('') (used to simulate pressing Enter) would otherwise be
    # treated as "not given" (empty string is falsy) and silently skip stdin
    # redirection entirely -- observed empirically as a 30s hang, since the
    # child then waits on the real ambient console instead.
    param($Sandbox, [string]$InstallScriptPath = $installScript, [switch]$SkipSoundPrompt = $true, [string]$SelectedSound = $null, [string[]]$InputLines = $null)
    $argParts = @(
        '-NoProfile', '-File', $InstallScriptPath,
        '-DeployDir', $Sandbox.DeployDir,
        '-SettingsPath', $Sandbox.SettingsPath,
        '-ToolsDir', $Sandbox.ToolsDir,
        '-ProfilePath', $Sandbox.ProfilePath,
        '-SourceExePath', $Sandbox.FakeExePath
    )
    if ($SelectedSound) {
        $argParts += @('-SelectedSound', $SelectedSound)
    } elseif ($SkipSoundPrompt -and ($null -eq $InputLines)) {
        $argParts += '-SkipSoundPrompt'
    }
    $argString = ConvertTo-QuotedArgString $argParts

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = $argString
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($null -ne $InputLines) { $psi.RedirectStandardInput = $true }

    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($null -ne $InputLines) {
        # A fresh StreamWriter over the SAME underlying pipe, with UTF8
        # encoding WITHOUT a BOM preamble -- $proc.StandardInput's own default
        # encoding was observed to emit a BOM before the first write, which
        # corrupted the first simulated line (e.g. "3" arrived as "<BOM>3",
        # failing [int]::TryParse) and threw off every answer after it.
        # ProcessStartInfo.StandardInputEncoding isn't available on this .NET
        # Framework version, hence wrapping the stream manually instead.
        $noBomUtf8 = New-Object System.Text.UTF8Encoding($false)
        $writer = New-Object System.IO.StreamWriter($proc.StandardInput.BaseStream, $noBomUtf8)
        $writer.AutoFlush = $true
        # A small delay between lines (not just before the first one) --
        # writing all lines back-to-back immediately after Process.Start(),
        # before the child's own Read-Host loop has reached its first prompt,
        # was observed to intermittently lose the first queued line (the
        # child's console-input setup appears to discard whatever was already
        # buffered in the pipe at that point, rather than queuing it for the
        # first ReadLine). Pacing each write after a short wait avoids the race.
        foreach ($line in $InputLines) {
            Start-Sleep -Milliseconds 400
            $writer.WriteLine($line)
        }
        $writer.Close()
    }

    # Timeout, not an unbounded wait: a bug in the (new, interactive)
    # sound-selection flow that ends up blocking on Read-Host must fail the
    # test loudly instead of hanging the whole Pester run forever.
    if (-not $proc.WaitForExit(30000)) {
        try { $proc.Kill() } catch {}
        return -999
    }
    $proc.ExitCode
}

function Invoke-InstallScriptInteractive {
    # A throwaway dummy line is always prepended: whatever is written FIRST to
    # the child's redirected stdin was observed, empirically and consistently,
    # to arrive at the child's very first Read-Host call corrupted into a few
    # bytes of encoding-preamble garbage (non-whitespace, unparsable as a
    # number) -- reproduced in isolation independent of the encoding used to
    # write it, so it is some property of how .NET's Process class sets up a
    # redirected-stdin pipe, not this code's own encoding choice. Every line
    # written AFTER that first one arrives perfectly intact. install.ps1's own
    # loop already treats an unparsable answer as "invalid, try again" and
    # re-prompts, so the dummy line costs one harmless extra iteration and the
    # real -InputLines answers below it all land correctly.
    param($Sandbox, [string[]]$InputLines)
    Invoke-InstallScript -Sandbox $Sandbox -SkipSoundPrompt:$false -InputLines (@('') + $InputLines)
}

function Get-DeployedConfig {
    param($Sandbox)
    Get-Content (Join-Path $Sandbox.DeployDir 'config.json') -Raw | ConvertFrom-Json
}

function Invoke-UninstallScript {
    param($Sandbox)
    $argString = ConvertTo-QuotedArgString @(
        '-NoProfile', '-File', $uninstallScript,
        '-DeployDir', $Sandbox.DeployDir,
        '-SettingsPath', $Sandbox.SettingsPath,
        '-ExeDeployPath', $Sandbox.ExeDeployPath,
        '-ProfilePath', $Sandbox.ProfilePath
    )
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argString -NoNewWindow -PassThru -Wait
    $proc.ExitCode
}

function Get-SettingsJson {
    param($Sandbox)
    Get-Content $Sandbox.SettingsPath -Raw | ConvertFrom-Json
}

function Test-HookPresent {
    param($Settings, [string]$EventName, [string]$ExpectedCommand)
    $found = $false
    foreach ($group in @($Settings.hooks.$EventName)) {
        foreach ($h in @($group.hooks)) {
            if ($h.command -eq $ExpectedCommand) { $found = $true }
        }
    }
    return $found
}

$expectedHookCommands = [ordered]@{
    'Notification'     = '& "$env:USERPROFILE\.claude\tools\ClaudeAttention.exe" alert'
    'Stop'             = '& "$env:USERPROFILE\.claude\tools\ClaudeAttention.exe" done'
    'UserPromptSubmit' = '& "$env:USERPROFILE\.claude\tools\ClaudeAttention.exe" clear'
}

Describe "Installer: fresh install into an isolated sandbox" {
    BeforeEach { $sandbox = New-InstallSandbox }
    AfterEach { Remove-InstallSandbox $sandbox }

    It "deploys the exe, watcher, sounds, and config" {
        (Invoke-InstallScript -Sandbox $sandbox) | Should Be 0
        Test-Path $sandbox.ExeDeployPath | Should Be $true
        (Get-Content $sandbox.ExeDeployPath -Raw) | Should Match 'fake exe content'
        Test-Path (Join-Path $sandbox.DeployDir 'watcher-background.ps1') | Should Be $true
        Test-Path (Join-Path $sandbox.DeployDir 'test-sound.ps1') | Should Be $true
        Test-Path (Join-Path $sandbox.DeployDir 'config.json') | Should Be $true
        Test-Path (Join-Path $sandbox.DeployDir 'sounds\classic.wav') | Should Be $true
    }

    It "creates settings.json with all 3 hooks and the env key set to 1" {
        (Invoke-InstallScript -Sandbox $sandbox) | Should Be 0
        $settings = Get-SettingsJson -Sandbox $sandbox
        foreach ($eventName in $expectedHookCommands.Keys) {
            (Test-HookPresent -Settings $settings -EventName $eventName -ExpectedCommand $expectedHookCommands[$eventName]) | Should Be $true
        }
        $settings.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE | Should Be '1'
    }

    It "writes an install manifest recording the env key did not exist before" {
        (Invoke-InstallScript -Sandbox $sandbox) | Should Be 0
        $manifestPath = Join-Path $sandbox.DeployDir 'install-manifest.json'
        Test-Path $manifestPath | Should Be $true
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $manifest.envKeyExistedBefore | Should Be $false
    }

    It "creates `$PROFILE with the watcher auto-start block" {
        (Invoke-InstallScript -Sandbox $sandbox) | Should Be 0
        $profileContent = Get-Content $sandbox.ProfilePath -Raw
        $profileContent | Should Match 'Claude Tab Notifier: auto-start watcher'
    }

    It "preserves pre-existing, unrelated `$PROFILE content" {
        Set-Content -Path $sandbox.ProfilePath -Value "# my own unrelated profile line`r`nSet-Alias ll Get-ChildItem" -Encoding utf8
        (Invoke-InstallScript -Sandbox $sandbox) | Should Be 0
        $profileContent = Get-Content $sandbox.ProfilePath -Raw
        $profileContent | Should Match 'my own unrelated profile line'
        $profileContent | Should Match 'Claude Tab Notifier: auto-start watcher'
    }

    It "preserves pre-existing, unrelated settings.json content (other hooks, other keys)" {
        $preExisting = @{
            hooks = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = 'echo unrelated'; shell = 'powershell' }) }) }
            someOtherTopLevelKey = 'leave-me-alone'
        }
        ($preExisting | ConvertTo-Json -Depth 10) | Set-Content -Path $sandbox.SettingsPath -Encoding utf8

        (Invoke-InstallScript -Sandbox $sandbox) | Should Be 0
        $settings = Get-SettingsJson -Sandbox $sandbox
        $settings.someOtherTopLevelKey | Should Be 'leave-me-alone'
        (Test-HookPresent -Settings $settings -EventName 'SessionStart' -ExpectedCommand 'echo unrelated') | Should Be $true
    }

    It "records the env key's real previous value when it already existed" {
        $preExisting = @{ env = @{ CLAUDE_CODE_DISABLE_TERMINAL_TITLE = '0' } }
        ($preExisting | ConvertTo-Json -Depth 10) | Set-Content -Path $sandbox.SettingsPath -Encoding utf8

        (Invoke-InstallScript -Sandbox $sandbox) | Should Be 0
        $manifest = Get-Content (Join-Path $sandbox.DeployDir 'install-manifest.json') -Raw | ConvertFrom-Json
        $manifest.envKeyExistedBefore | Should Be $true
        $manifest.envKeyPreviousValue | Should Be '0'
        (Get-SettingsJson -Sandbox $sandbox).env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE | Should Be '1'
    }

    It "is idempotent: running twice does not duplicate hooks or the profile block" {
        (Invoke-InstallScript -Sandbox $sandbox) | Should Be 0
        (Invoke-InstallScript -Sandbox $sandbox) | Should Be 0

        $settings = Get-SettingsJson -Sandbox $sandbox
        $stopGroups = @($settings.hooks.Stop)
        $stopHookCount = 0
        foreach ($group in $stopGroups) {
            foreach ($h in @($group.hooks)) {
                if ($h.command -eq $expectedHookCommands['Stop']) { $stopHookCount++ }
            }
        }
        $stopHookCount | Should Be 1

        $profileContent = Get-Content $sandbox.ProfilePath -Raw
        ([regex]::Matches($profileContent, 'Claude Tab Notifier: auto-start watcher')).Count | Should Be 1
    }
}

Describe "Uninstaller: full cycle in an isolated sandbox" {
    BeforeEach {
        $sandbox = New-InstallSandbox
        (Invoke-InstallScript -Sandbox $sandbox) | Should Be 0
    }
    AfterEach { Remove-InstallSandbox $sandbox }

    It "removes the deployed exe, watcher, and sound assets" {
        (Invoke-UninstallScript -Sandbox $sandbox) | Should Be 0
        Test-Path $sandbox.ExeDeployPath | Should Be $false
        Test-Path (Join-Path $sandbox.DeployDir 'watcher-background.ps1') | Should Be $false
    }

    It "removes all 3 hooks from settings.json" {
        (Invoke-UninstallScript -Sandbox $sandbox) | Should Be 0
        $settings = Get-SettingsJson -Sandbox $sandbox
        foreach ($eventName in $expectedHookCommands.Keys) {
            (Test-HookPresent -Settings $settings -EventName $eventName -ExpectedCommand $expectedHookCommands[$eventName]) | Should Be $false
        }
    }

    It "removes the env key entirely when the manifest says it did not exist before" {
        (Invoke-UninstallScript -Sandbox $sandbox) | Should Be 0
        $settings = Get-SettingsJson -Sandbox $sandbox
        $settings.env.PSObject.Properties['CLAUDE_CODE_DISABLE_TERMINAL_TITLE'] | Should Be $null
    }

    It "removes the watcher auto-start block from `$PROFILE" {
        (Invoke-UninstallScript -Sandbox $sandbox) | Should Be 0
        $profileContent = Get-Content $sandbox.ProfilePath -Raw
        $profileContent | Should Not Match 'Claude Tab Notifier: auto-start watcher'
    }

    It "removes the manifest and the now-empty deploy directory" {
        (Invoke-UninstallScript -Sandbox $sandbox) | Should Be 0
        Test-Path (Join-Path $sandbox.DeployDir 'install-manifest.json') | Should Be $false
        Test-Path $sandbox.DeployDir | Should Be $false
    }
}

Describe "Uninstaller: preserves what it did not install" {
    BeforeEach {
        $sandbox = New-InstallSandbox
        Set-Content -Path $sandbox.ProfilePath -Value "# my own unrelated profile line" -Encoding utf8
        $preExisting = @{
            hooks = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = 'echo unrelated'; shell = 'powershell' }) }) }
            someOtherTopLevelKey = 'leave-me-alone'
        }
        ($preExisting | ConvertTo-Json -Depth 10) | Set-Content -Path $sandbox.SettingsPath -Encoding utf8
        (Invoke-InstallScript -Sandbox $sandbox) | Should Be 0
    }
    AfterEach { Remove-InstallSandbox $sandbox }

    It "leaves unrelated settings.json content and `$PROFILE content intact" {
        (Invoke-UninstallScript -Sandbox $sandbox) | Should Be 0
        $settings = Get-SettingsJson -Sandbox $sandbox
        $settings.someOtherTopLevelKey | Should Be 'leave-me-alone'
        (Test-HookPresent -Settings $settings -EventName 'SessionStart' -ExpectedCommand 'echo unrelated') | Should Be $true
        (Get-Content $sandbox.ProfilePath -Raw) | Should Match 'my own unrelated profile line'
    }

    It "restores the env key to its real original value instead of removing it" {
        # This sandbox's settings.json had no env key before install, so exercise
        # the "existed before" restore path directly against the manifest+settings.
        $manifestPath = Join-Path $sandbox.DeployDir 'install-manifest.json'
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $manifest.envKeyExistedBefore = $true
        $manifest.envKeyPreviousValue = 'my-custom-value'
        ($manifest | ConvertTo-Json -Depth 5) | Set-Content -Path $manifestPath -Encoding utf8

        (Invoke-UninstallScript -Sandbox $sandbox) | Should Be 0
        (Get-SettingsJson -Sandbox $sandbox).env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE | Should Be 'my-custom-value'
    }
}

Describe "Uninstaller: nothing installed yet" {
    BeforeEach { $sandbox = New-InstallSandbox }
    AfterEach { Remove-InstallSandbox $sandbox }

    It "exits successfully and makes no changes when settings.json and `$PROFILE do not exist" {
        (Invoke-UninstallScript -Sandbox $sandbox) | Should Be 0
        Test-Path $sandbox.SettingsPath | Should Be $false
        Test-Path $sandbox.ProfilePath | Should Be $false
    }
}

Describe "Installer: strips Mark of the Web from a downloaded-ZIP install" {
    # Regression test for a real bug found via an actual install from a
    # downloaded GitHub ZIP: RemoteSigned (a common execution policy) refuses
    # to run an internet-zone-tagged, unsigned .ps1, so the watcher silently
    # failed to auto-start with "is not digitally signed". install.ps1 now
    # runs Unblock-File on everything it deploys.
    BeforeEach {
        $sandbox = New-InstallSandbox
        $stagedInstallScript = New-StagedInstallScript -Sandbox $sandbox
        $stageDir = Split-Path $stagedInstallScript -Parent
        $stagedWatcher = Join-Path $stageDir 'watcher-background.ps1'
        $stagedTestSound = Join-Path $stageDir 'test-sound.ps1'
        Add-MarkOfTheWeb -Path $stagedWatcher
        Add-MarkOfTheWeb -Path $stagedTestSound
        Add-MarkOfTheWeb -Path $sandbox.FakeExePath
    }
    AfterEach { Remove-InstallSandbox $sandbox }

    It "sanity check: the staged source files are actually tagged before install" {
        (Test-HasMarkOfTheWeb -Path $stagedWatcher) | Should Be $true
        (Test-HasMarkOfTheWeb -Path $stagedTestSound) | Should Be $true
        (Test-HasMarkOfTheWeb -Path $sandbox.FakeExePath) | Should Be $true
    }

    It "deploys watcher-background.ps1, test-sound.ps1, and the exe without the Mark of the Web tag" {
        (Invoke-InstallScript -Sandbox $sandbox -InstallScriptPath $stagedInstallScript) | Should Be 0

        $deployedWatcher = Join-Path $sandbox.DeployDir 'watcher-background.ps1'
        $deployedTestSound = Join-Path $sandbox.DeployDir 'test-sound.ps1'
        Test-Path $deployedWatcher | Should Be $true
        Test-Path $deployedTestSound | Should Be $true
        Test-Path $sandbox.ExeDeployPath | Should Be $true

        (Test-HasMarkOfTheWeb -Path $deployedWatcher) | Should Be $false
        (Test-HasMarkOfTheWeb -Path $deployedTestSound) | Should Be $false
        (Test-HasMarkOfTheWeb -Path $sandbox.ExeDeployPath) | Should Be $false
    }
}

$allSoundKeys = @('classic','chime','soft','alert','retro','magic','digital','double','scifi','success')

function Set-PreDeployedConfig {
    # Seeds a config.json at the deploy location BEFORE install.ps1 runs, so
    # the installer's own "config.json already exists -- left untouched" logic
    # (step 2) leaves it in place for the sound-selection step (step 3) to read
    # -- exactly what a real re-install against a customized config looks like.
    param($Sandbox, [string]$SelectedSound = 'classic', [bool]$SoundEnabled = $true, [string]$CustomSoundFile = '')
    New-Item -ItemType Directory -Path $Sandbox.DeployDir -Force | Out-Null
    $cfg = @{ soundEnabled = $SoundEnabled; selectedSound = $SelectedSound; customSoundFile = $CustomSoundFile }
    ($cfg | ConvertTo-Json -Compress) | Set-Content -Path (Join-Path $Sandbox.DeployDir 'config.json') -Encoding utf8
}

Describe "Installer: sound selection" {
    BeforeEach { $sandbox = New-InstallSandbox }
    AfterEach { Remove-InstallSandbox $sandbox }

    foreach ($soundName in $allSoundKeys) {
        It "-SelectedSound '$soundName' sets selectedSound directly, no prompt" {
            (Invoke-InstallScript -Sandbox $sandbox -SelectedSound $soundName) | Should Be 0
            (Get-DeployedConfig -Sandbox $sandbox).selectedSound | Should Be $soundName
        }
    }

    It "an unrecognized -SelectedSound is rejected and falls back to the current/default value" {
        (Invoke-InstallScript -Sandbox $sandbox -SelectedSound 'not-a-real-sound') | Should Be 0
        (Get-DeployedConfig -Sandbox $sandbox).selectedSound | Should Be 'classic'
    }

    It "a fresh install with no sound choice at all defaults to classic (-SkipSoundPrompt)" {
        (Invoke-InstallScript -Sandbox $sandbox) | Should Be 0
        (Get-DeployedConfig -Sandbox $sandbox).selectedSound | Should Be 'classic'
    }

    It "interactive: a valid numeric choice, then confirming yes, selects that sound" {
        # "3" = soft, "" (blank) = confirm yes
        (Invoke-InstallScriptInteractive -Sandbox $sandbox -InputLines @('3', '')) | Should Be 0
        (Get-DeployedConfig -Sandbox $sandbox).selectedSound | Should Be 'soft'
    }

    It "interactive: an invalid number is rejected and re-prompts instead of crashing" {
        # "55" invalid -> re-prompted -> "3" = soft -> "" confirm yes
        (Invoke-InstallScriptInteractive -Sandbox $sandbox -InputLines @('55', '3', '')) | Should Be 0
        (Get-DeployedConfig -Sandbox $sandbox).selectedSound | Should Be 'soft'
    }

    It "interactive: answering 'no' to the confirmation re-prompts instead of saving that choice" {
        # "3" = soft, "n" = reject it, "5" = retro, "" = confirm yes
        (Invoke-InstallScriptInteractive -Sandbox $sandbox -InputLines @('3', 'n', '5', '')) | Should Be 0
        (Get-DeployedConfig -Sandbox $sandbox).selectedSound | Should Be 'retro'
    }

    It "interactive: pressing Enter with no prior config keeps the classic default" {
        (Invoke-InstallScriptInteractive -Sandbox $sandbox -InputLines @('')) | Should Be 0
        (Get-DeployedConfig -Sandbox $sandbox).selectedSound | Should Be 'classic'
    }

    It "interactive: pressing Enter on a re-install preserves the existing selectedSound" {
        (Invoke-InstallScript -Sandbox $sandbox -SelectedSound 'magic') | Should Be 0
        (Invoke-InstallScriptInteractive -Sandbox $sandbox -InputLines @('')) | Should Be 0
        (Get-DeployedConfig -Sandbox $sandbox).selectedSound | Should Be 'magic'
    }

    It "a plain -SkipSoundPrompt re-install preserves the existing selectedSound too" {
        (Invoke-InstallScript -Sandbox $sandbox -SelectedSound 'success') | Should Be 0
        (Invoke-InstallScript -Sandbox $sandbox) | Should Be 0
        (Get-DeployedConfig -Sandbox $sandbox).selectedSound | Should Be 'success'
    }

    It "does not change soundEnabled when only selectedSound is chosen" {
        Set-PreDeployedConfig -Sandbox $sandbox -SelectedSound 'classic' -SoundEnabled $false
        (Invoke-InstallScript -Sandbox $sandbox -SelectedSound 'chime') | Should Be 0
        $cfg = Get-DeployedConfig -Sandbox $sandbox
        $cfg.selectedSound | Should Be 'chime'
        $cfg.soundEnabled | Should Be $false
    }

    It "does not touch customSoundFile when switching away from 'custom'" {
        Set-PreDeployedConfig -Sandbox $sandbox -SelectedSound 'custom' -CustomSoundFile 'C:\custom\ping.wav'
        (Invoke-InstallScript -Sandbox $sandbox -SelectedSound 'retro') | Should Be 0
        $cfg = Get-DeployedConfig -Sandbox $sandbox
        $cfg.selectedSound | Should Be 'retro'
        $cfg.customSoundFile | Should Be 'C:\custom\ping.wav'
    }

    It "keeps 'custom' and customSoundFile untouched when the prompt is skipped" {
        Set-PreDeployedConfig -Sandbox $sandbox -SelectedSound 'custom' -CustomSoundFile 'C:\custom\ping.wav'
        (Invoke-InstallScript -Sandbox $sandbox) | Should Be 0
        $cfg = Get-DeployedConfig -Sandbox $sandbox
        $cfg.selectedSound | Should Be 'custom'
        $cfg.customSoundFile | Should Be 'C:\custom\ping.wav'
    }

    It "a missing/corrupt deployed config.json does not crash the installer" {
        New-Item -ItemType Directory -Path $sandbox.DeployDir -Force | Out-Null
        Set-Content -Path (Join-Path $sandbox.DeployDir 'config.json') -Value '{ this is not valid json' -Encoding utf8
        (Invoke-InstallScript -Sandbox $sandbox) | Should Be 0
        Test-Path $sandbox.ExeDeployPath | Should Be $true
    }

    It "soundEnabled=false: interactive selection still works, declining the extra preview prompt" {
        Set-PreDeployedConfig -Sandbox $sandbox -SelectedSound 'classic' -SoundEnabled $false
        # "7" = digital, "n" = decline the extra "preview anyway?" question, "" = confirm yes
        (Invoke-InstallScriptInteractive -Sandbox $sandbox -InputLines @('7', 'n', '')) | Should Be 0
        $cfg = Get-DeployedConfig -Sandbox $sandbox
        $cfg.selectedSound | Should Be 'digital'
        $cfg.soundEnabled | Should Be $false
    }
}
