#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/cache
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path "$PWD/build/cache" Sources/Motion.swift Sources/RuntimeLog.swift Tests/MotionTests.swift -o build/motion-tests
build/motion-tests
