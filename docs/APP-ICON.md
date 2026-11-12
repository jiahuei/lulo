# Loupe app icon

The artwork comes from the owner's [issue #19 attachment](https://github.com/jiahuei/lulo/issues/19). The editable master is [artwork/lulo-icon.svg](artwork/lulo-icon.svg); the supplied PNG exports and catalog manifests are preserved in `App/Assets.xcassets/AppIcon.appiconset`.

The icon shows a dark loupe over a contact sheet with a mountain scene through the lens. It uses the D9 palette: blues `#4C94FF` / `#B9D8FF`, ink `#101213`, and surface `#ECEDEF`. The 1024-pixel canvas has an 824-pixel rounded-square body at (100, 100), its own shadow, and transparent outer margins. Preserve that geometry and transparency when exporting; do not add another mask or shadow.

The Lulo target includes `App/Assets.xcassets` in its Resources phase and selects `AppIcon` in both Debug and Release. Xcode compiles the catalog and merges the icon metadata into the built Info.plist through [ASSETCATALOG_COMPILER_APPICON_NAME](https://help.apple.com/xcode/mac/current/en.lproj/itcaec37c2a6.html). No manual icon entry in `App/Info.plist` or separate checked-in ICNS is needed.

## Updating the artwork

Edit the SVG master, then regenerate all ten macOS slots from the repository root with librsvg's `rsvg-convert` installed:

```sh
for points in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((points * scale))
    suffix=""
    if [ "$scale" -eq 2 ]; then suffix="@2x"; fi
    rsvg-convert -w "$pixels" -h "$pixels" docs/artwork/lulo-icon.svg \
      -o "App/Assets.xcassets/AppIcon.appiconset/icon_${points}x${points}${suffix}.png"
  done
done
```

Keep `Contents.json` aligned with these filenames. Review the exports at native sizes and rebuild using [QUICKSTART.md](../QUICKSTART.md). `bash tools/package-app.sh` checks the delivered app's icon metadata and decodes its compiled ICNS with `iconutil`. Complete the Finder, Dock, and About-panel checks in [macOS verification](MACOS-VERIFICATION.md) on a Mac.
