#!/bin/bash
# StreamRelay — Script unico: instala Vencord, atualiza, cria comando e inicia tudo
# Uso: curl -sL https://raw.githubusercontent.com/victorbillyph/streamandre/main/streamrelay-start.sh | bash
# ou:  streamrelay-start

set -u
ONION="${1:-m5u54wss3pxhi6tqvwv3i3l2m35wv3foitg6kkxln5fmef5blw6ybtad.onion}"
PORT="${2:-8080}"
BRIDGE="${3:-6789}"

INSTALL_DIR="$HOME/.local/share/streamrelay"
TOR_DIR="$INSTALL_DIR/tor"
TOR_BIN="$TOR_DIR/tor"
TOR_DATA="$INSTALL_DIR/tor-data"
TOR_SOCKS="9050"
REPO_URL="https://github.com/victorbillyph/streamandre.git"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo -e "${GREEN}=== StreamRelay Helper ===${NC}"

# --- PATH e symlink ---
mkdir -p "$HOME/.local/bin" 2>/dev/null
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then export PATH="$HOME/.local/bin:$PATH"; fi
SCRIPT_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
if [ -f "$SCRIPT_PATH" ] && [ "$(realpath "$HOME/.local/bin/streamrelay-start" 2>/dev/null)" != "$SCRIPT_PATH" ]; then
    ln -sf "$SCRIPT_PATH" "$HOME/.local/bin/streamrelay-start" 2>/dev/null
    chmod +x "$HOME/.local/bin/streamrelay-start" 2>/dev/null
fi

