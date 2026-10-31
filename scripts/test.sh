#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."

# Keep compiler and SwiftPM caches inside this workspace in restricted sessions.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/swift-module-cache"

exec swift test \
  --disable-sandbox \
  --cache-path .build/cache \
  --config-path .build/config \
  --security-path .build/security \
  "$@"
