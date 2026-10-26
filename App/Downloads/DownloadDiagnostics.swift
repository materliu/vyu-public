import AVFoundation
import Foundation

/// A bounded local diagnostic record, deliberately independent of download metadata.
/// Never add URLs, titles, headers, descriptions, or NSError.userInfo to this schema.
@MainActor
final class DownloadDiagnostics {
    enum Stage: String, Codable {
        case inspection, transfer, assetMetadata, offlineCache, mediaSelection, playerPreparation, preroll, tracks, sampleRead, complete
    }

    struct Failure: Codable, Equatable {
        let domain: String
        let code: Int
        let issue: String?
        let underlying: [Failure]
        let hlsPhase: HLSFileValidationFailure.Phase?
        let hlsCheck: HLSFileValidationFailure.Check?
        let observed: Double?
        let expected: Double?
        let timelineStart: Double?
        let timelineEnd: Double?

        init(_ error: Error, depth: Int = 0) {
            if let failure = error as? HLSFileValidationFailure {
                domain = "VYuHLSValidation"; code = failure.check.rawValue; issue = "incomplete-media"
                hlsPhase = failure.phase; hlsCheck = failure.check
                observed = failure.observed; expected = failure.expected; underlying = []
                timelineStart = failure.timelineStart; timelineEnd = failure.timelineEnd
                return
            }
            hlsPhase = nil; hlsCheck = nil; observed = nil; expected = nil; timelineStart = nil; timelineEnd = nil
            let nsError = error as NSError
            let allowedDomains = [NSURLErrorDomain, AVFoundationErrorDomain, NSOSStatusErrorDomain,
                                  NSPOSIXErrorDomain, NSCocoaErrorDomain, "CoreMediaErrorDomain"]
            domain = allowedDomains.contains(nsError.domain) ? nsError.domain : "Other"
            code = nsError.code
            if let error = error as? DownloadIssue {
                switch error {
                case .invalidURL: issue = "invalid-url"
                case .http: issue = "http"
                case .protectedContent: issue = "protected-content"
                case .unsupported: issue = "unsupported"
                case .invalidMedia: issue = "invalid-media"
                case .incompleteMedia: issue = "incomplete-media"
                case .oversizedManifest: issue = "oversized-manifest"
                case .playlistHTTP: issue = "playlist-http"
                case .playlistProblem: issue = "playlist-problem"
                }
            } else if error is HLSRelayError { issue = "relay" }
            else { issue = nil }
            // Some system errors carry multiple underlying failures. Keep the
            // chain shallow and bounded, extracting only domains and codes.
            var errors: [Error] = []
            if depth < 3 {
                if let child = nsError.userInfo[NSUnderlyingErrorKey] as? Error { errors.append(child) }
                if let children = nsError.userInfo["NSMultipleUnderlyingErrors"] as? [Error] {
                    errors.append(contentsOf: children.prefix(3 - errors.count))
                }
            }
            underlying = errors.prefix(3).map { Failure($0, depth: depth + 1) }
        }
    }

    struct Entry: Codable, Equatable {
        let attempt: UUID
        let kind: MediaKind
        var stage: Stage
        var bytes: Int64 = 0
        var expectedDuration: Double?
        var duration: Double?
        var playable: Bool?
        var protectedContent: Bool?
        var playableOffline: Bool?
        var video: Bool?
        var audio: Bool?
        var failure: Failure?
    }

    static let maximumEntries = 32
    private(set) var entries: [Entry] = []
    private let fileURL: URL

    init(rootDirectory: URL) {
        fileURL = rootDirectory.appendingPathComponent("download-diagnostics.json")
        if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 131_072,
           let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = Array(saved.suffix(Self.maximumEntries))
        }
    }

    func start(token: String, kind: MediaKind, stage: Stage = .inspection) {
        guard let attempt = Self.attempt(token), !entries.contains(where: { $0.attempt == attempt }) else { return }
        entries.append(Entry(attempt: attempt, kind: kind, stage: stage))
        if entries.count > Self.maximumEntries { entries.removeFirst(entries.count - Self.maximumEntries) }
        persist()
    }

    func update(token: String, stage: Stage? = nil, bytes: Int64? = nil, expectedDuration: Double? = nil,
                duration: Double? = nil, playable: Bool? = nil, protectedContent: Bool? = nil,
                playableOffline: Bool? = nil, video: Bool? = nil, audio: Bool? = nil, error: Error? = nil) {
        guard let attempt = Self.attempt(token), let index = entries.firstIndex(where: { $0.attempt == attempt }) else { return }
        if let stage { entries[index].stage = stage }
        if let bytes { entries[index].bytes = max(0, bytes) }
        if let expectedDuration, expectedDuration.isFinite { entries[index].expectedDuration = expectedDuration }
        if let duration, duration.isFinite { entries[index].duration = duration }
        if let playable { entries[index].playable = playable }
        if let protectedContent { entries[index].protectedContent = protectedContent }
        if let playableOffline { entries[index].playableOffline = playableOffline }
        if let video { entries[index].video = video }
        if let audio { entries[index].audio = audio }
        if let error { entries[index].failure = Failure(error) }
        persist()
    }

    private static func attempt(_ token: String) -> UUID? {
        let parts = token.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    private func persist() {
        // Diagnostic writes must never change a download's result.
        guard let data = try? JSONEncoder().encode(entries), data.count <= 131_072 else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var url = fileURL; try? url.setResourceValues(values)
    }
}
