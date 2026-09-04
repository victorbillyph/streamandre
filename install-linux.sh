#!/bin/bash

set -e

PLUGIN_NAME="StreamRelay"
REPO_URL="https://raw.githubusercontent.com/victorbillyph/streamandre/main/StreamRelay.tsx"

echo "=== StreamRelay Installer for Linux ==="
echo ""

# Check sudo
if [ "$EUID" -ne 0 ]; then
    echo "Requesting sudo..."
    sudo -v || { echo "Sudo required. Exiting."; exit 1; }
fi

# Detect Vencord path
VENCORD_DIR=""
for dir in \
    "$HOME/.config/Vencord" \
    "$HOME/.local/share/Vencord" \
    "$HOME/.var/app/com.discordapp.Discord/config/Vencord" \
    "$HOME/.config/discord/Vencord"; do
    if [ -d "$dir" ]; then
        VENCORD_DIR="$dir"
        break
    fi
done

if [ -z "$VENCORD_DIR" ]; then
    echo "Vencord not found. Installing to default path..."
    VENCORD_DIR="$HOME/.config/Vencord"
fi

PLUGINS_DIR="$VENCORD_DIR/plugins"
mkdir -p "$PLUGINS_DIR"

echo "Downloading plugin..."
curl -sL "$REPO_URL" -o "$PLUGINS_DIR/$PLUGIN_NAME.jsx" || wget -q "$REPO_URL" -O "$PLUGINS_DIR/$PLUGIN_NAME.jsx"

if [ ! -f "$PLUGINS_DIR/$PLUGIN_NAME.jsx" ]; then
    echo "Failed to download plugin. Exiting."
    exit 1
fi

echo "Plugin installed to: $PLUGINS_DIR/$PLUGIN_NAME.jsx"
echo ""
echo "=== Restart Discord to apply ==="
echo "Enable the plugin in Vencord Settings > Plugins"
