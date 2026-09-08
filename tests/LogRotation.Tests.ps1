Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

# Tests Write-WatcherLog's rotation (1MB cap, rotate-before-append so no
# MARKED/CLEARED/error entry is ever lost mid-rotation). Both watcher scripts
# reset their own log file to empty at startup, so organic growth to 1MB via
# real 500ms-interval polling would take far too long to test practically.
# Instead: start a real watcher, then append filler directly to ITS OWN log
# file (simulating hours of prior accumulated events), then trigger one real
# MARKED/CLEARED event through the watcher and observe whether the real
# Write-WatcherLog function -- running inside the real watcher process --
# rotates correctly. This exercises the actual production rotation logic,
# not a reimplementation of it.

function Add-LogFiller {
    param($Sandbox, [string]$WtSession, [int]$Bytes)
    $path = Get-WatcherLogPath $Sandbox $WtSession
    $chunk = ('X' * 1000) + "`n"
    $chunksNeeded = [Math]::Ceiling($Bytes / $chunk.Length)
    $sw = New-Object System.IO.StreamWriter($path, $true, [System.Text.Encoding]::UTF8)
    try {
        for ($i = 0; $i -lt $chunksNeeded; $i++) { $sw.Write($chunk) }
    } finally {
        $sw.Dispose()
    }
}

Describe "Log rotation (PowerShell watcher)" {
    BeforeEach {
        $sandbox = New-TestSandbox
        $wt = New-FakeWtSession
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null
    }
    AfterEach { Remove-TestSandbox $sandbox }

    It "rotates to .old and starts a fresh log once the 1MB cap is crossed, without losing the new event" {
        $logPath = Get-WatcherLogPath $sandbox $wt
        $oldPath = "$logPath.old"
        Add-LogFiller -Sandbox $sandbox -WtSession $wt -Bytes 1100000
        (Get-Item $logPath).Length | Should BeGreaterThan 1048576

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        # Wait for BOTH the .old file AND the new MARKED line, not just .old
        # alone -- Write-WatcherLog does Move-Item, then Set-Content (rotation
        # notice), then Add-Content (the actual message) as separate
        # sequential steps, so .old can appear microseconds before the fresh
        # log file's content is fully written.
        (Wait-ForCondition -TimeoutMs 30000 -Condition {
            (Test-Path $oldPath) -and ((Get-FileContentTolerant $logPath) -match 'MARKED')
        }) | Should Be $true

        (Get-Item $oldPath).Length | Should BeGreaterThan 1048576
        $newContent = Get-FileContentTolerant $logPath
        $newContent | Should Match 'LOG ROTATED'
        $newContent | Should Match 'MARKED'
        $newContent | Should Not Match 'XXXXXXXXXX'
        (Get-Item $logPath).Length | Should BeLessThan 1048576
    }

    It "does not rotate while under the 1MB cap -- prior content and the new event coexist" {
        $logPath = Get-WatcherLogPath $sandbox $wt
        $oldPath = "$logPath.old"
        Add-LogFiller -Sandbox $sandbox -WtSession $wt -Bytes 10000
        $sizeBefore = (Get-Item $logPath).Length

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        # A single point-in-time read right after Wait-ForLogLine can land on
        # a transient empty/partial view of a file another process is mid-
        # write on even with FileShare.ReadWrite -- wait for a stable read
        # containing both the pre-existing filler AND the new event instead
        # of trusting one immediate follow-up read.
        $ok = Wait-ForCondition -TimeoutMs 30000 -Condition {
            $c = Get-FileContentTolerant $logPath
            $null -ne $c -and $c -match 'XXXXXXXXXX' -and $c -match 'MARKED'
        }
        $ok | Should Be $true

        Test-Path $oldPath | Should Be $false
        (Get-Item $logPath).Length | Should BeGreaterThan $sizeBefore
    }
}

Describe "Log rotation (CMD watcher)" {
    BeforeEach {
        $sandbox = New-TestSandbox
        $wt = New-FakeWtSession
        $fakeParent = Start-IsolatedCmdWatcher -Sandbox $sandbox -WtSession $wt
        $hb = Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt
        if ($null -ne $hb) { $sandbox.TrackedPids.Add([int]$hb.pid) }
    }
    AfterEach { Remove-TestSandbox $sandbox }

    It "rotates to .old and starts a fresh log once the 1MB cap is crossed, without losing the new event" {
        $logPath = Get-WatcherLogPath $sandbox $wt
        $oldPath = "$logPath.old"
        Add-LogFiller -Sandbox $sandbox -WtSession $wt -Bytes 1100000
        (Get-Item $logPath).Length | Should BeGreaterThan 1048576

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        # Wait for BOTH the .old file AND the new MARKED line, not just .old
        # alone -- Write-WatcherLog does Move-Item, then Set-Content (rotation
        # notice), then Add-Content (the actual message) as separate
        # sequential steps, so .old can appear microseconds before the fresh
        # log file's content is fully written.
        (Wait-ForCondition -TimeoutMs 30000 -Condition {
            (Test-Path $oldPath) -and ((Get-FileContentTolerant $logPath) -match 'MARKED')
        }) | Should Be $true

        (Get-Item $oldPath).Length | Should BeGreaterThan 1048576
        $newContent = Get-FileContentTolerant $logPath
        $newContent | Should Match 'LOG ROTATED'
        $newContent | Should Match 'MARKED'
        $newContent | Should Not Match 'XXXXXXXXXX'
        (Get-Item $logPath).Length | Should BeLessThan 1048576
    }
}
