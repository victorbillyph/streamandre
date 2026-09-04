#!/bin/bash
set -e

PLUGIN_NAME="StreamRelay"
REPO_URL="https://raw.githubusercontent.com/victorbillyph/streamandre/main/plugin/StreamRelay.tsx"
VENCORD_REPO="https://github.com/Vendicated/Vencord.git"

echo "=== StreamRelay Installer for Linux ==="
echo ""

# Check sudo
if [ "$EUID" -ne 0 ]; then
    echo "Requesting sudo..."
    sudo -v || { echo "Sudo required. Exiting."; exit 1; }
fi

# Check dependencies
echo "Checking dependencies..."
for cmd in git node npm pnpm; do
    if ! command -v $cmd &> /dev/null; then
        echo "Installing $cmd..."
        if command -v apt &> /dev/null; then
            sudo apt update && sudo apt install -y $cmd
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y $cmd
        elif command -v pacman &> /dev/null; then
            sudo pacman -S --noconfirm $cmd
        fi
    fi
done

# Find or clone Vencord
VENCORD_DIR=""
for dir in \
    "$HOME/Vencord" \
    "$HOME/.local/share/Vencord" \
    "$HOME/Projects/Vencord" \
    "$HOME/Code/Vencord"; do
    if [ -d "$dir/src" ]; then
        VENCORD_DIR="$dir"
        break
    fi
done

if [ -z "$VENCORD_DIR" ]; then
    echo "Vencord source not found. Cloning..."
    VENCORD_DIR="$HOME/Vencord"
    git clone "$VENCORD_REPO" "$VENCORD_DIR"
fi

echo "Using Vencord at: $VENCORD_DIR"

# Create userplugins directory
USERPLUGINS_DIR="$VENCORD_DIR/src/userplugins"
mkdir -p "$USERPLUGINS_DIR"

# Download plugin
echo "Downloading plugin..."
curl -sL "$REPO_URL" -o "$USERPLUGINS_DIR/$PLUGIN_NAME.tsx" || \
    wget -q "$REPO_URL" -O "$USERPLUGINS_DIR/$PLUGIN_NAME.tsx"

if [ ! -f "$USERPLUGINS_DIR/$PLUGIN_NAME.tsx" ]; then
    echo "Failed to download plugin. Exiting."
    exit 1
fi

echo "Plugin installed to: $USERPLUGINS_DIR/$PLUGIN_NAME.tsx"

# Build Vencord
echo ""
echo "Building Vencord (this may take a few minutes)..."
cd "$VENCORD_DIR"
pnpm install
pnpm build

echo ""
echo "=== Build complete! ==="
echo "Restart Discord to apply changes."
echo "Enable the plugin in Vencord Settings > Plugins"
