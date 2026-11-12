import Foundation

public enum ImageFormat: String, CaseIterable, Sendable {
    case jpeg = "JPEG"
    case png = "PNG"
    case heif = "HEIF"
    case bmp = "BMP"
    case jpegXL = "JPEG XL"
    case webP = "WebP"

    public init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": self = .jpeg
        case "png": self = .png
        case "heic", "heif": self = .heif
        case "bmp": self = .bmp
        case "jxl": self = .jpegXL
        case "webp": self = .webP
        default: return nil
        }
    }
}

public struct ImageEntry: Equatable, Sendable {
    public let url: URL
    public let format: ImageFormat
    public let capturedAt: Date?
    public let createdAt: Date?
    public let rating: Int?
    public let pixelSize: CGSize?

    public init(
        url: URL, format: ImageFormat, capturedAt: Date? = nil, createdAt: Date? = nil,
        rating: Int? = nil, pixelSize: CGSize? = nil
    ) {
        self.url = url
        self.format = format
        self.capturedAt = capturedAt
        self.createdAt = createdAt
        self.rating = rating
        self.pixelSize = pixelSize
    }
}

public enum SortMethod: String, CaseIterable, Sendable {
    case name = "Name"
    case timeTaken = "Time Taken"
    case rating = "Star Rating"
    case fileType = "File Type"
}

public struct Preferences: Equatable, Sendable {
    public var sort: SortMethod
    public var ascending: Bool
    public var blurredBackground: Bool
    public var galleryLayout: GalleryLayout
    public var rowsTargetHeight: Double
    public var previewTileSize: Double

    public init(
        sort: SortMethod = .name, ascending: Bool = true,
        blurredBackground: Bool = false, galleryLayout: GalleryLayout = .preview,
        rowsTargetHeight: Double = 200, previewTileSize: Double = 128
    ) {
        self.sort = sort
        self.ascending = ascending
        self.blurredBackground = blurredBackground
        self.galleryLayout = galleryLayout
        self.rowsTargetHeight = GalleryLayout.rows.snappedSize(rowsTargetHeight)
        self.previewTileSize = GalleryLayout.preview.snappedSize(previewTileSize)
    }

    public init(defaults: UserDefaults) {
        sort = defaults.string(forKey: "sortMethod").flatMap(SortMethod.init(rawValue:)) ?? .name
        ascending = defaults.object(forKey: "sortAscending") as? Bool ?? true
        blurredBackground = defaults.bool(forKey: "blurredBackground")
        galleryLayout = defaults.string(forKey: "galleryLayout").flatMap(GalleryLayout.init(rawValue:)) ?? .preview
        rowsTargetHeight = GalleryLayout.rows.snappedSize(defaults.object(forKey: "rowsTargetHeight") as? Double ?? 200)
        previewTileSize = GalleryLayout.preview.snappedSize(
            defaults.object(forKey: "previewTileSize") as? Double ?? 128)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(sort.rawValue, forKey: "sortMethod")
        defaults.set(ascending, forKey: "sortAscending")
        defaults.set(blurredBackground, forKey: "blurredBackground")
        defaults.set(galleryLayout.rawValue, forKey: "galleryLayout")
        defaults.set(rowsTargetHeight, forKey: "rowsTargetHeight")
        defaults.set(previewTileSize, forKey: "previewTileSize")
    }
}

/// Checked values in each group; an empty set leaves that group unrestricted.
public struct ImageFilter: Equatable, Sendable {
    public var ratings: Set<Int>
    public var formats: Set<ImageFormat>

    public var activeCount: Int { ratings.count + formats.count }

    public init(ratings: Set<Int> = [], formats: Set<ImageFormat> = []) {
        self.ratings = ratings
        self.formats = formats
    }
}

public struct ViewingSession: Sendable {
    public var preferences: Preferences {
        didSet {
            if preferences.sort != oldValue.sort || preferences.ascending != oldValue.ascending {
                rebuildVisibleEntries()
            }
        }
    }
    public var filter = ImageFilter() {
        didSet { if filter != oldValue { rebuildVisibleEntries() } }
    }
    public var sidebarVisible = false
    public private(set) var entries: [ImageEntry] = []
    public private(set) var selectedURL: URL?
    public private(set) var generation = 0

