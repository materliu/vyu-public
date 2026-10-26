#if DEBUG
import Foundation

/// Available only to isolated UI tests. Real download APIs create every state;
/// the completed row contains a fully validated, locally generated video.
enum OfflineBatchFixture {
    enum Failure: Error { case invalidFixture, unexpectedState, timedOut }

    static func baseURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme == "http",
              ["127.0.0.1", "localhost"].contains(url.host ?? ""),
              url.user == nil, url.password == nil else { return nil }
        var parts = URLComponents()
        parts.scheme = "http"; parts.host = url.host; parts.port = url.port; parts.path = "/"
        return parts.url
    }

    @MainActor static func prepare(downloads: DownloadManager, metadata: VideoMetadataStore, baseURL: URL) async throws {
        guard self.baseURL(baseURL.absoluteString) == baseURL else { throw Failure.invalidFixture }
        guard downloads.records.isEmpty else { return }
        func candidate(_ path: String, title: String) -> MediaCandidate {
            MediaCandidate(url: URL(string: path, relativeTo: baseURL)!.absoluteURL,
                           pageURL: baseURL, frameURL: baseURL, title: title, kind: .file, source: "fixture", mimeType: "video/mp4")
        }
        let mountain = await downloads.start(candidate: candidate("batch-slow.mp4?task=one", title: "山间练习甲"), cookies: [])
        downloads.pause(id: mountain)
        try metadata.toggleFavorite(mountain)
        try metadata.setTags(["练习"], for: mountain)
        let garden = await downloads.start(candidate: candidate("batch-slow.mp4?task=two", title: "花园练习乙"), cookies: [])
        downloads.pause(id: garden)
        let lake = await downloads.start(candidate: candidate("forbidden.mp4?task=failed", title: "湖边练习丙"), cookies: [])
        let forest = await downloads.start(candidate: candidate("batch-slow.mp4?task=cancelled", title: "树林练习丁"), cookies: [])
        downloads.cancel(id: forest)
        let window = await downloads.start(candidate: candidate("media/direct.mp4?task=complete", title: "窗边练习戊"), cookies: [])
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try Task.checkCancellation()
            if downloads.records.first(where: { $0.id == window })?.phase == .complete {
                guard downloads.records.first(where: { $0.id == mountain })?.phase == .paused,
                      downloads.records.first(where: { $0.id == garden })?.phase == .paused,
                      downloads.records.first(where: { $0.id == lake })?.phase == .failed,
                      downloads.records.first(where: { $0.id == forest })?.phase == .cancelled else { throw Failure.unexpectedState }
                return
            }
            if downloads.records.first(where: { $0.id == window })?.phase == .failed { throw Failure.unexpectedState }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.timedOut
    }
}
#endif
