import Foundation

struct MediaVariant: Identifiable, Equatable {
    var id: String { url.absoluteString }
    let url: URL
    let label: String
    let bandwidth: Int?
    let resolution: String?
    var audioGroupID: String? = nil
}

struct MediaInspection: Equatable {
    let summary: String
    let variants: [MediaVariant]
    let audioTracks: [String]
    let expectedBytes: Int64?
    let downloadable: Bool
    var expectedDuration: Double? = nil
    var webSessionRetryAllowed: Bool = false
    var hlsDownloadURL: URL? = nil
    var requiresForeground = false
}

enum HLSPlaylistStage: String {
    case main = "主清单", variant = "画质清单", audio = "音轨清单"
}

enum HLSPlaylistProblem {
    case invalid, live, nested, protectedContent, missingAudioGroup, network(Int)
}

enum DownloadIssue: LocalizedError {
    case invalidURL, http(Int), protectedContent, unsupported(String), invalidMedia, incompleteMedia, oversizedManifest
    case playlistHTTP(HLSPlaylistStage, Int), playlistProblem(HLSPlaylistStage, HLSPlaylistProblem)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "视频地址无效，请回到网页重新识别。"
        case .http(401): return "服务器要求登录（HTTP 401）。请在网页中登录后重新选择视频。"
        case .http(403): return "服务器拒绝了视频请求（HTTP 403）。可尝试在网页播放以刷新链接，但仍可能无法下载。"
        case .http(404): return "服务器找不到此视频（HTTP 404）。请回到网页重新选择视频。"
        case .http(410): return "链接已过期（HTTP 410），请回到网页重新播放。"
        case .http(429): return "请求过于频繁（HTTP 429），请稍后重试。"
        case .http(let status): return "服务器返回 HTTP \(status)，请稍后重试。"
        case .playlistHTTP(let stage, let status):
            return "\(stage.rawValue)请求失败（HTTP \(status)）。可尝试在网页播放以刷新链接，但仍可能无法下载。"
        case .playlistProblem(let stage, let problem):
            switch problem {
            case .invalid: return "\(stage.rawValue)内容无效或格式不受支持，暂不能离线保存。"
            case .live: return "\(stage.rawValue)尚未结束，暂不能完整离线保存。"
            case .nested: return "\(stage.rawValue)包含嵌套清单，暂不支持离线保存。"
            case .protectedContent: return "\(stage.rawValue)含加密或受保护内容，暂不支持离线保存。"
            case .missingAudioGroup: return "画质清单引用的音轨组缺失，暂不能完整离线保存。"
            case .network(let code): return "\(stage.rawValue)连接失败（错误 \(code)），请检查网络后重试。"
            }
        case .protectedContent: return "检测到加密或受保护内容，暂不支持离线保存。仍可浏览和收藏网页。"
        case .unsupported(let reason): return reason
        case .invalidMedia: return "文件无法作为视频播放，未标记为下载完成。请回到网页重新识别。"
        case .incompleteMedia: return "下载内容不完整，未标记为完成。请重试。"
        case .oversizedManifest: return "播放清单过大或格式不受支持。仍可浏览和收藏网页。"
        }
    }
}

/// Only cookies eligible for the first media request enter the transfer's scope.
/// Each subsequent request rechecks domain, path, expiry and transport security.
enum MediaCookiePolicy {
    static func validHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return url.absoluteString.utf8.count <= 16_384
    }
    static func matching(_ cookies: [HTTPCookie], for url: URL, now: Date = Date()) -> [HTTPCookie] {
        guard validHTTPURL(url), let host = url.host?.lowercased() else { return [] }
        let requestPath = url.path.isEmpty ? "/" : url.path
        return cookies.filter { cookie in
            if cookie.isSecure && url.scheme?.lowercased() != "https" { return false }
            if let expiry = cookie.expiresDate, expiry <= now { return false }
            let domain = cookie.domain.lowercased()
            let domainMatches = domain.hasPrefix(".")
                ? (host == String(domain.dropFirst()) || host.hasSuffix(domain))
                : host == domain
            let path = cookie.path.isEmpty ? "/" : cookie.path
            let pathMatches = requestPath == path || (requestPath.hasPrefix(path) &&
                (path.hasSuffix("/") || requestPath.dropFirst(path.count).hasPrefix("/")))
            return domainMatches && pathMatches
        }
    }
    static func validUserAgent(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 1_024,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }
    static func request(url: URL, cookies: [HTTPCookie], pageURL: URL? = nil, method: String = "GET", userAgent: String? = nil,
                        context: MediaRequestContext? = nil) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        let context = context ?? MediaRequestContext(corsMode: .none, referrerPolicy: .strictOriginWhenCrossOrigin)
        let allowsCookies = pageURL.map { context.allowsCookies(for: url, frameURL: $0) } ?? (context.corsMode != .anonymous)
        let selected = allowsCookies ? matching(cookies, for: url) : []
        if !selected.isEmpty {
            request.setValue(HTTPCookie.requestHeaderFields(with: selected)["Cookie"], forHTTPHeaderField: "Cookie")
        }
        if let userAgent = validUserAgent(userAgent) { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        // Use the video's owning frame and observed policy, never arbitrary headers
        // from page scripts. Context also keeps page queries and fragments private.
        if let pageURL, validHTTPURL(pageURL) {
            request.setValue(context.referrer(from: pageURL, to: url), forHTTPHeaderField: "Referer")
            if context.corsMode != .none {
                request.setValue(MediaRequestContext.origin(of: pageURL), forHTTPHeaderField: "Origin")
            }
        }
        return request
    }
}

