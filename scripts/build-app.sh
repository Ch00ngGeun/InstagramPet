#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIGNING_CONFIG="${INSTAGRAMPET_SIGN_CONFIG:-$HOME/Library/Application Support/InstagramPet/signing.plist}"
SIGNING_IDENTITY="${INSTAGRAMPET_SIGN_IDENTITY--}"
SIGNING_KEYCHAIN="${INSTAGRAMPET_SIGN_KEYCHAIN:-}"
if [[ -z "${INSTAGRAMPET_SIGN_IDENTITY+x}" && -f "$SIGNING_CONFIG" ]]; then
    SIGNING_IDENTITY="$(/usr/libexec/PlistBuddy -c 'Print :identity' "$SIGNING_CONFIG")"
    if [[ -z "${INSTAGRAMPET_SIGN_KEYCHAIN+x}" ]]; then
        SIGNING_KEYCHAIN="$(/usr/libexec/PlistBuddy -c 'Print :keychain' "$SIGNING_CONFIG" 2>/dev/null || true)"
    fi
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    printf 'Signing identity must not be empty. Use - explicitly for ad-hoc signing.\n' >&2
    exit 1
fi
SIGNING_ARGS=(--force --sign "$SIGNING_IDENTITY")
if [[ -n "$SIGNING_KEYCHAIN" && "$SIGNING_IDENTITY" != '-' ]]; then
    SIGNING_ARGS+=(--keychain "$SIGNING_KEYCHAIN")
fi
if [[ "$SIGNING_IDENTITY" != '-' ]] && ! command -v codesign >/dev/null 2>&1; then
    printf 'Configured certificate signing requires codesign.\n' >&2
    exit 1
fi
cd "$PROJECT_DIR/macos"
swift build -c release
BINARY_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/InstagramPet.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PROJECT_DIR/macos/Resources/pet.png" "$APP_DIR/Contents/Resources/pet.png"
cp "$BINARY_DIR/InstagramPet" "$APP_DIR/Contents/MacOS/InstagramPet"
cp "$PROJECT_DIR/macos/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$BINARY_DIR/PetNativeHost" "$PROJECT_DIR/dist/PetNativeHost"
chmod 755 "$APP_DIR/Contents/MacOS/InstagramPet" "$PROJECT_DIR/dist/PetNativeHost"
if command -v codesign >/dev/null 2>&1; then
    codesign "${SIGNING_ARGS[@]}" "$APP_DIR"
    codesign "${SIGNING_ARGS[@]}" "$PROJECT_DIR/dist/PetNativeHost"
    codesign --verify --deep --strict "$APP_DIR"
    codesign --verify --strict "$PROJECT_DIR/dist/PetNativeHost"
    codesign --display --requirements - "$APP_DIR"
fi
printf 'Built app: %s\nBuilt bridge: %s\n' "$APP_DIR" "$PROJECT_DIR/dist/PetNativeHost"
