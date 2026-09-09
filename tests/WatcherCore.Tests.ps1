Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

# Tests watcher-background.ps1 (PowerShell, in-process runspace) and
# watcher-cmd.ps1 (CMD, separate process) as black boxes -- unmodified,
# driven only via real state/config/heartbeat files on isolated sandbox
# paths. Covers: MARKED -> CLEARED -> MARKED, deduplication, heartbeat
# schema, sound configuration (all built-ins + custom + missing), and
# config.json / state-file edge cases (missing, malformed).

$builtInSounds = @('alert','chime','classic','digital','double','magic','retro','scifi','soft','success')

# Codepoint reference for the built-in emoji catalog -- mirrors the catalogs
# duplicated in watcher-background.ps1/watcher-cmd.ps1/install.ps1, used here
# only to compute the expected glyph string for assertions (never to drive
# the watcher itself, which resolves its own emoji internally from config.json).
$emojiCodepoints = @{
    sparkle = @(0x2728); star = @(0x2B50); bell = @(0x1F514); bolt = @(0x26A1); fire = @(0x1F525)
    target  = @(0x1F3AF); check = @(0x2705); reddot = @(0x1F534); eyes = @(0x1F440); chat = @(0x1F4AC)
    heart   = @(0x2764, 0xFE0F); music = @(0x1F3B5)
}
function Get-EmojiChar {
    param([string]$Name)
    -join ($emojiCodepoints[$Name] | ForEach-Object { [System.Char]::ConvertFromUtf32($_) })
}

function Set-SandboxConfig {
    param($Sandbox, [bool]$SoundEnabled = $true, [string]$SelectedSound = 'classic', [string]$CustomSoundFile = '', [string]$SelectedEmoji = 'sparkle', [bool]$EmojiEnabled = $true)
    $cfg = @{ soundEnabled = $SoundEnabled; selectedSound = $SelectedSound; customSoundFile = $CustomSoundFile; selectedEmoji = $SelectedEmoji; emojiEnabled = $EmojiEnabled }
    ($cfg | ConvertTo-Json -Compress) | Set-Content -Path $Sandbox.ConfigPath -Encoding utf8
}

function Set-SandboxConfigRaw {
    param($Sandbox, [string]$RawText)
    Set-Content -Path $Sandbox.ConfigPath -Value $RawText -Encoding utf8
}

function Invoke-PsWatcherWithoutWtSession {
    # Runs watcher-background.ps1 as a standalone process with WT_SESSION
    # explicitly removed (regardless of this test-runner's own ambient value
    # -- it has one, being a real Windows Terminal session itself), and
    # captures stdout/stderr. Without WT_SESSION the script returns almost
    # immediately, so plain -Command (no -NoExit) correctly lets the process
    # exit on its own -- redirecting output is safe here specifically because
    # nothing keeps the process alive waiting on stdin. (For the "watcher
    # actually keeps running" case, -NoExit does NOT keep a process alive
    # once its stdio is redirected -- confirmed empirically -- so that case
    # is tested via the existing, proven Start-IsolatedPsWatcher instead,
    # which never redirects anything.)
    param($Sandbox)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -Command `"& '$($Sandbox.PsWatcher)'`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $Sandbox.LocalAppData
    $psi.EnvironmentVariables.Remove('WT_SESSION')
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $exited = $proc.WaitForExit(5000)
    if (-not $exited) {
        $Sandbox.TrackedPids.Add($proc.Id)
    }
    [PSCustomObject]@{ ExitCode = $(if ($exited) { $proc.ExitCode } else { $null }); Stdout = $stdout; Stderr = $stderr; Exited = $exited }
}