enum MediaFileResponse {
    static func isWebPage(_ response: HTTPURLResponse) -> Bool {
        let type = response.mimeType?.lowercased() ?? ""
        return type == "text/html" || type == "application/xhtml+xml" || type == "application/json" || type.hasSuffix("+json")
    }
    static func expectedBytes(_ response: HTTPURLResponse) -> Int64? {
        // Content-Length on a 206 response describes only the returned range.
        if response.statusCode == 206 {
            guard let range = response.value(forHTTPHeaderField: "Content-Range"),
                  range.lowercased().hasPrefix("bytes ") else { return nil }
            let parts = range.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let total = Int64(parts[1]), total > 0 else { return nil }
            let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
                  start >= 0, end >= start, total > end else { return nil }
            return total
        }
        return response.expectedContentLength > 0 ? response.expectedContentLength : nil
    }
}

struct HLSManifest {
    struct AudioTrack: Equatable {
        let name: String
        let language: String?
        let url: URL?
        var groupID: String? = nil
    }
    let variants: [MediaVariant]
    let audioTracks: [AudioTrack]
    let encrypted: Bool
    let isMaster: Bool
    let isVOD: Bool
    let duration: Double

    static func parse(_ text: String, relativeTo baseURL: URL) throws -> HLSManifest {
        guard text.utf8.count <= 2_000_000,
              text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { throw DownloadIssue.oversizedManifest }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var variants: [MediaVariant] = [], audio: [AudioTrack] = []
        var pending: [String: String]?, encrypted = false, duration: Double = 0
        for line in lines {
            if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
                let values = attributes(String(line.split(separator: ":", maxSplits: 1).last ?? ""))
                if values["METHOD"]?.uppercased() != "NONE" { encrypted = true }
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let values = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                if values["TYPE"] == "AUDIO" {
                    let url = values["URI"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
                    if let url, !MediaCookiePolicy.validHTTPURL(url) { throw DownloadIssue.invalidURL }
                    guard audio.count < 16 else { throw DownloadIssue.unsupported("播放清单包含超过 16 条音轨，当前版本暂不支持离线保存。") }
                    audio.append(AudioTrack(name: values["NAME"] ?? values["LANGUAGE"] ?? "音轨", language: values["LANGUAGE"], url: url, groupID: values["GROUP-ID"]))
                }
            } else if line.hasPrefix("#EXTINF:") {
                duration += Double(line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "") ?? 0
            } else if !line.isEmpty && !line.hasPrefix("#"), let values = pending {
                guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL, MediaCookiePolicy.validHTTPURL(url) else { throw DownloadIssue.invalidURL }
                let resolution = values["RESOLUTION"]
                let bandwidth = Int(values["BANDWIDTH"] ?? "")
                let label = resolution ?? bandwidth.map { "\($0 / 1_000) kbps" } ?? "默认画质"
                guard variants.count < 12 else { throw DownloadIssue.unsupported("播放清单包含超过 12 种画质，当前版本暂不支持离线保存。") }
                variants.append(MediaVariant(url: url, label: label, bandwidth: bandwidth, resolution: resolution, audioGroupID: values["AUDIO"]))
                pending = nil
            } else if !line.isEmpty && !line.hasPrefix("#") {
                guard let segment = URL(string: line, relativeTo: baseURL)?.absoluteURL,
                      MediaCookiePolicy.validHTTPURL(segment) else { throw DownloadIssue.invalidURL }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let values = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let raw = values["URI"] {
                    guard let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
                          MediaCookiePolicy.validHTTPURL(url) else { throw DownloadIssue.invalidURL }
                }
            }
        }
        return HLSManifest(variants: variants, audioTracks: audio, encrypted: encrypted,
                           isMaster: !variants.isEmpty, isVOD: lines.contains("#EXT-X-ENDLIST"), duration: duration)
    }

