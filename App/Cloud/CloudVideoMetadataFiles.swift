import Foundation

struct CloudVideoMetadataSnapshot {
    var entries: [UUID: VideoMetadata] = [:]
    var deleted: Set<UUID> = []
    var pending: Set<UUID> = []
    var invalidCount = 0
}

/// Small, separately coordinated files let library edits sync without replacing a video package.
/// Callers supply only video IDs owned by the accepted account.
enum CloudVideoMetadataFiles {
    static let maximumBytes = 32 * 1_024
    private struct Payload: Codable {
        let schemaVersion: Int
        let metadata: VideoMetadata
    }
    private enum Availability: Equatable { case absent, pending, current }

    static func synchronize(local: [UUID: VideoMetadata], allowedIDs: Set<UUID>, deletedIDs: Set<UUID>,
                            container: URL, metadataURLs: [URL], ubiquitous: Bool,
                            access: CloudSyncAccess? = nil) throws -> CloudVideoMetadataSnapshot {
        try access?.check()
        try prepare(container: container, access: access)
        var result = CloudVideoMetadataSnapshot()
        let directory = metadataDirectory(container)
        let declaredIDs = Set(metadataURLs.compactMap { url -> UUID? in
            guard url.isFileURL,
                  url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                  url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  url.lastPathComponent == "\(id.uuidString).json" else { return nil }
            return id
        })
        for id in deletedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            do { try purge(id: id, container: container, access: access); result.deleted.insert(id) }
            catch is CancellationError { throw CancellationError() }
            catch { result.invalidCount += 1 }
        }
        for id in allowedIDs.subtracting(deletedIDs).sorted(by: { $0.uuidString < $1.uuidString }) {
            do {
                try access?.check()
                if tombstoneExists(id, container: container) {
                    try purge(id: id, container: container, access: access)
                    result.deleted.insert(id)
                    continue
                }
                if let value = local[id] {
                    guard value.id == id else { throw CloudVideoArchiveError.invalidManifest }
                    try value.validate()
                }
                let url = fileURL(id, container: container)
                let availability = try availability(url, declared: declaredIDs.contains(id), ubiquitous: ubiquitous)
                if availability == .pending { result.pending.insert(id); continue }
                if availability == .absent && local[id] == nil { continue }
                let merged = try coordinatedMerge(url) { target -> VideoMetadata? in
                    try access?.check()
                    try validateLocation(target, container: container)
                    if tombstoneExists(id, container: container) { return nil }
                    // Recheck after acquiring coordination: a newer remote version may have arrived.
                    let currentAvailability = try self.availability(target, declared: declaredIDs.contains(id), ubiquitous: ubiquitous)
                    if currentAvailability == .pending { return nil }
                    let current = currentAvailability == .current ? try read(at: target, id: id) : nil
                    let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: target) ?? []
                    guard conflicts.count <= 32 else { throw CloudVideoArchiveError.invalidManifest }
                    var versions = try conflicts.map { try read(at: $0.url, id: id) }
                    if let current { versions.append(current) }
                    if let value = local[id] { versions.append(value) }
                    guard let winner = try newest(versions, id: id) else { return nil }
                    if current != winner || !conflicts.isEmpty {
                        try access?.check()
                        guard !tombstoneExists(id, container: container) else { return nil }
                        let data = try encoded(winner)
                        try data.write(to: target, options: .atomic)
                    }
                    // Mark conflicts resolved only after the winning contents are durably published.
                    try access?.check()
                    guard !tombstoneExists(id, container: container) else {
                        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                        return nil
                    }
                    for conflict in conflicts { conflict.isResolved = true }
                    return winner
                }
                try access?.check()
                if tombstoneExists(id, container: container) {
                    try purge(id: id, container: container, access: access)
                    result.deleted.insert(id)
                } else if let merged { result.entries[id] = merged }
            } catch is CancellationError { throw CancellationError() }
            catch { result.invalidCount += 1 }
        }
        return result
    }

    static func fileURL(_ id: UUID, container: URL) -> URL {
        metadataDirectory(container).appendingPathComponent("\(id.uuidString).json")
    }

    /// The same total order is used for normal updates and unresolved NSFileVersion copies.
    static func newest(_ versions: [VideoMetadata], id: UUID) throws -> VideoMetadata? {
        var result: VideoMetadata?
        for value in versions {
            guard value.id == id else { throw CloudVideoArchiveError.invalidManifest }
            try value.validate()
            if let result, value != result, !value.isNewer(than: result), !result.isNewer(than: value) {
                throw CloudVideoArchiveError.invalidManifest
            }
            if result.map({ value.isNewer(than: $0) }) ?? true { result = value }
        }
        return result
    }

    static func read(at url: URL, id: UUID) throws -> VideoMetadata {
        guard url.isFileURL else { throw CloudVideoArchiveError.invalidManifest }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard url.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize, count > 0, count <= maximumBytes else {
            throw CloudVideoArchiveError.invalidManifest
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw CloudVideoArchiveError.invalidManifest }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let payload = try decoder.decode(Payload.self, from: data)
        guard payload.schemaVersion == 1, payload.metadata.id == id else { throw CloudVideoArchiveError.invalidManifest }
        try payload.metadata.validate()
        return payload.metadata
    }

    private static func encoded(_ metadata: VideoMetadata) throws -> Data {
        try metadata.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Payload(schemaVersion: 1, metadata: metadata))
        guard data.count <= maximumBytes else { throw CloudVideoArchiveError.invalidManifest }
        return data
    }

    private static func metadataDirectory(_ container: URL) -> URL {
        container.appendingPathComponent("VideoMetadata", isDirectory: true)
    }

    private static func prepare(container: URL, access: CloudSyncAccess?) throws {
        try validateDirectory(container)
        let directory = metadataDirectory(container)
        try coordinatedMerge(directory) { target in
            try access?.check()
            guard target.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL ==
                    container.resolvingSymlinksInPath().standardizedFileURL else { throw CloudVideoArchiveError.invalidPackage }
            if FileManager.default.fileExists(atPath: target.path) { try validateDirectory(target) }
            else { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
        }
    }

    private static func purge(id: UUID, container: URL, access: CloudSyncAccess?) throws {
        try access?.check()
        let url = fileURL(id, container: container)
        try coordinatedMerge(url, options: .forDeleting) { target in
            try access?.check()
            try validateLocation(target, container: container)
            if FileManager.default.fileExists(atPath: target.path) {
                let values = try target.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw CloudVideoArchiveError.invalidManifest }
                try FileManager.default.removeItem(at: target)
            }
        }
    }

    private static func validateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard url.isFileURL, values.isDirectory == true, values.isSymbolicLink != true else {
            throw CloudVideoArchiveError.invalidPackage
        }
    }

    private static func validateLocation(_ url: URL, container: URL) throws {
        let directory = metadataDirectory(container)
        try validateDirectory(container)
        try validateDirectory(directory)
        guard url.isFileURL, url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              url.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL ==
                directory.resolvingSymlinksInPath().standardizedFileURL else { throw CloudVideoArchiveError.invalidPackage }
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw CloudVideoArchiveError.invalidPackage
        }
    }

    private static func tombstoneExists(_ id: UUID, container: URL) -> Bool {
        let url = container.appendingPathComponent("Deleted/\(id.uuidString).deleted")
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder.path)
    }

    private static func availability(_ url: URL, declared: Bool, ubiquitous: Bool) throws -> Availability {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard ubiquitous else { return exists ? .current : .absent }
        guard exists || declared || FileManager.default.fileExists(atPath: placeholder.path) else { return .absent }
        let fresh = URL(fileURLWithPath: url.path)
        let values = try fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                                       .ubiquitousItemDownloadingErrorKey, .ubiquitousItemUploadingErrorKey])
        if values.ubiquitousItemDownloadingError != nil || values.ubiquitousItemUploadingError != nil {
            throw CloudVideoArchiveError.fileOperationFailed
        }
        if values.isUbiquitousItem == true {
            if values.ubiquitousItemDownloadingStatus == .current { return .current }
            try FileManager.default.startDownloadingUbiquitousItem(at: fresh)
            return .pending
        }
        if exists { return .current }
        try FileManager.default.startDownloadingUbiquitousItem(at: fresh)
        return .pending
    }

    private static func coordinatedMerge<T>(_ url: URL, options: NSFileCoordinator.WritingOptions = .forMerging,
                                             _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError) { target in
            result = Result { try body(target) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CloudVideoArchiveError.fileOperationFailed }
        return try result.get()
    }
}
