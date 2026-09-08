Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

# Tests watcher-background.ps1 (PowerShell, in-process runspace) and
# watcher-cmd.ps1 (CMD, separate process) as black boxes -- unmodified,
# driven only via real state/config/heartbeat files on isolated sandbox
# paths. Covers: MARKED -> CLEARED -> MARKED, deduplication, heartbeat
# schema, sound configuration (all built-ins + custom + missing), and
# config.json / state-file edge cases (missing, malformed).

$builtInSounds = @('alert','chime','classic','digital','double','magic','retro','scifi','soft','success')

function Set-SandboxConfig {
    param($Sandbox, [bool]$SoundEnabled = $true, [string]$SelectedSound = 'classic', [string]$CustomSoundFile = '')
    $cfg = @{ soundEnabled = $SoundEnabled; selectedSound = $SelectedSound; customSoundFile = $CustomSoundFile }
    ($cfg | ConvertTo-Json -Compress) | Set-Content -Path $Sandbox.ConfigPath -Encoding utf8
}

function Set-SandboxConfigRaw {
    param($Sandbox, [string]$RawText)
    Set-Content -Path $Sandbox.ConfigPath -Value $RawText -Encoding utf8
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
}
