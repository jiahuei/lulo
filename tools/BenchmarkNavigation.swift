import Foundation
import ImageIO
import LuloCore
import LuloImaging

/// Measures production session navigation and the supplied full-resolution photo without timing fixture setup.
@main
enum BenchmarkNavigation {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let entries = (0..<2000).reversed().map {
            ImageEntry(url: URL(fileURLWithPath: "/benchmark/photo\($0).jpg"), format: .jpeg)
        }
        var session = ViewingSession()
        session.open(entries[0])
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