    static func attributes(_ source: String) -> [String: String] {
        var parts: [String] = [], current = "", quoted = false
        for character in source {
            if character == "\"" { quoted.toggle(); current.append(character) }
            else if character == "," && !quoted { parts.append(current); current = "" }
            else { current.append(character) }
        }
        parts.append(current)
        return parts.reduce(into: [:]) { result, entry in
            let pair = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return }
            result[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
    }
}

/// A rejected alternative must not invalidate a complete, unprotected rendition.
/// The original master is handed to AVFoundation only when every selectable branch
/// has passed inspection; otherwise only a self-contained media playlist is used.
enum HLSPreflight {
    typealias Loader = (URL) async throws -> (HLSManifest, URL)
    private struct Branch {
        let variant: MediaVariant
        let duration: Double
        let audio: [HLSManifest.AudioTrack]
        var hasExternalAudio: Bool { audio.contains { $0.url != nil } }
    }

    static func inspect(_ url: URL, load: Loader) async throws -> MediaInspection {
        let (manifest, effectiveURL) = try await playlist(url, stage: .main, load: load)
        guard !manifest.encrypted else { throw DownloadIssue.playlistProblem(.main, .protectedContent) }
        if !manifest.isMaster {
            try validateMedia(manifest, stage: .main)
            return MediaInspection(summary: "HLS 点播 · 默认画质 · 大小待下载后确认", variants: [],
                audioTracks: [], expectedBytes: nil, downloadable: true, expectedDuration: manifest.duration,
                hlsDownloadURL: effectiveURL)
        }

        var branches: [Branch] = []
        var failures: [Error] = []
        // Shared audio groups are inspected once, without retrying a rejected request
        // for every quality that references the same group.
        var audioResults: [URL: Result<HLSManifest, Error>] = [:]
        for variant in manifest.variants {
            try Task.checkCancellation()
            do {
                let (child, _) = try await playlist(variant.url, stage: .variant, load: load)
                try validateMedia(child, stage: .variant)
                let audio = variant.audioGroupID.map { group in manifest.audioTracks.filter { $0.groupID == group } } ?? []
                if variant.audioGroupID != nil, audio.isEmpty {
                    throw DownloadIssue.playlistProblem(.audio, .missingAudioGroup)
                }
                for track in audio {
                    guard let audioURL = track.url else { continue }
                    if audioResults[audioURL] == nil {
                        do {
                            let (audioManifest, _) = try await playlist(audioURL, stage: .audio, load: load)
                            try validateMedia(audioManifest, stage: .audio)
                            audioResults[audioURL] = .success(audioManifest)
                        } catch { audioResults[audioURL] = .failure(error) }
                    }
                    _ = try audioResults[audioURL]?.get()
                }
                branches.append(Branch(variant: variant, duration: child.duration, audio: audio))
            } catch {
                try Task.checkCancellation()
                failures.append(error)
            }
        }
        guard !branches.isEmpty else { throw failures.first ?? DownloadIssue.playlistProblem(.main, .invalid) }

        let usesMaster = failures.isEmpty && branches.contains { $0.hasExternalAudio }
        let available = usesMaster ? branches : branches.filter { !$0.hasExternalAudio }
        // A bare video-only playlist would drop its external audio. A partially
        // checked master could silently choose the branch that failed inspection.
        guard !available.isEmpty else { throw failures.first ?? DownloadIssue.playlistProblem(.main, .invalid) }
        let availableURLs = Set(available.map { $0.variant.url })
        let unavailableCount = manifest.variants.filter { !availableURLs.contains($0.url) }.count
        let unavailableNote = unavailableCount > 0 ? " · 另有 \(unavailableCount) 种画质不可用" : ""
        let audioNote = usesMaster ? " · 系统选择画质并保留独立音轨" : ""
        let audioNames = available.flatMap(\.audio).map(\.name).reduce(into: [String]()) { names, name in
            if !names.contains(name) { names.append(name) }
        }
        let selected = available[0]
        // A leaf's duration belongs to that exact rendition. When AVFoundation
        // receives the master, no single duration describes differing renditions;
        // only a duration shared by every selectable branch is authoritative.
        let expectedDuration = !usesMaster || available.allSatisfy { $0.duration == selected.duration }
            ? selected.duration : nil
        return MediaInspection(summary: "HLS 点播 · \(available.count) 种可用画质 · 大小待下载后确认\(unavailableNote)\(audioNote)",
            variants: usesMaster ? [] : available.map(\.variant), audioTracks: audioNames, expectedBytes: nil,
            downloadable: true, expectedDuration: expectedDuration,
            hlsDownloadURL: usesMaster ? effectiveURL : selected.variant.url)
    }