Describe "Watcher core behavior (PowerShell)" {
    BeforeEach {
        $sandbox = New-TestSandbox
        $wt = New-FakeWtSession
    }
    AfterEach { Remove-TestSandbox $sandbox }

    It "heartbeat schema: pid/parentPid/shell present and shell=powershell" {
        $proc = Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt
        $hb = Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt
        $hb | Should Not Be $null
        $hb.pid | Should Be $proc.Id
        $hb.shell | Should Be 'powershell'
        ($hb.PSObject.Properties.Name -contains 'parentPid') | Should Be $true
        ($hb.PSObject.Properties.Name -contains 'time') | Should Be $true
    }

    It "without WT_SESSION: exits cleanly, prints nothing, creates no state directory" {
        $result = Invoke-PsWatcherWithoutWtSession -Sandbox $sandbox
        $result.Exited | Should Be $true
        $result.ExitCode | Should Be 0
        $result.Stdout | Should BeNullOrEmpty
        $result.Stderr | Should BeNullOrEmpty
        Test-Path $sandbox.StateDir | Should Be $false
    }

    It "with WT_SESSION: starts normally and creates a heartbeat (no regression from the silent-exit fix)" {
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        (Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt) | Should Not Be $null
    }

    It "MARKED -> CLEARED -> MARKED across a full cycle" {
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'MARKED') | Should Be $true

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'clear'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'CLEARED') | Should Be $true

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        $ok = Wait-ForCondition -TimeoutMs 6000 -Condition {
            $lines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wt)
            (@($lines | Where-Object { $_ -match 'MARKED' })).Count -ge 2
        }
        $ok | Should Be $true
    }

    It "deduplication: repeated needsAttention writes produce only one MARKED" {
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'MARKED') | Should Be $true

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        Start-Sleep -Milliseconds 1500

        $lines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wt)
        (@($lines | Where-Object { $_ -match 'MARKED' })).Count | Should Be 1
    }

    It "sound disabled: no sound line logged on MARKED" {
        Set-SandboxConfig -Sandbox $sandbox -SoundEnabled $false
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'MARKED') | Should Be $true
        Start-Sleep -Milliseconds 800

        $lines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wt)
        (@($lines | Where-Object { $_ -match 'sound (played|SKIPPED|FAILED)' })).Count | Should Be 0
    }

    foreach ($soundName in $builtInSounds) {
        It "sound selection '$soundName' plays the matching built-in file" {
            Set-SandboxConfig -Sandbox $sandbox -SoundEnabled $true -SelectedSound $soundName
            Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
            Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

            Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
            $ok = Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern ([regex]::Escape("sound played") + '.*' + [regex]::Escape("$soundName.wav"))
            $ok | Should Be $true
        }
    }

    It "custom sound file (absolute path) plays correctly" {
        $customPath = Join-Path $sandbox.SoundsDir 'classic.wav'
        Set-SandboxConfig -Sandbox $sandbox -SoundEnabled $true -SelectedSound 'custom' -CustomSoundFile $customPath
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        $ok = Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern ([regex]::Escape("sound played: $customPath"))
        $ok | Should Be $true
    }

    It "missing custom sound file logs SKIPPED: file not found" {
        $missingPath = Join-Path $sandbox.SoundsDir 'does-not-exist.wav'
        Set-SandboxConfig -Sandbox $sandbox -SoundEnabled $true -SelectedSound 'custom' -CustomSoundFile $missingPath
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        $ok = Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'sound SKIPPED: file not found'
        $ok | Should Be $true
    }

    It "non-WAV file selected as custom sound is skipped as invalid" {
        $notWav = Join-Path $sandbox.SoundsDir 'not-a-wav.wav'
        Set-Content -Path $notWav -Value "this is not a wav file" -Encoding ascii
        Set-SandboxConfig -Sandbox $sandbox -SoundEnabled $true -SelectedSound 'custom' -CustomSoundFile $notWav
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        $ok = Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'not a valid WAV file'
        $ok | Should Be $true
    }

    It "missing config.json falls back to defaults (classic, enabled) without crashing" {
        Remove-Item $sandbox.ConfigPath -Force
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        $ok = Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern ([regex]::Escape("sound played") + '.*classic\.wav')
        $ok | Should Be $true
    }

    It "malformed config.json falls back to defaults without crashing" {
        Set-SandboxConfigRaw -Sandbox $sandbox -RawText '{ this is not : valid json ]'
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        $ok = Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern ([regex]::Escape("sound played") + '.*classic\.wav')
        $ok | Should Be $true
    }

    It "malformed state file JSON does not crash the loop; a later valid write still marks" {
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        $statePath = Get-StatePath $sandbox $wt
        Set-Content -Path $statePath -Value '{ broken' -Encoding utf8
        Start-Sleep -Milliseconds 1200

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'MARKED') | Should Be $true
    }

    It "no animation before needsAttention: heartbeat title stays exactly the original title" {
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        $hb1 = Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt
        $hb1 | Should Not Be $null
        $baseline = $hb1.title
        $baseline | Should Not BeNullOrEmpty

        Start-Sleep -Milliseconds 1200
        (Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt).title | Should Be $baseline
    }

    foreach ($emojiName in @('sparkle','star','bell','bolt','fire','target','check','reddot','eyes','chat','heart','music')) {
        It "emoji selection '$emojiName' animates that exact glyph in the title, never a different one" {
            Set-SandboxConfig -Sandbox $sandbox -SoundEnabled $true -SelectedEmoji $emojiName
            Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
            $hb1 = Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt
            $baseline = $hb1.title
            $glyph = Get-EmojiChar $emojiName

            Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
            (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'MARKED') | Should Be $true
            # heartbeat.title lags the real (immediately-updated) console title
            # by up to one 500ms tick -- it's refreshed at the START of the
            # NEXT loop iteration after a transition, not within the
            # transition itself. A full tick of margin avoids a race here.
            Start-Sleep -Milliseconds 700

            $hb = Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt
            $hb.title.EndsWith(" $baseline") | Should Be $true
            $emojiRun = $hb.title.Substring(0, $hb.title.Length - $baseline.Length - 1)
            $emojiRun.Length | Should BeGreaterThan 0
            ($emojiRun.Length % $glyph.Length) | Should Be 0
            $repeatCount = $emojiRun.Length / $glyph.Length
            $emojiRun | Should Be ($glyph * $repeatCount)
        }
    }

    It "the pulse cycles the same emoji through 1, 2, 3, 2 repeats -- a real grow/shrink pattern, not a static mark" {
        Set-SandboxConfig -Sandbox $sandbox -SoundEnabled $true -SelectedEmoji 'star'
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        $hb1 = Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt
        $baseline = $hb1.title
        $glyph = Get-EmojiChar 'star'

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'MARKED') | Should Be $true

        $counts = @()
        for ($i = 0; $i -lt 7; $i++) {
            Start-Sleep -Milliseconds 550
            $hb = Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt
            $hb.title.EndsWith(" $baseline") | Should Be $true
            $emojiRun = $hb.title.Substring(0, $hb.title.Length - $baseline.Length - 1)
            $emojiRun | Should Be ($glyph * ($emojiRun.Length / $glyph.Length))
            $counts += ($emojiRun.Length / $glyph.Length)
        }

        # Every observed frame is a valid pulse amplitude (1, 2, or 3 copies)...
        (@($counts | Where-Object { $_ -notin @(1, 2, 3) })).Count | Should Be 0
        # ...it's actually animating, not stuck on one size...
        (@($counts | Select-Object -Unique)).Count | Should BeGreaterThan 1
        # ...and it moves smoothly (a triangle wave: each step is +/-1), which a
        # second, independent animation loop racing this one would be very
        # unlikely to preserve across 6 consecutive transitions.
        for ($i = 1; $i -lt $counts.Count; $i++) {
            ([Math]::Abs($counts[$i] - $counts[$i - 1])) | Should Be 1
        }
    }

    It "CLEARED stops the animation and restores the original title exactly, and it stays that way" {
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        $hb1 = Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt
        $baseline = $hb1.title

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'MARKED') | Should Be $true
        Start-Sleep -Milliseconds 1200
        (Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt).title | Should Not Be $baseline

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'clear'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'CLEARED') | Should Be $true
        # Same one-tick heartbeat lag as noted above, in reverse.
        Start-Sleep -Milliseconds 700
        (Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt).title | Should Be $baseline

        # No residual ticking after clear -- it does not drift or resume animating.
        Start-Sleep -Milliseconds 1200
        (Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt).title | Should Be $baseline
    }

    It "two parallel sessions animate independently -- marking one does not affect the other" {
        $wt2 = New-FakeWtSession
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt2 | Out-Null
        $baseline1 = (Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt).title
        $baseline2 = (Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt2).title

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'MARKED') | Should Be $true
        Start-Sleep -Milliseconds 600

        (Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt).title | Should Not Be $baseline1
        (Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt2).title | Should Be $baseline2
    }

    It "emojiEnabled=false: title never changes even when marked, but MARKED still dedups correctly (state lifecycle keeps working)" {
        Set-SandboxConfig -Sandbox $sandbox -SoundEnabled $false -EmojiEnabled $false
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        $baseline = (Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt).title

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'MARKED') | Should Be $true
        Start-Sleep -Milliseconds 1200
        # Title stays exactly the baseline the whole time it's marked -- no pulse.
        (Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt).title | Should Be $baseline

        # Dedup still works: a second needsAttention write before clearing must
        # NOT produce a second MARKED line -- proves $marked is still tracked
        # correctly even though nothing about the title itself ever changes.
        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        Start-Sleep -Milliseconds 800
        $lines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wt)
        (@($lines | Where-Object { $_ -match 'MARKED' })).Count | Should Be 1

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'clear'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'CLEARED') | Should Be $true
        (Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt).title | Should Be $baseline

        # A full second mark->clear cycle still re-triggers cleanly.
        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        $ok = Wait-ForCondition -TimeoutMs 6000 -Condition {
            $lines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wt)
            (@($lines | Where-Object { $_ -match 'MARKED' })).Count -ge 2
        }
        $ok | Should Be $true
        (Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt).title | Should Be $baseline
    }

    It "emojiEnabled=false + soundEnabled=true: sound still plays even though the title never changes (independence)" {
        Set-SandboxConfig -Sandbox $sandbox -SoundEnabled $true -SelectedSound 'classic' -EmojiEnabled $false
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        $baseline = (Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt).title

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        $ok = Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern ([regex]::Escape("sound played") + '.*classic\.wav')
        $ok | Should Be $true
        Start-Sleep -Milliseconds 300
        (Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt).title | Should Be $baseline
    }

    It "soundEnabled=false + emojiEnabled=true: title still pulses even though no sound plays (independence)" {
        Set-SandboxConfig -Sandbox $sandbox -SoundEnabled $false -SelectedEmoji 'star' -EmojiEnabled $true
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        $baseline = (Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt).title
        $glyph = Get-EmojiChar 'star'

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'MARKED') | Should Be $true
        Start-Sleep -Milliseconds 700
        $hb = Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt
        $hb.title.EndsWith(" $baseline") | Should Be $true
        $emojiRun = $hb.title.Substring(0, $hb.title.Length - $baseline.Length - 1)
        $emojiRun | Should Be ($glyph * ($emojiRun.Length / $glyph.Length))

        Start-Sleep -Milliseconds 800
        $lines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wt)
        (@($lines | Where-Object { $_ -match 'sound (played|SKIPPED|FAILED)' })).Count | Should Be 0
    }

    It "both sound and emoji disabled: no sound lines, no title change, MARKED/CLEARED still fire" {
        Set-SandboxConfig -Sandbox $sandbox -SoundEnabled $false -EmojiEnabled $false
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        $baseline = (Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt).title

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'MARKED') | Should Be $true
        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'clear'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'CLEARED') | Should Be $true

        (Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt).title | Should Be $baseline
        $lines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wt)
        (@($lines | Where-Object { $_ -match 'sound (played|SKIPPED|FAILED)' })).Count | Should Be 0
    }
}

