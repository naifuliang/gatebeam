#!/bin/zsh -f
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/integration-contract-tests"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"

swiftc \
  -swift-version 5 \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework AppKit \
  -framework LocalAuthentication \
  -framework Security \
  "$ROOT_DIR/Sources/RemoteControlNetwork/HTTPClient.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/PublicIPService.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/Models.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/CloudflareDNSProvider.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/LocalNetworkService.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/RouterMappingService.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/AppConfigStore.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/KeychainStore.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/LaunchAgentManager.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/NetworkAgent.swift" \
  "$ROOT_DIR/Sources/RemoteControlNetwork/SettingsWindowController.swift" \
  "$ROOT_DIR/Tests/IntegrationContractTests/main.swift" \
  -o "$BUILD_DIR/integration-contract-tests"

"$BUILD_DIR/integration-contract-tests"
