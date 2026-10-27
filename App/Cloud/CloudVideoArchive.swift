import CryptoKit
import Foundation

struct CloudVideoManifest: Codable, Equatable {
    let schemaVersion: Int
    let id: UUID
    let title: String
    let sourceHost: String?
    let createdAt: Date
    let duration: Double
    let hasAudio: Bool
    let fileExtension: String
    let byteCount: Int64
    let sha256: String
}

enum CloudVideoArchiveError: LocalizedError {
    case ineligibleRecord, invalidManifest, invalidPackage, invalidMedia, integrityMismatch, invalidThumbnail, fileOperationFailed

    var errorDescription: String? {
        switch self {
        case .ineligibleRecord: return "仅支持同步已下载完成的普通视频文件。"
        case .invalidManifest: return "iCloud 视频信息无效，未导入本机。"
        case .invalidPackage: return "iCloud 视频目录无效，未导入本机。"
        case .invalidMedia: return "iCloud 视频文件尚不完整，未导入本机。"
        case .integrityMismatch: return "iCloud 视频文件校验不一致，请重新同步。"
        case .invalidThumbnail: return "视频预览图无效。"
        case .fileOperationFailed: return "无法读写视频同步文件，请稍后重试。"
        }
    }
}

enum CloudVideoArchive {
    static let manifestFilename = "manifest.json"
    static let thumbnailFilename = "thumbnail.jpg"
    static let maximumManifestBytes = 32 * 1_024
    static let maximumThumbnailBytes = 2 * 1_024 * 1_024
    private static let extensions: Set<String> = ["mp4", "mov", "m4v"]

    /// The source protocol is provenance. A completed HLS download may have
    /// become a validated portable file without changing its original kind.
    static func isEligibleForSync(record: DownloadRecord, mediaURL: URL) -> Bool {
        guard record.phase == .complete, record.candidate.kind != .protected,
              let duration = record.duration, duration.isFinite, duration > 0, record.hasAudio != nil,
              mediaURL.isFileURL, extensions.contains(mediaURL.pathExtension.lowercased()),
              let values = try? mediaURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else { return false }
        return true
    }

