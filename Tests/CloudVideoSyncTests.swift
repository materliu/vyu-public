import AVFoundation
import XCTest
@testable import VYu

/// Two independent app directories share a local Documents fixture. No user's iCloud container is accessed.
@MainActor final class CloudVideoSyncTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8765")!
    private var directories: [URL] = []
    private var managers: [DownloadManager] = []
    private var controllers: [CloudVideoSync] = []
    private var fixture = Data()

    override func setUp() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let healthData: Data, healthResponse: URLResponse
        do { (healthData, healthResponse) = try await session.data(from: base.appendingPathComponent("__health")) }
        catch let error as URLError where error.code == .cannotConnectToHost {
            throw XCTSkip("Generate fixtures and start fixtures/server.py to run cloud sync tests.")
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
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { throw CloudVideoArchiveError.invalidMedia }
        fixture = data
    }

    override func tearDown() async throws {
        // Let record-change debounce work finish before removing the temporary app directories.
        try await Task.sleep(for: .milliseconds(650))
        for controller in controllers { await controller.synchronize() }
        controllers = []
        managers = []
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []; fixture = Data()
    }

    func testICloudBuildSettingDefaultsToEnabledAndAcceptsPlistAndExpandedValues() {
        XCTAssertTrue(CloudVideoSync.iCloudEnabled(infoValue: nil))
        XCTAssertTrue(CloudVideoSync.iCloudEnabled(infoValue: true))
        XCTAssertTrue(CloudVideoSync.iCloudEnabled(infoValue: "YES"))
        XCTAssertFalse(CloudVideoSync.iCloudEnabled(infoValue: false))
        XCTAssertFalse(CloudVideoSync.iCloudEnabled(infoValue: "NO"))
    }

    func testLocalOnlyBuildKeepsVideoAndDoesNotStartCloudSync() async throws {
        let manager = try makeManager(withVideo: true)
        let record = try XCTUnwrap(manager.records.first)
        let local = try XCTUnwrap(manager.localURL(for: record))
        let sync = CloudVideoSync(downloads: manager, iCloudEnabled: false)
        controllers.append(sync)
        XCTAssertEqual(sync.message, "此本机构建未启用 iCloud，本机视频仍可播放")

        await sync.refreshAccount()
        await sync.retrySync()
        await sync.acceptCurrentAccount()
        await sync.synchronize()
        await sync.restore(id: record.id)
        await sync.deleteEverywhere(id: record.id)

        XCTAssertFalse(sync.isAvailable)
        XCTAssertFalse(sync.accountChanged)
        XCTAssertTrue(sync.visibleEntries.isEmpty)
        XCTAssertTrue(sync.operations.isEmpty)
        XCTAssertNil(sync.readyToPlay)
        XCTAssertEqual(sync.status(for: record), sync.message)
        XCTAssertEqual(manager.records, [record])
        XCTAssertEqual(try Data(contentsOf: local), fixture)
        XCTAssertTrue(manager.cloudPreparationStatus.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.rootDirectory.appendingPathComponent("CloudSync/state.json").path))
    }

    func testSyntheticContainerStillSyncsWhenNativeICloudIsDisabled() async throws {
        let cloud = try temporaryDirectory()
        let source = try makeManager(withVideo: true)
        let record = try XCTUnwrap(source.records.first)
        let sourceSync = CloudVideoSync(downloads: source, containerOverride: cloud, iCloudEnabled: false)
        controllers.append(sourceSync)
        await sourceSync.refreshAccount()
        XCTAssertTrue(sourceSync.isAvailable)
        XCTAssertEqual(sourceSync.entry(for: record.id)?.uploaded, true)

        let destination = try makeManager()
        let destinationSync = CloudVideoSync(downloads: destination, containerOverride: cloud, iCloudEnabled: false)
        controllers.append(destinationSync)
        await destinationSync.refreshAccount()
        XCTAssertNotNil(destinationSync.entry(for: record.id))
        await destinationSync.restore(id: record.id)
        let restored = try XCTUnwrap(destination.records.first)
        XCTAssertEqual(restored.phase, .complete)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(destination.localURL(for: restored))), fixture)
    }

    func testSecondDeviceDiscoversMetadataAndRestoresOnlyWhenRequested() async throws {
        let cloud = try temporaryDirectory()
        let source = try makeManager(withVideo: true)
        let record = try XCTUnwrap(source.records.first)
        let sourceSync = makeController(source, cloud: cloud)
        await sourceSync.refreshAccount()
        XCTAssertEqual(sourceSync.entry(for: record.id)?.uploaded, true)

        let package = CloudVideoFiles.packageURL(record.id, container: cloud)
        let manifest = try CloudVideoArchive.readManifest(at: package)
        XCTAssertEqual(try Data(contentsOf: CloudVideoArchive.verifyMedia(at: package, manifest: manifest)), fixture)
        let raw = try String(contentsOf: package.appendingPathComponent("manifest.json"), encoding: .utf8)
        for secret in ["signedSecret", "pageSecret", "frameSecret", "private-path", "localRelativePath", "Cookie"] {
            XCTAssertFalse(raw.contains(secret))
        }

        let destination = try makeManager()
        let destinationSync = makeController(destination, cloud: cloud)
        await destinationSync.refreshAccount()
        XCTAssertEqual(destinationSync.visibleEntries.map(\.id), [record.id])
        XCTAssertTrue(destination.records.isEmpty, "Metadata discovery must not silently download a full video.")
        XCTAssertTrue(try mediaFiles(in: destination).isEmpty)

        await destinationSync.restore(id: record.id)
        try await waitUntil { destination.records.first?.phase == .complete }
        let restored = try XCTUnwrap(destination.records.first)
        let local = try XCTUnwrap(destination.localURL(for: restored))
        XCTAssertEqual(try Data(contentsOf: local), fixture)
        XCTAssertTrue(local.path.hasPrefix(destination.rootDirectory.path + "/"))
        XCTAssertNotEqual(local, source.localURL(for: record))
        XCTAssertEqual(destinationSync.readyToPlay?.id, record.id)
        XCTAssertEqual(restored.candidate.source, "iCloud")
    }

    func testHLSOriginPortableMP4UploadsAndRestoresOnAnotherDevice() async throws {
        let cloud = try temporaryDirectory()
        let source = try makeManager(withVideo: true, sourceKind: .hls)
        let record = try XCTUnwrap(source.records.first)
        XCTAssertEqual(record.candidate.kind, .hls)
        XCTAssertEqual(source.localURL(for: record)?.pathExtension, "mp4")
        let sourceSync = makeController(source, cloud: cloud)
        await sourceSync.refreshAccount()
        XCTAssertEqual(sourceSync.entry(for: record.id)?.uploaded, true)
        XCTAssertEqual(sourceSync.status(for: record), "已同步到 iCloud")
        XCTAssertEqual(source.records.first?.candidate.kind, .hls, "Sync must not rewrite source provenance.")

        let destination = try makeManager()
        let destinationSync = makeController(destination, cloud: cloud)
        await destinationSync.refreshAccount()
        await destinationSync.restore(id: record.id)
        let restored = try XCTUnwrap(destination.records.first)
        XCTAssertEqual(restored.phase, .complete)
        let local = try XCTUnwrap(destination.localURL(for: restored))
        XCTAssertEqual(local.pathExtension, "mp4")
        XCTAssertEqual(try Data(contentsOf: local), fixture)
        let playable = try await AVURLAsset(url: local).load(.isPlayable)
        XCTAssertTrue(playable)
        XCTAssertEqual(restored.candidate.pageURL.absoluteString, "https://example.org/")
    }

    func testExistingHLSPackagePreparationFailureKeepsLocalRecordAndDoesNotAutomaticallyRetry() async throws {
        let directory = try temporaryDirectory()
        let cloud = try temporaryDirectory()
        let relative = "Media/existing.movpkg"
        let original = directory.appendingPathComponent(relative, isDirectory: true)
        // This directory is a state fixture, not a playable HLS package. The
        // rejected network preparation must leave the existing entry untouched.
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("hls-denied/master.m3u8")
        let candidate = MediaCandidate(url: source, pageURL: base, frameURL: base,
            title: "Existing synthetic package", kind: .hls, source: "fixture")
        let record = DownloadRecord(id: UUID(), candidate: candidate, phase: .complete, progress: 1,
            bytesWritten: 0, expectedBytes: nil, localRelativePath: relative, failure: nil,
            duration: 8, hasAudio: true, createdAt: Date())
        try JSONEncoder().encode([record]).write(to: directory.appendingPathComponent("downloads.json"))
        let manager = DownloadManager(rootDirectory: directory)
        managers.append(manager)
        let sync = makeController(manager, cloud: cloud)
        await sync.synchronize()
        XCTAssertNil(manager.cloudPreparationStatus[record.id], "Preparation requires an available accepted cloud account.")
        await sync.refreshAccount()
        try await waitUntil { manager.cloudPreparationStatus[record.id]?.hasPrefix("暂未生成可同步文件") == true }
        let failure = manager.cloudPreparationStatus[record.id]
        XCTAssertEqual(manager.records.first?.phase, .complete)
        XCTAssertEqual(manager.records.first?.localRelativePath, relative)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertNil(sync.entry(for: record.id))
        XCTAssertNil(sync.status(for: record), "The preparation result has its own UI; do not also show an unsupported message.")

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func attempts() async throws -> Int {
            let (data, _) = try await session.data(from: base.appendingPathComponent("__stats"))
            let values = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
            return values["GET /hls-denied/master.m3u8"] ?? 0
        }
        let before = try await attempts()
        await sync.synchronize()
        let after = try await attempts()
        XCTAssertEqual(after, before)
        XCTAssertEqual(manager.cloudPreparationStatus[record.id], failure)
    }

    func testCancelledPendingPlaybackStillRestoresVideoWithoutOpeningPlayer() async throws {
        let cloud = try temporaryDirectory()
        let source = try makeManager(withVideo: true)
        let record = try XCTUnwrap(source.records.first)
        let sourceSync = makeController(source, cloud: cloud)
        await sourceSync.refreshAccount()
        let destination = try makeManager()
        let destinationSync = makeController(destination, cloud: cloud)
        await destinationSync.refreshAccount()
        XCTAssertNotNil(destinationSync.entry(for: record.id))

        // Keep the manifest visible while simulating media that iCloud has not downloaded yet.
        let cloudMedia = CloudVideoFiles.packageURL(record.id, container: cloud).appendingPathComponent("video.mp4")
        let media = try Data(contentsOf: cloudMedia)
        try FileManager.default.removeItem(at: cloudMedia)
        await destinationSync.restore(id: record.id)
        XCTAssertTrue(destination.records.isEmpty)
        XCTAssertNotNil(destinationSync.operations[record.id])
        XCTAssertNil(destinationSync.readyToPlay)

        // Switching tabs or choosing another video cancels autoplay, while restoration can continue.
        destinationSync.cancelPendingPlayback()
        try media.write(to: cloudMedia, options: .atomic)
        await destinationSync.synchronize()
        try await waitUntil { destination.records.first?.phase == .complete }
        let restored = try XCTUnwrap(destination.records.first)
        let local = try XCTUnwrap(destination.localURL(for: restored))
        XCTAssertEqual(try Data(contentsOf: local), fixture)
        let playable = try await AVURLAsset(url: local).load(.isPlayable)
        XCTAssertTrue(playable)
        XCTAssertNil(destinationSync.operations[record.id])
        XCTAssertNil(destinationSync.readyToPlay, "A late download must not open the player after playback was cancelled.")
    }

    func testRemovingLocalCacheKeepsCloudAndDoesNotAutomaticallyRestore() async throws {
        let cloud = try temporaryDirectory()
        let manager = try makeManager(withVideo: true)
        let original = try XCTUnwrap(manager.records.first)
        let sync = makeController(manager, cloud: cloud)
        await sync.refreshAccount()
        manager.removeCache(id: original.id)
        await sync.synchronize()
        try await Task.sleep(for: .milliseconds(650))
        await sync.synchronize()

        let remaining = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(remaining.phase, .cancelled)
        XCTAssertNil(manager.localURL(for: remaining))
        XCTAssertTrue(try mediaFiles(in: manager).isEmpty)
        XCTAssertEqual(sync.visibleEntries.map(\.id), [original.id])
        let package = CloudVideoFiles.packageURL(original.id, container: cloud)
        XCTAssertNoThrow(try CloudVideoArchive.verifyMedia(at: package, manifest: CloudVideoArchive.readManifest(at: package)))

        await sync.restore(id: original.id)
        try await waitUntil { manager.records.first?.phase == .complete }
        XCTAssertNotNil(manager.records.first.flatMap { manager.localURL(for: $0) })
    }

    func testDeletionTombstoneWinsOverLatePublicationAndOtherDeviceCopy() async throws {
        let cloud = try temporaryDirectory()
        let first = try makeManager(withVideo: true)
        let record = try XCTUnwrap(first.records.first)
        let firstSync = makeController(first, cloud: cloud)
        await firstSync.refreshAccount()
        let staleParent = try temporaryDirectory()
        let stalePackage = staleParent.appendingPathComponent(record.id.uuidString)
        let staleManifest = try CloudVideoArchive.createStagingPackage(record: record,
            mediaURL: XCTUnwrap(first.localURL(for: record)), at: stalePackage)

        let second = try makeManager()
        let secondSync = makeController(second, cloud: cloud)
        await secondSync.refreshAccount()
        await secondSync.restore(id: record.id)
        try await waitUntil { second.records.first?.phase == .complete }
        await secondSync.deleteEverywhere(id: record.id)
        XCTAssertTrue(second.records.isEmpty)
        XCTAssertTrue(secondSync.visibleEntries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("Deleted/\(record.id.uuidString).deleted").path))

        try CloudVideoFiles.publish(staging: stalePackage, manifest: staleManifest, container: cloud, ubiquitous: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudVideoFiles.packageURL(record.id, container: cloud).path))
        await firstSync.synchronize()
        XCTAssertTrue(first.records.isEmpty, "A propagated deletion removes the owned copy on the other device.")
        XCTAssertTrue(firstSync.visibleEntries.isEmpty)
        let thirdSync = makeController(try makeManager(), cloud: cloud)
        await thirdSync.refreshAccount()
        XCTAssertTrue(thirdSync.visibleEntries.isEmpty)
    }

    func testHidingOnOneDeviceCanBeUndoneWithoutDeletingCloudVideo() async throws {
        let cloud = try temporaryDirectory()
        let manager = try makeManager(withVideo: true)
        let record = try XCTUnwrap(manager.records.first)
        let sync = makeController(manager, cloud: cloud)
        await sync.refreshAccount()
        sync.hideFromThisDevice(id: record.id)
        await sync.synchronize()
        XCTAssertTrue(manager.records.isEmpty)
        XCTAssertTrue(sync.visibleEntries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: CloudVideoFiles.packageURL(record.id, container: cloud).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.appendingPathComponent("Deleted/\(record.id.uuidString).deleted").path))

        let otherSync = makeController(try makeManager(), cloud: cloud)
        await otherSync.refreshAccount()
        XCTAssertEqual(otherSync.visibleEntries.map(\.id), [record.id])
        sync.showCloudVideos()
        XCTAssertEqual(sync.visibleEntries.map(\.id), [record.id])
        XCTAssertTrue(manager.records.isEmpty, "Showing metadata again must still require an explicit restore.")
    }

    func testExistingCorruptCloudPackageDoesNotReportUploadSuccessOrDamageLocalVideo() async throws {
        let cloud = try temporaryDirectory()
        try CloudVideoFiles.prepare(container: cloud)
        let manager = try makeManager(withVideo: true)
        let record = try XCTUnwrap(manager.records.first)
        let originalURL = try XCTUnwrap(manager.localURL(for: record))
        let conflict = CloudVideoFiles.packageURL(record.id, container: cloud)
        try FileManager.default.createDirectory(at: conflict, withIntermediateDirectories: false)
        try Data("incomplete manifest".utf8).write(to: conflict.appendingPathComponent("manifest.json"))
        let sync = makeController(manager, cloud: cloud)
        await sync.refreshAccount()

        XCTAssertNil(sync.entry(for: record.id), "An existing invalid package must not masquerade as a completed upload.")
        XCTAssertNotEqual(sync.status(for: record), "已同步到 iCloud")
        XCTAssertEqual(manager.records.first?.phase, .complete)
        XCTAssertEqual(try Data(contentsOf: originalURL), fixture)
    }

    func testHideKeepsLocalVideoWhenItsIntentCannotBePersisted() async throws {
        let cloud = try temporaryDirectory()
        let manager = try makeManager(withVideo: true)
        let record = try XCTUnwrap(manager.records.first)
        let local = try XCTUnwrap(manager.localURL(for: record))
        let sync = makeController(manager, cloud: cloud)
        await sync.refreshAccount()
        let stateURL = manager.rootDirectory.appendingPathComponent("CloudSync/state.json")
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)

        sync.hideFromThisDevice(id: record.id)
        XCTAssertEqual(manager.records, [record], "A failed state write must not delete the local video.")
        XCTAssertEqual(try Data(contentsOf: local), fixture)
        XCTAssertFalse(sync.isAvailable)
    }

    func testCorruptedLocalSyncStateFailsClosedWithoutUploadingOrChangingLocalVideo() async throws {
        let cloud = try temporaryDirectory()
        let manager = try makeManager(withVideo: true)
        let record = try XCTUnwrap(manager.records.first)
        let local = try XCTUnwrap(manager.localURL(for: record))
        let syncDirectory = manager.rootDirectory.appendingPathComponent("CloudSync")
        try FileManager.default.createDirectory(at: syncDirectory, withIntermediateDirectories: false)
        try Data("corrupt local state".utf8).write(to: syncDirectory.appendingPathComponent("state.json"))
        let sync = makeController(manager, cloud: cloud)
        await sync.refreshAccount()
        await sync.synchronize()

        XCTAssertFalse(sync.isAvailable)
        XCTAssertTrue(sync.visibleEntries.isEmpty)
        XCTAssertTrue(sync.message.contains("无法读取同步状态"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cloud.path).isEmpty)
        XCTAssertEqual(manager.records, [record])
        XCTAssertEqual(try Data(contentsOf: local), fixture)
    }

    func testAcceptingAnotherAccountDoesNotUploadPreviousAccountsLocalVideo() async throws {
        let cloud = try temporaryDirectory()
        let manager = try makeManager(withVideo: true)
        let record = try XCTUnwrap(manager.records.first)
        let local = try XCTUnwrap(manager.localURL(for: record))
        let identity = SimulatedCloudIdentity("first-account")
        let sync = CloudVideoSync(downloads: manager, containerOverride: cloud, identityOverride: { identity.get() })
        controllers.append(sync)
        await sync.refreshAccount()
        XCTAssertEqual(sync.entry(for: record.id)?.uploaded, true)

        // The fixed test container now represents the second account's initially empty Documents directory.
        try CloudVideoFiles.purgeDeletedPackage(id: record.id, container: cloud)
        identity.set("second-account")
        await sync.refreshAccount()
        XCTAssertTrue(sync.accountChanged)
        XCTAssertFalse(sync.isAvailable)
        XCTAssertTrue(sync.visibleEntries.isEmpty)
        await sync.acceptCurrentAccount()
        XCTAssertFalse(sync.accountChanged)
        XCTAssertTrue(sync.isAvailable)
        XCTAssertTrue(sync.visibleEntries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudVideoFiles.packageURL(record.id, container: cloud).path))
        XCTAssertEqual(sync.status(for: record), "保留在本机，未同步到当前 iCloud 账号")
        XCTAssertEqual(manager.records, [record])
        XCTAssertEqual(try Data(contentsOf: local), fixture)
    }

    func testStaleAccountAccessRejectsPendingWritesAndCancellationRemainsEffective() throws {
        let cloud = try temporaryDirectory()
        let identity = SimulatedCloudIdentity("first-account")
        let access = CloudSyncAccess(account: "first-account", identity: { identity.get() })
        XCTAssertNoThrow(try access.check())
        identity.set("second-account")
        XCTAssertThrowsError(try access.check()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try CloudVideoFiles.prepare(container: cloud, access: access)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cloud.path).isEmpty)

        access.cancel()
        identity.set("first-account")
        XCTAssertThrowsError(try access.check(), "Returning to an account must not revive a cancelled operation.")
        let freshAccess = CloudSyncAccess(account: "first-account", identity: { identity.get() })
        XCTAssertNoThrow(try freshAccess.check())
    }

    func testLibraryMetadataSyncsBothWaysWithoutDownloadingOrReplacingVideo() async throws {
        let cloud = try temporaryDirectory()
        let source = try makeManager(withVideo: true)
        let id = try XCTUnwrap(source.records.first?.id)
        let sourceMetadata = VideoMetadataStore(rootDirectory: source.rootDirectory)
        try sourceMetadata.toggleFavorite(id)
        try sourceMetadata.setTags(["旅行", "Family"], for: id)
        try sourceMetadata.setCoverFrameSeconds(3, for: id)
        let sourceSync = makeController(source, cloud: cloud, metadata: sourceMetadata)
        await sourceSync.refreshAccount()
        XCTAssertNil(sourceSync.metadataMessage)
        let package = CloudVideoFiles.packageURL(id, container: cloud)
        let manifestURL = package.appendingPathComponent(CloudVideoArchive.manifestFilename)
        let mediaURL = package.appendingPathComponent("video.mp4")
        let manifestBefore = try Data(contentsOf: manifestURL)
        let videoBefore = try Data(contentsOf: mediaURL)
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: mediaURL.path)

        let destination = try makeManager()
        let destinationMetadata = VideoMetadataStore(rootDirectory: destination.rootDirectory)
        let destinationSync = makeController(destination, cloud: cloud, metadata: destinationMetadata)
        await destinationSync.refreshAccount()
        XCTAssertEqual(destinationMetadata.metadata(for: id), sourceMetadata.metadata(for: id))
        XCTAssertEqual(destinationMetadata.coverFrameSeconds(for: id), 3)
        XCTAssertTrue(destination.records.isEmpty)
        XCTAssertTrue(try mediaFiles(in: destination).isEmpty, "Editing cloud-only metadata must not download media.")

        // A metadata edit itself schedules synchronization; no manual synchronize call here.
        try destinationMetadata.toggleFavorite(id)
        try destinationMetadata.setTags([], for: id)
        try destinationMetadata.setCoverFrameSeconds(nil, for: id)
        let cleared = try XCTUnwrap(destinationMetadata.metadata(for: id))
        try await waitUntil {
            (try? CloudVideoMetadataFiles.read(at: CloudVideoMetadataFiles.fileURL(id, container: cloud), id: id)) == cleared
        }
        await sourceSync.synchronize()
        XCTAssertEqual(sourceMetadata.metadata(for: id), cleared)
        XCTAssertFalse(sourceMetadata.isFavorite(id))
        XCTAssertEqual(sourceMetadata.tags(for: id), [])
        XCTAssertNil(sourceMetadata.coverFrameSeconds(for: id))
        let relaunched = VideoMetadataStore(rootDirectory: source.rootDirectory)
        XCTAssertEqual(relaunched.metadata(for: id), cleared)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: mediaURL), videoBefore)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: mediaURL.path)[.modificationDate] as? Date,
                       attributesBefore[.modificationDate] as? Date, "A tag edit must not replace or re-upload the video package.")
        let raw = try String(contentsOf: CloudVideoMetadataFiles.fileURL(id, container: cloud), encoding: .utf8)
        for secret in ["signedSecret", "pageSecret", "frameSecret", "private-path", "https:", "Cookie", "localRelativePath"] {
            XCTAssertFalse(raw.contains(secret))
        }
    }

    func testAnnotationsWaitLocallyUntilTheirVideoHasACloudEntry() async throws {
        let cloud = try temporaryDirectory()
        let manager = try makeManager()
        let metadata = VideoMetadataStore(rootDirectory: manager.rootDirectory)
        let unpublished = UUID()
        try metadata.toggleFavorite(unpublished)
        try metadata.setTags(["仅本机"], for: unpublished)
        let sync = makeController(manager, cloud: cloud, metadata: metadata)
        await sync.refreshAccount()
        XCTAssertTrue(sync.visibleEntries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudVideoMetadataFiles.fileURL(unpublished, container: cloud).path))
        XCTAssertEqual(metadata.tags(for: unpublished), ["仅本机"])
        XCTAssertTrue(metadata.isFavorite(unpublished))
    }

    func testCloudOnlyMetadataOwnershipSurvivesAccountChangeAndRelaunch() async throws {
        let cloud = try temporaryDirectory()
        let source = try makeManager(withVideo: true)
        let id = try XCTUnwrap(source.records.first?.id)
        let sourceMetadata = VideoMetadataStore(rootDirectory: source.rootDirectory)
        try sourceMetadata.setTags(["原账号标签"], for: id)
        let sourceSync = makeController(source, cloud: cloud, metadata: sourceMetadata)
        await sourceSync.refreshAccount()

        let destination = try makeManager()
        let metadata = VideoMetadataStore(rootDirectory: destination.rootDirectory)
        let identity = SimulatedCloudIdentity("first-account")
        let sync = CloudVideoSync(downloads: destination, metadataStore: metadata,
            containerOverride: cloud, identityOverride: { identity.get() })
        controllers.append(sync)
        await sync.refreshAccount()
        XCTAssertTrue(destination.records.isEmpty)
        XCTAssertEqual(metadata.tags(for: id), ["原账号标签"])

        // Reusing this synthetic UUID in the replacement container must not leak
        // the previous account's local annotations, even without a local video.
        try FileManager.default.removeItem(at: CloudVideoMetadataFiles.fileURL(id, container: cloud))
        identity.set("second-account")
        await sync.refreshAccount()
        XCTAssertTrue(sync.accountChanged)
        await sync.acceptCurrentAccount()
        XCTAssertTrue(sync.isAvailable)
        await sync.restore(id: id)
        XCTAssertTrue(destination.records.isEmpty, "Restoring a colliding UUID must not rebind the previous account's annotations.")
        try metadata.setTags(["原账号的本机新修改"], for: id)
        try metadata.setCoverFrameSeconds(2, for: id)
        await sync.synchronize()
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudVideoMetadataFiles.fileURL(id, container: cloud).path))
        XCTAssertEqual(metadata.tags(for: id), ["原账号的本机新修改"])

        let restartedMetadata = VideoMetadataStore(rootDirectory: destination.rootDirectory)
        let restarted = CloudVideoSync(downloads: destination, metadataStore: restartedMetadata,
            containerOverride: cloud, identityOverride: { identity.get() })
        controllers.append(restarted)
        await restarted.refreshAccount()
        XCTAssertTrue(restarted.isAvailable)
        XCTAssertEqual(restartedMetadata.tags(for: id), ["原账号的本机新修改"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudVideoMetadataFiles.fileURL(id, container: cloud).path))
    }

    func testVideoDeletionWinsOverLateMetadataAndRemovesSidecarOnBothDevices() async throws {
        let cloud = try temporaryDirectory()
        let first = try makeManager(withVideo: true)
        let id = try XCTUnwrap(first.records.first?.id)
        let firstMetadata = VideoMetadataStore(rootDirectory: first.rootDirectory)
        try firstMetadata.toggleFavorite(id)
        let firstSync = makeController(first, cloud: cloud, metadata: firstMetadata)
        await firstSync.refreshAccount()
        let second = try makeManager()
        let secondMetadata = VideoMetadataStore(rootDirectory: second.rootDirectory)
        let secondSync = makeController(second, cloud: cloud, metadata: secondMetadata)
        await secondSync.refreshAccount()
        XCTAssertTrue(secondMetadata.isFavorite(id))

        await secondSync.deleteEverywhere(id: id)
        XCTAssertNil(secondMetadata.metadata(for: id))
        try firstMetadata.setTags(["另一端迟到的修改"], for: id)
        try firstMetadata.setCoverFrameSeconds(2, for: id)
        let late = try XCTUnwrap(firstMetadata.metadata(for: id))
        await firstSync.synchronize()
        XCTAssertNil(firstMetadata.metadata(for: id))
        XCTAssertTrue(first.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudVideoMetadataFiles.fileURL(id, container: cloud).path))
        let publication = try CloudVideoMetadataFiles.synchronize(local: [id: late], allowedIDs: [id], deletedIDs: [],
            container: cloud, metadataURLs: [], ubiquitous: false)
        XCTAssertEqual(publication.deleted, [id])
        XCTAssertTrue(publication.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudVideoMetadataFiles.fileURL(id, container: cloud).path))
        XCTAssertNil(VideoMetadataStore(rootDirectory: first.rootDirectory).metadata(for: id))
    }

    func testCoverSelectionUpdatesCloudPreviewWithoutReplacingMediaAndRestoresSelectedFrame() async throws {
        let cloud = try temporaryDirectory()
        let source = try makeManager(withVideo: true)
        let record = try XCTUnwrap(source.records.first)
        let id = record.id
        let metadata = VideoMetadataStore(rootDirectory: source.rootDirectory)
        let sync = makeController(source, cloud: cloud, metadata: metadata)
        await sync.refreshAccount()
        let package = CloudVideoFiles.packageURL(id, container: cloud)
        let marker = package.appendingPathComponent(CloudVideoFiles.coverRevisionFilename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "A legacy video with no library metadata stays untouched.")
        let manifest = try CloudVideoArchive.readManifest(at: package)
        let media = package.appendingPathComponent("video.mp4")
        let mediaBefore = try Data(contentsOf: media)
        let mediaDate = try FileManager.default.attributesOfItem(atPath: media.path)[.modificationDate] as? Date
        let manifestBefore = try Data(contentsOf: package.appendingPathComponent(CloudVideoArchive.manifestFilename))

        try metadata.setCoverFrameSeconds(3, for: id)
        await sync.synchronize()
        let selected = try XCTUnwrap(metadata.metadata(for: id))
        XCTAssertTrue(try CloudVideoFiles.hasCurrentCover(metadata: selected, manifest: manifest, container: cloud, ubiquitous: false))
        let selectedJPEG = try XCTUnwrap(CloudVideoArchive.thumbnailData(at: package))
        XCTAssertEqual(sync.entry(for: id)?.thumbnail, selectedJPEG)
        let markerDate = try FileManager.default.attributesOfItem(atPath: marker.path)[.modificationDate] as? Date
        let markerBefore = try Data(contentsOf: marker)
        await sync.synchronize()
        XCTAssertEqual(try Data(contentsOf: marker), markerBefore)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: marker.path)[.modificationDate] as? Date, markerDate,
            "The same annotation revision must not continually rewrite the cloud preview.")

        let destination = try makeManager()
        let destinationMetadata = VideoMetadataStore(rootDirectory: destination.rootDirectory)
        let destinationSync = makeController(destination, cloud: cloud, metadata: destinationMetadata)
        await destinationSync.refreshAccount()
        XCTAssertEqual(destinationMetadata.coverFrameSeconds(for: id), 3)
        XCTAssertEqual(destinationSync.entry(for: id)?.thumbnail, selectedJPEG)
        XCTAssertTrue(destination.records.isEmpty, "A selected cover must not trigger media restoration.")
        await destinationSync.restore(id: id)
        let restored = try XCTUnwrap(destination.records.first)
        XCTAssertEqual(destinationMetadata.coverFrameSeconds(for: id), 3)
        let restoredImage = await destination.thumbnailStore.image(for: restored,
            localURL: try XCTUnwrap(destination.localURL(for: restored)), frameSeconds: 3)
        XCTAssertNotNil(restoredImage)

        try destinationMetadata.setCoverFrameSeconds(nil, for: id)
        await destinationSync.synchronize()
        await sync.synchronize()
        XCTAssertNil(metadata.coverFrameSeconds(for: id))
        let automatic = try XCTUnwrap(metadata.metadata(for: id))
        XCTAssertTrue(try CloudVideoFiles.hasCurrentCover(metadata: automatic, manifest: manifest, container: cloud, ubiquitous: false))
        XCTAssertEqual(try Data(contentsOf: media), mediaBefore)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: media.path)[.modificationDate] as? Date, mediaDate)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent(CloudVideoArchive.manifestFilename)), manifestBefore)
    }

    func testCoverWriterRejectsStaleRevisionDeletionAndCancelledAccountOrRender() async throws {
        let cloud = try temporaryDirectory()
        let manager = try makeManager(withVideo: true)
        let id = try XCTUnwrap(manager.records.first?.id)
        let metadata = VideoMetadataStore(rootDirectory: manager.rootDirectory)
        try metadata.setCoverFrameSeconds(1, for: id)
        let sync = makeController(manager, cloud: cloud, metadata: metadata)
        await sync.refreshAccount()
        let package = CloudVideoFiles.packageURL(id, container: cloud)
        let manifest = try CloudVideoArchive.readManifest(at: package)
        let jpeg = try XCTUnwrap(CloudVideoArchive.thumbnailData(at: package))
        let original = try XCTUnwrap(metadata.metadata(for: id))
        var newer = original
        newer.coverFrameSeconds = 3
        newer.updatedAt = newer.updatedAt.addingTimeInterval(1)
        newer.revision = UUID()
        _ = try CloudVideoMetadataFiles.synchronize(local: [id: newer], allowedIDs: [id], deletedIDs: [],
            container: cloud, metadataURLs: [], ubiquitous: false)
        let marker = package.appendingPathComponent(CloudVideoFiles.coverRevisionFilename)
        let before = try Data(contentsOf: marker)
        XCTAssertFalse(try CloudVideoFiles.updateCover(thumbnailJPEG: jpeg, metadata: original, manifest: manifest,
            container: cloud, ubiquitous: false), "A late rendered frame cannot replace the winning remote revision.")
        XCTAssertEqual(try Data(contentsOf: marker), before)
        let cancelledAccount = CloudSyncAccess(account: "first", identity: { "second" })
        XCTAssertThrowsError(try CloudVideoFiles.updateCover(thumbnailJPEG: jpeg, metadata: newer, manifest: manifest,
            container: cloud, ubiquitous: false, access: cancelledAccount))
        let render = CloudCoverWriteAccess()
        render.cancel()
        XCTAssertThrowsError(try CloudVideoFiles.updateCover(thumbnailJPEG: jpeg, metadata: newer, manifest: manifest,
            container: cloud, ubiquitous: false, writeAccess: render))
        XCTAssertEqual(try Data(contentsOf: marker), before)
        try CloudVideoFiles.delete(id: id, container: cloud)
        XCTAssertFalse(try CloudVideoFiles.updateCover(thumbnailJPEG: jpeg, metadata: newer, manifest: manifest,
            container: cloud, ubiquitous: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path), "Cover publication cannot recreate a deleted package.")
    }

    func testCoverWriterRejectsLinkedDestinationsAndOversizedImageWithoutChangingMedia() async throws {
        let cloud = try temporaryDirectory()
        let manager = try makeManager(withVideo: true)
        let id = try XCTUnwrap(manager.records.first?.id)
        let metadata = VideoMetadataStore(rootDirectory: manager.rootDirectory)
        try metadata.setCoverFrameSeconds(1, for: id)
        let sync = makeController(manager, cloud: cloud, metadata: metadata)
        await sync.refreshAccount()
        let package = CloudVideoFiles.packageURL(id, container: cloud)
        let manifest = try CloudVideoArchive.readManifest(at: package)
        let jpeg = try XCTUnwrap(CloudVideoArchive.thumbnailData(at: package))
        let media = package.appendingPathComponent("video.mp4")
        let mediaBefore = try Data(contentsOf: media)
        let prior = try XCTUnwrap(metadata.metadata(for: id))
        var newer = prior
        newer.revision = UUID(); newer.updatedAt = newer.updatedAt.addingTimeInterval(1)
        _ = try CloudVideoMetadataFiles.synchronize(local: [id: newer], allowedIDs: [id], deletedIDs: [],
            container: cloud, metadataURLs: [], ubiquitous: false)
        XCTAssertThrowsError(try CloudVideoFiles.updateCover(thumbnailJPEG: Data(repeating: 0, count: CloudVideoArchive.maximumThumbnailBytes + 1),
            metadata: newer, manifest: manifest, container: cloud, ubiquitous: false))
        let outside = cloud.appendingPathComponent("untouched.jpg")
        try jpeg.write(to: outside)
        let preview = package.appendingPathComponent(CloudVideoArchive.thumbnailFilename)
        try FileManager.default.removeItem(at: preview)
        try FileManager.default.createSymbolicLink(at: preview, withDestinationURL: outside)
        XCTAssertThrowsError(try CloudVideoFiles.updateCover(thumbnailJPEG: jpeg, metadata: newer, manifest: manifest,
            container: cloud, ubiquitous: false))
        XCTAssertEqual(try Data(contentsOf: outside), jpeg)
        XCTAssertEqual(try Data(contentsOf: media), mediaBefore)
    }

    func testValidButMismatchedJPEGIsHiddenUntilWinningCoverIsRepaired() async throws {
        let cloud = try temporaryDirectory()
        let manager = try makeManager(withVideo: true)
        let record = try XCTUnwrap(manager.records.first)
        let metadata = VideoMetadataStore(rootDirectory: manager.rootDirectory)
        try metadata.setCoverFrameSeconds(1, for: record.id)
        let sync = makeController(manager, cloud: cloud, metadata: metadata)
        await sync.refreshAccount()
        let package = CloudVideoFiles.packageURL(record.id, container: cloud)
        let manifest = try CloudVideoArchive.readManifest(at: package)
        let selected = try XCTUnwrap(metadata.metadata(for: record.id))
        let correctJPEG = try XCTUnwrap(CloudVideoArchive.thumbnailData(at: package))
        let local = try XCTUnwrap(manager.localURL(for: record))
        let differentFrame = await LocalVideoThumbnailRenderer.frameJPEG(url: local, seconds: 4, duration: record.duration)
        let differentJPEG = try XCTUnwrap(differentFrame)
        XCTAssertNotEqual(differentJPEG, correctJPEG)
        let preview = package.appendingPathComponent(CloudVideoArchive.thumbnailFilename)
        // Reproduce independent iCloud file arrival: a valid JPEG from a different revision.
        try differentJPEG.write(to: preview, options: .atomic)
        XCTAssertEqual(try CloudVideoArchive.thumbnailData(at: package), differentJPEG, "The replacement must still be a valid JPEG.")
        XCTAssertFalse(try CloudVideoFiles.hasCurrentCover(metadata: selected, manifest: manifest, container: cloud, ubiquitous: false))
        let pending = try CloudVideoFiles.snapshot(container: cloud, metadataURLs: [], ubiquitous: false)
        XCTAssertNil(pending.entries.first(where: { $0.id == record.id })?.thumbnail,
            "A cloud-only list must not display a frame that contradicts the marker.")
        XCTAssertTrue(try CloudVideoFiles.updateCover(thumbnailJPEG: correctJPEG, metadata: selected, manifest: manifest,
            container: cloud, ubiquitous: false), "The already-current branch must also verify the JPEG hash.")
        XCTAssertTrue(try CloudVideoFiles.hasCurrentCover(metadata: selected, manifest: manifest, container: cloud, ubiquitous: false))
        let repaired = try CloudVideoFiles.snapshot(container: cloud, metadataURLs: [], ubiquitous: false)
        XCTAssertEqual(repaired.entries.first(where: { $0.id == record.id })?.thumbnail, correctJPEG)
        XCTAssertFalse(try CloudVideoFiles.updateCover(thumbnailJPEG: differentJPEG, metadata: selected, manifest: manifest,
            container: cloud, ubiquitous: false), "A complete matching pair stays unchanged, even if another renderer encoded different bytes.")
        XCTAssertEqual(try CloudVideoArchive.thumbnailData(at: package), correctJPEG)
    }

    func testLegacyMarkerWithoutJPEGHashNeedsRepairBeforePreviewIsShown() async throws {
        let cloud = try temporaryDirectory()
        let manager = try makeManager(withVideo: true)
        let id = try XCTUnwrap(manager.records.first?.id)
        let metadata = VideoMetadataStore(rootDirectory: manager.rootDirectory)
        try metadata.setCoverFrameSeconds(1, for: id)
        let sync = makeController(manager, cloud: cloud, metadata: metadata)
        await sync.refreshAccount()
        let package = CloudVideoFiles.packageURL(id, container: cloud)
        let manifest = try CloudVideoArchive.readManifest(at: package)
        let jpeg = try XCTUnwrap(CloudVideoArchive.thumbnailData(at: package))
        let annotation = try XCTUnwrap(metadata.metadata(for: id))
        let marker = package.appendingPathComponent(CloudVideoFiles.coverRevisionFilename)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        legacy.removeValue(forKey: "thumbnailSHA256")
        legacy["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: legacy).write(to: marker, options: .atomic)
        XCTAssertFalse(try CloudVideoFiles.hasCurrentCover(metadata: annotation, manifest: manifest, container: cloud, ubiquitous: false))
        let pending = try CloudVideoFiles.snapshot(container: cloud, metadataURLs: [], ubiquitous: false)
        XCTAssertNil(pending.entries.first(where: { $0.id == id })?.thumbnail)
        XCTAssertTrue(try CloudVideoFiles.updateCover(thumbnailJPEG: jpeg, metadata: annotation, manifest: manifest,
            container: cloud, ubiquitous: false))
        let repaired = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        XCTAssertEqual(repaired["schemaVersion"] as? Int, 2)
        XCTAssertEqual((repaired["thumbnailSHA256"] as? String)?.count, 64)
        XCTAssertTrue(try CloudVideoFiles.hasCurrentCover(metadata: annotation, manifest: manifest, container: cloud, ubiquitous: false))
        // NSFileVersion conflict creation is not deterministic in a local temporary container;
        // native iCloud conflict delivery remains a separate device acceptance check.
    }

    func testInvalidMetadataFileDoesNotBlockCloudVideoRestore() async throws {
        let cloud = try temporaryDirectory()
        let first = try makeManager(withVideo: true)
        let id = try XCTUnwrap(first.records.first?.id)
        let firstMetadata = VideoMetadataStore(rootDirectory: first.rootDirectory)
        try firstMetadata.setTags(["有效本机标签"], for: id)
        let firstSync = makeController(first, cloud: cloud, metadata: firstMetadata)
        await firstSync.refreshAccount()
        try Data("invalid cloud annotation".utf8).write(to: CloudVideoMetadataFiles.fileURL(id, container: cloud))
        await firstSync.synchronize()
        XCTAssertNotNil(firstSync.metadataMessage)
        XCTAssertTrue(firstSync.isAvailable)
        XCTAssertEqual(firstMetadata.tags(for: id), ["有效本机标签"])

        let second = try makeManager()
        let secondMetadata = VideoMetadataStore(rootDirectory: second.rootDirectory)
        let secondSync = makeController(second, cloud: cloud, metadata: secondMetadata)
        await secondSync.refreshAccount()
        XCTAssertNotNil(secondSync.metadataMessage)
        XCTAssertNotNil(secondSync.entry(for: id))
        await secondSync.restore(id: id)
        XCTAssertEqual(second.records.first?.phase, .complete)
        XCTAssertNotNil(second.records.first.flatMap { second.localURL(for: $0) })
        XCTAssertTrue(secondMetadata.entries.isEmpty)
    }

    private func makeManager(withVideo: Bool = false, sourceKind: MediaKind = .file) throws -> DownloadManager {
        let directory = try temporaryDirectory()
        if withVideo {
            let mediaDirectory = directory.appendingPathComponent("Media", isDirectory: true)
            try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: false)
            try fixture.write(to: mediaDirectory.appendingPathComponent("fixture.mp4"))
            let page = URL(string: "https://example.org/private-path/watch?session=pageSecret")!
            let sourceFilename = sourceKind == .hls ? "master.m3u8" : "video.mp4"
            let candidate = MediaCandidate(url: URL(string: "https://cdn.example.org/\(sourceFilename)?signature=signedSecret")!,
                pageURL: page, frameURL: URL(string: "https://example.org/embed?secret=frameSecret")!,
                title: "本机同步测试视频", kind: sourceKind, source: "fixture")
            let record = DownloadRecord(id: UUID(), candidate: candidate, phase: .complete, progress: 1,
                bytesWritten: Int64(fixture.count), expectedBytes: Int64(fixture.count), localRelativePath: "Media/fixture.mp4",
                failure: nil, duration: 8, hasAudio: true, createdAt: Date(timeIntervalSince1970: 1_750_000_000))
            try JSONEncoder().encode([record]).write(to: directory.appendingPathComponent("downloads.json"))
        }
        let manager = DownloadManager(rootDirectory: directory)
        managers.append(manager)
        return manager
    }

    private func makeController(_ manager: DownloadManager, cloud: URL, metadata: VideoMetadataStore? = nil) -> CloudVideoSync {
        let controller = CloudVideoSync(downloads: manager, metadataStore: metadata, containerOverride: cloud)
        controllers.append(controller)
        return controller
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-cloud-sync-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    private func mediaFiles(in manager: DownloadManager) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: manager.rootDirectory.appendingPathComponent("Media"), includingPropertiesForKeys: nil)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard condition() else { XCTFail("The simulated cloud operation did not finish."); throw CloudVideoArchiveError.fileOperationFailed }
    }
}

private final class SimulatedCloudIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String?) { self.value = value }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: String?) { lock.lock(); defer { lock.unlock() }; self.value = value }
}
