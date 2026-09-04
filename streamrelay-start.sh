#!/bin/bash
# StreamRelay - Inicia helper de captura de tela com Tor automatico

ONION="${1:-m5u54wss3pxhi6tqvwv3i3l2m35wv3foitg6kkxln5fmef5blw6ybtad.onion}"
PORT="${2:-8080}"
BRIDGE="${3:-6789}"

INSTALL_DIR="$HOME/.local/share/streamrelay"
TOR_DIR="$INSTALL_DIR/tor"
TOR_BIN="$TOR_DIR/tor"
TOR_DATA="$INSTALL_DIR/tor-data"
TOR_SOCKS="9050"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== StreamRelay Helper ===${NC}"
echo ""

# Check if Tor is installed system-wide
check_system_tor() {
    if command -v tor &>/dev/null; then
        TOR_BIN="tor"
        return 0
    fi
    return 1
}

# Download Tor if not installed
download_tor() {
    echo -e "${YELLOW}Tor nao encontrado. Baixando...${NC}"
    mkdir -p "$TOR_DIR"
    
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) ARCH_NAME="linux-x86_64" ;;
        aarch64|arm64) ARCH_NAME="linux-aarch64" ;;
        *) echo -e "${RED}Arquitetura nao suportada: $ARCH${NC}"; exit 1 ;;
    esac
    
    TOR_URL="https://github.com/nickvdp/tor-binary/releases/latest/download/tor-${ARCH_NAME}"
    
    echo -e "${YELLOW}Baixando Tor para $ARCH...${NC}"
    curl -sL "$TOR_URL" -o "$TOR_BIN" || wget -q "$TOR_URL" -O "$TOR_BIN"
    chmod +x "$TOR_BIN"
    
    echo -e "${GREEN}Tor baixado!${NC}"
}

# Start Tor
start_tor() {
    # Check if Tor is already running
    if ss -tlnp 2>/dev/null | grep -q ":${TOR_SOCKS}"; then
        echo -e "${GREEN}[OK] Tor ja rodando na porta ${TOR_SOCKS}${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Iniciando Tor...${NC}"
    mkdir -p "$TOR_DATA"
    chmod 700 "$TOR_DATA"
    
    # Create torrc if not exists
    if [ ! -f "$TOR_DATA/torrc" ]; then
        cat > "$TOR_DATA/torrc" << EOF
SocksPort $TOR_SOCKS
DataDirectory $TOR_DATA
Log notice file $TOR_DATA/tor.log
EOF
    fi
    
    # Start Tor
    "$TOR_BIN" -f "$TOR_DATA/torrc" &>/dev/null &
    TOR_PID=$!
    
    # Wait for Tor to start
    echo -e "${YELLOW}Aguardando Tor conectar...${NC}"
    for i in $(seq 1 30); do
        if ss -tlnp 2>/dev/null | grep -q ":${TOR_SOCKS}"; then
            echo -e "${GREEN}[OK] Tor conectado!${NC}"
            return 0
        fi
        sleep 1
        echo -n "."
    done
    
    echo ""
    echo -e "${RED}[ERRO] Tor nao conectou em 30 segundos${NC}"
    return 1
}

# Start relay server
start_server() {
    if pgrep -f "relayServer.mjs" &>/dev/null; then
        echo -e "${GREEN}[OK] Servidor relay ja rodando${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Iniciando servidor relay...${NC}"
    cd "$INSTALL_DIR/server"
    TOR_DATA_DIR="$TOR_DATA" nohup node relayServer.mjs &>/dev/null &
    sleep 2
    
    if pgrep -f "relayServer.mjs" &>/dev/null; then
        echo -e "${GREEN}[OK] Servidor relay iniciado${NC}"
        return 0
    else
        echo -e "${RED}[ERRO] Falha ao iniciar servidor${NC}"
        return 1
    fi
}

# Start bridge (para viewers se conectarem via Tor; host usa relay direto)
start_bridge() {
    echo -e "${YELLOW}Iniciando bridge Tor (para viewers)...${NC}"
    cd "$INSTALL_DIR/client"
    node bridge.mjs "$ONION" "$PORT" &
    BRIDGE_PID=$!
    sleep 2
    if kill -0 $BRIDGE_PID 2>/dev/null; then
        echo -e "${GREEN}[OK] Bridge pronto em 127.0.0.1:6789 -> $ONION:$PORT${NC}"
        return 0
    else
        echo -e "${YELLOW}[AVISO] Bridge falhou, mas host continua (captura direta no relay)${NC}"
        return 0
    fi
}

# Cleanup on exit
cleanup() {
    echo ""
    echo -e "${YELLOW}Parando StreamRelay...${NC}"
    [ -n "$BRIDGE_PID" ] && kill $BRIDGE_PID 2>/dev/null
    echo -e "${GREEN}Parado!${NC}"
}

