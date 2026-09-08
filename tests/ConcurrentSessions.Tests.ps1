Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

# Multiple watchers (PS and/or CMD) sharing the SAME sandbox state directory
# simultaneously -- exactly what happens with several real Windows Terminal
# tabs open at once, all pointed at the same %LOCALAPPDATA%\ClaudeTabNotifier
# \state. Verifies each session's own state/heartbeat/log files are fully
# independent: marking or clearing one session must never affect another's
# title-marking state, and a live session must never be swept just because
# another session's startup sweep happens to run at the same time.

Describe "Concurrent sessions: no cross-contamination" {
    BeforeEach {
        $sandbox = New-TestSandbox
    }
    AfterEach { Remove-TestSandbox $sandbox }

    It "marking session A does not mark session B (two concurrent PS watchers)" {
        $wtA = New-FakeWtSession
        $wtB = New-FakeWtSession
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtA | Out-Null
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtB | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtA | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtB | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wtA -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wtA -Pattern 'MARKED') | Should Be $true

        Start-Sleep -Milliseconds 1000
        $bLines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wtB)
        (@($bLines | Where-Object { $_ -match 'MARKED' })).Count | Should Be 0
    }

    It "three concurrent watchers (2 PS + 1 CMD) each only log their own MARKED/CLEARED events" {
        $wtA = New-FakeWtSession
        $wtB = New-FakeWtSession
        $wtC = New-FakeWtSession
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtA | Out-Null
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtB | Out-Null
        $cmdParent = Start-IsolatedCmdWatcher -Sandbox $sandbox -WtSession $wtC
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtA | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtB | Out-Null
        $hbC = Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtC
        $hbC | Should Not Be $null
        $sandbox.TrackedPids.Add([int]$hbC.pid)

        Write-FakeState -Sandbox $sandbox -WtSession $wtC -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wtC -Pattern 'MARKED') | Should Be $true

        Write-FakeState -Sandbox $sandbox -WtSession $wtA -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wtA -Pattern 'MARKED') | Should Be $true

        Write-FakeState -Sandbox $sandbox -WtSession $wtC -Status 'clear'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wtC -Pattern 'CLEARED') | Should Be $true

        Start-Sleep -Milliseconds 800

        # A: exactly one MARKED, zero CLEARED (never cleared).
        $aLines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wtA)
        (@($aLines | Where-Object { $_ -match 'MARKED' })).Count | Should Be 1
        (@($aLines | Where-Object { $_ -match 'CLEARED' })).Count | Should Be 0

        # B: never touched at all -- no MARKED/CLEARED lines whatsoever.
        $bLines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wtB)
        (@($bLines | Where-Object { $_ -match 'MARKED|CLEARED' })).Count | Should Be 0

        # C: exactly one MARKED, then one CLEARED.
        $cLines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wtC)
        (@($cLines | Where-Object { $_ -match 'MARKED' })).Count | Should Be 1
        (@($cLines | Where-Object { $_ -match 'CLEARED' })).Count | Should Be 1
    }

    It "each concurrent session's heartbeat reports its own distinct pid" {
        $wtA = New-FakeWtSession
        $wtB = New-FakeWtSession
        $procA = Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtA
        $procB = Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtB
        $hbA = Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtA
        $hbB = Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtB

        $hbA.pid | Should Be $procA.Id
        $hbB.pid | Should Be $procB.Id
        ($hbA.pid -eq $hbB.pid) | Should Be $false
    }

    It "a new watcher's startup sweep does not disturb two other LIVE sessions" {
        $wtA = New-FakeWtSession
        $wtB = New-FakeWtSession
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtA | Out-Null
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtB | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtA | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtB | Out-Null

        # A third watcher starting up runs its own sweep over A's and B's
        # heartbeats -- both are live and identity-verified, so neither
        # should be removed or disturbed.
        $wtC = New-FakeWtSession
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtC | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtC | Out-Null
        Start-Sleep -Milliseconds 800

        Test-Path (Get-HeartbeatPath $sandbox $wtA) | Should Be $true
        Test-Path (Get-HeartbeatPath $sandbox $wtB) | Should Be $true

        # A and B should still be fully functional after the sweep -- prove
        # it by marking A and confirming it still responds.
        Write-FakeState -Sandbox $sandbox -WtSession $wtA -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wtA -Pattern 'MARKED') | Should Be $true
    }

    It "clearing session A while session B is mid-MARKED leaves B still marked" {
        $wtA = New-FakeWtSession
        $wtB = New-FakeWtSession
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtA | Out-Null
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtB | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtA | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtB | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wtA -Status 'needsAttention'
        Write-FakeState -Sandbox $sandbox -WtSession $wtB -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wtA -Pattern 'MARKED') | Should Be $true
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wtB -Pattern 'MARKED') | Should Be $true

        Write-FakeState -Sandbox $sandbox -WtSession $wtA -Status 'clear'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wtA -Pattern 'CLEARED') | Should Be $true

        Start-Sleep -Milliseconds 800
        $bLines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wtB)
        (@($bLines | Where-Object { $_ -match 'CLEARED' })).Count | Should Be 0
        (Get-Content (Get-StatePath $sandbox $wtB) -Raw | ConvertFrom-Json).status | Should Be 'needsAttention'
    }
}
