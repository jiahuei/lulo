#!/bin/bash
set -euo pipefail

# Run after the unsigned Debug build from QUICKSTART.md; reuse its exact modules and object files.
preview_output="${1:-build/previews}"
preview_sources="${2:-App}"
products=build/Build/Products/Debug
# Every app source except the @main entry point, which the preview harness replaces.
app_sources=()
for source in "$preview_sources"/*.swift; do
    [[ "$(basename "$source")" == LuloApp.swift ]] || app_sources+=("$source")
done
xcrun swiftc -swift-version 6 -parse-as-library \
    -target "$(uname -m)-apple-macos14.0" \
    -I "$products" \
    "${app_sources[@]}" tools/RenderPreviews.swift \
    "$products/LuloCore.o" "$products/LuloImaging.o" \
    -o build/LuloPreview
build/LuloPreview "$preview_output"
