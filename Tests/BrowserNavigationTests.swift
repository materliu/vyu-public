import UIKit
import WebKit
import XCTest
@testable import VYu

/// Navigation fixtures use loopback pages and a nonpersistent WebKit data store.
@MainActor final class BrowserNavigationTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8765")!
    private var window: UIWindow?
    private var browser: BrowserModel?

    override func setUp() async throws {
        continueAfterFailure = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let result: (Data, URLResponse)
        do { result = try await session.data(from: base.appendingPathComponent("__health")) }
        catch let error as URLError where error.code == .cannotConnectToHost {
            throw XCTSkip("Run fixture_generate.py, then fixtures/server.py before navigation integration tests.")
        }
        guard (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let health = try JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              health["ready"] as? Bool == true else {
            XCTFail("Fixture server is present but its generated media is not ready.")
            throw FixtureFailure.notReady
        }
    }

    override func tearDown() async throws {
        browser?.stopLoading()
        browser?.webView.removeFromSuperview()
        window?.isHidden = true
        window = nil
        browser = nil
    }

    func testTwoServerRedirectsCommitAndDiscoverFinalPage() async throws {
        let browser = mountBrowser()
        let destination = base.appendingPathComponent("direct")
        browser.open(base.appendingPathComponent("navigation-redirect").absoluteString)

        try await waitUntil("redirected page finished and its video was discovered") {
            browser.url == destination && !browser.isLoading &&
                browser.title == "直接视频 · 8 秒有声" &&
                browser.candidates.contains { $0.url.path == "/media/direct.mp4" }
        }
        XCTAssertNil(browser.loadError)
        XCTAssertEqual(browser.displayURL, destination)
        XCTAssertEqual(browser.historyVisit?.url, destination)
        XCTAssertTrue(browser.candidates.allSatisfy { $0.pageURL == destination })
    }

    func testStopBeforeCommitEndsLoadingAndReloadRetriesRequestedPage() async throws {
        let browser = mountBrowser()
        let destination = base.appendingPathComponent("navigation-delayed")
        let initialDocument = browser.documentID
        browser.open(destination.absoluteString)
        XCTAssertEqual(browser.displayURL, destination, "The first request must be displayable before commit.")
        try await waitUntil("delayed navigation started") {
            browser.documentID != initialDocument && browser.isLoading
        }
        XCTAssertNil(browser.url)

        browser.stopLoading()
        XCTAssertFalse(browser.isLoading)
        XCTAssertNil(browser.historyVisit)
        XCTAssertEqual(browser.requestedURL, destination)
        let stoppedDocument = browser.documentID

        browser.reload()
        try await waitUntil("stopped first request can be retried", timeout: 10) {
            browser.documentID != stoppedDocument && browser.url == destination && !browser.isLoading
        }
        XCTAssertNil(browser.loadError)
        XCTAssertEqual(browser.historyVisit?.url, destination)
        let ready = try await browser.webView.evaluateJavaScript("document.getElementById('navigation-delayed-ready') !== null")
        XCTAssertEqual(ready as? Bool, true)
    }

    func testOldNavigationCancellationCannotStopItsReplacement() async throws {
        let browser = mountBrowser()
        let initialDocument = browser.documentID
        let previous = try XCTUnwrap(browser.webView.load(URLRequest(url: base.appendingPathComponent("navigation-delayed"))))
        try await waitUntil("first navigation started") {
            browser.documentID != initialDocument && browser.isLoading
        }
        let previousDocument = browser.documentID
        let destination = base.appendingPathComponent("history-delayed")
        browser.open(destination.absoluteString)
        try await waitUntil("replacement started before its delayed response") {
            browser.documentID != previousDocument && browser.isLoading && browser.url == nil
        }

        // The replaced request can report cancellation after the new one starts.
        browser.webView(browser.webView, didFailProvisionalNavigation: previous,
                        withError: URLError(.cancelled))
        XCTAssertTrue(browser.isLoading)
        XCTAssertNil(browser.loadError)
        XCTAssertEqual(browser.displayURL, destination)

        try await waitUntil("replacement completed despite an old cancellation") {
            browser.url == destination && !browser.isLoading
        }
        XCTAssertNil(browser.loadError)
        XCTAssertEqual(browser.historyVisit?.url, destination)
    }

    func testUncommittedPageTimesOutWithoutRecordingHistory() async throws {
        let browser = mountBrowser(navigationTimeout: 0.2)
        let destination = base.appendingPathComponent("navigation-delayed")
        browser.open(destination.absoluteString)
        try await waitUntil("delayed first response timed out", timeout: 5) {
            !browser.isLoading && browser.loadError != nil
        }
        XCTAssertNil(browser.url)
        XCTAssertNil(browser.historyVisit)
        XCTAssertNil(browser.historyTitleUpdate)
        XCTAssertTrue(browser.candidates.isEmpty)
        XCTAssertEqual(browser.displayURL, destination)

        // A response that arrives after stopLoading must not commit or add history.
        try await Task.sleep(for: .milliseconds(3_200))
        XCTAssertNil(browser.url)
        XCTAssertNil(browser.historyVisit)
        XCTAssertFalse(browser.isLoading)
        XCTAssertNotNil(browser.loadError)
    }

    func testBlockedPortFailureLeavesLoadingState() async throws {
        let browser = mountBrowser()
        let destination = URL(string: "http://127.0.0.1:1/")!
        browser.open(destination.absoluteString)
        let deadline = Date().addingTimeInterval(5)
        while (browser.isLoading || browser.loadError == nil) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        // These values come only from a synthetic loopback request, without cookies or query strings.
        let details = "loading=\(browser.isLoading), error=\(browser.loadError ?? "nil"), " +
            "currentDocument=\(browser.hasCurrentDocument), " +
            "url=\(browser.url?.absoluteString ?? "nil"), requested=\(browser.requestedURL?.absoluteString ?? "nil"), " +
            "history=\(browser.historyVisit?.url.absoluteString ?? "nil"), webLoading=\(browser.webView.isLoading), " +
            "webURL=\(browser.webView.url?.absoluteString ?? "nil"), status=\(browser.statusText)"
        XCTAssertNotNil(browser.loadError, details)
        XCTAssertFalse(browser.isLoading, details)
        XCTAssertFalse(browser.hasCurrentDocument, details)
        XCTAssertNil(browser.historyVisit, details)
        XCTAssertEqual(browser.displayURL, destination, details)
    }

    func testCommittedPageStaysUsableWhileSlowImageFinishes() async throws {
        let browser = mountBrowser(navigationTimeout: 0.5)
        let destination = base.appendingPathComponent("navigation-slow-resources")
        browser.open(destination.absoluteString)
        try await waitUntil("HTML committed before its slow image") { browser.url == destination }
        try await Task.sleep(for: .milliseconds(650))

        XCTAssertFalse(browser.isLoading, "A committed page must leave the waiting state after its loading budget.")
        XCTAssertNil(browser.loadError)
        let ready = try await browser.webView.evaluateJavaScript("document.getElementById('navigation-ready') !== null")
        XCTAssertEqual(ready as? Bool, true)
        XCTAssertTrue(browser.webView.isLoading, "The delayed resource should still be allowed to finish.")
        try await waitUntil("slow image request finished normally", timeout: 8) { !browser.webView.isLoading }
        let loaded = try await browser.webView.evaluateJavaScript("document.querySelector('img').complete && document.querySelector('img').naturalWidth === 16")
        XCTAssertEqual(loaded as? Bool, true)
        XCTAssertNil(browser.loadError)
        XCTAssertEqual(browser.historyVisit?.url, destination)
    }

    func testContentProcessTerminationClearsDownloadStateAndShowsSafeError() async throws {
        let browser = mountBrowser()
        let marker = "fixture-private-query-value"
        let destination = URL(string: "direct?token=" + marker, relativeTo: base)!.absoluteURL
        browser.open(destination.absoluteString)
        try await waitUntil("video is ready before simulated content-process termination") {
            browser.url == destination && !browser.isLoading && !browser.candidates.isEmpty
        }
        browser.pendingDownload = try XCTUnwrap(browser.candidates.first)
        browser.webViewWebContentProcessDidTerminate(browser.webView)

        XCTAssertFalse(browser.isLoading)
        XCTAssertTrue(browser.candidates.isEmpty)
        XCTAssertTrue(browser.alternateSources.isEmpty)
        XCTAssertNil(browser.pendingDownload)
        let error = try XCTUnwrap(browser.loadError)
        XCTAssertFalse(error.contains(marker))
        XCTAssertFalse(error.contains(destination.absoluteString))
        XCTAssertFalse(browser.statusText.contains(marker))
    }

    func testNavigationFailureDoesNotExposeFailingURLOrLocalizedDescription() async throws {
        let browser = mountBrowser()
        let marker = "fixture-private-error-value"
        let destination = URL(string: "navigation-delayed?token=" + marker, relativeTo: base)!.absoluteURL
        let initialDocument = browser.documentID
        let navigation = try XCTUnwrap(browser.webView.load(URLRequest(url: destination)))
        try await waitUntil("navigation started before simulated network failure") {
            browser.documentID != initialDocument && browser.isLoading
        }
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                            userInfo: [NSLocalizedDescriptionKey: "Cannot open " + destination.absoluteString,
                                       NSURLErrorFailingURLErrorKey: destination])
        browser.webView(browser.webView, didFailProvisionalNavigation: navigation, withError: error)

        XCTAssertFalse(browser.isLoading)
        let message = try XCTUnwrap(browser.loadError)
        XCTAssertFalse(message.contains(marker))
        XCTAssertFalse(message.contains(destination.absoluteString))
        XCTAssertFalse(browser.statusText.contains(marker))
        XCTAssertNil(browser.historyVisit)
    }

    private func mountBrowser(navigationTimeout: TimeInterval = 25) -> BrowserModel {
        let browser = BrowserModel(navigationTimeout: navigationTimeout, websiteDataStore: .nonPersistent())
        let controller = UIViewController()
        controller.view = browser.webView
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        self.browser = browser
        return browser
    }

    private func waitUntil(_ reason: String, timeout: TimeInterval = 15, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        guard predicate() else { XCTFail(reason); throw FixtureFailure.timeout }
    }

    private enum FixtureFailure: Error { case notReady, timeout }
}
