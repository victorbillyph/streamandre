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

# Start bridge
start_bridge() {
    echo -e "${YELLOW}Iniciando bridge Tor...${NC}"
    cd "$INSTALL_DIR/client"
    node bridge.mjs "$ONION" "$PORT" &
    BRIDGE_PID=$!
    sleep 2
    
    if kill -0 $BRIDGE_PID 2>/dev/null; then
        echo -e "${GREEN}[OK] Bridge conectado${NC}"
        return 0
    else
        echo -e "${RED}[ERRO] Bridge falhou${NC}"
        return 1
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

# Main
echo -e "${GREEN}Onion: $ONION:$PORT${NC}"
echo ""

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
