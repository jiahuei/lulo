# Development setup

Run commands from the repository root. Lulo targets macOS 14+. The pinned application toolchain is **Xcode 16.4 (16F6), Apple Swift 6.1.2**, matching `.github/workflows/macos.yml`. AppKit, Image I/O, and interactive verification require macOS.

Open `Lulo.xcodeproj` with Xcode 16.4 and run the shared **Lulo** scheme. See [Build and test](#build-and-test) for command-line checks and local signing. The initial implementation needs the interactive macOS verification below before release.

- [Product behavior and decisions](docs/PRODUCT.md)
- [Interactive macOS verification](docs/MACOS-VERIFICATION.md)
- [Agent guidelines](AGENTS.md)
- [Swift and macOS conventions](docs/CONVENTIONS.md)

## Download a PR test build

Every pull request, including drafts, runs the macOS workflow and uploads `Lulo-macOS-universal` after tests, analysis, and packaging succeed. Its **Lulo test build** comment links directly to the downloadable artifact and identifies the source commit. The workflow run summary also contains the download link. Builds support Apple Silicon and Intel Macs running macOS 14 or later.

1. Sign in to GitHub and follow the PR's download link. Artifacts are retained for 30 days; rerun the PR's macOS workflow if the download has expired.
2. Unzip the downloaded artifact, then unzip `Lulo-macOS-universal.zip` inside it. The inner ZIP preserves the app bundle's executable permissions and signature.
3. Move `Lulo.app` to Applications and open it.
4. The app is ad-hoc signed with the user-selected read/write sandbox entitlements, but is not Apple-notarized. After the first blocked launch, use **System Settings > Privacy & Security > Open Anyway** for this app. See [Apple's instructions](https://support.apple.com/102445).

No Xcode or signing credentials are needed to try these builds. They are development previews; follow [the interactive verification checklist](docs/MACOS-VERIFICATION.md) when testing them. CI validates the signature and entitlements and performs a short launch, but does not verify Gatekeeper's downloaded-app flow or interactive sandbox grants on your laptop.

The comment workflow uses `workflow_run` and becomes active once `.github/workflows/pr-build-comment.yml` is on the default branch. The initial implementation PR receives a manually posted download link. Subsequent builds update one bot comment; failed builds replace the link with their status, and obsolete commits do not overwrite newer commit links. While a new build is running, the previous comment still identifies the previous build's commit. Fork PRs may need the repository owner's normal Actions approval before building.

## Build and test

Install Xcode 16.4, open it once to complete setup, then select the same toolchain as CI:

```sh
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
xcodebuild -version
swift --version
swift format lint --strict --recursive Package.swift Sources Tests App tools
swift test
xcodebuild -project Lulo.xcodeproj -scheme Lulo -configuration Debug -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build analyze
```

The shared Lulo scheme builds `build/Build/Products/Debug/Lulo.app`. The unsigned build validates compilation and static analysis; it does not validate sandbox enforcement. For interactive testing, open `Lulo.xcodeproj`, select the Lulo scheme, select a local signing identity/team in Xcode without committing those settings, and run with `App/Lulo.entitlements`. The entitlements enable App Sandbox and user-selected read/write file access for the explicit Move to Trash action. Follow [the macOS verification checklist](docs/MACOS-VERIFICATION.md).

The Swift package contains `LuloCore` for preferences, ordering, selection, and zoom, and `LuloImaging` for Image I/O and file access. Tests generate small synthetic images in temporary directories, including HEIF through macOS Image I/O. There are no external package dependencies. Linux cannot run the Image I/O tests or build the application.

Format changed Swift files with the pinned toolchain:

```sh
swift format format --in-place --recursive Package.swift Sources Tests App tools
```

## Package the test app locally

With the pinned Xcode toolchain selected, run:

```sh
bash tools/package-app.sh
```

This builds a universal Release app, signs it ad-hoc with `App/Lulo.entitlements`, and writes `build/distribution/Lulo-macOS-universal.zip`. It extracts that ZIP into a temporary directory, checks both architectures, executable permissions, signature integrity, and exact sandbox entitlements, then performs a three-second launch and prints the ZIP's SHA-256 checksum. It does not require a Developer ID certificate or publish a release.

## Native UI previews

After the unsigned Debug build, capture the actual AppKit viewer in light/dark appearance and at regular/compact sizes:

```sh
bash tools/render-previews.sh
```

The command compiles the current view/controller with a small preview entry point, reusing the build's package objects. It generates a synthetic image, declines the folder permission sheet, captures native view hierarchies under `build/previews/`, checks that the image area remains usable with the inspector open, and exercises multiple rating/type checkbox selections, group intersection, deselection recovery, status summaries, and the real Clear Filters button. It also navigates temporary copies of the approved real-photo fixture through actual canvas arrow events, checking wrapping, reversals, rapid selections, superseded opens, and matching image/metadata state. Loading checks require retained pixels and zoom before completion, the latest filename overlay, overlay dismissal on completion/failure, and recovery through corrupt files. Compact light/dark loading captures include a long filename. A deterministic barrier also holds a scan after its first metadata read while the actual controller opens another session; the check requires the new image to load before releasing the scan, then verifies prompt cancellation, unchanged new-session selection, and release of the old grant. Trash checks use synthetic files and a controlled operation to cover confirmation, cancellation, failure, next-image selection, last-image removal, and completion after another file opens. Package tests exercise the actual macOS Trash API and verify that bytes survive the move. CI uploads these PNGs as the `native-previews` artifact for seven days. `bash tools/render-previews.sh <output-directory> <app-source-directory>` can render another revision's view/controller for comparison.

Cached-navigation checks prewarm the real image store and verify both Next and Previous replace the image without presenting a loading overlay, including when the preceding request left an overlay visible. Package tests verify that loading feedback is requested for cache misses, eviction, changed files, and new sessions, but not for hits, canceled queued work, or reused completed prefetches.

Toolbar checks exercise both viewing-mode segments after manual zoom, verify double-click synchronization, and require new or reopened viewers to start in Fit to Window. Native arrow checks also verify off-center cursor anchoring, mode/region preservation during navigation and error recovery, and Fit resets on explicit opens. Portable zoom tests cover relative positions across image sizes, backing scales, letterboxing, and pan limits. Filter checks verify active-group counts through the icon button's accessibility label and tooltip. Gallery checks also verify that entering the grid resets to Fit, the toggle is disabled in the grid, and it re-enables in Fit when opening a gallery image.

Gallery checks use 80 synthetic images and one corrupt file to exercise permission refusal, thumbnail loading, keyboard selection/opening, returning to the selected image, cell reuse during scrolling, accessibility labels for embedded one-to-five/zero/missing ratings, portrait/landscape image geometry used to position overlays, multiple rating/type filter selections and recovery, disabled Trash in gallery mode, and clearing the gallery on a new explicit open. The harness also saves regular light and compact dark gallery captures for [manual visual verification](docs/MACOS-VERIFICATION.md).

This unsandboxed development helper is not bundled with Lulo. View captures establish layout evidence; they do not establish Finder integration, sandbox enforcement, mouse/trackpad behavior, display color fidelity, or VoiceOver behavior. The interactive checklist remains required.

## Navigation performance and photo regression

`Tests/LuloImagingTests/Fixtures/DSCF2143-LR-light.jpg` is the owner's explicitly approved public fixture: an 837 KB, 4085 × 6128 JPEG with its shooting and GPS metadata intact. The fixture README records permission. Package tests assert exposure, ISO, focal lengths, camera/lens, capture timezone, GPS coordinates, altitude, original dimensions, and unchanged bytes. Cache tests cover independent 1 GiB defaults, the full-resolution ten-image cap, thumbnail reuse beyond ten images, byte limits/eviction, file changes/deletion, new viewer sessions, cancelled queued requests, and completed decodes reused after cancellation. Small synthetic fixtures and injected byte budgets exercise eviction without allocating gigabytes during tests.

After `bash tools/package-app.sh`, run:

```sh
bash tools/benchmark-navigation.sh
# Optional before/after comparison, using the same fixture and compiler on this machine:
bash tools/benchmark-navigation.sh origin/main
```

The comparison compiles the base revision's actual package sources in a temporary directory. The candidate uses the optimized Release modules built for the app. Both run the same 2,000-entry navigation/status workload starting in the middle of the folder, full-resolution JPEG decoder, and metadata reader. Output includes every sample, median, and maximum in milliseconds; the candidate also measures warm image-store reuse and retained pixel bytes. CI runs the comparison against each PR's base commit. Setup/sorting is excluded from navigation samples; the first decode is reported alongside subsequent reads without flushing the OS filesystem cache. These component measurements do not include display/paint latency and are not a comparison against JPEGView. The benchmark also measures complete metadata discovery of 1,000 temporary links to a copy of the real photo, plus cancellation after the first metadata read (three samples each). Directory listing time is included; fixture/link setup is excluded. No machine-dependent timing threshold gates CI.

For interactive checks, use the PR app with a folder of large photos. Try paced next/previous navigation, rapid repeats/reversals, metadata-visible navigation, sorting/filter changes, external file replacement/deletion, and opening another file during a load. Confirm the final selection, full-resolution zoom, and sandbox behavior on your laptop.

## Documentation checks

Use Node.js 24, matching `.github/workflows/lint.yml`. The pinned Prettier command needs npm registry access unless cached.

```sh
npx --yes prettier@3.8.3 --check '**/*.md' '.github/**/*.yml' '.github/scripts/*.cjs' .prettierrc
node --test .github/scripts/comment-pr-build.test.cjs
bash -n tools/package-app.sh
git diff --check
```

Format only changed documentation/configuration paths with `npx --yes prettier@3.8.3 --write <paths>`.

Documentation checks run on pushes to every branch. macOS checks and app packaging run on pull requests and pushes to `main`, with read-only repository permissions. The separate PR-comment workflow uses trusted default-branch code with permission to read run metadata and write PR comments; it never downloads or executes PR artifacts. Local task records under `tasks/` are ignored by Git and Prettier. Signing credentials and generated build/distribution artifacts must stay out of Git. Dependency lockfiles remain trackable if dependencies are added later.

## Repository background

The repository foundation is adapted from [Talking Clock PR #1](https://github.com/jiahuei/ios-talking-clock/pull/1), using the reference repository's [main-branch files at `71a1f23`](https://github.com/jiahuei/ios-talking-clock/tree/71a1f23c251bbd288e1184a27950563daad53fbd). No image-viewer reference application code is included.
