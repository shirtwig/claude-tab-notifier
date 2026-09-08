# Claude Tab Notifier -- full formal automated test suite.
#
# Runs every Pester test file in this directory and reports one PASS/FAIL
# summary line per file plus a grand total. Each file's own Describe/It
# output still streams to the console as it runs; this just adds the
# roll-up at the end. Intended to be run from a clean state (no leftover
# ClaudeTabNotifierTests / ClaudeTabNotifierInstallTests sandboxes, no
# stray watcher processes) -- every test file cleans up fully after
# itself, including on failure, so a normal run leaves nothing behind.

$testFiles = @(
    'HookExe.Tests.ps1',
    'WatcherCore.Tests.ps1',
    'OrphanCleanup.Tests.ps1',
    'ConcurrentSessions.Tests.ps1',
    'LogRotation.Tests.ps1',
    'InstallUninstall.Tests.ps1'
)

$results = @()
foreach ($file in $testFiles) {
    $path = Join-Path $PSScriptRoot $file
    Write-Host ""
    Write-Host "==================== $file ====================" -ForegroundColor Cyan
    $r = Invoke-Pester -Script $path -PassThru
    $results += [PSCustomObject]@{
        File   = $file
        Passed = $r.PassedCount
        Failed = $r.FailedCount
        Total  = $r.TotalCount
    }
}

Write-Host ""
Write-Host "==================== SUMMARY ====================" -ForegroundColor Cyan
$grandPassed = 0
$grandTotal = 0
$anyFailed = $false
foreach ($r in $results) {
    $status = if ($r.Failed -eq 0) { 'PASS' } else { 'FAIL'; $anyFailed = $true }
    $color = if ($r.Failed -eq 0) { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1,-32} {2}/{3}" -f $status, $r.File, $r.Passed, $r.Total) -ForegroundColor $color
    $grandPassed += $r.Passed
    $grandTotal += $r.Total
}
Write-Host ""
Write-Host "TOTAL: $grandPassed / $grandTotal passed" -ForegroundColor $(if ($anyFailed) { 'Red' } else { 'Green' })

if ($anyFailed) { exit 1 } else { exit 0 }
