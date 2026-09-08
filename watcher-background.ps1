$ErrorActionPreference = 'Stop'

if (-not $env:WT_SESSION) {
    Write-Host "No WT_SESSION -- not running inside Windows Terminal." -ForegroundColor Red
    return
}

$stateDir  = Join-Path $env:LOCALAPPDATA 'ClaudeTabNotifier\state'
$stateFile = Join-Path $stateDir "$($env:WT_SESSION).json"
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
try {
    # Purely informational/debug file, shared across ALL sessions in this
    # state dir (unlike every other path here, which is per-session) -- when
    # two watchers start within the same instant, concurrent writes to this
    # one shared path can race and throw (observed: "Stream was not
    # readable"). With $ErrorActionPreference='Stop' that would silently
    # kill this session's entire watcher, so it must never be fatal.
    Set-Content -Path (Join-Path $stateDir '_latest_session.txt') -Value $env:WT_SESSION -Encoding utf8
} catch {}

$originalTitle = $Host.UI.RawUI.WindowTitle
$heartbeatFile = Join-Path $stateDir "_heartbeat_$($env:WT_SESSION).txt"
$logFile       = Join-Path $stateDir "_watcherlog_$($env:WT_SESSION).txt"
"" | Set-Content -Path $logFile -Encoding utf8

# Sound config is read once at startup (same pattern as $originalTitle) -- loaded
# here, in the un-sandboxed startup scope, so a bad config.json can't take down
# the polling loop itself; defaults are used if it's missing or invalid.
$soundEnabled = $true
$selectedSound = 'classic'
$customSoundFile = ''
$configPath = Join-Path $PSScriptRoot 'config.json'
if (Test-Path $configPath) {
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($null -ne $config.soundEnabled) { $soundEnabled = [bool]$config.soundEnabled }
        if ($config.selectedSound) { $selectedSound = $config.selectedSound }
        if ($config.customSoundFile) { $customSoundFile = $config.customSoundFile }
    } catch {
        Write-Host "Claude Tab Notifier: failed to read config.json, using defaults ($($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}

# Resolve the selection down to a single concrete path -- everything downstream
# (the polling loop, the play call, dedup) only ever sees this final $soundFile,
# exactly as before; the built-in-vs-custom logic is fully contained here.
if ($selectedSound -eq 'custom') {
    if ($customSoundFile -and [System.IO.Path]::IsPathRooted($customSoundFile)) {
        $soundFile = $customSoundFile
    } else {
        $soundFile = Join-Path $PSScriptRoot $customSoundFile
    }
} else {
    $soundFile = Join-Path $PSScriptRoot "sounds\$selectedSound.wav"
}

# Stale/orphan cleanup sweep -- runs once at startup, before this session's own
# heartbeat file even exists, so there is no risk of touching itself. Only ever
# deletes another session's files after proving via Get-Process/CIM that the
# owning process is actually gone (never by file age), and never terminates a
# PID unless its own command line still matches a real watcher process first --
# PIDs get reused by Windows, so "a process with this PID exists" alone is not
# enough to trust it's the same one that wrote the heartbeat.
$myPid = $PID
$myParentPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$myPid" -ErrorAction SilentlyContinue).ParentProcessId
$cleanupLogPath = Join-Path $stateDir '_cleanup.log'

# Rotation-safe log writer: rotation always happens as a discrete step BEFORE
# the new message is appended, so no MARKED/CLEARED/error entry is ever lost or
# split mid-write. Keeps at most one prior generation (<file>.old) -- simple
# defense-in-depth against unbounded growth, not full multi-generation rotation.
function Write-WatcherLog {
    param([string]$LogPath, [string]$Message, [int]$MaxBytes = 1048576)
    try {
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -ge $MaxBytes) {
            $oldPath = "$LogPath.old"
            Move-Item -Path $LogPath -Destination $oldPath -Force -ErrorAction SilentlyContinue
            Set-Content -Path $LogPath -Value "[$(Get-Date -Format T)] LOG ROTATED (previous entries in $(Split-Path $oldPath -Leaf))" -Encoding utf8
        }
        Add-Content -Path $LogPath -Value $Message -Encoding utf8
    } catch {
        # Logging must never break the actual watcher loop.
    }
}

