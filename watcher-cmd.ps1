# Claude Tab Notifier -- CMD-compatible watcher.
# CMD has no equivalent of PowerShell's in-process runspace hosting, so this runs
# as a genuinely separate OS process (launched via `start /B` from a .cmd launcher,
# which keeps the CMD prompt free without redirecting/attaching after the fact).
# Proven separately: a normally-spawned child that inherits its parent's console
# (not an external process attaching later) can reliably retitle that same
# Windows Terminal tab. Everything else mirrors watcher-background.ps1's loop.

$ErrorActionPreference = 'Stop'

if (-not $env:WT_SESSION) {
    exit 0
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

Add-Type -Name Native -Namespace ClaudeTabNotifier -MemberDefinition @"
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool SetConsoleTitleW(string lpConsoleTitle);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern uint GetConsoleTitleW(System.Text.StringBuilder lpConsoleTitle, uint nSize);
"@

$sb = New-Object System.Text.StringBuilder 1024
[ClaudeTabNotifier.Native]::GetConsoleTitleW($sb, 1024) | Out-Null
$originalTitle = $sb.ToString()

$heartbeatFile = Join-Path $stateDir "_heartbeat_$($env:WT_SESSION).txt"
$logFile       = Join-Path $stateDir "_watcherlog_$($env:WT_SESSION).txt"
"" | Set-Content -Path $logFile -Encoding utf8

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

# Stale/orphan cleanup sweep -- identical logic to watcher-background.ps1's (see
# its comments for the full rationale). Duplicated rather than shared, consistent
# with how sound-resolution logic is already duplicated across these scripts.
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
        try { $entry = $raw | ConvertFrom-Json } catch { continue }

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
    }
}

Invoke-StaleStateSweep -StateDir $stateDir -OwnWtSession $env:WT_SESSION -CleanupLogPath $cleanupLogPath

$soundEnabled = $true
$selectedSound = 'classic'
$customSoundFile = ''
$selectedEmoji = 'sparkle'
$configPath = Join-Path $PSScriptRoot 'config.json'
if (Test-Path $configPath) {
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($null -ne $config.soundEnabled) { $soundEnabled = [bool]$config.soundEnabled }
        if ($config.selectedSound) { $selectedSound = $config.selectedSound }
        if ($config.customSoundFile) { $customSoundFile = $config.customSoundFile }
        if ($config.selectedEmoji) { $selectedEmoji = $config.selectedEmoji }
    } catch {
        Write-WatcherLog -LogPath $logFile -Message "[$(Get-Date -Format T)] failed to read config.json, using defaults ($($_.Exception.Message))"
    }
}

# Emoji catalog -- identical to watcher-background.ps1's (see its comments for
# the full rationale, including why 'heart' needs two codepoints); duplicated
# rather than shared, consistent with how sound-resolution logic is already
# duplicated across these scripts.
$emojiCatalog = [ordered]@{
    sparkle = @(0x2728)
    star    = @(0x2B50)
    bell    = @(0x1F514)
    bolt    = @(0x26A1)
    fire    = @(0x1F525)
    target  = @(0x1F3AF)
    check   = @(0x2705)
    reddot  = @(0x1F534)
    eyes    = @(0x1F440)
    chat    = @(0x1F4AC)
    heart   = @(0x2764, 0xFE0F)
    music   = @(0x1F3B5)
}
if (-not $emojiCatalog.Contains($selectedEmoji)) { $selectedEmoji = 'sparkle' }
$emojiChar = -join ($emojiCatalog[$selectedEmoji] | ForEach-Object { [System.Char]::ConvertFromUtf32($_) })
if ($selectedSound -eq 'custom') {
    if ($customSoundFile -and [System.IO.Path]::IsPathRooted($customSoundFile)) {
        $soundFile = $customSoundFile
    } else {
        $soundFile = Join-Path $PSScriptRoot $customSoundFile
    }
} else {
    $soundFile = Join-Path $PSScriptRoot "sounds\$selectedSound.wav"
}

