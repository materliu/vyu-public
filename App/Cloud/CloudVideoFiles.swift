import CryptoKit
import Foundation

/// Invalidated immediately on account change; writers also recheck the current system identity.
final class CloudSyncAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let account: String
    private let identity: @Sendable () -> String?
    init(account: String, identity: @escaping @Sendable () -> String?) { self.account = account; self.identity = identity }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let valid = !cancelled; lock.unlock()
        guard valid, identity() == account else { throw CancellationError() }
    }
}

/// Invalidated synchronously when the local record or annotation changes during rendering.
final class CloudCoverWriteAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let valid = !cancelled; lock.unlock()
        guard valid else { throw CancellationError() }
    }
}

struct CloudVideoEntry: Identifiable, Equatable {
    var id: UUID { manifest.id }
    let manifest: CloudVideoManifest
    let thumbnail: Data?
    let uploaded: Bool
    let transferError: Bool
}

struct CloudVideoSnapshot {
    var entries: [CloudVideoEntry] = []
    var deleted: Set<UUID> = []
    var invalidCount = 0
}

/// All methods run off the main actor. File coordination ends before waiting on iCloud.
enum CloudVideoFiles {
    static let coverRevisionFilename = "cover-revision.json"
    private struct CoverRevision: Codable, Equatable {
        var schemaVersion = 2
        let id: UUID
        let revision: UUID
        let frameSeconds: Double?
        let thumbnailSHA256: String?
        init(_ metadata: VideoMetadata, thumbnailJPEG: Data) {
            id = metadata.id; revision = metadata.revision; frameSeconds = metadata.coverFrameSeconds
            thumbnailSHA256 = CloudVideoFiles.thumbnailHash(thumbnailJPEG)
        }
        func matches(metadata: VideoMetadata, thumbnailJPEG: Data) -> Bool {
            id == metadata.id && revision == metadata.revision && frameSeconds == metadata.coverFrameSeconds &&
                matches(thumbnailJPEG: thumbnailJPEG)
        }
        func matches(thumbnailJPEG: Data) -> Bool {
            schemaVersion == 2 && thumbnailSHA256 == CloudVideoFiles.thumbnailHash(thumbnailJPEG)
        }
    }

    static func prepare(container: URL, access: CloudSyncAccess? = nil) throws {
        for name in ["Videos", "Deleted"] {
            let url = container.appendingPathComponent(name, isDirectory: true)
            try coordinatedWrite(url) { target in
                try access?.check()
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            }
        }
    }

