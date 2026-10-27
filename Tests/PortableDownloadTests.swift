import AVFoundation
import Combine
import UIKit
import XCTest
@testable import VYu

/// The default manager path must produce a self-contained movie from generated HLS.
@MainActor final class PortableDownloadTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8765")!
    private var managers: [DownloadManager] = []
    private var fixtureReady = false

    override func setUp() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(from: base.appendingPathComponent("__health")) }
        catch let error as URLError where error.code == .cannotConnectToHost {
            throw XCTSkip("Generate fixtures and start fixtures/server.py on 127.0.0.1:8765 first.")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let health = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              health["ready"] as? Bool == true else {
            XCTFail("Fixture server is reachable but its generated media is not ready.")
            throw FixtureFailure.notReady
        }
        try await setOffline(false)
        fixtureReady = true
    }

    override func tearDown() async throws {
        defer {
            for manager in managers {
                for id in manager.records.map(\.id) { manager.removeRecord(id: id) }
                try? FileManager.default.removeItem(at: manager.rootDirectory)
            }
            managers = []
        }
        if fixtureReady { try await setOffline(false) }
    }

    func testHLSResourcesContinueInBackgroundAndAssembleOfflineOnReturn() async throws {
        let manager = makeManager()
        let source = candidate(path: "background-hls-media/master.m3u8")
        await manager.start(candidate: source, cookies: [])
        let id = try XCTUnwrap(manager.records.first?.id)
        XCTAssertFalse(manager.transferNeedsForeground(id: id))
        manager.setAppInBackground(true)
        try await waitUntil("Daemon finishes all resources without foreground assembly", timeout: 45) {
            manager.backgroundTransferStatus(id: id) != nil
        }
        let pending = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(pending.phase, .validating)
        XCTAssertNil(pending.localRelativePath)
        XCTAssertGreaterThan(pending.bytesWritten, 0)
        try await setOffline(true)
        manager.setAppInBackground(false)
        let completed = try await completedRecord(manager, id: id)
        XCTAssertEqual(completed.duration ?? 0, 8, accuracy: 0.25)
        XCTAssertEqual(completed.hasAudio, true)
        XCTAssertEqual(manager.localURL(for: completed)?.pathExtension, "mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.rootDirectory.appendingPathComponent("BackgroundHLS/" + id.uuidString).path))
    }

    func testBackgroundHLSRejectsDamagedResourceBeforeExport() async throws {
        let manager = makeManager()
        await manager.start(candidate: candidate(), cookies: [])
        let id = try XCTUnwrap(manager.records.first?.id)
        manager.setAppInBackground(true)
        try await waitUntil("Resources are ready", timeout: 45) { manager.backgroundTransferStatus(id: id) != nil }
        let folder = manager.rootDirectory.appendingPathComponent("BackgroundHLS/" + id.uuidString)
        try Data("damaged resource".utf8).write(to: folder.appendingPathComponent("0.part"))
        manager.setAppInBackground(false)
        try await waitUntil("Corrupt resource fails validation", timeout: 20) { manager.records.first?.phase == .failed }
        XCTAssertNil(manager.records.first?.localRelativePath)
        XCTAssertFalse(manager.records.contains { $0.phase == .complete })
    }

    func testBackgroundHLSPauseResumeRetainsCompletedResources() async throws {
        let manager = makeManager()
        let source = candidate(path: "background-hls-media/master.m3u8")
        await manager.start(candidate: source, cookies: [])
        let id = try XCTUnwrap(manager.records.first?.id)
        try await waitUntil("At least one completed resource", timeout: 20) { (manager.records.first?.bytesWritten ?? 0) > 0 }
        manager.pause(id: id)
        XCTAssertEqual(manager.records.first?.phase, .paused)
        XCTAssertTrue(manager.canResume(id: id))
        manager.resume(id: id)
        let complete = try await completedRecord(manager, id: id)
        XCTAssertEqual(complete.hasAudio, true)
        XCTAssertEqual(complete.duration ?? 0, 8, accuracy: 0.25)
    }

    func testReadyHLSPlanSurvivesManagerRecreationAndFinishesWithoutNetwork() async throws {
        let original = makeManager()
        await original.start(candidate: candidate(), cookies: [])
        let id = try XCTUnwrap(original.records.first?.id)
        original.setAppInBackground(true)
        try await waitUntil("All resources are durable", timeout: 45) { original.backgroundTransferStatus(id: id) != nil }
        try await setOffline(true)
        let restored = DownloadManager(rootDirectory: original.rootDirectory, initiallyInBackground: true)
        managers.append(restored)
        try await waitUntil("Restored job is waiting for foreground", timeout: 10) { restored.backgroundTransferStatus(id: id) != nil }
        XCTAssertEqual(restored.records.first?.phase, .validating)
        restored.setAppInBackground(false)
        let complete = try await completedRecord(restored, id: id)
        XCTAssertEqual(complete.hasAudio, true)
        XCTAssertEqual(complete.duration ?? 0, 8, accuracy: 0.25)
    }

    func testDefaultBackgroundPathSupportsMuxedFMP4ByteRanges() async throws {
        let manager = makeManager()
        await manager.start(candidate: candidate(path: "media/hls-fmp4/index.m3u8"), cookies: [])
        let complete = try await completedRecord(manager, id: XCTUnwrap(manager.records.first?.id))
        XCTAssertEqual(complete.duration ?? 0, 8, accuracy: 0.25)
        XCTAssertEqual(complete.hasAudio, true)
        XCTAssertEqual(manager.localURL(for: complete)?.pathExtension, "mp4")
    }

    func testBackgroundSessionRejectionFallsBackToAuthorizedForegroundRequest() async throws {
        let manager = makeManager()
        await manager.start(candidate: candidate(path: "background-hls-session-media/master.m3u8"), cookies: [])
        let id = try XCTUnwrap(manager.records.first?.id)
        let complete = try await completedRecord(manager, id: id)
        XCTAssertEqual(complete.hasAudio, true)
        XCTAssertEqual(complete.duration ?? 0, 8, accuracy: 0.25)
        XCTAssertTrue(manager.transferNeedsForeground(id: id))
    }

    func testSystemHLSWithoutWebRelayCanContinueInBackground() async throws {
        let manager = makeManager()
        await manager.start(candidate: candidate(path: "media/hls/master.m3u8"), cookies: [])
        let id = try XCTUnwrap(manager.records.first?.id)
        XCTAssertFalse(manager.transferNeedsForeground(id: id), "Native system HLS without a relay must not be paused as a portable export.")
        manager.setAppInBackground(true)
        let complete = try await completedRecord(manager, id: id)
        XCTAssertEqual(complete.hasAudio, true)
        XCTAssertEqual(manager.localURL(for: complete)?.pathExtension, "movpkg")
    }

    func testRestartAfterMP4CommitValidatesExistingMovieWithoutCreatingAnother() async throws {
        let original = makeManager()
        let recoveredRoot = temporaryRoot()
        var capturedPath: String?
        var captureError: Error?
        let observer = original.$records.sink { records in
            guard capturedPath == nil, let record = records.first(where: { $0.phase == .validating && $0.localRelativePath != nil }),
                  let relative = record.localRelativePath else { return }
            capturedPath = relative
            do {
                try FileManager.default.createDirectory(at: recoveredRoot.appendingPathComponent("Media"), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: original.rootDirectory.appendingPathComponent(relative), to: recoveredRoot.appendingPathComponent(relative))
                try FileManager.default.copyItem(at: original.rootDirectory.appendingPathComponent("downloads.json"), to: recoveredRoot.appendingPathComponent("downloads.json"))
                try FileManager.default.copyItem(at: original.rootDirectory.appendingPathComponent("BackgroundHLS"), to: recoveredRoot.appendingPathComponent("BackgroundHLS"))
            } catch { captureError = error }
        }
        defer { observer.cancel() }
        await original.start(candidate: candidate(), cookies: [])
        let id = try XCTUnwrap(original.records.first?.id)
        _ = try await completedRecord(original, id: id)
        XCTAssertNil(captureError)
        let relative = try XCTUnwrap(capturedPath)
        try await setOffline(true)
        let recovered = makeManager(root: recoveredRoot)
        let complete = try await completedRecord(recovered, id: id)
        XCTAssertEqual(complete.localRelativePath, relative)
        XCTAssertEqual(try mediaFiles(recovered).count, 1)
        XCTAssertEqual(complete.hasAudio, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveredRoot.appendingPathComponent("BackgroundHLS/" + id.uuidString).path))
    }

    func testDefaultManagerExportsSeparateFMP4ToCompleteMP4WithOfflineThumbnail() async throws {
        let manager = makeManager()
        let source = candidate()
        await manager.start(candidate: source, cookies: [])
        let id = try XCTUnwrap(manager.records.first?.id)
        let record = try await completedRecord(manager, id: id)
        XCTAssertEqual(record.candidate.kind, .hls, "The source remains HLS even when its local copy is MP4.")
        XCTAssertEqual(record.candidate, source)
        XCTAssertEqual(record.duration ?? 0, 8, accuracy: 0.25)
        XCTAssertEqual(record.hasAudio, true)
        XCTAssertEqual(record.progress, 1)
        let local = try XCTUnwrap(manager.localURL(for: record))
        XCTAssertEqual(local.pathExtension, "mp4", "The default path must not silently fall back to movpkg for this supported fixture.")
        XCTAssertEqual(local.deletingLastPathComponent().standardizedFileURL,
                       manager.rootDirectory.appendingPathComponent("Media").standardizedFileURL)
        XCTAssertGreaterThan(record.bytesWritten, 0)
        XCTAssertEqual(record.bytesWritten, Int64(try local.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
        XCTAssertEqual(try mediaFiles(manager), [local.lastPathComponent], "Export intermediates must be removed on success.")

        try await setOffline(true)
        let (_, response) = try await URLSession.shared.data(from: source.url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        let asset = AVURLAsset(url: local, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ])
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(playable)
        XCTAssertEqual(duration, 8, accuracy: 0.25)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 1)
        for track in video + audio {
            let range = try await track.load(.timeRange)
            XCTAssertGreaterThanOrEqual(range.duration.seconds, 7.75, "Both media tracks must span the complete fixture.")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        defer { generator.cancelAllCGImageGeneration() }
        for seconds in [0.5, 7.25] {
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            XCTAssertGreaterThan(image.width, 0)
            XCTAssertGreaterThan(image.height, 0)
        }

        let thumbnail = await manager.thumbnailStore.image(for: record, localURL: local)
        let pixels = try XCTUnwrap(thumbnail?.cgImage, "A completed portable HLS video must have a locally decoded preview.")
        XCTAssertGreaterThan(pixels.width, 0)
        XCTAssertGreaterThan(pixels.height, 0)
        XCTAssertLessThanOrEqual(pixels.width, 480)
        XCTAssertLessThanOrEqual(pixels.height, 270)
    }

    func testCancelAfterReceivingMediaDoesNotRestoreACompletedRecordOrFile() async throws {
        try await verifyStoppingActiveExport(removeRecord: false)
    }

    func testDeleteAfterReceivingMediaDoesNotRestoreTheRecordOrFile() async throws {
        try await verifyStoppingActiveExport(removeRecord: true)
    }

    func testStartupRemovesOnlyAbandonedExportNamesAndRetainsReferencedMovies() throws {
        let root = temporaryRoot()
        let media = root.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let referenced = "portable-\(UUID().uuidString).mp4"
        let abandoned = "portable-\(UUID().uuidString).mp4"
        let stage = ".hls-export-\(UUID().uuidString)"
        let retained = [referenced, "ordinary.mp4", "portable-not-a-uuid.mp4", ".hls-export-not-a-uuid",
                        "portable-\(UUID().uuidString).mov", ".hls-export-\(UUID().uuidString)-notes"]
        let marker = Data("Cleanup ownership fixture".utf8)
        for name in retained + [abandoned] { try marker.write(to: media.appendingPathComponent(name)) }
        let stageURL = media.appendingPathComponent(stage, isDirectory: true)
        try FileManager.default.createDirectory(at: stageURL, withIntermediateDirectories: false)
        try marker.write(to: stageURL.appendingPathComponent("incomplete-fragment"))
        // The legacy array is a supported index format. Cleanup must use its
        // ownership paths, without treating media contents as its responsibility.
        let record = DownloadRecord(id: UUID(), candidate: candidate(), phase: .complete, progress: 1,
            bytesWritten: Int64(marker.count), expectedBytes: nil, localRelativePath: "Media/" + referenced,
            failure: nil, duration: 8, hasAudio: true, createdAt: Date())
        try JSONEncoder().encode([record]).write(to: root.appendingPathComponent("downloads.json"))

        let manager = makeManager(root: root)
        XCTAssertEqual(try mediaFiles(manager), retained.sorted())
        XCTAssertEqual(manager.records.first?.localRelativePath, record.localRelativePath)
        XCTAssertEqual(manager.records.first?.phase, .complete)
        for name in retained { XCTAssertEqual(try Data(contentsOf: media.appendingPathComponent(name)), marker) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stageURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.appendingPathComponent(abandoned).path))
    }

    func testUnreadableOrMalformedIndexPreservesPortableMoviesAndThumbnails() throws {
        for unreadable in [true, false] {
            let root = temporaryRoot()
            let media = root.appendingPathComponent("Media", isDirectory: true)
            let thumbnails = root.appendingPathComponent("Thumbnails", isDirectory: true)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
            let movie = media.appendingPathComponent("portable-\(UUID().uuidString).mp4")
            let thumbnail = thumbnails.appendingPathComponent("\(UUID().uuidString)_existing.jpg")
            let marker = Data("Existing local data must survive an unreadable index".utf8)
            try marker.write(to: movie)
            try marker.write(to: thumbnail)
            let state = root.appendingPathComponent("downloads.json")
            if unreadable {
                // A directory reliably makes Data(contentsOf:) fail on device and simulator.
                try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
            } else {
                try Data("{incomplete archive".utf8).write(to: state)
            }

            let manager = makeManager(root: root)
            XCTAssertNotNil(manager.storageError)
            XCTAssertEqual(try Data(contentsOf: movie), marker,
                           "Unknown ownership must not be interpreted as an abandoned export.")
            XCTAssertEqual(try Data(contentsOf: thumbnail), marker,
                           "An unreadable archive does not mean its thumbnail owners were deleted.")
        }
    }

    func testPortableCompletionIsNotPublishedWhenFinalIndexWriteFails() async throws {
        let manager = makeManager()
        let root = manager.rootDirectory
        let blocked = expectation(description: "Block persistence after media transfer and before final commit")
        var didBlock = false
        var blockError: Error?
        var publishedComplete = false
        // This observer only changes filesystem state; it never reenters the
        // manager's @Published mutation. The first validating update precedes export.
        let observation = manager.$records.sink { entries in
            if entries.contains(where: { $0.phase == .complete }) { publishedComplete = true }
            guard !didBlock, entries.contains(where: { $0.phase == .validating && $0.bytesWritten > 0 }) else { return }
            didBlock = true
            do { try self.blockStateWrites(in: root) } catch { blockError = error }
            blocked.fulfill()
        }
        defer { observation.cancel() }
        await manager.start(candidate: candidate(), cookies: [])
        await fulfillment(of: [blocked], timeout: 30)
        XCTAssertNil(blockError)
        let id = try XCTUnwrap(manager.records.first?.id)
        try await waitUntil("A failed index commit must leave a retryable failed download", timeout: 60) {
            manager.records.first(where: { $0.id == id })?.phase == .failed
        }
        XCTAssertNotNil(manager.storageError)
        XCTAssertFalse(publishedComplete, "Observers and cloud sync must never receive an uncommitted completion.")
        let record = try XCTUnwrap(manager.records.first(where: { $0.id == id }))
        XCTAssertNotEqual(record.phase, .complete)
        if let local = manager.localURL(for: record) {
            XCTAssertFalse(CloudVideoArchive.isEligibleForSync(record: record, mediaURL: local))
        }
        let saved = try persistedRecords(at: root.appendingPathComponent("downloads-before-write-failure.json"))
        XCTAssertFalse(saved.contains { $0.id == id && $0.phase == .complete })
    }

    func testCloudPreparationCommitFailurePreservesOriginalRecordFileAndThumbnail() async throws {
        let root = temporaryRoot()
        let relative = "Media/existing.movpkg"
        let original = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        // This is an ownership fixture, not a playable package. Preparation uses
        // the generated remote HLS, and must not alter the old local copy on failure.
        let marker = Data("Previously completed local package".utf8)
        let owned = original.appendingPathComponent("existing-data")
        try marker.write(to: owned)
        let record = DownloadRecord(id: UUID(), candidate: candidate(), phase: .complete, progress: 1,
            bytesWritten: Int64(marker.count), expectedBytes: nil, localRelativePath: relative,
            failure: nil, duration: 8, hasAudio: true, createdAt: Date())
        let saved = try JSONEncoder().encode([record])
        try saved.write(to: root.appendingPathComponent("downloads.json"))
        let manager = makeManager(root: root)
        let thumbnail = root.appendingPathComponent("Thumbnails/\(record.id.uuidString)_existing.jpg")
        try marker.write(to: thumbnail)
        let blocked = expectation(description: "Block upgraded package commit after media transfer")
        var didBlock = false
        var blockError: Error?
        var publishedReplacement = false
        let records = manager.$records.sink { entries in
            if let current = entries.first(where: { $0.id == record.id }), current.localRelativePath != relative {
                publishedReplacement = true
            }
        }
        let status = manager.$cloudPreparationStatus.sink { statuses in
            guard !didBlock, statuses[record.id] == "正在检查可同步的视频…" else { return }
            didBlock = true
            do { try self.blockStateWrites(in: root) } catch { blockError = error }
            blocked.fulfill()
        }
        defer { records.cancel(); status.cancel() }
        manager.prepareCloudCopy(id: record.id)
        await fulfillment(of: [blocked], timeout: 30)
        XCTAssertNil(blockError)
        try await waitUntil("Preparing a cloud copy did not report its failed index commit", timeout: 60) {
            manager.storageError != nil
        }
        XCTAssertFalse(publishedReplacement, "An index write failure must keep the original in-memory ownership path.")
        XCTAssertEqual(manager.records.first(where: { $0.id == record.id }), record)
        XCTAssertEqual(try Data(contentsOf: owned), marker)
        XCTAssertEqual(try Data(contentsOf: thumbnail), marker)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("downloads-before-write-failure.json")), saved)
        XCTAssertFalse(CloudVideoArchive.isEligibleForSync(record: record, mediaURL: original))
    }

    func testFinalCompletionWriteCanBeRetriedFromTheExistingFileWhileOffline() async throws {
        let manager = makeManager()
        let root = manager.rootDirectory
        let blocked = expectation(description: "Block completion after the verified movie path is durable")
        var didBlock = false
        var writesBlocked = false
        var blockError: Error?
        var prematureCompletion = false
        let observation = manager.$records.sink { entries in
            if writesBlocked && entries.contains(where: { $0.phase == .complete }) { prematureCompletion = true }
            guard !didBlock, entries.contains(where: { $0.phase == .validating && $0.localRelativePath != nil }) else { return }
            didBlock = true
            do {
                try self.blockStateWrites(in: root)
                writesBlocked = true
            } catch { blockError = error }
            blocked.fulfill()
        }
        defer { observation.cancel() }
        await manager.start(candidate: candidate(), cookies: [])
        await fulfillment(of: [blocked], timeout: 30)
        XCTAssertNil(blockError)
        let id = try XCTUnwrap(manager.records.first?.id)
        try await waitUntil("Failed completion persistence did not leave a retryable record", timeout: 30) {
            manager.records.first(where: { $0.id == id })?.phase == .failed
        }
        let failed = try XCTUnwrap(manager.records.first(where: { $0.id == id }))
        let local = try XCTUnwrap(manager.localURL(for: failed), "A durably owned complete movie should be retained for retry.")
        let bytes = try Data(contentsOf: local)
        XCTAssertFalse(prematureCompletion)
        XCTAssertFalse(CloudVideoArchive.isEligibleForSync(record: failed, mediaURL: local))
        let backup = root.appendingPathComponent("downloads-before-write-failure.json")
        let saved = try XCTUnwrap(try persistedRecords(at: backup).first(where: { $0.id == id }))
        XCTAssertEqual(saved.phase, .validating)
        XCTAssertEqual(saved.localRelativePath, failed.localRelativePath)

        try await setOffline(true)
        let (_, response) = try await URLSession.shared.data(from: candidate().url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        let state = root.appendingPathComponent("downloads.json")
        try FileManager.default.removeItem(at: state)
        try FileManager.default.moveItem(at: backup, to: state)
        writesBlocked = false
        await manager.retry(id: id, cookies: [])
        let completed = try await completedRecord(manager, id: id)
        XCTAssertNil(manager.storageError)
        XCTAssertEqual(completed.localRelativePath, failed.localRelativePath,
                       "Retrying only the final commit must not replace or download the movie again.")
        XCTAssertEqual(try Data(contentsOf: local), bytes)
        XCTAssertTrue(CloudVideoArchive.isEligibleForSync(record: completed, mediaURL: local))
        XCTAssertEqual(try persistedRecords(at: state).first(where: { $0.id == id })?.phase, .complete)
    }

    private func blockStateWrites(in root: URL) throws {
        let state = root.appendingPathComponent("downloads.json")
        try FileManager.default.moveItem(at: state, to: root.appendingPathComponent("downloads-before-write-failure.json"))
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
    }

    private func persistedRecords(at state: URL) throws -> [DownloadRecord] {
        struct Archive: Decodable { let records: [DownloadRecord] }
        let data = try Data(contentsOf: state)
        if let archive = try? JSONDecoder().decode(Archive.self, from: data) { return archive.records }
        return try JSONDecoder().decode([DownloadRecord].self, from: data)
    }

    private func verifyStoppingActiveExport(removeRecord: Bool) async throws {
        let manager = makeManager()
        let stopped = expectation(description: "Stop after the portable exporter reports real media bytes")
        var stopTask: Task<Void, Never>?
        var stoppedID: UUID?
        // Schedule the mutation after @Published finishes publishing, avoiding a
        // reentrant write while progress is updating the record array.
        let observation = manager.$records.sink { entries in
            guard stopTask == nil, let entry = entries.first,
                  entry.phase == .downloading, entry.bytesWritten > 0 else { return }
            stoppedID = entry.id
            stopTask = Task { @MainActor in
                guard let current = manager.records.first(where: { $0.id == entry.id }),
                      [.downloading, .validating].contains(current.phase) else {
                    XCTFail("The fixture completed before cancellation could exercise an active export.")
                    stopped.fulfill()
                    return
                }
                if removeRecord { manager.removeRecord(id: entry.id) }
                else { manager.cancel(id: entry.id) }
                stopped.fulfill()
            }
        }
        defer { observation.cancel(); stopTask?.cancel() }
        await manager.start(candidate: candidate(), cookies: [])
        await fulfillment(of: [stopped], timeout: 30)
        if let stopTask { await stopTask.value }
        let id = try XCTUnwrap(stoppedID)
        try await waitUntil("Cancelled portable export left media or staging files behind", timeout: 10) {
            (try? self.mediaFiles(manager).isEmpty) == true
        }
        // The worker must finish its cleanup before its late result can arrive.
        // Check the resulting state across several actor turns as well.
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(50))
            if removeRecord { XCTAssertFalse(manager.records.contains { $0.id == id }) }
            else {
                let record = try XCTUnwrap(manager.records.first { $0.id == id })
                XCTAssertEqual(record.phase, .cancelled)
                XCTAssertNil(record.localRelativePath)
                XCTAssertNil(manager.localURL(for: record))
            }
            XCTAssertTrue(try mediaFiles(manager).isEmpty)
        }
    }

    private func makeManager(root: URL? = nil) -> DownloadManager {
        // Intentionally omit preferPortableHLS to exercise the production default.
        let manager = DownloadManager(rootDirectory: root ?? temporaryRoot())
        managers.append(manager)
        return manager
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("VYu-portable-download-" + UUID().uuidString)
    }

    private func candidate(path: String = "media/hls-fmp4-separate/master.m3u8") -> MediaCandidate {
        MediaCandidate(url: base.appendingPathComponent(path),
            pageURL: base, frameURL: base, title: "Generated separate HLS tracks", kind: .hls,
            source: "test-fixture", mimeType: "application/vnd.apple.mpegurl")
    }

    private func mediaFiles(_ manager: DownloadManager) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: manager.rootDirectory.appendingPathComponent("Media").path).sorted()
    }

    private func completedRecord(_ manager: DownloadManager, id: UUID) async throws -> DownloadRecord {
        try await waitUntil("Portable download did not reach a terminal state", timeout: 60) {
            guard let record = manager.records.first(where: { $0.id == id }) else { return false }
            return [.complete, .failed, .cancelled].contains(record.phase)
        }
        let record = try XCTUnwrap(manager.records.first { $0.id == id })
        guard record.phase == .complete else {
            XCTFail("Portable transfer ended as \(record.phase.rawValue): \(record.failure ?? "no diagnostic")")
            throw FixtureFailure.transferFailed
        }
        return record
    }

    private func waitUntil(_ message: String, timeout: TimeInterval, predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard predicate() else { XCTFail(message); throw FixtureFailure.timeout }
    }

    private func setOffline(_ value: Bool) async throws {
        var request = URLRequest(url: base.appendingPathComponent("__control"))
        request.httpMethod = "POST"
        request.httpBody = Data("{\"offline\":\(value)}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private enum FixtureFailure: Error { case notReady, transferFailed, timeout }
}
