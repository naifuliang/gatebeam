#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/proxy-policy-tests"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"

swiftc \
  -swift-version 5 \
  -module-cache-path "$MODULE_CACHE_DIR" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/HTTPClient.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/PublicIPService.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/Models.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/CloudflareDNSProvider.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/LocalNetworkService.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/RouterMappingService.swift" \
  "$ROOT_DIR/Tests/ProxyPolicyTests/main.swift" \
  -o "$BUILD_DIR/proxy-policy-tests"

"$BUILD_DIR/proxy-policy-tests"
