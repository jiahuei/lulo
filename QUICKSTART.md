# Development setup

Run commands from the repository root. Lulo targets macOS 14+. The pinned application toolchain is **Xcode 16.4 (16F6), Apple Swift 6.1.2**, matching `.github/workflows/macos.yml`. AppKit, Image I/O, and interactive verification require macOS.

## Download a PR test build

Every pull request, including drafts, runs the macOS workflow and uploads `Lulo-macOS-universal` after tests, analysis, and packaging succeed. Its **Lulo test build** comment links directly to the downloadable artifact and identifies the source commit. The workflow run summary also contains the download link. Builds support Apple Silicon and Intel Macs running macOS 14 or later.

1. Sign in to GitHub and follow the PR's download link. Artifacts are retained for 30 days; rerun the PR's macOS workflow if the download has expired.
2. Unzip the downloaded artifact, then unzip `Lulo-macOS-universal.zip` inside it. The inner ZIP preserves the app bundle's executable permissions and signature.
3. Move `Lulo.app` to Applications and open it.
4. The app is ad-hoc signed with the normal read-only sandbox entitlements, but is not Apple-notarized. After the first blocked launch, use **System Settings > Privacy & Security > Open Anyway** for this app. See [Apple's instructions](https://support.apple.com/102445).

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

The shared Lulo scheme builds `build/Build/Products/Debug/Lulo.app`. The unsigned build validates compilation and static analysis; it does not validate sandbox enforcement. For interactive testing, open `Lulo.xcodeproj`, select the Lulo scheme, select a local signing identity/team in Xcode without committing those settings, and run with `App/Lulo.entitlements`. The entitlements enable App Sandbox and user-selected read-only file access. Follow [the macOS verification checklist](docs/MACOS-VERIFICATION.md).

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

The command compiles the current view/controller with a small preview entry point, reusing the build's package objects. It generates a synthetic image, declines the folder permission sheet, captures native view hierarchies under `build/previews/`, checks that the image area remains usable with the inspector open, and exercises rating-filter exclusion and the real Clear Filters button. CI uploads these PNGs as the `native-previews` artifact for seven days. `bash tools/render-previews.sh <output-directory> <app-source-directory>` can render another revision's view/controller for comparison.

This unsandboxed development helper is not bundled with Lulo. View captures establish layout evidence; they do not establish Finder integration, sandbox enforcement, mouse/trackpad behavior, display color fidelity, or VoiceOver behavior. The interactive checklist remains required.

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
