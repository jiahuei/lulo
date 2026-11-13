# Mac setup and Mac App Store checklist

Follow this guide from a fresh MacBook to a tested, signed Lulo release. Run Terminal commands from the repository root unless a step says otherwise. Check an item only after completing it; record the source commit, macOS/Xcode versions, app version/build, and test results for each release.

Apple references were checked on **2026-11-13**. Recheck their requirements before submitting. This document describes release work still to perform; CI produces development previews and does not publish to the Mac App Store.

## 1. Understand the starting point

| Item | Repository state | Release action |
| --- | --- | --- |
| App | AppKit app for macOS 14+, Apple Silicon and Intel | Test both architectures and the minimum supported OS |
| Build | `Lulo.xcodeproj`, shared `Lulo` scheme, local Swift package | Use the root project and run package tests separately |
| CI toolchain | Xcode 16.4 (16F6), Apple Swift 6.1.2 | Match it for development; check upload eligibility before release |
| Identity | `com.jiahuei.Lulo`, automatic signing, no team committed | Confirm ownership and select your team locally |
| Version | `0.1.0` / `1`, hardcoded in `App/Info.plist` | Set the release version and a fresh build number |
| Icon | Loupe artwork in `App/Assets.xcassets/AppIcon.appiconset` | Verify the existing icon in the archive and installed app |
| Sandbox | App Sandbox and user-selected read/write access | Preserve both and test the distributed app's file access |
| Store category | No `LSApplicationCategoryType` in `App/Info.plist` | Add the appropriate category before upload |
| Privacy/support | No privacy manifest or policy/support pages and in-app links yet | Complete the audit and release requirements in section 6 |
| Distribution | Ad-hoc signed universal ZIP from CI | Create a separate App Store archive with distribution signing |

## 2. Set up the MacBook

