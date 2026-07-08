#!/bin/bash
# Builds Kakico.app — a native arm64, ad-hoc-signed macOS app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Kakico.app"

echo "==> swift build -c $CONFIG"
cd "$ROOT"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Kakico"
if [[ ! -f "$BIN" ]]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kakico"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Optional release version stamp (VERSION env var or 2nd arg, "v" prefix tolerated).
# Must happen before codesign: editing Info.plist afterwards breaks the seal.
VERSION="${VERSION:-${2:-}}"
if [[ -n "$VERSION" ]]; then
    VERSION="${VERSION#v}"
    echo "==> stamping version $VERSION"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

echo "==> ad-hoc code signing"
codesign --force --sign - "$APP"

echo "==> verifying"
codesign --verify --verbose "$APP"
echo "arch: $(lipo -archs "$APP/Contents/MacOS/Kakico")"
echo "Built: $APP"
