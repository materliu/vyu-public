import AVFoundation
import CryptoKit
import UIKit
import XCTest
@testable import VYu

/// Uses generated fixtures only. A present server with a failing transfer is a test failure.
@MainActor final class StreamingIntegrationTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8765")!
    private var managers: [DownloadManager] = []
    private var fixtureReady = false

    override func setUp() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(from: base.appendingPathComponent("__health")) }
        catch let error as URLError where error.code == .cannotConnectToHost {
            throw XCTSkip("Start fixtures/server.py on 127.0.0.1:8765 to run streaming integration tests.")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let health = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              health["ready"] as? Bool == true else {
            XCTFail("Fixture server is reachable but its generated media is not ready.")
            throw StreamingTestFailure.fixtureNotReady
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

    func testHLSMasterDownloadsCompleteAssetAndPlaysOffline() async throws {
        try await verifyHLS(path: "media/hls/master.m3u8", separateAudio: false)
    }

    func testHLSSeparateAudioDownloadsCompleteAssetAndPlaysOffline() async throws {
        try await verifyHLS(path: "media/hls-separate/master.m3u8", separateAudio: true)
    }

    func testHLSRejectedAlternativeStillDownloadsCompleteAvailableRenditionOffline() async throws {
        try await verifyHLS(path: "media/hls-failures/partial.m3u8", separateAudio: false, expectedVariants: 1)
    }

    func testHLSForbiddenMainAllVariantsAndAudioStayUndownloadable() async throws {
        let manager = makeManager()
        for (path, stage) in [("main-denied.m3u8", "主清单"), ("all-denied.m3u8", "画质清单"), ("audio-denied.m3u8", "音轨清单")] {
            let source = candidate("media/hls-failures/" + path, kind: .hls)
            let inspection = await manager.inspect(candidate: source, cookies: [])
            XCTAssertFalse(inspection.downloadable, path)
            XCTAssertTrue(inspection.summary.contains(stage), inspection.summary)
            XCTAssertTrue(inspection.summary.contains("403"), inspection.summary)
            XCTAssertTrue(inspection.variants.isEmpty)
            XCTAssertFalse(inspection.webSessionRetryAllowed, "A playlist is not a downloadable movie file.")
            await manager.start(candidate: source, cookies: [])
            let record = try XCTUnwrap(manager.records.first)
            XCTAssertEqual(record.phase, .failed, path)
            XCTAssertNil(record.localRelativePath)
            XCTAssertNil(manager.localURL(for: record))
        }
    }

    func testSilentFileRetainsDurationAndReportsNoAudio() async throws {
        let inventory = try await fixtureInventory()
        let manager = makeManager()
        let source = candidate("media/silent.mp4", kind: .file)
        let info = await manager.inspect(candidate: source, cookies: [])
        XCTAssertTrue(info.downloadable, info.summary)
        await manager.start(candidate: source, cookies: [])
        let id = try XCTUnwrap(manager.records.first?.id)
        let record = try await completedRecord(manager, id: id)
        XCTAssertEqual(record.duration ?? 0, inventory.duration, accuracy: 0.2)
        XCTAssertEqual(record.hasAudio, false)
        XCTAssertTrue(record.failure?.contains("没有音轨") == true, "No-audio status should remain visible after completion.")
        let local = try XCTUnwrap(manager.localURL(for: record))
        try assertHash(local, matches: inventory, file: "silent.mp4")
        let asset = AVURLAsset(url: local)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertTrue(audio.isEmpty)
        XCTAssertFalse(video.isEmpty)
    }

    func testFileThumbnailIsGeneratedOfflinePersistsAndIsRemovedWithCache() async throws {
        let manager = makeManager()
        let source = candidate("media/direct.mp4", kind: .file)
        await manager.start(candidate: source, cookies: [])
        let id = try XCTUnwrap(manager.records.first?.id)
        let record = try await completedRecord(manager, id: id)
        manager.thumbnailStore.remove(id: id)

        try await setOffline(true)
        let (_, response) = try await URLSession.shared.data(from: source.url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        let image = await manager.thumbnailStore.image(for: record, localURL: manager.localURL(for: record))
        try assertThumbnail(image)
        let files = try thumbnailFiles(in: manager.rootDirectory)
        XCTAssertEqual(files.count, 1, "One completed video should persist one preview image.")
        let file = try XCTUnwrap(files.first)
        let savedData = try Data(contentsOf: file)
        try assertThumbnail(UIImage(data: savedData))
        let savedDate = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: savedDate], ofItemAtPath: file.path)
        let writtenDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        XCTAssertEqual(writtenDate, savedDate, "The test must set its cache timestamp before checking reuse.")

        let restored = DownloadManager(rootDirectory: manager.rootDirectory, preferPortableHLS: false)
        managers.append(restored)
        let restoredRecord = try XCTUnwrap(restored.records.first { $0.id == id })
        XCTAssertEqual(restoredRecord.phase, .complete)
        let restoredImage = await restored.thumbnailStore.image(for: restoredRecord, localURL: restored.localURL(for: restoredRecord))
        try assertThumbnail(restoredImage)
        XCTAssertEqual(try thumbnailFiles(in: restored.rootDirectory), files)
        XCTAssertEqual(try Data(contentsOf: file), savedData)
        let restoredDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        XCTAssertEqual(restoredDate, writtenDate,
                       "Opening the library again should reuse its preview without rewriting it.")

        restored.removeCache(id: id)
        XCTAssertTrue(try thumbnailFiles(in: restored.rootDirectory).isEmpty)
        let removedRecord = try XCTUnwrap(restored.records.first { $0.id == id })
        XCTAssertNil(restored.localURL(for: removedRecord))
        let removedImage = await restored.thumbnailStore.image(for: removedRecord, localURL: restored.localURL(for: removedRecord))
        XCTAssertNil(removedImage)
        XCTAssertTrue(try thumbnailFiles(in: restored.rootDirectory).isEmpty,
                      "A removed video must not regenerate a stale preview.")
    }

    func testPauseThenImmediateResumeProducesCompleteMatchingFile() async throws {
        let inventory = try await fixtureInventory()
        let manager = makeManager()
        await manager.start(candidate: candidate("slow.mp4", kind: .file), cookies: [])
        let id = try XCTUnwrap(manager.records.first?.id)
        try await waitForBytes(manager, id: id)
        manager.pause(id: id)
        XCTAssertEqual(manager.records.first?.phase, .paused)
        // Deliberately do not wait for cancel(byProducingResumeData:) to return.
        manager.resume(id: id)
        let record = try await completedRecord(manager, id: id)
        XCTAssertEqual(manager.records.count, 1)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.duration ?? 0, inventory.duration, accuracy: 0.2)
        XCTAssertEqual(record.hasAudio, true)
        try assertHash(try XCTUnwrap(manager.localURL(for: record)), matches: inventory, file: "direct.mp4")
    }

    func testCancelThenRetryIgnoresPriorAttemptCallbacks() async throws {
        let inventory = try await fixtureInventory()
        let manager = makeManager()
        await manager.start(candidate: candidate("slow.mp4", kind: .file), cookies: [])
        let id = try XCTUnwrap(manager.records.first?.id)
        try await waitForBytes(manager, id: id)
        manager.cancel(id: id)
        XCTAssertEqual(manager.records.first?.phase, .cancelled)
        XCTAssertNil(manager.records.first?.localRelativePath)
        await manager.retry(id: id, cookies: [])
        let record = try await completedRecord(manager, id: id)
        XCTAssertEqual(manager.records.count, 1)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.duration ?? 0, inventory.duration, accuracy: 0.2)
        XCTAssertEqual(record.hasAudio, true)
        try assertHash(try XCTUnwrap(manager.localURL(for: record)), matches: inventory, file: "direct.mp4")
    }

    private func verifyHLS(path: String, separateAudio: Bool, expectedVariants: Int = 2) async throws {
        let inventory = try await fixtureInventory()
        let manager = makeManager()
        let source = candidate(path, kind: .hls)
        let inspection = await manager.inspect(candidate: source, cookies: [])
        addDiagnostic("HLS inspection", inspection.summary)
        XCTAssertTrue(inspection.downloadable, inspection.summary)
        XCTAssertEqual(inspection.expectedDuration ?? 0, inventory.duration, accuracy: 0.25)
        if separateAudio { XCTAssertFalse(inspection.audioTracks.isEmpty) }
        else {
            XCTAssertEqual(inspection.variants.count, expectedVariants)
            if expectedVariants == 1 {
                XCTAssertEqual(inspection.variants.first?.url, base.appendingPathComponent("media/hls/180p/index.m3u8"))
                XCTAssertEqual(inspection.hlsDownloadURL, inspection.variants.first?.url,
                               "The downloader must use the inspected rendition, not the rejected master alternatives.")
            }
        }
        await manager.start(candidate: source, cookies: [])
        let id = try XCTUnwrap(manager.records.first?.id)
        let record = try await completedRecord(manager, id: id, timeout: 60)
        XCTAssertEqual(record.duration ?? 0, inventory.duration, accuracy: 0.25)
        XCTAssertEqual(record.hasAudio, true)
        let local = try XCTUnwrap(manager.localURL(for: record))
        XCTAssertTrue(local.isFileURL)
        XCTAssertEqual(local.pathExtension, "movpkg", "A playlist text file is not an offline HLS asset.")
        manager.thumbnailStore.remove(id: id)

        try await setOffline(true)
        let (_, response) = try await URLSession.shared.data(from: source.url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        let image = await manager.thumbnailStore.image(for: record, localURL: local)
        try assertThumbnail(image)
        let thumbnail = try XCTUnwrap(try thumbnailFiles(in: manager.rootDirectory).first)
        try assertThumbnail(UIImage(data: Data(contentsOf: thumbnail)))
        let asset = AVURLAsset(url: local, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidLocalReferenceToRemote.rawValue
        ])
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, inventory.duration, accuracy: 0.25)
        XCTAssertTrue(asset.assetCache?.isPlayableOffline == true)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        try await waitUntil("Offline HLS player item did not become ready", timeout: 15) {
            item.status == .readyToPlay || item.status == .failed
        }
        guard item.status == .readyToPlay else {
            XCTFail(item.error?.localizedDescription ?? "Offline HLS player item failed before playback.")
            throw StreamingTestFailure.transferFailed
        }
        player.play()
        try await waitUntil("Offline HLS playback did not advance: \(player.currentItem?.error?.localizedDescription ?? "no player error")", timeout: 15) {
            player.currentTime().seconds > 1.2 || player.currentItem?.status == .failed
        }
        XCTAssertNotEqual(player.currentItem?.status, .failed, player.currentItem?.error?.localizedDescription ?? "")
        XCTAssertGreaterThan(player.currentTime().seconds, 1.2)
        // An offline HLS package can expose no static AVURLAsset tracks. Inspect
        // the selected, enabled tracks after the player has prepared and played it.
        XCTAssertTrue(item.tracks.contains { $0.isEnabled && $0.assetTrack?.mediaType == .audio },
                      "Prepared offline HLS playback must include an enabled audio track.")
        XCTAssertTrue(item.tracks.contains { $0.isEnabled && $0.assetTrack?.mediaType == .video },
                      "Prepared offline HLS playback must include an enabled video track.")
        addDiagnostic("Prepared offline HLS tracks", item.tracks.map {
            "\($0.assetTrack?.mediaType.rawValue ?? "unknown"): enabled=\($0.isEnabled)"
        }.joined(separator: "\n"))
        // Also check near the end so a cached first segment cannot satisfy the test.
        let seekSucceeded = await player.seek(to: CMTime(seconds: 6.2, preferredTimescale: 600),
                                              toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(seekSucceeded)
        player.play()
        try await waitUntil("Offline HLS playback did not reach the final segment", timeout: 15) {
            player.currentTime().seconds > 7.2 || player.currentItem?.status == .failed
        }
        XCTAssertNotEqual(player.currentItem?.status, .failed, player.currentItem?.error?.localizedDescription ?? "")
        XCTAssertGreaterThan(player.currentTime().seconds, 7.2)
        try await setOffline(false)
    }

    private func makeManager() -> DownloadManager {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-streaming-" + UUID().uuidString)
        let manager = DownloadManager(rootDirectory: directory, preferPortableHLS: false)
        managers.append(manager)
        return manager
    }

    private func thumbnailFiles(in root: URL) throws -> [URL] {
        let directory = root.appendingPathComponent("Thumbnails", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
            .sorted { $0.path < $1.path }
    }

    private func assertThumbnail(_ image: UIImage?, file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(image, "The completed local video should produce a preview while its origin is unavailable.", file: file, line: line)
        let pixels = try XCTUnwrap(image.cgImage, "The preview must be a decoded image.", file: file, line: line)
        XCTAssertGreaterThan(pixels.width, 0, file: file, line: line)
        XCTAssertGreaterThan(pixels.height, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(pixels.width, 480, file: file, line: line)
        XCTAssertLessThanOrEqual(pixels.height, 270, file: file, line: line)
    }

    private func candidate(_ path: String, kind: MediaKind) -> MediaCandidate {
        MediaCandidate(url: base.appendingPathComponent(path), pageURL: base, frameURL: base,
                       title: "Generated fixture", kind: kind, source: "test-fixture",
                       mimeType: kind == .hls ? "application/vnd.apple.mpegurl" : "video/mp4")
    }

    private func completedRecord(_ manager: DownloadManager, id: UUID, timeout: TimeInterval = 60) async throws -> DownloadRecord {
        do {
            try await waitUntil("Download did not reach a terminal state within \(Int(timeout)) seconds", timeout: timeout) {
                guard let record = manager.records.first(where: { $0.id == id }) else { return false }
                return [.complete, .failed, .cancelled].contains(record.phase)
            }
        } catch {
            if let record = manager.records.first(where: { $0.id == id }) { addRecord(record) }
            throw error
        }
        let record = try XCTUnwrap(manager.records.first(where: { $0.id == id }))
        addRecord(record)
        guard record.phase == .complete else {
            XCTFail("Transfer ended as \(record.phase.rawValue): \(record.failure ?? "no diagnostic"). This is not an offline-playback pass.")
            throw StreamingTestFailure.transferFailed
        }
        return record
    }

    private func waitForBytes(_ manager: DownloadManager, id: UUID) async throws {
        try await waitUntil("Slow download did not receive initial bytes", timeout: 20) {
            guard let record = manager.records.first(where: { $0.id == id }) else { return false }
            return (record.bytesWritten >= 32_768 && record.phase == .downloading) || record.phase == .failed
        }
        let record = try XCTUnwrap(manager.records.first(where: { $0.id == id }))
        guard record.phase == .downloading else {
            addRecord(record)
            XCTFail(record.failure ?? "Slow transfer failed before pause or cancellation.")
            throw StreamingTestFailure.transferFailed
        }
    }

    private func waitUntil(_ message: String, timeout: TimeInterval, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard predicate() else { XCTFail(message); throw StreamingTestFailure.timeout }
    }

    private func setOffline(_ value: Bool) async throws {
        var request = URLRequest(url: base.appendingPathComponent("__control"))
        request.httpMethod = "POST"
        request.httpBody = Data("{\"offline\":\(value)}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private struct FixtureInventory: Decodable {
        struct File: Decodable { let path: String; let sha256: String }
        let duration: Double
        let files: [File]
        enum CodingKeys: String, CodingKey { case duration = "duration_seconds", files }
    }

    private func fixtureInventory() async throws -> FixtureInventory {
        let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("media/inventory.json"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(FixtureInventory.self, from: data)
    }

    private func assertHash(_ url: URL, matches inventory: FixtureInventory, file: String) throws {
        let expected = try XCTUnwrap(inventory.files.first(where: { $0.path == file })?.sha256)
        let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, expected, "The completed file must match the full generated fixture, including after resume or retry.")
    }

    private func addRecord(_ record: DownloadRecord) {
        let value = (try? JSONEncoder().encode(record)).flatMap { String(data: $0, encoding: .utf8) } ?? record.phase.rawValue
        addDiagnostic("Download record", value)
    }

    private func addDiagnostic(_ name: String, _ value: String) {
        let attachment = XCTAttachment(string: value)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private enum StreamingTestFailure: Error { case fixtureNotReady, transferFailed, timeout }
}
