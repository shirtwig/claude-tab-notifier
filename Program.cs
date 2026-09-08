using System.Text.Json;

namespace ClaudeAttention;

/// <summary>
/// Minimal test hook for the Claude Tab Notifier POC (test #1: real hook -> state file -> watcher).
/// Reads its own WT_SESSION (inherited from Claude Code's process environment) and writes
/// {"status": "needsAttention"|"clear"} to %LOCALAPPDATA%\ClaudeTabNotifier\state\<WT_SESSION>.json.
/// Does NOT touch the console/title itself -- that's the watcher's job (proven separately).
/// </summary>
internal static class Program
{
    private static readonly string LogPath =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "tools", "claudeattention.log");

    private static int Main(string[] args)
    {
        var command = args.Length > 0 ? args[0].ToLowerInvariant() : string.Empty;
        var stdin = ReadStdin();
        Log($"command={command} stdinBytes={stdin?.Length ?? -1}");
        if (!string.IsNullOrEmpty(stdin))
        {
            Log($"stdin={stdin}");
        }

        var wtSession = Environment.GetEnvironmentVariable("WT_SESSION");
        Log($"WT_SESSION={(wtSession ?? "<null>")}");

        // Claude Code manages the console title itself (spinner + summary titles), which
        // races with the watcher's own title writes -- confirmed via millisecond-resolution
        // polling during POC testing. CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 (set via
        // ~/.claude/settings.json's "env" block) stops Claude Code from doing that. This is
        // diagnostic only -- it doesn't change hook behavior, just flags the problem early.
        var titleDisableVar = Environment.GetEnvironmentVariable("CLAUDE_CODE_DISABLE_TERMINAL_TITLE");
        if (titleDisableVar != "1")
        {
            Log($"WARNING: CLAUDE_CODE_DISABLE_TERMINAL_TITLE={(titleDisableVar ?? "<null>")} (expected \"1\") -- " +
                "Claude Code's own title management is likely still active and may race with the watcher's marker.");
        }
        else
        {
            Log("CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 confirmed.");
        }

        string? status = command switch
        {
            "alert" => "needsAttention", // Notification: Claude is waiting for input
            "done" => "needsAttention",  // Stop: Claude finished responding
            "clear" => "clear",          // UserPromptSubmit: user is back
            _ => null
        };

        if (status is null)
        {
            Console.Error.WriteLine("Usage: ClaudeAttention.exe <alert|done|clear>");
            return 1;
        }

        if (string.IsNullOrEmpty(wtSession))
        {
            Log("No WT_SESSION in hook process environment -- cannot write tab state, skipping.");
            return 0;
        }

        WriteState(wtSession, status);
        return 0;
    }

    private static void WriteState(string wtSession, string status)
    {
        try
        {
            var stateDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ClaudeTabNotifier", "state");
            Directory.CreateDirectory(stateDir);

            var stateFile = Path.Combine(stateDir, $"{wtSession}.json");
            var json = JsonSerializer.Serialize(new { status });
            File.WriteAllText(stateFile, json, System.Text.Encoding.UTF8);
            Log($"wrote state file \"{stateFile}\" = {json}");
        }
        catch (Exception ex)
        {
            Log($"WriteState FAILED: {ex}");
        }
    }

    private static string? ReadStdin()
    {
        try
        {
            return Console.IsInputRedirected ? Console.In.ReadToEnd() : null;
        }
        catch (Exception ex)
        {
            Log($"stdin read FAILED: {ex}");
            return null;
        }
    }

    private const long MaxLogBytes = 1024 * 1024;

    private static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);

            // Rotate BEFORE appending, same pattern as the watcher scripts' own
            // Write-WatcherLog: this hook fires multiple times per Claude Code
            // turn over the life of the install, so without a cap the log grows
            // unbounded (the watcher-side log already had this fixed; this one
            // hadn't).
            var info = new FileInfo(LogPath);
            if (info.Exists && info.Length >= MaxLogBytes)
            {
                var oldPath = LogPath + ".old";
                File.Delete(oldPath);
                File.Move(LogPath, oldPath);
                File.WriteAllText(LogPath, $"{DateTime.Now:HH:mm:ss.fff} LOG ROTATED (previous entries in {Path.GetFileName(oldPath)}){Environment.NewLine}");
            }

            File.AppendAllText(LogPath, $"{DateTime.Now:HH:mm:ss.fff} {message}{Environment.NewLine}");
        }
        catch
        {
            // Logging must never break the actual notification.
        }
    }
}
