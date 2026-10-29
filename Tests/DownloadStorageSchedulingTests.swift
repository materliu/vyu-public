import Combine
import CryptoKit
import Foundation
import XCTest
@testable import VYu

/// Uses only disposable libraries, a local cloud stand-in, and generated loopback media.
/// These tests exercise the production automatic subscriptions, not manual maintain() calls.
@MainActor final class DownloadStorageSchedulingTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8765")!
    private var roots: [URL] = []
    private var managers: [DownloadManager] = []
    private var clouds: [CloudVideoSync] = []
    private var optimizers: [VideoStorageOptimizer] = []
    private var fixture = Data()

    override func setUp() async throws {
        continueAfterFailure = false
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(from: base.appendingPathComponent("__health")) }
        catch let error as URLError where error.code == .cannotConnectToHost {
            throw XCTSkip("Generate fixtures and start the loopback fixture server before running storage scheduling tests.")
        }
        let health = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(health["ready"] as? Bool, true)
        var control = URLRequest(url: base.appendingPathComponent("__control"))
        control.httpMethod = "POST"
        control.httpBody = Data("{\"offline\":false}".utf8)
        control.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, controlResponse) = try await session.data(for: control)
        XCTAssertEqual((controlResponse as? HTTPURLResponse)?.statusCode, 200)
        let (media, mediaResponse) = try await session.data(from: base.appendingPathComponent("media/direct.mp4"))
        XCTAssertEqual((mediaResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertGreaterThan(media.count, 128 * 1_024, "The slow fixture must outlast the progress observation window.")
        fixture = media
    }

    override func tearDown() async throws {
        for optimizer in optimizers { optimizer.setAppActive(false) }
        for cloud in clouds { cloud.setAppActive(false) }
        for manager in managers { manager.pauseDownloads(ids: Set(manager.records.map(\.id))) }
        try await Task.sleep(for: .milliseconds(700))
        for cloud in clouds { await cloud.synchronize() }
        for manager in managers {
            for id in manager.records.map(\.id) { manager.removeRecord(id: id) }
        }
        optimizers = []; clouds = []; managers = []
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []; fixture = Data()
    }

    func testProgressOnlyUpdatesDoNotRepeatStorageScansWithOptimizationDisabled() async throws {
        try await exerciseProgressScheduling(enabled: false)
    }

    func testRestoredDownloadWithStorageOptimizationKeepsMainActorResponsiveAndProtectsInUseMedia() async throws {
        try await exerciseProgressScheduling(enabled: true)
    }

    func testColdRestoredHLSAndEnabledStorageFinishWithoutBlockingOrEvictingProtectedMedia() async throws {
        struct ExpectedMedia: Codable {
            let duration: Double?
            let requiresAudio: Bool
        }
        struct SeedArchive: Encodable {
            let records: [DownloadRecord]
            let authenticated: Set<UUID>
            let expectations: [UUID: ExpectedMedia]
            let attempts: [UUID: String]
            let foregroundHLS: Set<UUID>
        }
        let source = MediaCandidate(url: base.appendingPathComponent("background-hls-media/master.m3u8"),
            pageURL: base, frameURL: base, title: "后台恢复与存储优化合成测试", kind: .hls, source: "fixture")
        let inspection = MediaInspection(summary: "", variants: [], audioTracks: ["audio"], expectedBytes: nil,
            downloadable: true, expectedDuration: 8)
        let plan = try await HLSFileExporter.prepare(candidate: source, inspection: inspection)
        XCTAssertTrue(plan.requiresAudio)
        XCTAssertGreaterThan(plan.resources.count, 2)
        XCTAssertTrue(plan.resources.allSatisfy {
            $0.url.scheme == "http" && $0.url.host == "127.0.0.1" && $0.url.port == 8765
        }, "Every recovered request must remain on the generated loopback fixture service.")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-startup-hls-storage-" + UUID().uuidString)
        roots.append(root)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let protectedURL = media.appendingPathComponent("protected-fixture.mp4")
        try fixture.write(to: protectedURL)
        let protectedRecord = DownloadRecord(id: UUID(), candidate: candidate(path: "media/direct.mp4?storage=hls-existing"),
            phase: .complete, progress: 1, bytesWritten: Int64(fixture.count), expectedBytes: Int64(fixture.count),
            localRelativePath: "Media/protected-fixture.mp4", failure: nil, duration: 8, hasAudio: true, createdAt: Date())
        let hlsID = UUID()
        let attempt = hlsID.uuidString + "|" + UUID().uuidString
        let hlsRecord = DownloadRecord(id: hlsID, candidate: source, phase: .downloading, progress: 0,
            bytesWritten: 0, expectedBytes: nil, localRelativePath: nil, failure: nil, duration: nil,
            hasAudio: nil, createdAt: Date())
        let archive = SeedArchive(records: [protectedRecord, hlsRecord], authenticated: [],
            expectations: [hlsID: ExpectedMedia(duration: 8, requiresAudio: true)], attempts: [hlsID: attempt], foregroundHLS: [])
        try JSONEncoder().encode(archive).write(to: root.appendingPathComponent("downloads.json"))
        let jobDirectory = root.appendingPathComponent("BackgroundHLS/" + hlsID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
        let job = BackgroundHLSStore.Job(id: hlsID, attempt: attempt, plan: plan, userAgent: nil)
        XCTAssertFalse(job.paused)
        XCTAssertTrue(job.receipts.isEmpty)
        try JSONEncoder().encode(job).write(to: jobDirectory.appendingPathComponent("job.json"))

        let heartbeat = StorageSchedulingHeartbeat()
        heartbeat.start()
        defer { heartbeat.stop() }
        // This is the production manager's cold recovery path. No pre-existing
        // manager or bare HLS store can supply in-memory task/receipt state.
        let manager = DownloadManager(rootDirectory: root, initiallyInBackground: true)
        managers.append(manager)
        let protectedLease = manager.beginUsingLocalVideo(id: protectedRecord.id)
        let recoveryLease = manager.beginUsingLocalVideo(id: hlsID)
        defer {
            manager.endUsingLocalVideo(protectedLease)
            manager.endUsingLocalVideo(recoveryLease)
        }
        let metadata = VideoMetadataStore(rootDirectory: root)
        let cloud = CloudVideoSync(downloads: manager, metadataStore: metadata,
            containerOverride: root.appendingPathComponent("FixtureCloud", isDirectory: true))
        clouds.append(cloud)
        let optimizer = VideoStorageOptimizer(downloads: manager, cloud: cloud, metadataStore: metadata, budgetBytes: 1)
        optimizers.append(optimizer)
        let meter = StorageMaintenanceMeter(optimizer)
        try optimizer.setEnabled(true)
        await cloud.refreshAccount()
        XCTAssertTrue(cloud.isAvailable)
        XCTAssertEqual(cloud.entry(for: protectedRecord.id)?.uploaded, true)
        XCTAssertFalse(manager.transferNeedsForeground(id: hlsID))
        try await waitUntil("cold-recovered HLS receipts become complete in the background", timeout: 45) {
            manager.backgroundTransferStatus(id: hlsID) != nil
        }
        let pending = try XCTUnwrap(manager.records.first { $0.id == hlsID })
        XCTAssertEqual(pending.phase, .validating)
        XCTAssertNil(pending.localRelativePath)
        XCTAssertGreaterThan(pending.bytesWritten, 0)
        XCTAssertFalse(manager.canEvictLocalCache(pending))
        let durableJob = try JSONDecoder().decode(BackgroundHLSStore.Job.self,
            from: Data(contentsOf: jobDirectory.appendingPathComponent("job.json")))
        XCTAssertEqual(durableJob.id, hlsID)
        XCTAssertEqual(durableJob.attempt, attempt)
        XCTAssertTrue(durableJob.ready)
        XCTAssertEqual(durableJob.receipts.count, plan.resources.count)
        let validReceipts = try await Task.detached(priority: .utility) {
            for index in plan.resources.indices {
                guard let receipt = durableJob.receipts[index] else { return false }
                let bytes = try Data(contentsOf: jobDirectory.appendingPathComponent("\(index).part"))
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                guard Int64(bytes.count) == receipt.bytes, digest == receipt.digest else { return false }
            }
            return true
        }.value
        XCTAssertTrue(validReceipts, "Storage optimization must not reclaim or corrupt active HLS resources.")
        XCTAssertEqual(try Data(contentsOf: protectedURL), fixture)
        try await waitForQuietMaintenance(meter, optimizer: optimizer)
        let beforeAssemblyPasses = meter.starts

        manager.setAppInBackground(false)
        try await waitUntil("foreground assembly produces a fully validated movie", timeout: 45) {
            manager.records.first(where: { $0.id == hlsID })?.phase == .complete
        }
        let completed = try XCTUnwrap(manager.records.first { $0.id == hlsID })
        XCTAssertEqual(completed.id, hlsID)
        XCTAssertEqual(completed.duration ?? 0, 8, accuracy: 0.25)
        XCTAssertEqual(completed.hasAudio, true)
        let completedURL = try XCTUnwrap(manager.localURL(for: completed))
        XCTAssertEqual(completedURL.pathExtension, "mp4")
        let completedBytes = try XCTUnwrap((FileManager.default.attributesOfItem(atPath: completedURL.path)[.size]) as? NSNumber).int64Value
        XCTAssertEqual(completed.bytesWritten, completedBytes)
        try await waitUntil("assembled media path and completion trigger storage accounting", timeout: 15) {
            meter.starts > beforeAssemblyPasses && !optimizer.isMaintaining &&
                optimizer.localVideoBytes >= Int64(self.fixture.count) + completedBytes
        }
        XCTAssertEqual(Set(manager.records.map(\.id)), Set([protectedRecord.id, hlsID]))
        XCTAssertTrue(manager.records.allSatisfy { $0.phase == .complete && $0.localCacheEvicted != true })
        XCTAssertEqual(try Data(contentsOf: protectedURL), fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: jobDirectory.path),
                       "Only the successfully exported fixture resource directory should be retired.")
        XCTAssertGreaterThan(meter.starts, 0)
        XCTAssertGreaterThan(heartbeat.samples, 20)
        XCTAssertLessThan(heartbeat.maximumGap, 1.0)
        let metrics = XCTAttachment(string: "coldRestoredResources=\(durableJob.receipts.count)\n" +
            "storageOptimizationEnabled=true\nmaintenancePasses=\(meter.starts)\n" +
            "heartbeatSamples=\(heartbeat.samples)\nmaximumMainActorGap=\(heartbeat.maximumGap)")
        metrics.name = "Cold HLS restoration with automatic storage optimization"
        metrics.lifetime = .keepAlways
        add(metrics)
    }

    private func exerciseProgressScheduling(enabled: Bool) async throws {
        let heartbeat = StorageSchedulingHeartbeat()
        heartbeat.start()
        defer { heartbeat.stop() }
        let (manager, cloud, optimizer, slowID, protectedRecord, protectedURL) = try await restoredLibrary(enabled: enabled)
        let meter = StorageMaintenanceMeter(optimizer)
        let protectedLease = manager.beginUsingLocalVideo(id: protectedRecord.id)
        defer { manager.endUsingLocalVideo(protectedLease) }
        // An enabled 1-byte budget cannot evict a video currently in use.
        if enabled { try optimizer.setEnabled(true) }
        optimizer.setAppActive(true)
        try await waitUntil("initial storage pass", timeout: 15) { meter.starts > 0 && !optimizer.isMaintaining }
        try await waitForQuietMaintenance(meter, optimizer: optimizer)
        XCTAssertEqual(optimizer.isEnabled, enabled)
        XCTAssertTrue(cloud.isAvailable)
        XCTAssertEqual(try Data(contentsOf: protectedURL), fixture)

        let initialPasses = meter.starts
        let protectedMediaUsage = optimizer.localVideoBytes
        XCTAssertGreaterThanOrEqual(protectedMediaUsage, Int64(fixture.count))
        manager.resume(id: slowID)
        try await waitUntil("persisted paused download becomes active", timeout: 20) {
            manager.records.first(where: { $0.id == slowID })?.phase == .downloading && manager.hasActiveDownloads
        }
        try await waitUntil("phase change schedules maintenance", timeout: 10) { meter.starts > initialPasses }
        try await waitUntil("first real download bytes", timeout: 15) {
            (manager.records.first(where: { $0.id == slowID })?.bytesWritten ?? 0) > 0
        }
        try await waitForQuietMaintenance(meter, optimizer: optimizer)
        let progressBaseline = meter.starts
        let priorBytes = try XCTUnwrap(manager.records.first(where: { $0.id == slowID })).bytesWritten
        var lastBytes = priorBytes
        var distinctProgressUpdates = 0
        let observation = manager.$records.sink { records in
            guard let record = records.first(where: { $0.id == slowID }), record.phase == .downloading,
                  record.bytesWritten > lastBytes else { return }
            lastBytes = record.bytesWritten
            distinctProgressUpdates += 1
        }
        defer { observation.cancel() }
        try await waitUntil("three separate loopback progress updates", timeout: 15) { distinctProgressUpdates >= 3 }
        // The fixture emits a chunk every two seconds, leaving ample time for a
        // wrongly scheduled 400 ms storage pass to start between progress events.
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertEqual(try XCTUnwrap(manager.records.first(where: { $0.id == slowID })).phase, .downloading)
        XCTAssertGreaterThan(lastBytes, priorBytes)
        let progressOnlyPasses = meter.starts - progressBaseline
        XCTAssertEqual(progressOnlyPasses, 0,
                       "Only byte/progress fields changed; rescanning the same media set is unnecessary.")
        XCTAssertFalse(manager.canEvictLocalCache(try XCTUnwrap(manager.records.first(where: { $0.id == slowID }))))
        XCTAssertEqual(try Data(contentsOf: protectedURL), fixture)
        XCTAssertNotEqual(manager.records.first(where: { $0.id == protectedRecord.id })?.localCacheEvicted, true)

        let beforePause = meter.starts
        manager.pause(id: slowID)
        try await waitUntil("pause remains a storage-relevant state transition", timeout: 10) {
            meter.starts > beforePause && !optimizer.isMaintaining
        }
        XCTAssertEqual(try XCTUnwrap(manager.records.first(where: { $0.id == slowID })).phase, .paused)
        XCTAssertEqual(try Data(contentsOf: protectedURL), fixture)
        try await waitForQuietMaintenance(meter, optimizer: optimizer)

        // A completed file must still be counted even after progress-only changes
        // are deduplicated. A lease prevents a tiny-budget pass from removing it.
        var completedAtPass: Int?
        var directID: UUID?
        let completionObservation = manager.$records.sink { records in
            guard completedAtPass == nil, let id = directID,
                  records.contains(where: { $0.id == id && $0.phase == .complete }) else { return }
            completedAtPass = meter.starts
        }
        defer { completionObservation.cancel() }
        let completedID = await manager.start(candidate: candidate(path: "media/direct.mp4?storage=completion"), cookies: [])
        directID = completedID
        let completionLease = manager.beginUsingLocalVideo(id: completedID)
        defer { manager.endUsingLocalVideo(completionLease) }
        // Handle completion before the async start call returned, without relying
        // on that timing for the subscription assertion.
        if manager.records.first(where: { $0.id == completedID })?.phase == .complete, completedAtPass == nil {
            completedAtPass = meter.starts
        }
        try await waitUntil("new file completes and triggers storage maintenance", timeout: 30) {
            guard let completedAtPass else { return false }
            return meter.starts > completedAtPass && !optimizer.isMaintaining
        }
        let completed = try XCTUnwrap(manager.records.first { $0.id == completedID })
        XCTAssertEqual(completed.phase, .complete)
        let completedURL = try XCTUnwrap(manager.localURL(for: completed))
        XCTAssertEqual(try Data(contentsOf: completedURL), fixture)
        XCTAssertGreaterThanOrEqual(optimizer.localVideoBytes, Int64(fixture.count * 2))
        try await waitForQuietMaintenance(meter, optimizer: optimizer)

        // Explicit removal affects only this test's extra completed record. Its
        // path disappearing must schedule a new scan and update the displayed bytes.
        manager.endUsingLocalVideo(completionLease)
        let beforeRemoval = meter.starts
        let usageBeforeRemoval = optimizer.localVideoBytes
        XCTAssertGreaterThan(usageBeforeRemoval, protectedMediaUsage)
        manager.removeCache(id: completedID)
        try await waitUntil("removed media path changes storage usage", timeout: 10) {
            meter.starts > beforeRemoval && !optimizer.isMaintaining && optimizer.localVideoBytes == protectedMediaUsage
        }
        XCTAssertLessThan(optimizer.localVideoBytes, usageBeforeRemoval)
        XCTAssertFalse(FileManager.default.fileExists(atPath: completedURL.path))
        XCTAssertNil(manager.localURL(for: try XCTUnwrap(manager.records.first { $0.id == completedID })))
        XCTAssertEqual(try Data(contentsOf: protectedURL), fixture,
                       "An active playback lease must remain protected throughout download recovery and cleanup.")
        XCTAssertGreaterThan(heartbeat.samples, 20)
        XCTAssertLessThan(heartbeat.maximumGap, 1.0,
                          "The main actor must service the heartbeat while restoration, downloads and storage accounting overlap.")
        let metrics = XCTAttachment(string: "optimizationEnabled=\(enabled)\ninitialMaintenancePasses=\(initialPasses)\n" +
            "progressOnlyMaintenancePasses=\(progressOnlyPasses)\ntotalMaintenancePasses=\(meter.starts)\n" +
            "logicalFixtureBytes=\(fixture.count)\nprotectedResidentBytes=\(protectedMediaUsage)\n" +
            "beforeRemovalResidentBytes=\(usageBeforeRemoval)\nafterRemovalResidentBytes=\(optimizer.localVideoBytes)\n" +
            "progressUpdates=\(distinctProgressUpdates)\nheartbeatSamples=\(heartbeat.samples)\nmaximumMainActorGap=\(heartbeat.maximumGap)")
        metrics.name = "Isolated download and storage scheduling"
        metrics.lifetime = .keepAlways
        add(metrics)
    }

    private func restoredLibrary(enabled: Bool) async throws -> (DownloadManager, CloudVideoSync, VideoStorageOptimizer, UUID, DownloadRecord, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-startup-storage-" + UUID().uuidString)
        roots.append(root)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let protectedURL = media.appendingPathComponent("protected-fixture.mp4")
        try fixture.write(to: protectedURL)
        let protectedRecord = DownloadRecord(id: UUID(), candidate: candidate(path: "media/direct.mp4?storage=existing"),
            phase: .complete, progress: 1, bytesWritten: Int64(fixture.count), expectedBytes: Int64(fixture.count),
            localRelativePath: "Media/protected-fixture.mp4", failure: nil, duration: 8, hasAudio: true, createdAt: Date())
        let paused = DownloadRecord(id: UUID(), candidate: candidate(path: "batch-slow.mp4?storage=restored"),
            phase: .paused, progress: 0, bytesWritten: 0, expectedBytes: nil, localRelativePath: nil,
            failure: nil, duration: nil, hasAudio: nil, createdAt: Date())
        try JSONEncoder().encode([protectedRecord, paused]).write(to: root.appendingPathComponent("downloads.json"))
        let manager = DownloadManager(rootDirectory: root)
        managers.append(manager)
        let metadata = VideoMetadataStore(rootDirectory: root)
        let cloud = CloudVideoSync(downloads: manager, metadataStore: metadata,
                                   containerOverride: root.appendingPathComponent("FixtureCloud", isDirectory: true))
        clouds.append(cloud)
        await cloud.refreshAccount()
        XCTAssertEqual(cloud.entry(for: protectedRecord.id)?.uploaded, true)
        let optimizer = VideoStorageOptimizer(downloads: manager, cloud: cloud, metadataStore: metadata,
                                              budgetBytes: enabled ? 1 : 1_000_000_000)
        optimizer.setAppActive(false)
        optimizers.append(optimizer)
        return (manager, cloud, optimizer, paused.id, protectedRecord, protectedURL)
    }

    private func candidate(path: String) -> MediaCandidate {
        MediaCandidate(url: URL(string: path, relativeTo: base.appendingPathComponent("/"))!.absoluteURL,
                       pageURL: base, frameURL: base, title: "存储与恢复合成测试", kind: .file,
                       source: "fixture", mimeType: "video/mp4")
    }

    private func waitForQuietMaintenance(_ meter: StorageMaintenanceMeter, optimizer: VideoStorageOptimizer) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var lastCount = meter.starts
        var stableSince = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime < deadline {
            if optimizer.isMaintaining || meter.starts != lastCount {
                lastCount = meter.starts; stableSince = ProcessInfo.processInfo.systemUptime
            } else if ProcessInfo.processInfo.systemUptime - stableSince >= 0.8 { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("Storage maintenance did not settle between relevant state changes.")
        throw StorageSchedulingFailure.timedOut
    }

    private func waitUntil(_ description: String, timeout: TimeInterval, _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        guard predicate() else { XCTFail(description); throw StorageSchedulingFailure.timedOut }
    }
}

private enum StorageSchedulingFailure: Error { case timedOut }

@MainActor private final class StorageMaintenanceMeter {
    private(set) var starts = 0
    private var observation: AnyCancellable?
    init(_ optimizer: VideoStorageOptimizer) {
        observation = optimizer.$isMaintaining.removeDuplicates().sink { [weak self] active in
            if active { self?.starts += 1 }
        }
    }
}

@MainActor private final class StorageSchedulingHeartbeat {
    private(set) var samples = 0
    private(set) var maximumGap: TimeInterval = 0
    private var task: Task<Void, Never>?
    func start() {
        let initial = ProcessInfo.processInfo.systemUptime
        task = Task { [weak self] in
            var previous = initial
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard let self else { return }
                let current = ProcessInfo.processInfo.systemUptime
                self.maximumGap = max(self.maximumGap, current - previous)
                self.samples += 1
                previous = current
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}
