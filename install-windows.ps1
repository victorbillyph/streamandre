#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$PLUGIN_NAME = "StreamRelay"
$REPO_URL = "https://raw.githubusercontent.com/victorbillyph/streamandre/main/plugin/StreamRelay.tsx"
$VENCORD_REPO = "https://github.com/Vendicated/Vencord.git"

Write-Host "=== StreamRelay Installer for Windows ===" -ForegroundColor Cyan
Write-Host ""

# Check admin
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# Check dependencies
Write-Host "Checking dependencies..." -ForegroundColor Cyan
$deps = @("git", "node", "pnpm")
foreach ($dep in $deps) {
    if (-not (Get-Command $dep -ErrorAction SilentlyContinue)) {
        Write-Host "Installing $dep..." -ForegroundColor Yellow
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            winget install -e --id $dep
        } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
            choco install $dep -y
        } else {
            Write-Host "Please install $dep manually" -ForegroundColor Red
        }
    }
}

# Find or clone Vencord
$VENCORD_DIR = $null
$possiblePaths = @(
    "$env:USERPROFILE\Vencord",
    "$env:USERPROFILE\Projects\Vencord",
    "$env:USERPROFILE\Code\Vencord",
    "$env:LOCALAPPDATA\Vencord"
)

foreach ($path in $possiblePaths) {
    if (Test-Path "$path\src") {
        $VENCORD_DIR = $path
        break
    }
}

if (-not $VENCORD_DIR) {
    Write-Host "Vencord source not found. Cloning..." -ForegroundColor Yellow
    $VENCORD_DIR = "$env:USERPROFILE\Vencord"
    git clone $VENCORD_REPO $VENCORD_DIR
}

Write-Host "Using Vencord at: $VENCORD_DIR" -ForegroundColor Green

# Create userplugins directory
$USERPLUGINS_DIR = "$VENCORD_DIR\src\userplugins"
New-Item -ItemType Directory -Force -Path $USERPLUGINS_DIR | Out-Null

# Download plugin
Write-Host "Downloading plugin..." -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri $REPO_URL -OutFile "$USERPLUGINS_DIR\$PLUGIN_NAME.tsx" -UseBasicParsing
} catch {
    Write-Host "Failed to download plugin: $_" -ForegroundColor Red
    exit 1
}

Write-Host "Plugin installed to: $USERPLUGINS_DIR\$PLUGIN_NAME.tsx" -ForegroundColor Green

# Build Vencord
Write-Host ""
Write-Host "Building Vencord (this may take a few minutes)..." -ForegroundColor Yellow
Set-Location $VENCORD_DIR
pnpm install
pnpm build

Write-Host ""
Write-Host "=== Build complete! ===" -ForegroundColor Green
Write-Host "Restart Discord to apply changes."
Write-Host "Enable the plugin in Vencord Settings > Plugins"
