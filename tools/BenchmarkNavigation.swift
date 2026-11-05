import Foundation
import ImageIO
import LuloCore
import LuloImaging

/// Measures production session navigation and the supplied full-resolution photo without timing fixture setup.
@main
enum BenchmarkNavigation {
    static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let entries = (0..<2000).reversed().map {
            ImageEntry(url: URL(fileURLWithPath: "/benchmark/photo\($0).jpg"), format: .jpeg)
        }
        var session = ViewingSession()
        session.open(entries[entries.count / 2])
        session.replaceEntries(entries)
        try measure("navigation_and_status_2000_entries", count: 20) {
            session.navigate(1)
            // The viewer reads the ordered list again to update its position indicator.
            guard session.visibleEntries.contains(where: { $0.url == session.selectedURL }) else {
                throw BenchmarkError.invalidSelection
            }
        }
        try measure("photo_decode_full_resolution", count: 8) {
            let image = try ImageLoader.decode(at: url)
            guard image.width == 4085, image.height == 6128 else { throw BenchmarkError.invalidImage }
        }
        try measure("photo_metadata", count: 8) {
            guard try ImageLoader.details(at: url).width == 4085 else { throw BenchmarkError.invalidImage }
        }
        #if !BASELINE
            let store = ImageStore()
            let prefetched = try await store.load(at: url, generation: 1)
            var samples: [Double] = []
            for _ in 0..<20 {
                let start = ContinuousClock.now
                let loaded = try await store.load(at: url, generation: 1)
                guard loaded.image === prefetched.image else { throw BenchmarkError.invalidImage }
                let elapsed = start.duration(to: .now).components
                samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            }
            print(
                "photo_store_warm: milliseconds=\(samples); median=\(samples.sorted()[samples.count / 2]); max=\(samples.max()!)"
            )
            print("photo_store_cached_bytes: \(await store.cachedBytes)")
        #endif
        try measureFolderDiscovery(photo: url)
    }

    private static func measureFolderDiscovery(photo: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("photo0.jpg")
        try FileManager.default.copyItem(at: photo, to: first)
        // Link only the temporary copy: setup is excluded and the committed fixture is untouched.
        for index in 1..<1000 {
            try FileManager.default.linkItem(at: first, to: folder.appendingPathComponent("photo\(index).jpg"))
        }
        try measure("folder_metadata_1000_entries", count: 3) {
            guard try ImageLoader.discover(in: folder).count == 1000 else { throw BenchmarkError.invalidSelection }
        }
        #if !BASELINE
            try measure("folder_cancel_after_one_metadata_read", count: 3) {
                var checks = 0
                do {
                    _ = try ImageLoader.discover(
                        in: folder,
                        isCancelled: {
                            checks += 1
                            return checks == 3
                        })
                    throw BenchmarkError.invalidSelection
                } catch is CancellationError {
                    guard checks == 3 else { throw BenchmarkError.invalidSelection }
                }
            }
        #endif
    }

    private static func measure(_ name: String, count: Int, work: () throws -> Void) rethrows {
        var samples: [Double] = []
        for _ in 0..<count {
            let start = ContinuousClock.now
            try autoreleasepool { try work() }
            let elapsed = start.duration(to: .now).components
            samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        let sorted = samples.sorted()
        print("\(name): milliseconds=\(samples); median=\(sorted[sorted.count / 2]); max=\(sorted.last!)")
    }

    private enum BenchmarkError: Error { case invalidSelection, invalidImage }
}
