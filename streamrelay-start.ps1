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

function Update-Helper {
    if (Test-Path "$INSTALL_DIR\.git") {
        Write-Host "Verificando atualizacoes..." -ForegroundColor Yellow
        Push-Location $INSTALL_DIR
        git fetch --quiet
        $local = git rev-parse HEAD
        $remote = git rev-parse '@{u}' 2>$null; if (-not $remote) { $remote = $local }
        if ($local -ne $remote) {
            Write-Host "Nova versao encontrada, atualizando..." -ForegroundColor Yellow
            git pull --ff-only --quiet
            Write-Host "Atualizado!" -ForegroundColor Green
            Push-Location "$INSTALL_DIR\client"; npm install --silent; Pop-Location
            if ((Test-Path "$INSTALL_DIR\plugin\StreamRelay.tsx") -and (Test-Path "$env:USERPROFILE\Vencord\src\userplugins\StreamRelay.tsx")) {
                $a = Get-FileHash "$INSTALL_DIR\plugin\StreamRelay.tsx"
                $b = Get-FileHash "$env:USERPROFILE\Vencord\src\userplugins\StreamRelay.tsx"
                if ($a.Hash -ne $b.Hash) {
                    Write-Host "Plugin atualizado, recompilando..." -ForegroundColor Yellow
                    Copy-Item "$INSTALL_DIR\plugin\StreamRelay.tsx" "$env:USERPROFILE\Vencord\src\userplugins\StreamRelay.tsx" -Force
                    Push-Location "$env:USERPROFILE\Vencord"; pnpm build | Out-Null; Start-Process -FilePath "pnpm" -ArgumentList "inject" -Verb RunAs -Wait; Pop-Location
                    Write-Host "[OK] Plugin atualizado" -ForegroundColor Green
                }
            }
        } else {
            Write-Host "[OK] Ja na ultima versao" -ForegroundColor Green
        }
        Pop-Location
    }
}

function Ensure-Deps {
    $need = @()
    foreach ($c in @("git","node","pnpm")) { if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { $need += $c } }
    if ($need.Count -eq 0) { return }
    Write-Host "Dependencias faltando: $($need -join ', ') — instalando..." -ForegroundColor Yellow
    $map = @{ git = "Git.Git"; node = "OpenJS.NodeJS.LTS"; pnpm = "pnpm.pnpm" }
    foreach ($dep in $need) {
        $id = $map[$dep]; if (-not $id) { $id = $dep }
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            try { winget install -e --id $id --accept-source-agreements --accept-package-agreements --silent --disable-interactivity | Out-Null } catch {}
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        }
        if (-not (Get-Command $dep -ErrorAction SilentlyContinue) -and (Get-Command choco -ErrorAction SilentlyContinue)) {
            try { choco install $dep -y --no-progress | Out-Null } catch {}
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        }
        if (-not (Get-Command $dep -ErrorAction SilentlyContinue)) {
            # fallback manual
            if ($dep -eq "git") {
                Write-Host "Baixando Git manualmente..." -ForegroundColor Yellow
                $url = "https://github.com/git-for-windows/git/releases/latest/download/Git-2.45.0-64-bit.exe"
                $tmp = "$env:TEMP\Git-installer.exe"
                Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
                Start-Process -FilePath $tmp -ArgumentList "/VERYSILENT /NORESTART" -Wait
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            } elseif ($dep -eq "node") {
                Write-Host "Baixando Node.js manualmente..." -ForegroundColor Yellow
                $url = "https://nodejs.org/dist/latest-v20.x/node-v20.18.0-x64.msi"
                $tmp = "$env:TEMP\node-installer.msi"
                Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
                Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$tmp`" /quiet /norestart" -Wait
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            } elseif ($dep -eq "pnpm") {
                npm install -g pnpm
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            }
            if (-not (Get-Command $dep -ErrorAction SilentlyContinue)) {
                throw "Falha ao instalar $dep. Instale manualmente: https://github.com/$id"
            }
        }
    }
}

function Ensure-VencordPlugin {
    try { Ensure-Deps } catch { Write-Host "[AVISO] $_" -ForegroundColor Yellow; return }
    $VENCORD_DIR = "$env:USERPROFILE\Vencord"
    $PLUGIN_SRC = "$INSTALL_DIR\plugin\StreamRelay.tsx"
    $USERPLUGIN = "$VENCORD_DIR\src\userplugins\StreamRelay.tsx"
    if (Test-Path $USERPLUGIN) {
        Write-Host "[OK] Plugin Vencord ja instalado" -ForegroundColor Green
        return
    }
    Write-Host "Plugin Vencord nao encontrado. Instalando..." -ForegroundColor Yellow
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git nao encontrado apos instalacao" }
    if (-not (Test-Path "$VENCORD_DIR\.git")) {
        Write-Host "Clonando Vencord..." -ForegroundColor Yellow
        git clone https://github.com/Vendicated/Vencord.git $VENCORD_DIR
    }
    New-Item -ItemType Directory -Force -Path "$VENCORD_DIR\src\userplugins" | Out-Null
    Copy-Item $PLUGIN_SRC $USERPLUGIN -Force
    Write-Host "Instalando dependencias e compilando..." -ForegroundColor Yellow
    Push-Location $VENCORD_DIR
    pnpm install; pnpm build
    Pop-Location
    Write-Host "Patchando Discord (Admin necessario)..." -ForegroundColor Yellow
    Push-Location $VENCORD_DIR
    Start-Process -FilePath "pnpm" -ArgumentList "inject" -Verb RunAs -Wait
    Pop-Location
    Write-Host "[OK] Plugin instalado! Reinicie o Discord" -ForegroundColor Green
}

# Main
Write-Host "Onion: ${Onion}:${Port}" -ForegroundColor Green
Write-Host ""
Update-Helper
try { Ensure-VencordPlugin } catch { Write-Host "[AVISO] Falha ao instalar plugin: $_" -ForegroundColor Yellow }

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