# --- Ensure install (clone se nao existe) ---
ensure_install() {
    if [ ! -d "$INSTALL_DIR/.git" ]; then
        echo -e "${YELLOW}Instalacao nao encontrada, clonando...${NC}"
        TMP=$(mktemp -d /tmp/streamrelay-XXXXXX)
        if ! git clone --depth 1 "$REPO_URL" "$TMP" 2>/dev/null; then
            echo -e "${RED}Falha ao clonar, tentando com gh...${NC}"
            gh repo clone victorbillyph/streamandre "$TMP" 2>/dev/null || { echo -e "${RED}Sem git, instale git${NC}"; return 1; }
        fi
        mkdir -p "$INSTALL_DIR"
        cp -r "$TMP"/* "$INSTALL_DIR"/ 2>/dev/null; cp -r "$TMP"/.* "$INSTALL_DIR"/ 2>/dev/null || true
        rm -rf "$TMP"
        (cd "$INSTALL_DIR/client" && npm install --silent 2>/dev/null || npm install)
    fi
}
ensure_install || echo -e "${YELLOW}[AVISO] Falha ensure_install, continuando...${NC}"

check_system_tor() { command -v tor &>/dev/null && TOR_BIN="tor" && return 0; return 1; }
download_tor() {
    echo -e "${YELLOW}Tor nao encontrado. Baixando...${NC}"
    mkdir -p "$TOR_DIR"
    ARCH=$(uname -m); case "$ARCH" in x86_64|amd64) A="linux-x86_64" ;; aarch64|arm64) A="linux-aarch64" ;; *) echo -e "${RED}Arch $ARCH nao suportado${NC}"; return 1 ;; esac
    URL="https://github.com/nickvdp/tor-binary/releases/latest/download/tor-${A}"
    curl -sL "$URL" -o "$TOR_BIN" || wget -q "$URL" -O "$TOR_BIN" || return 1
    chmod +x "$TOR_BIN"; echo -e "${GREEN}Tor baixado!${NC}"
}
repair_tor() {
    echo -e "${YELLOW}Reparando Tor...${NC}"
    pkill -f "tor -f $TOR_DATA/torrc" 2>/dev/null; sleep 1
    rm -f "$TOR_DATA"/lock 2>/dev/null
    return 0
}
start_tor() {
    if ss -tlnp 2>/dev/null | grep -q ":${TOR_SOCKS}"; then echo -e "${GREEN}[OK] Tor :${TOR_SOCKS}${NC}"; return 0; fi
    echo -e "${YELLOW}Iniciando Tor...${NC}"
    mkdir -p "$TOR_DATA"; chmod 700 "$TOR_DATA"
    [ ! -f "$TOR_DATA/torrc" ] && echo -e "SocksPort $TOR_SOCKS\nDataDirectory $TOR_DATA\nLog notice file $TOR_DATA/tor.log" > "$TOR_DATA/torrc"
    "$TOR_BIN" -f "$TOR_DATA/torrc" &>/dev/null &
    for i in $(seq 1 30); do ss -tlnp 2>/dev/null | grep -q ":${TOR_SOCKS}" && echo -e "${GREEN}[OK] Tor conectado!${NC}" && return 0; sleep 1; echo -n "."; done; echo ""
    echo -e "${RED}[ERRO] Tor falhou, tentando reparar...${NC}"; repair_tor; "$TOR_BIN" -f "$TOR_DATA/torrc" &>/dev/null & sleep 5; ss -tlnp 2>/dev/null | grep -q ":${TOR_SOCKS}" && echo -e "${GREEN}[OK] Tor reparado!${NC}" && return 0; echo -e "${RED}Falha Tor${NC}"; return 1
}
repair_relay() {
    echo -e "${YELLOW}Reparando relay...${NC}"
    pkill -f "relayServer.mjs" 2>/dev/null; sleep 1
    fuser -k 8080/tcp 2>/dev/null; sleep 1
    (cd "$INSTALL_DIR/client" && npm install --silent 2>/dev/null)
    return 0
}
start_server() {
    if pgrep -f "relayServer.mjs" &>/dev/null; then echo -e "${GREEN}[OK] Relay ja rodando${NC}"; return 0; fi
    echo -e "${YELLOW}Iniciando relay...${NC}"
    if [ ! -f "$INSTALL_DIR/server/relayServer.mjs" ]; then echo -e "${RED}Falta relayServer.mjs, reinstalando...${NC}"; ensure_install; fi
    cd "$INSTALL_DIR/server"; TOR_DATA_DIR="$TOR_DATA" nohup node relayServer.mjs &>/dev/null & sleep 2
    pgrep -f "relayServer.mjs" &>/dev/null && echo -e "${GREEN}[OK] Relay iniciado${NC}" && return 0
    echo -e "${YELLOW}[AVISO] Falha relay, reparando...${NC}"; repair_relay; cd "$INSTALL_DIR/server"; TOR_DATA_DIR="$TOR_DATA" nohup node relayServer.mjs &>/dev/null & sleep 2; pgrep -f "relayServer.mjs" &>/dev/null && echo -e "${GREEN}[OK] Relay reparado${NC}" && return 0; echo -e "${RED}Falha relay${NC}"; return 1
}
start_bridge() {
    echo -e "${YELLOW}Iniciando bridge (viewers)...${NC}"
    cd "$INSTALL_DIR/client"; node bridge.mjs "$ONION" "$PORT" & BRIDGE_PID=$!; sleep 2
    if kill -0 $BRIDGE_PID 2>/dev/null; then echo -e "${GREEN}[OK] Bridge 127.0.0.1:6789 -> $ONION:$PORT${NC}"; return 0; else echo -e "${YELLOW}[AVISO] Bridge falhou, host continua direto${NC}"; return 0; fi
}
cleanup() { echo ""; echo -e "${YELLOW}Parando...${NC}"; [ -n "${BRIDGE_PID:-}" ] && kill $BRIDGE_PID 2>/dev/null; echo -e "${GREEN}Parado!${NC}"; }
trap cleanup EXIT INT TERM

auto_update() {
    if [ -d "$INSTALL_DIR/.git" ]; then
        echo -e "${YELLOW}Verificando atualizacoes...${NC}"
        (cd "$INSTALL_DIR" && git fetch --quiet && L=$(git rev-parse HEAD) && R=$(git rev-parse @{u} 2>/dev/null || echo $L) && if [ "$L" != "$R" ]; then echo -e "${YELLOW}Atualizando...${NC}"; git pull --ff-only --quiet && echo -e "${GREEN}Atualizado!${NC}"; (cd client && npm install --silent); return 0; else echo -e "${GREEN}[OK] Ultima versao${NC}"; return 1; fi)
        UPD=$?
        if [ $UPD -eq 0 ]; then
            if [ -f "$INSTALL_DIR/plugin/StreamRelay.tsx" ] && [ -f "$HOME/Vencord/src/userplugins/StreamRelay.tsx" ]; then
                if ! diff -q "$INSTALL_DIR/plugin/StreamRelay.tsx" "$HOME/Vencord/src/userplugins/StreamRelay.tsx" >/dev/null 2>&1; then
                    echo -e "${YELLOW}Plugin mudou, recompilando...${NC}"
                    cp "$INSTALL_DIR/plugin/StreamRelay.tsx" "$HOME/Vencord/src/userplugins/StreamRelay.tsx"
                    (cd "$HOME/Vencord" && npx pnpm build >/dev/null 2>&1 && sudo npx pnpm inject >/dev/null 2>&1) && echo -e "${GREEN}[OK] Plugin atualizado${NC}" || echo -e "${YELLOW}Falha recompilar, tente manual: cd ~/Vencord && sudo pnpm inject${NC}"
                fi
            fi
            cp "$INSTALL_DIR/streamrelay-start.sh" "$HOME/.local/bin/streamrelay-start" 2>/dev/null; chmod +x "$HOME/.local/bin/streamrelay-start" 2>/dev/null
        fi
    fi
}
ensure_vencord_plugin() {
    local SRC="$INSTALL_DIR/plugin/StreamRelay.tsx" VDIR="$HOME/Vencord" DST="$VDIR/src/userplugins/StreamRelay.tsx"
    if [ -f "$DST" ]; then echo -e "${GREEN}[OK] Plugin ja instalado${NC}"; return 0; fi
    echo -e "${YELLOW}Instalando Vencord + plugin...${NC}"
    if [ ! -d "$VDIR/.git" ]; then git clone https://github.com/Vendicated/Vencord.git "$VDIR" || { echo -e "${RED}Falha clonar Vencord${NC}"; return 1; }; fi
    mkdir -p "$VDIR/src/userplugins"; cp "$SRC" "$DST" || { echo -e "${RED}Falta $SRC, reinstalando...${NC}"; ensure_install; cp "$SRC" "$DST"; }
    echo -e "${YELLOW}Compilando...${NC}"
    if ! (cd "$VDIR" && npx pnpm install 2>&1 | tail -5 && npx pnpm build 2>&1 | tail -5); then echo -e "${YELLOW}Tentando reparar pnpm...${NC}"; npm install -g pnpm 2>/dev/null; sudo npm install -g pnpm 2>/dev/null; (cd "$VDIR" && npx pnpm install && npx pnpm build) || return 1; fi
    echo -e "${YELLOW}Patchando Discord (sudo)...${NC}"
    (cd "$VDIR" && sudo npx pnpm inject) || echo -e "${YELLOW}[AVISO] sudo pnpm inject falhou, rode manual: cd ~/Vencord && sudo pnpm inject${NC}"
    echo -e "${GREEN}[OK] Plugin instalado! Reinicie Discord${NC}"
}

# --- Main ---
echo -e "${GREEN}Onion: $ONION:$PORT${NC}\n"
auto_update
ensure_vencord_plugin || echo -e "${YELLOW}[AVISO] Sem plugin, viewer precisa instalar manual${NC}"
if ! check_system_tor; then [ -x "$TOR_BIN" ] && echo -e "${GREEN}[OK] Tor $TOR_BIN${NC}" || download_tor || { echo -e "${RED}Sem Tor, tentando continuar...${NC}"; }; fi
start_tor || { repair_tor; start_tor || exit 1; }
start_server || { repair_relay; start_server || exit 1; }
start_bridge || true
echo -e "\n${GREEN}Iniciando captura...${NC}\n${YELLOW}Ctrl+C para parar${NC}\n"
cd "$INSTALL_DIR/client"
# tenta grim, fallback ffmpeg
if ! command -v grim &>/dev/null && ! command -v ffmpeg &>/dev/null; then echo -e "${RED}Instale grim ou ffmpeg${NC}"; fi
node capture-helper.js || { echo -e "${RED}Capture falhou, tentando reparar...${NC}"; sleep 2; node capture-helper.js; }