    static func snapshot(container: URL, metadataURLs: [URL], ubiquitous: Bool) throws -> CloudVideoSnapshot {
        var result = CloudVideoSnapshot()
        let videos = container.appendingPathComponent("Videos", isDirectory: true)
        let deleted = container.appendingPathComponent("Deleted", isDirectory: true)
        // Enumeration supplements the metadata query for files this device just published.
        // Only NSMetadataQuery discovers remote placeholders on a new device.
        let localPackages = (try? FileManager.default.contentsOfDirectory(at: videos, includingPropertiesForKeys: nil)) ?? []
        let localDeleted = (try? FileManager.default.contentsOfDirectory(at: deleted, includingPropertiesForKeys: nil)) ?? []
        let urls = metadataURLs + localDeleted + localPackages.map { $0.appendingPathComponent(CloudVideoArchive.manifestFilename) }
        var packages: Set<URL> = []
        for url in urls {
            if url.deletingLastPathComponent().standardizedFileURL.path == deleted.standardizedFileURL.path,
               url.pathExtension == "deleted", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) {
                result.deleted.insert(id)
            } else if url.lastPathComponent == CloudVideoArchive.manifestFilename,
                      url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == videos.standardizedFileURL.path,
                      UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) != nil {
                packages.insert(url.deletingLastPathComponent())
            }
        }
        for package in packages {
            guard let id = UUID(uuidString: package.lastPathComponent), !result.deleted.contains(id) else { continue }
            let manifestURL = package.appendingPathComponent(CloudVideoArchive.manifestFilename)
            do {
                guard try available(manifestURL, ubiquitous: ubiquitous, request: true) else { continue }
                let manifest = try coordinatedRead(manifestURL) { try CloudVideoArchive.readManifest(at: $0.deletingLastPathComponent()) }
                let previewURL = package.appendingPathComponent(CloudVideoArchive.thumbnailFilename)
                let markerURL = package.appendingPathComponent(coverRevisionFilename)
                let markerDeclared = coverFileExists(markerURL) || metadataURLs.contains {
                    $0.standardizedFileURL == markerURL.standardizedFileURL
                }
                let markerAvailable = !markerDeclared || (try? coverFileAvailable(markerURL, ubiquitous: ubiquitous)) == true
                var preview: Data?
                if markerAvailable, (try? available(previewURL, ubiquitous: ubiquitous, request: true)) == true {
                    preview = try? coordinatedRead(package) { target in
                        let jpeg = try CloudVideoArchive.thumbnailData(at: target)
                        guard markerDeclared else { return jpeg }
                        // Marker and JPEG are separate iCloud files and may arrive out of order.
                        guard !coverHasConflicts(target), let jpeg,
                              let marker = try readCoverRevision(at: target.appendingPathComponent(coverRevisionFilename)),
                              marker.id == manifest.id, marker.matches(thumbnailJPEG: jpeg) else { return nil }
                        return jpeg
                    }
                }
                let mediaURL = package.appendingPathComponent("video.\(manifest.fileExtension)")
                let statusURLs = [manifestURL, mediaURL] + (preview == nil ? [] : [previewURL]) + (markerDeclared ? [markerURL] : [])
                let values = statusURLs.map {
                    try? fresh($0).resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey,
                                                           .ubiquitousItemDownloadingErrorKey, .ubiquitousItemHasUnresolvedConflictsKey])
                }
                result.entries.append(CloudVideoEntry(manifest: manifest, thumbnail: preview,
                    uploaded: ubiquitous ? values.allSatisfy { $0?.ubiquitousItemIsUploaded == true } : FileManager.default.fileExists(atPath: mediaURL.path),
                    transferError: values.contains { $0?.ubiquitousItemUploadingError != nil || $0?.ubiquitousItemDownloadingError != nil || $0?.ubiquitousItemHasUnresolvedConflicts == true }))
            } catch { result.invalidCount += 1 }
        }
        return result
    }

    static func publish(staging: URL, manifest: CloudVideoManifest, container: URL, ubiquitous: Bool, access: CloudSyncAccess? = nil) throws {
        try access?.check()
        let destination = packageURL(manifest.id, container: container)
        guard !FileManager.default.fileExists(atPath: tombstoneURL(manifest.id, container: container).path) else { return }
        if ubiquitous {
            // setUbiquitous performs its own coordinated write; never nest it in another coordinator.
            if !FileManager.default.fileExists(atPath: destination.path) {
                try access?.check()
                try FileManager.default.setUbiquitous(true, itemAt: staging, destinationURL: destination)
            } else {
                try coordinatedRead(destination) { target in
                    guard try CloudVideoArchive.readManifest(at: target) == manifest else { throw CloudVideoArchiveError.integrityMismatch }
                    _ = try CloudVideoArchive.verifyMedia(at: target, manifest: manifest)
                }
            }
        } else {
            try coordinatedWrite(destination) { target in
                try access?.check()
                if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.moveItem(at: staging, to: target) }
                else {
                    guard try CloudVideoArchive.readManifest(at: target) == manifest else { throw CloudVideoArchiveError.integrityMismatch }
                    _ = try CloudVideoArchive.verifyMedia(at: target, manifest: manifest)
                }
            }
        }
    }

    static func downloadCopy(entry: CloudVideoEntry, container: URL, stagingParent: URL, ubiquitous: Bool, access: CloudSyncAccess? = nil) throws -> URL? {
        try access?.check()
        let package = packageURL(entry.id, container: container)
        guard !FileManager.default.fileExists(atPath: tombstoneURL(entry.id, container: container).path) else { return nil }
        let media = package.appendingPathComponent("video.\(entry.manifest.fileExtension)")
        guard try available(media, ubiquitous: ubiquitous, request: true) else { return nil }
        let stage = stagingParent.appendingPathComponent(entry.id.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: stage.path) else { throw CloudVideoArchiveError.invalidPackage }
        var created = false
        do {
            try FileManager.default.createDirectory(at: stagingParent, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try coordinatedRead(package) { source in
                try access?.check()
                // Copy only the declared files; never follow arbitrary members of a remote directory.
                let actual = try CloudVideoArchive.readManifest(at: source)
                guard actual == entry.manifest else { throw CloudVideoArchiveError.invalidManifest }
                let media = try CloudVideoArchive.verifyMedia(at: source, manifest: actual)
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                created = true
                try FileManager.default.copyItem(at: media, to: stage.appendingPathComponent(media.lastPathComponent))
                try FileManager.default.copyItem(at: source.appendingPathComponent(CloudVideoArchive.manifestFilename),
                    to: stage.appendingPathComponent(CloudVideoArchive.manifestFilename))
                _ = try CloudVideoArchive.verifyMedia(at: stage, manifest: actual)
            }
            guard !FileManager.default.fileExists(atPath: tombstoneURL(entry.id, container: container).path) else {
                try FileManager.default.removeItem(at: stage); return nil
            }
            return stage
        } catch {
            if created { try? FileManager.default.removeItem(at: stage) }
            throw error
        }
    }

    static func delete(id: UUID, container: URL, access: CloudSyncAccess? = nil) throws {
        try access?.check()
        // A permanent, immutable tombstone wins over late uploads from other devices.
        let tombstone = tombstoneURL(id, container: container)
        try coordinatedWrite(tombstone) { url in
            try access?.check()
            if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: .atomic) }
        }
        try purgeDeletedPackage(id: id, container: container, access: access)
    }

    static func purgeDeletedPackage(id: UUID, container: URL, access: CloudSyncAccess? = nil) throws {
        try access?.check()
        let url = packageURL(id, container: container)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try coordinatedWrite(url, options: .forDeleting) { target in
            try access?.check()
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        }
    }

    static func hasCurrentCover(metadata: VideoMetadata, manifest: CloudVideoManifest, container: URL,
                                ubiquitous: Bool, access: CloudSyncAccess? = nil) throws -> Bool {
        try access?.check()
        try metadata.validate()
        guard metadata.id == manifest.id, !coverTombstoneExists(metadata.id, container: container) else { return false }
        let package = packageURL(metadata.id, container: container)
        let marker = package.appendingPathComponent(coverRevisionFilename)
        guard try coverFileAvailable(marker, ubiquitous: ubiquitous, allowConflicts: true),
              try coverFileAvailable(package.appendingPathComponent(CloudVideoArchive.thumbnailFilename),
                  ubiquitous: ubiquitous, allowConflicts: true) else { return false }
        return try coordinatedRead(package) { target in
            try access?.check()
            try validateCoverLocation(target, container: container)
            guard try CloudVideoArchive.readManifest(at: target) == manifest,
                  !coverHasConflicts(target),
                  let marker = try readCoverRevision(at: target.appendingPathComponent(coverRevisionFilename)),
                  let jpeg = try CloudVideoArchive.thumbnailData(at: target),
                  marker.matches(metadata: metadata, thumbnailJPEG: jpeg) else { return false }
            return !coverTombstoneExists(metadata.id, container: container)
        }
    }

    /// Coordinates the winning annotation and the package together, replacing only its small JPEG and marker.
    /// Returns false for a pending file, stale render, deletion, or a revision another device already published.
    static func updateCover(thumbnailJPEG: Data, metadata: VideoMetadata, manifest: CloudVideoManifest,
                            container: URL, ubiquitous: Bool, access: CloudSyncAccess? = nil,
                            writeAccess: CloudCoverWriteAccess? = nil) throws -> Bool {
        try access?.check(); try writeAccess?.check(); try metadata.validate()
        guard metadata.id == manifest.id, thumbnailJPEG.count >= 4,
              thumbnailJPEG.count <= CloudVideoArchive.maximumThumbnailBytes,
              thumbnailJPEG.prefix(3) == Data([0xff, 0xd8, 0xff]), thumbnailJPEG.suffix(2) == Data([0xff, 0xd9]) else {
            throw CloudVideoArchiveError.invalidThumbnail
        }
        guard !coverTombstoneExists(metadata.id, container: container) else { return false }
        let package = packageURL(metadata.id, container: container)
        let annotation = CloudVideoMetadataFiles.fileURL(metadata.id, container: container)
        let marker = package.appendingPathComponent(coverRevisionFilename)
        guard try coverFileAvailable(annotation, ubiquitous: ubiquitous),
              try coverFileAvailable(package.appendingPathComponent(CloudVideoArchive.manifestFilename), ubiquitous: ubiquitous) else { return false }
        // Do not overwrite an undiscovered placeholder for another device's marker.
        let markerPlaceholder = marker.deletingLastPathComponent().appendingPathComponent(".\(marker.lastPathComponent).icloud")
        if FileManager.default.fileExists(atPath: marker.path) || FileManager.default.fileExists(atPath: markerPlaceholder.path) {
            guard try coverFileAvailable(marker, ubiquitous: ubiquitous, allowConflicts: true) else { return false }
        }
        var coordinationError: NSError?
        var operation: Result<Bool, Error>?
        NSFileCoordinator().coordinate(readingItemAt: annotation, options: .withoutChanges,
            writingItemAt: package, options: .forMerging, error: &coordinationError) { annotationURL, target in
                operation = Result {
                    try access?.check(); try writeAccess?.check()
                    try validateCoverLocation(target, container: container)
                    try validateCoverAnnotation(annotationURL, id: metadata.id, container: container)
                    guard !coverTombstoneExists(metadata.id, container: container),
                          try CloudVideoArchive.readManifest(at: target) == manifest,
                          try CloudVideoMetadataFiles.read(at: annotationURL, id: metadata.id) == metadata else { return false }
                    let marker = target.appendingPathComponent(coverRevisionFilename)
                    let preview = target.appendingPathComponent(CloudVideoArchive.thumbnailFilename)
                    let conflicts = [preview, marker].flatMap { NSFileVersion.unresolvedConflictVersionsOfItem(at: $0) ?? [] }
                    guard conflicts.count <= 64 else { throw CloudVideoArchiveError.invalidPackage }
                    let revision = CoverRevision(metadata, thumbnailJPEG: thumbnailJPEG)
                    if !coverHasConflicts(target), let prior = try readCoverRevision(at: marker),
                       let jpeg = try CloudVideoArchive.thumbnailData(at: target),
                       prior.matches(metadata: metadata, thumbnailJPEG: jpeg) { return false }
                    try validateOptionalCoverFile(preview)
                    try validateOptionalCoverFile(marker)
                    let data = try JSONEncoder().encode(revision)
                    guard data.count <= 1_024 else { throw CloudVideoArchiveError.invalidPackage }
                    try access?.check(); try writeAccess?.check()
                    guard !coverTombstoneExists(metadata.id, container: container),
                          try CloudVideoMetadataFiles.read(at: annotationURL, id: metadata.id) == metadata else { return false }
                    try thumbnailJPEG.write(to: preview, options: .atomic)
                    try access?.check(); try writeAccess?.check()
                    guard !coverTombstoneExists(metadata.id, container: container),
                          try CloudVideoMetadataFiles.read(at: annotationURL, id: metadata.id) == metadata else { return false }
                    // Publish the marker last, so an interrupted write is retried.
                    try data.write(to: marker, options: .atomic)
                    try access?.check(); try writeAccess?.check()
                    guard !coverTombstoneExists(metadata.id, container: container),
                          try CloudVideoMetadataFiles.read(at: annotationURL, id: metadata.id) == metadata else { return false }
                    // Old conflict files cannot choose the selected time; the coordinated annotation does.
                    for conflict in conflicts {
                        try access?.check(); try writeAccess?.check()
                        guard !coverTombstoneExists(metadata.id, container: container) else { return false }
                        conflict.isResolved = true
                    }
                    return true
                }
            }
        if let coordinationError { throw coordinationError }
        guard let operation else { throw CloudVideoArchiveError.fileOperationFailed }
        return try operation.get()
    }

    private static func readCoverRevision(at url: URL) throws -> CoverRevision? {
        guard try optionalCoverFileExists(url) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 1_024 else { throw CloudVideoArchiveError.invalidPackage }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_025) ?? Data()
        guard data.count <= 1_024 else { throw CloudVideoArchiveError.invalidPackage }
        let marker = try JSONDecoder().decode(CoverRevision.self, from: data)
        guard [1, 2].contains(marker.schemaVersion),
              marker.thumbnailSHA256.map({ $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) ?? true,
              marker.frameSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw CloudVideoArchiveError.invalidPackage }
        return marker
    }

    private static func validateOptionalCoverFile(_ url: URL) throws { _ = try optionalCoverFileExists(url) }

    private static func optionalCoverFileExists(_ url: URL) throws -> Bool {
        guard try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).contains(url.lastPathComponent) else { return false }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CloudVideoArchiveError.invalidPackage }
        return true
    }

    private static func validateCoverLocation(_ package: URL, container: URL) throws {
        let videos = container.appendingPathComponent("Videos", isDirectory: true)
        for directory in [container, videos, package] {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard directory.isFileURL, values.isDirectory == true, values.isSymbolicLink != true else { throw CloudVideoArchiveError.invalidPackage }
        }
        guard UUID(uuidString: package.lastPathComponent) != nil,
              package.standardizedFileURL.deletingLastPathComponent() == videos.standardizedFileURL,
              package.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL == videos.resolvingSymlinksInPath().standardizedFileURL else {
            throw CloudVideoArchiveError.invalidPackage
        }
    }

    private static func validateCoverAnnotation(_ url: URL, id: UUID, container: URL) throws {
        let expected = CloudVideoMetadataFiles.fileURL(id, container: container)
        let directory = expected.deletingLastPathComponent()
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              url.standardizedFileURL == expected.standardizedFileURL,
              url.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else {
            throw CloudVideoArchiveError.invalidPackage
        }
    }

    private static func thumbnailHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func coverHasConflicts(_ package: URL) -> Bool {
        [CloudVideoArchive.thumbnailFilename, coverRevisionFilename].contains { filename in
            let url = package.appendingPathComponent(filename)
            return !(NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).isEmpty ||
                (try? fresh(url).resourceValues(forKeys: [.ubiquitousItemHasUnresolvedConflictsKey]))?.ubiquitousItemHasUnresolvedConflicts == true
        }
    }

    private static func coverFileExists(_ url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder.path)
    }

    private static func coverFileAvailable(_ url: URL, ubiquitous: Bool, allowConflicts: Bool = false) throws -> Bool {
        guard coverFileExists(url) else { return false }
        return try available(url, ubiquitous: ubiquitous, request: true, allowConflicts: allowConflicts)
    }

    private static func coverTombstoneExists(_ id: UUID, container: URL) -> Bool {
        let url = tombstoneURL(id, container: container)
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder.path)
    }

    static func packageURL(_ id: UUID, container: URL) -> URL { container.appendingPathComponent("Videos/\(id.uuidString)", isDirectory: true) }
    private static func tombstoneURL(_ id: UUID, container: URL) -> URL { container.appendingPathComponent("Deleted/\(id.uuidString).deleted") }
    private static func fresh(_ url: URL) -> URL { URL(fileURLWithPath: url.path) }

    private static func available(_ url: URL, ubiquitous: Bool, request: Bool, allowConflicts: Bool = false) throws -> Bool {
        if !ubiquitous { return FileManager.default.fileExists(atPath: url.path) }
        let values = try fresh(url).resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                                              .ubiquitousItemHasUnresolvedConflictsKey])
        guard allowConflicts || values.ubiquitousItemHasUnresolvedConflicts != true else { throw CloudVideoArchiveError.invalidPackage }
        if values.isUbiquitousItem == true {
            if values.ubiquitousItemDownloadingStatus == .current { return true }
            if request { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func coordinatedRead<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { target in
            result = Result { try body(target) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CloudVideoArchiveError.fileOperationFailed }
        return try result.get()
    }

    private static func coordinatedWrite(_ url: URL, options: NSFileCoordinator.WritingOptions = [], _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError) { target in
            do { try body(target) } catch { operationError = error }
        }
        if let error = coordinationError ?? operationError as NSError? { throw error }
    }
}