- [ ] Check **Apple menu > About This Mac** for the model, chip, and macOS version. Back up before upgrading and leave room for Xcode, build products, and archives.
- [ ] Choose a macOS version supported by the intended Xcode using [Apple's compatibility table](https://developer.apple.com/xcode/system-requirements/). Lulo can run on macOS 14, but Xcode 16.4 requires macOS Sequoia 15.3 or later within its supported host range (currently through Tahoe 26.1.x). A newer Mac/OS may require a newer Xcode; do not assume the CI pin runs on every newer macOS.
- [ ] Download **Xcode 16.4** from [Apple Developer Downloads](https://developer.apple.com/download/all/) to reproduce CI. Expand the `.xip`, move the app into `/Applications`, and name it `Xcode_16.4.app` for the commands below. The Mac App Store normally supplies the current Xcode, not this pinned version. Command Line Tools alone are insufficient.
- [ ] Open that Xcode once, accept its license, and finish installing required components. Lulo needs macOS support; no iOS simulator is needed.
- [ ] In Terminal, select and verify the full installation:

```sh
unset DEVELOPER_DIR
sudo xcode-select --switch /Applications/Xcode_16.4.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
xcode-select -p
xcodebuild -version
swift --version
xcodebuild -showsdks
git --version
```

Expect Xcode **16.4 / 16F6**, Apple Swift **6.1.2**, and a macOS SDK. `DEVELOPER_DIR` overrides `xcode-select`; set it in each new shell when reproducing CI, and change or unset it deliberately when switching Xcode. Swift Package Manager and Git come with Xcode. Lulo has no external package dependencies; Homebrew and CocoaPods are unnecessary.

If your Mac cannot run the pinned Xcode, install a compatible released Xcode and record that difference. Run all checks with it, resolve compatibility issues through a PR, and retain the pinned CI result as separate evidence. Before uploading, consult Apple's [upload toolchain table](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) and [upcoming requirements](https://developer.apple.com/news/upcoming-requirements/). The April 2026 SDK 26 requirement lists iOS/iPadOS, tvOS, visionOS, and watchOS; do not apply it to macOS by assumption. Use an eligible released Xcode and rerun verification if it differs from development.

- [ ] Install **Node.js 24** from [Node.js downloads](https://nodejs.org/en/download) for the repository's documentation and PR-comment checks. Verify `node --version` reports `v24.x` and `npm --version` succeeds. Node is not needed to run or archive Lulo.

## 3. Get the source, compile, and run tests

- [ ] Clone the repository:

```sh
mkdir -p ~/Developer
cd ~/Developer
git clone https://github.com/jiahuei/lulo.git
cd lulo
git switch -c chore/prepare-app-store-release
```

For an existing checkout, preserve local work and update a clean `main` with `git pull --ff-only` before creating a preparation branch. Read [QUICKSTART.md](QUICKSTART.md), [product behavior](docs/PRODUCT.md), and [conventions](docs/CONVENTIONS.md) before making release changes.

- [ ] Run the checks matching [macOS CI](.github/workflows/macos.yml), in this order:

```sh
swift format lint --strict --recursive Package.swift Sources Tests App tools
swift test
xcodebuild -project Lulo.xcodeproj -scheme Lulo -configuration Debug -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build analyze
bash tools/render-previews.sh
bash tools/package-app.sh
bash tools/benchmark-navigation.sh
bash tools/benchmark-canvas.sh
```

`swift test` runs both `LuloCoreTests` and the macOS-only `LuloImagingTests`. The app scheme has no test targets, so Xcode's Product > Test does not replace this command. The Debug app is at `build/Build/Products/Debug/Lulo.app`. Linux cannot verify AppKit, Image I/O, or the application build.

The preview and benchmark scripts exercise native code and produce evidence under `build/`; see QUICKSTART for their coverage. `package-app.sh` builds both architectures and checks an ad-hoc signed test ZIP at `build/distribution/Lulo-macOS-universal.zip`. This ZIP is for local testing, not an App Store upload. The scripts launch UI, so run them in a logged-in Mac session.

- [ ] Run [lint CI's](.github/workflows/lint.yml) remaining checks:

```sh
npx --yes prettier@3.8.3 --check '**/*.md' '.github/**/*.yml' '.github/scripts/*.cjs' .prettierrc
node --test .github/scripts/comment-pr-build.test.cjs
bash -n tools/package-app.sh
git diff --check
```

The first Prettier run needs npm registry access. Format only changed files with the pinned tool; do not reformat unrelated files to resolve a pre-existing failure.

- [ ] Open `Lulo.xcodeproj`, select the **Lulo** scheme and **My Mac**, and run with **Command-R**. For sandbox testing select a local signing identity/team under the target's **Signing & Capabilities**, preserving `App/Lulo.entitlements`. You can also launch the ad-hoc signed Release app produced above. Paid membership is needed for store distribution, not the unsigned build or package tests.
- [ ] Complete [the interactive macOS checklist](docs/MACOS-VERIFICATION.md). Include Finder opening, folder permission grant/refusal, navigation, gallery, filters, external file changes, corrupt images, orientation/color/transparency, zoom, VoiceOver, and light/dark appearance. Test confirmed Trash and cancellation only with disposable images and verify recovery from Trash. Record failures and retest fixes.

**Checkpoint:** the app compiles, both package test targets pass, native checks run, and a sandboxed app behaves correctly on the Mac. This is the development milestone; release preparation continues below.

## 4. Activate the publishing account

- [ ] Use an Apple Account with two-factor authentication and enroll in the [Apple Developer Program](https://developer.apple.com/help/account/membership/program-enrollment/). Choose individual or organization enrollment based on the intended seller; complete verification and wait for active membership. A free Personal Team cannot publish to the store or use TestFlight distribution.
- [ ] Sign in to [App Store Connect](https://appstoreconnect.apple.com/) and accept outstanding agreements as Account Holder. If charging for the app, complete the Paid Apps Agreement and requested tax/banking details. Confirm the intended price and territories before release.
- [ ] Add the account under **Xcode > Settings > Accounts** and confirm the paid team is available. On a shared team, obtain access to signing resources and the app; uploading and submitting require appropriate roles. The Account Holder can complete the full process.

Keep passwords, certificate private keys, profiles, and API keys out of Git and logs. This manual process does not require signing secrets in GitHub Actions. See Apple's [account roles](https://developer.apple.com/help/app-store-connect/manage-your-team/overview-of-accounts-and-roles/) and [agreements](https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/) guidance.

## 5. Configure the release identity and signing

Select the **Lulo target**, not just the project, in Xcode.

- [ ] Enable **Automatically manage signing** and select the paid team for Debug and Release. Let Xcode manage development and App Store distribution signing assets. Keep the team selection local as required by the project conventions; inspect project diffs before committing.
- [ ] Confirm that your team owns the exact, case-sensitive bundle ID **`com.jiahuei.Lulo`**. Otherwise choose a permanent reverse-domain ID you control and use it in both configurations. Register or confirm the explicit App ID under **Certificates, Identifiers & Profiles > Identifiers** in the [developer account](https://developer.apple.com/account/). Use the same identifier in App Store Connect.
- [ ] Set `CFBundleShortVersionString` and `CFBundleVersion` in **`App/Info.plist`**. They currently contain literal `0.1.0` and `1`; changing only `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION` will not replace those literals. Choose the public version and increment Build for each replacement upload. Verify the processed archive values later.
- [ ] Add **Application Category** (`LSApplicationCategoryType`) to `App/Info.plist`, for example `public.app-category.photography` if Photography is your chosen category. It is currently absent. Match the intended listing; see [Apple's category reference](https://developer.apple.com/documentation/bundleresources/information-property-list/lsapplicationcategorytype).
- [ ] Keep the macOS deployment target at **14.0** unless deliberately changing supported systems. Ensure Release builds both **arm64** and **x86_64**, with **Build Active Architecture Only = No**. Confirm **AppIcon** remains selected for both configurations.
- [ ] Preserve **App Sandbox** and **User Selected File: Read/Write**. Read/write supports the explicit, confirmed Move to Trash action; viewing must leave originals unchanged. Do not add broad filesystem permissions or require Full Disk Access to make testing pass.

Use the **App Store Connect** distribution route. Developer ID signing/notarization is for distribution outside the store; the ad-hoc test packaging script is also a separate route. Never carry `CODE_SIGNING_ALLOWED=NO` into the store archive. See [Apple's distribution guide](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases).

## 6. Finish privacy, support, and artwork

These are release tasks, not features already supplied by this checklist.

- [ ] Audit the shipped code and add **`PrivacyInfo.xcprivacy`** with target membership so it reaches the archived app. The repository currently has none. Inspect required-reason API usage, including `UserDefaults` in preferences and file timestamp access, and declare only the applicable approved reasons. Follow [Apple's required-reason API documentation](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api); do not copy unrelated declarations or treat a manifest as proof of the audit.
- [ ] Publish working HTTPS **Privacy Policy** and **Support** pages that open without login, with a monitored contact route. Describe local image/metadata processing, stored preferences, and confirmed Trash behavior accurately. Add accessible in-app policy/support links, such as in the application menu or About UI, and test them. Apple's [review guidelines, section 5.1.1](https://developer.apple.com/app-store/review/guidelines/#privacy) require an accessible in-app policy link as well as listing metadata.
- [ ] Complete App Store Connect's **App Privacy** answers after auditing the release binary and any dependencies. The current local-only design is a starting point for the audit, not an automatic declaration. The privacy label, manifest, and public policy are separate deliverables. See [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/).
- [ ] Verify the existing Loupe icon in Finder, Dock, About, and the archive, including the 1024-pixel source. Keep the macOS artwork's intended transparent margins; do not apply iOS icon rules to it.
- [ ] Capture the final app with synthetic or licensed images and safe filenames/metadata. Show gallery, image viewing, metadata, and filtering without personal GPS or other private information. Use **Shift-Command-5** or macOS Screenshot, then check actual pixel dimensions against [Apple's Mac screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/). CI previews and README images are not automatically valid store screenshots. Do not stretch them to fit.

## 7. Create and complete the store listing

- [ ] In **App Store Connect > Apps > + > New App**, choose **macOS**, an available app name, primary language, the registered bundle ID, and an internal SKU such as `lulo-macos`. Create the record before upload and save its numeric Apple ID. See [Add a new app](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/).
- [ ] Set the macOS version to match `CFBundleShortVersionString`. Complete description, keywords, copyright, category, screenshots, support URL, and privacy-policy URL. Describe supported formats accurately; do not advertise RAW support or editing.
- [ ] Complete the age-rating questionnaire, content-rights and export-compliance questions, price, availability, and applicable trader-status information. Use the final app's behavior and your distribution circumstances; resolve required fields shown by App Store Connect. Consult [App Store Connect Help](https://developer.apple.com/help/app-store-connect/) for the current forms.
- [ ] Supply reviewer contact details and practical review notes: no account is required; open a supplied sample image; grant its containing folder for navigation/gallery or decline for single-image viewing; Trash requires explicit confirmation. Use disposable samples for that test.
- [ ] Choose **Manually release this version** to retain control of publication after approval.

## 8. Archive, validate, and upload

- [ ] Finish release changes through review, update the Mac checkout to the reviewed commit, and rerun section 3 with the release toolchain. Record any intentional local signing settings. Retain test evidence for macOS 14 and current macOS, and for Apple Silicon and Intel; a universal binary alone is not runtime coverage.
- [ ] In **Product > Scheme > Edit Scheme > Archive**, confirm **Release**. Select the Lulo scheme and an appropriate Mac destination, then **Product > Archive**. With both architectures configured, verify the resulting archive rather than relying on the destination name.
- [ ] Open **Window > Organizer > Archives** and select the new Lulo archive. Confirm the team, bundle ID, version/build, minimum OS, icon, privacy manifest, and sandbox entitlements. Keep the archive and generated debugging symbols. Use **Show in Finder**, then substitute its actual path below:

```sh
LULO_ARCHIVE='/path/to/Lulo.xcarchive'
plutil -p "$LULO_ARCHIVE/Products/Applications/Lulo.app/Contents/Info.plist"
lipo "$LULO_ARCHIVE/Products/Applications/Lulo.app/Contents/MacOS/Lulo" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$LULO_ARCHIVE/Products/Applications/Lulo.app"
codesign --display --entitlements - "$LULO_ARCHIVE/Products/Applications/Lulo.app"
```

Inspect signing output locally; do not paste account identifiers into public logs. Distribution signing can add legitimate signing entitlements beyond the two source entitlements, so do not apply the test ZIP script's exact entitlement-equality assertion to this archive.

- [ ] Use **Validate App** if available and resolve errors. Choose **Distribute App > App Store Connect** and the upload route supporting both **TestFlight and App Store**, with automatic signing. Review Xcode's signing summary. Avoid **TestFlight Internal Only** for the release candidate because it cannot be submitted to the public store. Follow [Apple's distribution guide](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases).
- [ ] Wait for upload and App Store Connect processing. Confirm the exact version/build appears under TestFlight, address processing emails and compliance prompts, and record the final build number if Xcode adjusted it. Upload success is not review approval.

## 9. Test the distributed build

- [ ] Complete TestFlight test information and create an **Internal Testing** group with eligible App Store Connect users, including yourself. Assign the processed build, install **TestFlight for Mac** from the Mac App Store, accept the invitation, and install Lulo. See [Apple's TestFlight workflow](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/).
- [ ] Repeat [interactive verification](docs/MACOS-VERIFICATION.md) on this exact build outside Xcode, especially Finder opening, security-scoped folder access, denied permissions, Trash recovery, image rendering, and accessibility. Check a clean install and upgrades where applicable, using disposable fixtures and preserving data you need. Verify policy/support links.
- [ ] If using external testers, complete beta review requirements; TestFlight review is separate from public App Review. Fix defects, increment Build, upload again, and record results for the final candidate.

## 10. Submit, publish, and verify

- [ ] Select the exact tested build in the macOS version's **Build** section. Confirm all release gates and required metadata are complete. Click **Add for Review**, then open the draft submission and **Submit for Review**; adding the draft alone does not submit it. See [Submit an app](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/).
- [ ] Monitor review messages and respond to findings. Code or bundled-asset fixes require a new tested build; metadata corrections may not. Keep the manual-release choice while resolving review.
- [ ] After approval, check **Pending Developer Release**, the selected build, price, territories, and listing. Choose **Release This Version** when ready. Allow for propagation and consult [Apple's release options](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option/).
- [ ] Verify the public listing and install from the Mac App Store. Repeat basic open, folder navigation, rendering, and disposable-image Trash checks. Confirm the app launches normally without a Gatekeeper bypass.
- [ ] Record the store URL, source commit, app version/build, Xcode version, archive location, and test evidence. Monitor support and crashes. For updates, increment version/build as appropriate, test the upgrade, and repeat the archive/review process. Keep membership, agreements, and public links current.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `xcodebuild` requires Xcode or uses the wrong version | Check `DEVELOPER_DIR`, `xcode-select -p`, and the actual app path; select the full Xcode installation |
| Pinned Xcode will not launch on this Mac | Compare the host OS with Apple's compatibility table; use a supported development environment or verify a newer toolchain |
| Signing or provisioning failure | Check active paid membership, agreements, account permissions, bundle ID ownership, Release team, and Xcode's automatic-signing diagnostics |
| Product > Test does not run the suites | Run `swift test` from the repository root |
| Sandbox navigation or Trash fails | Test a signed build and the intended user-selected grants; do not disable sandboxing or grant Full Disk Access as a workaround |
| Missing category, icon, or privacy declaration | Inspect the archived bundle, source plist/catalog/manifest, and target membership; fix and archive again |
| Duplicate build or no selectable build | Increase the literal build number in `App/Info.plist`; check processing errors, version/ID match, compliance, and Internal Only distribution |
| Approved version is not public | Check manual-release status, availability settings, and propagation |
