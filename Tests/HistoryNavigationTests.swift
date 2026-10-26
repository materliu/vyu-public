import Combine
import UIKit
import WebKit
import XCTest
@testable import VYu

/// Synthetic loopback pages and a temporary library; no user browsing data.
@MainActor final class HistoryNavigationTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8765")!
    private var window: UIWindow?
    private var browser: BrowserModel?
    private var library: LibraryStore?
    private var directory: URL?
    private var subscriptions: Set<AnyCancellable> = []

    override func setUp() async throws {
        continueAfterFailure = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let result: (Data, URLResponse)
        do { result = try await session.data(from: base.appendingPathComponent("__health")) }
        catch let error as URLError where error.code == .cannotConnectToHost {
            throw XCTSkip("Run fixture_generate.py, then fixtures/server.py before history integration tests.")
        }
        guard (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let health = try JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              health["ready"] as? Bool == true else {
            XCTFail("Fixture server is present but its generated media is not ready.")
            throw FixtureFailure.notReady
        }
    }

    override func tearDown() async throws {
        subscriptions = []
        browser?.webView.stopLoading()
        browser?.webView.removeFromSuperview()
        window?.isHidden = true
        window = nil; browser = nil; library = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    func testClearIgnoresLateTitleAndPublishedVisitUntilReload() async throws {
        let (browser, library) = mountBrowser()
        let url = base.appendingPathComponent("direct")
        browser.open(url.absoluteString)
        try await waitUntil("initial visit and page title recorded") {
            !browser.isLoading && library.recent.first?.url == url &&
                library.recent.first?.title == "直接视频 · 8 秒有声"
        }
        let queuedVisit = try XCTUnwrap(browser.historyVisit)
        let previousDocument = browser.documentID

        try library.clearRecent()
        browser.suppressPendingHistory()
        XCTAssertFalse(browser.isCurrentHistoryVisitAllowed(queuedVisit),
                       "A visit emitted before clearing must also be rejected when its UI delivery is late.")
        _ = try await browser.webView.evaluateJavaScript("document.title = '清理后的迟到标题'")
        try await waitUntil("late title reached the browser model") { browser.title == "清理后的迟到标题" }
        XCTAssertTrue(library.recent.isEmpty)
        let restored = LibraryStore(directory: try XCTUnwrap(directory))
        XCTAssertTrue(restored.recent.isEmpty, "Late title callbacks must not restore persisted history.")

        browser.reload()
        try await waitUntil("reloading intentionally records a fresh visit") {
            browser.documentID != previousDocument && !browser.isLoading &&
                library.recent.first?.url == url && library.recent.first?.title == "直接视频 · 8 秒有声"
        }
        XCTAssertEqual(library.recent.count, 1)
    }

    func testDifferentURLsWithSameTitleAreBothRecorded() async throws {
        let (browser, library) = mountBrowser()
        let first = URL(string: "/direct?first", relativeTo: base)!.absoluteURL
        let second = URL(string: "/direct?second", relativeTo: base)!.absoluteURL
        browser.open(first.absoluteString)
        try await waitUntil("first same-title page recorded") {
            !browser.isLoading && library.recent.first?.url == first &&
                library.recent.first?.title == "直接视频 · 8 秒有声"
        }
        browser.open(second.absoluteString)
        try await waitUntil("second same-title page recorded") {
            !browser.isLoading && library.recent.first?.url == second && library.recent.count == 2
        }
        XCTAssertEqual(library.recent.map(\.url), [second, first])
        XCTAssertEqual(Set(library.recent.map(\.title)), ["直接视频 · 8 秒有声"])
    }

    func testClearDuringPendingNavigationSuppressesLateCommitAndAllowsNextVisit() async throws {
        let (browser, library) = mountBrowser()
        let first = base.appendingPathComponent("direct")
        let delayed = base.appendingPathComponent("history-delayed")
        browser.open(first.absoluteString)
        try await waitUntil("initial history exists") {
            !browser.isLoading && library.recent.first?.url == first
        }
        let previousDocument = browser.documentID
        browser.open(delayed.absoluteString)
        try await waitUntil("new navigation started before response commit") {
            browser.documentID != previousDocument && browser.isLoading && browser.historyVisit == nil
        }
        XCTAssertNotEqual(browser.url, delayed, "Fixture must still be pending when history is cleared.")
        let pendingDocument = browser.documentID
        try library.clearRecent()
        browser.suppressPendingHistory()
        try await waitUntil("pending page finished after history was cleared") {
            browser.url == delayed && !browser.isLoading
        }
        XCTAssertEqual(browser.documentID, pendingDocument)
        XCTAssertTrue(library.recent.isEmpty, "The pending visit must not recreate cleared history.")
        XCTAssertNil(browser.historyVisit)

        let subsequent = URL(string: "/direct?after-clear", relativeTo: base)!.absoluteURL
        browser.open(subsequent.absoluteString)
        try await waitUntil("a later user navigation is recorded normally") {
            !browser.isLoading && library.recent.first?.url == subsequent
        }
        XCTAssertEqual(library.recent.map(\.url), [subsequent])
    }

    private func mountBrowser() -> (BrowserModel, LibraryStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-history-" + UUID().uuidString)
        let library = LibraryStore(directory: root)
        let browser = BrowserModel()
        // Match ContentView's two event handlers, including the consumption-time
        // gate needed when an event was published before a history deletion.
        browser.$historyVisit.compactMap { $0 }.sink { [weak browser, weak library] event in
            guard let browser, let library, browser.isCurrentHistoryVisitAllowed(event) else { return }
            library.visit(url: event.url, title: event.title)
        }.store(in: &subscriptions)
        browser.$historyTitleUpdate.compactMap { $0 }.sink { [weak browser, weak library] event in
            guard let browser, let library, browser.isCurrentHistoryVisitAllowed(event) else { return }
            library.updateRecentTitle(url: event.url, title: event.title)
        }.store(in: &subscriptions)
        let controller = UIViewController(); controller.view = browser.webView
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller; window.makeKeyAndVisible()
        self.window = window; self.browser = browser; self.library = library; directory = root
        return (browser, library)
    }

    private func waitUntil(_ reason: String, timeout: TimeInterval = 15, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard predicate() else { XCTFail(reason); throw FixtureFailure.timeout }
    }

    private enum FixtureFailure: Error { case notReady, timeout }
}
