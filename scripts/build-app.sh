#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR/macos"
swift build -c release
BINARY_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/InstagramPet.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BINARY_DIR/InstagramPet" "$APP_DIR/Contents/MacOS/InstagramPet"
cp "$PROJECT_DIR/macos/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$BINARY_DIR/PetNativeHost" "$PROJECT_DIR/dist/PetNativeHost"
chmod 755 "$APP_DIR/Contents/MacOS/InstagramPet" "$PROJECT_DIR/dist/PetNativeHost"
if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP_DIR"
    codesign --force --sign - "$PROJECT_DIR/dist/PetNativeHost"
fi
printf 'Built app: %s\nBuilt bridge: %s\n' "$APP_DIR" "$PROJECT_DIR/dist/PetNativeHost"
