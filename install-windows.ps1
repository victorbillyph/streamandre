#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$PLUGIN_NAME = "StreamRelay"
$REPO_URL = "https://raw.githubusercontent.com/victorbillyph/streamandre/main/StreamRelay.tsx"

Write-Host "=== StreamRelay Installer for Windows ===" -ForegroundColor Cyan
Write-Host ""

# Check admin
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# Detect Vencord path
$VENCORD_DIR = $null
$possiblePaths = @(
    "$env:APPDATA\Vencord",
    "$env:LOCALAPPDATA\Discord\Vencord",
    "$env:USERPROFILE\.config\Vencord"
)

foreach ($path in $possiblePaths) {
    if (Test-Path $path) {
        $VENCORD_DIR = $path
        break
    }
}

if (-not $VENCORD_DIR) {
    Write-Host "Vencord not found. Installing to default path..." -ForegroundColor Yellow
    $VENCORD_DIR = "$env:APPDATA\Vencord"
}

$PLUGINS_DIR = "$VENCORD_DIR\plugins"
New-Item -ItemType Directory -Force -Path $PLUGINS_DIR | Out-Null

Write-Host "Downloading plugin..." -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri $REPO_URL -OutFile "$PLUGINS_DIR\$PLUGIN_NAME.jsx" -UseBasicParsing
} catch {
    Write-Host "Failed to download plugin: $_" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path "$PLUGINS_DIR\$PLUGIN_NAME.jsx")) {
    Write-Host "Plugin file not found after download. Exiting." -ForegroundColor Red
    exit 1
}

Write-Host "Plugin installed to: $PLUGINS_DIR\$PLUGIN_NAME.jsx" -ForegroundColor Green
Write-Host ""
Write-Host "=== Restart Discord to apply ===" -ForegroundColor Yellow
Write-Host "Enable the plugin in Vencord Settings > Plugins"
