#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT_DIR/Resources/AppIcon-Source.png"
ICONSET="$ROOT_DIR/build/AppIcon.iconset"
OUTPUT="$ROOT_DIR/Resources/AppIcon.icns"
GENERATED_OUTPUT="$ROOT_DIR/build/AppIcon.generated.icns"
GENERATOR="$ROOT_DIR/build/generate_icon"
MODULE_CACHE_DIR="$ROOT_DIR/build/module-cache"

mkdir -p "$ROOT_DIR/build" "$MODULE_CACHE_DIR"

swiftc \
  -swift-version 5 \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework AppKit \
  "$ROOT_DIR/scripts/generate_icon.swift" \
  -o "$GENERATOR"

"$GENERATOR" "$ROOT_DIR"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

sips -z 16 16 "$SOURCE" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$SOURCE" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$SOURCE" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$SOURCE" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$SOURCE" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$SOURCE" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SOURCE" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$SOURCE" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SOURCE" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$SOURCE" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

if iconutil -c icns "$ICONSET" -o "$GENERATED_OUTPUT"; then
  mv "$GENERATED_OUTPUT" "$OUTPUT"
elif [[ -s "$OUTPUT" ]]; then
  echo "warning: iconutil rejected the generated iconset; using the checked-in AppIcon.icns" >&2
else
  echo "error: iconutil rejected the generated iconset and no fallback AppIcon.icns exists" >&2
  exit 1
fi

echo "Built icon: $OUTPUT"