function Invoke-StaleStateSweep {
    param([string]$StateDir, [string]$OwnWtSession, [string]$CleanupLogPath)

    try {
        $heartbeats = Get-ChildItem -Path $StateDir -Filter '_heartbeat_*.txt' -ErrorAction SilentlyContinue
    } catch {
        return
    }

    foreach ($hbFile in $heartbeats) {
        $wtSession = $hbFile.Name -replace '^_heartbeat_', '' -replace '\.txt$', ''
        if (-not $wtSession -or $wtSession -eq $OwnWtSession) { continue }

        $raw = $null
        try { $raw = Get-Content $hbFile.FullName -Raw -ErrorAction Stop } catch { continue }
        $entry = $null
        try { $entry = $raw | ConvertFrom-Json } catch { continue }  # legacy plain-timestamp format -- skip, not a target of this feature

        if ($null -eq $entry.pid -or $null -eq $entry.shell) { continue }

        $filesToRemove = @(
            (Join-Path $StateDir "$wtSession.json"),
            $hbFile.FullName,
            (Join-Path $StateDir "_watcherlog_$wtSession.txt")
        )

        $ownerProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($entry.pid)" -ErrorAction SilentlyContinue
        if (-not $ownerProcess) {
            foreach ($f in $filesToRemove) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
            Write-WatcherLog -LogPath $CleanupLogPath -Message "[$(Get-Date -Format o)] REMOVED (process gone): WT_SESSION=$wtSession pid=$($entry.pid) shell=$($entry.shell)"
            continue
        }

        # Identity check differs by shell type: a CMD watcher is its own dedicated
        # process (launched via "-File ...watcher-cmd.ps1"), so its command line
        # meaningfully proves identity. A PowerShell watcher is a thread INSIDE the
        # interactive shell process -- that process's command line is whatever
        # opened the tab (e.g. "powershell -NoExit") and never mentions the script,
        # by architecture. For that case the best available check is process name.
        $looksLikeWatcher = if ($entry.shell -eq 'cmd') {
            $ownerProcess.CommandLine -match 'watcher-cmd\.ps1'
        } else {
            $ownerProcess.Name -eq 'powershell.exe'
        }
        if (-not $looksLikeWatcher) {
            Write-WatcherLog -LogPath $CleanupLogPath -Message "[$(Get-Date -Format o)] SKIPPED (pid $($entry.pid) no longer a watcher process, likely reused -- ambiguous, not touching): WT_SESSION=$wtSession commandline=$($ownerProcess.CommandLine)"
            continue
        }

        if ($entry.shell -eq 'cmd') {
            $parentProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($entry.parentPid)" -ErrorAction SilentlyContinue
            if (-not $parentProcess) {
                Stop-Process -Id $entry.pid -Force -ErrorAction SilentlyContinue
                foreach ($f in $filesToRemove) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
                Write-WatcherLog -LogPath $CleanupLogPath -Message "[$(Get-Date -Format o)] TERMINATED ORPHAN: WT_SESSION=$wtSession pid=$($entry.pid) (verified watcher-cmd.ps1) parentPid=$($entry.parentPid) (confirmed dead)"
            }
        }
        # else: shell=powershell and the process is alive+identity-verified -- for that
        # architecture the watcher thread dies with its whole process, so a live,
        # identity-matched pid can only mean it is still legitimately active. No log
        # line needed for the common "still active" case to keep _cleanup.log small.
    }
}

Invoke-StaleStateSweep -StateDir $stateDir -OwnWtSession $env:WT_SESSION -CleanupLogPath $cleanupLogPath

Write-Host "=== Claude Tab Notifier -- background watcher (runs on a separate thread in THIS process) ===" -ForegroundColor Cyan
Write-Host "WT_SESSION    : $env:WT_SESSION"
Write-Host "Original title: $originalTitle"
Write-Host "State file    : $stateFile"
Write-Host "Watcher log   : $logFile"
Write-Host "Sound enabled : $soundEnabled"
Write-Host "Sound file    : $soundFile"
Write-Host ""

