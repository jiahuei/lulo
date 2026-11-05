#!/bin/bash
set -euo pipefail

# Optional base ref gives an equivalent Release comparison using the same fixture and benchmark.
# Compile production package sources from that revision, not a reimplementation of their algorithms.
benchmark_base="${1:-}"
benchmark_target="$(uname -m)-apple-macos14.0"
fixture=Tests/LuloImagingTests/Fixtures/DSCF2143-LR-light.jpg
if [ -n "$benchmark_base" ]; then
    baseline=$(mktemp -d)
    trap 'rm -rf "$baseline"' EXIT
    git archive "$benchmark_base" Sources | tar -x -C "$baseline"
    xcrun swiftc -target "$benchmark_target" -O -whole-module-optimization -swift-version 6 -parse-as-library \
        -emit-module -emit-object -module-name LuloCore \
        "$baseline"/Sources/LuloCore/*.swift \
        -emit-module-path "$baseline/LuloCore.swiftmodule" -o "$baseline/LuloCore.o"
    xcrun swiftc -target "$benchmark_target" -O -whole-module-optimization -swift-version 6 -parse-as-library \
        -I "$baseline" -emit-module -emit-object -module-name LuloImaging \
        "$baseline"/Sources/LuloImaging/*.swift \
        -emit-module-path "$baseline/LuloImaging.swiftmodule" -o "$baseline/LuloImaging.o"
    xcrun swiftc -target "$benchmark_target" -O -swift-version 6 -parse-as-library -D BASELINE -I "$baseline" \
        tools/BenchmarkNavigation.swift "$baseline/LuloCore.o" "$baseline/LuloImaging.o" \
        -o "$baseline/BenchmarkNavigation"
    echo "BASELINE $benchmark_base"
    "$baseline/BenchmarkNavigation" "$fixture"
fi

# Run after package-app.sh so candidate measurements use the actual optimized Release modules.
echo "CANDIDATE"
products=build/Build/Products/Release
xcrun swiftc -target "$benchmark_target" -O -swift-version 6 -parse-as-library \
    -I "$products" \
    tools/BenchmarkNavigation.swift "$products/LuloCore.o" "$products/LuloImaging.o" \
    -o build/BenchmarkNavigation
build/BenchmarkNavigation "$fixture"
