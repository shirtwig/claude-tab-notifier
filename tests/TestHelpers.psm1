# Shared helpers for the Claude Tab Notifier Pester suite.
#
# Isolation strategy: every test gets its own fake WT_SESSION and its own fake
# %LOCALAPPDATA% root (via ProcessStartInfo.EnvironmentVariables on the child
# process only -- never touching the real environment or the real state
# directory). Watcher scripts are copied verbatim into an isolated scripts
# folder so config.json/sounds\ can be freely rewritten per test without ever
# touching the real deployed copies. No production script is modified to
# achieve this -- they already just read $env:LOCALAPPDATA and $PSScriptRoot
# generically.

$script:ProjectRoot = Split-Path $PSScriptRoot -Parent

function New-TestSandbox {
    $id = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $root = Join-Path $env:TEMP "ClaudeTabNotifierTests\$id"
    $localAppData = Join-Path $root 'localappdata'
    $scriptsDir   = Join-Path $root 'scripts'
    $soundsDir    = Join-Path $scriptsDir 'sounds'
    $claudeHome   = Join-Path $root 'claudehome'

    New-Item -ItemType Directory -Path $localAppData, $scriptsDir, $soundsDir, $claudeHome -Force | Out-Null

    Copy-Item -Path (Join-Path $script:ProjectRoot 'watcher-background.ps1') -Destination $scriptsDir -Force
    Copy-Item -Path (Join-Path $script:ProjectRoot 'watcher-cmd.ps1') -Destination $scriptsDir -Force
    Copy-Item -Path (Join-Path $script:ProjectRoot 'taskbar-badge.ps1') -Destination $scriptsDir -Force
    Copy-Item -Path (Join-Path $script:ProjectRoot 'sounds\*.wav') -Destination $soundsDir -Force
    Copy-Item -Path (Join-Path $script:ProjectRoot 'config.json') -Destination $scriptsDir -Force

    [PSCustomObject]@{
        Id           = $id
        Root         = $root
        LocalAppData = $localAppData
        ScriptsDir   = $scriptsDir
        SoundsDir    = $soundsDir
        ClaudeHome   = $claudeHome
        StateDir     = Join-Path $localAppData 'ClaudeTabNotifier\state'
        PsWatcher    = Join-Path $scriptsDir 'watcher-background.ps1'
        CmdWatcher   = Join-Path $scriptsDir 'watcher-cmd.ps1'
        ConfigPath   = Join-Path $scriptsDir 'config.json'
        TrackedPids  = (New-Object System.Collections.Generic.List[int])
    }
}

function Remove-TestSandbox {
    param($Sandbox)
    foreach ($procId in @($Sandbox.TrackedPids)) {
        try { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue } catch {}
    }
    Start-Sleep -Milliseconds 300
    try { Remove-Item -Path $Sandbox.Root -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

function New-FakeWtSession {
    [Guid]::NewGuid().ToString()
}

function Wait-ForCondition {
    param([scriptblock]$Condition, [int]$TimeoutMs = 5000, [int]$PollMs = 100)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalMilliseconds -lt $TimeoutMs) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds $PollMs
    }
    return $false
}

function Start-IsolatedProcess {
    param([string]$FileName, [string]$Arguments, [hashtable]$EnvOverrides)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    foreach ($key in $EnvOverrides.Keys) {
        $psi.EnvironmentVariables[$key] = $EnvOverrides[$key]
    }
    [System.Diagnostics.Process]::Start($psi)
}

function Start-IsolatedPsWatcher {
    param($Sandbox, [string]$WtSession, [hashtable]$ExtraEnv = @{})
    $envOverrides = @{ WT_SESSION = $WtSession; LOCALAPPDATA = $Sandbox.LocalAppData }
    foreach ($key in $ExtraEnv.Keys) { $envOverrides[$key] = $ExtraEnv[$key] }
    $proc = Start-IsolatedProcess -FileName 'powershell.exe' `
        -Arguments "-NoProfile -NoExit -Command `"& '$($Sandbox.PsWatcher)'`"" `
        -EnvOverrides $envOverrides
    $Sandbox.TrackedPids.Add($proc.Id)
    return $proc
}

