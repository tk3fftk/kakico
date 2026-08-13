#!/bin/bash
# Generates Resources/AppIcon.icns from Resources/AppIcon.png
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Resources/AppIcon.png"
DST="$ROOT/Resources/AppIcon.icns"

if [[ ! -f "$SRC" ]]; then
    echo "error: $SRC not found" >&2
    exit 1
fi

echo "==> generating $DST from $SRC"
TMP_DIR="$(mktemp -d)"
trap 'if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then rm -rf "$TMP_DIR"; fi' EXIT

ICONSET_DIR="$TMP_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

sips -z 16 16     "$SRC" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64     "$SRC" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$SRC" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$SRC" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET_DIR" -o "$DST"
echo "==> updated $DST successfully"
