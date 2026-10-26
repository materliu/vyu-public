import Combine
import Foundation
import WebKit

@MainActor
final class BrowserModel: NSObject, ObservableObject {
    struct HistoryEvent: Equatable {
        let documentID: UUID
        let url: URL
        let title: String
    }

    @Published var url: URL?
    @Published private(set) var popup: BrowserPopup?
    @Published private(set) var requestedURL: URL?
    @Published private(set) var loadError: String?
    var displayURL: URL? { requestedURL ?? url }
    var isGoogleSignIn: Bool { displayURL?.host?.lowercased() == "accounts.google.com" }
    var canReturnToXLogin: Bool {
        ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(url?.host?.lowercased() ?? "")
    }
    var hasCurrentDocument: Bool { committedPageURL != nil && loadError == nil && !isGoogleSignIn }
    @Published var title = ""
    @Published var candidates: [MediaCandidate] = []
    @Published var isLoading = false
    @Published var statusText = "输入网址，打开网页后识别视频"
    @Published var canGoBack = false
    @Published private(set) var protectedContentDetected = false
    @Published private(set) var mediaSourceDetected = false
    @Published private(set) var documentID = UUID()
    @Published private(set) var discoveryID = UUID()
    @Published private(set) var historyVisit: HistoryEvent?
    @Published private(set) var historyTitleUpdate: HistoryEvent?
    @Published var pendingDownload: MediaCandidate?
    @Published var downloadNotice: String?
    struct AlternateSourceKey: Hashable {
        let url: URL
        let frameURL: URL
    }
    @Published private(set) var alternateSources: [AlternateSourceKey: [MediaCandidate]] = [:]

    let webView: WKWebView
    private var navigationToken = UUID().uuidString
    private var committedPageURL: URL?
    private var provisionalNavigation: WKNavigation?
    private let navigationTimeout: TimeInterval
    private var navigationWatchdog: Task<Void, Never>?
    private var suppressesCurrentHistory = false
    private var suppressedHistoryURLs: Set<URL> = []
    private var observations: [NSKeyValueObservation] = []
    private let messageProxy = ScriptMessageProxy()
    // Frame handles come from validated WebKit messages, never a JavaScript claim.
    private var discoveryFrames: [URL: WKFrameInfo] = [:]
    private var explicitlySelectedFrames: Set<URL> = []
    private var documentReferrerPolicies: [URL: MediaRequestContext.ReferrerPolicy] = [:]
    private var partialResources: Set<MediaCandidate.ID> = []
    private let maximumFrameContexts = 160