trap cleanup EXIT INT TERM

auto_update() {
    if [ -d "$INSTALL_DIR/.git" ]; then
        echo -e "${YELLOW}Verificando atualizacoes...${NC}"
        (cd "$INSTALL_DIR" && git fetch --quiet && LOCAL=$(git rev-parse HEAD) && REMOTE=$(git rev-parse @{u} 2>/dev/null || echo $LOCAL) && if [ "$LOCAL" != "$REMOTE" ]; then echo -e "${YELLOW}Nova versao encontrada, atualizando...${NC}"; git pull --ff-only --quiet && echo -e "${GREEN}Atualizado!${NC}"; (cd "$INSTALL_DIR/client" && npm install --silent); return 0; else echo -e "${GREEN}[OK] Ja na ultima versao${NC}"; return 1; fi)
        UPDATED=$?
        if [ $UPDATED -eq 0 ]; then
            # reinstala plugin se mudou
            if [ -f "$INSTALL_DIR/plugin/StreamRelay.tsx" ] && [ -f "$HOME/Vencord/src/userplugins/StreamRelay.tsx" ]; then
                if ! diff -q "$INSTALL_DIR/plugin/StreamRelay.tsx" "$HOME/Vencord/src/userplugins/StreamRelay.tsx" >/dev/null 2>&1; then
                    echo -e "${YELLOW}Plugin atualizado, recompilando...${NC}"
                    cp "$INSTALL_DIR/plugin/StreamRelay.tsx" "$HOME/Vencord/src/userplugins/StreamRelay.tsx"
                    (cd "$HOME/Vencord" && npx pnpm build >/dev/null 2>&1 && sudo npx pnpm inject >/dev/null 2>&1) && echo -e "${GREEN}[OK] Plugin atualizado${NC}" || echo -e "${YELLOW}[AVISO] Falha ao recompilar plugin${NC}"
                fi
            fi
            cp "$INSTALL_DIR/streamrelay-start.sh" "$HOME/.local/bin/streamrelay-start" 2>/dev/null; chmod +x "$HOME/.local/bin/streamrelay-start" 2>/dev/null
        fi
    fi
}

ensure_vencord_plugin() {
    local PLUGIN_SRC="$INSTALL_DIR/plugin/StreamRelay.tsx"
    local VENCORD_DIR="$HOME/Vencord"
    local USERPLUGIN="$VENCORD_DIR/src/userplugins/StreamRelay.tsx"
    if [ -f "$USERPLUGIN" ]; then
        echo -e "${GREEN}[OK] Plugin Vencord ja instalado${NC}"
        return 0
    fi
    echo -e "${YELLOW}Plugin Vencord nao encontrado. Instalando...${NC}"
    if [ ! -d "$VENCORD_DIR/.git" ]; then
        echo -e "${YELLOW}Clonando Vencord...${NC}"
        git clone https://github.com/Vendicated/Vencord.git "$VENCORD_DIR" || { echo -e "${RED}Falha ao clonar Vencord${NC}"; return 1; }
    fi
    mkdir -p "$VENCORD_DIR/src/userplugins"
    cp "$PLUGIN_SRC" "$USERPLUGIN"
    echo -e "${YELLOW}Instalando dependencias e compilando...${NC}"
    (cd "$VENCORD_DIR" && npx pnpm install && npx pnpm build) || { echo -e "${RED}Falha ao compilar Vencord${NC}"; return 1; }
    echo -e "${YELLOW}Patchando Discord (precisa sudo)...${NC}"
    (cd "$VENCORD_DIR" && sudo npx pnpm inject) || echo -e "${YELLOW}[AVISO] Falha no inject, tente manualmente: cd ~/Vencord && sudo pnpm inject${NC}"
    echo -e "${GREEN}[OK] Plugin instalado! Reinicie o Discord${NC}"
}

# Main
echo -e "${GREEN}Onion: $ONION:$PORT${NC}"
echo ""
auto_update
ensure_vencord_plugin || echo -e "${YELLOW}[AVISO] Continue sem plugin (viewer precisa instalar manualmente)${NC}"

# Check/install Tor
if ! check_system_tor; then
    if [ -x "$TOR_BIN" ]; then
        echo -e "${GREEN}[OK] Tor encontrado em $TOR_BIN${NC}"
    else
        download_tor
    fi
fi

# Start Tor
start_tor || exit 1

# Start server
start_server || exit 1

# Start bridge
start_bridge || exit 1

# Start capture
echo ""
echo -e "${GREEN}Iniciando captura de tela...${NC}"
echo -e "${YELLOW}Pressione Ctrl+C para parar${NC}"
echo ""

cd "$INSTALL_DIR/client"
node capture-helper.js
