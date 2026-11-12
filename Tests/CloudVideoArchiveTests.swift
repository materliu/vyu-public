import XCTest
import Darwin
@testable import VYu

final class CloudVideoArchiveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testRoundTripExportsOnlySelectedMetadataAndMedia() throws {
        let record = makeRecord()
        let mediaURL = try writeMedia(Data("hello".utf8))
        let package = root.appendingPathComponent(record.id.uuidString)
        let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0x00, 0xff, 0xd9])
        let manifest = try CloudVideoArchive.createStagingPackage(record: record, mediaURL: mediaURL,
            thumbnailJPEG: jpeg, at: package)

        XCTAssertEqual(manifest.sha256, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(manifest.byteCount, 5)
        XCTAssertEqual(manifest.sourceHost, "example.org")
        XCTAssertEqual(try CloudVideoArchive.readManifest(at: package), manifest)
        XCTAssertEqual(try Data(contentsOf: CloudVideoArchive.verifyMedia(at: package, manifest: manifest)), Data("hello".utf8))
        XCTAssertEqual(try CloudVideoArchive.thumbnailData(at: package), jpeg)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: package.path)),
                       Set(["manifest.json", "video.mp4", "thumbnail.jpg"]))

        let json = try String(contentsOf: package.appendingPathComponent("manifest.json"), encoding: .utf8)
        for secret in ["https://", "signedSecret", "pageSecret", "frameSecret", "private-path", "Resume", "Cookie", "localRelativePath"] {
            XCTAssertFalse(json.contains(secret), "Unexpected exported value: \(secret)")
        }
    }

    func testLargeFileCrossesHashChunkBoundary() throws {
        let bytes = Data(repeating: 0xa5, count: 1_024 * 1_024 + 17)
        let (package, manifest) = try createPackage(bytes: bytes)
        XCTAssertEqual(manifest.byteCount, Int64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: CloudVideoArchive.verifyMedia(at: package, manifest: manifest)), bytes)
        XCTAssertNil(try CloudVideoArchive.thumbnailData(at: package))
    }

    func testRepeatedLargeFileVerificationKeepsChunkMemoryBounded() throws {
        let media = root.appendingPathComponent("large.mp4")
        XCTAssertTrue(FileManager.default.createFile(atPath: media.path, contents: nil))
        let handle = try FileHandle(forWritingTo: media)
        try handle.truncate(atOffset: 128 * 1_024 * 1_024)
        try handle.close()
        let manifest = CloudVideoManifest(schemaVersion: 1, id: UUID(), title: "memory fixture",
            sourceHost: nil, createdAt: Date(), duration: 1, hasAudio: false, fileExtension: "mp4",
            byteCount: 128 * 1_024 * 1_024, sha256: "254bcc3fc4f27172636df4bf32de9f107f620d559b20d760197e452b97453917")

        // Keep one outer pool, as in a background upload/verification task.
        // Without per-chunk draining, three passes retain about 384 MiB.
        try autoreleasepool {
            let before = try memoryFootprint()
            for _ in 0..<3 { try CloudVideoArchive.verifyMediaFile(at: media, manifest: manifest) }
            let after = try memoryFootprint()
            XCTAssertLessThan(after > before ? after - before : 0, 64 * 1_024 * 1_024,
                              "Hash verification must not retain every file chunk until the task ends.")
        }
    }

    private func memoryFootprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw NSError(domain: NSMachErrorDomain, code: Int(status)) }
        return info.phys_footprint
    }

    func testTamperedOrTruncatedMediaDoesNotVerify() throws {
        let (package, manifest) = try createPackage(bytes: Data("hello".utf8))
        let media = package.appendingPathComponent("video.mp4")
        try Data("jello".utf8).write(to: media)
        XCTAssertThrowsError(try CloudVideoArchive.verifyMedia(at: package, manifest: manifest))
        try Data("hell".utf8).write(to: media)
        XCTAssertThrowsError(try CloudVideoArchive.verifyMedia(at: package, manifest: manifest))
    }

    func testIncompleteProtectedAndMissingValidationResultsAreNotExported() throws {
        let source = try writeMedia(Data("hello".utf8))
        for phase in [DownloadPhase.queued, .downloading, .paused, .validating, .failed, .cancelled] {
            let record = makeRecord(phase: phase)
            XCTAssertThrowsError(try CloudVideoArchive.createStagingPackage(record: record, mediaURL: source,
                at: root.appendingPathComponent(record.id.uuidString)))
        }
        let protected = makeRecord(kind: .protected)
        XCTAssertThrowsError(try CloudVideoArchive.createStagingPackage(record: protected, mediaURL: source,
            at: root.appendingPathComponent(protected.id.uuidString)))
        var record = makeRecord()
        record.duration = nil
        XCTAssertThrowsError(try CloudVideoArchive.createStagingPackage(record: record, mediaURL: source,
            at: root.appendingPathComponent(record.id.uuidString)))
        record.duration = 10
        record.hasAudio = nil
        XCTAssertThrowsError(try CloudVideoArchive.createStagingPackage(record: record, mediaURL: source,
            at: root.appendingPathComponent(record.id.uuidString)))
    }

    func testValidatedPortableFileFromHLSSyncsWithoutExportingSourceCredentials() throws {
        let record = makeRecord(kind: .hls)
        let source = try writeMedia(Data("verified portable fixture bytes".utf8))
        XCTAssertTrue(CloudVideoArchive.isEligibleForSync(record: record, mediaURL: source))
        let package = root.appendingPathComponent(record.id.uuidString)
        let manifest = try CloudVideoArchive.createStagingPackage(record: record, mediaURL: source, at: package)
        XCTAssertEqual(record.candidate.kind, .hls)
        XCTAssertEqual(manifest.fileExtension, "mp4")
        XCTAssertEqual(manifest.sourceHost, "example.org")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: package.path)), Set(["manifest.json", "video.mp4"]))
        let json = try String(contentsOf: package.appendingPathComponent("manifest.json"), encoding: .utf8)
        for secret in ["https://", "signedSecret", "pageSecret", "frameSecret", "private-path", "localRelativePath"] {
            XCTAssertFalse(json.contains(secret))
        }
    }

    func testHLSSystemPackageAndIncompleteOrLinkedPortableFilesAreIneligible() throws {
        let record = makeRecord(kind: .hls)
        let package = root.appendingPathComponent("movie.movpkg", isDirectory: true)
        let disguisedDirectory = root.appendingPathComponent("directory.mp4", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: disguisedDirectory, withIntermediateDirectories: false)
        let segment = root.appendingPathComponent("segment.m4s")
        try Data("segment".utf8).write(to: segment)
        let empty = try writeMedia(Data())
        let regular = try writeMedia(Data("portable".utf8))
        let linked = root.appendingPathComponent("linked.mp4")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: regular)
        for source in [package, disguisedDirectory, segment, empty, linked] {
            XCTAssertFalse(CloudVideoArchive.isEligibleForSync(record: record, mediaURL: source))
            XCTAssertThrowsError(try CloudVideoArchive.createStagingPackage(record: record, mediaURL: source,
                at: root.appendingPathComponent(record.id.uuidString)))
        }
        for duration in [Double.nan, .infinity, 0, -1] {
            var invalid = record; invalid.duration = duration
            XCTAssertFalse(CloudVideoArchive.isEligibleForSync(record: invalid, mediaURL: regular))
        }
    }

    func testManifestRejectsPathEscapesUnknownSchemaAndUnexpectedHosts() throws {
        let (package, _) = try createPackage()
        let manifestURL = package.appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: manifestURL)
        for (key, value) in [("fileExtension", "../../outside"), ("fileExtension", "movpkg"),
                              ("sourceHost", "https://example.org/?secret=value"), ("sourceHost", "example.org:443"),
                              ("sha256", String(repeating: "g", count: 64)), ("title", String(repeating: "a", count: 241))] {
            var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            dictionary[key] = value
            try JSONSerialization.data(withJSONObject: dictionary).write(to: manifestURL)
            XCTAssertThrowsError(try CloudVideoArchive.readManifest(at: package), "Accepted \(key)")
        }
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        dictionary["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: dictionary).write(to: manifestURL)
        XCTAssertThrowsError(try CloudVideoArchive.readManifest(at: package))
    }

    func testManifestSizeAndDirectoryIdentityAreChecked() throws {
        let (package, _) = try createPackage()
        let renamed = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: package, to: renamed)
        XCTAssertThrowsError(try CloudVideoArchive.readManifest(at: renamed))
        try Data(repeating: 0x20, count: CloudVideoArchive.maximumManifestBytes + 1)
            .write(to: renamed.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try CloudVideoArchive.readManifest(at: renamed))
    }

    func testSymbolicLinksAreRejectedForSourceMediaAndPackageFiles() throws {
        let source = try writeMedia(Data("hello".utf8))
        let linkedSource = root.appendingPathComponent("linked.mp4")
        try FileManager.default.createSymbolicLink(at: linkedSource, withDestinationURL: source)
        let record = makeRecord()
        XCTAssertThrowsError(try CloudVideoArchive.createStagingPackage(record: record, mediaURL: linkedSource,
            at: root.appendingPathComponent(record.id.uuidString)))

        let (package, manifest) = try createPackage()
        let media = package.appendingPathComponent("video.mp4")
        try FileManager.default.removeItem(at: media)
        try FileManager.default.createSymbolicLink(at: media, withDestinationURL: source)
        XCTAssertThrowsError(try CloudVideoArchive.verifyMedia(at: package, manifest: manifest))

        let manifestURL = package.appendingPathComponent("manifest.json")
        let outsideManifest = root.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: manifestURL, to: outsideManifest)
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: outsideManifest)
        XCTAssertThrowsError(try CloudVideoArchive.readManifest(at: package))
    }

    func testThumbnailBoundsAndFormatAreCheckedWithoutCreatingPackage() throws {
        let source = try writeMedia(Data("hello".utf8))
        let record = makeRecord()
        let package = root.appendingPathComponent(record.id.uuidString)
        for jpeg in [Data("not a JPEG".utf8), Data(repeating: 0xff, count: CloudVideoArchive.maximumThumbnailBytes + 1)] {
            XCTAssertThrowsError(try CloudVideoArchive.createStagingPackage(record: record, mediaURL: source,
                thumbnailJPEG: jpeg, at: package))
            XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
        }
    }

    func testExistingPackageCannotBeOverwrittenAndEmptyMediaIsRejected() throws {
        let (package, original) = try createPackage()
        let record = makeRecord(id: original.id)
        let replacement = try writeMedia(Data("replacement".utf8))
        XCTAssertThrowsError(try CloudVideoArchive.createStagingPackage(record: record, mediaURL: replacement, at: package))
        XCTAssertEqual(try CloudVideoArchive.readManifest(at: package), original)
        XCTAssertNoThrow(try CloudVideoArchive.verifyMedia(at: package, manifest: original))

        let emptyRecord = makeRecord()
        let empty = try writeMedia(Data())
        XCTAssertThrowsError(try CloudVideoArchive.createStagingPackage(record: emptyRecord, mediaURL: empty,
            at: root.appendingPathComponent(emptyRecord.id.uuidString)))
    }

    private func makeRecord(id: UUID = UUID(), phase: DownloadPhase = .complete, kind: MediaKind = .file) -> DownloadRecord {
        let candidate = MediaCandidate(url: URL(string: "https://cdn.example.org/private-path/video.mp4?token=signedSecret")!,
            pageURL: URL(string: "https://example.org/private-path/watch?session=pageSecret")!,
            frameURL: URL(string: "https://example.org/player?auth=frameSecret")!, title: "示例视频", kind: kind, source: "video")
        return DownloadRecord(id: id, candidate: candidate, phase: phase, progress: 1, bytesWritten: 5,
            expectedBytes: 5, localRelativePath: "Media/private-path.mp4", failure: nil, duration: 65,
            hasAudio: true, createdAt: Date(timeIntervalSince1970: 1_750_000_000))
    }

    private func writeMedia(_ data: Data) throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).mp4")
        try data.write(to: url)
        return url
    }

    private func createPackage(bytes: Data = Data("hello".utf8)) throws -> (URL, CloudVideoManifest) {
        let record = makeRecord()
        let source = try writeMedia(bytes)
        let package = root.appendingPathComponent(record.id.uuidString)
        let manifest = try CloudVideoArchive.createStagingPackage(record: record, mediaURL: source, at: package)
        return (package, manifest)
    }
}
