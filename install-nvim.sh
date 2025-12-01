#!/usr/bin/env bash

set -euo pipefail

# Detect architecture
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)
        NVIM_FILE="nvim-linux-x86_64.tar.gz"
        ;;
    aarch64|arm64)
        NVIM_FILE="nvim-linux-arm64.tar.gz"
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        echo "Supported: x86_64, aarch64/arm64"
        exit 1
        ;;
esac

NVIM_URL="https://github.com/neovim/neovim/releases/latest/download/${NVIM_FILE}"
TEMP_DIR="$(mktemp -d)"
ARCHIVE="${TEMP_DIR}/${NVIM_FILE}"

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "Downloading Neovim package..."
curl -sSL "$NVIM_URL" -o "$ARCHIVE"

echo "Listing archive contents:"

if [ -t 1 ]; then
    # We have a real terminal
    # Disable -e just for this pipeline so a non-zero from less doesn't kill the script
    set +e
    tar -tzf "$ARCHIVE" | less
    PIPE_STATUS=$?
    set -e
    if [ $PIPE_STATUS -ne 0 ]; then
        echo "Warning: tar|less returned $PIPE_STATUS, continuing anyway..."
    fi
else
    # Non-interactive; just dump
    tar -tzf "$ARCHIVE"
fi
echo
if ! read -r -p "Proceed to extract Neovim into /usr (requires sudo)? [yes/no]: " response; then
    echo "No input available; cancelling."
    exit 1
fi

if [[ "$response" =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Extracting to /usr..."
    sudo tar -xzf "$ARCHIVE" --strip-components=1 --overwrite -C /usr
    echo "✓ Installation complete."
    echo
    if command -v nvim >/dev/null 2>&1; then
        echo "nvim version:"
        nvim --version | head -5
    else
        echo "Note: 'nvim' not found in PATH; ensure /usr/bin is in your PATH."
    fi
else
    echo "Installation cancelled."
fi
