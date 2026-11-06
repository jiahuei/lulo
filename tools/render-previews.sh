#!/bin/bash
set -euo pipefail

# Run after the unsigned Debug build from QUICKSTART.md; reuse its exact modules and object files.
preview_output="${1:-build/previews}"
preview_sources="${2:-App}"
products=build/Build/Products/Debug
xcrun swiftc -swift-version 6 -parse-as-library \
    -target "$(uname -m)-apple-macos14.0" \
    -I "$products" \
    "$preview_sources/ImageCanvas.swift" "$preview_sources/GalleryView.swift" \
    "$preview_sources/ViewerController.swift" tools/RenderPreviews.swift \
    "$products/LuloCore.o" "$products/LuloImaging.o" \
    -o build/LuloPreview
build/LuloPreview "$preview_output"
