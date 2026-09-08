Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

# Tests Invoke-StaleStateSweep, the startup sweep duplicated in both watcher
# scripts, as a black box: it runs once when a NEW watcher starts, inspecting
# every OTHER session's heartbeat file in the same state dir. Covers: removal
# of a truly-dead session's files, safe identity verification against PID
# reuse (never trusting "a process with this PID exists" alone), and the
# cleanup log's content. All scenarios are driven by writing fake heartbeat
# files by hand (not by starting real watchers for the "victim" session) so
# the sweep's behavior can be tested precisely against controlled inputs.

function Write-FakeHeartbeat {
    # Named OwnerPid, not Pid -- $PID is a read-only PowerShell automatic
    # variable (the current process's own id), and a parameter named -Pid
    # collides with it case-insensitively, making it unassignable.
    param($Sandbox, [string]$WtSession, [int]$OwnerPid, [int]$ParentPid, [string]$Shell)
    $entry = @{ time = (Get-Date -Format o); pid = $OwnerPid; parentPid = $ParentPid; shell = $Shell }
    ($entry | ConvertTo-Json -Compress) | Set-Content -Path (Get-HeartbeatPath $Sandbox $WtSession) -Encoding utf8
}

function Start-DummyProcess {
    # A real, harmless long-lived process to stand in for "a real PID that
    # exists but is NOT a watcher" (identity-mismatch case) or "a real PID
    # that IS a watcher-shaped process" depending on the scenario.
    param($Sandbox)
    $proc = Start-IsolatedProcess -FileName 'powershell.exe' -Arguments '-NoProfile -NoExit -Command "Start-Sleep -Seconds 600"' -EnvOverrides @{}
    $Sandbox.TrackedPids.Add($proc.Id)
    return $proc
}

Describe "Stale-state sweep: cross-session dead-process cleanup" {
    BeforeEach {
        $sandbox = New-TestSandbox
        New-Item -ItemType Directory -Path $sandbox.StateDir -Force | Out-Null
    }
    AfterEach { Remove-TestSandbox $sandbox }

    It "removes a dead PowerShell session's state/heartbeat/log files and logs REMOVED" {
        $victim = New-FakeWtSession
        Write-FakeState -Sandbox $sandbox -WtSession $victim -Status 'needsAttention'
        Write-FakeHeartbeat -Sandbox $sandbox -WtSession $victim -OwnerPid 999999 -ParentPid 1 -Shell 'powershell'
        "some log content" | Set-Content -Path (Get-WatcherLogPath $sandbox $victim) -Encoding utf8

        # A live watcher for a DIFFERENT session triggers the sweep on startup.
        $wt = New-FakeWtSession
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        (Wait-ForCleanupLogLine -Sandbox $sandbox -Pattern "REMOVED.*$victim") | Should Be $true
        Test-Path (Get-StatePath $sandbox $victim) | Should Be $false
        Test-Path (Get-HeartbeatPath $sandbox $victim) | Should Be $false
        Test-Path (Get-WatcherLogPath $sandbox $victim) | Should Be $false
    }

    It "removes a dead CMD session's files and logs REMOVED" {
        $victim = New-FakeWtSession
        Write-FakeState -Sandbox $sandbox -WtSession $victim -Status 'clear'
        Write-FakeHeartbeat -Sandbox $sandbox -WtSession $victim -OwnerPid 999998 -ParentPid 999997 -Shell 'cmd'

        $wt = New-FakeWtSession
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        (Wait-ForCleanupLogLine -Sandbox $sandbox -Pattern "REMOVED.*$victim") | Should Be $true
        Test-Path (Get-StatePath $sandbox $victim) | Should Be $false
    }

    It "does not touch its OWN heartbeat/state on startup (no self-sweep)" {
        $wt = New-FakeWtSession
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        $hb = Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt
        $hb | Should Not Be $null
        Start-Sleep -Milliseconds 500
        Test-Path (Get-HeartbeatPath $sandbox $wt) | Should Be $true
    }

    It "leaves a live, identity-matched PowerShell session's files untouched" {
        $liveVictim = Start-DummyProcess -Sandbox $sandbox
        $victimSession = New-FakeWtSession
        Write-FakeState -Sandbox $sandbox -WtSession $victimSession -Status 'needsAttention'
        Write-FakeHeartbeat -Sandbox $sandbox -WtSession $victimSession -OwnerPid $liveVictim.Id -ParentPid 1 -Shell 'powershell'

        $wt = New-FakeWtSession
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null
        Start-Sleep -Milliseconds 1000

        Test-Path (Get-StatePath $sandbox $victimSession) | Should Be $true
        Test-Path (Get-HeartbeatPath $sandbox $victimSession) | Should Be $true
    }

    It "identity check: a live but non-watcher process claiming shell=cmd is SKIPPED, not terminated" {
        # PID-reuse safety: the heartbeat's own pid now happens to belong to a
        # real, live, ordinary process (Start-DummyProcess's own -NoExit shell,
        # never launched via watcher-cmd.ps1) -- must never be trusted/killed
        # just because a live process with that PID exists.
        $reusedPidProc = Start-DummyProcess -Sandbox $sandbox
        $victimSession = New-FakeWtSession
        Write-FakeHeartbeat -Sandbox $sandbox -WtSession $victimSession -OwnerPid $reusedPidProc.Id -ParentPid 1 -Shell 'cmd'

        $wt = New-FakeWtSession
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        (Wait-ForCleanupLogLine -Sandbox $sandbox -Pattern "SKIPPED.*$victimSession") | Should Be $true
        (Test-ProcessAlive -ProcessId $reusedPidProc.Id) | Should Be $true
        Test-Path (Get-HeartbeatPath $sandbox $victimSession) | Should Be $true
    }

    It "identity check: a live CMD watcher whose parent is confirmed dead is terminated as an orphan" {
        $victimSession = New-FakeWtSession
        $started = Start-IsolatedCmdWatcher -Sandbox $sandbox -WtSession $victimSession
        $victimHb = Wait-ForHeartbeat -Sandbox $sandbox -WtSession $victimSession
        $victimHb | Should Not Be $null
        $victimPid = [int]$victimHb.pid
        $sandbox.TrackedPids.Add($victimPid)

        # Kill only the fake parent (not the watcher itself) so the watcher's
        # OWN 10s self-check hasn't necessarily fired yet -- the NEXT watcher's
        # startup sweep should independently detect and terminate it first.
        Stop-Process -Id $started.Id -Force

        $wt = New-FakeWtSession
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        $ok = Wait-ForCleanupLogLine -Sandbox $sandbox -Pattern "TERMINATED ORPHAN.*$victimSession" -TimeoutMs 10000
        $ok | Should Be $true
        (Wait-ForCondition -TimeoutMs 5000 -Condition { -not (Test-ProcessAlive -ProcessId $victimPid) }) | Should Be $true
    }

    It "ignores a heartbeat file in the legacy plain-timestamp format without crashing" {
        $victim = New-FakeWtSession
        "2026-01-01T00:00:00" | Set-Content -Path (Get-HeartbeatPath $sandbox $victim) -Encoding utf8

        $wt = New-FakeWtSession
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        $hb = Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt
        $hb | Should Not Be $null
        Test-Path (Get-HeartbeatPath $sandbox $victim) | Should Be $true
    }
}

