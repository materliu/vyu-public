import AVFoundation
import UIKit
import WebKit
import XCTest
@testable import VYu

/// Local generated media only; no real site, browsing history, or account data.
@MainActor final class HLSCompatibilityIntegrationTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8765")!
    private var window: UIWindow?
    private var browsers: [BrowserModel] = []
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
            throw XCTSkip("Run fixture_generate.py, then fixtures/server.py before HLS compatibility integration tests.")
        }
        guard (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let health = try JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              health["ready"] as? Bool == true else {
            XCTFail("Fixture server is present but its generated media is not ready.")
            throw FixtureFailure.notReady
        }
        try await setOffline(false)
        fixtureReady = true
    }

    override func tearDown() async throws {
        defer {
            for browser in browsers { browser.webView.stopLoading(); browser.webView.removeFromSuperview() }
            browsers = []
            window?.isHidden = true; window = nil
            for manager in managers {
                for id in manager.records.map(\.id) { manager.removeRecord(id: id) }
                try? FileManager.default.removeItem(at: manager.rootDirectory)
            }
            managers = []
        }
        if fixtureReady { try await setOffline(false) }
    }

    func testRejectedHLSOffersOnlyItsOwnMP4AndDownloadsCompleteVideo() async throws {
        let browser = mountBrowser()
        let discovered = try await openAlternatives(in: browser)
        let prepared = await browser.prepareForDownload(discovered)
        let candidate = try XCTUnwrap(prepared)
        let manager = makeManager()
        let rejected = await manager.inspect(candidate: candidate, cookies: [])
        XCTAssertFalse(rejected.downloadable)
        XCTAssertTrue(rejected.summary.contains("主清单"), rejected.summary)
        XCTAssertTrue(rejected.summary.contains("403"), rejected.summary)
        XCTAssertTrue(manager.records.isEmpty, "Inspecting a rejected playlist must not start a transfer.")

        let alternatives = browser.alternatives(for: candidate)
        XCTAssertEqual(alternatives.count, 1, "Another media object's MP4 must not be offered for the selected video.")
        let alternate = try XCTUnwrap(alternatives.first)
        XCTAssertEqual(alternate.kind, .file)
        XCTAssertEqual(alternate.url.path, "/media/direct.mp4")
        XCTAssertEqual(alternate.url.query, "matched=1")
        XCTAssertEqual(alternate.pageURL, candidate.pageURL)
        XCTAssertEqual(alternate.frameURL, candidate.frameURL)
        XCTAssertFalse(alternatives.contains { $0.url.query == "unrelated=1" })
        let preparedAlternate = await browser.prepareForDownload(alternate)
        let fileCandidate = try XCTUnwrap(preparedAlternate)
        let inspection = await manager.inspect(candidate: fileCandidate, cookies: [])
        XCTAssertTrue(inspection.downloadable, inspection.summary)
        await manager.start(candidate: fileCandidate, cookies: [])
        let record = try await completedRecord(manager)
        XCTAssertEqual(record.candidate.url, fileCandidate.url)
        XCTAssertEqual(record.duration ?? 0, 8, accuracy: 0.25)
        XCTAssertEqual(record.hasAudio, true)
        XCTAssertEqual(record.bytesWritten, inspection.expectedBytes)
        let local = try XCTUnwrap(manager.localURL(for: record))
        XCTAssertTrue(local.isFileURL)
        try await setOffline(true)
        let (_, response) = try await URLSession.shared.data(from: fileCandidate.url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        let asset = AVURLAsset(url: local, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ])
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 8, accuracy: 0.25)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(videoTracks.isEmpty)
        XCTAssertFalse(audioTracks.isEmpty)
    }

    func testProtectionSignalClearsMatchedAlternatives() async throws {
        let browser = mountBrowser()
        let candidate = try await openAlternatives(in: browser)
        let alternative = try XCTUnwrap(browser.alternatives(for: candidate).first)
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('video').dispatchEvent(new Event('encrypted'))")
        try await waitUntil("protection signal reaches native model") { browser.protectedContentDetected }
        XCTAssertTrue(browser.alternateSources.isEmpty)
        XCTAssertTrue(browser.alternatives(for: candidate).isEmpty)
        let stale = await browser.prepareForDownload(alternative)
        XCTAssertNil(stale)
    }

    func testPageNavigationInvalidatesPreviouslyMatchedAlternatives() async throws {
        let browser = mountBrowser()
        let candidate = try await openAlternatives(in: browser)
        let alternative = try XCTUnwrap(browser.alternatives(for: candidate).first)
        let oldDocument = browser.documentID
        browser.open(base.appendingPathComponent("direct").absoluteString)
        try await waitUntil("new page committed without old video association") {
            browser.documentID != oldDocument && browser.url?.path == "/direct"
                && browser.candidates.contains { $0.url.path == "/media/direct.mp4" }
        }
        XCTAssertTrue(browser.alternatives(for: candidate).isEmpty)
        XCTAssertTrue(browser.alternatives(for: alternative).isEmpty)
        let stale = await browser.prepareForDownload(alternative)
        XCTAssertNil(stale, "A candidate from the previous page must not inherit the new page's session.")
    }

    func testRejectedVariantDoesNotBlockValidHLSDownloadAndOfflinePlayback() async throws {
        let browser = mountBrowser()
        browser.open(base.appendingPathComponent("hls-partial").absoluteString)
        try await waitUntil("partial HLS master discovered") {
            browser.candidates.contains { $0.url.path == "/hls-partial/master.m3u8" }
        }
        let discovered = try XCTUnwrap(browser.candidates.first { $0.url.path == "/hls-partial/master.m3u8" })
        let prepared = await browser.prepareForDownload(discovered)
        let candidate = try XCTUnwrap(prepared)
        let manager = makeManager()
        let inspection = await manager.inspect(candidate: candidate, cookies: [])
        XCTAssertTrue(inspection.downloadable, inspection.summary)
        XCTAssertEqual(inspection.variants.count, 1)
        XCTAssertEqual(inspection.variants.first?.url.path, "/media/hls/360p/index.m3u8")
        XCTAssertEqual(inspection.expectedDuration ?? 0, 8, accuracy: 0.25)
        // Starting the original master must use an inspected available variant;
        // AVFoundation must not silently select the rejected higher-bandwidth one.
        await manager.start(candidate: candidate, cookies: [])
        let record = try await completedRecord(manager)
        XCTAssertEqual(record.duration ?? 0, 8, accuracy: 0.25)
        XCTAssertEqual(record.hasAudio, true)
        let local = try XCTUnwrap(manager.localURL(for: record))
        XCTAssertEqual(local.pathExtension, "movpkg", "Playlist text is not a downloaded HLS asset.")
        try await setOffline(true)
        let (_, response) = try await URLSession.shared.data(from: candidate.url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        let asset = AVURLAsset(url: local, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidLocalReferenceToRemote.rawValue
        ])
        XCTAssertTrue(asset.assetCache?.isPlayableOffline == true)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        try await waitUntil("downloaded HLS prepares without its origin", timeout: 15) {
            item.status == .readyToPlay || item.status == .failed
        }
        XCTAssertEqual(item.status, .readyToPlay, item.error?.localizedDescription ?? "")
        player.play()
        try await waitUntil("offline HLS clock advances", timeout: 15) {
            player.currentTime().seconds > 1.2 || item.status == .failed
        }
        XCTAssertNotEqual(item.status, .failed, item.error?.localizedDescription ?? "")
        XCTAssertGreaterThan(player.currentTime().seconds, 1.2)
        XCTAssertTrue(item.tracks.contains { $0.isEnabled && $0.assetTrack?.mediaType == .audio })
        XCTAssertTrue(item.tracks.contains { $0.isEnabled && $0.assetTrack?.mediaType == .video })
        let seekSucceeded = await player.seek(to: CMTime(seconds: 6.2, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(seekSucceeded)
        player.play()
        try await waitUntil("offline HLS reaches the final segment", timeout: 15) {
            player.currentTime().seconds > 7.2 || item.status == .failed
        }
        XCTAssertNotEqual(item.status, .failed, item.error?.localizedDescription ?? "")
        XCTAssertGreaterThan(player.currentTime().seconds, 7.2)
    }

    private func openAlternatives(in browser: BrowserModel) async throws -> MediaCandidate {
        browser.open(base.appendingPathComponent("hls-alternatives").absoluteString)
        try await waitUntil("HLS player and its matching MP4 metadata discovered") {
            guard let candidate = browser.candidates.first(where: { $0.url.path == "/hls-denied/master.m3u8" }) else { return false }
            return !browser.alternatives(for: candidate).isEmpty
        }
        return try XCTUnwrap(browser.candidates.first { $0.url.path == "/hls-denied/master.m3u8" })
    }

    private func mountBrowser() -> BrowserModel {
        let browser = BrowserModel()
        let controller = UIViewController(); controller.view = browser.webView
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller; window.makeKeyAndVisible()
        self.window = window
        browsers.append(browser)
        return browser
    }

    private func makeManager() -> DownloadManager {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-hls-compat-" + UUID().uuidString)
        let manager = DownloadManager(rootDirectory: root)
        managers.append(manager)
        return manager
    }

    private func completedRecord(_ manager: DownloadManager) async throws -> DownloadRecord {
        try await waitUntil("transfer reached a terminal state", timeout: 60) {
            guard let record = manager.records.first else { return false }
            return [.complete, .failed, .cancelled].contains(record.phase)
        }
        let record = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(record.phase, .complete, record.failure ?? "No safe diagnostic available.")
        return record
    }

    private func setOffline(_ value: Bool) async throws {
        var request = URLRequest(url: base.appendingPathComponent("__control"))
        request.httpMethod = "POST"; request.httpBody = Data("{\"offline\":\(value)}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func waitUntil(_ reason: String, timeout: TimeInterval = 20, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard predicate() else { XCTFail(reason); throw FixtureFailure.timeout }
    }

    private enum FixtureFailure: Error { case notReady, timeout }
}
