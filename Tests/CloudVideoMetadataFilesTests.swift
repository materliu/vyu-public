import XCTest
@testable import VYu

final class CloudVideoMetadataFilesTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDownWithError() throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
    }

    func testNewerRemoteWinsAndStaleLocalDoesNotRewriteSidecar() throws {
        let cloud = try temporaryDirectory()
        let id = UUID()
        let older = metadata(id, date: 1_700_000_000, tags: ["旧"])
        let newer = metadata(id, date: 1_700_000_001, tags: ["新"])
        _ = try sync([id: newer], id: id, cloud: cloud)
        let file = CloudVideoMetadataFiles.fileURL(id, container: cloud)
        let before = try Data(contentsOf: file)
        let result = try sync([id: older], id: id, cloud: cloud)
        XCTAssertEqual(result.entries[id], newer)
        XCTAssertEqual(result.invalidCount, 0)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testRevisionTieBreakAndClearedStateUseTheSameConflictOrder() throws {
        let id = UUID()
        let first = VideoMetadata(id: id, isFavorite: true, tags: ["旧"], updatedAt: Date(timeIntervalSince1970: 100),
            revision: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let cleared = VideoMetadata(id: id, isFavorite: false, tags: [], updatedAt: first.updatedAt,
            revision: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        XCTAssertEqual(try CloudVideoMetadataFiles.newest([first, cleared], id: id), cleared)
        XCTAssertEqual(try CloudVideoMetadataFiles.newest([cleared, first], id: id), cleared)
        let cloud = try temporaryDirectory()
        _ = try sync([id: first], id: id, cloud: cloud)
        XCTAssertEqual(try sync([id: cleared], id: id, cloud: cloud).entries[id], cleared)
        XCTAssertEqual(try sync([id: first], id: id, cloud: cloud).entries[id], cleared)
    }

    func testRepeatedSynchronizationAtMillisecondPrecisionDoesNotRewriteOrCreateRevisions() throws {
        let cloud = try temporaryDirectory(), id = UUID()
        let value = metadata(id, date: 1_700_000_000_123 / 1_000, tags: ["毫秒时间"])
        _ = try sync([id: value], id: id, cloud: cloud)
        let file = CloudVideoMetadataFiles.fileURL(id, container: cloud)
        let originalData = try Data(contentsOf: file)
        let originalDate = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        for _ in 0..<10 {
            let result = try sync([id: value], id: id, cloud: cloud)
            XCTAssertEqual(result.entries[id], value)
            XCTAssertEqual(result.invalidCount, 0)
            XCTAssertEqual(try Data(contentsOf: file), originalData)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, originalDate)
        }
    }

    func testSameRevisionWithDifferentPayloadIsRejectedInsteadOfOscillating() throws {
        let id = UUID()
        let first = metadata(id, date: 100, tags: ["甲"])
        var forged = first
        forged.tags = ["乙"]
        XCTAssertThrowsError(try CloudVideoMetadataFiles.newest([first, forged], id: id))
        XCTAssertThrowsError(try CloudVideoMetadataFiles.newest([forged, first], id: id))
    }

    func testMismatchedUUIDAndOversizedCloudFilesDoNotReplaceLocalMetadata() throws {
        let cloud = try temporaryDirectory()
        let id = UUID(), other = UUID()
        let original = metadata(id, date: 100, tags: ["本机"])
        let unrelated = metadata(other, date: 200, tags: ["另一视频"])
        _ = try CloudVideoMetadataFiles.synchronize(local: [other: unrelated], allowedIDs: [other], deletedIDs: [],
            container: cloud, metadataURLs: [], ubiquitous: false)
        let target = CloudVideoMetadataFiles.fileURL(id, container: cloud)
        let otherData = try Data(contentsOf: CloudVideoMetadataFiles.fileURL(other, container: cloud))
        try otherData.write(to: target)
        let mismatch = try sync([id: original], id: id, cloud: cloud)
        XCTAssertEqual(mismatch.invalidCount, 1)
        XCTAssertNil(mismatch.entries[id])
        XCTAssertEqual(try Data(contentsOf: target), otherData)

        let large = Data(repeating: 65, count: CloudVideoMetadataFiles.maximumBytes + 1)
        try large.write(to: target)
        let oversized = try sync([id: original], id: id, cloud: cloud)
        XCTAssertEqual(oversized.invalidCount, 1)
        XCTAssertTrue(oversized.entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: target), large)
    }

    func testSidecarSymlinkCannotReadOrReplaceOutsideFile() throws {
        let cloud = try temporaryDirectory()
        let outside = try temporaryDirectory().appendingPathComponent("outside.json")
        let id = UUID()
        let value = metadata(id, date: 100, tags: ["本机"])
        _ = try sync([:], id: id, cloud: cloud)
        let preserved = Data("must remain outside the cloud scope".utf8)
        try preserved.write(to: outside)
        try FileManager.default.createSymbolicLink(at: CloudVideoMetadataFiles.fileURL(id, container: cloud), withDestinationURL: outside)
        let result = try sync([id: value], id: id, cloud: cloud)
        XCTAssertEqual(result.invalidCount, 1)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside), preserved)
    }

    func testDirectorySymlinkIsRejectedBeforeAnyAnnotationIsWritten() throws {
        let cloud = try temporaryDirectory(), outside = try temporaryDirectory()
        try FileManager.default.createSymbolicLink(at: cloud.appendingPathComponent("VideoMetadata"), withDestinationURL: outside)
        let id = UUID()
        XCTAssertThrowsError(try sync([id: metadata(id, date: 100, tags: ["本机"])], id: id, cloud: cloud))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testCancelledAccessAndDisallowedIDsCannotPublish() throws {
        let cloud = try temporaryDirectory()
        let id = UUID()
        let value = metadata(id, date: 100, tags: ["本机"])
        let result = try CloudVideoMetadataFiles.synchronize(local: [id: value], allowedIDs: [], deletedIDs: [],
            container: cloud, metadataURLs: [], ubiquitous: false)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudVideoMetadataFiles.fileURL(id, container: cloud).path))
        let access = CloudSyncAccess(account: "fixture", identity: { "other-account" })
        XCTAssertThrowsError(try CloudVideoMetadataFiles.synchronize(local: [id: value], allowedIDs: [id], deletedIDs: [],
            container: cloud, metadataURLs: [], ubiquitous: false, access: access)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudVideoMetadataFiles.fileURL(id, container: cloud).path))
    }

    func testPermanentDeletionPreventsLateSidecarPublication() throws {
        let cloud = try temporaryDirectory()
        let id = UUID(), value = metadata(id, date: 100, tags: ["迟到修改"])
        try CloudVideoFiles.prepare(container: cloud)
        _ = try sync([id: value], id: id, cloud: cloud)
        try CloudVideoFiles.delete(id: id, container: cloud)
        let result = try sync([id: value], id: id, cloud: cloud)
        XCTAssertEqual(result.deleted, [id])
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudVideoMetadataFiles.fileURL(id, container: cloud).path))
        let again = try sync([id: value], id: id, cloud: cloud)
        XCTAssertEqual(again.deleted, [id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudVideoMetadataFiles.fileURL(id, container: cloud).path))
    }

    private func sync(_ values: [UUID: VideoMetadata], id: UUID, cloud: URL) throws -> CloudVideoMetadataSnapshot {
        try CloudVideoMetadataFiles.synchronize(local: values, allowedIDs: [id], deletedIDs: [],
            container: cloud, metadataURLs: [], ubiquitous: false)
    }

    private func metadata(_ id: UUID, date: TimeInterval, tags: [String]) -> VideoMetadata {
        VideoMetadata(id: id, isFavorite: true, tags: tags, updatedAt: Date(timeIntervalSince1970: date), revision: UUID())
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-metadata-cloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }
}
