import Foundation
import XCTest
@testable import VYu

/// Exercises the local transport with synthetic bytes, without iCloud accounts or AV playback.
final class CloudVideoFilesTests: XCTestCase {
    func testManifestAppearsOnlyAfterPublicationAndUnrelatedMetadataIsIgnored() async throws {
        try await Task.detached {
            let root = try Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let container = root.appendingPathComponent("Cloud")
            try CloudVideoFiles.prepare(container: container)
            let fixture = try Self.package(in: root)
            let before = try CloudVideoFiles.snapshot(container: container,
                metadataURLs: [fixture.url.appendingPathComponent(CloudVideoArchive.manifestFilename)], ubiquitous: false)
            XCTAssertTrue(before.entries.isEmpty, "A local staging package is outside the cloud library.")

            try CloudVideoFiles.publish(staging: fixture.url, manifest: fixture.manifest, container: container, ubiquitous: false)
            let published = CloudVideoFiles.packageURL(fixture.manifest.id, container: container)
            let manifestURL = published.appendingPathComponent(CloudVideoArchive.manifestFilename)
            let heldManifest = root.appendingPathComponent("held-manifest.json")
            try FileManager.default.moveItem(at: manifestURL, to: heldManifest)
            let pending = try CloudVideoFiles.snapshot(container: container, metadataURLs: [manifestURL], ubiquitous: false)
            XCTAssertTrue(pending.entries.isEmpty, "Media without its completed manifest is not a cloud video entry.")
            try FileManager.default.moveItem(at: heldManifest, to: manifestURL)

            let unrelated = root.appendingPathComponent("Other/Videos/\(UUID().uuidString)/manifest.json")
            let visible = try CloudVideoFiles.snapshot(container: container, metadataURLs: [manifestURL, unrelated], ubiquitous: false)
            XCTAssertEqual(visible.entries.map(\.id), [fixture.manifest.id])
            XCTAssertEqual(visible.entries.first?.manifest, fixture.manifest)
            XCTAssertEqual(visible.entries.first?.uploaded, true)
            XCTAssertEqual(visible.entries.first?.transferError, false)
            XCTAssertEqual(visible.invalidCount, 0)
        }.value
    }

