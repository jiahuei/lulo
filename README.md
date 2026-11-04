# Lulo

A native, read-only macOS image viewer for JPEG, PNG, and HEIF images. Requires macOS 14 or later.

Lulo opens images in one reused window, asks permission before browsing their containing folder, and supports wrapping keyboard navigation, fit/100% display, scroll zoom, drag panning, embedded metadata, and rating/type filters. Display and sorting preferences persist across launches. RAW decoding, editing, sidecars, and library management are outside the initial scope.

Open `Lulo.xcodeproj` with Xcode 16.4 and run the shared **Lulo** scheme. See the development guide for command-line checks and local signing. The initial implementation needs the interactive macOS verification listed below before release.

- [Development setup and checks](QUICKSTART.md)
- [Product behavior and decisions](docs/PRODUCT.md)
- [Interactive macOS verification](docs/MACOS-VERIFICATION.md)
- [Agent guidelines](AGENTS.md)
- [Swift and macOS conventions](docs/CONVENTIONS.md)

The repository foundation is adapted from [Talking Clock PR #1](https://github.com/jiahuei/ios-talking-clock/pull/1), using the reference repository's [main-branch files at `71a1f23`](https://github.com/jiahuei/ios-talking-clock/tree/71a1f23c251bbd288e1184a27950563daad53fbd). No image-viewer reference application code is included.
