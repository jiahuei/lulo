#!/bin/bash
set -euo pipefail

# Run after package-app.sh so measurements use the actual optimized Release modules.
products=build/Build/Products/Release
xcrun swiftc -O -swift-version 6 -parse-as-library \
    -target "$(uname -m)-apple-macos14.0" -I "$products" \
    tools/BenchmarkNavigation.swift "$products/LuloCore.o" "$products/LuloImaging.o" \
    -o build/BenchmarkNavigation
build/BenchmarkNavigation Tests/LuloImagingTests/Fixtures/DSCF2143-LR.jpg
