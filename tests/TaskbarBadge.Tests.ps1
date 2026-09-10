Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

# Tests the Windows Taskbar attention dot feature (taskbar-badge.ps1), wired
# into watcher-background.ps1 and watcher-cmd.ps1. Follows this suite's
# existing black-box, real-process philosophy -- there is no mock, and the
# real ITaskbarList3 COM path really runs against the real Windows Terminal
# window hosting whatever process ends up running these tests. Two env-var
# test-only seams (never touched by install.ps1, the real hooks, or any
# user-facing config) make the otherwise-unautomatable parts deterministic:
#
#   - CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE points at a small file
#     ('1'/'0', re-read every check) that substitutes for GetForegroundWindow()
#     -- a background test process cannot reliably force itself into the
#     real OS foreground (SetForegroundWindow returns FALSE when called this
#     way; confirmed while building this feature), so "the user switched
#     back" cannot be simulated for real. A file (not a fixed env value) is
#     used so a single already-running watcher process's simulated
#     foreground state can be flipped mid-test, the same polling-a-file
#     pattern $stateFile itself already uses.
#   - CLAUDE_TAB_NOTIFIER_TEST_HWND forces a specific (including a
#     deliberately invalid) resolved target, used here only to prove a
#     resolution failure never breaks the watcher's existing behavior.
#
# Environmental assumption: these tests assume exactly one Windows Terminal
# top-level window is open on the machine running them (true for a normal
# dev box). If more than one real WT window is open, Resolve-
# TaskbarWindowTarget correctly detects the ambiguity and disables itself by
# design (see taskbar-badge.ps1) -- a real, documented, environment-dependent
# limitation, not a code defect -- and the first test below fails with a
# clear message instead of the rest silently misbehaving.

$moduleUnderTest = Join-Path (Split-Path $PSScriptRoot -Parent) 'taskbar-badge.ps1'
. $moduleUnderTest
$script:realTarget = Resolve-TaskbarWindowTarget

function New-FgFile {
    param($Sandbox, [bool]$Initial = $false)
    $path = Join-Path $Sandbox.Root 'fg.flag'
    Set-Content -Path $path -Value $(if ($Initial) { '1' } else { '0' })
    return $path
}

function Set-FgFile {
    param([string]$Path, [bool]$Value)
    Set-Content -Path $Path -Value $(if ($Value) { '1' } else { '0' })
}

