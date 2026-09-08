@echo off
start /B powershell -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\ClaudeTabNotifierPOC\watcher-cmd.ps1"
echo Claude Tab Notifier watcher started in background (CMD).