    func testMissingOrIncompleteMediaNeverProducesAnImportCopy() async throws {
        try await Task.detached {
            let root = try Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let container = root.appendingPathComponent("Cloud")
            try CloudVideoFiles.prepare(container: container)
            let fixture = try Self.package(in: root)
            try CloudVideoFiles.publish(staging: fixture.url, manifest: fixture.manifest, container: container, ubiquitous: false)
            let entry = CloudVideoEntry(manifest: fixture.manifest, thumbnail: nil, uploaded: false, transferError: false)
            let package = CloudVideoFiles.packageURL(entry.id, container: container)
            let media = package.appendingPathComponent("video.mp4")
            let imports = root.appendingPathComponent("Imports")
            try FileManager.default.removeItem(at: media)
            XCTAssertNil(try CloudVideoFiles.downloadCopy(entry: entry, container: container,
                stagingParent: imports, ubiquitous: false))
            XCTAssertFalse(FileManager.default.fileExists(atPath: imports.appendingPathComponent(entry.id.uuidString).path))

            try Data([0, 1, 2]).write(to: media)
            XCTAssertThrowsError(try CloudVideoFiles.downloadCopy(entry: entry, container: container,
                stagingParent: imports, ubiquitous: false)) { error in
                guard case CloudVideoArchiveError.integrityMismatch = error else {
                    return XCTFail("Expected incomplete media to fail its hash and byte count checks.")
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: imports.appendingPathComponent(entry.id.uuidString).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        }.value
    }

    func testPublishedFileRoundTripPreservesBytesAndHash() async throws {
        try await Task.detached {
            let root = try Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let container = root.appendingPathComponent("Cloud")
            try CloudVideoFiles.prepare(container: container)
            let fixture = try Self.package(in: root)
            try CloudVideoFiles.publish(staging: fixture.url, manifest: fixture.manifest, container: container, ubiquitous: false)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
            let snapshot = try CloudVideoFiles.snapshot(container: container, metadataURLs: [], ubiquitous: false)
            let entry = try XCTUnwrap(snapshot.entries.first)
            let imported = try XCTUnwrap(CloudVideoFiles.downloadCopy(entry: entry, container: container,
                stagingParent: root.appendingPathComponent("Imports"), ubiquitous: false))
            let manifest = try CloudVideoArchive.readManifest(at: imported)
            XCTAssertEqual(manifest, fixture.manifest)
            let media = try CloudVideoArchive.verifyMedia(at: imported, manifest: manifest)
            XCTAssertEqual(try Data(contentsOf: media), fixture.bytes)
            XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: imported.path)), ["video.mp4", "manifest.json"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: CloudVideoFiles.packageURL(entry.id, container: container).path))
        }.value
    }

    func testTombstoneWinsOverLatePublicationAndStaleEntries() async throws {
        try await Task.detached {
            let root = try Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let container = root.appendingPathComponent("Cloud")
            try CloudVideoFiles.prepare(container: container)
            let fixture = try Self.package(in: root)
            try CloudVideoFiles.publish(staging: fixture.url, manifest: fixture.manifest, container: container, ubiquitous: false)
            let entry = try XCTUnwrap(CloudVideoFiles.snapshot(container: container, metadataURLs: [], ubiquitous: false).entries.first)
            try CloudVideoFiles.delete(id: entry.id, container: container)
            let late = try Self.package(in: root, id: entry.id, name: "Late")
            try CloudVideoFiles.publish(staging: late.url, manifest: late.manifest, container: container, ubiquitous: false)
            let target = CloudVideoFiles.packageURL(entry.id, container: container)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: late.url.path))

            // Simulate a package arriving from another device after the tombstone.
            try FileManager.default.moveItem(at: late.url, to: target)
            let hidden = try CloudVideoFiles.snapshot(container: container, metadataURLs: [], ubiquitous: false)
            XCTAssertTrue(hidden.entries.isEmpty)
            XCTAssertEqual(hidden.deleted, [entry.id])
            XCTAssertNil(try CloudVideoFiles.downloadCopy(entry: entry, container: container,
                stagingParent: root.appendingPathComponent("Imports"), ubiquitous: false),
                "A cached UI entry must not import a deleted video that arrives late.")
            try CloudVideoFiles.purgeDeletedPackage(id: entry.id, container: container)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(try CloudVideoFiles.snapshot(container: container, metadataURLs: [], ubiquitous: false).deleted, [entry.id])
        }.value
    }

    func testFailedCopyPreservesOtherStagingDirectories() async throws {
        try await Task.detached {
            let root = try Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let container = root.appendingPathComponent("Cloud")
            try CloudVideoFiles.prepare(container: container)
            let fixture = try Self.package(in: root)
            try CloudVideoFiles.publish(staging: fixture.url, manifest: fixture.manifest, container: container, ubiquitous: false)
            let entry = CloudVideoEntry(manifest: fixture.manifest, thumbnail: nil, uploaded: true, transferError: false)
            let imports = root.appendingPathComponent("Imports")
            let other = imports.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let sentinel = other.appendingPathComponent("keep.data")
            let sentinelData = Data([91, 92, 93])
            try sentinelData.write(to: sentinel)
            try Data([1]).write(to: CloudVideoFiles.packageURL(entry.id, container: container).appendingPathComponent("video.mp4"))
            XCTAssertThrowsError(try CloudVideoFiles.downloadCopy(entry: entry, container: container,
                stagingParent: imports, ubiquitous: false))
            XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
            XCTAssertFalse(FileManager.default.fileExists(atPath: imports.appendingPathComponent(entry.id.uuidString).path))
        }.value
    }

    func testCopyDoesNotOverwriteOrRemoveAnExistingStage() async throws {
        try await Task.detached {
            let root = try Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let container = root.appendingPathComponent("Cloud")
            try CloudVideoFiles.prepare(container: container)
            let fixture = try Self.package(in: root)
            try CloudVideoFiles.publish(staging: fixture.url, manifest: fixture.manifest, container: container, ubiquitous: false)
            let entry = CloudVideoEntry(manifest: fixture.manifest, thumbnail: nil, uploaded: true, transferError: false)
            let imports = root.appendingPathComponent("Imports")
            let existing = imports.appendingPathComponent(entry.id.uuidString)
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
            let sentinel = existing.appendingPathComponent("keep.data")
            let sentinelData = Data([31, 32, 33])
            try sentinelData.write(to: sentinel)
            XCTAssertThrowsError(try CloudVideoFiles.downloadCopy(entry: entry, container: container,
                stagingParent: imports, ubiquitous: false))
            XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existing.path), ["keep.data"])
        }.value
    }

    func testDeletionOnlyRemovesTheRequestedVideo() async throws {
        try await Task.detached {
            let root = try Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let container = root.appendingPathComponent("Cloud")
            try CloudVideoFiles.prepare(container: container)
            let first = try Self.package(in: root, name: "First")
            let second = try Self.package(in: root, name: "Second")
            try CloudVideoFiles.publish(staging: first.url, manifest: first.manifest, container: container, ubiquitous: false)
            try CloudVideoFiles.publish(staging: second.url, manifest: second.manifest, container: container, ubiquitous: false)
            try CloudVideoFiles.delete(id: first.manifest.id, container: container)
            let remaining = try CloudVideoFiles.snapshot(container: container, metadataURLs: [], ubiquitous: false)
            XCTAssertEqual(remaining.entries.map(\.id), [second.manifest.id])
            XCTAssertEqual(remaining.deleted, [first.manifest.id])
            let media = try CloudVideoArchive.verifyMedia(at: CloudVideoFiles.packageURL(second.manifest.id, container: container), manifest: second.manifest)
            XCTAssertEqual(try Data(contentsOf: media), second.bytes)
        }.value
    }

    private static func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func package(in root: URL, id: UUID = UUID(), name: String = "Staging") throws
        -> (url: URL, manifest: CloudVideoManifest, bytes: Data) {
        let bytes = Data((0..<16_384).map { UInt8($0 % 251) })
        let source = root.appendingPathComponent("\(name)-source.mp4")
        try bytes.write(to: source)
        let parent = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(id.uuidString, isDirectory: true)
        let url = URL(string: "https://example.test/video.mp4?signature=private-test-value")!
        let candidate = MediaCandidate(url: url, pageURL: URL(string: "https://example.test/watch")!,
            frameURL: url, title: "Synthetic video", kind: .file, source: "test")
        let record = DownloadRecord(id: id, candidate: candidate, phase: .complete, progress: 1,
            bytesWritten: Int64(bytes.count), expectedBytes: Int64(bytes.count), localRelativePath: "Media/video.mp4",
            failure: nil, duration: 5, hasAudio: false, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let manifest = try CloudVideoArchive.createStagingPackage(record: record, mediaURL: source, at: stage)
        return (stage, manifest, bytes)
    }
}
