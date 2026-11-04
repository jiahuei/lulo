# Interactive macOS verification

Automated package tests and an unsigned build do not establish Finder integration, sandbox behavior, rendering fidelity, gestures, or accessibility. The following checks remain a release gate and must be recorded on a Mac. Use only synthetic or appropriately licensed fixtures. Do not publish personal paths, GPS, serial numbers, or metadata.

Build using QUICKSTART.md, then run a locally signed app with the checked-in sandbox entitlements. An unsigned build or a package test is not proof of sandbox enforcement. Record macOS/Xcode versions, display backing scales, input devices, and actual results when performing these checks.

- [ ] Launch: window fills the available screen without native full screen; image fit is letterboxed and uncropped.
- [ ] Open via Finder and Open: one window is reused, requested image becomes selected, filters clear, sidebar collapses, and saved zoom default is restored. Repeat with the window closed and with a permission sheet open.
- [ ] Grant the exact containing folder; siblings appear. Decline; the opened image remains usable. Retry from File > Allow Folder Navigation. Choose a different folder; it must not be enumerated as though it were the containing folder.
- [ ] Switch between authorized folders and rapidly open/navigate images while decoding and scanning. Old results must never replace the new selection; grants must outlive dependent work.
- [ ] Navigate at both ends, through a single image, through corrupt/unreadable images, and with no filter matches. RAW files never enter the list; direct RAW opening shows the unsupported message.
- [ ] Verify every sort in both directions, equal primary values, missing metadata, and capture-time to creation-time fallback. Descending reverses filename ties too. Combine exact rating and type filters.
- [ ] Relaunch: saved display/sort/direction survive, filters and sidebar reset. Navigation retains active filters/sort/sidebar.
- [ ] Compare 100% on 1x and 2x backing displays and move the window between them. Equal pixel-size images tagged at 72 and 300 PPI must render at equal sizes. Resize and expand/collapse metadata while in fit mode.
- [ ] Test scroll up/down using a mouse and trackpad with natural scrolling both enabled and disabled. Verify double-click after manual zoom for both saved defaults. Drag to pan an oversized image.
- [ ] Inspect synthetic asymmetric orientation fixtures for all eight EXIF orientations. Compare tagged sRGB and Display P3 colors, and PNG transparency, against a trusted color-managed viewer. Test JPEG and HEIC/HEIF from representative encoders, including missing metadata.
- [ ] Compare sidebar field names with docs/PRODUCT.md. Confirm missing fields are omitted, source dimensions do not change with zoom, and sidecars do not affect metadata/ratings.
- [ ] Test VoiceOver labels, keyboard focus, menu shortcuts, selectable metadata, light/dark appearance, minimum window size, and sidebar scrolling with lengthy comments/paths.
- [ ] Compare hashes of all input images before and after viewing. Confirm no image, sidecar, or catalog files are created or modified.
- [ ] Exercise a near-limit image and an image over 64 megapixels, then continue navigating. Measure resident memory during repeated rapid selections; distinguish decode working memory from retained image data.

No interactive verification has yet been recorded in this repository.