function Start-IsolatedCmdWatcher {
    param($Sandbox, [string]$WtSession, [hashtable]$ExtraEnv = @{})

    # A tiny disposable launcher file, mirroring the real watcher-cmd.cmd pattern
    # (start /B, then stay alive) -- avoids nested-quoting issues with inline
    # cmd /c commands.
    # Keep-alive uses a ping loop, not "timeout /t", because timeout.exe checks
    # that stdin is a real console handle and exits immediately otherwise --
    # which is exactly the case for a process tree spawned non-interactively
    # by this test harness. ping's delay doesn't depend on console/stdin type,
    # so the fake parent reliably stays alive until the test explicitly kills it.
    $launcherPath = Join-Path $Sandbox.Root "launch_$([Guid]::NewGuid().ToString('N').Substring(0,6)).cmd"
    @"
@echo off
start /B powershell -NoProfile -ExecutionPolicy Bypass -File "$($Sandbox.CmdWatcher)"
:loop
ping -n 2 127.0.0.1 >nul
goto loop
"@ | Set-Content -Path $launcherPath -Encoding ASCII

    $envOverrides = @{ WT_SESSION = $WtSession; LOCALAPPDATA = $Sandbox.LocalAppData }
    foreach ($key in $ExtraEnv.Keys) { $envOverrides[$key] = $ExtraEnv[$key] }
    $fakeParent = Start-IsolatedProcess -FileName 'cmd.exe' `
        -Arguments "/c `"$launcherPath`"" `
        -EnvOverrides $envOverrides
    $Sandbox.TrackedPids.Add($fakeParent.Id)
    return $fakeParent
}

function Get-HeartbeatPath {
    param($Sandbox, [string]$WtSession)
    Join-Path $Sandbox.StateDir "_heartbeat_$WtSession.txt"
}

function Get-StatePath {
    param($Sandbox, [string]$WtSession)
    Join-Path $Sandbox.StateDir "$WtSession.json"
}

function Get-WatcherLogPath {
    param($Sandbox, [string]$WtSession)
    Join-Path $Sandbox.StateDir "_watcherlog_$WtSession.txt"
}

function Get-CleanupLogPath {
    param($Sandbox)
    Join-Path $Sandbox.StateDir '_cleanup.log'
}

function Get-FileContentTolerant {
    # Get-Content can throw a sharing-violation IOException if it happens to
    # poll at the exact instant another process has the file open for append
    # (observed intermittently under system load). Opening explicitly with
    # FileShare.ReadWrite -- rather than relying on Get-Content's default
    # sharing mode -- lets a read always succeed alongside a writer that is
    # itself using shared-read/write access, which Add-Content/Set-Content are.
    param([string]$Path)
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object System.IO.StreamReader($stream)
            return $reader.ReadToEnd()
        } finally {
            $stream.Dispose()
        }
    } catch {
        return $null
    }
}

function Get-HeartbeatEntry {
    param($Sandbox, [string]$WtSession)
    $path = Get-HeartbeatPath $Sandbox $WtSession
    if (-not (Test-Path $path)) { return $null }
    $raw = Get-FileContentTolerant $path
    if (-not $raw) { return $null }
    try { $raw | ConvertFrom-Json } catch { $null }
}

function Wait-ForHeartbeat {
    param($Sandbox, [string]$WtSession, [int]$TimeoutMs = 8000)
    $ok = Wait-ForCondition -TimeoutMs $TimeoutMs -Condition { $null -ne (Get-HeartbeatEntry -Sandbox $Sandbox -WtSession $WtSession) }
    if (-not $ok) { return $null }
    Get-HeartbeatEntry -Sandbox $Sandbox -WtSession $WtSession
}

function Write-FakeState {
    param($Sandbox, [string]$WtSession, [string]$Status)
    $path = Get-StatePath $Sandbox $WtSession
    (@{ status = $Status } | ConvertTo-Json -Compress) | Set-Content -Path $path -Encoding utf8
}

function Get-LogLinesTolerant {
    param([string]$Path)
    $raw = Get-FileContentTolerant $Path
    if ($null -eq $raw) { return @() }
    ,($raw -split "`r?`n")
}

function Wait-ForLogLine {
    # 30s default (raised from 20s, 12s, then 6s): under this
    # machine's real background system load (observed throughout this test
    # session: Docker Desktop, multiple VS Code integrated-terminal shells,
    # npm/tsx dev servers running concurrently), rapid-fire SoundPlayer.Play()
    # calls and large file operations across dozens of consecutive tests can
    # intermittently push a single 500ms-poll-interval watcher cycle well
    # past a lower margin -- observed empirically across multiple different,
    # otherwise-identical sound-selection tests in separate full-suite runs,
    # each one proven correct (not a logic defect) once given more headroom.
    param($Sandbox, [string]$WtSession, [string]$Pattern, [int]$TimeoutMs = 30000)
    Wait-ForCondition -TimeoutMs $TimeoutMs -Condition {
        $p = Get-WatcherLogPath $Sandbox $WtSession
        $content = Get-FileContentTolerant $p
        $null -ne $content -and $content -match $Pattern
    }
}

function Wait-ForCleanupLogLine {
    param($Sandbox, [string]$Pattern, [int]$TimeoutMs = 6000)
    Wait-ForCondition -TimeoutMs $TimeoutMs -Condition {
        $p = Get-CleanupLogPath $Sandbox
        $content = Get-FileContentTolerant $p
        $null -ne $content -and $content -match $Pattern
    }
}

function Stop-TrackedProcess {
    param([int]$ProcessId)
    try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch {}
}

function Test-ProcessAlive {
    param([int]$ProcessId)
    $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

Export-ModuleMember -Function *
