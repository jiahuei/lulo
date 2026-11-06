import Foundation

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

    public init(url: URL, format: ImageFormat, capturedAt: Date? = nil, createdAt: Date? = nil, rating: Int? = nil) {
        self.url = url
        self.format = format
        self.capturedAt = capturedAt
        self.createdAt = createdAt
        self.rating = rating
    }
}

public enum SortMethod: String, CaseIterable, Sendable {
    case name = "Name"
    case timeTaken = "Time Taken"
    case rating = "Star Rating"
    case fileType = "File Type"
}

public enum DisplayDefault: String, CaseIterable, Sendable {
    case fit = "Fit to Window"
    case actualSize = "100%"
}

public struct Preferences: Equatable, Sendable {
    public var display: DisplayDefault
    public var sort: SortMethod
    public var ascending: Bool

    public init(display: DisplayDefault = .fit, sort: SortMethod = .name, ascending: Bool = true) {
        self.display = display
        self.sort = sort
        self.ascending = ascending
    }

    public init(defaults: UserDefaults) {
        display = defaults.string(forKey: "displayDefault").flatMap(DisplayDefault.init(rawValue:)) ?? .fit
        sort = defaults.string(forKey: "sortMethod").flatMap(SortMethod.init(rawValue:)) ?? .name
        ascending = defaults.object(forKey: "sortAscending") as? Bool ?? true
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(display.rawValue, forKey: "displayDefault")
        defaults.set(sort.rawValue, forKey: "sortMethod")
        defaults.set(ascending, forKey: "sortAscending")
    }
}

public struct ImageFilter: Equatable, Sendable {
    public var rating: Int?
    public var format: ImageFormat?

    public init(rating: Int? = nil, format: ImageFormat? = nil) {
        self.rating = rating
        self.format = format
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
            (filter.rating == nil || ($0.rating ?? 0) == filter.rating)
                && (filter.format == nil || $0.format == filter.format)
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
