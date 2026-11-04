# Initial viewer behavior

Lulo is a read-only, native macOS 14+ image viewer implementing [issue #2](https://github.com/jiahuei/lulo/issues/2). It has no editing, catalog, account, analytics, network, or cloud functionality. Metadata and ratings are embedded-image data only; sidecars and RAW decoding are outside this version.

## Opening and navigation

Finder and File > Open reuse one viewer window. The initial window fills the screen's available work area as a normal window, without entering macOS full-screen mode. Opening a file resets filters, collapses metadata, and restores the saved display default. The display default, sort method, and sort direction persist in UserDefaults. Arrow navigation retains sorting, filters, and sidebar visibility; each selected image starts at the saved display default.

JPEG (including JPG), PNG, and HEIF (including HEIC) are supported. A direct RAW open produces an unsupported-format message. The app requests the containing folder before enumerating siblings. Canceling leaves the directly opened image viewable; File > Allow Folder Navigation can request access again. Grants last for the process lifetime or until replaced, with ongoing work retaining its own grant. There are no persisted bookmarks. Discovery is nonrecursive, excludes hidden files and symbolic links, and retains unreadable supported files so errors do not remove navigation choices. The directly opened file remains in the session even if discovery skips it.

Left/right arrows on the image, Previous/Next buttons, and Command-[ / Command-] navigate with wrapping. Use the menu shortcuts when a filter or metadata text control has keyboard focus. Missing, corrupt, unsupported, and inaccessible files produce recoverable messages.

## Display

Fit to Window is the initial saved default. It preserves aspect ratio, shows the entire image, and leaves unused viewport space. The Default image zoom control changes the saved default to fit or 100%. At 100%, one decoded source pixel occupies one backing pixel, independent of print DPI. Backing conversions are recalculated for the current view when resizing or moving between displays. macOS scaled display modes may further transform backing pixels before physical display output.

Scrolling upward over the image increases zoom; downward decreases it. Natural-scroll device direction is normalized. Double-click first selects 100%; the next double-click restores the saved default. With a 100% default both destinations are 100%. Manual scrolling starts a new double-click pair. Drag an oversized image to pan; pan is constrained to its edges. Temporary zoom is limited to 1%–3200%.

Image I/O applies orientation during decoding; Core Graphics draws the resulting image with its color space and alpha. A serial queue and a 64-megapixel input limit bound concurrent decoding and retained image memory. Larger images show a recoverable limit message rather than silently substituting a reduced-resolution image at 100%. A typical 8-bit RGBA image at this limit occupies about 256 MiB; Image I/O working memory and display buffers are additional. No decoded cache or prefetch is maintained. Canceled queued loads are skipped, and completed loads must match the latest request before changing presentation.

## Sorting and filtering decisions

- Initial order is ascending natural filename order (`photo2` before `photo10`). Filename comparison uses the user's locale, with a literal URL fallback for otherwise equal names.
- Sort choices are Name, Time Taken, Star Rating, and File Type. File Type groups JPEG aliases and HEIF aliases together.
- Descending reverses both primary values and filename tie-breaks.
- Time Taken uses embedded Date Time Original, then file creation time. Embedded timezone offsets are honored; timestamps without offsets are compared as UTC wall-clock values rather than guessed local zones.
- Files without the selected date/rating metadata form a group after known values in both directions. Within that group filenames determine order. This produces a transitive sort rather than a pairwise filename fallback that can contradict timestamp ordering.
- Star filters match an exact rating. Unrated / 0 Stars includes absent, unsupported, and zero embedded ratings. Recognized XMP ratings are integers from 0 through 5; rejected/invalid ratings are treated as unrated.
- Rating and file-type filters combine with AND. Each control initially includes all values.
- Filtering retains the selected image if it still matches; otherwise it selects the first image in the new ordered set. With no matches, the viewer displays “No images match the current filters.” Clearing filters selects the first image if the selection was empty.

## Metadata

The sidebar starts collapsed and displays available values in these read-only groups:

| Group | Fields |
| --- | --- |
| File | File Name, File Path, File Dimensions, Current Dimensions |
| Timestamps | Date Time Original, Date Time Digitized, Date Time |
| Exposure | Exposure (shutter speed and aperture), Focal Length, Focal Length 35mm, Brightness Value, Exposure Bias, ISO Speed Rating, Flash, Exposure Program, Metering Mode |
| Camera and lens | Make, Model, Serial Number, Lens |
| Attribution and comments | Artist, Software, User Comment |
| Location | GPS, Altitude, Direction |

Missing fields are omitted. Dimensions are orientation-adjusted source dimensions, not the zoomed viewport size. Current Dimensions matches File Dimensions because editing is unsupported. Flash, exposure program, and metering mode currently display embedded numeric codes. The screenshot referenced in issue #2 supplied only the field list; its image and personal metadata are not fixtures.

## Architecture and platform references

`LuloCore` owns value types for preferences, session selection, sorting/filtering, and zoom. `LuloImaging` uses Foundation and Image I/O for metadata, decoding, directory discovery, and security-scoped access. The AppKit application owns the single window, native controls, permission panels, rendering, and a serial operation queue. UI state stays on the main actor. Session generations reject old folder scans; request identifiers reject old image loads.

There are no external package dependencies or copied upstream application sources. These native APIs inform the implementation:

- [Apple: accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Apple: balanced security-scoped resource access](<https://developer.apple.com/documentation/foundation/nsurl/startaccessingsecurityscopedresource()>)
- [Apple: Image I/O image sources and transformed thumbnails](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/ImageIOGuide/imageio_source/ikpg_source.html)
- [Apple: backing scale and coordinate conversions](https://developer.apple.com/documentation/appkit/nswindow/backingscalefactor)
- [Apple: Xcode toolchain requirements](https://developer.apple.com/xcode/system-requirements/)
