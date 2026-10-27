import Foundation
import UIKit
import XCTest
@testable import VYu

/// Cache transactions use tiny synthetic owned files. These tests do not claim
/// that the synthetic bytes are playable or that a cloud upload has occurred.
@MainActor final class LocalVideoCacheTests: XCTestCase {
    private var roots: [URL] = []
    private var managers: [DownloadManager] = []
    private let bytes = Data(repeating: 23, count: 4_096)

    override func tearDown() async throws {
        managers = []
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }

    func testEvictionWritesStateBeforeUnlinkAndPreservesIdentityMetadataAndThumbnail() throws {
        let root = try temporaryRoot(), record = completeRecord()
        var stateWasEvictedBeforeRemoval = false
        let hooks = VideoCacheEvictionHooks(beforeFileRemoval: {
            let saved = try self.savedRecords(root)
            stateWasEvictedBeforeRemoval = saved.first?.localCacheEvicted == true && saved.first?.localRelativePath == nil
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(record.localRelativePath!).path))
        })
        let manager = try makeManager(root: root, records: [record], hooks: hooks)
        let store = VideoMetadataStore(rootDirectory: root)
        try store.toggleFavorite(record.id)
        try store.setTags(["收藏", "家庭"], for: record.id)
        try store.rename("保留自定义名称", for: record.id, fallback: record.candidate.title)
        try store.setCoverFrameSeconds(2.5, for: record.id)
        let metadata = store.entries
        let thumbnail = root.appendingPathComponent("Thumbnails/\(record.id.uuidString)_retained.jpg")
        try bytes.write(to: thumbnail)
        let identity = try XCTUnwrap(manager.cacheFileIdentity(for: record))
        XCTAssertEqual(identity.byteCount, Int64(bytes.count))
        XCTAssertTrue(manager.canEvictLocalCache(record))

        XCTAssertTrue(try manager.evictLocalCache(record: record, expectedIdentity: identity))

        XCTAssertTrue(stateWasEvictedBeforeRemoval)
        XCTAssertFalse(FileManager.default.fileExists(atPath: identity.url.path))
        let evicted = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(evicted.id, record.id)
        XCTAssertEqual(evicted.candidate, record.candidate)
        XCTAssertEqual(evicted.duration, record.duration)
        XCTAssertEqual(evicted.hasAudio, record.hasAudio)
        XCTAssertEqual(evicted.createdAt, record.createdAt)
        XCTAssertEqual(evicted.bytesWritten, record.bytesWritten)
        XCTAssertEqual(evicted.phase, .cancelled)
        XCTAssertEqual(evicted.localCacheEvicted, true)
        XCTAssertNil(evicted.localRelativePath)
        XCTAssertNil(evicted.failure)
        XCTAssertEqual(try savedRecords(root), [evicted])
        XCTAssertEqual(try Data(contentsOf: thumbnail), bytes)

        let restarted = DownloadManager(rootDirectory: root)
        managers.append(restarted)
        XCTAssertEqual(restarted.records, [evicted])
        XCTAssertEqual(try Data(contentsOf: thumbnail), bytes, "Startup must keep the preview for a cloud-only record.")
        XCTAssertEqual(VideoMetadataStore(rootDirectory: root).entries, metadata)
    }

    func testEvictionCancelsPendingDecoderWithoutErasingTheRetainedPreview() async throws {
        let root = try temporaryRoot(), record = completeRecord()
        let manager = try makeManager(root: root, records: [record])
        let source = try XCTUnwrap(manager.localURL(for: record))
        let cache = root.appendingPathComponent("PreviewRace", isDirectory: true)
        var continuation: CheckedContinuation<Data?, Never>?
        let store = VideoThumbnailStore(directory: cache) { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        let pending = Task { await store.image(for: record, localURL: source) }
        let deadline = Date().addingTimeInterval(2)
        while continuation == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard let decoding = continuation else {
            pending.cancel()
            return XCTFail("The controlled decoder did not start.")
        }
        let jpeg = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.jpegData(compressionQuality: 0.8))
        let retained = cache.appendingPathComponent("\(record.id.uuidString)_retained.jpg")
        try jpeg.write(to: retained)
        store.prepareForCacheEviction(id: record.id)
        try FileManager.default.removeItem(at: source)
        decoding.resume(returning: nil)
        let result = await pending.value
        XCTAssertNil(result)
        XCTAssertEqual(try Data(contentsOf: retained), jpeg)
        var evicted = record
        evicted.phase = .cancelled
        evicted.localRelativePath = nil
        evicted.localCacheEvicted = true
        let cached = await store.image(for: evicted, localURL: nil)
        XCTAssertNotNil(cached)
        XCTAssertEqual(try Data(contentsOf: retained), jpeg)
    }

    func testStateWriteFailureNeverRemovesVideoOrPublishesEviction() throws {
        let root = try temporaryRoot(), record = completeRecord()
        let manager = try makeManager(root: root, records: [record], hooks: VideoCacheEvictionHooks(beforeStateWrite: {
            throw CocoaError(.fileWriteOutOfSpace)
        }))
        let before = try Data(contentsOf: root.appendingPathComponent("downloads.json"))
        let identity = try XCTUnwrap(manager.cacheFileIdentity(for: record))
        XCTAssertThrowsError(try manager.evictLocalCache(record: record, expectedIdentity: identity))
        XCTAssertEqual(manager.records, [record])
        XCTAssertEqual(try Data(contentsOf: identity.url), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("downloads.json")), before)
        XCTAssertNotNil(manager.storageError)
        let restarted = DownloadManager(rootDirectory: root)
        managers.append(restarted)
        XCTAssertEqual(restarted.records, [record])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache-eviction.json").path))
    }

    func testRealArchiveWriteFailureRetainsMediaAndThePreviousArchive() throws {
        let root = try temporaryRoot(), record = completeRecord()
        let manager = try makeManager(root: root, records: [record])
        let identity = try XCTUnwrap(manager.cacheFileIdentity(for: record))
        let state = root.appendingPathComponent("downloads.json")
        let previous = root.appendingPathComponent("previous-state.json")
        try FileManager.default.moveItem(at: state, to: previous)
        let before = try Data(contentsOf: previous)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        XCTAssertThrowsError(try manager.evictLocalCache(record: record, expectedIdentity: identity))
        XCTAssertEqual(manager.records, [record])
        XCTAssertEqual(try Data(contentsOf: identity.url), bytes)
        XCTAssertEqual(try Data(contentsOf: previous), before)
        XCTAssertNotNil(manager.storageError)
        // Restore only the test's deliberately obstructed state-file path.
        try FileManager.default.removeItem(at: state)
        try FileManager.default.moveItem(at: previous, to: state)
        let restarted = DownloadManager(rootDirectory: root)
        managers.append(restarted)
        XCTAssertEqual(restarted.records, [record])
    }

    func testUnlinkFailureRollsBackDurableStateAndRetainsOriginalFile() throws {
        let root = try temporaryRoot(), record = completeRecord()
        let manager = try makeManager(root: root, records: [record], hooks: VideoCacheEvictionHooks(beforeFileRemoval: {
            throw CocoaError(.fileWriteNoPermission)
        }))
        let identity = try XCTUnwrap(manager.cacheFileIdentity(for: record))
        XCTAssertThrowsError(try manager.evictLocalCache(record: record, expectedIdentity: identity))
        XCTAssertEqual(manager.records, [record])
        XCTAssertEqual(try savedRecords(root), [record])
        XCTAssertEqual(try Data(contentsOf: identity.url), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache-eviction.json").path))
        XCTAssertTrue(manager.canEvictLocalCache(record), "A successfully rolled-back cleanup can be attempted later.")
    }

    func testFailedRollbackKeepsRecoveryJournalAndLaunchRestoresOriginalRecord() throws {
        let root = try temporaryRoot(), record = completeRecord()
        var writes = 0
        let hooks = VideoCacheEvictionHooks(beforeStateWrite: {
            writes += 1
            if writes == 2 { throw CocoaError(.fileWriteOutOfSpace) }
        }, beforeFileRemoval: { throw CocoaError(.fileWriteNoPermission) })
        let manager = try makeManager(root: root, records: [record], hooks: hooks)
        let identity = try XCTUnwrap(manager.cacheFileIdentity(for: record))
        XCTAssertThrowsError(try manager.evictLocalCache(record: record, expectedIdentity: identity))
        XCTAssertEqual(manager.records, [record], "The current process still exposes its retained playable copy.")
        XCTAssertEqual(try savedRecords(root).first?.localCacheEvicted, true)
        XCTAssertEqual(try Data(contentsOf: identity.url), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache-eviction.json").path))
        XCTAssertFalse(manager.canEvictLocalCache(record), "An unresolved recovery cannot be overwritten by another transaction.")

        let restarted = DownloadManager(rootDirectory: root)
        managers.append(restarted)
        XCTAssertEqual(restarted.records, [record])
        XCTAssertEqual(try savedRecords(root), [record])
        XCTAssertEqual(try Data(contentsOf: identity.url), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache-eviction.json").path))
    }

    func testCrashAfterUnlinkKeepsEvictedStateAndDoesNotResurrectMissingFile() throws {
        let root = try temporaryRoot(), record = completeRecord()
        var journalAtUnlink: Data?
        let manager = try makeManager(root: root, records: [record], hooks: VideoCacheEvictionHooks(beforeFileRemoval: {
            journalAtUnlink = try Data(contentsOf: root.appendingPathComponent("cache-eviction.json"))
        }))
        let identity = try XCTUnwrap(manager.cacheFileIdentity(for: record))
        XCTAssertTrue(try manager.evictLocalCache(record: record, expectedIdentity: identity))
        // Replay the journal left by a process terminating after unlink, before
        // its final journal cleanup, using the real transaction's encoded data.
        try XCTUnwrap(journalAtUnlink).write(to: root.appendingPathComponent("cache-eviction.json"))
        let restarted = DownloadManager(rootDirectory: root)
        managers.append(restarted)
        XCTAssertEqual(restarted.records, manager.records)
        XCTAssertEqual(restarted.records.first?.localCacheEvicted, true)
        XCTAssertNil(restarted.records.first?.localRelativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: identity.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache-eviction.json").path))
    }

    func testReaderLeasesRequireEveryReaderToFinish() throws {
        let manager = try makeManager(records: [completeRecord()])
        let record = try XCTUnwrap(manager.records.first)
        let identity = try XCTUnwrap(manager.cacheFileIdentity(for: record))
        let first = manager.beginUsingLocalVideo(id: record.id)
        let second = manager.beginUsingLocalVideo(id: record.id)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(manager.localVideoUseIDs, [record.id])
        XCTAssertFalse(manager.canEvictLocalCache(record))
        XCTAssertFalse(try manager.evictLocalCache(record: record, expectedIdentity: identity))
        manager.endUsingLocalVideo(first)
        manager.endUsingLocalVideo(first)
        XCTAssertTrue(manager.isLocalVideoInUse(id: record.id))
        XCTAssertFalse(manager.canEvictLocalCache(record))
        manager.endUsingLocalVideo(second)
        XCTAssertTrue(manager.localVideoUseIDs.isEmpty)
        XCTAssertTrue(manager.canEvictLocalCache(record))
    }

    func testChangedFileIdentityOrStaleRecordCannotBeEvicted() throws {
        let manager = try makeManager(records: [completeRecord()])
        let record = try XCTUnwrap(manager.records.first)
        let identity = try XCTUnwrap(manager.cacheFileIdentity(for: record))
        var stale = record
        stale.duration = 99
        XCTAssertFalse(manager.canEvictLocalCache(stale))
        XCTAssertFalse(try manager.evictLocalCache(record: stale, expectedIdentity: identity))
        let replacement = bytes + Data([1])
        try replacement.write(to: identity.url, options: .atomic)
        XCTAssertNotEqual(manager.cacheFileIdentity(for: record), identity)
        XCTAssertFalse(try manager.evictLocalCache(record: record, expectedIdentity: identity))
        XCTAssertEqual(manager.records, [record])
        XCTAssertEqual(try Data(contentsOf: identity.url), replacement)
    }

    func testIdentityChangeAfterStateWriteRollsBackWithoutDeletingReplacement() throws {
        let root = try temporaryRoot(), record = completeRecord()
        let source = root.appendingPathComponent(record.localRelativePath!)
        let replacement = bytes + Data([9])
        let manager = try makeManager(root: root, records: [record], hooks: VideoCacheEvictionHooks(beforeFileRemoval: {
            try replacement.write(to: source, options: .atomic)
        }))
        let identity = try XCTUnwrap(manager.cacheFileIdentity(for: record))
        XCTAssertThrowsError(try manager.evictLocalCache(record: record, expectedIdentity: identity))
        XCTAssertEqual(manager.records, [record])
        XCTAssertEqual(try savedRecords(root), [record])
        XCTAssertEqual(try Data(contentsOf: source), replacement)
    }

    func testSymlinkFileAndMediaDirectoryAreNeverEvictable() throws {
        let outside = try temporaryRoot()
        let outsideFile = outside.appendingPathComponent("protected.mp4")
        try bytes.write(to: outsideFile)
        let root = try temporaryRoot(), record = completeRecord()
        let manager = try makeManager(root: root, records: [record])
        let local = root.appendingPathComponent(record.localRelativePath!)
        try FileManager.default.removeItem(at: local)
        try FileManager.default.createSymbolicLink(at: local, withDestinationURL: outsideFile)
        XCTAssertNil(manager.cacheFileIdentity(for: record))
        XCTAssertFalse(manager.canEvictLocalCache(record))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Media"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Media"), withDestinationURL: outside)
        XCTAssertNil(manager.cacheFileIdentity(for: record))
        XCTAssertFalse(manager.canEvictLocalCache(record))
        XCTAssertEqual(try Data(contentsOf: outsideFile), bytes)
    }

    func testRootAliasAndNestedOrTraversalPathsAreRejected() throws {
        let root = try temporaryRoot(), record = completeRecord()
        let manager = try makeManager(root: root, records: [record])
        for path in ["../outside.mp4", "/tmp/outside.mp4", "Media/../outside.mp4", "Media/nested/video.mp4", "Media/video.movpkg", "Media/test.mp4/", "Media/\0.mp4"] {
            var changed = record
            changed.localRelativePath = path
            XCTAssertNil(manager.cacheFileIdentity(for: changed), path)
        }
        let alias = try temporaryRoot().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let aliasManager = DownloadManager(rootDirectory: alias)
        managers.append(aliasManager)
        XCTAssertNil(aliasManager.cacheFileIdentity(for: record))
        XCTAssertFalse(aliasManager.canEvictLocalCache(record))
    }

    func testIncompleteRecordAndSharedLocalPathArePreserved() throws {
        let record = completeRecord()
        for phase in [DownloadPhase.queued, .downloading, .paused, .validating, .failed, .cancelled] {
            var changed = record
            changed.phase = phase
            let manager = try makeManager(records: [changed])
            XCTAssertFalse(manager.canEvictLocalCache(changed), phase.rawValue)
        }
        var noDuration = record
        noDuration.duration = nil
        let missingValidation = try makeManager(records: [noDuration])
        XCTAssertFalse(missingValidation.canEvictLocalCache(noDuration))
        var second = completeRecord()
        second.localRelativePath = record.localRelativePath
        let shared = try makeManager(records: [record, second])
        XCTAssertFalse(shared.canEvictLocalCache(record))
        XCTAssertFalse(shared.canEvictLocalCache(second))
    }

    func testLegacyRecordsDecodeWithoutMarkerAndEvictedRetryNeverUsesSource() async throws {
        let record = completeRecord(), root = try temporaryRoot()
        let manager = try makeManager(root: root, records: [record])
        let legacy = try String(contentsOf: root.appendingPathComponent("downloads.json"), encoding: .utf8)
        XCTAssertFalse(legacy.contains("localCacheEvicted"))
        XCTAssertNil(manager.records.first?.localCacheEvicted)
        let identity = try XCTUnwrap(manager.cacheFileIdentity(for: record))
        XCTAssertTrue(try manager.evictLocalCache(record: record, expectedIdentity: identity))
        let evicted = manager.records
        let saved = try Data(contentsOf: root.appendingPathComponent("downloads.json"))
        await manager.retry(id: record.id, cookies: [])
        XCTAssertEqual(manager.records, evicted)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("downloads.json")), saved)
    }

    private func makeManager(root: URL? = nil, records: [DownloadRecord],
                             hooks: VideoCacheEvictionHooks = VideoCacheEvictionHooks()) throws -> DownloadManager {
        let directory = try root ?? temporaryRoot()
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Media"), withIntermediateDirectories: true)
        for record in records {
            if let path = record.localRelativePath, path.hasPrefix("Media/"), !path.dropFirst(6).contains("/") {
                try bytes.write(to: directory.appendingPathComponent(path))
            }
        }
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("downloads.json"))
        let manager = DownloadManager(rootDirectory: directory, cacheEvictionHooks: hooks)
        managers.append(manager)
        return manager
    }

    private func savedRecords(_ root: URL) throws -> [DownloadRecord] {
        let data = try Data(contentsOf: root.appendingPathComponent("downloads.json"))
        if let legacy = try? JSONDecoder().decode([DownloadRecord].self, from: data) { return legacy }
        struct Archive: Decodable { let records: [DownloadRecord] }
        return try JSONDecoder().decode(Archive.self, from: data).records
    }

    private func completeRecord() -> DownloadRecord {
        let id = UUID(), url = URL(string: "https://example.test/video.mp4")!
        return DownloadRecord(id: id, candidate: MediaCandidate(url: url, pageURL: url, frameURL: url,
            title: "保留视频标题", kind: .file, source: "syntheticCacheTest"), phase: .complete, progress: 1,
            bytesWritten: Int64(bytes.count), expectedBytes: Int64(bytes.count), localRelativePath: "Media/\(id.uuidString).mp4",
            failure: nil, duration: 8, hasAudio: true, createdAt: Date(timeIntervalSince1970: 123))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYuCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }
}
