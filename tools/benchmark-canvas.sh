#!/bin/bash
set -euo pipefail

# Optional base ref compares production canvas sources with the same fixture and Release modules.
canvas_base="${1:-}"
canvas_target="$(uname -m)-apple-macos14.0"
canvas_products=build/Build/Products/Release
canvas_scratch=$(mktemp -d)
trap 'rm -rf "$canvas_scratch"' EXIT
canvas_versions=(App)
if [ -n "$canvas_base" ]; then
    git archive "$canvas_base" App | tar -x -C "$canvas_scratch"
    canvas_versions=("$canvas_scratch/App" App)
fi
for canvas_sources in "${canvas_versions[@]}"; do
    canvas_files=("$canvas_sources/ImageCanvas.swift")
    # Earlier versions used only AppKit; the D9 canvas uses the shared palette and message views.
    if [ -f "$canvas_sources/Theme.swift" ]; then
        canvas_files+=("$canvas_sources/Theme.swift" "$canvas_sources/Controls.swift")
    fi
    xcrun swiftc -target "$canvas_target" -O -swift-version 6 -parse-as-library \
        -I "$canvas_products" "${canvas_files[@]}" \
        tools/BenchmarkCanvas.swift "$canvas_products/LuloCore.o" "$canvas_products/LuloImaging.o" \
        -o "$canvas_scratch/BenchmarkCanvas"
    if [ "$canvas_sources" = App ]; then
        echo "CANVAS CANDIDATE"
    else
        echo "CANVAS BASELINE $canvas_base"
    fi
    "$canvas_scratch/BenchmarkCanvas" Tests/LuloImagingTests/Fixtures/DSCF2143-LR-light.jpg
done
