import AVFoundation
import UIKit
import WebKit
import XCTest
@testable import VYu

/// Records only fixed labels from generated loopback media, never real browsing data.
@MainActor final class HLSPlaybackContextTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8765")!
    private var window: UIWindow?
    private var browser: BrowserModel?
    private var managers: [DownloadManager] = []

    override func setUp() async throws {
        continueAfterFailure = false
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("__health")) }
        catch let error as URLError where error.code == .cannotConnectToHost {
            throw XCTSkip("Generate fixture media and start fixtures/server.py before running HLS context tests.")
        }
        let health = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(health["ready"] as? Bool, true)
        try await post("__control", body: ["offline": false])
    }

    override func tearDown() async throws {
        _ = try? await browser?.webView.evaluateJavaScript("document.querySelector('video')?.pause()")
        browser?.webView.stopLoading()
        window?.isHidden = true
        window = nil; browser = nil
        _ = try? await post("__control", body: ["offline": false])
        for manager in managers {
            for id in manager.records.map(\.id) { manager.removeRecord(id: id) }
            try? FileManager.default.removeItem(at: manager.rootDirectory)
        }
        managers = []
    }

    func testSameOriginNativeHLSPlaybackAndInspectionRequestContext() async throws {
        try await comparePlaybackAndInspection(mode: "same")
    }

    func testCrossOriginNativeHLSPlaybackAndInspectionRequestContext() async throws {
        try await comparePlaybackAndInspection(mode: "cross")
    }

    func testCrossOriginAnonymousNativeHLSPlaybackAndInspectionRequestContext() async throws {
        try await comparePlaybackAndInspection(mode: "cross-anonymous")
    }

    func testNoReferrerNativeHLSPlaybackAndInspectionRequestContext() async throws {
        try await comparePlaybackAndInspection(mode: "no-referrer")
    }

    func testCrossOriginAnonymousHLSDownloadMatchesPlaybackAndPlaysOffline() async throws {
        try await verifyEnforcedPlaybackContextDownload(mode: "cross-anonymous")
    }

    func testNoReferrerHLSDownloadMatchesPlaybackAndPlaysOffline() async throws {
        try await verifyEnforcedPlaybackContextDownload(mode: "no-referrer")
    }

    func testAssetDownloadSessionAdditionalHeadersWithFrameReferrer() async throws {
        try await inspectAssetDownloadHeaders(referrerMode: "framePath")
    }

    func testAssetDownloadSessionAdditionalHeadersWithOriginReferrer() async throws {
        try await inspectAssetDownloadHeaders(referrerMode: "origin")
    }

    private func inspectAssetDownloadHeaders(referrerMode: String) async throws {
        let run = UUID().uuidString
        var page = URLComponents(url: base.appendingPathComponent("playback-context"), resolvingAgainstBaseURL: false)!
        page.queryItems = [URLQueryItem(name: "run", value: run), URLQueryItem(name: "mode", value: "same")]
        // Register a generated run without introducing any WebKit media requests.
        let (_, registration) = try await URLSession.shared.data(from: page.url!)
        XCTAssertEqual((registration as? HTTPURLResponse)?.statusCode, 200)
        try await post("__playback-context", body: ["run": run, "phase": "asset-download"])

        let browser = BrowserModel(websiteDataStore: .nonPersistent())
        let ua = try await browser.webView.evaluateJavaScript("navigator.userAgent", in: nil, contentWorld: .defaultClient)
        let userAgent = try XCTUnwrap(ua as? String)
        let configuration = URLSessionConfiguration.background(withIdentifier: "app.vyu.ios.fixture.context." + run)
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.httpAdditionalHeaders = [
            "Origin": "http://127.0.0.1:8765",
            "Referer": referrerMode == "framePath" ? "http://127.0.0.1:8765/playback-context" : "http://127.0.0.1:8765/"
        ]
        let delegate = HLSContextAssetDelegate()
        let session = AVAssetDownloadURLSession(configuration: configuration, assetDownloadDelegate: delegate, delegateQueue: .main)
        defer {
            session.invalidateAndCancel()
            if let location = delegate.snapshot().location,
               HLSLocalAssetLocation.relativePath(for: location, home: URL(fileURLWithPath: NSHomeDirectory())) != nil {
                try? FileManager.default.removeItem(at: location)
            }
        }
        let source = base.appendingPathComponent("playback-context-media/" + run + "/master.m3u8")
        let asset = AVURLAsset(url: source, options: [AVURLAssetHTTPUserAgentKey: userAgent])
        let task = try XCTUnwrap(session.makeAssetDownloadTask(asset: asset, assetTitle: "Synthetic context diagnostic", assetArtworkData: nil, options: nil))
        task.resume()
        try await waitUntil("Synthetic AVAssetDownload task completes", timeout: 60) { delegate.snapshot().complete }
        let result = delegate.snapshot()
        let transferEvents = try await events(run: run)
        let summary: [String: Any] = ["mode": "asset-" + referrerMode, "assetDownload": transferEvents,
                                     "completionErrorCode": result.error.map { ($0 as NSError).code } ?? 0]
        let encoded = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print("[HLSPlaybackContext] " + String(decoding: encoded, as: UTF8.self))
        XCTAssertNil(result.error, "Synthetic asset download failed with code \(result.error.map { ($0 as NSError).code } ?? 0)")
        let location = try XCTUnwrap(result.location)
        XCTAssertNotNil(HLSLocalAssetLocation.relativePath(for: location, home: URL(fileURLWithPath: NSHomeDirectory())))
        XCTAssertEqual(location.pathExtension, "movpkg")
        XCTAssertTrue(transferEvents.contains { $0["resource"] as? String == "master" })
        XCTAssertTrue(transferEvents.contains { $0["resource"] as? String == "segment" })

        let local = AVURLAsset(url: location, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidLocalReferenceToRemote.rawValue
        ])
        let duration = try await local.load(.duration).seconds
        XCTAssertEqual(duration, 8, accuracy: 0.25)
        XCTAssertTrue(local.assetCache?.isPlayableOffline == true)
    }

    private func comparePlaybackAndInspection(mode: String) async throws {
        let run = UUID().uuidString
        let browser = BrowserModel(websiteDataStore: .nonPersistent())
        self.browser = browser
        let controller = UIViewController(); controller.view = browser.webView
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller; window.makeKeyAndVisible()
        self.window = window
        var components = URLComponents(url: base.appendingPathComponent("playback-context"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "run", value: run), URLQueryItem(name: "mode", value: mode)]
        browser.open(components.url!.absoluteString)

        try await waitUntil("fixture HLS source discovered") {
            browser.hasCurrentDocument && browser.candidates.contains {
                $0.kind == .hls && $0.url.path.contains(run) && $0.url.lastPathComponent == "master.m3u8"
            }
        }
        _ = try await browser.webView.evaluateJavaScript("""
            (() => {
                const video = document.querySelector('video');
                video.muted = true;
                video.play().catch(() => document.body.dataset.playbackRejected = 'true');
                return true;
            })()
            """)
        try await waitUntil("WebKit HLS playback clock advances", timeout: 30) {
            let value = try await browser.webView.evaluateJavaScript("""
                (() => {
                    const video = document.querySelector('video');
                    return Boolean(video && video.currentTime > 0.3 && video.readyState >= 2 && !video.error);
                })()
                """)
            return value as? Bool == true
        }
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('video').pause()")

        let discovered = try XCTUnwrap(browser.candidates.first {
            $0.kind == .hls && $0.url.path.contains(run) && $0.url.lastPathComponent == "master.m3u8"
        })
        let prepared = await browser.prepareForDownload(discovered)
        let candidate = try XCTUnwrap(prepared)
        let playback = try await events(run: run)
        XCTAssertTrue(playback.contains { $0["phase"] as? String == "playback" && $0["resource"] as? String == "master" })
        XCTAssertTrue(playback.contains { $0["phase"] as? String == "playback" && $0["resource"] as? String == "segment" })

        try await post("__playback-context", body: ["run": run, "phase": "inspection"])
        let client = MediaHTTPClient(candidate: candidate, cookies: [])
        defer { client.close() }
        let inspection = try await HLSPreflight.inspect(candidate.url, load: client.playlist)
        XCTAssertTrue(inspection.downloadable)
        let allEvents = try await events(run: run)
        let preflight = allEvents.filter { $0["phase"] as? String == "inspection" && $0["resource"] as? String != "segment" }
        XCTAssertTrue(preflight.contains { $0["resource"] as? String == "master" && $0["method"] as? String == "GET" })

        // Report the observed difference without asserting a platform-dependent UA.
        // The run ID, URLs, raw headers, and any browsing credentials are excluded.
        let summary: [String: Any] = ["mode": mode, "playback": playback, "inspection": preflight]
        let encoded = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print("[HLSPlaybackContext] " + String(decoding: encoded, as: UTF8.self))
    }

    private func verifyEnforcedPlaybackContextDownload(mode: String) async throws {
        let run = UUID().uuidString
        let browser = BrowserModel(websiteDataStore: .nonPersistent())
        self.browser = browser
        let controller = UIViewController(); controller.view = browser.webView
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller; window.makeKeyAndVisible()
        self.window = window
        var page = URLComponents(url: base.appendingPathComponent("playback-context"), resolvingAgainstBaseURL: false)!
        page.queryItems = [URLQueryItem(name: "run", value: run), URLQueryItem(name: "mode", value: mode),
                           URLQueryItem(name: "enforce", value: "1")]
        browser.open(page.url!.absoluteString)
        try await waitUntil("Enforced fixture HLS source is discovered") {
            browser.hasCurrentDocument && browser.candidates.contains {
                $0.kind == .hls && $0.url.path.contains(run) && $0.url.lastPathComponent == "master.m3u8"
            }
        }
        _ = try await browser.webView.evaluateJavaScript("""
            (() => {
                const video = document.querySelector('video');
                video.muted = true;
                video.play().catch(() => document.body.dataset.playbackRejected = 'true');
                return true;
            })()
            """)
        try await waitUntil("WebKit plays media with the enforced request context", timeout: 30) {
            let value = try await browser.webView.evaluateJavaScript("""
                (() => {
                    const video = document.querySelector('video');
                    return Boolean(video && video.currentTime > 0.3 && video.readyState >= 2 && !video.error);
                })()
                """)
            return value as? Bool == true
        }
        _ = try await browser.webView.evaluateJavaScript("document.querySelector('video').pause()")
        let discovered = try XCTUnwrap(browser.candidates.first {
            $0.kind == .hls && $0.url.path.contains(run) && $0.url.lastPathComponent == "master.m3u8"
        })
        let playback = try await events(run: run).filter { $0["phase"] as? String == "playback" }
        assertMatchingContext(playback, mode: mode, requiredResources: ["master", "playlist", "segment"])

        // Keep the same real WebKit UA and URL. Only omit the newly captured
        // request context, reproducing the old master's HTTP 403 deterministically.
        var legacy = discovered
        legacy.requestContext = nil
        let actualUserAgent = try await browser.webView.evaluateJavaScript(
            "navigator.userAgent", in: nil, contentWorld: .defaultClient)
        legacy.userAgent = try XCTUnwrap(actualUserAgent as? String)
        try await post("__playback-context", body: ["run": run, "phase": "legacy-inspection"])
        let legacyClient = MediaHTTPClient(candidate: legacy, cookies: [])
        defer { legacyClient.close() }
        do {
            _ = try await HLSPreflight.inspect(legacy.url, load: legacyClient.playlist)
            XCTFail("The legacy request must fail before request context is supplied.")
            throw ContextRegressionFailure.unexpectedLegacySuccess
        } catch DownloadIssue.playlistHTTP(let stage, let status) {
            XCTAssertEqual(stage, .main)
            XCTAssertEqual(status, 403)
        }
        let legacyEvents = try await events(run: run).filter { $0["phase"] as? String == "legacy-inspection" }
        XCTAssertTrue(legacyEvents.contains { event in
            event["resource"] as? String == "master" && event["uaClass"] as? String == "WebKit" &&
                (mode == "cross-anonymous" ? event["originPresent"] as? Bool == false : event["refererMode"] as? String == "framePath")
        }, "The failing legacy request must differ in Origin or Referer, not a missing browser UA.")

        let prepared = await browser.prepareForDownload(discovered)
        let candidate = try XCTUnwrap(prepared)
        XCTAssertEqual(candidate.url, discovered.url)
        let context = try XCTUnwrap(candidate.requestContext)
        XCTAssertEqual(context.corsMode, mode == "cross-anonymous" ? .anonymous : .none)
        XCTAssertEqual(context.referrerPolicy, mode == "no-referrer" ? .noReferrer : .strictOriginWhenCrossOrigin)
        // Stop WebKit prefetch before counting download requests. The prepared
        // candidate already contains the owning frame's validated context.
        _ = try await browser.webView.evaluateJavaScript("""
            (() => { const video = document.querySelector('video'); video.pause(); video.removeAttribute('src'); video.load(); return true; })()
            """)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-context-download-" + UUID().uuidString)
        let manager = DownloadManager(rootDirectory: root, preferPortableHLS: false)
        managers.append(manager)
        try await post("__playback-context", body: ["run": run, "phase": "inspection"])
        let inspection = await manager.inspect(candidate: candidate, cookies: [])
        XCTAssertTrue(inspection.downloadable, inspection.summary)
        XCTAssertEqual(inspection.expectedDuration ?? 0, 8, accuracy: 0.25)
        let inspectionEvents = try await events(run: run).filter { $0["phase"] as? String == "inspection" }
        assertMatchingContext(inspectionEvents, mode: mode, requiredResources: ["master", "playlist"])

        try await post("__playback-context", body: ["run": run, "phase": "asset-download"])
        await manager.start(candidate: candidate, cookies: [])
        let id = try XCTUnwrap(manager.records.first?.id)
        try await waitUntil("Context-preserving HLS download reaches a terminal state", timeout: 90) {
            guard let record = manager.records.first(where: { $0.id == id }) else { return false }
            return [.complete, .failed, .cancelled].contains(record.phase)
        }
        let record = try XCTUnwrap(manager.records.first(where: { $0.id == id }))
        XCTAssertEqual(record.phase, .complete, record.failure ?? "The asset did not complete.")
        XCTAssertEqual(record.duration ?? 0, 8, accuracy: 0.25)
        XCTAssertEqual(record.hasAudio, true)
        let local = try XCTUnwrap(manager.localURL(for: record))
        XCTAssertTrue(local.isFileURL)
        XCTAssertEqual(local.pathExtension, "movpkg")
        let downloadEvents = try await events(run: run).filter { $0["phase"] as? String == "asset-download" }
        assertMatchingContext(downloadEvents, mode: mode, requiredResources: ["master", "playlist", "segment"])

        try await post("__playback-context", body: ["run": run, "phase": "offline-check"])
        try await post("__control", body: ["offline": true])
        let (_, response) = try await URLSession.shared.data(from: candidate.url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        let eventsBeforeOfflinePlayback = try await events(run: run).count
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
        try await waitUntil("Offline context HLS player becomes ready", timeout: 15) {
            item.status == .readyToPlay || item.status == .failed
        }
        XCTAssertEqual(item.status, .readyToPlay)
        player.play()
        try await waitUntil("Offline context HLS playback clock advances", timeout: 15) {
            player.currentTime().seconds > 1.2 || item.status == .failed
        }
        XCTAssertNotEqual(item.status, .failed)
        XCTAssertGreaterThan(player.currentTime().seconds, 1.2)
        XCTAssertTrue(item.tracks.contains { $0.isEnabled && $0.assetTrack?.mediaType == .audio })
        XCTAssertTrue(item.tracks.contains { $0.isEnabled && $0.assetTrack?.mediaType == .video })
        let seekSucceeded = await player.seek(to: CMTime(seconds: 6.2, preferredTimescale: 600),
                                              toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(seekSucceeded)
        player.play()
        try await waitUntil("Offline context HLS plays its final segment", timeout: 15) {
            player.currentTime().seconds > 7.2 || item.status == .failed
        }
        XCTAssertNotEqual(item.status, .failed)
        XCTAssertGreaterThan(player.currentTime().seconds, 7.2)
        let eventsAfterOfflinePlayback = try await events(run: run).count
        XCTAssertEqual(eventsAfterOfflinePlayback, eventsBeforeOfflinePlayback,
                       "Offline playback must use the complete local asset without contacting the source.")
        try await post("__control", body: ["offline": false])
    }

    private func assertMatchingContext(_ observed: [[String: Any]], mode: String, requiredResources: Set<String>,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let resources = Set(observed.compactMap { $0["resource"] as? String })
        XCTAssertTrue(requiredResources.isSubset(of: resources), "Missing a required HLS request stage.", file: file, line: line)
        let expectedReferrer = mode == "no-referrer" ? "none" : "origin"
        let expectsOrigin = mode == "cross-anonymous"
        for event in observed {
            XCTAssertEqual(event["method"] as? String, "GET", file: file, line: line)
            XCTAssertEqual(event["uaClass"] as? String, "WebKit", file: file, line: line)
            XCTAssertEqual(event["refererMode"] as? String, expectedReferrer, file: file, line: line)
            XCTAssertEqual(event["originPresent"] as? Bool, expectsOrigin, file: file, line: line)
            XCTAssertEqual(event["originMatchesFrame"] as? Bool, expectsOrigin, file: file, line: line)
            XCTAssertEqual(event["cookiePresent"] as? Bool, false, file: file, line: line)
        }
    }

    private enum ContextRegressionFailure: Error { case unexpectedLegacySuccess }

    private func events(run: String) async throws -> [[String: Any]] {
        var components = URLComponents(url: base.appendingPathComponent("__playback-context"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "run", value: run)]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(body["events"] as? [[String: Any]])
        let allowedKeys: Set<String> = ["phase", "method", "resource", "uaClass", "refererMode", "originPresent", "originMatchesFrame", "rangePresent", "cookiePresent"]
        for event in events { XCTAssertEqual(Set(event.keys), allowedKeys) }
        return events
    }

    private func post(_ path: String, body: [String: Any]) async throws {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func waitUntil(_ reason: String, timeout: TimeInterval = 20, predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail(reason)
        throw URLError(.timedOut)
    }
}

private final class HLSContextAssetDelegate: NSObject, AVAssetDownloadDelegate {
    private let lock = NSLock()
    private var location: URL?
    private var complete = false
    private var error: Error?

    func snapshot() -> (location: URL?, complete: Bool, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        return (location, complete, error)
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); self.location = location; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); self.error = error; complete = true; lock.unlock()
    }
}
