# Swift and macOS conventions

These conventions guide the implementation. See `PRODUCT.md` for behavior and architecture, and `../QUICKSTART.md` for the macOS target, pinned toolchain, and checks.

- Prefer native platform capabilities and standard-library solutions before adding dependencies or custom infrastructure.
- Use the official `swift format` tool with the repository's `.swift-format` configuration. Use the Xcode/Swift toolchain pinned in `.github/workflows/macos.yml`.
- Keep presentation state on the main actor. Perform file enumeration and image decoding away from the UI thread, and prevent obsolete asynchronous results from replacing the current selection.
- Keep portable logic independent of AppKit and SwiftUI where that makes it easier to test. Introduce interfaces only when a concrete integration or test needs one.
- Use native macOS controls, menu commands, keyboard shortcuts, semantic colors, and accessible labels. Verify VoiceOver, focus behavior, light/dark appearance, and window resizing on macOS.
- Treat viewing as read-only. Do not change original image bytes or metadata as a side effect of opening or displaying a file.
- Only an explicit, confirmed Move to Trash command may move a source image. Use the native Trash API without a permanent-delete fallback.
- Respect user-granted file access. Pair successful security-scoped access with release after dependent work finishes; do not assume that opening one file grants access to its parent directory.
- Use Image I/O for supported image decoding and metadata when appropriate. Preserve orientation, aspect ratio, transparency, and color profiles, and bound decoded-image memory.
- Surface missing, unsupported, unreadable, and corrupt files as recoverable errors. Do not log private image paths or metadata unnecessarily.
- Use synthetic or appropriately licensed fixtures and temporary directories in tests. State each test's purpose and cover relevant failure paths as well as success.
- Keep signing teams, provisioning profiles, and credentials out of the repository. Commit a shared scheme when an Xcode project is introduced.
- Pin dependency versions exactly and commit dependency lockfiles when created.

## Platform references

Consult current Apple documentation when implementing integrations:

- [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Image I/O](https://developer.apple.com/documentation/imageio)
- [Creating image thumbnails](<https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:)>)
- [Applying image orientation to thumbnails](https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailwithtransform)