Describe "Taskbar attention dot" {
    BeforeEach {
        $sandbox = New-TestSandbox
        $wt = New-FakeWtSession
    }
    AfterEach {
        # Best-effort real cleanup -- a test that caused the real dot to be
        # shown must not leave it lit on the developer's actual taskbar.
        if ($script:realTarget.Available) {
            try { Clear-TaskbarAttentionDot -Hwnd $script:realTarget.Hwnd | Out-Null } catch {}
        }
        Remove-TestSandbox $sandbox
    }

    It "environment sanity: resolves exactly one real WT window (see file header if this fails)" {
        $script:realTarget.Available | Should Be $true
    }

    It "needsAttention sets the badge (TASKBAR SHOW logged)" {
        $fg = New-FgFile -Sandbox $sandbox -Initial $false
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt -ExtraEnv @{ CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE = $fg } | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'TASKBAR SHOW') | Should Be $true
    }

    It "repeated needsAttention does not produce duplicate TASKBAR SHOW lines" {
        $fg = New-FgFile -Sandbox $sandbox -Initial $false
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt -ExtraEnv @{ CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE = $fg } | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'TASKBAR SHOW') | Should Be $true

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        Start-Sleep -Milliseconds 1500

        $lines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wt)
        (@($lines | Where-Object { $_ -match 'TASKBAR SHOW' })).Count | Should Be 1
    }

    It "not foreground: badge remains after the session itself clears" {
        $fg = New-FgFile -Sandbox $sandbox -Initial $false
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt -ExtraEnv @{ CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE = $fg } | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'TASKBAR SHOW') | Should Be $true

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'clear'
        Start-Sleep -Milliseconds 1500

        $lines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wt)
        (@($lines | Where-Object { $_ -match 'TASKBAR CLEAR' })).Count | Should Be 0
    }

    It "foreground + no attention clears the badge (TASKBAR CLEAR logged)" {
        $fg = New-FgFile -Sandbox $sandbox -Initial $false
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt -ExtraEnv @{ CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE = $fg } | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'TASKBAR SHOW') | Should Be $true

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'clear'
        Set-FgFile -Path $fg -Value $true
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'TASKBAR CLEAR') | Should Be $true
    }

    It "clear is idempotent: no extra TASKBAR CLEAR lines once already cleared" {
        $fg = New-FgFile -Sandbox $sandbox -Initial $false
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt -ExtraEnv @{ CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE = $fg } | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'TASKBAR SHOW') | Should Be $true
        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'clear'
        Set-FgFile -Path $fg -Value $true
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'TASKBAR CLEAR') | Should Be $true

        # Stay foreground with nothing pending for several more ticks.
        Start-Sleep -Milliseconds 2000
        $lines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wt)
        (@($lines | Where-Object { $_ -match 'TASKBAR CLEAR' })).Count | Should Be 1
    }

    It "soundEnabled=false does not prevent TASKBAR SHOW" {
        Set-Content -Path $sandbox.ConfigPath -Encoding utf8 -Value (
            (@{ soundEnabled = $false; selectedSound = 'classic'; customSoundFile = ''; selectedEmoji = 'sparkle'; emojiEnabled = $true } | ConvertTo-Json -Compress)
        )
        $fg = New-FgFile -Sandbox $sandbox -Initial $false
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt -ExtraEnv @{ CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE = $fg } | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'TASKBAR SHOW') | Should Be $true
    }

    It "emojiEnabled=false does not prevent TASKBAR SHOW" {
        Set-Content -Path $sandbox.ConfigPath -Encoding utf8 -Value (
            (@{ soundEnabled = $true; selectedSound = 'classic'; customSoundFile = ''; selectedEmoji = 'sparkle'; emojiEnabled = $false } | ConvertTo-Json -Compress)
        )
        $fg = New-FgFile -Sandbox $sandbox -Initial $false
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt -ExtraEnv @{ CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE = $fg } | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'TASKBAR SHOW') | Should Be $true
    }

    It "both sound and emoji disabled: TASKBAR SHOW still fires" {
        Set-Content -Path $sandbox.ConfigPath -Encoding utf8 -Value (
            (@{ soundEnabled = $false; selectedSound = 'classic'; customSoundFile = ''; selectedEmoji = 'sparkle'; emojiEnabled = $false } | ConvertTo-Json -Compress)
        )
        $fg = New-FgFile -Sandbox $sandbox -Initial $false
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt -ExtraEnv @{ CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE = $fg } | Out-Null
        Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt | Out-Null

        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'TASKBAR SHOW') | Should Be $true
    }

    It "resolution failure (forced bad target) does not break the watcher's existing behavior" {
        $fg = New-FgFile -Sandbox $sandbox -Initial $false
        Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wt -ExtraEnv @{
            CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE = $fg
            CLAUDE_TAB_NOTIFIER_TEST_HWND             = 'not-a-number'
        } | Out-Null

        # The watcher must still start and do its real job (heartbeat, MARKED)
        # despite Resolve-TaskbarWindowTarget throwing during startup.
        (Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wt) | Should Not Be $null
        Write-FakeState -Sandbox $sandbox -WtSession $wt -Status 'needsAttention'
        (Wait-ForLogLine -Sandbox $sandbox -WtSession $wt -Pattern 'MARKED') | Should Be $true

        # And it must never have logged a TASKBAR SHOW (feature stayed off).
        $lines = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wt)
        (@($lines | Where-Object { $_ -match 'TASKBAR SHOW' })).Count | Should Be 0
    }

    Context "multiple sessions sharing one taskbar dot" {
        It "session B's own log shows TASKBAR SHOW because session A needs attention (aggregate crosses sessions)" {
            $wtA = New-FakeWtSession
            $wtB = $wt
            $fgA = New-FgFile -Sandbox $sandbox -Initial $false
            $fgB = Join-Path $sandbox.Root 'fgB.flag'
            Set-Content $fgB '0'

            Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtA -ExtraEnv @{ CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE = $fgA } | Out-Null
            Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtB -ExtraEnv @{ CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE = $fgB } | Out-Null
            Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtA | Out-Null
            Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtB | Out-Null

            Write-FakeState -Sandbox $sandbox -WtSession $wtA -Status 'needsAttention'
            # Session B never goes needsAttention itself, yet must still see
            # the aggregate and decide to show the shared badge.
            (Wait-ForLogLine -Sandbox $sandbox -WtSession $wtB -Pattern 'TASKBAR SHOW') | Should Be $true
        }

        It "two sessions needing attention simultaneously: both log TASKBAR SHOW" {
            $wtA = New-FakeWtSession
            $wtB = $wt
            $fgA = New-FgFile -Sandbox $sandbox -Initial $false
            $fgB = Join-Path $sandbox.Root 'fgB.flag'
            Set-Content $fgB '0'

            Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtA -ExtraEnv @{ CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE = $fgA } | Out-Null
            Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtB -ExtraEnv @{ CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE = $fgB } | Out-Null
            Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtA | Out-Null
            Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtB | Out-Null

            Write-FakeState -Sandbox $sandbox -WtSession $wtA -Status 'needsAttention'
            Write-FakeState -Sandbox $sandbox -WtSession $wtB -Status 'needsAttention'
            (Wait-ForLogLine -Sandbox $sandbox -WtSession $wtA -Pattern 'TASKBAR SHOW') | Should Be $true
            (Wait-ForLogLine -Sandbox $sandbox -WtSession $wtB -Pattern 'TASKBAR SHOW') | Should Be $true
        }

        It "one session clearing while the other still needs attention: badge remains (no CLEAR, even at foreground)" {
            $wtA = New-FakeWtSession
            $wtB = $wt
            $fgA = New-FgFile -Sandbox $sandbox -Initial $false
            $fgB = Join-Path $sandbox.Root 'fgB.flag'
            Set-Content $fgB '0'

            Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtA -ExtraEnv @{ CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE = $fgA } | Out-Null
            Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtB -ExtraEnv @{ CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE = $fgB } | Out-Null
            Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtA | Out-Null
            Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtB | Out-Null

            Write-FakeState -Sandbox $sandbox -WtSession $wtA -Status 'needsAttention'
            Write-FakeState -Sandbox $sandbox -WtSession $wtB -Status 'needsAttention'
            (Wait-ForLogLine -Sandbox $sandbox -WtSession $wtA -Pattern 'TASKBAR SHOW') | Should Be $true
            (Wait-ForLogLine -Sandbox $sandbox -WtSession $wtB -Pattern 'TASKBAR SHOW') | Should Be $true

            # B clears and becomes foreground; A is still pending (not foreground).
            Write-FakeState -Sandbox $sandbox -WtSession $wtB -Status 'clear'
            Set-FgFile -Path $fgB -Value $true
            Start-Sleep -Milliseconds 2000

            $linesB = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wtB)
            (@($linesB | Where-Object { $_ -match 'TASKBAR CLEAR' })).Count | Should Be 0
        }

        It "when the last remaining session clears at foreground: badge clears" {
            $wtA = New-FakeWtSession
            $wtB = $wt
            $fgA = New-FgFile -Sandbox $sandbox -Initial $false
            $fgB = Join-Path $sandbox.Root 'fgB.flag'
            Set-Content $fgB '0'

            Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtA -ExtraEnv @{ CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE = $fgA } | Out-Null
            Start-IsolatedPsWatcher -Sandbox $sandbox -WtSession $wtB -ExtraEnv @{ CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE = $fgB } | Out-Null
            Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtA | Out-Null
            Wait-ForHeartbeat -Sandbox $sandbox -WtSession $wtB | Out-Null

            Write-FakeState -Sandbox $sandbox -WtSession $wtA -Status 'needsAttention'
            Write-FakeState -Sandbox $sandbox -WtSession $wtB -Status 'needsAttention'
            (Wait-ForLogLine -Sandbox $sandbox -WtSession $wtA -Pattern 'TASKBAR SHOW') | Should Be $true
            (Wait-ForLogLine -Sandbox $sandbox -WtSession $wtB -Pattern 'TASKBAR SHOW') | Should Be $true

            # B clears first but A is still pending -- confirmed not cleared yet.
            Write-FakeState -Sandbox $sandbox -WtSession $wtB -Status 'clear'
            Set-FgFile -Path $fgB -Value $true
            Start-Sleep -Milliseconds 1500

            # Now A (the last one) clears too, with its own window foreground.
            Write-FakeState -Sandbox $sandbox -WtSession $wtA -Status 'clear'
            Set-FgFile -Path $fgA -Value $true

            $sawClear = Wait-ForCondition -TimeoutMs 10000 -Condition {
                $la = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wtA)
                $lb = Get-LogLinesTolerant (Get-WatcherLogPath $sandbox $wtB)
                (@($la | Where-Object { $_ -match 'TASKBAR CLEAR' })).Count -gt 0 -or
                (@($lb | Where-Object { $_ -match 'TASKBAR CLEAR' })).Count -gt 0
            }
            $sawClear | Should Be $true
        }
    }
}
