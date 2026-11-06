import Foundation
import Testing

@testable import LuloCore

private func entry(_ name: String, rating: Int? = nil, captured: Double? = nil, created: Double? = nil) -> ImageEntry {
    let url = URL(fileURLWithPath: "/synthetic/\(name)")
    return ImageEntry(
        url: url, format: ImageFormat(url: url)!,
        capturedAt: captured.map(Date.init(timeIntervalSince1970:)),
        createdAt: created.map(Date.init(timeIntervalSince1970:)), rating: rating)
}

private func names(_ session: ViewingSession) -> [String] {
    session.visibleEntries.map { $0.url.lastPathComponent }
}

/// Ensures every sort key reverses primary ordering and filename tie-breaks together.
@Test(arguments: SortMethod.allCases)
func sortInBothDirections(_ method: SortMethod) {
    let entries = [
        entry("b.png", rating: 2, captured: 20), entry("a.png", rating: 2, captured: 20),
        entry("c.jpg", rating: 1, captured: 10),
    ]
    var session = ViewingSession(preferences: Preferences(sort: method))
    session.replaceEntries(entries)
    let expected = method == .name ? ["a.png", "b.png", "c.jpg"] : ["c.jpg", "a.png", "b.png"]
    #expect(names(session) == expected)
    session.preferences.ascending = false
    #expect(names(session) == Array(expected.reversed()))
}

/// Ensures capture dates take precedence, creation dates provide fallback, and missing dates sort by filename.
@Test
func timeFallbackAndMissingValues() {
    var session = ViewingSession(preferences: Preferences(sort: .timeTaken))
    session.replaceEntries([
        entry("d.jpg"), entry("b.jpg", created: 20), entry("c.jpg"),
        entry("a.jpg", captured: 20, created: 100), entry("e.jpg", captured: 10),
    ])
    #expect(names(session) == ["e.jpg", "a.jpg", "b.jpg", "c.jpg", "d.jpg"])
    session.preferences.ascending = false
    #expect(names(session) == ["b.jpg", "a.jpg", "e.jpg", "d.jpg", "c.jpg"])
}

/// Ensures missing ratings remain a filename-ordered group after known ratings in either direction.
@Test
func missingRatings() {
    var session = ViewingSession(preferences: Preferences(sort: .rating))
    session.replaceEntries([entry("b.jpg"), entry("a.jpg"), entry("c.jpg", rating: 0), entry("d.jpg", rating: 5)])
    #expect(names(session) == ["c.jpg", "d.jpg", "a.jpg", "b.jpg"])
    session.preferences.ascending = false
    #expect(names(session) == ["d.jpg", "c.jpg", "b.jpg", "a.jpg"])
}

/// Ensures numeric filename ordering is natural and format aliases share one sort/filter type.
@Test
func filenamesAndAliases() {
    var session = ViewingSession()
    session.replaceEntries([entry("photo10.JPG"), entry("photo2.jpeg"), entry("photo1.jpg")])
    #expect(names(session) == ["photo1.jpg", "photo2.jpeg", "photo10.JPG"])
    #expect(ImageFormat(url: URL(fileURLWithPath: "/test.HEIC")) == .heif)
    #expect(ImageFormat(url: URL(fileURLWithPath: "/test.heif")) == .heif)
    #expect(ImageFormat(url: URL(fileURLWithPath: "/test.dng")) == nil)
}

/// Ensures exact ratings and file types intersect and excluding the selection picks the first remaining image.
@Test
func filteringAndSelection() {
    var session = ViewingSession()
    session.open(entry("a.jpg", rating: 5))
    session.replaceEntries([
        entry("a.jpg", rating: 5), entry("b.png", rating: 5), entry("c.png", rating: 3), entry("d.png"),
    ])
    session.filter = ImageFilter(ratings: [5], formats: [.png])
    session.reconcileSelection()
    #expect(names(session) == ["b.png"])
    #expect(session.selectedURL?.lastPathComponent == "b.png")
    session.filter.ratings = [0]
    session.reconcileSelection()
    #expect(names(session) == ["d.png"])
    session.filter.ratings = [4]
    session.reconcileSelection()
    #expect(session.visibleEntries.isEmpty)
    #expect(session.selectedURL == nil)
    session.navigate(1)
    #expect(session.selectedURL == nil)
    session.filter = ImageFilter()
    session.reconcileSelection()
    #expect(session.selectedURL?.lastPathComponent == "a.jpg")
}

