import AVFoundation
import XCTest
@testable import VYu

/// All media and cloud copies belong to disposable, synthetic app directories.
@MainActor final class VideoStorageOptimizerTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8765")!
    private var directories: [URL] = []
    private var managers: [DownloadManager] = []
    private var controllers: [CloudVideoSync] = []
    private var optimizers: [VideoStorageOptimizer] = []
    private var fixture = Data()

    override func setUp() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let healthData: Data, healthResponse: URLResponse
        do { (healthData, healthResponse) = try await session.data(from: base.appendingPathComponent("__health")) }
        catch let error as URLError where error.code == .cannotConnectToHost {
            throw XCTSkip("Generate fixtures and start fixtures/server.py to run storage optimization tests.")
        }
        guard (healthResponse as? HTTPURLResponse)?.statusCode == 200,
              let health = try JSONSerialization.jsonObject(with: healthData) as? [String: Any],
              health["ready"] as? Bool == true else { throw CloudVideoArchiveError.invalidMedia }
        var control = URLRequest(url: base.appendingPathComponent("__control"))
        control.httpMethod = "POST"; control.httpBody = Data("{\"offline\":false}".utf8)
        control.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, controlResponse) = try await session.data(for: control)
        XCTAssertEqual((controlResponse as? HTTPURLResponse)?.statusCode, 200)
        let (data, response) = try await session.data(from: base.appendingPathComponent("media/direct.mp4"))
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw CloudVideoArchiveError.invalidMedia
        }
        fixture = data
    }

    override func tearDown() async throws {
        for optimizer in optimizers { optimizer.setAppActive(false) }
        try await Task.sleep(for: .milliseconds(650))
        for controller in controllers { await controller.synchronize() }
        optimizers = []; controllers = []; managers = []
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []; fixture = Data()
    }

    func testDefaultOffCountsLocalFilesWithoutCountingOrRemovingSyntheticCloudServer() async throws {
        let (manager, cloud, sync) = try await syncedLibrary(count: 2)
        let optimizer = makeOptimizer(manager, sync: sync, budget: 1)
        XCTAssertFalse(optimizer.isEnabled)
        await optimizer.refreshUsage()
        XCTAssertGreaterThanOrEqual(optimizer.localVideoBytes, Int64(fixture.count * 2))
        XCTAssertEqual(optimizer.cloudCacheBytes, 0, "The override directory represents the remote server, not a second local cache.")
        XCTAssertEqual(optimizer.localBytes, optimizer.localVideoBytes)
        let originals = try localFiles(manager)
        let remote = try cloudFiles(cloud)
        await optimizer.maintain()
        XCTAssertEqual(try localFiles(manager), originals)
        XCTAssertEqual(try cloudFiles(cloud), remote)
        XCTAssertTrue(manager.records.allSatisfy { $0.phase == .complete && $0.localCacheEvicted != true })
    }

    func testPreferencePersistsAndDisablingStopsReclamation() async throws {
        let (manager, _, sync) = try await syncedLibrary(count: 1)
        let optimizer = makeOptimizer(manager, sync: sync, budget: 1)
        try optimizer.setEnabled(true)
        XCTAssertTrue(optimizer.isEnabled)
        let relaunched = makeOptimizer(manager, sync: sync, budget: 1)
        XCTAssertTrue(relaunched.isEnabled)
        XCTAssertEqual(relaunched.budgetBytes, 1)
        try relaunched.setEnabled(false)
        let disabled = makeOptimizer(manager, sync: sync, budget: 1)
        XCTAssertFalse(disabled.isEnabled)
        let before = try localFiles(manager)
        await disabled.maintain()
        XCTAssertEqual(try localFiles(manager), before)
    }

    func testDefaultBudgetIsOneDecimalGigabyte() throws {
        let manager = try makeManager(count: 0)
        let sync = makeSync(manager, cloud: try temporaryDirectory())
        let optimizer = VideoStorageOptimizer(downloads: manager, cloud: sync,
            metadataStore: VideoMetadataStore(rootDirectory: manager.rootDirectory), automaticallyMaintain: false)
        optimizers.append(optimizer)
        XCTAssertEqual(optimizer.budgetBytes, 1_000_000_000)
        XCTAssertFalse(optimizer.isEnabled)
    }

    func testDisablingRevokesEvictionEvenWhenThePreferenceCannotBeSaved() async throws {
        let (manager, _, sync) = try await syncedLibrary(count: 1)
        let optimizer = makeOptimizer(manager, sync: sync, budget: 1)
        try optimizer.setEnabled(true)
        let state = manager.rootDirectory.appendingPathComponent("VideoStorage/state.json")
        let savedState = try Data(contentsOf: state)
        try FileManager.default.removeItem(at: state)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        let before = try localFiles(manager)

        XCTAssertThrowsError(try optimizer.setEnabled(false))
        XCTAssertFalse(optimizer.isEnabled, "A failed settings write must still revoke the user's permission to reclaim files.")
        await optimizer.maintain()
        XCTAssertEqual(try localFiles(manager), before)
        XCTAssertTrue(manager.records.allSatisfy { $0.phase == .complete && $0.localCacheEvicted != true })

        // Undo only this test's state-file obstruction before the fixture is removed.
        try FileManager.default.removeItem(at: state)
        try savedState.write(to: state)
    }

    func testMarkUsedPrunesStaleAccessRecordsWhileKeepingKnownVideoTimestamps() throws {
        let manager = try makeManager(count: 2)
        let sync = makeSync(manager, cloud: try temporaryDirectory())
        let records = manager.records
        let staleID = UUID()
        let directory = manager.rootDirectory.appendingPathComponent("VideoStorage")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = directory.appendingPathComponent("state.json")
        let previousDate = Date(timeIntervalSince1970: 1_770_000_000)
        // JSONEncoder's default Date encoding is seconds from Apple's reference date.
        let archive: [String: Any] = ["schemaVersion": 1, "isEnabled": false,
            "lastUsed": [staleID.uuidString: previousDate.timeIntervalSinceReferenceDate,
                         records[0].id.uuidString: previousDate.timeIntervalSinceReferenceDate]]
        try JSONSerialization.data(withJSONObject: archive).write(to: state)
        let clock = StorageTestClock()
        let optimizer = makeOptimizer(manager, sync: sync, now: { clock.date })
        optimizer.markUsed(records[1].id)

        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])
        let lastUsed = try XCTUnwrap(saved["lastUsed"] as? [String: Double])
        XCTAssertNil(lastUsed[staleID.uuidString], "Removed videos must not grow the access ledger indefinitely.")
        XCTAssertEqual(lastUsed[records[0].id.uuidString], previousDate.timeIntervalSinceReferenceDate)
        XCTAssertEqual(lastUsed[records[1].id.uuidString], clock.date.timeIntervalSinceReferenceDate)
        XCTAssertEqual(lastUsed.count, 2)
    }

    func testPersistedUpdateOrderKeepsRecentlyEditedVideoDespitePlaybackHistory() async throws {
        let manager = try makeManager(count: 3)
        let records = manager.records
        let metadata = VideoMetadataStore(rootDirectory: manager.rootDirectory)
        let updatedAt = Date(timeIntervalSince1970: 1_780_000_000)
        try saveMetadata(records[0], in: metadata, updatedAt: updatedAt)
        try saveMetadata(records[1], in: metadata, updatedAt: updatedAt.addingTimeInterval(20))
        try saveMetadata(records[2], in: metadata, updatedAt: updatedAt.addingTimeInterval(10))
        let cloud = try temporaryDirectory()
        let sync = makeSync(manager, cloud: cloud, metadata: metadata)
        await sync.refreshAccount()
        XCTAssertTrue(sync.visibleEntries.allSatisfy { $0.uploaded && !$0.transferError })
        let meter = makeOptimizer(manager, sync: sync)
        await meter.refreshUsage()
        let oneVideoBudget = meter.localBytes / 3 + 1_024
        let clock = StorageTestClock()
        let optimizer = makeOptimizer(manager, sync: sync, metadata: metadata,
                                      budget: oneVideoBudget, now: { clock.date })
        try optimizer.setEnabled(true)
        // The least recently edited video is played last. Playback must not
        // displace a more recently updated library entry under the new policy.
        for index in [1, 2, 0] {
            optimizer.markUsed(records[index].id)
            clock.date.addTimeInterval(10)
        }
        let remoteBefore = try cloudFiles(cloud)
        // Reload both stores to exercise persisted edits and the old access ledger.
        let relaunched = makeOptimizer(manager, sync: sync,
            metadata: VideoMetadataStore(rootDirectory: manager.rootDirectory),
            budget: oneVideoBudget, now: { clock.date })
        await relaunched.maintain()
        XCTAssertLessThanOrEqual(relaunched.localBytes, oneVideoBudget)
        XCTAssertNotNil(manager.localURL(for: try record(records[1].id, in: manager)))
        for index in [0, 2] {
            let evicted = try record(records[index].id, in: manager)
            XCTAssertNil(manager.localURL(for: evicted))
            XCTAssertEqual(evicted.localCacheEvicted, true)
            XCTAssertNil(evicted.failure, "Cache eviction is not a failed download.")
            XCTAssertNotNil(sync.entry(for: evicted.id))
        }
        XCTAssertEqual(try cloudFiles(cloud), remoteBefore)
    }

    func testCloudOnlyAndLocalCandidatesShareFavoriteAndUpdatePriority() async throws {
        let manager = try makeManager(count: 4)
        let records = manager.records
        let metadata = VideoMetadataStore(rootDirectory: manager.rootDirectory)
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        try saveMetadata(records[0], in: metadata, favorite: true, updatedAt: date)
        try saveMetadata(records[1], in: metadata, updatedAt: date.addingTimeInterval(20))
        try saveMetadata(records[2], in: metadata, updatedAt: date.addingTimeInterval(10))
        try saveMetadata(records[3], in: metadata, favorite: true, updatedAt: date.addingTimeInterval(30))
        let cloud = try temporaryDirectory()
        let sync = makeSync(manager, cloud: cloud, metadata: metadata)
        await sync.refreshAccount()
        XCTAssertEqual(sync.visibleEntries.count, 4)
        let remoteBefore = try cloudFiles(cloud)
        manager.removeCache(id: records[0].id)
        manager.removeCache(id: records[2].id)
        XCTAssertNil(manager.localURL(for: try record(records[0].id, in: manager)))
        XCTAssertNil(manager.localURL(for: try record(records[2].id, in: manager)))
        let optimizer = makeOptimizer(manager, sync: sync, metadata: metadata)

        // Synthetic cloud files are remote fixtures, not native cache bytes.
        // This checks that native-only entries still enter the same policy order.
        XCTAssertEqual(optimizer.evictionCandidateIDs(),
            [records[2].id, records[1].id, records[0].id, records[3].id])
        XCTAssertEqual(try cloudFiles(cloud), remoteBefore)
    }

    func testFavoriteIsKeptAheadOfMoreRecentlyUpdatedNonfavorite() async throws {
        let manager = try makeManager(count: 2)
        let favorite = manager.records[0]
        let recent = manager.records[1]
        let metadata = VideoMetadataStore(rootDirectory: manager.rootDirectory)
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        try saveMetadata(favorite, in: metadata, favorite: true, updatedAt: date)
        try saveMetadata(recent, in: metadata, updatedAt: date.addingTimeInterval(10_000))
        let cloud = try temporaryDirectory()
        let sync = makeSync(manager, cloud: cloud, metadata: metadata)
        await sync.refreshAccount()
        let budget = await budgetKeeping(1, of: 2, manager: manager, sync: sync)
        let remoteBefore = try cloudFiles(cloud)
        let optimizer = makeOptimizer(manager, sync: sync, metadata: metadata, budget: budget)
        try optimizer.setEnabled(true)

        await optimizer.maintain()

        XCTAssertNotNil(manager.localURL(for: try record(favorite.id, in: manager)))
        XCTAssertEqual(try record(recent.id, in: manager).localCacheEvicted, true)
        XCTAssertLessThanOrEqual(optimizer.localBytes, budget)
        XCTAssertTrue(metadata.isFavorite(favorite.id))
        XCTAssertEqual(try cloudFiles(cloud), remoteBefore)
    }

    func testFavoritesOverBudgetKeepTheMostRecentlyUpdatedFavorite() async throws {
        let manager = try makeManager(count: 3)
        let records = manager.records
        let metadata = VideoMetadataStore(rootDirectory: manager.rootDirectory)
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        try saveMetadata(records[0], in: metadata, favorite: true, updatedAt: date.addingTimeInterval(10))
        try saveMetadata(records[1], in: metadata, favorite: true, updatedAt: date.addingTimeInterval(20))
        try saveMetadata(records[2], in: metadata, favorite: true, updatedAt: date)
        let sync = makeSync(manager, cloud: try temporaryDirectory(), metadata: metadata)
        await sync.refreshAccount()
        let budget = await budgetKeeping(1, of: 3, manager: manager, sync: sync)
        let optimizer = makeOptimizer(manager, sync: sync, metadata: metadata, budget: budget)
        try optimizer.setEnabled(true)

        await optimizer.maintain()

        XCTAssertNotNil(manager.localURL(for: try record(records[1].id, in: manager)))
        for index in [0, 2] {
            XCTAssertEqual(try record(records[index].id, in: manager).localCacheEvicted, true)
            XCTAssertTrue(metadata.isFavorite(records[index].id), "Reclaiming a cache must not remove the favorite annotation.")
        }
        XCTAssertLessThanOrEqual(optimizer.localBytes, budget)
    }

    func testNewDownloadDatesRemainRecentWhenMetadataIsOlderOrAbsent() async throws {
        let manager = try makeManager(count: 3)
        let records = manager.records.sorted { $0.createdAt < $1.createdAt }
        let metadata = VideoMetadataStore(rootDirectory: manager.rootDirectory)
        try saveMetadata(records[0], in: metadata, updatedAt: records[0].createdAt.addingTimeInterval(0.5))
        try saveMetadata(records[1], in: metadata, updatedAt: records[0].createdAt.addingTimeInterval(-100))
        let sync = makeSync(manager, cloud: try temporaryDirectory(), metadata: metadata)
        await sync.refreshAccount()
        let budget = await budgetKeeping(2, of: 3, manager: manager, sync: sync)
        let optimizer = makeOptimizer(manager, sync: sync, metadata: metadata, budget: budget)
        try optimizer.setEnabled(true)

        await optimizer.maintain()

        XCTAssertEqual(try record(records[0].id, in: manager).localCacheEvicted, true)
        XCTAssertNotNil(manager.localURL(for: try record(records[1].id, in: manager)))
        XCTAssertNotNil(manager.localURL(for: try record(records[2].id, in: manager)))
        XCTAssertLessThanOrEqual(optimizer.localBytes, budget)
    }

    func testLiveFavoriteChangeAfterOptimizerCreationUpdatesRetention() async throws {
        let manager = try makeManager(count: 2)
        let records = manager.records.sorted { $0.createdAt < $1.createdAt }
        let metadata = VideoMetadataStore(rootDirectory: manager.rootDirectory)
        let sync = makeSync(manager, cloud: try temporaryDirectory(), metadata: metadata)
        await sync.refreshAccount()
        let budget = await budgetKeeping(1, of: 2, manager: manager, sync: sync)
        let optimizer = makeOptimizer(manager, sync: sync, metadata: metadata, budget: budget)
        try optimizer.setEnabled(true)

        try metadata.toggleFavorite(records[0].id)
        await sync.synchronize()
        await optimizer.maintain()

        XCTAssertNotNil(manager.localURL(for: try record(records[0].id, in: manager)))
        XCTAssertEqual(try record(records[1].id, in: manager).localCacheEvicted, true)
        XCTAssertLessThanOrEqual(optimizer.localBytes, budget)
    }

    func testUnsafeAndInUseNonfavoritesStayLocalBeforeAnEligibleFavoriteIsReclaimed() async throws {
        let manager = try makeManager(count: 3)
        let records = manager.records
        let metadata = VideoMetadataStore(rootDirectory: manager.rootDirectory)
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        try saveMetadata(records[0], in: metadata, updatedAt: date)
        try saveMetadata(records[1], in: metadata, updatedAt: date.addingTimeInterval(10))
        try saveMetadata(records[2], in: metadata, favorite: true, updatedAt: date.addingTimeInterval(20))
        let cloud = try temporaryDirectory()
        try CloudVideoFiles.prepare(container: cloud)
        let unfinished = CloudVideoFiles.packageURL(records[0].id, container: cloud)
        try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: false)
        try Data("unfinished publication".utf8).write(to: unfinished.appendingPathComponent("manifest.json"))
        let sync = makeSync(manager, cloud: cloud, metadata: metadata)
        await sync.refreshAccount()
        XCTAssertNil(sync.entry(for: records[0].id))
        XCTAssertEqual(sync.entry(for: records[1].id)?.uploaded, true)
        XCTAssertEqual(sync.entry(for: records[2].id)?.uploaded, true)
        let lease = manager.beginUsingLocalVideo(id: records[1].id)
        defer { manager.endUsingLocalVideo(lease) }
        let remoteBefore = try cloudFiles(cloud)
        let optimizer = makeOptimizer(manager, sync: sync, metadata: metadata, budget: 1)
        try optimizer.setEnabled(true)

        await optimizer.maintain()

        for index in [0, 1] {
            let local = try XCTUnwrap(manager.localURL(for: try record(records[index].id, in: manager)))
            XCTAssertEqual(try Data(contentsOf: local), fixture)
        }
        XCTAssertEqual(try record(records[2].id, in: manager).localCacheEvicted, true)
        XCTAssertGreaterThan(optimizer.localBytes, optimizer.budgetBytes)
        XCTAssertEqual(try cloudFiles(cloud), remoteBefore)
    }

    func testUnreadableMetadataPreservesEveryFileInsteadOfTreatingFavoritesAsEmpty() async throws {
        let manager = try makeManager(count: 2)
        let metadata = VideoMetadataStore(rootDirectory: manager.rootDirectory)
        try metadata.toggleFavorite(manager.records[0].id)
        let sync = makeSync(manager, cloud: try temporaryDirectory(), metadata: metadata)
        await sync.refreshAccount()
        let file = manager.rootDirectory.appendingPathComponent("VideoMetadata/metadata.json")
        let corrupted = Data("{\"entries\": [unfinished".utf8)
        try corrupted.write(to: file)
        let unreadable = VideoMetadataStore(rootDirectory: manager.rootDirectory)
        let optimizer = makeOptimizer(manager, sync: sync, metadata: unreadable, budget: 1)
        try optimizer.setEnabled(true)
        let before = try localFiles(manager)

        await optimizer.maintain()

        XCTAssertEqual(try localFiles(manager), before)
        XCTAssertTrue(manager.records.allSatisfy { $0.phase == .complete && $0.localCacheEvicted != true })
        XCTAssertEqual(try Data(contentsOf: file), corrupted)
        XCTAssertGreaterThan(optimizer.localBytes, optimizer.budgetBytes)
        XCTAssertNotNil(optimizer.message)
    }

    func testEvictionPreservesAnnotationsAndPreviewAndCloudRestoreRemainsPlayable() async throws {
        let manager = try makeManager(count: 1)
        let original = try XCTUnwrap(manager.records.first)
        let metadata = VideoMetadataStore(rootDirectory: manager.rootDirectory)
        try metadata.rename("为离线阅读保存的合成视频", for: original.id, fallback: original.candidate.title)
        try metadata.toggleFavorite(original.id)
        try metadata.setTags(["收藏资料", "合成视频"], for: original.id)
        try metadata.setCoverFrameSeconds(3, for: original.id)
        let originalMetadata = try XCTUnwrap(metadata.metadata(for: original.id))
        let originalURL = try XCTUnwrap(manager.localURL(for: original))
        let preview = await manager.thumbnailStore.image(for: original, localURL: originalURL, frameSeconds: 3)
        XCTAssertNotNil(preview)
        let thumbnailDirectory = manager.rootDirectory.appendingPathComponent("Thumbnails")
        let thumbnailsBefore = try files(in: thumbnailDirectory)
        XCTAssertFalse(thumbnailsBefore.isEmpty)
        let cloud = try temporaryDirectory()
        let sync = makeSync(manager, cloud: cloud, metadata: metadata)
        await sync.refreshAccount()
        XCTAssertEqual(sync.entry(for: original.id)?.uploaded, true)
        let remoteBefore = try cloudFiles(cloud)
        let optimizer = makeOptimizer(manager, sync: sync, budget: 1)
        try optimizer.setEnabled(true)
        await optimizer.maintain()
        XCTAssertNil(manager.localURL(for: try record(original.id, in: manager)))
        XCTAssertEqual(metadata.metadata(for: original.id), originalMetadata)
        XCTAssertEqual(VideoMetadataStore(rootDirectory: manager.rootDirectory).metadata(for: original.id), originalMetadata)
        XCTAssertEqual(try files(in: thumbnailDirectory), thumbnailsBefore)
        XCTAssertEqual(try cloudFiles(cloud), remoteBefore)
        XCTAssertNotNil(sync.entry(for: original.id)?.thumbnail)

        try optimizer.setEnabled(false)
        await sync.restore(id: original.id)
        let restored = try record(original.id, in: manager)
        let restoredURL = try XCTUnwrap(manager.localURL(for: restored))
        XCTAssertEqual(restored.phase, .complete)
        XCTAssertNotEqual(restored.localCacheEvicted, true)
        XCTAssertEqual(try Data(contentsOf: restoredURL), fixture)
        let playable = try await AVURLAsset(url: restoredURL).load(.isPlayable)
        XCTAssertTrue(playable)
        XCTAssertEqual(metadata.metadata(for: original.id), originalMetadata)
        sync.cancelPendingPlayback()
    }

    func testPlayingVideoLeasesProtectBytesUntilEveryConsumerFinishes() async throws {
        let (manager, _, sync) = try await syncedLibrary(count: 1)
        let original = try XCTUnwrap(manager.records.first)
        let local = try XCTUnwrap(manager.localURL(for: original))
        let optimizer = makeOptimizer(manager, sync: sync, budget: 1)
        try optimizer.setEnabled(true)
        let playerLease = manager.beginUsingLocalVideo(id: original.id)
        let coverLease = manager.beginUsingLocalVideo(id: original.id)
        await optimizer.maintain()
        XCTAssertEqual(try Data(contentsOf: local), fixture)
        XCTAssertGreaterThan(optimizer.localBytes, optimizer.budgetBytes)
        manager.endUsingLocalVideo(playerLease)
        await optimizer.maintain()
        XCTAssertEqual(try Data(contentsOf: local), fixture)
        manager.endUsingLocalVideo(coverLease)
        await optimizer.maintain()
        XCTAssertEqual(try record(original.id, in: manager).localCacheEvicted, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        XCTAssertEqual(optimizer.localBytes, 0)
    }

    func testUnsyncedVideoAndUnavailableAccountStayLocalEvenOverBudget() async throws {
        let manager = try makeManager(count: 1)
        let cloud = try temporaryDirectory()
        let sync = makeSync(manager, cloud: cloud)
        // Do not initialize synchronization: no recoverable remote copy exists.
        let optimizer = makeOptimizer(manager, sync: sync, budget: 1)
        try optimizer.setEnabled(true)
        let before = try localFiles(manager)
        await optimizer.maintain()
        XCTAssertEqual(try localFiles(manager), before)
        XCTAssertTrue(manager.records.allSatisfy { $0.phase == .complete })
        XCTAssertGreaterThan(optimizer.localBytes, optimizer.budgetBytes)

        let unavailable = CloudVideoSync(downloads: manager, containerOverride: cloud, identityOverride: { nil })
        controllers.append(unavailable)
        await unavailable.refreshAccount()
        XCTAssertFalse(unavailable.isAvailable)
        let noAccount = makeOptimizer(manager, sync: unavailable, budget: 1)
        await noAccount.maintain()
        XCTAssertEqual(try localFiles(manager), before)
    }

    func testFailedCloudPublicationDoesNotMakeTheOnlyPlayableCopyEvictable() async throws {
        let manager = try makeManager(count: 1)
        let original = try XCTUnwrap(manager.records.first)
        let cloud = try temporaryDirectory()
        try CloudVideoFiles.prepare(container: cloud)
        let package = CloudVideoFiles.packageURL(original.id, container: cloud)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try Data("unfinished publication".utf8).write(to: package.appendingPathComponent("manifest.json"))
        let sync = makeSync(manager, cloud: cloud)
        await sync.refreshAccount()
        XCTAssertNil(sync.entry(for: original.id))
        let before = try localFiles(manager)
        let optimizer = makeOptimizer(manager, sync: sync, budget: 1)
        try optimizer.setEnabled(true)
        await optimizer.maintain()
        XCTAssertEqual(try localFiles(manager), before)
        XCTAssertEqual(try record(original.id, in: manager).phase, .complete)
    }

    func testCloudBytesChangedAfterPublicationKeepTheOnlyValidLocalCopy() async throws {
        let (manager, cloud, sync) = try await syncedLibrary(count: 1)
        let original = try XCTUnwrap(manager.records.first)
        let entry = try XCTUnwrap(sync.entry(for: original.id))
        let media = CloudVideoFiles.packageURL(original.id, container: cloud)
            .appendingPathComponent("video.\(entry.manifest.fileExtension)")
        var corrupted = try Data(contentsOf: media)
        corrupted[corrupted.count / 2] ^= 0xff
        try corrupted.write(to: media)
        let before = try localFiles(manager)
        let optimizer = makeOptimizer(manager, sync: sync, budget: 1)
        try optimizer.setEnabled(true)
        await optimizer.maintain()
        XCTAssertEqual(try localFiles(manager), before)
        XCTAssertEqual(try record(original.id, in: manager).phase, .complete)
        XCTAssertNotEqual(try record(original.id, in: manager).localCacheEvicted, true)
    }

    func testAccountChangeAndBackgroundingPreventPreviouslyEligibleEviction() async throws {
        let manager = try makeManager(count: 1)
        let identity = StorageTestIdentity("first-account")
        let sync = CloudVideoSync(downloads: manager, containerOverride: try temporaryDirectory(),
                                  identityOverride: { identity.get() })
        controllers.append(sync)
        await sync.refreshAccount()
        XCTAssertEqual(sync.entry(for: try XCTUnwrap(manager.records.first).id)?.uploaded, true)
        let optimizer = makeOptimizer(manager, sync: sync, budget: 1)
        try optimizer.setEnabled(true)
        let before = try localFiles(manager)
        optimizer.setAppActive(false)
        await optimizer.maintain()
        XCTAssertEqual(try localFiles(manager), before)
        optimizer.setAppActive(true)
        identity.set("second-account")
        // The live identity check must revoke proof even before account refresh arrives.
        await optimizer.maintain()
        XCTAssertEqual(try localFiles(manager), before)
        await sync.refreshAccount()
        XCTAssertTrue(sync.accountChanged)
        await optimizer.maintain()
        XCTAssertEqual(try localFiles(manager), before)
    }

    func testUnderBudgetMaintenanceIsIdempotentAndDoesNotRewriteMediaOrCloudPackages() async throws {
        let (manager, cloud, sync) = try await syncedLibrary(count: 1)
        let optimizer = makeOptimizer(manager, sync: sync)
        try optimizer.setEnabled(true)
        let before = try localFiles(manager)
        let remoteBefore = try cloudFiles(cloud)
        await optimizer.maintain()
        await optimizer.maintain()
        XCTAssertEqual(try localFiles(manager), before)
        XCTAssertEqual(try cloudFiles(cloud), remoteBefore)
        XCTAssertLessThan(optimizer.localBytes, optimizer.budgetBytes)
        XCTAssertFalse(optimizer.isMaintaining)
        XCTAssertTrue(manager.records.allSatisfy { $0.phase == .complete && $0.localCacheEvicted != true })
    }

    func testCorruptedPreferenceFailsClosedWithoutReplacingTheUnreadableFile() async throws {
        let (manager, _, sync) = try await syncedLibrary(count: 1)
        let directory = manager.rootDirectory.appendingPathComponent("VideoStorage")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = directory.appendingPathComponent("state.json")
        let invalid = Data("{\"isEnabled\":true, unfinished".utf8)
        try invalid.write(to: state)
        let before = try localFiles(manager)
        let optimizer = makeOptimizer(manager, sync: sync, budget: 1)
        XCTAssertFalse(optimizer.isEnabled)
        XCTAssertNotNil(optimizer.message)
        XCTAssertThrowsError(try optimizer.setEnabled(true))
        await optimizer.maintain()
        XCTAssertEqual(try localFiles(manager), before)
        XCTAssertEqual(try Data(contentsOf: state), invalid)
    }

    private func syncedLibrary(count: Int) async throws -> (DownloadManager, URL, CloudVideoSync) {
        let manager = try makeManager(count: count)
        let cloud = try temporaryDirectory()
        let sync = makeSync(manager, cloud: cloud)
        await sync.refreshAccount()
        XCTAssertTrue(sync.isAvailable)
        XCTAssertEqual(sync.visibleEntries.count, count)
        XCTAssertTrue(sync.visibleEntries.allSatisfy { $0.uploaded && !$0.transferError })
        return (manager, cloud, sync)
    }

    private func makeOptimizer(_ manager: DownloadManager, sync: CloudVideoSync,
                               metadata: VideoMetadataStore? = nil,
                               budget: Int64 = 1_000_000_000,
                               now: @escaping () -> Date = Date.init) -> VideoStorageOptimizer {
        let optimizer = VideoStorageOptimizer(downloads: manager, cloud: sync,
                                              metadataStore: metadata ?? VideoMetadataStore(rootDirectory: manager.rootDirectory), budgetBytes: budget,
                                              now: now, automaticallyMaintain: false)
        optimizers.append(optimizer)
        return optimizer
    }

    private func budgetKeeping(_ retained: Int, of count: Int, manager: DownloadManager,
                               sync: CloudVideoSync) async -> Int64 {
        let meter = makeOptimizer(manager, sync: sync)
        await meter.refreshUsage()
        return meter.localBytes / Int64(count) * Int64(retained) + 1_024
    }

    private func saveMetadata(_ record: DownloadRecord, in metadata: VideoMetadataStore,
                              favorite: Bool = false, updatedAt: Date) throws {
        let value = VideoMetadata(id: record.id, isFavorite: favorite, tags: [], updatedAt: updatedAt,
                                  revision: UUID())
        try metadata.merge([record.id: value])
    }

    private func makeManager(count: Int) throws -> DownloadManager {
        let root = try temporaryDirectory()
        let media = root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var records: [DownloadRecord] = []
        for index in 0..<count {
            let name = "fixture-\(index).mp4"
            try fixture.write(to: media.appendingPathComponent(name))
            let page = URL(string: "https://example.org/watch/\(index)")!
            let candidate = MediaCandidate(url: URL(string: "https://cdn.example.org/\(name)")!,
                                           pageURL: page, frameURL: page,
                                           title: "缓存测试视频 \(index)", kind: .file, source: "fixture")
            records.append(DownloadRecord(id: UUID(), candidate: candidate, phase: .complete, progress: 1,
                bytesWritten: Int64(fixture.count), expectedBytes: Int64(fixture.count),
                localRelativePath: "Media/\(name)", failure: nil, duration: 8, hasAudio: true,
                createdAt: Date(timeIntervalSince1970: 1_750_000_000 + Double(index))))
        }
        try JSONEncoder().encode(records).write(to: root.appendingPathComponent("downloads.json"))
        let manager = DownloadManager(rootDirectory: root)
        managers.append(manager)
        return manager
    }

    private func makeSync(_ manager: DownloadManager, cloud: URL, metadata: VideoMetadataStore? = nil) -> CloudVideoSync {
        let sync = CloudVideoSync(downloads: manager, metadataStore: metadata, containerOverride: cloud)
        controllers.append(sync)
        return sync
    }

    private func record(_ id: UUID, in manager: DownloadManager) throws -> DownloadRecord {
        try XCTUnwrap(manager.records.first { $0.id == id })
    }

    private func localFiles(_ manager: DownloadManager) throws -> [String: Data] {
        try files(in: manager.rootDirectory.appendingPathComponent("Media"))
    }

    private func cloudFiles(_ cloud: URL) throws -> [String: Data] { try files(in: cloud) }

    private func files(in directory: URL) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]))
        var contents: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let relative = String(url.path.dropFirst(directory.path.count + 1))
                contents[relative] = try Data(contentsOf: url)
            }
        }
        return contents
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VYu-storage-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }
}

@MainActor private final class StorageTestClock {
    var date = Date(timeIntervalSince1970: 1_780_000_000)
}

private final class StorageTestIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String?) { self.value = value }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: String?) { lock.lock(); defer { lock.unlock() }; self.value = value }
}
