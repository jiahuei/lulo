# Development setup

Run commands from the repository root. Lulo targets macOS 14+. The pinned application toolchain is **Xcode 16.4 (16F6), Apple Swift 6.1.2**, matching `.github/workflows/macos.yml`. AppKit, Image I/O, and interactive verification require macOS.

## Build and test

Install Xcode 16.4, open it once to complete setup, then select the same toolchain as CI:

```sh
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
xcodebuild -version
swift --version
swift format lint --strict --recursive Package.swift Sources Tests App
swift test
xcodebuild -project Lulo.xcodeproj -scheme Lulo -configuration Debug -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build analyze
```

The shared Lulo scheme builds `build/Build/Products/Debug/Lulo.app`. The unsigned build validates compilation and static analysis; it does not validate sandbox enforcement. For interactive testing, open `Lulo.xcodeproj`, select the Lulo scheme, select a local signing identity/team in Xcode without committing those settings, and run with `App/Lulo.entitlements`. The entitlements enable App Sandbox and user-selected read-only file access. Follow [the macOS verification checklist](docs/MACOS-VERIFICATION.md).

The Swift package contains `LuloCore` for preferences, ordering, selection, and zoom, and `LuloImaging` for Image I/O and file access. Tests generate small synthetic images in temporary directories, including HEIF through macOS Image I/O. There are no external package dependencies. Linux cannot run the Image I/O tests or build the application.

Format changed Swift files with the pinned toolchain:

```sh
swift format format --in-place --recursive Package.swift Sources Tests App
```

## Documentation checks

Use Node.js 24, matching `.github/workflows/lint.yml`. The pinned Prettier command needs npm registry access unless cached.

```sh
npx --yes prettier@3.8.3 --check '**/*.md' '.github/**/*.yml' .prettierrc
git diff --check
```

Format only changed documentation/configuration paths with `npx --yes prettier@3.8.3 --write <paths>`.

Both workflows run on pushes to every branch with read-only repository permissions. Local task records under `tasks/` are ignored by Git and Prettier. Signing credentials and generated build/distribution artifacts must stay out of Git. Dependency lockfiles remain trackable if dependencies are added later.
