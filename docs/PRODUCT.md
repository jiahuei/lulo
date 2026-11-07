# Initial viewer behavior

Lulo is a native macOS 14+ image viewer implementing [issue #2](https://github.com/jiahuei/lulo/issues/2). It has no editing, catalog, account, analytics, network, or cloud functionality. Metadata and ratings are embedded-image data only; sidecars and RAW decoding are outside this version.

## Opening and navigation

Finder and File > Open reuse one viewer window. The initial window fills the screen's available work area as a normal window, without entering macOS full-screen mode. Opening a file resets filters, collapses metadata, and restores the saved display default. The display default, sort method, and sort direction persist in UserDefaults. Arrow navigation retains sorting, filters, and sidebar visibility; each selected image starts at the saved display default.

JPEG (including JPG), PNG, and HEIF (including HEIC) are supported. A direct RAW open produces an unsupported-format message. The app requests the containing folder before enumerating siblings. Canceling leaves the directly opened image viewable; File > Allow Folder Navigation can request access again. Grants last for the process lifetime or until replaced, with ongoing work retaining its own grant. There are no persisted bookmarks. Discovery is nonrecursive, excludes hidden files and symbolic links, and retains unreadable supported files so errors do not remove navigation choices. The directly opened file remains in the session even if discovery skips it.

Left/right arrows on the image, toolbar navigation buttons, and Command-[ / Command-] navigate with wrapping. Use the menu shortcuts when a filter or metadata text control has keyboard focus. Missing, corrupt, unsupported, and inaccessible files produce recoverable messages.

## Moving images to Trash

Move to Trash is available from the toolbar and File menu (Command-Delete) for the currently displayed image. A confirmation names the image, with Cancel as the default. The action is unavailable in gallery mode, while loading, during another Trash operation, while a sheet is open, or without a displayed image. It moves one image to the macOS Trash; there is no permanent-delete fallback, bulk action, or in-app undo. Recover trashed images in Finder.

After success, the next image in the current filtered/sorted order becomes selected, wrapping at the end. If no images remain, the viewer offers Open Image; if filters exclude the remaining entries, Clear Filters remains available. A failed operation reports an error and retains the current selection. Navigation and new opens remain usable during the background operation, whose completion cannot replace another session. Obsolete folder scans cannot reintroduce a trashed entry.

The sandbox grants read/write access only to user-selected files and folders to support this explicit action. Opening and viewing never write image contents or metadata. The Trash operation retains its access grant through completion and rejects directories and symbolic links, including those with image extensions.

## Interface

The image occupies the main workspace. A native unified toolbar contains icon-only Open (image), Gallery (grid), Previous/Next, Sort & Filter (circled decreasing lines), Metadata, and Move to Trash buttons, plus a two-segment saved zoom toggle with a fit-to-window icon and 100%. Icon buttons retain descriptive tooltips and accessibility labels. System fonts and semantic colors follow macOS light/dark appearance. The window title identifies the selected file or, in gallery mode, the folder.

Gallery (also View > Toggle Gallery or Command-G) switches between the image viewer and a scrollable thumbnail grid of the authorized folder. If folder access was declined, Gallery requests it again; canceling keeps the single-image viewer. The grid follows the same sort and filters, shows filenames, and keeps the current selection. Embedded ratings appear as one to five filled gold stars over the upper-left of each thumbnail image, including portrait images. Zero or missing ratings show no stars; there are no empty star placeholders. Ratings are read-only and included in the thumbnail accessibility label. Click or use arrow keys to select; double-click or press Return to view that image. The Gallery button returns to the overview with the image selected and scrolled into view. Returning to the image viewer restores the saved zoom default and the previous metadata-sidebar visibility. Zoom, metadata, and Move to Trash controls are disabled in gallery mode. A new explicit file open returns to the image viewer and resets the session as usual.

Thumbnail decoding runs serially off the main actor, separately from full-resolution image loading. Image I/O fits each preview within 320 by 320 pixels while retaining orientation, aspect ratio, alpha, and color information; the same 64-megapixel source limit applies. Only visible collection items request thumbnails. Cells release their previews and cancel pending requests when they leave view, the grid reloads, or gallery mode closes; reused cells reject old results. A separate least-recently-used cache retains up to 1 GiB of decoded thumbnail pixels, without an image-count limit. Cached previews survive scrolling, sorting/filter changes, switching views, and opening other files; every revisit checks file size and modification time before reuse. Completed decodes remain reusable when the original cell cancels, while canceled queued requests skip decoding. Cache entries retain pixels rather than file-access grants; each request retains its current grant until completion. A failed preview keeps its filename and shows Preview unavailable, and the image can still be opened to show the normal recoverable error. No matching images offers Clear Filters.

Sort & Filter opens a transient popover with labeled sort and direction controls plus rating and file-type checkboxes. Rating choices occupy two equal-width columns, ordered downward: Unrated / 0 Stars, 1 Star, and 2 Stars on the left; 3 Stars, 4 Stars, and 5 Stars on the right. Changes apply immediately. The Sort & Filter button reports the number of active filter groups in its tooltip and accessibility label, and the status bar names those filters beside the image position. Clear Filters is available both in Sort & Filter and in the no-matches state. New explicit opens dismiss Sort & Filter and return keyboard focus to the image.

The initial empty state offers Open Image, cache misses use a compact translucent loading box with a native spinner and the incoming filename, and failed image loads offer Open Another Image. Cached next and previous images skip the loading overlay, including images already decoded by prefetch. Navigation retains the previous image and its zoom/pan while checking the cache or decoding, then swaps in the completed image at the saved display default. A new selection dismisses any previous loading overlay; only a current request that needs decoding can show it again. Late loading notifications cannot cover an already displayed image or a newer selection. Metadata is cleared while loading so it cannot be mistaken for the incoming file. Errors and empty filters clear the retained image. Long loading filenames truncate in the middle, with the full name available to accessibility and a tooltip. The metadata inspector uses distinct group headings, secondary field labels, and selectable values with wrapping for long paths/comments. Its width is 300 points; the viewer supports windows down to 720 points wide.

The design/development pass used [nice-skills design-research](https://github.com/EmbeddedLLM/nice-skills/tree/a11b1778ac52bd3fd08bc68290ecb09fcadb3b77/skills/design-research) and [software-workflow](https://github.com/EmbeddedLLM/nice-skills/tree/a11b1778ac52bd3fd08bc68290ecb09fcadb3b77/skills/software-workflow). The relevant guidance was actionable empty states, visible focus, labeled controls, and preserving the established platform. The catalog does not cover AppKit; native integration follows [Apple's toolbar guidance](https://developer.apple.com/design/human-interface-guidelines/toolbars). No skill scripts or dependencies run inside Lulo.

## Display

Fit to Window is the initial saved default. It preserves aspect ratio, shows the entire image, and leaves unused viewport space. The Default image zoom toggle shows the saved choice and changes it directly to fit or 100%, applying the new default to the current image. Temporary scroll or double-click zoom does not change the toggle's saved selection. At 100%, one decoded source pixel occupies one backing pixel, independent of print DPI. Backing conversions are recalculated for the current view when resizing or moving between displays. macOS scaled display modes may further transform backing pixels before physical display output.

Scrolling upward over the image increases zoom; downward decreases it. Natural-scroll device direction is normalized. Double-click first selects 100%; the next double-click restores the saved default. With a 100% default both destinations are 100%. Manual scrolling starts a new double-click pair. Drag an oversized image to pan; pan is constrained to its edges. Temporary zoom is limited to 1%–3200%.

Image I/O applies orientation during decoding; Core Graphics draws the resulting image with its color space and alpha. A serial image-store actor keeps decoding off the main actor, separate from folder metadata discovery. Obsolete scans check cancellation before directory listing, before and after each metadata read, and before returning results. Opening another session cancels the scan and rejects any already-queued completion; its security-scoped grant stays alive until the worker exits. An in-progress directory listing or individual Image I/O metadata read must finish before its next cancellation check. A 64-megapixel input limit bounds each decode; larger images show a recoverable limit message rather than silently substituting reduced resolution at 100%.

Navigation retains the filtered/sorted order until entries, filtering, or sort preferences change. A least-recently-used cache retains at most ten full-resolution images and at most 1 GiB of decoded pixel buffers; metadata is retained alongside each image. Revisits check file size and modification time before reuse; explicit opens start a new cache generation. One adjacent image in the current navigation direction is prefetched only within authorized files. Changing direction, filters, sorting, or opening a new image cancels obsolete queued prefetch work. An already-running Image I/O decode cannot be interrupted; its result can populate the cache but cannot replace a newer selection.

The two independent cache budgets allow up to 2 GiB of retained decoded pixels in total. They exclude displayed images/thumbnails when evicted, active decodes, metadata and cache bookkeeping, Image I/O working memory, and display buffers. A typical 8-bit RGBA image at the input limit occupies about 256 MiB. Prefetch failures remain silent until that file is selected, when the usual recoverable error is shown. Full-resolution pixel data and metadata are unchanged by reuse. Both caches are memory-only and share strict byte accounting, least-recently-used eviction, and file validation.

## Sorting and filtering decisions

- Initial order is ascending natural filename order (`photo2` before `photo10`). Filename comparison uses the user's locale, with a literal URL fallback for otherwise equal names.
- Sort choices are Name, Time Taken, Star Rating, and File Type. File Type groups JPEG aliases and HEIF aliases together.
- Descending reverses both primary values and filename tie-breaks.
- Time Taken uses embedded Date Time Original, then file creation time. Embedded timezone offsets are honored; timestamps without offsets are compared as UTC wall-clock values rather than guessed local zones.
- Files without the selected date/rating metadata form a group after known values in both directions. Within that group filenames determine order. This produces a transitive sort rather than a pairwise filename fallback that can contradict timestamp ordering.
- Star checkboxes match exact ratings; multiple checked ratings combine with OR. Unrated / 0 Stars includes absent, unsupported, and zero embedded ratings. Recognized XMP ratings are integers from 0 through 5; rejected/invalid ratings are treated as unrated.
- File-type checkboxes allow any combination of JPEG, PNG, and HEIF. Multiple checked types combine with OR.
- Rating and file-type groups combine with AND. Each group starts unchecked, meaning all values; unchecking the last value also removes that group's restriction. Clear Filters unchecks both groups. The toolbar counts active groups, and the status bar lists checked values in rating/type order.
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

`LuloCore` owns value types for preferences, session selection, sorting/filtering, and zoom. `LuloImaging` uses Foundation and Image I/O for metadata, decoding, directory discovery, and security-scoped access. The AppKit application owns the single window, native controls, permission panels, rendering, a background folder-discovery queue, and a serial image-store actor. UI state stays on the main actor. Session generations reject old folder scans; request identifiers reject old image loads.

There are no external package dependencies or copied upstream application sources. These native APIs inform the implementation:

- [Apple: accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Apple: balanced security-scoped resource access](<https://developer.apple.com/documentation/foundation/nsurl/startaccessingsecurityscopedresource()>)
- [Apple: Image I/O image sources and transformed thumbnails](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/ImageIOGuide/imageio_source/ikpg_source.html)
- [Apple: backing scale and coordinate conversions](https://developer.apple.com/documentation/appkit/nswindow/backingscalefactor)
- [Apple: Xcode toolchain requirements](https://developer.apple.com/xcode/system-requirements/)