    private static func playlist(_ url: URL, stage: HLSPlaylistStage, load: Loader) async throws -> (HLSManifest, URL) {
        do { return try await load(url) }
        catch {
            try Task.checkCancellation()
            if let issue = error as? DownloadIssue {
                switch issue {
                case .http(let status): throw DownloadIssue.playlistHTTP(stage, status)
                case .protectedContent: throw DownloadIssue.playlistProblem(stage, .protectedContent)
                case .playlistHTTP, .playlistProblem: throw issue
                default: throw DownloadIssue.playlistProblem(stage, .invalid)
                }
            }
            throw DownloadIssue.playlistProblem(stage, .network((error as NSError).code))
        }
    }

    private static func validateMedia(_ manifest: HLSManifest, stage: HLSPlaylistStage) throws {
        guard !manifest.encrypted else { throw DownloadIssue.playlistProblem(stage, .protectedContent) }
        guard !manifest.isMaster else { throw DownloadIssue.playlistProblem(stage, .nested) }
        guard manifest.isVOD else { throw DownloadIssue.playlistProblem(stage, .live) }
        guard manifest.duration.isFinite, manifest.duration > 0 else { throw DownloadIssue.playlistProblem(stage, .invalid) }
    }
}

/// Foreground preflight redirects can be checked. No shared cookie or credential store is used.
final class MediaHTTPClient: NSObject, URLSessionTaskDelegate {
    let cookies: [HTTPCookie]
    let pageURL: URL
    let userAgent: String?
    let requestContext: MediaRequestContext?
    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    init(candidate: MediaCandidate, cookies: [HTTPCookie]) {
        let allowsCookies = candidate.requestContext?.allowsCookies(for: candidate.url, frameURL: candidate.frameURL) ?? true
        self.cookies = allowsCookies ? MediaCookiePolicy.matching(cookies, for: candidate.url) : []
        pageURL = candidate.frameURL
        userAgent = MediaCookiePolicy.validUserAgent(candidate.userAgent)
        requestContext = candidate.requestContext
    }
    func close() { session.invalidateAndCancel() }
    func request(_ url: URL, method: String = "GET") -> URLRequest {
        MediaCookiePolicy.request(url: url, cookies: cookies, pageURL: pageURL, method: method, userAgent: userAgent,
            context: requestContext)
    }
    func fileMetadata(_ url: URL) async throws -> Int64? {
        guard MediaCookiePolicy.validHTTPURL(url) else { throw DownloadIssue.invalidURL }
        let head = try await headers(url, method: "HEAD")
        if (200...299).contains(head.statusCode), ![204, 205].contains(head.statusCode), !MediaFileResponse.isWebPage(head) {
            return MediaFileResponse.expectedBytes(head)
        }
        // Some signed URLs and media endpoints allow GET but reject HEAD. A single
        // bounded GET checks the same method used by playback instead of guessing expiry.
        // Do not immediately repeat rate-limited or temporarily unavailable requests.
        guard head.statusCode != 429, head.statusCode != 503 else { throw DownloadIssue.http(head.statusCode) }
        var response = try await headers(url, method: "GET", range: "bytes=0-0")
        if response.statusCode == 416 { response = try await headers(url, method: "GET") }
        guard (200...299).contains(response.statusCode) else { throw DownloadIssue.http(response.statusCode) }
        guard ![204, 205].contains(response.statusCode) else { throw DownloadIssue.invalidMedia }
        guard !MediaFileResponse.isWebPage(response) else {
            throw DownloadIssue.unsupported("服务器返回了网页或登录页，没有返回视频。请在网页完成登录或验证后重试。")
        }
        return MediaFileResponse.expectedBytes(response)
    }
    private func headers(_ url: URL, method: String, range: String? = nil) async throws -> HTTPURLResponse {
        var request = request(url, method: method)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        // Servers may ignore Range. Stop immediately after headers in either case;
        // inspecting a candidate must not read the full video into memory.
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else { throw DownloadIssue.invalidMedia }
        return http
    }
    func playlist(_ url: URL) async throws -> (HLSManifest, URL) {
        guard MediaCookiePolicy.validHTTPURL(url) else { throw DownloadIssue.invalidURL }
        let (bytes, response) = try await session.bytes(for: request(url))
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DownloadIssue.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard response.expectedContentLength <= 2_000_000 else { throw DownloadIssue.oversizedManifest }
        var data = Data()
        for try await byte in bytes { data.append(byte); if data.count > 2_000_000 { throw DownloadIssue.oversizedManifest } }
        guard let text = String(data: data, encoding: .utf8) else { throw DownloadIssue.oversizedManifest }
        let effectiveURL = response.url ?? url
        return (try HLSManifest.parse(text, relativeTo: effectiveURL), effectiveURL)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, MediaCookiePolicy.validHTTPURL(url),
              !(response.url?.scheme == "https" && url.scheme == "http") else { completionHandler(nil); return }
        var redirected = self.request(url, method: request.httpMethod ?? "GET")
        if let range = request.value(forHTTPHeaderField: "Range") { redirected.setValue(range, forHTTPHeaderField: "Range") }
        completionHandler(redirected)
    }
}

/// AVFoundation's file URL may contain kernel path forms such as .nofollow.
/// Resolve a copy only for containment checks; persist the original relative
/// spelling and its container-root form for subsequent app launches. A system
/// alias outside that root stays opaque and is checked again when restored.
enum HLSLocalAssetLocation {
    private static let originalPrefix = "system-original/"
    private static let absolutePrefix = originalPrefix + "absolute/"
    private static let bookmarkPrefix = originalPrefix + "bookmark/"
    private struct BookmarkedLocation: Codable {
        let originalURL: String
        let bookmark: Data
    }
    private enum RootForm: String {
        case raw, resolved, rawNoFollow = "raw-nofollow", resolvedNoFollow = "resolved-nofollow"
        var noFollow: Bool { self == .rawNoFollow || self == .resolvedNoFollow }
        var usesResolvedHome: Bool { self == .resolved || self == .resolvedNoFollow }
    }

