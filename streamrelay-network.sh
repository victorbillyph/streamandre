#!/bin/bash
# StreamRelay Network Helper - Start script

INSTALL_DIR="$HOME/.local/share/streamrelay"
MODE="${1:-host}"
ONION="${2}"
NAME="${3}"

echo -e "\033[0;32m=== StreamRelay Network Helper ===\033[0m"
echo ""

cd "$INSTALL_DIR/client"

case "$MODE" in
    host)
        echo -e "\033[0;33mIniciando como HOST (transmissor)...\033[0m"
        node network-helper.js host
        ;;
    view)
        if [ -z "$ONION" ]; then
            echo -e "\033[0;31mUso: streamrelay-network view <onion-do-streamer>\033[0m"
            exit 1
        fi
        echo -e "\033[0;33mIniciando como VIEWER (assistindo $ONION)...\033[0m"
        node network-helper.js view "$ONION"
        ;;
    addpeer)
        if [ -z "$ONION" ]; then
            echo -e "\033[0;31mUso: streamrelay-network addpeer <onion> [nome]\033[0m"
            exit 1
        fi
        echo -e "\033[0;33mAdicionando amigo $ONION ($NAME)...\033[0m"
        node network-helper.js addpeer "$ONION" "$NAME"
        ;;
    listpeers)
        echo -e "\033[0;33mListando amigos na rede...\033[0m"
        node network-helper.js listpeers
        ;;
    liststreams)
        echo -e "\033[0;33mBuscando transmissoes disponiveis...\033[0m"
        node network-helper.js liststreams
        ;;
    *)
        echo -e "\033[0;32m=== StreamRelay Network Helper ===\033[0m"
        echo ""
        echo "Uso:"
        echo "  streamrelay-network host                    # Iniciar transmissao"
        echo "  streamrelay-network view <onion>            # Assistir transmissao"
        echo "  streamrelay-network addpeer <onion> [nome]  # Adicionar amigo"
        echo "  streamrelay-network listpeers               # Listar amigos"
        echo "  streamrelay-network liststreams             # Buscar transmissoes"
        echo ""
        echo "Seu endereco onion sera gerado automaticamente"
        echo "Compartilhe com amigos para eles te assistirem!"
        ;;
esac