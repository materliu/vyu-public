import UIKit
import WebKit
import XCTest
@testable import VYu

/// Loopback login-shaped flows use synthetic values and an ephemeral WebKit store.
@MainActor final class BrowserPopupTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8765")!
    private var window: UIWindow?
    private var popupWindow: UIWindow?
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
            throw XCTSkip("Run fixture_generate.py, then fixtures/server.py before popup integration tests.")
        }
        guard (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let health = try JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              health["ready"] as? Bool == true else {
            XCTFail("Fixture server is present but its generated media is not ready.")
            throw FixtureFailure.notReady
        }
    }

    override func tearDown() async throws {
        browser?.closePopup()
        browser?.stopLoading()
        browser?.webView.removeFromSuperview()
        popupWindow?.rootViewController?.view.removeFromSuperview()
        popupWindow?.isHidden = true
        popupWindow = nil
        window?.isHidden = true
        window = nil
        browser = nil
    }

    func testPopupURLPolicyAllowsOnlyNetworkURLsAndExactBlankDocument() {
        XCTAssertTrue(BrowserPopup.allowsNavigation(URL(string: "https://accounts.google.com/")))
        XCTAssertTrue(BrowserPopup.allowsNavigation(base.appendingPathComponent("popup-child")))
        XCTAssertTrue(BrowserPopup.allowsNavigation(URL(string: "about:blank")))
        for value in ["about:blank#fragment", "about:srcdoc", "file:///private/test", "javascript:alert(1)",
                      "data:text/html,hello", "blob:https://example.com/fixture", "mailto:fixture@example.com",
                      "https://fixture:secret@example.com/"] {
            XCTAssertFalse(BrowserPopup.allowsNavigation(URL(string: value)), value)
        }
        XCTAssertFalse(BrowserPopup.allowsNavigation(nil))
    }

    func testGoogleLoginNoticeUsesExactHostWithoutLoadingAnyWebsite() {
        for (address, expected) in [
            ("https://accounts.google.com/o/oauth2/auth", true),
            ("https://accounts.google.com.example.test/", false),
            ("https://example.test/accounts.google.com", false),
            ("https://example.test/?next=https://accounts.google.com", false)
        ] {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let popup = BrowserPopup(configuration: configuration, initialURL: URL(string: address), onClose: {})
            XCTAssertEqual(popup.isGoogleSignIn, expected, address)
            XCTAssertNil(popup.webView.url, "Constructing a popup must not replay or start its initial URL.")
            popup.close()
        }
    }

    func testBlankShellTimesOutAndCannotRetryAsANetworkRequest() async throws {
        let blank = URL(string: "about:blank")!
        let popup = standalonePopup(initialURL: blank, navigationTimeout: 0.75)
        defer { popup.close() }
        popup.webView.load(URLRequest(url: blank))
        try await waitUntil("blank shell was created", timeout: 3) {
            popup.webView.url == blank && !popup.webView.isLoading
        }
        XCTAssertTrue(popup.isLoading, "A blank shell must wait for its opener to provide the login page.")
        XCTAssertNil(popup.error)
        try await waitUntil("blank shell stopped waiting", timeout: 3) { popup.error != nil }
        XCTAssertFalse(popup.isLoading)
        XCTAssertFalse(popup.canRetry)
        popup.retry()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(popup.webView.url, blank)
        XCTAssertFalse(popup.webView.isLoading)
        XCTAssertFalse(popup.isLoading)
        XCTAssertNotNil(popup.error)
    }

    func testStoppedPopupIgnoresLateCompletionAndFailureCallbacks() async throws {
        let popup = standalonePopup(navigationTimeout: 0.4)
        defer { popup.close() }
        let navigation = try XCTUnwrap(popup.webView.load(URLRequest(url: base.appendingPathComponent("history-delayed"))))
        try await waitUntil("delayed navigation started") {
            popup.url?.path == "/history-delayed" && popup.webView.isLoading
        }
        popup.stop()
        let stoppedError = popup.error
        let stoppedStatus = popup.statusText
        deliverLateCallbacks(to: popup, navigation: navigation)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(popup.isLoading)
        XCTAssertFalse(popup.canRetry)
        XCTAssertEqual(popup.error, stoppedError)
        XCTAssertEqual(popup.statusText, stoppedStatus)
    }

    func testClosedPopupIgnoresLateCallbacksAndClosesOnlyOnce() async throws {
        var closeCount = 0
        let popup = standalonePopup(navigationTimeout: 0.4) { closeCount += 1 }
        let navigation = try XCTUnwrap(popup.webView.load(URLRequest(url: base.appendingPathComponent("history-delayed"))))
        try await waitUntil("navigation began before native close") {
            popup.url?.path == "/history-delayed" && popup.webView.isLoading
        }
        popup.close()
        let closedError = popup.error
        let closedStatus = popup.statusText
        let closedLoading = popup.isLoading
        deliverLateCallbacks(to: popup, navigation: navigation)
        popup.webViewDidClose(popup.webView)
        popup.close()
        popup.retry()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(closeCount, 1)
        XCTAssertFalse(popup.canRetry)
        XCTAssertEqual(popup.error, closedError)
        XCTAssertEqual(popup.statusText, closedStatus)
        XCTAssertEqual(popup.isLoading, closedLoading)
    }

    func testFailedUncommittedRequestDoesNotExposeOAuthDetailsOrReplayAsGET() async throws {
        let address = base.appendingPathComponent("history-delayed")
            .appending(queryItems: [URLQueryItem(name: "state", value: "synthetic-private-state"),
                                   URLQueryItem(name: "code", value: "synthetic-private-code")])
        let popup = standalonePopup(initialURL: address)
        defer { popup.close() }
        let startObserver = PopupNavigationStartObserver(popup: popup)
        popup.webView.navigationDelegate = startObserver
        let requestedNavigation = try XCTUnwrap(popup.webView.load(URLRequest(url: address)))
        // WebKit publishes url/isLoading before it necessarily delivers didStart.
        // Inject the synthetic error only after forwarding that real delegate event.
        try await waitUntil("WebKit delivered the request's provisional start") { startObserver.navigation != nil }
        let navigation = try XCTUnwrap(startObserver.navigation)
        XCTAssertTrue(navigation === requestedNavigation)
        popup.webView.navigationDelegate = popup
        let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                              userInfo: [NSLocalizedDescriptionKey: "Failed OAuth URL: " + address.absoluteString,
                                         NSURLErrorFailingURLErrorKey: address])
        popup.webView(popup.webView, didFailProvisionalNavigation: navigation, withError: failure)
        popup.webView.stopLoading()
        let message = try XCTUnwrap(popup.error)
        XCTAssertFalse(message.contains("synthetic-private"))
        XCTAssertFalse(message.contains(address.absoluteString))
        XCTAssertFalse(popup.statusText.contains("synthetic-private"))
        XCTAssertFalse(popup.canRetry)
        popup.retry()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(popup.isLoading)
        XCTAssertFalse(popup.webView.isLoading, "Retry cannot reconstruct an uncommitted login request from its URL.")
        XCTAssertNotNil(popup.error)
    }

    func testGETPopupKeepsMainDocumentAndCandidateAndReturnsThroughOpener() async throws {
        let browser = try await readyBrowser()
        let documentID = browser.documentID
        let candidateURLs = Set(browser.candidates.map(\.url))
        try await run("window.open('/popup-child', 'fixtureGet'); void 0", in: browser.webView)
        let popup = try await mountedPopup(from: browser)
        try await waitUntil("GET popup finished") {
            popup.url?.path == "/popup-child" && !popup.isLoading
        }
        XCTAssertNil(popup.error)
        XCTAssertTrue(popup.webView.configuration.userContentController.userScripts.isEmpty,
                      "Login windows must not inherit the video's page-world discovery script.")
        try await assertScript("window.opener !== null", in: popup.webView)
        XCTAssertEqual(browser.documentID, documentID)
        XCTAssertEqual(browser.url, base.appendingPathComponent("popup-parent"))
        XCTAssertEqual(Set(browser.candidates.map(\.url)), candidateURLs)

        try await run("document.getElementById('popup-complete').click(); void 0", in: popup.webView)
        try await waitUntil("window.close dismissed the GET popup") { browser.popup == nil }
        try await waitForScript("document.body.dataset.popupResult === 'fixture-get'", in: browser.webView)
        XCTAssertEqual(browser.documentID, documentID)
        try await assertScript("document.body.dataset.parentState === 'preserved'", in: browser.webView)
    }

    func testAboutBlankPopupCanNavigateWithoutReplacingParent() async throws {
        let browser = try await readyBrowser()
        let documentID = browser.documentID
        try await run("openBlankPopup(); void 0", in: browser.webView)
        let popup = try await mountedPopup(from: browser)
        try await waitUntil("about:blank popup reached its HTTP destination") {
            popup.url?.path == "/popup-child" && !popup.isLoading
        }
        XCTAssertNil(popup.error)
        try await assertScript("window.opener !== null", in: popup.webView)
        XCTAssertEqual(browser.documentID, documentID)
        XCTAssertEqual(browser.url, base.appendingPathComponent("popup-parent"))
        browser.closePopup()
        XCTAssertNil(browser.popup)
        try await assertScript("document.body.dataset.parentState === 'preserved'", in: browser.webView)
        XCTAssertTrue(browser.candidates.contains { $0.url.path == "/media/direct.mp4" })
    }

    func testFormPopupPreservesPOSTBodyAndCanMessageAndCloseItsOpener() async throws {
        let browser = try await readyBrowser()
        let documentID = browser.documentID
        let candidateURLs = Set(browser.candidates.map(\.url))
        try await run("document.querySelector('form').requestSubmit(); void 0", in: browser.webView)
        let popup = try await mountedPopup(from: browser)
        try await waitUntil("POST popup finished with the server's form acknowledgement") {
            popup.url?.path == "/popup-post" && !popup.isLoading
        }
        XCTAssertNil(popup.error)
        try await assertScript("document.body.dataset.requestMethod === 'POST' && document.body.dataset.postMarker === 'fixture-marker'", in: popup.webView)
        try await assertScript("window.opener !== null", in: popup.webView)
        try await run("document.getElementById('popup-complete').click(); void 0", in: popup.webView)
        try await waitUntil("window.close dismissed the POST popup") { browser.popup == nil }
        try await waitForScript("document.body.dataset.popupResult === 'fixture-marker'", in: browser.webView)
        XCTAssertEqual(browser.documentID, documentID)
        XCTAssertEqual(Set(browser.candidates.map(\.url)), candidateURLs)
        XCTAssertEqual(browser.historyVisit?.url, base.appendingPathComponent("popup-parent"))
    }

    func testNativeClosePreservesParentAndASecondPopupCanOpen() async throws {
        let browser = try await readyBrowser()
        let documentID = browser.documentID
        try await run("window.open('/popup-child', 'fixtureFirst'); void 0", in: browser.webView)
        let first = try await mountedPopup(from: browser)
        try await waitUntil("first popup committed") { first.url?.path == "/popup-child" && !first.isLoading }
        browser.closePopup()
        XCTAssertNil(browser.popup)
        XCTAssertEqual(browser.documentID, documentID)

        try await run("window.open('/popup-child', 'fixtureSecond'); void 0", in: browser.webView)
        let second = try await mountedPopup(from: browser)
        XCTAssertFalse(first.webView === second.webView)
        try await waitUntil("second popup committed") { second.url?.path == "/popup-child" && !second.isLoading }
        try await assertScript("window.opener !== null", in: second.webView)
        XCTAssertEqual(browser.documentID, documentID)
    }

    private func readyBrowser() async throws -> BrowserModel {
        let browser = BrowserModel(websiteDataStore: .nonPersistent())
        // Scripted clicks are permitted only in this test's ephemeral web view.
        // The UI suite exercises real taps with production popup preferences.
        browser.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let controller = UIViewController()
        controller.view = browser.webView
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        self.browser = browser
        browser.open(base.appendingPathComponent("popup-parent").absoluteString)
        try await waitUntil("parent page finished and its video was discovered") {
            browser.url?.path == "/popup-parent" && !browser.isLoading &&
                browser.candidates.contains { $0.url.path == "/media/direct.mp4" }
        }
        return browser
    }

    private func mountedPopup(from browser: BrowserModel) async throws -> BrowserPopup {
        try await waitUntil("WebKit created an independent popup") { browser.popup != nil }
        let popup = try XCTUnwrap(browser.popup)
        mount(popup)
        return popup
    }

    private func standalonePopup(initialURL: URL? = nil, navigationTimeout: TimeInterval = 25,
                                 onClose: @escaping () -> Void = {}) -> BrowserPopup {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let popup = BrowserPopup(configuration: configuration, initialURL: initialURL,
                                 navigationTimeout: navigationTimeout, onClose: onClose)
        mount(popup)
        return popup
    }

    private func mount(_ popup: BrowserPopup) {
        popupWindow?.isHidden = true
        let controller = UIViewController()
        controller.view = popup.webView
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        popupWindow = window
    }

    private func deliverLateCallbacks(to popup: BrowserPopup, navigation: WKNavigation) {
        popup.webView(popup.webView, didCommit: navigation)
        popup.webView(popup.webView, didFinish: navigation)
        popup.webView(popup.webView, didFailProvisionalNavigation: navigation,
                      withError: URLError(.cancelled))
        // WebKit delegate signatures allow nil. A missing navigation must never
        // match the nil active navigation left by a stop or close operation.
        popup.webView(popup.webView, didCommit: nil)
        popup.webView(popup.webView, didFinish: nil)
        popup.webView(popup.webView, didFail: nil, withError: URLError(.cannotConnectToHost))
    }

    private func run(_ script: String, in webView: WKWebView) async throws {
        _ = try await webView.evaluateJavaScript(script)
    }

    private func bool(_ script: String, in webView: WKWebView) async throws -> Bool {
        try await webView.evaluateJavaScript(script) as? Bool == true
    }

    private func assertScript(_ script: String, in webView: WKWebView,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await bool(script, in: webView)
        XCTAssertTrue(result, "Synthetic page assertion failed: " + script, file: file, line: line)
    }

    private func waitForScript(_ script: String, in webView: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if try await bool(script, in: webView) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("The synthetic opener did not receive its popup result.")
        throw FixtureFailure.timeout
    }

    private func waitUntil(_ reason: String, timeout: TimeInterval = 15, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        guard predicate() else { XCTFail(reason); throw FixtureFailure.timeout }
    }

    private enum FixtureFailure: Error { case notReady, timeout }
}

@MainActor private final class PopupNavigationStartObserver: NSObject, WKNavigationDelegate {
    let popup: BrowserPopup
    private(set) var navigation: WKNavigation?

    init(popup: BrowserPopup) { self.popup = popup }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        popup.webView(webView, didStartProvisionalNavigation: navigation)
        self.navigation = navigation
    }
}
