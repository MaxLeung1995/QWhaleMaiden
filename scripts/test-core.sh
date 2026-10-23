#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/cache
export CLANG_MODULE_CACHE_PATH="$PWD/build/cache"
export SWIFT_MODULECACHE_PATH="$PWD/build/cache"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path "$PWD/build/cache" Sources/Core.swift Sources/Agents.swift Sources/IPC.swift Tests/CoreTests.swift -lsqlite3 -o build/core-tests
build/core-tests
