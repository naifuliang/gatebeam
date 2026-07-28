#!/bin/zsh -f
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-}"
SWIFT_FLAGS=()

case "$MODE" in
  "")
    BUILD_DIR="$ROOT_DIR/build/integration-contract-tests"
    ;;
  --thread-sanitizer)
    BUILD_DIR="$ROOT_DIR/build/integration-contract-tests-tsan"
    SWIFT_FLAGS=(-sanitize=thread -g)
    ;;
  *)
    print -u2 -- "Usage: ${0:t} [--thread-sanitizer]"
    exit 64
    ;;
esac

MODULE_CACHE_DIR="$BUILD_DIR/module-cache"
TEST_BINARY="$BUILD_DIR/integration-contract-tests"

rm -rf -- "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"

swiftc \
  -swift-version 5 \
  "${SWIFT_FLAGS[@]}" \
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
  -o "$TEST_BINARY"

if [[ "$MODE" == "--thread-sanitizer" ]]; then
  /usr/bin/otool -L "$TEST_BINARY" |
    /usr/bin/grep -F "libclang_rt.tsan_osx_dynamic.dylib" >/dev/null || {
      print -u2 -- "error: integration contract binary is not linked to Thread Sanitizer"
      exit 1
    }
  env \
    TSAN_OPTIONS="halt_on_error=1:exitcode=66:report_bugs=1" \
    "$TEST_BINARY"
else
  "$TEST_BINARY"
fi
