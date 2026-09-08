Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

# Tests the real, deployed ClaudeAttention.exe as a black box -- no modification,
# no rebuild. Isolation: LOCALAPPDATA is overridden for the child process, so
# the state file lands inside the sandbox instead of the real state directory.
#
# The hook's own log file is NOT isolated the same way: empirically,
# Environment.SpecialFolder.UserProfile resolves to the real absolute user
# profile path regardless of a USERPROFILE env var override on the child
# process (unlike LocalApplicationData, which falls back to a relative path
# that WorkingDirectory can redirect). So log-content assertions read the
# REAL ~/.claude/tools/claudeattention.log. This is accepted as a documented
# trade-off: the log is append-only and this is exactly how the hook behaves
# in production, so it's non-destructive -- just not a pristine empty file.
# Each test uses a fresh random WT_SESSION, and log assertions scope to the
# lines around that session's own marker so they can't be confused by
# unrelated real usage elsewhere in the same growing log file.

$exePath = Join-Path $env:USERPROFILE '.claude\tools\ClaudeAttention.exe'

function Invoke-Hook {
    param($Sandbox, [string]$Command, [string]$Stdin = '{}', [switch]$NoWtSession, [string]$DisableTitleEnv = '1')

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exePath
    $psi.Arguments = $Command
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    # Environment.SpecialFolder.LocalApplicationData does not reliably honor an
    # overridden LOCALAPPDATA env var for this self-contained single-file exe
    # (confirmed empirically -- it fell back to a relative "ClaudeTabNotifier\
    # state\..." path). Anchoring WorkingDirectory to the sandbox means even
    # that relative fallback lands safely inside it rather than wherever this
    # test process happens to be running from.
    $psi.WorkingDirectory = $Sandbox.LocalAppData
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $Sandbox.LocalAppData
    $psi.EnvironmentVariables['USERPROFILE'] = $Sandbox.ClaudeHome
    # This test-runner's own process almost certainly has a real WT_SESSION
    # (it's running inside an actual Windows Terminal tab) -- ProcessStartInfo
    # copies the current environment by default, so skipping the override
    # would leak that real value through. Must explicitly Remove() it.
    if ($NoWtSession) {
        $psi.EnvironmentVariables.Remove('WT_SESSION')
    } else {
        $psi.EnvironmentVariables['WT_SESSION'] = $Sandbox.CurrentWtSession
    }
    if ($DisableTitleEnv) {
        $psi.EnvironmentVariables['CLAUDE_CODE_DISABLE_TERMINAL_TITLE'] = $DisableTitleEnv
    } else {
        $psi.EnvironmentVariables.Remove('CLAUDE_CODE_DISABLE_TERMINAL_TITLE')
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($Stdin)
    $proc.StandardInput.Close()
    $proc.WaitForExit(5000) | Out-Null
    [PSCustomObject]@{ ExitCode = $proc.ExitCode }
}

function Get-HookLogPath {
    # Real log location -- see isolation note at top of file. Uses the
    # test-runner's own real USERPROFILE, same as $exePath above.
    Join-Path $env:USERPROFILE '.claude\tools\claudeattention.log'
}

function Get-HookLogLinesNearSession {
    param($Sandbox, [int]$ContextLines = 5)
    $path = Get-HookLogPath
    if (-not (Test-Path $path)) { return @() }
    $lines = Get-LogLinesTolerant $path
    $idx = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match [regex]::Escape($Sandbox.CurrentWtSession)) { $idx = $i; break }
    }
    if ($idx -lt 0) { return @() }
    $start = [Math]::Max(0, $idx - $ContextLines)
    $end = [Math]::Min($lines.Count - 1, $idx + $ContextLines)
    $lines[$start..$end]
}

Describe "Hook exe: payload parsing and state writing" {
    BeforeEach {
        $sandbox = New-TestSandbox
        $sandbox | Add-Member -NotePropertyName CurrentWtSession -NotePropertyValue (New-FakeWtSession)
    }
    AfterEach { Remove-TestSandbox $sandbox }

    It "'done' command with WT_SESSION writes needsAttention" {
        $r = Invoke-Hook -Sandbox $sandbox -Command 'done' -Stdin '{"hook_event_name":"Stop"}'
        $r.ExitCode | Should Be 0
        $statePath = Get-StatePath $sandbox $sandbox.CurrentWtSession
        Test-Path $statePath | Should Be $true
        (Get-Content $statePath -Raw | ConvertFrom-Json).status | Should Be 'needsAttention'
    }

    It "'alert' command with WT_SESSION writes needsAttention" {
        $r = Invoke-Hook -Sandbox $sandbox -Command 'alert' -Stdin '{"hook_event_name":"Notification"}'
        $r.ExitCode | Should Be 0
        (Get-Content (Get-StatePath $sandbox $sandbox.CurrentWtSession) -Raw | ConvertFrom-Json).status | Should Be 'needsAttention'
    }

    It "'clear' command with WT_SESSION writes clear" {
        $r = Invoke-Hook -Sandbox $sandbox -Command 'clear' -Stdin '{"hook_event_name":"UserPromptSubmit"}'
        $r.ExitCode | Should Be 0
        (Get-Content (Get-StatePath $sandbox $sandbox.CurrentWtSession) -Raw | ConvertFrom-Json).status | Should Be 'clear'
    }

    It "unknown command exits with error and writes no state" {
        $r = Invoke-Hook -Sandbox $sandbox -Command 'bogus'
        $r.ExitCode | Should Be 1
        Test-Path (Get-StatePath $sandbox $sandbox.CurrentWtSession) | Should Be $false
    }

    It "missing WT_SESSION: no state file written, no crash" {
        $r = Invoke-Hook -Sandbox $sandbox -Command 'done' -NoWtSession
        $r.ExitCode | Should Be 0
        Test-Path $sandbox.StateDir | Should Be $false
    }

    It "logs the raw stdin payload it received" {
        $marker = "MARKER_$([Guid]::NewGuid().ToString('N'))"
        Invoke-Hook -Sandbox $sandbox -Command 'done' -Stdin "{`"marker`":`"$marker`"}" | Out-Null
        $nearLines = (Get-HookLogLinesNearSession -Sandbox $sandbox) -join "`n"
        $nearLines | Should Match ([regex]::Escape($marker))
    }

    It "CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 is logged as confirmed" {
        Invoke-Hook -Sandbox $sandbox -Command 'done' -DisableTitleEnv '1' | Out-Null
        $nearLines = (Get-HookLogLinesNearSession -Sandbox $sandbox) -join "`n"
        $nearLines | Should Match 'CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 confirmed'
    }

    It "missing CLAUDE_CODE_DISABLE_TERMINAL_TITLE logs a warning" {
        Invoke-Hook -Sandbox $sandbox -Command 'done' -DisableTitleEnv '' | Out-Null
        $nearLines = (Get-HookLogLinesNearSession -Sandbox $sandbox) -join "`n"
        $nearLines | Should Match 'WARNING.*CLAUDE_CODE_DISABLE_TERMINAL_TITLE'
    }
}
