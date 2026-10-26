import Foundation

/// Small, non-secret properties of the video's owning document. Captured in
/// WebKit's isolated world; never accepted as arbitrary page-supplied headers.
struct MediaRequestContext: Codable, Equatable {
    enum CORSMode: String, Codable { case none, anonymous, useCredentials }
    enum ReferrerPolicy: String, Codable {
        case noReferrer = "no-referrer"
        case noReferrerWhenDowngrade = "no-referrer-when-downgrade"
        case origin, sameOrigin = "same-origin", strictOrigin = "strict-origin"
        case originWhenCrossOrigin = "origin-when-cross-origin"
        case strictOriginWhenCrossOrigin = "strict-origin-when-cross-origin"
        case unsafeURL = "unsafe-url"

        static func parse(_ value: String?) -> Self? {
            value?.split(separator: ",").reversed().compactMap {
                Self(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }.first
        }
    }

    let corsMode: CORSMode
    let referrerPolicy: ReferrerPolicy

    static func origin(of url: URL) -> String? {
        guard MediaCookiePolicy.validHTTPURL(url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = ""; parts.query = nil; parts.fragment = nil
        if (parts.scheme?.lowercased() == "https" && parts.port == 443) ||
            (parts.scheme?.lowercased() == "http" && parts.port == 80) { parts.port = nil }
        return parts.string
    }

    func allowsCookies(for target: URL, frameURL: URL) -> Bool {
        corsMode != .anonymous || MediaMessageValidator.sameOrigin(target, frameURL)
    }

    func referrer(from frame: URL, to target: URL) -> String? {
        guard MediaCookiePolicy.validHTTPURL(frame), MediaCookiePolicy.validHTTPURL(target),
              var parts = URLComponents(url: frame, resolvingAgainstBaseURL: false) else { return nil }
        let sameOrigin = MediaMessageValidator.sameOrigin(frame, target)
        let downgrade = frame.scheme?.lowercased() == "https" && target.scheme?.lowercased() == "http"
        // Retain the existing credential boundary even for unsafe-url: page
        // queries/fragments are not copied into media requests or persisted headers.
        parts.query = nil; parts.fragment = nil
        switch referrerPolicy {
        case .noReferrer: return nil
        case .sameOrigin where !sameOrigin: return nil
        case .strictOrigin, .strictOriginWhenCrossOrigin, .noReferrerWhenDowngrade:
            if downgrade { return nil }
        default: break
        }
        switch referrerPolicy {
        case .origin, .strictOrigin: parts.path = "/"
        case .originWhenCrossOrigin, .strictOriginWhenCrossOrigin:
            if !sameOrigin || parts.path.isEmpty { parts.path = "/" }
        default: if parts.path.isEmpty { parts.path = "/" }
        }
        return parts.string
    }
}
