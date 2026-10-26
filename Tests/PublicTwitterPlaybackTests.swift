import AVFoundation
import AVKit
import XCTest
@testable import VYu

/// Opt-in public media probe. It never reads a user's browsing session or library.
@MainActor final class PublicTwitterPlaybackTests: XCTestCase {
    func testOptInPublicTwitterAssetThroughProductionOfflinePlayer() async throws {
        guard ProcessInfo.processInfo.environment["VYU_PUBLIC_HLS_PROBE"] == "1" else {
            throw XCTSkip("Explicit public-network probe opt-in required.")
        }
        let environment = ProcessInfo.processInfo.environment
        guard environment["VYU_TEST_LIBRARY_ID"].flatMap(UUID.init(uuidString:)) != nil else {
            throw XCTSkip("An isolated host-app library ID is required for the public media probe.")
        }
        let restoreMode = environment["VYU_PUBLIC_RESTORE_PROBE"]
        let probeID = environment["VYU_PUBLIC_PROBE_ID"].flatMap(UUID.init(uuidString:)) ?? UUID()
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VYu-public-player-" + probeID.uuidString)
        let manager = DownloadManager(rootDirectory: root,
            preferPortableHLS: environment["VYU_SYSTEM_HLS_PROBE"] != "1")
        defer {
            if restoreMode != "save" {
                for id in manager.records.map(\.id) { manager.removeRecord(id: id) }
                try? FileManager.default.removeItem(at: root)
            }
        }
        let page = URL(string: "https://x.com/")!
        let source = MediaCandidate(
            url: URL(string: "https://video.twimg.com/amplify_video/2059310686539517955/pl/5Zmh0DCW3Jy5MVuF.m3u8?tag=27")!,
            pageURL: page, frameURL: page, title: "Public Earth-orbit playback probe", kind: .hls,
            source: "public-network-test", mimeType: "application/vnd.apple.mpegurl",
            requestContext: MediaRequestContext(corsMode: .none, referrerPolicy: .strictOriginWhenCrossOrigin))
        if restoreMode == "restore" {
            XCTAssertEqual(manager.records.count, 1, "Restore must load the asset saved by an earlier app process.")
            XCTAssertEqual(manager.records.first?.phase, .complete)
        } else { await manager.start(candidate: source, cookies: []) }
        let deadline = Date().addingTimeInterval(120)
        while !manager.records.contains(where: { [.complete, .failed, .cancelled].contains($0.phase) }) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let record = try XCTUnwrap(manager.records.first)
        if let data = try? Data(contentsOf: root.appendingPathComponent("download-diagnostics.json")),
           let value = String(data: data, encoding: .utf8) {
            print("VYu public download safe diagnostic: " + value)
        }
        XCTAssertEqual(record.phase, .complete, record.failure ?? "No sanitized failure")
        let local = try XCTUnwrap(manager.localURL(for: record))
        let thumbnail = await manager.thumbnailStore.image(for: record, localURL: local)
        print("VYu public thumbnail decoded=\(thumbnail != nil)")
        XCTAssertNotNil(thumbnail, "A complete public video must produce its offline-list preview.")
        let model = PlayerModel(url: local, position: 0, requiresAudio: record.hasAudio == true)
        model.player.isMuted = true
        defer { model.stop(); model.player.replaceCurrentItem(with: nil) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = AVPlayerViewController()
        controller.player = model.player
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; controller.player = nil; previousKeyWindow?.makeKey() }
        await model.start()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        model.player.currentItem?.add(output)
        let normal = try await observe(model.player, mode: "production-player-with-native-view", interval: 4, output: output)
        XCTAssertTrue(normal.advanced, "The production offline player must advance with its native video view attached.")
        XCTAssertFalse(model.failed)
        XCTAssertTrue(normal.decodedFrame, "The saved package must yield a decoded frame.")
        _ = await model.player.seek(to: CMTime(seconds: 47, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        model.player.play()
        let tail = try await observe(model.player, mode: "offline-tail", interval: 3, output: output)
        XCTAssertTrue(tail.advanced)
        XCTAssertTrue(tail.decodedFrame)
    }

    private func observe(_ player: AVPlayer, mode: String, interval: Double, output: AVPlayerItemVideoOutput? = nil) async throws -> (advanced: Bool, decodedFrame: Bool) {
        let start = player.currentTime().seconds
        var decoded = false
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            if let output, output.hasNewPixelBuffer(forItemTime: player.currentTime()),
               output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil { decoded = true }
            try await Task.sleep(for: .milliseconds(100))
        }
        let time = player.currentTime().seconds
        var result: [String: Any] = ["mode": mode, "clockStart": start.isFinite ? start : -1,
            "clockEnd": time.isFinite ? time : -1, "rate": player.rate,
            "timeControl": player.timeControlStatus.rawValue, "itemStatus": player.currentItem?.status.rawValue ?? -1,
            "decodedFrame": decoded, "bufferEmpty": player.currentItem?.isPlaybackBufferEmpty ?? false,
            "likelyToKeepUp": player.currentItem?.isPlaybackLikelyToKeepUp ?? false]
        let reason = player.reasonForWaitingToPlay
        result["waiting"] = reason == .toMinimizeStalls ? "minimize-stalls" : reason == .evaluatingBufferingRate ? "evaluating-buffer" : reason == .noItemToPlay ? "no-item" : reason == nil ? "none" : "other"
        result["loadedRanges"] = player.currentItem?.loadedTimeRanges.compactMap { value -> [Double]? in
            let range = value.timeRangeValue
            guard range.start.seconds.isFinite, range.duration.seconds.isFinite else { return nil }
            return [range.start.seconds, range.duration.seconds]
        }
        if let error = player.currentItem?.error {
            let encoded = try JSONEncoder().encode(DownloadDiagnostics.Failure(error))
            result["error"] = try JSONSerialization.jsonObject(with: encoded)
        }
        result["errorLogCodes"] = player.currentItem?.errorLog()?.events.map(\.errorStatusCode) ?? []
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        print("VYu public player numeric diagnostic: " + text)
        let attachment = XCTAttachment(string: text); attachment.name = mode; attachment.lifetime = .keepAlways; add(attachment)
        return (start.isFinite && time.isFinite && time > start + 0.5, decoded)
    }
}
