#!/bin/zsh -f
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT_DIR/Resources/AppIcon-Source.png"
ICON_BUILD_DIR="$ROOT_DIR/build/icon"
ICONSET="$ICON_BUILD_DIR/AppIcon.iconset"
OUTPUT="${1:-$ICON_BUILD_DIR/AppIcon.icns}"
ASSET_CATALOG="$ICON_BUILD_DIR/AppIcon.xcassets"
ASSET_SET="$ASSET_CATALOG/AppIcon.appiconset"
ASSET_OUTPUT="$ICON_BUILD_DIR/AppIcon.asset-output"
PARTIAL_INFO_PLIST="$ICON_BUILD_DIR/AppIcon.asset-info.plist"
ACTOOL_LOG="$ICON_BUILD_DIR/actool.log"
MODULE_CACHE_DIR="$ROOT_DIR/build/module-cache"

mkdir -p "$ICON_BUILD_DIR" "$MODULE_CACHE_DIR" "$(dirname "$OUTPUT")"
[[ -s "$SOURCE" ]] || { echo "error: missing tracked icon source: $SOURCE" >&2; exit 1; }

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

declare -A EXPECTED_DIMENSIONS=(
  [icon_16x16.png]=16
  [icon_16x16@2x.png]=32
  [icon_32x32.png]=32
  [icon_32x32@2x.png]=64
  [icon_128x128.png]=128
  [icon_128x128@2x.png]=256
  [icon_256x256.png]=256
  [icon_256x256@2x.png]=512
  [icon_512x512.png]=512
  [icon_512x512@2x.png]=1024
)

for name in ${(k)EXPECTED_DIMENSIONS}; do
  image="$ICONSET/$name"
  expected_dimension="${EXPECTED_DIMENSIONS[$name]}"
  [[ -f "$image" ]] || { echo "error: missing icon image: $name" >&2; exit 1; }

  width="$(sips -g pixelWidth "$image" | awk '/pixelWidth/ { print $2 }')"
  height="$(sips -g pixelHeight "$image" | awk '/pixelHeight/ { print $2 }')"
  if [[ "$width" != "$expected_dimension" || "$height" != "$expected_dimension" ]]; then
    echo "error: $name must be ${expected_dimension}x${expected_dimension}, got ${width}x${height}" >&2
    exit 1
  fi
done

# iconutil on the current macOS/Xcode toolchain rejects even iconsets it has
# just extracted from a valid .icns. actool is Apple's supported asset compiler
# and creates the same .icns product from this fully validated iconset.
rm -rf "$ASSET_CATALOG" "$ASSET_OUTPUT"
rm -f "$PARTIAL_INFO_PLIST"
mkdir -p "$ASSET_SET" "$ASSET_OUTPUT"
printf '%s\n' '{"info":{"author":"xcode","version":1}}' > "$ASSET_CATALOG/Contents.json"
cp "$ICONSET"/*.png "$ASSET_SET/"
cat > "$ASSET_SET/Contents.json" <<'EOF'
{"images":[{"filename":"icon_16x16.png","idiom":"mac","scale":"1x","size":"16x16"},{"filename":"icon_16x16@2x.png","idiom":"mac","scale":"2x","size":"16x16"},{"filename":"icon_32x32.png","idiom":"mac","scale":"1x","size":"32x32"},{"filename":"icon_32x32@2x.png","idiom":"mac","scale":"2x","size":"32x32"},{"filename":"icon_128x128.png","idiom":"mac","scale":"1x","size":"128x128"},{"filename":"icon_128x128@2x.png","idiom":"mac","scale":"2x","size":"128x128"},{"filename":"icon_256x256.png","idiom":"mac","scale":"1x","size":"256x256"},{"filename":"icon_256x256@2x.png","idiom":"mac","scale":"2x","size":"256x256"},{"filename":"icon_512x512.png","idiom":"mac","scale":"1x","size":"512x512"},{"filename":"icon_512x512@2x.png","idiom":"mac","scale":"2x","size":"512x512"}],"info":{"author":"xcode","version":1}}
EOF

if ! xcrun actool \
  --compile "$ASSET_OUTPUT" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$PARTIAL_INFO_PLIST" \
  "$ASSET_CATALOG" >"$ACTOOL_LOG" 2>&1; then
  cat "$ACTOOL_LOG" >&2
  exit 1
fi

GENERATED_OUTPUT="$ASSET_OUTPUT/AppIcon.icns"
[[ -s "$GENERATED_OUTPUT" ]] || { echo "error: actool did not produce AppIcon.icns" >&2; exit 1; }
cp "$GENERATED_OUTPUT" "$OUTPUT"
file "$OUTPUT" | grep -q 'Mac OS X icon' || { echo "error: generated AppIcon.icns is invalid" >&2; exit 1; }

echo "Built icon: $OUTPUT"
