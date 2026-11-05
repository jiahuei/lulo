import Foundation
import LuloCore
import Testing

@testable import LuloImaging

/// Ensures cancellation skips enumeration entirely, including when the obsolete folder no longer exists.
@Test
func cancelledDiscoveryDoesNotEnumerate() {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    #expect(throws: CancellationError.self) {
        try ImageLoader.discover(in: missing, isCancelled: { true })
    }
}

/// Ensures a session change during one metadata read stops the scan before the remaining files are read or returned.
@Test(arguments: [1, 100])
func discoveryStopsAfterInFlightMetadata(_ count: Int) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for index in 0..<count { try Data().write(to: folder.appendingPathComponent("photo\(index).jpg")) }
    var reads = 0
    let operation = BlockOperation()
    var session = ViewingSession()
    let next = ImageEntry(url: URL(fileURLWithPath: "/new-session/photo.jpg"), format: .jpeg)
    #expect(throws: CancellationError.self) {
        try ImageLoader.discover(
            in: folder, isCancelled: { operation.isCancelled },
            readEntry: { url in
                reads += 1
                // The read has started; opening a new session cancels the enclosing scan operation.
                session.open(next)
                operation.cancel()
                return ImageEntry(url: url, format: .jpeg)
            })
    }
    #expect(reads == 1)
    #expect(session.selectedURL == next.url)
    #expect(session.entries == [next])
}