Write-WatcherLog -LogPath $logFile -Message "[$(Get-Date -Format T)] CMD watcher started. WT_SESSION=$env:WT_SESSION originalTitle=$originalTitle soundEnabled=$soundEnabled soundFile=$soundFile"

$marked = $false
$lastStatus = $null
$iterationCount = 0
$selfCheckIntervalIterations = 20  # ~10s at the 500ms poll interval
# Pulse pattern -- identical to watcher-background.ps1's (see its comments for
# the full rationale: the closest approximation of a font-size grow/shrink
# pulse achievable entirely within a plain console title string).
$animPattern = @(1, 2, 3, 2)
$animFrame = 0

while ($true) {
    try {
        Start-Sleep -Milliseconds 500
        $iterationCount++

        # Animate every tick while marked -- see watcher-background.ps1 for
        # the full rationale (runs before the heartbeat write so a later
        # malformed state file can never suppress it; no per-tick log line to
        # avoid unbounded log growth; current title recorded in the
        # already-every-tick-overwritten heartbeat instead).
        if ($marked) {
            $currentTitle = ($emojiChar * $animPattern[$animFrame]) + " $originalTitle"
            [ClaudeTabNotifier.Native]::SetConsoleTitleW($currentTitle) | Out-Null
            $animFrame = ($animFrame + 1) % $animPattern.Count
        } else {
            $currentTitle = $originalTitle
        }

        $heartbeatEntry = @{ time = (Get-Date -Format o); pid = $myPid; parentPid = $myParentPid; shell = 'cmd'; title = $currentTitle }
        ($heartbeatEntry | ConvertTo-Json -Compress) | Set-Content -Path $heartbeatFile -Encoding utf8

        if ($iterationCount % $selfCheckIntervalIterations -eq 0) {
            $parentStillAlive = $null -ne (Get-CimInstance Win32_Process -Filter "ProcessId=$myParentPid" -ErrorAction SilentlyContinue)
            if (-not $parentStillAlive) {
                Write-WatcherLog -LogPath $logFile -Message "[$(Get-Date -Format T)] SELF-ORPHAN DETECTED: parentPid=$myParentPid no longer exists. Cleaning up and exiting."
                Write-WatcherLog -LogPath $cleanupLogPath -Message "[$(Get-Date -Format o)] SELF-TERMINATED: WT_SESSION=$env:WT_SESSION pid=$myPid parentPid=$myParentPid"
                Remove-Item $stateFile, $heartbeatFile, $logFile -Force -ErrorAction SilentlyContinue
                exit 0
            }
        }

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
            $marked = $true
            $animFrame = 0
            # Set frame 0 immediately (matching the previous immediate-set
            # behavior) rather than waiting for the next tick's animate step
            # above -- then prime $animFrame so the next tick continues the
            # cycle smoothly instead of repeating frame 0.
            $firstFrameTitle = ($emojiChar * $animPattern[0]) + " $originalTitle"
            [ClaudeTabNotifier.Native]::SetConsoleTitleW($firstFrameTitle) | Out-Null
            $animFrame = 1 % $animPattern.Count
            Write-WatcherLog -LogPath $logFile -Message "[$(Get-Date -Format T)] MARKED -> $firstFrameTitle"

            if ($soundEnabled) {
                try {
                    if (Test-Path $soundFile) {
                        $bytes = [System.IO.File]::ReadAllBytes($soundFile)
                        $looksLikeWav = $bytes.Length -ge 12 -and
                            [System.Text.Encoding]::ASCII.GetString($bytes[0..3]) -eq 'RIFF' -and
                            [System.Text.Encoding]::ASCII.GetString($bytes[8..11]) -eq 'WAVE'
                        if ($looksLikeWav) {
                            $player = New-Object System.Media.SoundPlayer $soundFile
                            $player.Play()
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
