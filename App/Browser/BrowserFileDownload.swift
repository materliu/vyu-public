import Foundation
import WebKit

/// A foreground file transfer in the originating WebKit data store. WebKit manages
/// its cookies; credentials and resume data are never copied out of the browser.
@MainActor
final class BrowserFileDownload: NSObject, WKDownloadDelegate {
    let destination: URL
    let onProgress: (Int64, Int64) -> Void
    let onCompletion: (URL?, HTTPURLResponse?, Error?) -> Void
    private var download: WKDownload?
    private var response: HTTPURLResponse?
    private var observation: NSKeyValueObservation?
    private var finished = false
    private var redirects = 0
    private var sourceFrameURL: URL?
    private var requestContext: MediaRequestContext?

    init(destination: URL, onProgress: @escaping (Int64, Int64) -> Void,
         onCompletion: @escaping (URL?, HTTPURLResponse?, Error?) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
        self.onCompletion = onCompletion
    }

    func start(candidate: MediaCandidate, webView: WKWebView) {
        guard !finished, candidate.kind == .file,
              MediaMessageValidator.networkURL(candidate.url.absoluteString) != nil else {
            complete(error: DownloadIssue.invalidURL); return
        }
        var request = MediaCookiePolicy.request(url: candidate.url, cookies: [],
            pageURL: candidate.frameURL, userAgent: candidate.userAgent, context: candidate.requestContext)
        request.httpShouldHandleCookies = candidate.requestContext?.allowsCookies(for: candidate.url, frameURL: candidate.frameURL) ?? true
        request.mainDocumentURL = candidate.pageURL
        sourceFrameURL = candidate.frameURL
        requestContext = candidate.requestContext
        webView.startDownload(using: request) { [self] transfer in
            guard !finished else {
                transfer.cancel { [self] _ in try? FileManager.default.removeItem(at: destination) }
                return
            }
            download = transfer
            transfer.delegate = self
            observation = transfer.progress.observe(\.completedUnitCount, options: [.initial, .new]) { [weak self] progress, _ in
                let written = progress.completedUnitCount, expected = progress.totalUnitCount
                Task { @MainActor in
                    guard let self, !self.finished else { return }
                    self.onProgress(written, expected)
                }
            }
        }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        observation = nil
        // Keep the delegate alive until WebKit stops writing before removing the stage.
        download?.cancel { [self] _ in try? FileManager.default.removeItem(at: destination) }
        onCompletion(nil, response, URLError(.cancelled))
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard !finished else { completionHandler(nil); return }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(nil); complete(error: DownloadIssue.invalidMedia); return
        }
        self.response = http
        guard (200...299).contains(http.statusCode) else {
            completionHandler(nil); complete(error: DownloadIssue.http(http.statusCode)); return
        }
        guard !MediaFileResponse.isWebPage(http), let url = http.url,
              MediaMessageValidator.networkURL(url.absoluteString) != nil else {
            completionHandler(nil); complete(error: DownloadIssue.invalidMedia); return
        }
        // Ignore the untrusted suggested filename; only our UUID-named stage is writable.
        completionHandler(destination)
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        redirects += 1
        guard !finished, redirects <= 10, let url = request.url,
              MediaMessageValidator.networkURL(url.absoluteString) != nil,
              !(response.url?.scheme == "https" && url.scheme == "http") else {
            decisionHandler(.cancel); complete(error: DownloadIssue.invalidURL); return
        }
        if let sourceFrameURL, let requestContext,
           !requestContext.allowsCookies(for: url, frameURL: sourceFrameURL) {
            // WKDownload's redirect callback cannot replace its request. Do not
            // carry an enabled cookie policy into an anonymous cross-origin hop.
            decisionHandler(.cancel)
            complete(error: DownloadIssue.unsupported("此网页会话跳转需要重新检查请求上下文，请返回视频来源后重试。"))
            return
        }
        if let sourceFrameURL, !MediaMessageValidator.sameOrigin(sourceFrameURL, url),
           let referrer = request.value(forHTTPHeaderField: "Referer") {
            let permitted = MediaCookiePolicy.request(url: url, cookies: [], pageURL: sourceFrameURL, context: requestContext)
                .value(forHTTPHeaderField: "Referer")
            guard referrer == permitted else {
                decisionHandler(.cancel)
                complete(error: DownloadIssue.unsupported("网页会话跳转到了新的来源，请回到网页播放后重新选择视频。"))
                return
            }
        }
        decisionHandler(.allow)
    }

    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Standard system trust evaluation; no certificate exceptions or new credentials.
        completionHandler(.performDefaultHandling, nil)
    }

    func downloadDidFinish(_ download: WKDownload) { complete(error: nil) }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        complete(error: error)
    }

    private func complete(error: Error?) {
        guard !finished else { return }
        finished = true
        observation = nil
        download = nil
        if error != nil { try? FileManager.default.removeItem(at: destination) }
        onCompletion(error == nil ? destination : nil, response, error)
    }
}