    public init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
    }

    // Navigation and status reads share the same order; only its inputs trigger sorting.
    public private(set) var visibleEntries: [ImageEntry] = []

    private mutating func rebuildVisibleEntries() {
        visibleEntries = entries.filter {
            (filter.ratings.isEmpty || filter.ratings.contains($0.rating ?? 0))
                && (filter.formats.isEmpty || filter.formats.contains($0.format))
        }.sorted { left, right in
            let comparison: ComparisonResult
            switch preferences.sort {
            case .name: comparison = .orderedSame
            case .fileType: comparison = left.format.rawValue.compare(right.format.rawValue)
            case .rating:
                comparison = compareOptional(left.rating, right.rating)
            case .timeTaken:
                comparison = compareOptional(left.capturedAt ?? left.createdAt, right.capturedAt ?? right.createdAt)
            }
            // A fixed missing-value group keeps the comparator transitive. Pairwise filename
            // fallback between dated and undated files can create cycles in the ordering.
            let leftMissing = isMissingSortValue(left)
            let rightMissing = isMissingSortValue(right)
            if leftMissing != rightMissing { return !leftMissing }
            var result = comparison
            if result == .orderedSame {
                result = left.url.lastPathComponent.localizedStandardCompare(right.url.lastPathComponent)
                if result == .orderedSame { result = left.url.absoluteString.compare(right.url.absoluteString) }
            }
            return preferences.ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    public mutating func open(_ entry: ImageEntry?) {
        generation += 1
        entries = entry.map { [$0] } ?? []
        selectedURL = entry?.url
        filter = ImageFilter()
        visibleEntries = entries
        sidebarVisible = false
    }

    public mutating func replaceEntries(_ entries: [ImageEntry]) {
        self.entries = entries
        rebuildVisibleEntries()
        reconcileSelection()
    }

    public mutating func updateEntry(_ entry: ImageEntry) {
        guard let index = entries.firstIndex(where: { $0.url == entry.url }), entries[index] != entry else { return }
        entries[index] = entry
        rebuildVisibleEntries()
        reconcileSelection()
    }

    /// Removes an entry only after its file was successfully trashed, keeping the next visible image selected.
    public mutating func removeEntry(at url: URL) {
        let removedIndex = visibleEntries.firstIndex(where: { $0.url == url })
        let wasSelected = selectedURL == url
        entries.removeAll { $0.url == url }
        rebuildVisibleEntries()
        if wasSelected, let removedIndex, !visibleEntries.isEmpty {
            selectedURL = visibleEntries[removedIndex % visibleEntries.count].url
        }
        reconcileSelection()
    }

    public mutating func reconcileSelection() {
        let visible = visibleEntries
        if !visible.contains(where: { $0.url == selectedURL }) { selectedURL = visible.first?.url }
    }

    public mutating func navigate(_ delta: Int) {
        let visible = visibleEntries
        guard !visible.isEmpty else {
            selectedURL = nil
            return
        }
        let index = visible.firstIndex(where: { $0.url == selectedURL }) ?? 0
        selectedURL = visible[((index + delta) % visible.count + visible.count) % visible.count].url
    }

    public mutating func select(_ url: URL) {
        guard visibleEntries.contains(where: { $0.url == url }) else { return }
        selectedURL = url
    }

    private func isMissingSortValue(_ entry: ImageEntry) -> Bool {
        switch preferences.sort {
        case .rating: return entry.rating == nil
        case .timeTaken: return entry.capturedAt == nil && entry.createdAt == nil
        default: return false
        }
    }
}

private func compareOptional<Value: Comparable>(_ left: Value?, _ right: Value?) -> ComparisonResult {
    guard let left, let right else { return .orderedSame }
    return left == right ? .orderedSame : left < right ? .orderedAscending : .orderedDescending
}
