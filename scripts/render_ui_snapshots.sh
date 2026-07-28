#!/bin/zsh -f
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_CACHE_DIR="$ROOT_DIR/build/module-cache"
RUNNER="$ROOT_DIR/build/render_ui_snapshots"
SOURCES=("$ROOT_DIR"/Sources/RemoteControlNetwork/*.swift)
FILTERED=()

mkdir -p "$ROOT_DIR/build" "$MODULE_CACHE_DIR"

for source in "${SOURCES[@]}"; do
  if [[ "$(basename "$source")" != "main.swift" ]]; then
    FILTERED+=("$source")
  fi
done

swiftc \
  -swift-version 5 \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework AppKit \
  -framework LocalAuthentication \
  -framework Security \
  "${FILTERED[@]}" \
  "$ROOT_DIR/scripts/render_ui_snapshots.swift" \
  -o "$RUNNER"

"$RUNNER" "$ROOT_DIR"
