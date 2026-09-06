# StreamRelay - Script unico Windows: instala Vencord, atualiza, cria comando e inicia tudo
# Uso: irm https://raw.githubusercontent.com/victorbillyph/streamandre/main/streamrelay-start.ps1 | iex

param([string]$Onion = "m5u54wss3pxhi6tqvwv3i3l2m35wv3foitg6kkxln5fmef5blw6ybtad.onion", [int]$Port = 8080, [int]$BridgePort = 6789)
$ErrorActionPreference = "Continue"
$INSTALL_DIR = "$env:LOCALAPPDATA\StreamRelay"
$TOR_DIR = "$INSTALL_DIR\tor"; $TOR_EXE = "$TOR_DIR\tor.exe"; $TOR_DATA = "$INSTALL_DIR\tor-data"; $TOR_SOCKS = 9050
$REPO_URL = "https://github.com/victorbillyph/streamandre.git"

Write-Host "=== StreamRelay Helper ===" -ForegroundColor Green

# --- PATH e comando ---
$binDir = "$env:LOCALAPPDATA\bin"; New-Item -ItemType Directory -Force -Path $binDir | Out-Null
if (-not ($env:Path -split ";" -contains $binDir)) { $env:Path = "$binDir;" + $env:Path; [Environment]::SetEnvironmentVariable("Path", $env:Path, "User") }
# cria .bat que chama este script
$batPath = "$binDir\streamrelay-start.bat"
if (-not (Test-Path $batPath)) { "@echo off`r`npowershell -ExecutionPolicy Bypass -File `"$INSTALL_DIR\streamrelay-start.ps1`" %*" | Out-File -FilePath $batPath -Encoding ASCII }

function Ensure-Install {
    if (-not (Test-Path "$INSTALL_DIR\.git")) {
        Write-Host "Instalacao nao encontrada, clonando..." -ForegroundColor Yellow
        $tmp = Join-Path $env:TEMP ("streamrelay-" + [Guid]::NewGuid().ToString().Substring(0,8))
        $gitExe = (Get-Command git -ErrorAction SilentlyContinue).Source; if (-not $gitExe -and (Test-Path "$INSTALL_DIR\tools\git\cmd\git.exe")) { $gitExe = "$INSTALL_DIR\tools\git\cmd\git.exe" }; if (-not $gitExe) { $gitExe = "git" }
        try { & $gitExe clone --depth 1 $REPO_URL $tmp } catch { Write-Host "Falha clone: $_" -ForegroundColor Red; return }
        New-Item -ItemType Directory -Force -Path $INSTALL_DIR | Out-Null
        Copy-Item -Path "$tmp\*" -Destination $INSTALL_DIR -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -Path "$tmp\.*" -Destination $INSTALL_DIR -Force -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        Push-Location "$INSTALL_DIR\server"; cmd /c "npm.cmd install --silent" 2>$null; Pop-Location
        Push-Location "$INSTALL_DIR\client"; cmd /c "npm.cmd install --silent" 2>$null; Pop-Location
    }
}
Ensure-Install

function Test-Tor { if (Get-Command "tor" -ErrorAction SilentlyContinue) { return $true }; if (Test-Path $TOR_EXE) { return $true }; return $false }
function Install-Tor {
    Write-Host "Tor nao encontrado. Baixando Expert Bundle..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path $TOR_DIR | Out-Null
    $is64 = [Environment]::Is64BitOperatingSystem
    $url = if ($is64) { "https://archive.torproject.org/tor-package-archive/torbrowser/15.0.21/tor-expert-bundle-windows-x86_64-15.0.21.tar.gz" } else { "https://archive.torproject.org/tor-package-archive/torbrowser/15.0.21/tor-expert-bundle-windows-i686-15.0.21.tar.gz" }
    $tmp = "$env:TEMP\tor-expert.tar.gz"
    Write-Host "Baixando $url ..." -ForegroundColor Yellow
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -MaximumRedirection 5
        if ((Get-Item $tmp).Length -lt 5MB) { throw "pequeno" }
    } catch { try { Start-BitsTransfer -Source $url -Destination $tmp -ErrorAction Stop } catch { curl.exe -L $url -o $tmp } }
    Write-Host "Extraindo..." -ForegroundColor Yellow
    try { tar -xzf $tmp -C $TOR_DIR 2>$null } catch { Expand-Archive -Path $tmp -DestinationPath $TOR_DIR -Force 2>$null }
    $found = Get-ChildItem -Path $TOR_DIR -Recurse -Filter "tor.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $script:TOR_EXE = $found.FullName; Write-Host "Tor em: $TOR_EXE" -ForegroundColor Green }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Write-Host "Tor baixado!" -ForegroundColor Green
}
function Repair-Tor {
    Write-Host "Reparando Tor..." -ForegroundColor Yellow
    Get-Process -Name "tor" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$TOR_DATA\lock" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}
function Start-Tor {
    $port = Get-NetTCPConnection -LocalPort $TOR_SOCKS -ErrorAction SilentlyContinue
    if ($port) { Write-Host "[OK] Tor :$TOR_SOCKS" -ForegroundColor Green; return }
    Write-Host "Iniciando Tor..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path $TOR_DATA | Out-Null
    $torrc = "SocksPort $TOR_SOCKS`nDataDirectory $TOR_DATA`nLog notice file $TOR_DATA\tor.log"
    $torrc | Out-File -FilePath "$TOR_DATA\torrc" -Encoding ASCII
    $torCmd = if (Get-Command "tor" -ErrorAction SilentlyContinue) { "tor" } else { $TOR_EXE }
    Start-Process -FilePath $torCmd -ArgumentList "-f", "$TOR_DATA\torrc" -WindowStyle Hidden
    for ($i=0; $i -lt 30; $i++) { $port = Get-NetTCPConnection -LocalPort $TOR_SOCKS -ErrorAction SilentlyContinue; if ($port) { Write-Host "[OK] Tor conectado!" -ForegroundColor Green; return }; Start-Sleep -Seconds 1; Write-Host "." -NoNewline }
    Write-Host ""; Write-Host "[ERRO] Tor falhou, reparando..." -ForegroundColor Red; Repair-Tor
    Start-Process -FilePath $torCmd -ArgumentList "-f", "$TOR_DATA\torrc" -WindowStyle Hidden
    Start-Sleep -Seconds 5
    $port = Get-NetTCPConnection -LocalPort $TOR_SOCKS -ErrorAction SilentlyContinue
    if ($port) { Write-Host "[OK] Tor reparado!" -ForegroundColor Green } else { throw "Falha Tor" }
}
function Repair-Relay {
    Write-Host "Reparando relay..." -ForegroundColor Yellow
    $p = Get-NetTCPConnection -LocalPort $script:Port -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -ne 0 } | Select-Object -First 1
    if ($p) { $proc = Get-Process -Id $p.OwningProcess -ErrorAction SilentlyContinue; if ($proc) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } }
    Start-Sleep -Seconds 1
    Push-Location "$INSTALL_DIR\server"; cmd /c "npm.cmd install --silent" 2>$null; Pop-Location
    Push-Location "$INSTALL_DIR\client"; cmd /c "npm.cmd install --silent" 2>$null; Pop-Location
}
function Start-Server {
    $port = Get-NetTCPConnection -LocalPort $script:Port -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -ne 0 }
    if ($port) { Write-Host "[OK] Relay ja rodando :$script:Port" -ForegroundColor Green; return }
    Write-Host "Iniciando relay..." -ForegroundColor Yellow
    if (-not (Test-Path "$INSTALL_DIR\server\relayServer.mjs")) { Ensure-Install }
    Push-Location "$INSTALL_DIR\server"; $env:TOR_DATA_DIR = $TOR_DATA; Start-Process -FilePath "node" -ArgumentList "relayServer.mjs" -WindowStyle Hidden; Pop-Location; Start-Sleep -Seconds 2
    $port = Get-NetTCPConnection -LocalPort $script:Port -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -ne 0 }
    if ($port) { Write-Host "[OK] Relay iniciado :$script:Port" -ForegroundColor Green; return }
    Repair-Relay; Push-Location "$INSTALL_DIR\server"; $env:TOR_DATA_DIR = $TOR_DATA; Start-Process -FilePath "node" -ArgumentList "relayServer.mjs" -WindowStyle Hidden; Pop-Location; Start-Sleep -Seconds 2
    $port = Get-NetTCPConnection -LocalPort $script:Port -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -ne 0 }
    if (-not $port) { throw "Falha relay - porta $script:Port nao abriu. Tente: cd $INSTALL_DIR\server; node relayServer.mjs" }
    Write-Host "[OK] Relay iniciado apos reparo :$script:Port" -ForegroundColor Green
}
function Start-Bridge {
    Write-Host "Iniciando bridge..." -ForegroundColor Yellow
    Push-Location "$INSTALL_DIR\client"
    $bridgeProc = Start-Process -FilePath "node" -ArgumentList "bridge.mjs", $script:Onion, $script:Port -PassThru -WindowStyle Hidden
    Pop-Location; Start-Sleep -Seconds 2
    if ($bridgeProc -and -not $bridgeProc.HasExited) { Write-Host "[OK] Bridge 127.0.0.1:6789 -> ${script:Onion}:$script:Port" -ForegroundColor Green; return $bridgeProc }
    Write-Host "[AVISO] Bridge falhou, host continua direto" -ForegroundColor Yellow; return $null
}
function Update-Helper {
    if (Test-Path "$INSTALL_DIR\.git") {
        Write-Host "Verificando atualizacoes..." -ForegroundColor Yellow
        Push-Location $INSTALL_DIR; git fetch --quiet
        $local = git rev-parse HEAD; $remote = git rev-parse '@{u}' 2>$null; if (-not $remote) { $remote = $local }
        if ($local -ne $remote) {
            Write-Host "Atualizando..." -ForegroundColor Yellow; git pull --ff-only --quiet; Write-Host "Atualizado!" -ForegroundColor Green
            Push-Location "$INSTALL_DIR\server"; cmd /c "npm.cmd install --silent" 2>$null; Pop-Location
            Push-Location "$INSTALL_DIR\client"; cmd /c "npm.cmd install --silent" 2>$null; Pop-Location
            if ((Test-Path "$INSTALL_DIR\plugin\StreamRelay.tsx") -and (Test-Path "$env:USERPROFILE\Vencord\src\userplugins\StreamRelay.tsx")) {
                $a = Get-FileHash "$INSTALL_DIR\plugin\StreamRelay.tsx"; $b = Get-FileHash "$env:USERPROFILE\Vencord\src\userplugins\StreamRelay.tsx"
                if ($a.Hash -ne $b.Hash) {
                    Copy-Item "$INSTALL_DIR\plugin\StreamRelay.tsx" "$env:USERPROFILE\Vencord\src\userplugins\StreamRelay.tsx" -Force
                    Push-Location "$env:USERPROFILE\Vencord"; cmd /c "pnpm.cmd build" | Out-Null; Start-Process -FilePath "pnpm" -ArgumentList "inject" -Verb RunAs -Wait; Pop-Location
                    Write-Host "[OK] Plugin atualizado" -ForegroundColor Green
                }
            }
        } else { Write-Host "[OK] Ultima versao" -ForegroundColor Green }
        Pop-Location
    }
}
function Ensure-Deps {
    $need = @(); foreach ($c in @("git","node","pnpm")) { if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { $need += $c } }
    if ($need.Count -eq 0) { return }
    Write-Host "Faltando: $($need -join ', ') - baixando portateis..." -ForegroundColor Yellow
    $toolsDir = "$INSTALL_DIR\tools"; New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
    foreach ($dep in $need) {
        if (-not (Get-Command $dep -ErrorAction SilentlyContinue)) {
            if ($dep -eq "git") {
                $url = "https://github.com/git-for-windows/git/releases/download/v2.45.1.windows.1/MinGit-2.45.1-64-bit.zip"; $tmp = "$env:TEMP\mingit.zip"
                try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -MaximumRedirection 5 } catch { Start-BitsTransfer -Source $url -Destination $tmp -ErrorAction SilentlyContinue }
                Expand-Archive -Path $tmp -DestinationPath "$toolsDir\git" -Force; $env:Path = "$toolsDir\git\cmd;" + "$toolsDir\git\mingw64\bin;" + $env:Path
            } elseif ($dep -eq "node") {
                $url = "https://nodejs.org/dist/v20.18.0/node-v20.18.0-win-x64.zip"; $tmp = "$env:TEMP\node.zip"
                try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -MaximumRedirection 5 } catch { Start-BitsTransfer -Source $url -Destination $tmp -ErrorAction SilentlyContinue }
                Expand-Archive -Path $tmp -DestinationPath $toolsDir -Force; $env:Path = "$toolsDir\node-v20.18.0-win-x64;" + $env:Path
            } elseif ($dep -eq "pnpm") { cmd /c "npm.cmd install -g pnpm"; $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User") }
            if (-not (Get-Command $dep -ErrorAction SilentlyContinue)) { throw "Falha $dep" }
        }
    }
}
function Ensure-VencordPlugin {
    try { Ensure-Deps } catch { Write-Host "[AVISO] $_" -ForegroundColor Yellow; return }
    $VENCORD_DIR = "$env:USERPROFILE\Vencord"; $PLUGIN_SRC = "$INSTALL_DIR\plugin\StreamRelay.tsx"; $USERPLUGIN = "$VENCORD_DIR\src\userplugins\StreamRelay.tsx"
    if (Test-Path $USERPLUGIN) { Write-Host "[OK] Plugin ja instalado" -ForegroundColor Green; return }
    Write-Host "Instalando Vencord+plugin..." -ForegroundColor Yellow
    $gitExe = (Get-Command git -ErrorAction SilentlyContinue).Source; if (-not $gitExe) { $gitExe = "$INSTALL_DIR\tools\git\cmd\git.exe" }
    if (-not (Test-Path "$VENCORD_DIR\.git")) { & $gitExe clone https://github.com/Vendicated/Vencord.git $VENCORD_DIR }
    New-Item -ItemType Directory -Force -Path "$VENCORD_DIR\src\userplugins" | Out-Null; Copy-Item $PLUGIN_SRC $USERPLUGIN -Force
    Push-Location $VENCORD_DIR; cmd /c "pnpm.cmd install"; cmd /c "pnpm.cmd build"; Pop-Location
    Start-Process -FilePath "pnpm" -ArgumentList "inject" -Verb RunAs -Wait
    Write-Host "[OK] Plugin instalado! Reinicie Discord" -ForegroundColor Green
}

# --- Main ---
Write-Host "Onion: ${script:Onion}:${script:Port}" -ForegroundColor Green
Update-Helper
try { Ensure-VencordPlugin } catch { Write-Host "[AVISO] Plugin: $_" -ForegroundColor Yellow }
try {
    if (-not (Test-Tor)) { Install-Tor }
    Start-Tor; Start-Server; $bridgeProc = Start-Bridge
    Write-Host "`nIniciando captura... Ctrl+C para parar`n" -ForegroundColor Green
    Push-Location "$INSTALL_DIR\client"; node capture-helper.js; Pop-Location
} catch {
    Write-Host "ERRO: $_" -ForegroundColor Red
    Write-Host "Pressione qualquer tecla..." -ForegroundColor Yellow; $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown"); exit 1
} finally {
    if ($bridgeProc) { Stop-Process -Id $bridgeProc.Id -Force -ErrorAction SilentlyContinue }
    Write-Host "Parado!" -ForegroundColor Green
    if ($Error.Count -gt 0) { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
}
