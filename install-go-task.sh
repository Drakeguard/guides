!/usr/bin/env bash
#
# install-go-task.sh — Installs the latest Go-Task binary
# https://taskfile.dev
#
# Usage:
#   chmod +x install-go-task.sh
#   ./install-go-task.sh
#
# Optional env vars:
#   VERSION=v3.39.2   # install a specific version
#   INSTALL_DIR=/usr/local/bin

set -euo pipefail

VERSION="${VERSION:-latest}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

# Detect system architecture
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l) ARCH="armv7" ;;
    armv6l) ARCH="armv6" ;;
esac

# Ensure dependencies
if ! command -v curl >/dev/null 2>&1; then
    echo "Installing curl..."
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y curl
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y curl
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y curl
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm curl
    else
        echo "Error: please install curl manually." >&2
        exit 1
    fi
fi

# Get latest version if not provided
if [ "$VERSION" = "latest" ]; then
    echo "Fetching latest Go-Task version..."
    VERSION="$(curl -sL https://api.github.com/repos/go-task/task/releases/latest | jq .tag_name)"
    echo "Latest version: $VERSION"
fi

# Download and install
TMP_DIR="$(mktemp -d)"
TAR_FILE="task_${OS}_${ARCH}.tar.gz"
URL="https://github.com/go-task/task/releases/download/${VERSION}/${TAR_FILE}"

echo "Downloading ${URL} ..."
curl -sSL "$URL" -o "$TMP_DIR/$TAR_FILE"

echo "Extracting..."
tar -xzf "$TMP_DIR/$TAR_FILE" -C "$TMP_DIR"

echo "Installing to ${INSTALL_DIR} ..."
sudo install -m 755 "$TMP_DIR/task" "$INSTALL_DIR/task"

echo "Cleaning up..."
rm -rf "$TMP_DIR"

echo "✅ Go-Task installed successfully!"
echo "Version: $($INSTALL_DIR/task --version)"