$loopScript = {
    param($stateFile, $originalTitle, $heartbeatFile, $logFile, $soundEnabled, $soundFile, $myPid, $myParentPid)

    # $Host.UI.RawUI.WindowTitle throws in this background runspace (its default
    # PSHost doesn't implement RawUI -- confirmed via LOOP ERROR log evidence).
    # SetConsoleTitleW is a raw, process-scoped Win32 call with no dependency on
    # $Host, already proven correct for Unicode in the earlier encoding probe.
    Add-Type -Name Native -Namespace ClaudeTabNotifier -MemberDefinition @"
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool SetConsoleTitleW(string lpConsoleTitle);
"@

    # Same rotation-safe helper as the outer scope -- a separate runspace does not
    # inherit functions defined outside it, so this is intentionally duplicated.
    function Write-WatcherLog {
        param([string]$LogPath, [string]$Message, [int]$MaxBytes = 1048576)
        try {
            if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -ge $MaxBytes) {
                $oldPath = "$LogPath.old"
                Move-Item -Path $LogPath -Destination $oldPath -Force -ErrorAction SilentlyContinue
                Set-Content -Path $LogPath -Value "[$(Get-Date -Format T)] LOG ROTATED (previous entries in $(Split-Path $oldPath -Leaf))" -Encoding utf8
            }
            Add-Content -Path $LogPath -Value $Message -Encoding utf8
        } catch {
            # Logging must never break the actual watcher loop.
        }
    }

    $marked = $false
    $lastStatus = $null

    while ($true) {
        try {
            Start-Sleep -Milliseconds 500
            $heartbeatEntry = @{ time = (Get-Date -Format o); pid = $myPid; parentPid = $myParentPid; shell = 'powershell' }
            ($heartbeatEntry | ConvertTo-Json -Compress) | Set-Content -Path $heartbeatFile -Encoding utf8

            $exists = Test-Path $stateFile
            $status = 'clear'
            if ($exists) {
                try { $status = (Get-Content $stateFile -Raw | ConvertFrom-Json).status } catch { continue }
            }

            # No unconditional per-cycle log line here (deliberately) -- only the
            # actual mark/clear/sound/error events below are logged, matching the
            # measured-and-addressed unbounded-growth finding from resource testing.

            if ($status -eq $lastStatus) { continue }
            $lastStatus = $status

            if ($status -eq 'needsAttention' -and -not $marked) {
                $sparkle = [char]0x2728
                [ClaudeTabNotifier.Native]::SetConsoleTitleW("$sparkle $originalTitle") | Out-Null
                $marked = $true
                Write-WatcherLog -LogPath $logFile -Message "[$(Get-Date -Format T)] MARKED -> $sparkle $originalTitle"

                if ($soundEnabled) {
                    try {
                        if (Test-Path $soundFile) {
                            $bytes = [System.IO.File]::ReadAllBytes($soundFile)
                            $looksLikeWav = $bytes.Length -ge 12 -and
                                [System.Text.Encoding]::ASCII.GetString($bytes[0..3]) -eq 'RIFF' -and
                                [System.Text.Encoding]::ASCII.GetString($bytes[8..11]) -eq 'WAVE'
                            if ($looksLikeWav) {
                                $player = New-Object System.Media.SoundPlayer $soundFile
                                $player.Play()  # async -- must not block the polling loop
                                Write-WatcherLog -LogPath $logFile -Message "[$(Get-Date -Format T)] sound played: $soundFile"
                            } else {
                                Write-WatcherLog -LogPath $logFile -Message "[$(Get-Date -Format T)] sound SKIPPED: not a valid WAV file: $soundFile"
                            }
                        } else {
                            Write-WatcherLog -LogPath $logFile -Message "[$(Get-Date -Format T)] sound SKIPPED: file not found: $soundFile"
                        }
                    } catch {
                        Write-WatcherLog -LogPath $logFile -Message "[$(Get-Date -Format T)] sound FAILED: $($_.Exception.Message)"
                    }
                }
            }
            elseif ($status -eq 'clear' -and $marked) {
                [ClaudeTabNotifier.Native]::SetConsoleTitleW($originalTitle) | Out-Null
                $marked = $false
                Write-WatcherLog -LogPath $logFile -Message "[$(Get-Date -Format T)] CLEARED -> $originalTitle"
            }
        } catch {
            Write-WatcherLog -LogPath $logFile -Message "[$(Get-Date -Format T)] LOOP ERROR: $($_.Exception.Message)"
        }
    }
}

$runspace = [runspacefactory]::CreateRunspace()
$runspace.ApartmentState = 'STA'
$runspace.ThreadOptions = 'ReuseThread'
$runspace.Open()

$ps = [powershell]::Create()
$ps.Runspace = $runspace
[void]$ps.AddScript($loopScript).AddArgument($stateFile).AddArgument($originalTitle).AddArgument($heartbeatFile).AddArgument($logFile).AddArgument($soundEnabled).AddArgument($soundFile).AddArgument($myPid).AddArgument($myParentPid)

$null = $ps.BeginInvoke()

Write-Host "Background watcher thread started -- this prompt is free." -ForegroundColor Green
Write-Host "You can now run 'claude' normally in this same tab to start a second session." -ForegroundColor Green
Write-Host ""
