# StreamRelay - Inicia helper com Tor automatico (Windows)
# Execute: .\streamrelay-start.ps1

param(
    [string]$Onion = "m5u54wss3pxhi6tqvwv3i3l2m35wv3foitg6kkxln5fmef5blw6ybtad.onion",
    [int]$Port = 8080,
    [int]$BridgePort = 6789
)

$ErrorActionPreference = "Stop"

$INSTALL_DIR = "$env:LOCALAPPDATA\StreamRelay"
$TOR_DIR = "$INSTALL_DIR\tor"
$TOR_EXE = "$TOR_DIR\tor.exe"
$TOR_DATA = "$INSTALL_DIR\tor-data"
$TOR_SOCKS = 9050

Write-Host "=== StreamRelay Helper ===" -ForegroundColor Green
Write-Host ""

# Check if Tor is installed
function Test-Tor {
    if (Get-Command "tor" -ErrorAction SilentlyContinue) { return $true }
    if (Test-Path $TOR_EXE) { return $true }
    return $false
}

# Download Tor
function Install-Tor {
    Write-Host "Tor nao encontrado. Baixando..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path $TOR_DIR | Out-Null
    
    $arch = if ([Environment]::Is64BitOperatingSystem) { "windows-x86_64" } else { "windows-i686" }
    $url = "https://github.com/nickvdp/tor-binary/releases/latest/download/tor-${arch}.exe"
    
    Write-Host "Baixando Tor..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $url -OutFile $TOR_EXE -UseBasicParsing
    
    Write-Host "Tor baixado!" -ForegroundColor Green
}

# Start Tor
function Start-Tor {
    # Check if already running
    $port = Get-NetTCPConnection -LocalPort $TOR_SOCKS -ErrorAction SilentlyContinue
    if ($port) {
        Write-Host "[OK] Tor ja rodando na porta $TOR_SOCKS" -ForegroundColor Green
        return
    }
    
    Write-Host "Iniciando Tor..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path $TOR_DATA | Out-Null
    
    # Create torrc
    $torrc = @"
SocksPort $TOR_SOCKS
DataDirectory $TOR_DATA
Log notice file $TOR_DATA\tor.log
"@
    $torrc | Out-File -FilePath "$TOR_DATA\torrc" -Encoding ASCII
    
    # Start Tor
    $torCmd = if (Get-Command "tor" -ErrorAction SilentlyContinue) { "tor" } else { $TOR_EXE }
    Start-Process -FilePath $torCmd -ArgumentList "-f", "$TOR_DATA\torrc" -WindowStyle Hidden
    
    # Wait for Tor
    Write-Host "Aguardando Tor conectar..." -ForegroundColor Yellow
    for ($i = 0; $i -lt 30; $i++) {
        $port = Get-NetTCPConnection -LocalPort $TOR_SOCKS -ErrorAction SilentlyContinue
        if ($port) {
            Write-Host "[OK] Tor conectado!" -ForegroundColor Green
            return
        }
        Start-Sleep -Seconds 1
        Write-Host "." -NoNewline
    }
    
    Write-Host ""
    throw "Tor nao conectou em 30 segundos"
}

# Start relay server
function Start-Server {
    $proc = Get-Process -Name "node" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -like "*relayServer*"
    }
    
    if ($proc) {
        Write-Host "[OK] Servidor relay ja rodando" -ForegroundColor Green
        return
    }
    
    Write-Host "Iniciando servidor relay..." -ForegroundColor Yellow
    Push-Location "$INSTALL_DIR\server"
    $env:TOR_DATA_DIR = $TOR_DATA
    Start-Process -FilePath "node" -ArgumentList "relayServer.mjs" -WindowStyle Hidden
    Pop-Location
    Start-Sleep -Seconds 2
    Write-Host "[OK] Servidor relay iniciado" -ForegroundColor Green
}

# Start bridge
function Start-Bridge {
    Write-Host "Iniciando bridge Tor..." -ForegroundColor Yellow
    Push-Location "$INSTALL_DIR\client"
    $bridgeProc = Start-Process -FilePath "node" -ArgumentList "bridge.mjs", $Onion, $Port -PassThru -WindowStyle Hidden
    Pop-Location
    Start-Sleep -Seconds 2
    Write-Host "[OK] Bridge conectado" -ForegroundColor Green
    return $bridgeProc
}

# Main
Write-Host "Onion: ${Onion}:${Port}" -ForegroundColor Green
Write-Host ""

try {
    if (-not (Test-Tor)) {
        Install-Tor
    }
    
    Start-Tor
    Start-Server
    $bridgeProc = Start-Bridge
    
    Write-Host ""
    Write-Host "Iniciando captura de tela..." -ForegroundColor Green
    Write-Host "Pressione Ctrl+C para parar" -ForegroundColor Yellow
    Write-Host ""
    
    Push-Location "$INSTALL_DIR\client"
    node capture-helper.js
    Pop-Location
} finally {
    if ($bridgeProc) { Stop-Process -Id $bridgeProc.Id -Force -ErrorAction SilentlyContinue }
    Write-Host "Parado!" -ForegroundColor Green
}
