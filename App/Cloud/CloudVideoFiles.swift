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
                var preview: Data?
                if (try? available(previewURL, ubiquitous: ubiquitous, request: true)) == true {
                    preview = try? coordinatedRead(previewURL) { try CloudVideoArchive.thumbnailData(at: $0.deletingLastPathComponent()) }
                }
                let mediaURL = package.appendingPathComponent("video.\(manifest.fileExtension)")
                let statusURLs = [manifestURL, mediaURL] + (preview == nil ? [] : [previewURL])
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

    static func packageURL(_ id: UUID, container: URL) -> URL { container.appendingPathComponent("Videos/\(id.uuidString)", isDirectory: true) }
    private static func tombstoneURL(_ id: UUID, container: URL) -> URL { container.appendingPathComponent("Deleted/\(id.uuidString).deleted") }
    private static func fresh(_ url: URL) -> URL { URL(fileURLWithPath: url.path) }

    private static func available(_ url: URL, ubiquitous: Bool, request: Bool) throws -> Bool {
        if !ubiquitous { return FileManager.default.fileExists(atPath: url.path) }
        let values = try fresh(url).resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                                                              .ubiquitousItemHasUnresolvedConflictsKey])
        guard values.ubiquitousItemHasUnresolvedConflicts != true else { throw CloudVideoArchiveError.invalidPackage }
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
