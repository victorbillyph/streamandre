#!/bin/bash
# StreamRelay Screen Capture Helper
# Captura a tela usando grim/slurp e envia frames via WebSocket ao relay server

set -e

ONION_ADDR="${1:-m5u54wss3pxhi6tqvwv3i3l2m35wv3foitg6kkxln5fmef5blw6ybtad.onion}"
ONION_PORT="${2:-8080}"
FPS="${3:-15}"
BRIDGE_PORT="${4:-6789}"

echo "[StreamRelay Helper] Iniciando captura de tela..."
echo "[StreamRelay Helper] Onion: $ONION_ADDR:$ONION_PORT"
echo "[StreamRelay Helper] FPS: $FPS"

# Capture geometry using slurp
echo "[StreamRelay Helper] Selecione a area para capturar..."
GEOMETRY=$(slurp 2>/dev/null)

if [ -z "$GEOMETRY" ]; then
    # If slurp cancelled, capture full screen
    RESOLUTION=$(grim -g "$(swaymsg -t get_outputs 2>/dev/null | jq -r '.[0].rect | "\(.x),\(.y) \(.width)x\(.height)"' 2>/dev/null || echo "0,0 1920x1080)" - 2>/dev/null)
    GEOMETRY=""
    echo "[StreamRelay Helper] Capturando tela inteira"
else
    echo "[StreamRelay Helper] Area selecionada: $GEOMETRY"
fi

# Function to capture a single frame
capture_frame() {
    if [ -n "$GEOMETRY" ]; then
        grim -g "$GEOMETRY" -t webp -q 60 /tmp/sr_frame.webp 2>/dev/null
    else
        grim -t webp -q 60 /tmp/sr_frame.webp 2>/dev/null
    fi
}

# Function to send frame via the relay
send_frame() {
    if [ -f /tmp/sr_frame.webp ]; then
        # Use node to send the frame via WebSocket
        node -e "
const fs = require('fs');
const WebSocket = require('ws');
const ws = new WebSocket('ws://127.0.0.1:${BRIDGE_PORT}');

ws.on('open', () => {
    const frame = fs.readFileSync('/tmp/sr_frame.webp');
    const header = Buffer.alloc(13);
    header.write('SRF1', 0);
    header.writeUInt8(4, 4); // webp
    // Get dimensions from webp header if possible, otherwise use defaults
    header.writeUInt16LE(1920, 5);
    header.writeUInt16LE(1080, 7);
    header.writeUInt32LE(Date.now(), 9);
    
    const packet = Buffer.concat([header, frame]);
    ws.send(packet);
    ws.close();
    process.exit(0);
});

ws.on('error', (e) => {
    console.error('WS error:', e.message);
    process.exit(1);
});

setTimeout(() => { ws.close(); process.exit(1); }, 5000);
" 2>/dev/null
    fi
}

echo "[StreamRelay Helper] Capturando a cada $((1000/FPS))ms... Pressione Ctrl+C para parar."

# Main loop
while true; do
    capture_frame
    send_frame
    sleep "$(echo "scale=3; 1/$FPS" | bc)"
done