Describe "Watcher core behavior (CMD)" {
    BeforeEach {
        $sandbox = New-TestSandbox
        $wt = New-FakeWtSession
    }
    AfterEach { Remove-TestSandbox $sandbox }

    function Start-TrackedCmdWatcher {
        param($Sandbox, [string]$WtSession)
        $fakeParent = Start-IsolatedCmdWatcher -Sandbox $Sandbox -WtSession $WtSession
        $hb = Wait-ForHeartbeat -Sandbox $Sandbox -WtSession $WtSession
        if ($null -ne $hb) { $Sandbox.TrackedPids.Add([int]$hb.pid) }
        [PSCustomObject]@{ FakeParent = $fakeParent; Heartbeat = $hb }
    }

    It "heartbeat schema: parentPid=fake-parent pid, shell=cmd, watcher pid is a distinct live process" {
        $started = Start-TrackedCmdWatcher -Sandbox $sandbox -WtSession $wt
        $started.Heartbeat | Should Not Be $null
        $started.Heartbeat.shell | Should Be 'cmd'
        $started.Heartbeat.parentPid | Should Be $started.FakeParent.Id
        $started.Heartbeat.pid | Should Not Be $started.FakeParent.Id
        (Test-ProcessAlive -ProcessId ([int]$started.Heartbeat.pid)) | Should Be $true
    }

    It "MARKED -> CLEARED -> MARKED across a full cycle" {
        Start-TrackedCmdWatcher -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'MARKED') | Should Be $true

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'clear'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'CLEARED') | Should Be $true

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        $ok = Wait-ForCondition -TimeoutMs 6000 -Condition {
            $lines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wt)
            (@($lines | Where-Object { $_ -match 'MARKED' })).Count -ge 2
        }
        $ok | Should Be $true
    }

    It "deduplication: repeated needsAttention writes produce only one MARKED" {
        Start-TrackedCmdWatcher -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'MARKED') | Should Be $true

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        Start-Sleep -Milliseconds 1500

        $lines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wt)
        (@($lines | Where-Object { $_ -match 'MARKED' })).Count | Should Be 1
    }

    It "sound disabled: no sound line logged on MARKED" {
        Set-SandboxConfig -Sandbox $sandbox -SoundEnabled $false
        Start-TrackedCmdWatcher -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'MARKED') | Should Be $true
        Start-Sleep -Milliseconds 800

        $lines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wt)
        (@($lines | Where-Object { $_ -match 'sound (played|SKIPPED|FAILED)' })).Count | Should Be 0
    }

    foreach ($soundName in $builtInSounds) {
        It "sound selection '$soundName' plays the matching built-in file" {
            Set-SandboxConfig -Sandbox $sandbox -SoundEnabled $true -SelectedSound $soundName
            Start-TrackedCmdWatcher -Sandbox $sandbox -WtSession $wt | Out-Null

            Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
            $ok = Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern ([regex]::Escape("sound played") + '.*' + [regex]::Escape("$soundName.wav"))
            $ok | Should Be $true
        }
    }

    It "missing config.json falls back to defaults (classic, enabled) without crashing" {
        Remove-Item $sandbox.ConfigPath -Force
        Start-TrackedCmdWatcher -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        $ok = Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern ([regex]::Escape("sound played") + '.*classic\.wav')
        $ok | Should Be $true
    }

    It "malformed config.json falls back to defaults without crashing" {
        Set-SandboxConfigRaw -Sandbox $sandbox -RawText '{ this is not : valid json ]'
        Start-TrackedCmdWatcher -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        $ok = Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern ([regex]::Escape("sound played") + '.*classic\.wav')
        $ok | Should Be $true
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'failed to read config\.json' -TimeoutMs 500) | Should Be $true
    }

    It "self-terminates when its fake parent process dies (orphan detection)" {
        $started = Start-TrackedCmdWatcher -Sandbox $sandbox -WtSession $wt
        $watcherPid = [int]$started.Heartbeat.pid

        Stop-Process -Id $started.FakeParent.Id -Force

        $ok = Wait-ForCondition -TimeoutMs 16000 -PollMs 500 -Condition {
            -not (Test-ProcessAlive -ProcessId $watcherPid)
        }
        $ok | Should Be $true
        Test-Path (Get-StatePath $sandbox $wt) | Should Be $false
        Test-Path (Get-HeartbeatPath $sandbox $wt) | Should Be $false
    }

    # Core emoji-pulse behavior for the CMD shell -- not the full 10-emoji
    # sweep (already covered exhaustively for PowerShell above, and both
    # shells share the exact same catalog/animation logic, only duplicated
    # verbatim per this file's existing convention), just proof that the
    # duplicated catalog and pulse loop work correctly in this shell too.
    It "emoji selection 'bell' animates that exact glyph in the title, never a different one" {
        Set-SandboxConfig -Sandbox $sandbox -SoundEnabled $true -SelectedEmoji 'bell'
        $started = Start-TrackedCmdWatcher -Sandbox $sandbox -WtSession $wt
        $baseline = $started.Heartbeat.title
        $baseline | Should Not BeNullOrEmpty
        $glyph = Get-EmojiChar 'bell'

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'MARKED') | Should Be $true
        # heartbeat.title lags the real (immediately-updated) console title by
        # up to one 500ms tick -- see the PowerShell describe block above.
        Start-Sleep -Milliseconds 700

        $hb = Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt
        $hb.title.EndsWith(" $baseline") | Should Be $true
        $emojiRun = $hb.title.Substring(0, $hb.title.Length - $baseline.Length - 1)
        $emojiRun.Length | Should BeGreaterThan 0
        $emojiRun | Should Be ($glyph * ($emojiRun.Length / $glyph.Length))
    }

    It "CLEARED stops the animation and restores the original title exactly" {
        $started = Start-TrackedCmdWatcher -Sandbox $sandbox -WtSession $wt
        $baseline = $started.Heartbeat.title

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'MARKED') | Should Be $true
        Start-Sleep -Milliseconds 1200
        (Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt).title | Should Not Be $baseline

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'clear'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'CLEARED') | Should Be $true
        Start-Sleep -Milliseconds 700
        (Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt).title | Should Be $baseline
    }

    # Core independent-enable/disable behavior for the CMD shell -- not the
    # full combination sweep (already covered exhaustively for PowerShell
    # above, and both shells share the exact same gating logic, only
    # duplicated verbatim per this file's existing convention).
    It "emojiEnabled=false: title never changes even when marked, but sound and dedup still work" {
        Set-SandboxConfig -Sandbox $sandbox -SoundEnabled $true -SelectedSound 'classic' -EmojiEnabled $false
        $started = Start-TrackedCmdWatcher -Sandbox $sandbox -WtSession $wt
        $baseline = $started.Heartbeat.title

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        $ok = Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern ([regex]::Escape("sound played") + '.*classic\.wav')
        $ok | Should Be $true
        Start-Sleep -Milliseconds 300
        (Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt).title | Should Be $baseline
    }

    It "both sound and emoji disabled: no sound lines, no title change, MARKED/CLEARED still fire" {
        Set-SandboxConfig -Sandbox $sandbox -SoundEnabled $false -EmojiEnabled $false
        $started = Start-TrackedCmdWatcher -Sandbox $sandbox -WtSession $wt
        $baseline = $started.Heartbeat.title

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'MARKED') | Should Be $true
        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'clear'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'CLEARED') | Should Be $true

        (Get-HeartbeatEntry -Sandbox $sandbox -WtSession $wt).title | Should Be $baseline
        $lines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wt)
        (@($lines | Where-Object { $_ -match 'sound (played|SKIPPED|FAILED)' })).Count | Should Be 0
    }
}
