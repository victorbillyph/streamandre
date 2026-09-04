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
cat > "$HOME/.local/bin/streamrelay-start" << 'EOF'
#!/bin/bash
# StreamRelay - Inicia helper de captura de tela

ONION="${1:-m5u54wss3pxhi6tqvwv3i3l2m35wv3foitg6kkxln5fmef5blw6ybtad.onion}"
PORT="${2:-8080}"
BRIDGE="${3:-6789}"

echo "Iniciando StreamRelay Helper..."
echo "Onion: $ONION:$PORT"
echo ""

# Start bridge in background
cd "$HOME/.local/share/streamrelay/client"
echo "Iniciando bridge Tor..."
node bridge.mjs "$ONION" "$PORT" &
BRIDGE_PID=$!
sleep 2

# Start capture
echo "Iniciando captura de tela..."
echo "Pressione Ctrl+C para parar"
node capture-helper.js

# Cleanup
kill $BRIDGE_PID 2>/dev/null
EOF

chmod +x "$HOME/.local/bin/streamrelay-start"

echo ""
echo "=== Instalacao concluida! ==="
echo ""
echo "Para usar:"
echo "  streamrelay-start"
echo ""
echo "Ou manualmente:"
echo "  cd $INSTALL_DIR/client"
echo "  node bridge.mjs <onion> <porta>"
echo "  node capture-helper.js"
