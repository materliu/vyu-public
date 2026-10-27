import XCTest
@testable import VYu

/// All media and cloud directories are synthetic state fixtures; no user container is accessed.
@MainActor final class CloudVideoCacheEvictionTests: XCTestCase {
    private var roots: [URL] = []
    private var managers: [DownloadManager] = []
    private var controllers: [CloudVideoSync] = []
    private let bytes = Data("synthetic completed video bytes".utf8)

    override func tearDown() async throws {
        for controller in controllers { controller.cancelCacheEvictions() }
        controllers = []; managers = []
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }

    func testMatchingUploadedSyntheticArchiveProvesLocalCopyWithoutChangingEitherFile() throws {
        let fixture = try makeArchive()
        XCTAssertTrue(try prove(fixture))
        XCTAssertEqual(try Data(contentsOf: fixture.local), bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.media), bytes)
    }

    func testStagedManifestMatchesPersistedFractionalTimestampExactly() throws {
        for index in 0..<16 {
            let date = Date(timeIntervalSinceReferenceDate: 800_000_000.1234567 + Double(index) * 0.00000013)
            let fixture = try makeArchive(createdAt: date)
            let persisted = try CloudVideoArchive.readManifest(at: fixture.media.deletingLastPathComponent())
            XCTAssertEqual(fixture.entry.manifest, persisted,
                "The published declaration must use the exact timestamp that a later snapshot will read.")
            XCTAssertTrue(try prove(fixture))
        }
    }

    func testPendingOrFailedUploadCannotProveRecovery() throws {
        let fixture = try makeArchive()
        for entry in [
            CloudVideoEntry(manifest: fixture.entry.manifest, thumbnail: nil, uploaded: false, transferError: false),
            CloudVideoEntry(manifest: fixture.entry.manifest, thumbnail: nil, uploaded: true, transferError: true)
        ] {
            XCTAssertFalse(try CloudVideoFiles.canRemoveLocalCache(entry: entry, localURL: fixture.local,
                container: fixture.cloud, ubiquitous: false))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.local), bytes)
    }

    func testNativeProofRejectsOrdinaryLocalDirectoryMasqueradingAsUploadedICloud() throws {
        let fixture = try makeArchive()
        XCTAssertFalse(try CloudVideoFiles.canRemoveLocalCache(entry: fixture.entry, localURL: fixture.local,
            container: fixture.cloud, ubiquitous: true))
        XCTAssertEqual(try Data(contentsOf: fixture.local), bytes)
    }

    func testAlteredLocalOrArchivedBytesPreventEvictionProof() throws {
        let fixture = try makeArchive()
        let altered = Data(repeating: 0x61, count: bytes.count)
        try altered.write(to: fixture.local)
        XCTAssertThrowsError(try prove(fixture))
        XCTAssertEqual(try Data(contentsOf: fixture.local), altered)
        try bytes.write(to: fixture.local)
        try altered.write(to: fixture.media)
        XCTAssertThrowsError(try prove(fixture))
        XCTAssertEqual(try Data(contentsOf: fixture.local), bytes)
    }

    func testChangedManifestAndDeletionPlaceholderPreventProof() throws {
        let fixture = try makeArchive()
        let manifestURL = fixture.media.deletingLastPathComponent().appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: manifestURL)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        json["title"] = "Another declaration"
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)
        XCTAssertFalse(try prove(fixture))
        try original.write(to: manifestURL)
        let deletion = fixture.cloud.appendingPathComponent("Deleted/.\(fixture.entry.id.uuidString).deleted.icloud")
        try Data().write(to: deletion)
        XCTAssertFalse(try prove(fixture))
        XCTAssertEqual(try Data(contentsOf: fixture.local), bytes)
    }

    func testStaleOrCancelledAccountAccessCannotProveRecovery() throws {
        let fixture = try makeArchive()
        let identity = CacheFixtureIdentity("first")
        let access = CloudSyncAccess(account: "first", identity: { identity.get() })
        identity.set("second")
        XCTAssertThrowsError(try prove(fixture, access: access)) { XCTAssertTrue($0 is CancellationError) }
        identity.set("first"); access.cancel()
        XCTAssertThrowsError(try prove(fixture, access: access)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: fixture.local), bytes)
    }

    func testSyntheticServerIsNeverCountedOrEvictedAsDeviceCache() throws {
        let fixture = try makeArchive()
        XCTAssertEqual(try CloudVideoFiles.residentMediaBytes(entries: [fixture.entry],
            container: fixture.cloud, ubiquitous: false), 0)
        XCTAssertEqual(try CloudVideoFiles.evictResidentMedia(entry: fixture.entry,
            container: fixture.cloud, ubiquitous: false), 0)
        XCTAssertEqual(try Data(contentsOf: fixture.media), bytes)
    }

    func testUnsynchronizedCoverSelectionKeepsTheLocalMediaNeededToRenderIt() throws {
        let fixture = try makeArchive()
        let metadata = VideoMetadata(id: fixture.entry.id, isFavorite: false, tags: [], updatedAt: Date(),
            revision: UUID(), coverFrameSeconds: 4)
        XCTAssertFalse(try CloudVideoFiles.canRemoveLocalCache(entry: fixture.entry, localURL: fixture.local,
            container: fixture.cloud, ubiquitous: false, metadata: metadata))
        XCTAssertEqual(try Data(contentsOf: fixture.local), bytes)
    }

    func testControllerEvictionRetainsCloudEntryServerBytesAndLocalRecordAcrossRestart() async throws {
        let fixture = try await makeController()
        let removed = try await fixture.sync.evictLocalCacheIfRecoverable(id: fixture.record.id) { true }
        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.local.path))
        XCTAssertNotNil(fixture.sync.entry(for: fixture.record.id))
        let retained = try XCTUnwrap(fixture.manager.records.first)
        XCTAssertEqual(retained.id, fixture.record.id)
        XCTAssertNil(retained.localRelativePath)
        XCTAssertEqual(retained.candidate.title, fixture.record.candidate.title)
        let package = CloudVideoFiles.packageURL(fixture.record.id, container: fixture.cloud)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("video.mp4")), bytes)
        let restarted = DownloadManager(rootDirectory: fixture.manager.rootDirectory)
        managers.append(restarted)
        XCTAssertNil(restarted.records.first?.localRelativePath)
        XCTAssertEqual(restarted.records.first?.id, retained.id)
    }

    func testRevokedPreferenceAfterProofKeepsLocalFile() async throws {
        let fixture = try await makeController()
        var checks = 0
        let removed = try await fixture.sync.evictLocalCacheIfRecoverable(id: fixture.record.id) {
            checks += 1
            return checks == 1
        }
        XCTAssertFalse(removed)
        XCTAssertGreaterThanOrEqual(checks, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.local), bytes)
    }

    func testLeaseAndPendingPlaybackProtectLocalVideo() async throws {
        let fixture = try await makeController()
        let lease = fixture.manager.beginUsingLocalVideo(id: fixture.record.id)
        let whileInUse = try await fixture.sync.evictLocalCacheIfRecoverable(id: fixture.record.id) { true }
        XCTAssertFalse(whileInUse)
        fixture.manager.endUsingLocalVideo(lease)
        fixture.sync.readyToPlay = fixture.record
        let pendingPlayback = try await fixture.sync.evictLocalCacheIfRecoverable(id: fixture.record.id) { true }
        XCTAssertFalse(pendingPlayback)
        XCTAssertEqual(try Data(contentsOf: fixture.local), bytes)
    }

    func testReplacementBetweenProofAndCommitKeepsReplacementBytes() async throws {
        let fixture = try await makeController()
        let replacement = Data(repeating: 0x62, count: bytes.count)
        var checks = 0
        let removed = try await fixture.sync.evictLocalCacheIfRecoverable(id: fixture.record.id) {
            checks += 1
            if checks == 2 { try? replacement.write(to: fixture.local, options: .atomic) }
            return true
        }
        XCTAssertFalse(removed)
        XCTAssertEqual(try Data(contentsOf: fixture.local), replacement)
    }

    func testAccountChangeImmediatelyBeforeCommitKeepsLocalVideo() async throws {
        let identity = CacheFixtureIdentity("first")
        let fixture = try await makeController(identity: identity)
        var checks = 0
        do {
            _ = try await fixture.sync.evictLocalCacheIfRecoverable(id: fixture.record.id) {
                checks += 1
                if checks == 2 { identity.set("second") }
                return true
            }
            XCTFail("A stale native identity must prevent removing the local copy.")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: fixture.local), bytes)
    }

    func testControllerSkipsMissingBackupAndSyntheticCloudUsageIsZero() async throws {
        let fixture = try await makeController()
        let package = CloudVideoFiles.packageURL(fixture.record.id, container: fixture.cloud)
        try FileManager.default.removeItem(at: package.appendingPathComponent("video.mp4"))
        do {
            let removed = try await fixture.sync.evictLocalCacheIfRecoverable(id: fixture.record.id) { true }
            XCTAssertFalse(removed)
        } catch { XCTAssertTrue(error is CloudVideoArchiveError || error is CocoaError) }
        XCTAssertEqual(try Data(contentsOf: fixture.local), bytes)
        let usage = try await fixture.sync.localCloudMediaUsage()
        XCTAssertEqual(usage, 0)
        let reclaimed = await fixture.sync.evictCloudOnlyMediaCaches { true }
        XCTAssertEqual(reclaimed, 0)
    }

    func testNativeUsageFailureIsNotReportedAsZero() async throws {
        let manager = DownloadManager(rootDirectory: try temporaryDirectory())
        managers.append(manager)
        let sync = CloudVideoSync(downloads: manager, iCloudEnabled: false)
        controllers.append(sync)
        do {
            _ = try await sync.localCloudMediaUsage()
            XCTFail("Unavailable cache accounting must remain an error.")
        } catch { XCTAssertTrue(error is CloudVideoArchiveError) }
    }

    private struct ArchiveFixture {
        let local: URL
        let cloud: URL
        let media: URL
        let entry: CloudVideoEntry
    }

    private func makeArchive(createdAt: Date? = nil) throws -> ArchiveFixture {
        let root = try temporaryDirectory(), cloud = try temporaryDirectory()
        try CloudVideoFiles.prepare(container: cloud)
        var record = makeRecord()
        if let createdAt { record.createdAt = createdAt }
        let local = root.appendingPathComponent("video.mp4")
        try bytes.write(to: local)
        let package = CloudVideoFiles.packageURL(record.id, container: cloud)
        let manifest = try CloudVideoArchive.createStagingPackage(record: record, mediaURL: local, at: package)
        return ArchiveFixture(local: local, cloud: cloud, media: package.appendingPathComponent("video.mp4"),
            entry: CloudVideoEntry(manifest: manifest, thumbnail: nil, uploaded: true, transferError: false))
    }

    private func prove(_ fixture: ArchiveFixture, access: CloudSyncAccess? = nil) throws -> Bool {
        try CloudVideoFiles.canRemoveLocalCache(entry: fixture.entry, localURL: fixture.local,
            container: fixture.cloud, ubiquitous: false, access: access)
    }

    private func makeController(identity: CacheFixtureIdentity = CacheFixtureIdentity("first")) async throws
        -> (manager: DownloadManager, sync: CloudVideoSync, record: DownloadRecord, local: URL, cloud: URL) {
        let root = try temporaryDirectory(), cloud = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Media"), withIntermediateDirectories: true)
        let record = makeRecord(relative: "Media/cache.mp4")
        let local = root.appendingPathComponent("Media/cache.mp4")
        try bytes.write(to: local)
        try JSONEncoder().encode([record]).write(to: root.appendingPathComponent("downloads.json"))
        let manager = DownloadManager(rootDirectory: root)
        managers.append(manager)
        let sync = CloudVideoSync(downloads: manager, containerOverride: cloud, identityOverride: { identity.get() })
        controllers.append(sync)
        await sync.refreshAccount()
        XCTAssertNotNil(sync.entry(for: record.id))
        XCTAssertTrue(manager.canEvictLocalCache(record))
        return (manager, sync, record, local, cloud)
    }

    private func makeRecord(relative: String? = nil) -> DownloadRecord {
        let url = URL(string: "https://example.invalid/synthetic.mp4")!
        let candidate = MediaCandidate(url: url, pageURL: url, frameURL: url,
            title: "Synthetic cached video", kind: .file, source: "fixture")
        return DownloadRecord(id: UUID(), candidate: candidate, phase: .complete, progress: 1,
            bytesWritten: Int64(bytes.count), expectedBytes: Int64(bytes.count), localRelativePath: relative,
            failure: nil, duration: 8, hasAudio: true, createdAt: Date())
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYuCacheEviction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }
}

private final class CacheFixtureIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String?) { self.value = value }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: String?) { lock.lock(); self.value = value; lock.unlock() }
}
