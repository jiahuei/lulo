import Foundation

/// Performs the explicit file mutation away from the main actor while retaining its access grant.
public actor ImageTrash {
    public init() {}

    public func move(at url: URL, access: FileAccess) throws -> URL? {
        defer { withExtendedLifetime(access) {} }
        let authorized = access.url.standardizedFileURL
        guard
            authorized == url.standardizedFileURL
                || authorized == url.deletingLastPathComponent().standardizedFileURL
        else { throw CocoaError(.fileWriteNoPermission) }
        _ = try ImageLoader.validateFormat(url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        // A directory or symlink named like an image must never remove unrelated files.
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ImageLoadError.unsupported
        }
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        return destination as URL?
    }
}