    /// The caller coordinates source access and supplies a new staging directory named after the record UUID.
    /// Only this manifest, the verified media file, and an optional JPEG enter the package.
    static func createStagingPackage(record: DownloadRecord, mediaURL: URL, thumbnailJPEG: Data? = nil,
                                     at packageURL: URL) throws -> CloudVideoManifest {
        guard isEligibleForSync(record: record, mediaURL: mediaURL),
              let duration = record.duration, let hasAudio = record.hasAudio else { throw CloudVideoArchiveError.ineligibleRecord }
        let fileExtension = mediaURL.pathExtension.lowercased()
        guard extensions.contains(fileExtension), UUID(uuidString: packageURL.lastPathComponent) == record.id,
              packageURL.isFileURL, !FileManager.default.fileExists(atPath: packageURL.path) else {
            throw CloudVideoArchiveError.invalidPackage
        }
        if let thumbnailJPEG { try validateJPEG(thumbnailJPEG) }
        let fingerprint = try hashFile(at: mediaURL)
        let manifest = CloudVideoManifest(schemaVersion: 1, id: record.id,
            title: String(record.candidate.title.prefix(240)), sourceHost: record.candidate.pageURL.host?.lowercased(),
            createdAt: record.createdAt, duration: duration, hasAudio: hasAudio, fileExtension: fileExtension,
            byteCount: fingerprint.bytes, sha256: fingerprint.sha256)
        try validateManifest(manifest)

        var createdDirectory = false
        do {
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: false)
            createdDirectory = true
            try FileManager.default.copyItem(at: mediaURL, to: packageURL.appendingPathComponent("video.\(fileExtension)"))
            _ = try verifyMedia(at: packageURL, manifest: manifest)
            if let thumbnailJPEG { try thumbnailJPEG.write(to: packageURL.appendingPathComponent(thumbnailFilename), options: .atomic) }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(manifest)
            guard data.count <= maximumManifestBytes else { throw CloudVideoArchiveError.invalidManifest }
            // A package is discoverable only after the complete media and optional thumbnail are present.
            try data.write(to: packageURL.appendingPathComponent(manifestFilename), options: .atomic)
            // Date encoding converts between epochs and milliseconds. Return the
            // persisted representation so exact manifest comparisons do not depend
            // on sub-microsecond precision that JSON cannot round-trip.
            return try readManifest(at: packageURL)
        } catch {
            if createdDirectory { try? FileManager.default.removeItem(at: packageURL) }
            throw (error as? CloudVideoArchiveError) ?? .fileOperationFailed
        }
    }

    static func readManifest(at packageURL: URL) throws -> CloudVideoManifest {
        let url = try containedFile(manifestFilename, in: packageURL)
        let data = try boundedData(at: url, maximumBytes: maximumManifestBytes)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let manifest = try? decoder.decode(CloudVideoManifest.self, from: data) else {
            throw CloudVideoArchiveError.invalidManifest
        }
        try validateManifest(manifest)
        guard UUID(uuidString: packageURL.lastPathComponent) == manifest.id else { throw CloudVideoArchiveError.invalidManifest }
        return manifest
    }

    static func validateManifest(_ manifest: CloudVideoManifest) throws {
        guard manifest.schemaVersion == 1, manifest.title.count <= 240, manifest.title.utf8.count <= 4_096,
              manifest.createdAt.timeIntervalSinceReferenceDate.isFinite,
              manifest.duration.isFinite, manifest.duration > 0,
              extensions.contains(manifest.fileExtension), manifest.byteCount > 0,
              manifest.sha256.utf8.count == 64,
              manifest.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              manifest.sourceHost.map(validHost) ?? true else { throw CloudVideoArchiveError.invalidManifest }
    }

    /// This checks bytes and hash. The caller must also validate the copied local file with AVFoundation.
    @discardableResult static func verifyMedia(at packageURL: URL, manifest: CloudVideoManifest) throws -> URL {
        try validateManifest(manifest)
        guard UUID(uuidString: packageURL.lastPathComponent) == manifest.id else { throw CloudVideoArchiveError.invalidManifest }
        let url = try containedFile("video.\(manifest.fileExtension)", in: packageURL)
        let fingerprint = try hashFile(at: url)
        guard fingerprint.bytes == manifest.byteCount, fingerprint.sha256 == manifest.sha256 else {
            throw CloudVideoArchiveError.integrityMismatch
        }
        return url
    }

    /// Compares an owned local copy with the immutable cloud media declaration.
    static func verifyMediaFile(at url: URL, manifest: CloudVideoManifest) throws {
        try validateManifest(manifest)
        let fingerprint = try hashFile(at: url)
        guard fingerprint.bytes == manifest.byteCount, fingerprint.sha256 == manifest.sha256 else {
            throw CloudVideoArchiveError.integrityMismatch
        }
    }

    static func thumbnailData(at packageURL: URL) throws -> Data? {
        try validateDirectory(packageURL)
        let url = packageURL.appendingPathComponent(thumbnailFilename)
        // Directory enumeration also notices dangling symbolic links.
        guard try FileManager.default.contentsOfDirectory(atPath: packageURL.path).contains(thumbnailFilename) else { return nil }
        _ = try containedFile(thumbnailFilename, in: packageURL)
        let data = try boundedData(at: url, maximumBytes: maximumThumbnailBytes)
        try validateJPEG(data)
        return data
    }

    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        if host.contains(":") {
            // IPv6 literals contain only hex digits, colons and optional brackets; URLs and ports are not hosts.
            return host.filter { $0 == ":" }.count >= 2 && host.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0) || $0 == 58 || $0 == 91 || $0 == 93
            }
        }
        return host.utf8.allSatisfy {
            (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46
        }
    }

    private static func validateDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw CloudVideoArchiveError.invalidPackage }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CloudVideoArchiveError.invalidPackage }
    }

    private static func containedFile(_ filename: String, in packageURL: URL) throws -> URL {
        try validateDirectory(packageURL)
        guard filename == URL(fileURLWithPath: filename).lastPathComponent else { throw CloudVideoArchiveError.invalidPackage }
        let root = packageURL.resolvingSymlinksInPath().standardizedFileURL
        let url = packageURL.appendingPathComponent(filename)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.deletingLastPathComponent().path == root.path else { throw CloudVideoArchiveError.invalidPackage }
        try validateRegularFile(url)
        return url
    }

    private static func validateRegularFile(_ url: URL) throws {
        guard url.isFileURL else { throw CloudVideoArchiveError.invalidMedia }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CloudVideoArchiveError.invalidMedia }
    }

    private static func hashFile(at url: URL) throws -> (bytes: Int64, sha256: String) {
        try validateRegularFile(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes: Int64 = 0
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            guard bytes <= Int64.max - Int64(data.count) else { throw CloudVideoArchiveError.invalidMedia }
            bytes += Int64(data.count)
            hasher.update(data: data)
        }
        guard bytes > 0 else { throw CloudVideoArchiveError.invalidMedia }
        return (bytes, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
        try validateRegularFile(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while let data = try handle.read(upToCount: min(64 * 1_024, maximumBytes + 1 - result.count)), !data.isEmpty {
            result.append(data)
            guard result.count <= maximumBytes else { throw CloudVideoArchiveError.invalidPackage }
        }
        return result
    }

    private static func validateJPEG(_ data: Data) throws {
        guard data.count >= 4, data.count <= maximumThumbnailBytes,
              data.prefix(3) == Data([0xff, 0xd8, 0xff]), data.suffix(2) == Data([0xff, 0xd9]) else {
            throw CloudVideoArchiveError.invalidThumbnail
        }
    }
}
