#!/usr/bin/env bash

# Usage:
#   ./add_yubikey.sh [USERNAME] YUBIKEY_OTP_OR_ID
#
# USERNAME is optional — defaults to current user ($USER).
# The YubiKey input can be a full OTP or the 12-char public ID.
# It will always be trimmed to the first 12 characters (public ID).
# If the entry already exists, it won't be added again.

set -e

# Parse username & yubikey input
if [ -n "$1" ] && [[ "$1" != "" ]]; then
    USERNAME="$1"
    YUBIINPUT="$2"
else
    USERNAME="$USER"
    YUBIINPUT="$1"
fi

# Ask for key input if missing
if [ -z "$YUBIINPUT" ]; then
    read -rp "Enter YubiKey OTP or Public ID: " YUBIINPUT
fi

# Trim to 12 chars (Public ID)
PUBID="${YUBIINPUT:0:12}"

# Basic validation
if [[ -z "$USERNAME" || -z "$PUBID" ]]; then
    echo "Error: username and public ID are required."
    exit 1
fi

ENTRY="${USERNAME}:${PUBID}"
DIR="/etc/yubico"
FILE="$DIR/authorized_yubikeys"

# Create dir if needed
if [ ! -d "$DIR" ]; then
    echo "Directory $DIR not found — creating it..."
    sudo mkdir -p "$DIR"
    sudo chmod 755 "$DIR"
fi

# Create file if needed
if [ ! -f "$FILE" ]; then
    sudo touch "$FILE"
    sudo chmod 644 "$FILE"
fi

echo "Generated entry: $ENTRY"

# Check for duplicate
if sudo grep -qxF "$ENTRY" "$FILE"; then
    echo "ℹ Entry already exists in $FILE — not adding again."
    exit 0
fi

# Append to file
sudo sh -c "echo '$ENTRY' >> '$FILE'"

echo "✔ Entry added to $FILE"
