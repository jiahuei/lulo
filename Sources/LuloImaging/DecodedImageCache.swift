import Foundation

/// Shared storage for actor-owned decoded images; budgets count pixel buffers, not file sizes.
struct DecodedImageCache<Value: Sendable> {
    let byteLimit: Int
    let countLimit: Int
    private(set) var cachedBytes = 0
    private var entries: [Entry] = []

    init(byteLimit: Int, countLimit: Int = .max) {
        self.byteLimit = max(0, byteLimit)
        self.countLimit = countLimit
    }

    mutating func removeAll() {
        entries.removeAll()
        cachedBytes = 0
    }

    mutating func load(at url: URL, decode: () throws -> Value, byteCost: (Value) -> Int) throws -> Value {
        let stamp: FileStamp
        do { stamp = try FileStamp(url: url) } catch { throw ImageLoadError.unreadable }
        if let index = entries.firstIndex(where: { $0.url == url }) {
            let previous = entries.remove(at: index)
            if previous.stamp == stamp {
                entries.append(previous)
                return previous.value
            }
            cachedBytes -= previous.cost
        }
        let value = try autoreleasepool { try decode() }
        let cost = byteCost(value)
        // NSCache's cost limit is advisory; eviction here enforces both budgets exactly.
        if cost <= byteLimit {
            while !entries.isEmpty && (cachedBytes + cost > byteLimit || entries.count >= countLimit) {
                cachedBytes -= entries.removeFirst().cost
            }
            entries.append(Entry(url: url, stamp: stamp, value: value, cost: cost))
            cachedBytes += cost
        }
        return value
    }

    private struct Entry {
        let url: URL
        let stamp: FileStamp
        let value: Value
        let cost: Int
    }
}

struct FileStamp: Equatable {
    let modified: Date?
    let size: UInt64?
    let fileNumber: UInt64?

    init(url: URL) throws {
        // URL resource values may be cached on the URL itself; stat afresh on each revisit.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        modified = attributes[.modificationDate] as? Date
        size = (attributes[.size] as? NSNumber)?.uint64Value
        fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}
