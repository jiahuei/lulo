import Foundation

// Apple's geometry types live in CoreGraphics; Linux Foundation provides them directly.
#if canImport(CoreGraphics)
    import CoreGraphics
#endif

public enum ImageFormat: String, CaseIterable, Sendable {
    case jpeg = "JPEG"
    case png = "PNG"
    case heif = "HEIF"

    public init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": self = .jpeg
        case "png": self = .png
        case "heic", "heif": self = .heif
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
    /// Orientation-adjusted pixel size, read during discovery so gallery layout needs no extra file access.
    public let pixelSize: CGSize?

    public init(
        url: URL, format: ImageFormat, capturedAt: Date? = nil, createdAt: Date? = nil, rating: Int? = nil,
        pixelSize: CGSize? = nil
    ) {
        self.url = url
        self.format = format
        self.capturedAt = capturedAt
        self.createdAt = createdAt
        self.rating = rating
        self.pixelSize = pixelSize
    }

    /// Width over height, with a 3:2 placeholder for unreadable files whose size is unknown.
    public var aspectRatio: Double {
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else { return 1.5 }
        return Double(pixelSize.width / pixelSize.height)
    }
}

public enum SortMethod: String, CaseIterable, Sendable {
    case name = "Name"
    case timeTaken = "Time Taken"
    case rating = "Star Rating"
    case fileType = "File Type"
}

public enum GalleryLayout: String, CaseIterable, Sendable {
    /// Justified rows of images at their own aspect ratios; the size is the target row height.
    case rows
    /// A large preview beside a square grid; the size is the minimum tile edge.
    case preview

    public var sizeRange: ClosedRange<Double> { self == .rows ? 120...300 : 88...220 }
    public var sizeStep: Double { self == .rows ? 10 : 6 }
    public var defaultSize: Double { self == .rows ? 200 : 128 }

    /// Every selectable size, ascending. Steps are counted from the default because Preview's default (128) is
    /// not a multiple of 6 from 88; both ends of the range are added so they stay reachable.
    public var sizes: [Double] {
        let first = Int(((sizeRange.lowerBound - defaultSize) / sizeStep).rounded(.up))
        let last = Int(((sizeRange.upperBound - defaultSize) / sizeStep).rounded(.down))
        let steps = (first...last).map { defaultSize + Double($0) * sizeStep }
        return Array(Set([sizeRange.lowerBound, sizeRange.upperBound] + steps)).sorted()
    }

    /// Snaps a size to the nearest selectable size within this layout's range.
    public func clampedSize(_ size: Double) -> Double {
        guard size.isFinite else { return defaultSize }
        return sizes.min { abs($0 - size) < abs($1 - size) } ?? defaultSize
    }

    /// The selectable size the given number of steps away, stopping at either end of the range.
    public func adjustedSize(_ size: Double, steps: Int) -> Double {
        let values = sizes
        let index = values.firstIndex(of: clampedSize(size)) ?? 0
        return values[min(values.count - 1, max(0, index + steps))]
    }
}

public struct Preferences: Equatable, Sendable {
    public var sort: SortMethod
    public var ascending: Bool
    public var blurredBackground = false
    public var galleryLayout = GalleryLayout.rows
    public private(set) var rowHeight = GalleryLayout.rows.defaultSize
    public private(set) var tileSize = GalleryLayout.preview.defaultSize

    public init(sort: SortMethod = .name, ascending: Bool = true) {
        self.sort = sort
        self.ascending = ascending
    }

    public init(defaults: UserDefaults) {
        sort = defaults.string(forKey: "sortMethod").flatMap(SortMethod.init(rawValue:)) ?? .name
        ascending = defaults.object(forKey: "sortAscending") as? Bool ?? true
        blurredBackground = defaults.object(forKey: "blurredBackground") as? Bool ?? false
        galleryLayout = defaults.string(forKey: "galleryLayout").flatMap(GalleryLayout.init(rawValue:)) ?? .rows
        for layout in GalleryLayout.allCases {
            if let size = defaults.object(forKey: Self.sizeKey(layout)) as? Double {
                setThumbnailSize(size, for: layout)
            }
        }
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(sort.rawValue, forKey: "sortMethod")
        defaults.set(ascending, forKey: "sortAscending")
        defaults.set(blurredBackground, forKey: "blurredBackground")
        defaults.set(galleryLayout.rawValue, forKey: "galleryLayout")
        for layout in GalleryLayout.allCases {
            defaults.set(thumbnailSize(for: layout), forKey: Self.sizeKey(layout))
        }
    }

    /// Each layout keeps its own size so switching layouts restores the size last used there.
    public func thumbnailSize(for layout: GalleryLayout) -> Double {
        layout == .rows ? rowHeight : tileSize
    }

    public mutating func setThumbnailSize(_ size: Double, for layout: GalleryLayout) {
        let size = layout.clampedSize(size)
        if layout == .rows { rowHeight = size } else { tileSize = size }
    }

    private static func sizeKey(_ layout: GalleryLayout) -> String {
        layout == .rows ? "galleryRowHeight" : "galleryTileSize"
    }
}

/// Checked values in each group; an empty set leaves that group unrestricted.
public struct ImageFilter: Equatable, Sendable {
    public var ratings: Set<Int>
    public var formats: Set<ImageFormat>

    public init(ratings: Set<Int> = [], formats: Set<ImageFormat> = []) {
        self.ratings = ratings
        self.formats = formats
    }

    /// The number of ticked checkboxes; checking every value in a group still counts each one.
    public var activeCount: Int { ratings.count + formats.count }
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
