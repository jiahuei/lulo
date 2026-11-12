# Real-photo regression fixtures

`DSCF2143-LR-light.jpg` is the unmodified smaller JPEG variant supplied by the repository owner for navigation-performance and metadata regression testing. The owner explicitly authorized publishing the image and all its embedded metadata, including GPS coordinates and altitude, on November 5, 2026. This is a specific exception to the repository's general rule against committing personal photos or metadata.

The smaller variant is 837,172 bytes and retains the same shooting and GPS metadata as the initially supplied image. The image is a 4085 × 6128 JPEG from a Fujifilm X-S20. Tests cover its shooting details, capture-time offset, GPS coordinates, altitude, full-resolution decoding, and unchanged source bytes. The performance tool uses this same fixture; it does not generate or substitute a smaller photo.

## Additional image formats

The repository owner supplied and requested all five `DSCF2180-LR` files and `IMG_0308.heic` for public regression tests on November 12, 2026, including their embedded metadata. These are unmodified copies of the supplied files and another specific exception to the general restriction on personal-photo fixtures.

| File                 | Encoding        | Display dimensions |
| -------------------- | --------------- | ------------------ |
| `DSCF2180-LR-16.bmp` | 16-bit BMP      | 156 × 104          |
| `DSCF2180-LR-24.bmp` | 24-bit BMP      | 156 × 104          |
| `DSCF2180-LR-32.bmp` | 32-bit BMP      | 156 × 104          |
| `DSCF2180-LR.jxl`    | JPEG XL         | 624 × 416          |
| `DSCF2180-LR.webp`   | WebP            | 624 × 416          |
| `IMG_0308.heic`      | HEIC with alpha | 1576 × 2100        |

Tests cover format recognition, full-resolution decoding, thumbnail bounds and aspect ratio, color-space availability, HEIC alpha, folder discovery, and unchanged source bytes. The files retain their original metadata; tests do not print personal metadata. Rendering fidelity and Finder integration still require the interactive macOS checklist.