/// Ensures checked values combine with OR within each group and AND across groups, including aliases and unrated.
@Test
func multipleFilterSelections() {
    var session = ViewingSession()
    let entries = [
        entry("a.jpg", rating: 4), entry("b.jpeg", rating: 5), entry("c.png", rating: 4),
        entry("d.heic", rating: 5), entry("e.heif", rating: 3), entry("f.png"), entry("g.png", rating: 0),
    ]
    session.open(entries[1])
    session.replaceEntries(entries)
    session.filter = ImageFilter(ratings: [4, 5], formats: [.jpeg, .png])
    session.reconcileSelection()
    #expect(names(session) == ["a.jpg", "b.jpeg", "c.png"])
    #expect(session.selectedURL == entries[1].url)
    session.navigate(1)
    #expect(session.selectedURL == entries[2].url)
    session.navigate(1)
    #expect(session.selectedURL == entries[0].url)

    session.filter.ratings.remove(4)
    session.reconcileSelection()
    #expect(names(session) == ["b.jpeg"])
    #expect(session.selectedURL == entries[1].url)
    session.filter.formats.insert(.heif)
    #expect(names(session) == ["b.jpeg", "d.heic"])
    session.filter.ratings = [0, 3]
    #expect(names(session) == ["e.heif", "f.png", "g.png"])

    session.filter.ratings = []
    #expect(names(session) == entries.map { $0.url.lastPathComponent })
    session.filter.formats = [.heif]
    #expect(names(session) == ["d.heic", "e.heif"])
    session.filter.formats.remove(.heif)
    #expect(names(session) == entries.map { $0.url.lastPathComponent })
    session.filter.ratings = [4, 5]
    #expect(names(session) == ["a.jpg", "b.jpeg", "c.png", "d.heic"])
    session.filter = ImageFilter()
    #expect(names(session) == entries.map { $0.url.lastPathComponent })
}

/// Ensures navigation wraps at both ends, preserves filters/preferences/sidebar, and handles a single match.
@Test
func wrappingNavigation() {
    var session = ViewingSession(preferences: Preferences(sort: .name, ascending: false))
    session.open(entry("b.png", rating: 5))
    session.replaceEntries([entry("a.png", rating: 5), entry("b.png", rating: 5), entry("c.jpg", rating: 5)])
    session.filter = ImageFilter(ratings: [5], formats: [.png])
    session.sidebarVisible = true
    session.navigate(-1)
    #expect(session.selectedURL?.lastPathComponent == "a.png")
    session.navigate(1)
    #expect(session.selectedURL?.lastPathComponent == "b.png")
    #expect(session.filter == ImageFilter(ratings: [5], formats: [.png]))
    #expect(session.sidebarVisible)
    #expect(!session.preferences.ascending)
    session.replaceEntries([entry("b.png", rating: 5)])
    session.navigate(1)
    session.navigate(-1)
    #expect(session.selectedURL?.lastPathComponent == "b.png")
}

/// Ensures saved preferences survive reconstruction and explicit opens while transient session state resets.
@Test
func preferencePersistenceAndSessionReset() throws {
    let name = "LuloTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(Preferences(defaults: defaults) == Preferences())
    let saved = Preferences(display: .actualSize, sort: .rating, ascending: false)
    saved.save(to: defaults)
    var session = ViewingSession(preferences: Preferences(defaults: defaults))
    #expect(session.preferences == saved)
    #expect(session.filter == ImageFilter())
    #expect(!session.sidebarVisible)
    session.filter = ImageFilter(ratings: [4, 5], formats: [.jpeg, .png])
    session.sidebarVisible = true
    let previousGeneration = session.generation
    session.open(entry("new.jpg"))
    #expect(session.generation != previousGeneration)
    #expect(session.preferences == saved)
    #expect(session.filter == ImageFilter())
    #expect(!session.sidebarVisible)
    #expect(session.selectedURL?.lastPathComponent == "new.jpg")
    defaults.set("invalid", forKey: "sortMethod")
    #expect(Preferences(defaults: defaults).sort == .name)
}

