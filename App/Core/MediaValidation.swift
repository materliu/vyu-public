import Foundation

/// Data supplied by WebKit, never by the page's JavaScript message body.
struct DiscoveryMessageContext {
    let navigationToken: String
    let pageURL: URL
    let frameRequestURL: URL?
    let originScheme: String
    let originHost: String
    let originPort: Int
}

enum DiscoverySignal: Equatable { case mediaSource, protectedContent }
enum InlineDownloadIssue: Equatable { case mediaSource, protectedContent, noSource }

enum ValidatedDiscoveryMessage: Equatable {
    case candidate(MediaCandidate)
    // The page already supplied both representations in one video_info object.
    // This is still untrusted metadata; native UI must confirm a selected file.
    case alternative(MediaCandidate, relatedURL: URL)
    // A readable HLS response identified an initialization/segment resource.
    // Suppression stays within this validated frame and navigation generation.
    case partialResource(MediaCandidate.ID)
    // The page is not an authorization boundary. Native UI must confirm this one
    // candidate before a download starts, even when the script checked isTrusted.
    case downloadRequested(MediaCandidate)
    case downloadUnavailable(InlineDownloadIssue)
    case signal(DiscoverySignal)
}

enum DiscoveryValidationError: Error, Equatable {
    case malformed, oversized, staleNavigation, invalidURL, originMismatch, unsupportedMedia
}

enum MediaMessageValidator {
    static let maximumMessageBytes = 24_576
    private static let allowedSources: Set<String> = ["video", "source", "performance", "fetch", "xhr", "encrypted"]

    static func validate(_ body: Any, context: DiscoveryMessageContext) throws -> ValidatedDiscoveryMessage {
        guard let fields = body as? [String: Any], fields.count <= 8,
              fields.keys.allSatisfy({ ["token", "documentURL", "event", "url", "title", "source", "mime", "relatedURL"].contains($0) }),
              fields.values.allSatisfy({ $0 is String }), JSONSerialization.isValidJSONObject(fields) else {
            throw DiscoveryValidationError.malformed
        }
        guard let data = try? JSONSerialization.data(withJSONObject: fields), data.count <= maximumMessageBytes else {
            throw DiscoveryValidationError.oversized
        }
        guard let token = fields["token"] as? String, token.count <= 128,
              token == context.navigationToken else { throw DiscoveryValidationError.staleNavigation }
        guard let document = fields["documentURL"] as? String, document.utf8.count <= 8_192,
              let documentURL = networkURL(document), let requestURL = context.frameRequestURL,
              networkURL(requestURL.absoluteString) != nil, networkURL(context.pageURL.absoluteString) != nil else {
            throw DiscoveryValidationError.invalidURL
        }
        guard sameOrigin(documentURL, requestURL),
              origin(requestURL) == Origin(scheme: context.originScheme.lowercased(),
                                           host: context.originHost.lowercased(),
                                           port: normalizedPort(context.originPort, scheme: context.originScheme)) else {
            throw DiscoveryValidationError.originMismatch
        }
        guard let source = fields["source"] as? String,
              let event = fields["event"] as? String,
              (event == "alternative" ? source == "metadata" : allowedSources.contains(source)),
              let title = fields["title"] as? String, title.utf8.count <= 1_024,
              (fields["mime"] as? String)?.utf8.count ?? 0 <= 256 else { throw DiscoveryValidationError.malformed }
        if !["alternative", "partial"].contains(event), fields["relatedURL"] != nil { throw DiscoveryValidationError.malformed }
        if event == "mse" { return .signal(.mediaSource) }
        if event == "protected" { return .signal(.protectedContent) }
        let unavailableEvents: [String: InlineDownloadIssue] = [
            "download-mse": .mediaSource, "download-protected": .protectedContent, "download-unavailable": .noSource
        ]
        if let issue = unavailableEvents[event] {
            guard source == "video", fields["url"] as? String == "", fields["mime"] as? String == "" else {
                throw DiscoveryValidationError.malformed
            }
            return .downloadUnavailable(issue)
        }
        guard ["candidate", "download", "alternative", "partial"].contains(event),
              let value = fields["url"] as? String, value.utf8.count <= 8_192,
              let mediaURL = networkURL(value) else { throw DiscoveryValidationError.invalidURL }
        // A request must refer to that element's source, never an arbitrary fetch
        // or performance entry from elsewhere on a page with multiple videos.
        if event == "download", !["video", "source"].contains(source) {
            throw DiscoveryValidationError.malformed
        }
        let mime = (fields["mime"] as? String)?.lowercased().split(separator: ";").first.map(String.init)
        if event == "partial" {
            guard ["fetch", "xhr"].contains(source), let relatedValue = fields["relatedURL"] as? String,
                  let relatedURL = networkURL(relatedValue),
                  relatedURL.pathExtension.lowercased() == "m3u8" ||
                    ["application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl"].contains(mime ?? "") else {
                throw DiscoveryValidationError.malformed
            }
            return .partialResource(MediaCandidate.ID(url: mediaURL, pageURL: context.pageURL, frameURL: requestURL))
        }
        if event == "alternative" {
            guard let relatedValue = fields["relatedURL"] as? String,
                  let relatedURL = networkURL(relatedValue) else { throw DiscoveryValidationError.invalidURL }
            guard relatedURL.pathExtension.lowercased() == "m3u8", mime == "video/mp4",
                  ["", "mp4"].contains(mediaURL.pathExtension.lowercased()) else {
                throw DiscoveryValidationError.unsupportedMedia
            }
            let candidate = MediaCandidate(url: mediaURL, pageURL: context.pageURL, frameURL: requestURL,
                                           title: title, kind: .file, source: source, mimeType: mime)
            return .alternative(candidate, relatedURL: relatedURL)
        }
        guard let kind = classify(mediaURL, mime: mime, source: source) else {
            throw DiscoveryValidationError.unsupportedMedia
        }
        let candidate = MediaCandidate(url: mediaURL, pageURL: context.pageURL, frameURL: requestURL,
                                       title: title, kind: kind, source: source, mimeType: mime)
        return event == "download" ? .downloadRequested(candidate) : .candidate(candidate)
    }

    static func networkURL(_ value: String) -> URL? {
        guard value.utf8.count <= 8_192, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil || (1...65_535).contains(url.port!) else { return nil }
        return url
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool { origin(lhs) == origin(rhs) }

    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int
    }

    private static func normalizedPort(_ port: Int?, scheme: String) -> Int {
        if let port, port > 0 { return port }
        return scheme.lowercased() == "https" ? 443 : 80
    }

    private static func origin(_ url: URL) -> Origin {
        let scheme = url.scheme?.lowercased() ?? ""
        return Origin(scheme: scheme, host: url.host?.lowercased() ?? "", port: normalizedPort(url.port, scheme: scheme))
    }

    private static func classify(_ url: URL, mime: String?, source: String) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if ["m4s", "cmfv", "cmfa", "ts"].contains(ext) { return nil }
        if ext == "m3u8" || ["application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl"].contains(mime ?? "") { return .hls }
        if ext == "mpd" || mime == "application/dash+xml" { return .dash }
        if ["mp4", "mov", "m4v", "webm"].contains(ext) || mime?.hasPrefix("video/") == true { return .file }
        // A video element may use a signed, extensionless endpoint. Resource requests
        // need a media extension or response MIME to avoid treating every URL as media.
        if ["video", "source"].contains(source), mime == nil || mime == "" { return .file }
        return nil
    }
}