    static func isSystemPath(_ value: String) -> Bool {
        value.hasPrefix(originalPrefix) || value.hasPrefix("system/") || value.hasPrefix("system-nofollow/")
    }

    static func relativePath(for location: URL, home: URL) -> String? {
        guard location.absoluteString.utf8.count <= 16_384, isContained(location, home: home),
              let components = URLComponents(url: location, resolvingAgainstBaseURL: false) else { return nil }
        if FileManager.default.fileExists(atPath: location.path),
           let bookmark = try? location.bookmarkData(options: .withoutImplicitSecurityScope,
               includingResourceValuesForKeys: nil, relativeTo: nil), bookmark.count <= 65_536,
           restoredBookmark(bookmark, home: home) != nil,
           let payload = try? JSONEncoder().encode(BookmarkedLocation(originalURL: location.absoluteString, bookmark: bookmark)) {
            return bookmarkPrefix + payload.base64EncodedString()
        }
        let path = location.path
        let noFollow = path.hasPrefix("/.nofollow/")
        let scopedPath = noFollow ? String(path.dropFirst("/.nofollow".count)) : path
        let rawHome = rootPath(home)
        let resolvedHome = rootPath(home.resolvingSymlinksInPath().standardizedFileURL)
        let form: RootForm, selectedRoot: String
        if scopedPath.hasPrefix(rawHome + "/") {
            form = noFollow ? .rawNoFollow : .raw; selectedRoot = rawHome
        } else if scopedPath.hasPrefix(resolvedHome + "/") {
            form = noFollow ? .resolvedNoFollow : .resolved; selectedRoot = resolvedHome
        } else { return absolutePrefix + Data(location.absoluteString.utf8).base64EncodedString() }
        let encodedRoot = URLComponents(url: URL(fileURLWithPath: selectedRoot, isDirectory: true), resolvingAgainstBaseURL: false)!.percentEncodedPath
        let encodedPrefix = (noFollow ? "/.nofollow" : "") + encodedRoot
        guard components.percentEncodedPath.hasPrefix(encodedPrefix) else { return nil }
        let relative = String(components.percentEncodedPath.dropFirst(encodedPrefix.count))
        guard !relative.isEmpty else { return nil }
        return originalPrefix + form.rawValue + "/" + relative
    }
    static func url(for relativePath: String, home: URL) -> URL? {
        if relativePath.hasPrefix(bookmarkPrefix) {
            let encoded = String(relativePath.dropFirst(bookmarkPrefix.count))
            guard encoded.utf8.count <= 196_608, let data = Data(base64Encoded: encoded), data.count <= 131_072,
                  let saved = try? JSONDecoder().decode(BookmarkedLocation.self, from: data),
                  saved.originalURL.utf8.count <= 16_384, saved.bookmark.count <= 65_536 else { return nil }
            // Keep the exact callback URL while it is usable. Foundation can
            // relocate its bookmark when an app update changes the container.
            if let original = URL(string: saved.originalURL), isContained(original, home: home),
               FileManager.default.fileExists(atPath: original.path) { return original }
            return restoredBookmark(saved.bookmark, home: home)
        }
        if relativePath.hasPrefix(absolutePrefix) {
            let encoded = String(relativePath.dropFirst(absolutePrefix.count))
            guard encoded.utf8.count <= 24_000, let data = Data(base64Encoded: encoded), data.count <= 16_384,
                  let original = String(data: data, encoding: .utf8), let restored = URL(string: original),
                  isContained(restored, home: home) else { return nil }
            return restored
        }
        if relativePath.hasPrefix(originalPrefix) {
            let value = relativePath.dropFirst(originalPrefix.count)
            guard let separator = value.firstIndex(of: "/"),
                  let form = RootForm(rawValue: String(value[..<separator])) else { return nil }
            let relative = String(value[value.index(after: separator)...])
            guard !relative.isEmpty, !relative.hasPrefix("/"), relative.utf8.count <= 16_384 else { return nil }
            let selectedHome = form.usesResolvedHome ? home.resolvingSymlinksInPath().standardizedFileURL : home
            let encodedRoot = URLComponents(url: URL(fileURLWithPath: rootPath(selectedHome), isDirectory: true), resolvingAgainstBaseURL: false)!.percentEncodedPath
            let path = (form.noFollow ? "/.nofollow" : "") + encodedRoot + relative
            guard let components = URLComponents(string: "file://" + path), components.percentEncodedPath == path,
                  let restored = components.url, isContained(restored, home: home) else { return nil }
            return restored
        }
        // Older libraries saved a resolved relative path. Keep that format
        // readable while all newly captured locations use their original form.
        let noFollow = relativePath.hasPrefix("system-nofollow/")
        let prefix = noFollow ? "system-nofollow/" : "system/"
        guard relativePath.hasPrefix(prefix) else { return nil }
        let resolvedHome = home.resolvingSymlinksInPath().standardizedFileURL
        let relative = String(relativePath.dropFirst(prefix.count))
        let isDirectory = relative.hasSuffix("/")
        let plain = resolvedHome.appendingPathComponent(relative, isDirectory: isDirectory).standardizedFileURL
        let scoped = plain.resolvingSymlinksInPath().standardizedFileURL
        guard plain.path.hasPrefix(resolvedHome.path + "/"), plain.pathExtension == "movpkg",
              scoped.path.hasPrefix(resolvedHome.path + "/"), scoped.pathExtension == "movpkg" else { return nil }
        return noFollow ? URL(fileURLWithPath: "/.nofollow" + plain.path, isDirectory: isDirectory) : plain
    }

    private static func restoredBookmark(_ bookmark: Data, home: URL) -> URL? {
        var stale = false
        guard let restored = try? URL(resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing],
            relativeTo: nil, bookmarkDataIsStale: &stale),
            isContained(restored, home: home), FileManager.default.fileExists(atPath: restored.path) else { return nil }
        return restored
    }

    private static func rootPath(_ url: URL) -> String {
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func isContained(_ location: URL, home: URL) -> Bool {
        guard location.isFileURL, location.user == nil, location.password == nil, location.query == nil, location.fragment == nil,
              location.host == nil || location.host == "" || location.host == "localhost" else { return false }
        let path = location.path
        let scopedPath = path.hasPrefix("/.nofollow/") ? String(path.dropFirst("/.nofollow".count)) : path
        let resolved = URL(fileURLWithPath: scopedPath).resolvingSymlinksInPath().standardizedFileURL
        let resolvedHome = rootPath(home.resolvingSymlinksInPath().standardizedFileURL)
        return resolved.path.hasPrefix(resolvedHome + "/") && resolved.pathExtension == "movpkg"
    }
}
