# StreamRelay Helper Installer for Windows
# Instala as dependencias e configura o helper de captura de tela

$ErrorActionPreference = "Stop"

# requer admin para winget/choco/msi
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requer Admin — reiniciando como administrador..." -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"irm 'https://raw.githubusercontent.com/victorbillyph/streamandre/main/install-helper.ps1' | iex`""
    exit
}

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
            # fallback portable (sem admin)
            $toolsDir = "$INSTALL_DIR\tools"
            New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
            if ($dep -eq "git") {
                Write-Host "  Baixando Git portatil (sem instalar)..." -ForegroundColor Yellow
                try {
                    $url = "https://github.com/git-for-windows/git/releases/download/v2.45.1.windows.1/MinGit-2.45.1-64-bit.zip"
                    $tmp = "$env:TEMP\mingit.zip"
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    try { Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -MaximumRedirection 5 } catch { Start-BitsTransfer -Source $url -Destination $tmp -ErrorAction Stop }
                    Expand-Archive -Path $tmp -DestinationPath "$toolsDir\git" -Force
                    $env:Path = "$toolsDir\git\cmd;$toolsDir\git\mingw64\bin;" + $env:Path
                    if (Test-Path "$toolsDir\git\cmd\git.exe") { $installed = $true; Write-Host "  [OK] Git portatil pronto" -ForegroundColor Green }
                } catch { Write-Host "  Falha Git portatil: $_" -ForegroundColor Red }
            } elseif ($dep -eq "node" -or $dep -eq "npm") {
                Write-Host "  Baixando Node.js portatil..." -ForegroundColor Yellow
                try {
                    $url = "https://nodejs.org/dist/v20.18.0/node-v20.18.0-win-x64.zip"
                    $tmp = "$env:TEMP\node.zip"
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    try { Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -MaximumRedirection 5 } catch { Start-BitsTransfer -Source $url -Destination $tmp -ErrorAction Stop }
                    Expand-Archive -Path $tmp -DestinationPath $toolsDir -Force
                    $env:Path = "$toolsDir\node-v20.18.0-win-x64;" + $env:Path
                    if (Test-Path "$toolsDir\node-v20.18.0-win-x64\node.exe") { $installed = $true; Write-Host "  [OK] Node portatil pronto" -ForegroundColor Green }
                } catch { Write-Host "  Falha Node portatil: $_" -ForegroundColor Red }
            }
            if (-not $installed) { Write-Host "  [ERRO] Falha ao instalar $dep" -ForegroundColor Red }
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
# usa git portatil se instalou
if (Test-Path "$INSTALL_DIR\tools\git\cmd\git.exe") { $env:Path = "$INSTALL_DIR\tools\git\cmd;" + $env:Path }
if (Test-Path "$INSTALL_DIR\tools\node-v20.18.0-win-x64\node.exe") { $env:Path = "$INSTALL_DIR\tools\node-v20.18.0-win-x64;" + $env:Path }
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
