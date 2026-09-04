# StreamRelay Helper Installer for Windows
# Instala as dependencias e configura o helper de captura de tela

$ErrorActionPreference = "Stop"

$INSTALL_DIR = "$env:LOCALAPPDATA\StreamRelay"
$REPO_URL = "https://github.com/victorbillyph/streamandre.git"

Write-Host "=== StreamRelay Helper Installer ===" -ForegroundColor Cyan
Write-Host ""

# Check dependencies
Write-Host "Verificando dependencias..." -ForegroundColor Cyan

function Check-Command($cmd) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) {
        Write-Host "  [OK] $cmd" -ForegroundColor Green
        return $true
    } else {
        Write-Host "  [FALTA] $cmd" -ForegroundColor Red
        return $false
    }
}

$missing = @()
if (-not (Check-Command "git")) { $missing += "git" }
if (-not (Check-Command "node")) { $missing += "node" }
if (-not (Check-Command "npm")) { $missing += "npm" }

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "Instalando dependencias faltantes..." -ForegroundColor Yellow
    $wingetMap = @{ git = "Git.Git"; node = "OpenJS.NodeJS.LTS"; npm = "OpenJS.NodeJS.LTS" }
    $chocoMap = @{ git = "git"; node = "nodejs"; npm = "nodejs" }
    foreach ($dep in $missing) {
        $installed = $false
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            $id = $wingetMap[$dep]; if (-not $id) { $id = $dep }
            Write-Host "  winget install $id ..." -ForegroundColor Yellow
            try {
                winget install -e --id $id --accept-source-agreements --accept-package-agreements --silent --disable-interactivity 2>&1 | Out-Null
                # atualiza PATH
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            } catch {}
            if (Get-Command $dep -ErrorAction SilentlyContinue) { $installed = $true; Write-Host "  [OK] $dep instalado via winget" -ForegroundColor Green }
        }
        if (-not $installed -and (Get-Command choco -ErrorAction SilentlyContinue)) {
            $cid = $chocoMap[$dep]; if (-not $cid) { $cid = $dep }
            Write-Host "  choco install $cid ..." -ForegroundColor Yellow
            try { choco install $cid -y --no-progress 2>&1 | Out-Null } catch {}
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            if (Get-Command $dep -ErrorAction SilentlyContinue) { $installed = $true }
        }
        if (-not $installed) {
            Write-Host "  [ERRO] Falha ao instalar $dep" -ForegroundColor Red
        }
    }
    # revalida
    $stillMissing = @()
    foreach ($dep in $missing) { if (-not (Get-Command $dep -ErrorAction SilentlyContinue)) { $stillMissing += $dep } }
    if ($stillMissing.Count -gt 0) {
        Write-Host "Instale manualmente: $($stillMissing -join ', ')" -ForegroundColor Red
        Write-Host "  - Git: https://git-scm.com/download/win"
        Write-Host "  - Node.js: https://nodejs.org/"
        exit 1
    }
    Write-Host "Dependencias instaladas. Reinicie o terminal se necessario." -ForegroundColor Green
}

Write-Host ""
Write-Host "Clonando repositorio..." -ForegroundColor Cyan
if (Test-Path "$INSTALL_DIR\.git") {
    Set-Location $INSTALL_DIR
    git pull
} else {
    git clone $REPO_URL $INSTALL_DIR
}

Write-Host ""
Write-Host "Instalando dependencias Node.js..." -ForegroundColor Cyan
Set-Location "$INSTALL_DIR\client"
npm install

Write-Host ""
Write-Host "Criando script de inicializacao..." -ForegroundColor Cyan

$batContent = @"
@echo off
echo StreamRelay Helper
echo.

set ONION=%1
set PORT=%2
set BRIDGE=%3

if "%ONION%"=="" set ONION=m5u54wss3pxhi6tqvwv3i3l2m35wv3foitg6kkxln5fmef5blw6ybtad.onion
if "%PORT%"=="" set PORT=8080
if "%BRIDGE%"=="" set BRIDGE=6789

echo Onion: %ONION%:%PORT%
echo.

cd /d "%INSTALL_DIR%\client"
echo Iniciando bridge Tor...
start /b node bridge.mjs %ONION% %PORT%
timeout /t 2 /nobreak >nul

echo Iniciando captura de tela...
echo Pressione Ctrl+C para parar
node capture-helper.js
"@

$batContent | Out-File -FilePath "$env:LOCALAPPDATA\bin\streamrelay-start.bat" -Encoding ASCII

Write-Host ""
Write-Host "=== Instalacao concluida! ===" -ForegroundColor Green
Write-Host ""
Write-Host "Para usar:" -ForegroundColor Yellow
Write-Host "  streamrelay-start"
Write-Host ""
Write-Host "Ou manualmente:" -ForegroundColor Yellow
Write-Host "  cd $INSTALL_DIR\client"
Write-Host "  node bridge.mjs <onion> <porta>"
Write-Host "  node capture-helper.js"
