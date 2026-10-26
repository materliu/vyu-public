import Combine
import Foundation
import WebKit

/// A real WebKit child window. Its configuration keeps the opener's process and
/// website data store, but it has no media discovery scripts or native bridge.
@MainActor
final class BrowserPopup: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let webView: WKWebView
    @Published private(set) var url: URL?
    @Published private(set) var hostDisplay = "新窗口"
    @Published private(set) var statusText = "正在打开窗口…"
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?
    var error: String? { errorMessage }
    var isGoogleSignIn: Bool { url?.host?.lowercased() == "accounts.google.com" }
    var canRetry: Bool {
        guard !isClosed, committedURL != nil, let current = webView.url else { return false }
        return MediaMessageValidator.networkURL(current.absoluteString) != nil
    }

    private let onClose: () -> Void
    private let navigationTimeout: TimeInterval
    private var currentNavigation: WKNavigation?
    private var committedURL: URL?
    private var generation = UUID()
    private var watchdog: Task<Void, Never>?
    private var isClosed = false

    init(configuration: WKWebViewConfiguration, initialURL: URL?,
         navigationTimeout: TimeInterval = 25, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.navigationTimeout = navigationTimeout
        // WebKit supplies this exact configuration for the child window. Do not
        // replace its processPool or data store, or manually replay the request.
        configuration.userContentController = WKUserContentController()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = false
        rememberDestination(initialURL)
        startWatchdog()
    }

    static func allowsNavigation(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.absoluteString == "about:blank" ||
            MediaMessageValidator.networkURL(url.absoluteString) != nil
    }

    func stop() {
        invalidateNavigation()
        webView.stopLoading()
        isLoading = false
        statusText = "已停止打开窗口。"
        if committedURL == nil { errorMessage = "已停止打开窗口，请返回原网页后重新打开。" }
    }

    func stopLoading() { stop() }

    func retry() {
        guard !isClosed else { return }
        // An uncommitted OAuth request may be a POST. Rebuilding it from its URL
        // would discard its body and state, so only WebKit may reload a document.
        guard canRetry else {
            showError("请返回原网页后重新打开登录窗口。")
            return
        }
        invalidateNavigation()
        errorMessage = nil
        isLoading = true
        statusText = "正在重新打开…"
        startWatchdog()
        webView.reload()
    }

    func reload() { retry() }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        invalidateNavigation()
        webView.stopLoading()
        onClose()
    }

    private func rememberDestination(_ destination: URL?) {
        guard let destination,
              MediaMessageValidator.networkURL(destination.absoluteString) != nil else { return }
        // OAuth URLs remain in memory only; UI displays the host, never the URL.
        url = destination
        hostDisplay = destination.host ?? "网页"
    }

    private func invalidateNavigation() {
        generation = UUID()
        watchdog?.cancel()
        watchdog = nil
        currentNavigation = nil
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let expectedGeneration = generation
        let delay = navigationTimeout
        watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == expectedGeneration, self.isLoading,
                  !self.isClosed else { return }
            if self.committedURL != nil {
                self.isLoading = false
                self.statusText = "网页响应较慢，可继续操作。"
            } else {
                self.showError("登录窗口打开超时，请返回原网页后重新打开。")
                self.webView.stopLoading()
            }
        }
    }

    private func showError(_ message: String) {
        invalidateNavigation()
        isLoading = false
        errorMessage = message
        statusText = message
    }

    private func handleFailure(_ navigation: WKNavigation?, error: Error) {
        guard let navigation, let active = currentNavigation, navigation === active else { return }
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorCancelled {
            // A replacement navigation may start immediately after cancellation.
            let expectedGeneration = generation
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.generation == expectedGeneration,
                      !self.webView.isLoading, self.isLoading else { return }
                self.showError("登录窗口打开已取消，请返回原网页后重新打开。")
            }
            return
        }
        // Localized network errors can contain full OAuth URLs. Keep them out of
        // UI, logs and saved records, including errors returned by redirects.
        if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorTimedOut {
            showError("登录窗口打开超时，请返回原网页后重新打开。")
        } else if failure.domain == NSURLErrorDomain,
                  [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                   NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost].contains(failure.code) {
            showError("无法连接登录网页，请检查网络后在原网页重新打开。")
        } else {
            showError("登录网页未能打开，请返回原网页后重新打开。")
        }
    }
}

extension BrowserPopup: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !isClosed, Self.allowsNavigation(navigationAction.request.url) else {
            if navigationAction.targetFrame?.isMainFrame != false {
                showError("此登录链接无法在 V语 中打开，请返回原页面。")
            }
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            rememberDestination(navigationAction.request.url)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !isClosed else { webView.stopLoading(); return }
        invalidateNavigation()
        currentNavigation = navigation
        committedURL = nil
        errorMessage = nil
        isLoading = true
        statusText = "正在打开窗口…"
        rememberDestination(webView.url)
        startWatchdog()
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation, let active = currentNavigation, navigation === active else { return }
        rememberDestination(webView.url)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let navigation, let active = currentNavigation, navigation === active else { return }
        rememberDestination(webView.url)
        if let current = webView.url, MediaMessageValidator.networkURL(current.absoluteString) != nil {
            committedURL = current
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, let active = currentNavigation, navigation === active else { return }
        guard let current = webView.url,
              MediaMessageValidator.networkURL(current.absoluteString) != nil else {
            // window.open("") creates a blank shell before its opener assigns a
            // destination. Keep waiting under the same bounded watchdog.
            statusText = "正在等待登录网页…"
            return
        }
        rememberDestination(current)
        committedURL = current
        watchdog?.cancel()
        watchdog = nil
        isLoading = false
        errorMessage = nil
        statusText = ""
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure(navigation, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        committedURL = nil
        showError("登录窗口已中断，请返回原网页后重新打开。")
    }
}

extension BrowserPopup: WKUIDelegate {
    func webViewDidClose(_ webView: WKWebView) { close() }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        statusText = "此页面需要再打开一个窗口，请返回原登录页重试。"
        return nil
    }
}
