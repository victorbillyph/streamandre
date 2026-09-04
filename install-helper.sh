#!/bin/bash
# StreamRelay Helper Installer
# Instala as dependencias e configura o helper de captura de tela

set -e

INSTALL_DIR="$HOME/.local/share/streamrelay"
REPO_URL="https://github.com/victorbillyph/streamandre.git"

echo "=== StreamRelay Helper Installer ==="
echo ""

# Check dependencies
echo "Verificando dependencias..."

check_cmd() {
    if command -v "$1" &>/dev/null; then
        echo "  [OK] $1"
        return 0
    else
        echo "  [FALTA] $1"
        return 1
    fi
}

MISSING=0
check_cmd git || MISSING=1
check_cmd node || MISSING=1
check_cmd npm || MISSING=1
check_cmd grim || MISSING=1
check_cmd slurp || MISSING=1

if [ $MISSING -eq 1 ]; then
    echo ""
    echo "Instalando dependencias faltantes..."
    
    if command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm git nodejs npm grim slurp
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y git nodejs npm grim slurp
    elif command -v apt &>/dev/null; then
        sudo apt update && sudo apt install -y git nodejs npm grim slurp
    else
        echo "Gerenciador de pacotes nao encontrado. Instale manualmente:"
        echo "  - git, node, npm, grim, slurp"
        exit 1
    fi
fi

echo ""
echo "Clonando repositorio..."
mkdir -p "$INSTALL_DIR"
if [ -d "$INSTALL_DIR/.git" ]; then
    cd "$INSTALL_DIR"
    git pull
else
    git clone "$REPO_URL" "$INSTALL_DIR"
fi

echo ""
echo "Instalando dependencias Node.js..."
cd "$INSTALL_DIR/client"
npm install

echo ""
echo "Criando script de inicializacao..."
cat > "$HOME/.local/bin/streamrelay-start" << 'STARTEOF'
#!/bin/bash
# StreamRelay - Inicia TUDO automaticamente (Tor, servidor, bridge, captura)

ONION="${1:-m5u54wss3pxhi6tqvwv3i3l2m35wv3foitg6kkxln5fmef5blw6ybtad.onion}"
PORT="${2:-8080}"
BRIDGE="${3:-6789}"

INSTALL_DIR="$HOME/.local/share/streamrelay"
TOR_DIR="$INSTALL_DIR/tor"
TOR_BIN="$TOR_DIR/tor"
TOR_DATA="$INSTALL_DIR/tor-data"
TOR_SOCKS="9050"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== StreamRelay Helper ===${NC}"
echo ""

# Download Tor if not installed
if ! command -v tor &>/dev/null && [ ! -x "$TOR_BIN" ]; then
    echo -e "${YELLOW}Tor nao encontrado. Baixando...${NC}"
    mkdir -p "$TOR_DIR"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) ARCH_NAME="linux-x86_64" ;;
        aarch64|arm64) ARCH_NAME="linux-aarch64" ;;
        *) echo -e "${RED}Arquitetura nao suportada: $ARCH${NC}"; exit 1 ;;
    esac
    TOR_URL="https://github.com/nickvdp/tor-binary/releases/latest/download/tor-${ARCH_NAME}"
    curl -sL "$TOR_URL" -o "$TOR_BIN" || wget -q "$TOR_URL" -O "$TOR_BIN"
    chmod +x "$TOR_BIN"
    echo -e "${GREEN}Tor baixado!${NC}"
fi

# Set tor binary
if command -v tor &>/dev/null; then
    TOR_BIN="tor"
fi

# Start Tor
if ! ss -tlnp 2>/dev/null | grep -q ":${TOR_SOCKS}"; then
    echo -e "${YELLOW}Iniciando Tor...${NC}"
    mkdir -p "$TOR_DATA"
    chmod 700 "$TOR_DATA"
    [ ! -f "$TOR_DATA/torrc" ] && echo -e "SocksPort $TOR_SOCKS\nDataDirectory $TOR_DATA\nLog notice file $TOR_DATA/tor.log" > "$TOR_DATA/torrc"
    "$TOR_BIN" -f "$TOR_DATA/torrc" &>/dev/null &
    for i in $(seq 1 30); do
        ss -tlnp 2>/dev/null | grep -q ":${TOR_SOCKS}" && break
        sleep 1
        echo -n "."
    done
    echo ""
    ss -tlnp 2>/dev/null | grep -q ":${TOR_SOCKS}" && echo -e "${GREEN}[OK] Tor conectado!${NC}" || { echo -e "${RED}[ERRO] Tor falhou${NC}"; exit 1; }
else
    echo -e "${GREEN}[OK] Tor ja rodando${NC}"
fi

# Start server
if ! pgrep -f "relayServer.mjs" &>/dev/null; then
    echo -e "${YELLOW}Iniciando servidor relay...${NC}"
    cd "$INSTALL_DIR/server"
    TOR_DATA_DIR="$TOR_DATA" nohup node relayServer.mjs &>/dev/null &
    sleep 2
    echo -e "${GREEN}[OK] Servidor relay iniciado${NC}"
else
    echo -e "${GREEN}[OK] Servidor relay ja rodando${NC}"
fi

# Start bridge
echo -e "${YELLOW}Iniciando bridge Tor...${NC}"
cd "$INSTALL_DIR/client"
node bridge.mjs "$ONION" "$PORT" &
BRIDGE_PID=$!
sleep 2
echo -e "${GREEN}[OK] Bridge conectado${NC}"

# Cleanup
cleanup() { echo ""; echo -e "${YELLOW}Parando...${NC}"; kill $BRIDGE_PID 2>/dev/null; echo -e "${GREEN}Parado!${NC}"; }
trap cleanup EXIT INT TERM

# Start capture
echo ""
echo -e "${GREEN}Iniciando captura de tela...${NC}"
echo -e "${YELLOW}Pressione Ctrl+C para parar${NC}"
echo ""
node capture-helper.js
STARTEOF

chmod +x "$HOME/.local/bin/streamrelay-start"

# Link network helper
mkdir -p "$HOME/.local/bin"
cp "$INSTALL_DIR/streamrelay-network.sh" "$HOME/.local/bin/streamrelay-network" 2>/dev/null || cp "$INSTALL_DIR/client/network-helper.js" "$HOME/.local/bin/" 2>/dev/null
chmod +x "$HOME/.local/bin/streamrelay-network" 2>/dev/null

echo ""
echo "=== Instalacao concluida! ==="
echo ""
echo "Para usar (modo centralizado):"
echo "  streamrelay-start"
echo ""
echo "Para modo descentralizado (cada um com seu onion):"
echo "  streamrelay-network host              # iniciar transmissao"
echo "  streamrelay-network view <onion>      # assistir"
echo "  streamrelay-network addpeer <onion>   # adicionar amigo"
echo "  streamrelay-network listpeers         # listar amigos"
echo ""
echo "Ou manualmente:"
echo "  cd $INSTALL_DIR/client"
echo "  node bridge.mjs <onion> <porta>"
echo "  node capture-helper.js"
echo "  node network-helper.js host|view|addpeer|listpeers"
