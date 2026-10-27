import Foundation

enum MediaKind: String, Codable { case file, hls, dash, blob, protected }

struct MediaCandidate: Identifiable, Codable, Equatable {
    struct ID: Hashable {
        let url: URL
        let pageURL: URL
        let frameURL: URL
    }
    // A shared CDN URL can appear in multiple frames with different request
    // contexts. Keep those candidates distinct in both discovery and selection.
    // This computed identity is not part of the persisted candidate schema.
    var id: ID { ID(url: url, pageURL: pageURL, frameURL: frameURL) }
    let url: URL
    let pageURL: URL
    let frameURL: URL
    let title: String
    let kind: MediaKind
    let source: String
    var mimeType: String?
    // Captured from WebKit's isolated world, never accepted from page messages.
    var userAgent: String? = nil
    var requestContext: MediaRequestContext? = nil
}

enum DownloadPhase: String, Codable {
    case queued, downloading, paused, validating, complete, failed, cancelled
}

struct DownloadRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let candidate: MediaCandidate
    var phase: DownloadPhase
    var progress: Double
    var bytesWritten: Int64
    var expectedBytes: Int64?
    var localRelativePath: String?
    var failure: String?
    var duration: Double?
    var hasAudio: Bool?
    var createdAt: Date
    /// A verified iCloud copy may be kept while its replaceable local file is evicted.
    var localCacheEvicted: Bool? = nil
}