    init(navigationTimeout: TimeInterval = 25, websiteDataStore: WKWebsiteDataStore = .default()) {
        self.navigationTimeout = navigationTimeout
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Keep WebKit's system/engine UA and add the mobile Safari compatibility
        // token. Without it, X redirects embedded views to an external-only scheme.
        configuration.applicationNameForUserAgent = [configuration.applicationNameForUserAgent, "Safari/604.1"]
            .compactMap { $0 }.joined(separator: " ")
        // This app's default WebKit store is sandboxed by its independent bundle ID.
        configuration.websiteDataStore = websiteDataStore
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        messageProxy.owner = self
        configuration.userContentController.add(messageProxy, contentWorld: .page, name: "vyuMedia")
        configuration.userContentController.add(messageProxy, contentWorld: .defaultClient, name: "vyuDownloadAction")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = false
        installScript()
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                // Re-read the current document on the main actor. A queued KVO
                // callback must not carry a previous page's title into history.
                Task { @MainActor in self?.updateCurrentTitle() }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.canGoBack = view.canGoBack }
            }
        ]
    }

    func open(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let destination = MediaMessageValidator.networkURL(value) else {
            statusText = "请输入完整的 HTTP 或 HTTPS 网址"; return
        }
        requestedURL = destination
        loadError = nil
        webView.load(URLRequest(url: destination))
    }

    func closePopup() {
        let window = popup
        popup = nil
        window?.close()
    }

    func returnToXLogin() {
        guard canReturnToXLogin else { return }
        closePopup()
        open("https://x.com/i/flow/login")
    }

    func goBack() { webView.goBack() }
    func reload() {
        if let destination = requestedURL, loadError != nil || committedPageURL == nil {
            open(destination.absoluteString)
        } else { webView.reload() }
    }

    func stopLoading() {
        // Invalidate first: WebKit may deliver cancellation after another load starts.
        navigationWatchdog?.cancel()
        provisionalNavigation = nil
        webView.stopLoading()
        isLoading = false
        if committedPageURL == nil {
            loadError = "已停止打开网页，可点重试。"
            statusText = loadError!
        } else { updateStatus() }
    }

    private func startNavigationWatchdog() {
        navigationWatchdog?.cancel()
        let generation = documentID
        let delay = navigationTimeout
        navigationWatchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.documentID == generation, self.isLoading else { return }
            self.isLoading = false
            if self.committedPageURL == nil {
                self.provisionalNavigation = nil
                self.webView.stopLoading()
                self.loadError = "网页连接超时，请重试。"
                self.statusText = self.loadError!
            } else {
                // Slow subresources must not hide or stop an already visible page.
                self.updateStatus()
            }
        }
    }

    func suppressPendingHistory(url: URL? = nil) {
        if let url { suppressedHistoryURLs.insert(url) }
        else { suppressesCurrentHistory = true }
    }

    func isCurrentHistoryVisitAllowed(_ event: HistoryEvent) -> Bool {
        event.documentID == documentID && event.url == committedPageURL &&
            Self.canRecordVisit(event.url) && !suppressesCurrentHistory && !suppressedHistoryURLs.contains(event.url)
    }

    static func canRecordVisit(_ url: URL) -> Bool {
        guard url.host?.lowercased() != "accounts.google.com" else { return false }
        // Authentication callback parameters are transient credentials, not history.
        let privateKeys: Set<String> = ["code", "access_token", "id_token", "refresh_token", "oauth_token", "oauth_verifier", "credential", "samlresponse"]
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var fragment = URLComponents()
        fragment.percentEncodedQuery = components?.percentEncodedFragment
        let parameters = (components?.queryItems ?? []) + (fragment.queryItems ?? [])
        return !parameters.contains { privateKeys.contains($0.name.lowercased()) }
    }

    private func updateCurrentTitle() {
        title = webView.title ?? ""
        guard let pageURL = committedPageURL, webView.url == pageURL else { return }
        let event = HistoryEvent(documentID: documentID, url: pageURL, title: title)
        guard isCurrentHistoryVisitAllowed(event) else { return }
        historyTitleUpdate = event
    }

    func refreshCandidates(resetHistory: Bool = false) {
        guard hasCurrentDocument else { return }
        if resetHistory {
            // Queued messages from the previous scan must not repopulate the list.
            navigationToken = UUID().uuidString
            discoveryID = UUID()
            candidates = []; alternateSources = [:]; pendingDownload = nil
            discoveryFrames = [:]
            partialResources = []
            explicitlySelectedFrames = []
            installScript()
            let encoded = String(data: try! JSONEncoder().encode(navigationToken), encoding: .utf8)!
            webView.evaluateJavaScript("window.__vyuSetNavigationToken && window.__vyuSetNavigationToken(\(encoded), true)") { _, _ in }
            webView.evaluateJavaScript("window.__vyuSetNavigationToken && window.__vyuSetNavigationToken(\(encoded), true)", in: nil, in: .defaultClient) { _ in }
        } else {
            webView.evaluateJavaScript("window.__vyuRescan && window.__vyuRescan()") { _, _ in }
            webView.evaluateJavaScript("window.__vyuRescan && window.__vyuRescan()", in: nil, in: .defaultClient) { _ in }
        }
        updateStatus()
    }

    func isCurrentCandidate(_ candidate: MediaCandidate) -> Bool {
        guard hasCurrentDocument, committedPageURL == candidate.pageURL, !protectedContentDetected else { return false }
        let matches: (MediaCandidate) -> Bool = {
            $0.id == candidate.id && $0.kind == candidate.kind
        }
        return candidates.contains(where: matches) ||
            alternateSources.values.contains(where: { $0.contains(where: matches) })
    }

    func prepareForDownload(_ candidate: MediaCandidate) async -> MediaCandidate? {
        let token = navigationToken
        guard isCurrentCandidate(candidate), let frame = discoveryFrames[candidate.frameURL] else { return nil }
        let encodedURL = String(data: try! JSONEncoder().encode(candidate.url.absoluteString), encoding: .utf8)!
        // Read the actual owning frame. The isolated world avoids page-defined
        // navigator/element getters being mistaken for browser request settings.
        let script = """
        (() => {
          const target = \(encodedURL);
          const validPolicies = ['no-referrer', 'no-referrer-when-downgrade', 'origin', 'same-origin',
            'strict-origin', 'origin-when-cross-origin', 'strict-origin-when-cross-origin', 'unsafe-url'];
          let metaPolicy = '';
          const referrerMetas = document.querySelectorAll('meta[name="referrer" i]');
          if (referrerMetas.length > 160) return null;
          for (const meta of referrerMetas) {
            const policy = (meta.getAttribute('content') || '').trim().toLowerCase();
            if (validPolicies.includes(policy)) metaPolicy = policy;
          }
          const modes = new Set();
          for (const video of Array.from(document.querySelectorAll('video')).slice(0, 80)) {
            // A blob or a different currentSrc cannot be bound to an observed
            // playlist by proximity. Only the element's selected URL is usable.
            // Match the inline control's source selection before first playback.
            let selected = video.currentSrc || video.getAttribute('src') || '';
            if (!selected) {
              const source = Array.from(video.querySelectorAll('source')).slice(0, 30)
                .find(item => item.getAttribute('src') && (!item.type || video.canPlayType(item.type)));
              selected = source?.src || '';
            }
            if (!selected) continue;
            try { if (new URL(selected, document.baseURI).href !== target) continue; }
            catch (_) { continue; }
            // Missing means no CORS. Empty and invalid values mean anonymous;
            // keywords are ASCII case-insensitive, with no whitespace trimming.
            const cors = (video.getAttribute('crossorigin') || '').replace(/[A-Z]/g, letter => letter.toLowerCase());
            modes.add(!video.hasAttribute('crossorigin') ? 'none' :
              cors === 'use-credentials' ? 'useCredentials' : 'anonymous');
          }
          return {documentURL: location.href, userAgent: navigator.userAgent, metaPolicy,
            corsMode: modes.size > 1 ? 'anonymous' : modes.size === 1 ? Array.from(modes)[0] : null};
        })()
        """
        let value = try? await webView.evaluateJavaScript(script, in: frame, contentWorld: .defaultClient)
        guard token == navigationToken, isCurrentCandidate(candidate),
              let fields = value as? [String: Any], let document = fields["documentURL"] as? String,
              let liveFrameURL = MediaMessageValidator.networkURL(document), liveFrameURL == candidate.frameURL else { return nil }
        var prepared = candidate
        if let agent = fields["userAgent"] as? String, !agent.isEmpty, agent.utf8.count <= 1_024,
           !agent.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            prepared.userAgent = agent
        }
        let mode = (fields["corsMode"] as? String).flatMap(MediaRequestContext.CORSMode.init(rawValue:)) ?? .none
        var responseURL = URLComponents(url: liveFrameURL, resolvingAgainstBaseURL: false)
        responseURL?.fragment = nil
        let policy = MediaRequestContext.ReferrerPolicy.parse(fields["metaPolicy"] as? String)
            ?? documentReferrerPolicies[responseURL?.url ?? liveFrameURL] ?? .strictOriginWhenCrossOrigin
        prepared.requestContext = MediaRequestContext(corsMode: mode, referrerPolicy: policy)
        return prepared
    }

    func alternatives(for candidate: MediaCandidate) -> [MediaCandidate] {
        guard !protectedContentDetected, candidate.kind == .hls,
              candidate.pageURL == committedPageURL else { return [] }
        let key = AlternateSourceKey(url: candidate.url, frameURL: candidate.frameURL)
        return (alternateSources[key] ?? []).filter {
            $0.pageURL == candidate.pageURL && $0.frameURL == candidate.frameURL
        }.map { alternate in
            // An explicit player selection reads its current card title immediately,
            // while background metadata updates may still be coalescing. Keep that
            // selected title when switching representations of the same video.
            guard ["video", "source"].contains(candidate.source),
                  !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return alternate }
            return MediaCandidate(url: alternate.url, pageURL: alternate.pageURL, frameURL: alternate.frameURL,
                title: candidate.title, kind: alternate.kind, source: alternate.source,
                mimeType: alternate.mimeType, userAgent: alternate.userAgent, requestContext: alternate.requestContext)
        }
    }

    private func installScript() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: DiscoveryScript.source(token: navigationToken),
                                             injectionTime: .atDocumentStart, forMainFrameOnly: false,
                                             in: .page))
        controller.addUserScript(WKUserScript(source: DiscoveryScript.source(token: navigationToken, controlsOnly: true),
                                             injectionTime: .atDocumentStart, forMainFrameOnly: false,
                                             in: .defaultClient))
    }

    private func prepareNavigation() {
        closePopup()
        navigationToken = UUID().uuidString
        documentID = UUID()
        discoveryID = UUID()
        historyVisit = nil
        historyTitleUpdate = nil
        suppressesCurrentHistory = false
        suppressedHistoryURLs = []
        pendingDownload = nil
        downloadNotice = nil
        committedPageURL = nil
        provisionalNavigation = nil
        candidates = []
        alternateSources = [:]
        discoveryFrames = [:]
        partialResources = []
        explicitlySelectedFrames = []
        documentReferrerPolicies = [:]
        protectedContentDetected = false
        mediaSourceDetected = false
        isLoading = true
        loadError = nil
        statusText = "正在打开网页并识别视频…"
        installScript()
        startNavigationWatchdog()
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        let trustedAction = message.name == "vyuDownloadAction" && message.world === WKContentWorld.defaultClient
        guard trustedAction || (message.name == "vyuMedia" && message.world === WKContentWorld.page),
              hasCurrentDocument, let pageURL = committedPageURL else { return }
        let origin = message.frameInfo.securityOrigin
        let context = DiscoveryMessageContext(navigationToken: navigationToken, pageURL: pageURL,
                                              frameRequestURL: message.frameInfo.request.url,
                                              originScheme: origin.protocol, originHost: origin.host, originPort: origin.port)
        guard let result = try? MediaMessageValidator.validate(message.body, context: context) else { return }
        switch result {
        case .downloadRequested, .downloadUnavailable:
            guard trustedAction else { return }
        default: break
        }
        switch result {
        case .downloadRequested(let candidate):
            if discoveryFrames[candidate.frameURL] != nil || discoveryFrames.count < maximumFrameContexts {
                discoveryFrames[candidate.frameURL] = message.frameInfo
                explicitlySelectedFrames.insert(candidate.frameURL)
            }
        case .candidate(let candidate), .alternative(let candidate, _):
            // Public frame information has no stable frame identifier. When two
            // frames share a document URL, preserve an explicit click's handle
            // instead of replacing it with a later background discovery.
            if !explicitlySelectedFrames.contains(candidate.frameURL),
               discoveryFrames[candidate.frameURL] != nil || discoveryFrames.count < maximumFrameContexts {
                discoveryFrames[candidate.frameURL] = message.frameInfo
            }
        default: break
        }
        switch result {
        case .candidate(let candidate):
            merge(candidate)
        case .alternative(let candidate, let relatedURL):
            let key = AlternateSourceKey(url: relatedURL, frameURL: candidate.frameURL)
            guard !protectedContentDetected, !partialResources.contains(candidate.id),
                  alternateSources[key] != nil || alternateSources.count < 80 else { return }
            var sources = alternateSources[key] ?? []
            if let index = sources.firstIndex(where: { $0.id == candidate.id }) {
                sources[index] = candidate
                alternateSources[key] = sources
            } else if sources.count < 12, alternateSources.values.reduce(0, { $0 + $1.count }) < 160 {
                sources.append(candidate)
                alternateSources[key] = sources
            }
        case .downloadRequested(let clicked):
            guard !protectedContentDetected else {
                downloadNotice = DownloadIssue.protectedContent.localizedDescription; return
            }
            // Extensionless endpoints can have a response MIME discovered by the
            // page observer. Keep that format hint for this exact clicked URL;
            // it grants no authorization and the transfer still validates bytes.
            let known = candidates.first { $0.id == clicked.id && !($0.mimeType ?? "").isEmpty }
            let candidate: MediaCandidate
            if (clicked.mimeType ?? "").isEmpty, let known {
                candidate = MediaCandidate(url: clicked.url, pageURL: clicked.pageURL, frameURL: clicked.frameURL,
                    title: clicked.title, kind: known.kind, source: clicked.source, mimeType: known.mimeType)
            } else { candidate = clicked }
            merge(candidate, explicitRequest: true)
            // Only the isolated world's real button click reaches this branch.
            pendingDownload = candidate
        case .downloadUnavailable(let issue):
            switch issue {
            case .mediaSource: downloadNotice = "这个播放器使用临时媒体地址，暂时无法确定它对应的完整视频。请先播放，再检查视频来源。"
            case .protectedContent:
                protectedContentDetected = true
                downloadNotice = DownloadIssue.protectedContent.localizedDescription
            case .noSource: downloadNotice = "这个视频尚未加载地址。请先在网页播放，再点下载此视频。"
            }
        case .signal(.mediaSource): mediaSourceDetected = true
        case .signal(.protectedContent):
            protectedContentDetected = true
        case .partialResource(let id):
            guard partialResources.count < 512 || partialResources.contains(id) else { return }
            partialResources.insert(id)
            candidates.removeAll { $0.id == id && !["video", "source"].contains($0.source) }
            for key in Array(alternateSources.keys) {
                alternateSources[key]?.removeAll { $0.id == id }
                if alternateSources[key]?.isEmpty == true { alternateSources.removeValue(forKey: key) }
            }
        }
        if protectedContentDetected {
            alternateSources = [:]
            // An encrypted event does not identify every request belonging to that video.
            // Conservatively prevent this page's candidates being offered as downloadable.
            candidates = candidates.map { item in
                MediaCandidate(url: item.url, pageURL: item.pageURL, frameURL: item.frameURL,
                               title: item.title, kind: .protected, source: item.source, mimeType: item.mimeType)
            }
        }
        updateStatus()
    }

    private func merge(_ candidate: MediaCandidate, explicitRequest: Bool = false) {
        let explicitSource = ["video", "source"].contains(candidate.source)
        guard explicitSource || !partialResources.contains(candidate.id) else { return }
        if let index = candidates.firstIndex(where: { $0.id == candidate.id }) {
            if explicitSource || (!["video", "source"].contains(candidates[index].source) && candidates[index].mimeType?.isEmpty != false) {
                candidates[index] = candidate
            }
        } else {
            if explicitRequest && candidates.count >= 100 { candidates.removeFirst() }
            if candidates.count < 100 { candidates.append(candidate) }
        }
    }

    private func updateStatus() {
        if protectedContentDetected { statusText = "页面报告了加密媒体，暂不提供下载；仍可浏览和收藏" }
        else if !candidates.isEmpty { statusText = "可点视频旁的下载按钮；\(candidates.count) 个候选来源可能包含不同画质或旧链接" }
        else if mediaSourceDetected { statusText = "播放器使用媒体流，正在查找源清单；blob 地址不能直接下载" }
        else { statusText = "尚未识别到视频。可先播放，再点重新识别；也可收藏此页" }
    }
}

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if webView === self.webView, let response = navigationResponse.response as? HTTPURLResponse,
           let documentURL = response.url,
           MediaMessageValidator.networkURL(documentURL.absoluteString) != nil {
            // Store only the parsed policy, not arbitrary response headers.
            var responseURL = URLComponents(url: documentURL, resolvingAgainstBaseURL: false)
            responseURL?.fragment = nil
            let key = responseURL?.url ?? documentURL
            if let policy = MediaRequestContext.ReferrerPolicy.parse(response.value(forHTTPHeaderField: "Referrer-Policy")),
               documentReferrerPolicies[key] != nil || documentReferrerPolicies.count < maximumFrameContexts {
                documentReferrerPolicies[key] = policy
            } else {
                documentReferrerPolicies.removeValue(forKey: key)
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame == nil,
           navigationAction.request.url?.absoluteString == "about:blank", hasCurrentDocument {
            // A login popup can be created empty, then receive its URL or POST form.
            decisionHandler(.allow); return
        }
        if navigationAction.targetFrame?.isMainFrame == false,
           let scheme = navigationAction.request.url?.scheme?.lowercased(), ["about", "blob", "data"].contains(scheme) {
            // These are common internal player frames. Their messages remain subject
            // to native HTTP-origin checks, but they must be allowed to render.
            decisionHandler(.allow); return
        }
        guard let targetURL = navigationAction.request.url,
              MediaMessageValidator.networkURL(targetURL.absoluteString) != nil else {
            decisionHandler(.cancel); return
        }
        let fragmentNavigation: Bool = {
            guard let current = webView.url, current != targetURL,
                  var previous = URLComponents(url: current, resolvingAgainstBaseURL: false),
                  var next = URLComponents(url: targetURL, resolvingAgainstBaseURL: false) else { return false }
            previous.fragment = nil; next.fragment = nil
            return previous.url == next.url
        }()
        // A server redirect may ask policy again for the same WKNavigation.
        // Only didStart creates a document epoch; policy must not discard its identity.
        if navigationAction.targetFrame?.isMainFrame == true && fragmentNavigation {
            url = targetURL
            requestedURL = targetURL
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        prepareNavigation()
        provisionalNavigation = navigation
        requestedURL = webView.url ?? requestedURL
        isLoading = true
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let active = provisionalNavigation, navigation === active else { return }
        // WebKit can commit an internal about:blank page for a blocked request.
        // It is not the requested site and must not enable downloads or history.
        guard let pageURL = webView.url,
              MediaMessageValidator.networkURL(pageURL.absoluteString) != nil else {
            navigationFailed(navigation, error: URLError(.unsupportedURL))
            return
        }
        committedPageURL = pageURL
        url = pageURL
        requestedURL = pageURL
        loadError = nil
        let event = HistoryEvent(documentID: documentID, url: pageURL, title: webView.title ?? "")
        if isCurrentHistoryVisitAllowed(event) { historyVisit = event }
        // Rebind restored back/forward documents as well as freshly injected ones.
        let encoded = String(data: try! JSONEncoder().encode(navigationToken), encoding: .utf8)!
        webView.evaluateJavaScript("window.__vyuSetNavigationToken && window.__vyuSetNavigationToken(\(encoded))") { _, _ in }
        webView.evaluateJavaScript("window.__vyuSetNavigationToken && window.__vyuSetNavigationToken(\(encoded))", in: nil, in: .defaultClient) { _ in }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let active = provisionalNavigation, navigation === active else { return }
        navigationWatchdog?.cancel()
        isLoading = false
        url = webView.url
        requestedURL = webView.url
        updateCurrentTitle()
        canGoBack = webView.canGoBack
        if isGoogleSignIn {
            statusText = "网页已打开。"
        } else {
            // Initial page loads may have emitted MIME-only discoveries before commit.
            refreshCandidates(resetHistory: false)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation, error: error)
    }

    private func navigationFailed(_ navigation: WKNavigation?, error: Error) {
        guard let active = provisionalNavigation, navigation === active else { return }
        navigationWatchdog?.cancel()
        provisionalNavigation = nil
        isLoading = false
        pendingDownload = nil
        candidates = []; alternateSources = [:]
        discoveryFrames = [:]; explicitlySelectedFrames = []; documentReferrerPolicies = [:]; partialResources = []
        // Never put a failing URL, query string or request headers in a saved/UI error.
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain {
            switch failure.code {
            case NSURLErrorCancelled: loadError = "网页加载已取消，可点重试。"
            case NSURLErrorBadURL, NSURLErrorUnsupportedURL:
                loadError = "这个网址无法打开，请检查地址后重试。"
            case NSURLErrorTimedOut: loadError = "网页连接超时，请重试。"
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                loadError = "网络连接中断，请检查网络后重试。"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost:
                loadError = "暂时无法连接这个站点，请稍后重试。"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid:
                loadError = "无法建立安全连接，请检查设备时间或稍后重试。"
            default: loadError = "网页未能打开（错误 \(failure.code)），请重试。"
            }
        } else { loadError = "网页未能打开（错误 \(failure.code)），请重试。" }
        statusText = loadError!
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationWatchdog?.cancel()
        provisionalNavigation = nil
        committedPageURL = nil
        navigationToken = UUID().uuidString
        documentID = UUID()
        historyVisit = nil; historyTitleUpdate = nil
        candidates = []; alternateSources = [:]; pendingDownload = nil
        discoveryFrames = [:]; explicitlySelectedFrames = []; documentReferrerPolicies = [:]; partialResources = []
        isLoading = false
        loadError = "网页进程已结束，请重新加载。"
        statusText = loadError!
    }
}

extension BrowserModel: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView === self.webView, navigationAction.targetFrame == nil,
              popup == nil, hasCurrentDocument,
              BrowserPopup.allowsNavigation(navigationAction.request.url) else { return nil }
        let origin = navigationAction.sourceFrame.securityOrigin
        guard ["http", "https"].contains(origin.protocol.lowercased()), !origin.host.isEmpty else { return nil }
        // WebKit must create the actual child window to retain POST bodies,
        // window.opener and the site's message channel. Do not replay its request.
        let child = BrowserPopup(configuration: configuration, initialURL: navigationAction.request.url) { [weak self] in
            self?.closePopup()
        }
        popup = child
        return child.webView
    }
}

@MainActor
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserModel?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}
