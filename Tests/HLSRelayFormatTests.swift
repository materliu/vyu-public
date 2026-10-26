import AVFoundation
import XCTest
@testable import VYu

/// End-to-end format coverage uses only locally generated eight-second media.
@MainActor final class HLSRelayFormatTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8765")!
    private var managers: [DownloadManager] = []
    private var fixtureReady = false

    override func setUp() async throws {
        continueAfterFailure = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let result: (Data, URLResponse)
        do { result = try await session.data(from: base.appendingPathComponent("__health")) }
        catch let error as URLError where error.code == .cannotConnectToHost {
            throw XCTSkip("Generate media and start fixtures/server.py before running relay format tests.")
        }
        let health = try XCTUnwrap(JSONSerialization.jsonObject(with: result.0) as? [String: Any])
        XCTAssertEqual((result.1 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(health["ready"] as? Bool, true)
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

    func testRelayPreservesSeparateAudioAndPlaysEntireAssetWithOriginOffline() async throws {
        try await verifyFormat(path: "media/hls-separate/master.m3u8", separateAudio: true)
    }

    func testRelayPreservesFMP4InitializationAndByteRangesWithOriginOffline() async throws {
        let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("media/hls-fmp4/index.m3u8"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("#EXT-X-MAP:"), "The fixture must include a real fMP4 initialization reference.")
        XCTAssertTrue(text.contains("BYTERANGE=\""), "The initialization must use a range in the shared MP4.")
        XCTAssertTrue(text.contains("#EXT-X-BYTERANGE:"), "Media segments must exercise the relay's Range/206 path.")
        XCTAssertTrue(text.contains("stream.mp4"))
        try await verifyFormat(path: "media/hls-fmp4/index.m3u8", separateAudio: false)
    }

    func testRelayPreservesSeparateFMP4AudioGroupsAndInitializationWithOriginOffline() async throws {
        let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("media/hls-fmp4-separate/master.m3u8"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(text.components(separatedBy: "#EXT-X-MEDIA:").count - 1, 3)
        XCTAssertTrue(text.contains("CODECS=\"avc1.4d401e\""))
        XCTAssertTrue(text.contains("AUDIO=\"audio-128000\""))
        try await verifyFormat(path: "media/hls-fmp4-separate/master.m3u8", separateAudio: true)
    }

    func testFMP4InitializationFileIsRejectedAfterTransfer() async throws {
        let source = MediaCandidate(url: base.appendingPathComponent("media/hls-fmp4-separate/video/180p/init.mp4"),
            pageURL: base.appendingPathComponent("hls-format-fixture"), frameURL: base.appendingPathComponent("hls-format-fixture"),
            title: "Synthetic initialization file", kind: .file, source: "performance", mimeType: "video/mp4")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-init-fragment-" + UUID().uuidString)
        let manager = DownloadManager(rootDirectory: root, preferPortableHLS: false)
        managers.append(manager)
        await manager.start(candidate: source, cookies: [])
        try await waitUntil("Initialization file transfer terminates", timeout: 30) {
            guard let record = manager.records.first else { return false }
            return [.complete, .failed, .cancelled].contains(record.phase)
        }
        let record = try XCTUnwrap(manager.records.first)
        XCTAssertGreaterThan(record.bytesWritten, 0)
        XCTAssertEqual(record.phase, .failed)
        XCTAssertNil(manager.localURL(for: record))
    }

    private func verifyFormat(path: String, separateAudio: Bool) async throws {
        let source = MediaCandidate(url: base.appendingPathComponent(path), pageURL: base.appendingPathComponent("hls-format-fixture"),
            frameURL: base.appendingPathComponent("hls-format-fixture"), title: "Synthetic relay format fixture",
            kind: .hls, source: "test-fixture", mimeType: "application/vnd.apple.mpegurl",
            requestContext: MediaRequestContext(corsMode: .none, referrerPolicy: .strictOriginWhenCrossOrigin))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-relay-format-" + UUID().uuidString)
        let manager = DownloadManager(rootDirectory: root, preferPortableHLS: false)
        managers.append(manager)
        let inspection = await manager.inspect(candidate: source, cookies: [])
        XCTAssertTrue(inspection.downloadable, inspection.summary)
        XCTAssertTrue(inspection.requiresForeground, "A candidate with request context must use the foreground HLS relay.")
        XCTAssertEqual(inspection.expectedDuration ?? 0, 8, accuracy: 0.25)
        if separateAudio {
            XCTAssertFalse(inspection.audioTracks.isEmpty)
            XCTAssertEqual(inspection.hlsDownloadURL, source.url, "The master is needed to preserve its external audio group.")
        }
        await manager.start(candidate: source, cookies: [])
        try await waitUntil("Relay format transfer reaches a terminal state", timeout: 75) {
            guard let record = manager.records.first else { return false }
            return [.complete, .failed, .cancelled].contains(record.phase)
        }
        let record = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(record.phase, .complete, record.failure ?? "No safe failure detail")
        XCTAssertEqual(record.duration ?? 0, 8, accuracy: 0.25)
        XCTAssertEqual(record.hasAudio, true)
        let local = try XCTUnwrap(manager.localURL(for: record))
        XCTAssertTrue(local.isFileURL)
        XCTAssertEqual(local.pathExtension, "movpkg")

        try await setOffline(true)
        let (_, unavailable) = try await URLSession.shared.data(from: source.url)
        XCTAssertEqual((unavailable as? HTTPURLResponse)?.statusCode, 503)
        let asset = AVURLAsset(url: local, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidLocalReferenceToRemote.rawValue
        ])
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 8, accuracy: 0.25)
        XCTAssertTrue(asset.assetCache?.isPlayableOffline == true)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        try await waitUntil("Offline format player prepares", timeout: 15) {
            item.status == .readyToPlay || item.status == .failed
        }
        XCTAssertEqual(item.status, .readyToPlay, "Offline format player failed to prepare.")
        player.play()
        try await waitUntil("Offline playback advances past the first second", timeout: 15) {
            player.currentTime().seconds > 1.2 || item.status == .failed
        }
        XCTAssertNotEqual(item.status, .failed)
        XCTAssertGreaterThan(player.currentTime().seconds, 1.2)
        XCTAssertTrue(item.tracks.contains { $0.isEnabled && $0.assetTrack?.mediaType == .audio }, "Offline playback must retain the audio track.")
        XCTAssertTrue(item.tracks.contains { $0.isEnabled && $0.assetTrack?.mediaType == .video }, "Offline playback must retain the video track.")
        let seekSucceeded = await player.seek(to: CMTime(seconds: 6.2, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(seekSucceeded)
        player.play()
        try await waitUntil("Offline playback reaches the last segment", timeout: 15) {
            player.currentTime().seconds > 7.2 || item.status == .failed
        }
        XCTAssertNotEqual(item.status, .failed)
        XCTAssertGreaterThan(player.currentTime().seconds, 7.2)
        XCTAssertTrue(item.tracks.contains { $0.isEnabled && $0.assetTrack?.mediaType == .audio })
        XCTAssertTrue(item.tracks.contains { $0.isEnabled && $0.assetTrack?.mediaType == .video })
    }

    private func setOffline(_ value: Bool) async throws {
        var request = URLRequest(url: base.appendingPathComponent("__control"))
        request.httpMethod = "POST"
        request.httpBody = Data("{\"offline\":\(value)}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func waitUntil(_ reason: String, timeout: TimeInterval, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard predicate() else { XCTFail(reason); throw URLError(.timedOut) }
    }
}