/// Ensures mixed missing and present metadata produces a transitive total ordering for every input permutation.
@Test
func missingMetadataOrderIsStable() {
    let a = entry("a.jpg", captured: 30)
    let b = entry("b.jpg")
    let c = entry("c.jpg", captured: 10)
    for input in [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]] {
        var session = ViewingSession(preferences: Preferences(sort: .timeTaken))
        session.replaceEntries(input)
        #expect(names(session) == ["c.jpg", "a.jpg", "b.jpg"])
    }
}

/// Ensures retained ordering refreshes for entry metadata, nested filter/sort changes, replacement, and reopen.
@Test
func retainedOrderTracksEveryInput() {
    var session = ViewingSession(preferences: Preferences(sort: .rating))
    session.open(entry("a.jpg", rating: 1))
    session.replaceEntries([entry("a.jpg", rating: 1), entry("b.jpg", rating: 2)])
    session.updateEntry(entry("a.jpg", rating: 3))
    #expect(names(session) == ["b.jpg", "a.jpg"])
    session.filter.ratings = [2]
    session.reconcileSelection()
    #expect(names(session) == ["b.jpg"])
    session.updateEntry(entry("b.jpg", rating: 4))
    #expect(session.visibleEntries.isEmpty)
    #expect(session.selectedURL == nil)
    session.filter = ImageFilter()
    session.reconcileSelection()
    session.preferences.ascending = false
    #expect(names(session) == ["b.jpg", "a.jpg"])
    session.updateEntry(entry("a.jpg", rating: 5))
    #expect(names(session) == ["a.jpg", "b.jpg"])
    var copy = session
    copy.preferences.sort = .name
    #expect(names(copy) == ["b.jpg", "a.jpg"])
    session.replaceEntries([entry("c.jpg", rating: 5)])
    #expect(names(copy) == ["b.jpg", "a.jpg"])
    #expect(names(session) == ["c.jpg"])
    session.open(entry("new.png"))
    #expect(names(session) == ["new.png"])
    session.open(nil)
    #expect(session.visibleEntries.isEmpty)
}

/// Ensures Trash selects the next image matching multiple ratings/types, wraps, and preserves preferences.
@Test(arguments: [true, false])
func removalPreservesNavigation(_ ascending: Bool) {
    var session = ViewingSession(preferences: Preferences(display: .actualSize, ascending: ascending))
    let first = entry("a.png", rating: 4)
    let middle = entry("b.jpeg", rating: 5)
    let last = entry("c.png", rating: 5)
    let excluded = entry("d.jpg", rating: 1)
    session.open(middle)
    session.replaceEntries([first, middle, last, excluded])
    session.filter = ImageFilter(ratings: [4, 5], formats: [.jpeg, .png])
    session.sidebarVisible = true
    let generation = session.generation
    session.removeEntry(at: middle.url)
    #expect(session.selectedURL == (ascending ? last.url : first.url))
    #expect(names(session) == (ascending ? ["a.png", "c.png"] : ["c.png", "a.png"]))
    session.removeEntry(at: session.selectedURL!)
    #expect(session.selectedURL == (ascending ? first.url : last.url))
    session.removeEntry(at: session.selectedURL!)
    #expect(session.selectedURL == nil)
    #expect(session.visibleEntries.isEmpty)
    #expect(session.entries == [excluded])
    #expect(session.filter == ImageFilter(ratings: [4, 5], formats: [.jpeg, .png]))
    #expect(session.preferences == Preferences(display: .actualSize, ascending: ascending))
    #expect(session.sidebarVisible)
    #expect(session.generation == generation)
    session.filter = ImageFilter()
    session.reconcileSelection()
    #expect(session.selectedURL == excluded.url)
    session.removeEntry(at: excluded.url)
    #expect(session.entries.isEmpty)
    #expect(session.selectedURL == nil)
}

/// Ensures completing a trash operation after navigation does not replace a still-valid selection.
@Test
func removalRetainsAnotherSelection() {
    let first = entry("a.png")
    let second = entry("b.png")
    var session = ViewingSession()
    session.open(second)
    session.replaceEntries([first, second])
    session.removeEntry(at: first.url)
    #expect(session.selectedURL == second.url)
    session.removeEntry(at: first.url)
    #expect(session.entries == [second])
    #expect(session.selectedURL == second.url)
}
