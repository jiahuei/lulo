#!/bin/bash
set -euo pipefail

# Compare the actual canvas source before the PR review fixes with today's source on the same runner.
canvas_base="${1:-75ef7bc2b04bcebf66a6882b0784b662522cd1d5}"
canvas_target="$(uname -m)-apple-macos14.0"
canvas_products=build/Build/Products/Release
canvas_baseline=$(mktemp -d)
trap 'rm -rf "$canvas_baseline"' EXIT
git archive "$canvas_base" App/ImageCanvas.swift App/Presentation.swift | tar -x -C "$canvas_baseline"
for canvas_sources in "$canvas_baseline/App" App; do
    xcrun swiftc -target "$canvas_target" -O -swift-version 6 -parse-as-library \
        -I "$canvas_products" "$canvas_sources/ImageCanvas.swift" "$canvas_sources/Presentation.swift" \
        tools/BenchmarkCanvas.swift "$canvas_products/LuloCore.o" "$canvas_products/LuloImaging.o" \
        -o "$canvas_baseline/BenchmarkCanvas"
    if [ "$canvas_sources" = App ]; then echo "CANVAS CANDIDATE"; else echo "CANVAS BASELINE $canvas_base"; fi
    "$canvas_baseline/BenchmarkCanvas" Tests/LuloImagingTests/Fixtures/DSCF2143-LR-light.jpg
done
