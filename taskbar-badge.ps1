# Claude Tab Notifier -- Windows Taskbar attention dot (shared module).
#
# Dot-sourced by BOTH watcher-background.ps1 (in its outer scope AND again
# inside its background runspace -- a runspace does not inherit functions
# defined outside it, matching the existing duplication pattern already used
# there for Write-WatcherLog/Native) and watcher-cmd.ps1 (single scope).
#
# Scope of this file: resolve which real, EXISTING Windows Terminal (or
# legacy console) top-level window to badge, and expose a tiny, safe surface
# for setting/clearing that badge. It never creates a window or a taskbar
# icon of its own -- ITaskbarList3::SetOverlayIcon only ever touches the
# taskbar button of a window handle that already exists.
#
# Design note: ITaskbarList3 is a plain vtable-only COM interface (no
# IDispatch/type library). A reference to it that crosses back into loosely
# typed PowerShell can only be late-bound via IDispatch, which fails
# outright ("does not contain a method named 'HrInit'") -- confirmed
# empirically while building the POC this module replaces. The fix used here
# is the same one proven there: the entire create/HrInit/SetOverlayIcon
# sequence lives in real compiled C# (Add-Type -TypeDefinition), and
# PowerShell only ever calls static methods taking plain IntPtr/string.

function Initialize-TaskbarBadgeSupport {
    # Safe to call multiple times, including once per runspace/process scope
    # -- Add-Type throws "type already exists" if invoked twice in a context
    # that can already see the type (types loaded via Add-Type are shared
    # across all runspaces in this process's single AppDomain), so this
    # checks first rather than relying on try/catch around Add-Type itself.
    if (([System.Management.Automation.PSTypeName]'ClaudeTaskbarBadge.Bridge').Type) { return }

    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;

namespace ClaudeTaskbarBadge {

    // Full ITaskbarList3 COM interface, vtable slots declared in the EXACT
    // order Windows defines them (ITaskbarList -> ITaskbarList2 ->
    // ITaskbarList3) -- COM interop dispatches purely by vtable position, so
    // any slot skipped or reordered here would silently call the WRONG
    // native method. Slots this module never calls are still declared (with
    // loose IntPtr signatures) purely to keep the count and order correct.
    [ComImport]
    [Guid("56FDF342-FD6D-11D0-958A-006097C9A090")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ITaskbarList {
        void HrInit();
        void AddTab(IntPtr hwnd);
        void DeleteTab(IntPtr hwnd);
        void ActivateTab(IntPtr hwnd);
        void SetActiveAlt(IntPtr hwnd);
    }

    [ComImport]
    [Guid("602D4995-B13A-429B-A66E-1935E44F4317")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ITaskbarList2 : ITaskbarList {
        new void HrInit();
        new void AddTab(IntPtr hwnd);
        new void DeleteTab(IntPtr hwnd);
        new void ActivateTab(IntPtr hwnd);
        new void SetActiveAlt(IntPtr hwnd);
        void MarkFullscreenWindow(IntPtr hwnd, [MarshalAs(UnmanagedType.Bool)] bool fFullscreen);
    }

    [ComImport]
    [Guid("EA1AFB91-9E28-4B86-90E9-9E9F8A5EEFAF")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ITaskbarList3 : ITaskbarList2 {
        new void HrInit();
        new void AddTab(IntPtr hwnd);
        new void DeleteTab(IntPtr hwnd);
        new void ActivateTab(IntPtr hwnd);
        new void SetActiveAlt(IntPtr hwnd);
        new void MarkFullscreenWindow(IntPtr hwnd, [MarshalAs(UnmanagedType.Bool)] bool fFullscreen);
        void SetProgressValue(IntPtr hwnd, ulong ullCompleted, ulong ullTotal);
        void SetProgressState(IntPtr hwnd, int tbpFlags);
        void RegisterTab(IntPtr hwndTab, IntPtr hwndMDI);
        void UnregisterTab(IntPtr hwndTab);
        void SetTabOrder(IntPtr hwndTab, IntPtr hwndInsertBefore);
        void SetTabActive(IntPtr hwndTab, IntPtr hwndMDI, int tbatFlags);
        int ThumbBarAddButtons(IntPtr hwnd, uint cButtons, IntPtr pButtons);
        int ThumbBarUpdateButtons(IntPtr hwnd, uint cButtons, IntPtr pButtons);
        void ThumbBarSetImageList(IntPtr hwnd, IntPtr himl);
        void SetOverlayIcon(IntPtr hwnd, IntPtr hIcon, [MarshalAs(UnmanagedType.LPWStr)] string pszDescription);
        void SetThumbnailTooltip(IntPtr hwnd, [MarshalAs(UnmanagedType.LPWStr)] string pszTip);
        void SetThumbnailClip(IntPtr hwnd, IntPtr prcClip);
    }

    public static class Native {
        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll", SetLastError = true)]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool DestroyIcon(IntPtr hIcon);
    }

    public static class ProcessWalk {
        private const uint TH32CS_SNAPPROCESS = 0x00000002;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct PROCESSENTRY32 {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string szExeFile;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);
        // Explicit CharSet.Unicode is required on these two (not just on the
        // struct above) -- .NET's DllImport defaults to CharSet.Ansi when
        // unspecified, which silently bound to the Process32FirstA/NextA
        // entry points while the struct was marshaled as Unicode, corrupting
        // every szExeFile string (each pair of ANSI bytes reinterpreted as
        // one UTF-16 character). Confirmed empirically: exe names came back
        // as CJK-looking garbage until this was made consistent.
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern bool Process32First(IntPtr hSnapshot, ref PROCESSENTRY32 lppe);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern bool Process32Next(IntPtr hSnapshot, ref PROCESSENTRY32 lppe);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr hObject);

        // Walks parent pids up from startPid looking for WindowsTerminal.exe,
        // using ONE process-table snapshot (CreateToolhelp32Snapshot) instead
        // of repeated Get-CimInstance Win32_Process/WMI queries -- each CIM
        // call measured ~300-400ms on this machine (WMI provider overhead),
        // which made the previous ancestry walk cost 1.6-2.1 SECONDS of
        // blocking startup latency per watcher process (confirmed by direct
        // timing while validating this feature -- exactly the kind of
        // significant overhead this feature must not introduce). A snapshot
        // reads the whole process table in one native call (a few ms) and the
        // walk itself is then pure in-memory dictionary lookups.
        public static void FindWindowsTerminalAncestor(uint startPid, int maxHops, out uint wtPid, out string chain) {
            wtPid = 0;
            var sb = new StringBuilder();
            var byPid = new Dictionary<uint, PROCESSENTRY32>();

            IntPtr snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (snap == IntPtr.Zero || snap.ToInt64() == -1) {
                chain = "(process snapshot failed)";
                return;
            }
            try {
                var entry = new PROCESSENTRY32();
                entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
                if (Process32First(snap, ref entry)) {
                    do {
                        byPid[entry.th32ProcessID] = entry;
                    } while (Process32Next(snap, ref entry));
                }
            } finally {
                CloseHandle(snap);
            }

            uint cur = startPid;
            for (int i = 0; i < maxHops; i++) {
                PROCESSENTRY32 e;
                if (!byPid.TryGetValue(cur, out e)) { break; }
                if (sb.Length > 0) { sb.Append(" <- "); }
                sb.Append(e.szExeFile).Append("(pid=").Append(cur).Append(")");
                if (string.Equals(e.szExeFile, "WindowsTerminal.exe", StringComparison.OrdinalIgnoreCase)) {
                    wtPid = cur;
                    break;
                }
                if (e.th32ParentProcessID == cur || e.th32ParentProcessID == 0) { break; }
                cur = e.th32ParentProcessID;
            }
            chain = sb.ToString();
        }
    }

    // Keeps the entire COM lifecycle (creation, HrInit, the actual
    // SetOverlayIcon call, and in-memory icon generation/disposal) inside
    // real compiled IL -- see the file header comment for why this can't be
    // split across the PowerShell boundary.
    public static class Bridge {
        private static ITaskbarList3 _instance;

        private static ITaskbarList3 Get() {
            if (_instance == null) {
                var comType = Type.GetTypeFromCLSID(new Guid("56FDF344-FD6D-11D0-958A-006097C9A090"));
                _instance = (ITaskbarList3)Activator.CreateInstance(comType);
                _instance.HrInit();
            }
            return _instance;
        }

        private static IntPtr CreateRedDotIcon() {
            using (var bmp = new Bitmap(16, 16)) {
                using (var g = Graphics.FromImage(bmp)) {
                    g.Clear(Color.Transparent);
                    using (var brush = new SolidBrush(Color.FromArgb(255, 220, 30, 30))) {
                        g.FillEllipse(brush, 1, 1, 14, 14);
                    }
                    using (var pen = new Pen(Color.White, 1.5f)) {
                        g.DrawEllipse(pen, 1, 1, 14, 14);
                    }
                }
                return bmp.GetHicon();
            }
        }

        // The Shell makes its own copy of the icon inside SetOverlayIcon, so
        // it is safe (and correct -- avoids a GDI handle leak) to destroy our
        // handle immediately after the call returns, success or failure.
        public static void ShowAttentionDot(IntPtr hwnd) {
            IntPtr hIcon = CreateRedDotIcon();
            try {
                Get().SetOverlayIcon(hwnd, hIcon, "Claude needs attention");
            } finally {
                if (hIcon != IntPtr.Zero) { Native.DestroyIcon(hIcon); }
            }
        }

        public static void ClearAttentionDot(IntPtr hwnd) {
            Get().SetOverlayIcon(hwnd, IntPtr.Zero, null);
        }
    }
}
"@ -ReferencedAssemblies System.Drawing
}

function Resolve-TaskbarWindowTarget {
    # Finds the ONE real, existing top-level window whose taskbar button
    # should carry the attention dot. Never guesses across a real ambiguity
    # (documented case: more than one Windows Terminal top-level window
    # owned by the same WindowsTerminal.exe process) -- returns Available =
    # $false instead, with a Reason explaining exactly why, and the caller
    # must simply not badge anything for that session. This is the one
    # limitation flagged up front: there is no documented API/env var that
    # exposes "my own WT top-level HWND" directly from inside a pane process.
    Initialize-TaskbarBadgeSupport

    # CLAUDE_TAB_NOTIFIER_TEST_HWND is a test-only seam, same spirit as
    # CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND above: it lets Pester force a
    # specific (including deliberately invalid) target handle -- e.g. to
    # prove a Taskbar API failure is caught and logged without breaking the
    # watcher loop or the existing sound/emoji notification -- without ever
    # touching the real desktop's real window. Unset in every real run.
    if ($env:CLAUDE_TAB_NOTIFIER_TEST_HWND) {
        return [PSCustomObject]@{
            Hwnd      = [IntPtr][long]$env:CLAUDE_TAB_NOTIFIER_TEST_HWND
            Available = $true
            Reason    = "TEST OVERRIDE: CLAUDE_TAB_NOTIFIER_TEST_HWND=$($env:CLAUDE_TAB_NOTIFIER_TEST_HWND)"
        }
    }

    [uint32]$wtPidOut = 0
    [string]$chainOut = ''
    [ClaudeTaskbarBadge.ProcessWalk]::FindWindowsTerminalAncestor([uint32]$PID, 12, [ref]$wtPidOut, [ref]$chainOut)
    $wtPid = if ($wtPidOut -ne 0) { $wtPidOut } else { $null }
    $chain = $chainOut

    if ($wtPid) {
        $matches = New-Object System.Collections.Generic.List[IntPtr]
        $callback = {
            param($hWnd, $lParam)
            [uint32]$ownerPid = 0
            [void][ClaudeTaskbarBadge.Native]::GetWindowThreadProcessId($hWnd, [ref]$ownerPid)
            if ($ownerPid -eq $wtPid -and [ClaudeTaskbarBadge.Native]::IsWindowVisible($hWnd)) {
                $sb = New-Object System.Text.StringBuilder 256
                [void][ClaudeTaskbarBadge.Native]::GetClassName($hWnd, $sb, 256)
                if ($sb.ToString() -eq 'CASCADIA_HOSTING_WINDOW_CLASS') {
                    $matches.Add($hWnd)
                }
            }
            return $true
        }
        [void][ClaudeTaskbarBadge.Native]::EnumWindows($callback, [IntPtr]::Zero)

        if ($matches.Count -eq 1) {
            return [PSCustomObject]@{
                Hwnd      = $matches[0]
                Available = $true
                Reason    = "resolved via WindowsTerminal.exe ancestor (pid=$wtPid), ancestry=$chain"
            }
        } elseif ($matches.Count -gt 1) {
            # Real ambiguity (multiple top-level WT windows owned by the same
            # process) -- documented limitation, not guessed around.
            return [PSCustomObject]@{
                Hwnd      = $null
                Available = $false
                Reason    = "AMBIGUOUS: $($matches.Count) CASCADIA_HOSTING_WINDOW_CLASS windows owned by WindowsTerminal.exe pid=$wtPid -- not guessing which one, taskbar dot disabled for this session"
            }
        } else {
            # Found the WT process but no matching visible top-level window --
            # NOT falling back to GetConsoleWindow() here: under ConPTY that
            # returns a hidden pseudo-console window, not the real visible WT
            # window, so it would silently badge nothing.
            return [PSCustomObject]@{
                Hwnd      = $null
                Available = $false
                Reason    = "WindowsTerminal.exe ancestor found (pid=$wtPid) but no visible CASCADIA_HOSTING_WINDOW_CLASS window could be enumerated for it -- taskbar dot disabled for this session"
            }
        }
    }

    # No Windows Terminal ancestor at all -- a legacy standalone console
    # (conhost), where GetConsoleWindow() reliably IS the real, visible
    # top-level window (no ConPTY indirection involved).
    $cw = [ClaudeTaskbarBadge.Native]::GetConsoleWindow()
    if ($cw -ne [IntPtr]::Zero) {
        return [PSCustomObject]@{
            Hwnd      = $cw
            Available = $true
            Reason    = "no WindowsTerminal.exe ancestor -- using GetConsoleWindow() (legacy console), ancestry=$chain"
        }
    }

    return [PSCustomObject]@{
        Hwnd      = $null
        Available = $false
        Reason    = "no WindowsTerminal.exe ancestor and GetConsoleWindow() returned no window -- taskbar dot disabled for this session"
    }
}

function Test-TaskbarAnyAttention {
    # The aggregate signal for the WHOLE Windows Terminal window: true if ANY
    # session's own state file (already written by the existing hook/watcher
    # mechanism, untouched by this feature) currently says needsAttention.
    # Deliberately reads the same per-session state files the pulse/sound
    # logic already reads -- no new per-session file is introduced, so there
    # is exactly one source of truth for "does this session need attention",
    # never two that could disagree.
    param([string]$StateDir)
    try {
        $files = Get-ChildItem -Path $StateDir -Filter '*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '_*' }
    } catch {
        return $false
    }
    foreach ($f in $files) {
        try {
            $status = (Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json).status
            if ($status -eq 'needsAttention') { return $true }
        } catch {
            continue
        }
    }
    return $false
}

function Test-TaskbarIsForeground {
    # CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE is a test-only seam (Pester
    # sets it on the spawned watcher process's environment only -- never
    # touched by install.ps1, the real hooks, or any user-facing config). It
    # exists because a background/non-interactive process cannot reliably
    # force itself into the real OS foreground (SetForegroundWindow returns
    # FALSE when called this way -- confirmed empirically while validating
    # this feature), so real "the user actually switched back" end-to-end
    # coverage is not automatable. Pointing this at a small file (re-read
    # every call, same polling-a-file spirit as $stateFile) lets a test flip
    # simulated foreground state for an already-running watcher process,
    # exercising the WATCHER'S OWN DECISION LOGIC deterministically without
    # touching real OS window focus. In every real, non-test run this
    # variable is unset and GetForegroundWindow() alone decides.
    param([IntPtr]$Hwnd)
    $overrideFile = $env:CLAUDE_TAB_NOTIFIER_TEST_FOREGROUND_FILE
    if ($overrideFile) {
        try {
            return ((Get-Content $overrideFile -Raw -ErrorAction Stop).Trim() -eq '1')
        } catch {
            return $false
        }
    }
    return ([ClaudeTaskbarBadge.Native]::GetForegroundWindow() -eq $Hwnd)
}

function Show-TaskbarAttentionDot {
    param([IntPtr]$Hwnd)
    try {
        [ClaudeTaskbarBadge.Bridge]::ShowAttentionDot($Hwnd)
        return [PSCustomObject]@{ Success = $true; Error = $null }
    } catch {
        return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
    }
}

function Clear-TaskbarAttentionDot {
    param([IntPtr]$Hwnd)
    try {
        [ClaudeTaskbarBadge.Bridge]::ClearAttentionDot($Hwnd)
        return [PSCustomObject]@{ Success = $true; Error = $null }
    } catch {
        return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message }
    }
}
