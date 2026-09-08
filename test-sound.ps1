param([string]$Sound)

$ErrorActionPreference = 'Stop'

$configPath = Join-Path $PSScriptRoot 'config.json'
$soundEnabled = $true
$selectedSound = 'classic'
$customSoundFile = ''

if (Test-Path $configPath) {
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($null -ne $config.soundEnabled) { $soundEnabled = [bool]$config.soundEnabled }
        if ($config.selectedSound) { $selectedSound = $config.selectedSound }
        if ($config.customSoundFile) { $customSoundFile = $config.customSoundFile }
    } catch {
        Write-Host "Failed to read config.json: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# -Sound explicitly previews a specific sound by name, overriding the configured
# selection AND the enabled flag -- previewing is a deliberate request to hear it,
# not the "play on needsAttention" path, so soundEnabled=false shouldn't block it.
if ($Sound) {
    $selectedSound = $Sound
} elseif (-not $soundEnabled) {
    Write-Host "Sound is disabled in config.json -- nothing to test. Pass -Sound <name> to preview anyway." -ForegroundColor Yellow
    exit 0
}

if ($selectedSound -eq 'custom') {
    if ($customSoundFile -and [System.IO.Path]::IsPathRooted($customSoundFile)) {
        $soundFile = $customSoundFile
    } else {
        $soundFile = Join-Path $PSScriptRoot $customSoundFile
    }
} else {
    $soundFile = Join-Path $PSScriptRoot "sounds\$selectedSound.wav"
}

Write-Host "selectedSound = $selectedSound"
Write-Host "soundFile     = $soundFile"

if (-not (Test-Path $soundFile)) {
    Write-Host "Sound file not found: $soundFile" -ForegroundColor Red
    exit 1
}

Write-Host "Playing $soundFile ..."
$player = New-Object System.Media.SoundPlayer $soundFile
$player.PlaySync()
Write-Host "Done."
