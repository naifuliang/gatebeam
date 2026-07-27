#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/backend-diagnostics"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"

swiftc \
  -swift-version 5 \
  -O \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework Security \
  "$ROOT_DIR/Sources/RemoteControlNetwork/Models.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/AppConfigStore.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/KeychainStore.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/HTTPClient.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/PublicIPService.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/LocalNetworkService.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/CloudflareDNSProvider.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/RouterMappingService.swift" \
  "$ROOT_DIR/Tools/BackendDiagnostics/main.swift" \
  -o "$BUILD_DIR/backend-diagnostics"

echo "Built: $BUILD_DIR/backend-diagnostics"
