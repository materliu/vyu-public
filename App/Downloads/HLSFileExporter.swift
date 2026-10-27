import AVFoundation
import Foundation

enum HLSFileExportError: LocalizedError {
    /// A valid HLS structure that this file exporter does not implement.
    case unsupported
    case limitExceeded
    var errorDescription: String? {
        switch self {
        case .unsupported: return "此 HLS 格式暂不支持导出为单个视频文件。"
        case .limitExceeded: return "视频超过当前导出限制，或本机可用空间不足。"
        }
    }
}

/// Stable, numeric-only context for completeness failures. No resource URLs or
/// server-provided descriptions may enter this error or its diagnostic archive.
struct HLSFileValidationFailure: LocalizedError {
    enum Phase: String, Codable { case playlist, resource, structure, sourceMetadata, sourceSamples, composition, export, outputMetadata, outputSamples }
    enum Check: Int, Codable {
        case playlistDuration = 1, audioDuration, missingAudio, playlistLength, resourceRange, resourceLength
        case assetDuration, trackDuration, sampleData, sampleTiming, sampleContinuity, sampleCoverage
        case atomBoundary, exportCompletion
    }
    let phase: Phase
    let check: Check
    let observed: Double?
    let expected: Double?
    let timelineStart: Double?
    let timelineEnd: Double?
    init(_ phase: Phase, _ check: Check, observed: Double? = nil, expected: Double? = nil, timelineStart: Double? = nil, timelineEnd: Double? = nil) {
        self.phase = phase; self.check = check
        self.observed = observed.flatMap { $0.isFinite ? $0 : nil }
        self.expected = expected.flatMap { $0.isFinite ? $0 : nil }
        self.timelineStart = timelineStart.flatMap { $0.isFinite ? $0 : nil }
        self.timelineEnd = timelineEnd.flatMap { $0.isFinite ? $0 : nil }
    }
    var errorDescription: String? { DownloadIssue.incompleteMedia.localizedDescription }
}

enum HLSFileExportStage { case transferring, assembling, validating }
struct HLSFileExportProgress {
    let bytes: Int64
    let fraction: Double?
    let stage: HLSFileExportStage
}
struct HLSFileExportResult {
    let url: URL
    let bytes: Int64
    let duration: Double
    let hasAudio: Bool
}

/// Public AVFoundation APIs operate on complete local fMP4 tracks. No movpkg
/// internals, CDN path guesses, decryption, or credentials enter the output.
enum HLSFileExporter {
    static func prepare(candidate: MediaCandidate, inspection: MediaInspection) async throws -> HLSFileDownloadPlan {
        let transfer = HLSFileTransfer(candidate: candidate, cookies: [], destination: URL(fileURLWithPath: "/dev/null"), onProgress: { _ in })
        defer { transfer.client.session.invalidateAndCancel() }
        let selected = try await transfer.selectedPlaylists(inspection.hlsDownloadURL ?? candidate.url)
        let plan = HLSFileDownloadPlan(video: selected.video, audio: selected.audio, requiresAudio: selected.requiresAudio || !inspection.audioTracks.isEmpty)
        try plan.validate()
        return plan
    }

    static func export(candidate: MediaCandidate, cookies: [HTTPCookie], inspection: MediaInspection,
                       destination: URL, plan: HLSFileDownloadPlan? = nil, cachedResources: [HLSFilePlaylist.Resource: URL] = [:],
                       onProgress: @escaping @MainActor @Sendable (HLSFileExportProgress) -> Void = { _ in }) async throws -> HLSFileExportResult {
        let transfer = HLSFileTransfer(candidate: candidate, cookies: cookies, destination: destination, onProgress: onProgress)
        transfer.preparedPlan = plan; transfer.cachedResources = cachedResources
        let session = transfer.client.session
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try await transfer.run(inspection: inspection)
        } onCancel: { session.invalidateAndCancel() }
    }
}

struct HLSFileDownloadPlan: Codable {
    let video: HLSFilePlaylist
    let audio: HLSFilePlaylist?
    let requiresAudio: Bool
    var resources: [HLSFilePlaylist.Resource] {
        [video.initialization] + video.segments.map(\.resource) + (audio.map { [$0.initialization] + $0.segments.map(\.resource) } ?? [])
    }
    func validate() throws {
        for playlist in [video, audio].compactMap({ $0 }) {
            guard (1...2048).contains(playlist.segments.count), playlist.duration.isFinite,
                  playlist.duration > 0, playlist.duration <= 86400,
                  playlist.segments.allSatisfy({ $0.duration.isFinite && $0.duration > 0 && $0.duration <= 3600 }) else { throw DownloadIssue.invalidMedia }
        }
        for resource in resources {
            guard MediaCookiePolicy.validHTTPURL(resource.url) else { throw DownloadIssue.invalidURL }
            if let range = resource.range {
                guard range.offset >= 0, range.length > 0, range.length <= 64 * 1024 * 1024,
                      range.offset <= Int64.max - range.length else { throw DownloadIssue.invalidMedia }
            }
        }
    }
}

struct HLSFilePlaylist: Codable {
    struct ByteRange: Hashable, Codable {
        let offset: Int64
        let length: Int64
        var header: String { "bytes=\(offset)-\(offset + length - 1)" }
    }
    struct Resource: Hashable, Codable {
        let url: URL
        let range: ByteRange?
    }
    struct Segment: Codable {
        let resource: Resource
        let duration: Double
    }
    let initialization: Resource
    let segments: [Segment]
    var duration: Double { segments.reduce(0) { $0 + $1.duration } }

    static func parse(_ text: String, relativeTo base: URL) throws -> HLSFilePlaylist {
        let manifest = try HLSManifest.parse(text, relativeTo: base)
        guard !manifest.encrypted else { throw DownloadIssue.protectedContent }
        guard !manifest.isMaster, manifest.isVOD else { throw HLSFileExportError.unsupported }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.count <= 10_000, lines.first == "#EXTM3U" else { throw DownloadIssue.invalidMedia }
        var initialization: Resource?, segments: [Segment] = []
        var duration: Double?, pendingRange: String?, ended = false
        func resolved(_ raw: String) throws -> URL {
            guard !raw.contains("{$"), !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let url = URL(string: raw, relativeTo: base)?.absoluteURL, MediaCookiePolicy.validHTTPURL(url),
                  !(base.scheme?.lowercased() == "https" && url.scheme?.lowercased() == "http") else { throw DownloadIssue.invalidURL }
            return url
        }
        func byteRange(_ raw: String, previous: Resource?, url: URL) throws -> ByteRange {
            let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let length = Int64(parts[0]), length > 0, length <= 64 * 1024 * 1024 else {
                throw DownloadIssue.invalidMedia
            }
            let offset: Int64
            if parts.count == 2, let explicit = Int64(parts[1]) { offset = explicit }
            else if parts.count == 1, let previous, previous.url == url, let previousRange = previous.range {
                offset = previousRange.offset + previousRange.length
            } else { throw DownloadIssue.invalidMedia }
            guard offset >= 0, offset <= Int64.max - length else { throw DownloadIssue.invalidMedia }
            return ByteRange(offset: offset, length: length)
        }
        for line in lines {
            if line == "#EXT-X-ENDLIST" { guard duration == nil, pendingRange == nil else { throw DownloadIssue.invalidMedia }; ended = true }
            else if line.hasPrefix("#EXT-X-DISCONTINUITY") || line == "#EXT-X-GAP" || line.hasPrefix("#EXT-X-SKIP:") ||
                        line.hasPrefix("#EXT-X-PART:") || line.hasPrefix("#EXT-X-DEFINE:") || line.hasPrefix("#EXT-X-CONTENT-STEERING:") ||
                        line == "#EXT-X-I-FRAMES-ONLY" { throw HLSFileExportError.unsupported }
            else if line.hasPrefix("#EXT-X-MAP:") {
                guard !ended else { throw DownloadIssue.invalidMedia }
                let values = HLSManifest.attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                guard let raw = values["URI"], !raw.isEmpty else { throw DownloadIssue.invalidMedia }
                let url = try resolved(raw)
                let range = try values["BYTERANGE"].map { try byteRange($0, previous: nil, url: url) }
                let resource = Resource(url: url, range: range)
                if let initialization, initialization != resource { throw HLSFileExportError.unsupported }
                initialization = resource
            } else if line.hasPrefix("#EXTINF:") {
                guard !ended, duration == nil, let value = Double(line.dropFirst(8).split(separator: ",").first ?? ""),
                      value.isFinite, value > 0, value <= 3600 else { throw DownloadIssue.invalidMedia }
                duration = value
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                guard !ended, pendingRange == nil else { throw DownloadIssue.invalidMedia }
                pendingRange = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
            } else if !line.isEmpty && !line.hasPrefix("#") {
                guard !ended, let value = duration else { throw DownloadIssue.invalidMedia }
                guard initialization != nil else { throw HLSFileExportError.unsupported }
                guard segments.count < 2048 else { throw HLSFileExportError.limitExceeded }
                let url = try resolved(line)
                let range = try pendingRange.map { try byteRange($0, previous: segments.last?.resource, url: url) }
                segments.append(Segment(resource: Resource(url: url, range: range), duration: value))
                duration = nil; pendingRange = nil
            }
        }
        guard let initialization, !segments.isEmpty, duration == nil, pendingRange == nil else { throw DownloadIssue.invalidMedia }
        let playlist = HLSFilePlaylist(initialization: initialization, segments: segments)
        guard playlist.duration.isFinite, playlist.duration > 0, playlist.duration <= 24 * 3600 else { throw HLSFileExportError.limitExceeded }
        return playlist
    }
}

private final class HLSFileTransfer {
    let client: MediaHTTPClient
    private let candidate: MediaCandidate
    private let destination: URL
    private let onProgress: @MainActor @Sendable (HLSFileExportProgress) -> Void
    private let deadline = ContinuousClock.now.advanced(by: .seconds(1800))
    private let byteLimit: Int64 = 2 * 1024 * 1024 * 1024
    var preparedPlan: HLSFileDownloadPlan?
    var cachedResources: [HLSFilePlaylist.Resource: URL] = [:]
    private var bytes: Int64 = 0
    private var lastProgress = ContinuousClock.now
    private var completedResources = 0, totalResources = 1
    private var phase: HLSFileValidationFailure.Phase = .playlist

    init(candidate: MediaCandidate, cookies: [HTTPCookie], destination: URL,
         onProgress: @escaping @MainActor @Sendable (HLSFileExportProgress) -> Void) {
        self.candidate = candidate; self.destination = destination; self.onProgress = onProgress
        client = MediaHTTPClient(candidate: candidate, cookies: cookies)
    }

    func run(inspection: MediaInspection) async throws -> HLSFileExportResult {
        try check()
        guard candidate.kind == .hls, inspection.downloadable, destination.isFileURL,
              ["mp4", "mov"].contains(destination.pathExtension.lowercased()),
              !FileManager.default.fileExists(atPath: destination.path) else { throw DownloadIssue.invalidURL }
        let parent = destination.deletingLastPathComponent()
        let directory = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directory.isDirectory == true, directory.isSymbolicLink != true else { throw DownloadIssue.invalidURL }
        let stage = parent.appendingPathComponent(".hls-export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        try Self.protect(stage)
        phase = .playlist
        let playlists: HLSFileDownloadPlan
        if let preparedPlan { try preparedPlan.validate(); playlists = preparedPlan }
        else {
            let selected = try await selectedPlaylists(inspection.hlsDownloadURL ?? candidate.url)
            playlists = HLSFileDownloadPlan(video: selected.video, audio: selected.audio, requiresAudio: selected.requiresAudio)
        }
        // Preflight may replace a master with its media-playlist URL. Preserve
        // an AUDIO group with no URI: its required track is embedded in video.
        let requiresAudio = playlists.requiresAudio || !inspection.audioTracks.isEmpty
        let expectedDuration = playlists.video.duration
        if let expected = inspection.expectedDuration {
            guard expected.isFinite, abs(expectedDuration - expected) <= max(1, expected * 0.01) else { throw failure(.playlistDuration, observed: expectedDuration, expected: expected) }
        }
        if let audio = playlists.audio {
            guard abs(audio.duration - expectedDuration) <= 1 else { throw failure(.audioDuration, observed: audio.duration, expected: expectedDuration) }
        }
        totalResources = playlists.video.segments.count + 1 + (playlists.audio.map { $0.segments.count + 1 } ?? 0)
        let videoURL = stage.appendingPathComponent("video.mp4")
        try await assemble(playlists.video, into: videoURL, stage: stage)
        var sources = [(videoURL, expectedDuration, AVMediaType.video)]
        if let audio = playlists.audio {
            let audioURL = stage.appendingPathComponent("audio.mp4")
            try await assemble(audio, into: audioURL, stage: stage)
            sources.append((audioURL, audio.duration, .audio))
        }
        try check()
        try Self.requireSpace(at: stage, bytes: bytes + 32 * 1024 * 1024)
        await onProgress(HLSFileExportProgress(bytes: bytes, fraction: 0.9, stage: .assembling))
        var assets: [AVURLAsset] = [], selectedTracks: [MediaTrack] = []
        defer { assets.forEach { $0.cancelLoading() } }
        for (url, duration, requiredType) in sources {
            let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
            assets.append(asset)
            phase = .sourceMetadata
            let metadata = try await inspect(asset, expectedDuration: duration, requiredType: requiredType)
            phase = .sourceSamples
            let tracks = try await verifySamples(asset: asset, tracks: metadata, expectedDuration: duration)
            if requiredType == .audio { guard tracks.allSatisfy({ $0.track.mediaType == .audio }) else { throw DownloadIssue.invalidMedia } }
            selectedTracks += tracks.filter { requiredType == .video ? (playlists.audio == nil || $0.track.mediaType != .audio) : $0.track.mediaType == .audio }
        }
        let includesAudio = selectedTracks.contains { $0.track.mediaType == .audio }
        guard !requiresAudio || includesAudio else { throw failure(.missingAudio) }
        phase = .composition
        // fMP4 edit lists can contain a shared leading empty interval. Its end
        // is a timestamp, not the length of the downloaded media. Copy actual
        // presentation ranges and remove only the common leading interval;
        // each track keeps its offset relative to the other tracks.
        guard let origin = selectedTracks.flatMap(\.segments).map({ $0.target.start }).min(by: { CMTimeCompare($0, $1) < 0 }) else { throw DownloadIssue.invalidMedia }
        let composition = AVMutableComposition()
        for input in selectedTracks {
            guard let output = composition.addMutableTrack(withMediaType: input.track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw DownloadIssue.invalidMedia }
            for segment in input.segments {
                try output.insertTimeRange(segment.target, of: input.track, at: CMTimeSubtract(segment.target.start, origin))
            }
            if input.track.mediaType == .video { output.preferredTransform = try await input.track.load(.preferredTransform) }
        }
        let compositionDuration = composition.duration.seconds
        guard compositionDuration.isFinite, compositionDuration > 0 else { throw DownloadIssue.invalidMedia }
        guard let mediaDuration = selectedTracks.map(\.mediaDuration).max(),
              compositionDuration <= mediaDuration + 0.25 else { throw HLSFileExportError.unsupported }
        let stagedOutput = stage.appendingPathComponent("output." + destination.pathExtension)
        phase = .export
        try await export(composition, to: stagedOutput)
        try Self.protect(stagedOutput)
        try check()
        await onProgress(HLSFileExportProgress(bytes: bytes, fraction: 0.95, stage: .validating))
        let outputAsset = AVURLAsset(url: stagedOutput, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        defer { outputAsset.cancelLoading() }
        phase = .outputMetadata
        let metadata = try await inspect(outputAsset, expectedDuration: compositionDuration, requiredType: .video)
        phase = .outputSamples
        let tracks = try await verifySamples(asset: outputAsset, tracks: metadata)
        let hasAudio = tracks.contains { $0.track.mediaType == .audio }
        guard !(requiresAudio || includesAudio) || hasAudio else { throw failure(.missingAudio) }
        for output in tracks {
            guard let input = selectedTracks.first(where: { $0.track.mediaType == output.track.mediaType }),
                  abs(output.mediaDuration - input.mediaDuration) <= 0.25 else { throw failure(.trackDuration, observed: output.mediaDuration) }
        }
        let duration = try await outputAsset.load(.duration).seconds
        guard abs(duration - compositionDuration) <= 0.25 else { throw failure(.assetDuration, observed: duration, expected: compositionDuration) }
        let size = Int64(try stagedOutput.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard size > 0, size <= byteLimit else { throw HLSFileExportError.limitExceeded }
        try check()
        // Move is the only commit. The caller owns final persistence/validation;
        // cancellation before this point leaves no apparently complete file.
        try FileManager.default.moveItem(at: stagedOutput, to: destination)
        return HLSFileExportResult(url: destination, bytes: size, duration: duration, hasAudio: hasAudio)
    }

    func selectedPlaylists(_ url: URL) async throws -> (video: HLSFilePlaylist, audio: HLSFilePlaylist?, requiresAudio: Bool) {
        let (text, effective) = try await playlist(url)
        let manifest = try HLSManifest.parse(text, relativeTo: effective)
        guard !manifest.encrypted else { throw DownloadIssue.protectedContent }
        if !manifest.isMaster { return (try HLSFilePlaylist.parse(text, relativeTo: effective), nil, false) }
        // Every URL and audio group comes from this fetched master. Do not infer
        // an MP4 alternative, bitrate path, or audio URL from a CDN filename.
        guard let variant = manifest.variants.max(by: { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) }) else { throw DownloadIssue.invalidMedia }
        let (videoText, videoURL) = try await playlist(variant.url)
        let video = try HLSFilePlaylist.parse(videoText, relativeTo: videoURL)
        guard let group = variant.audioGroupID else { return (video, nil, false) }
        let audioTracks = manifest.audioTracks.filter { $0.groupID == group }
        guard !audioTracks.isEmpty else { throw failure(.missingAudio) }
        let defaultURL = text.components(separatedBy: .newlines).compactMap { line -> URL? in
            guard line.hasPrefix("#EXT-X-MEDIA:") else { return nil }
            let values = HLSManifest.attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
            guard values["TYPE"] == "AUDIO", values["GROUP-ID"] == group, values["DEFAULT"] == "YES",
                  let raw = values["URI"] else { return nil }
            return URL(string: raw, relativeTo: effective)?.absoluteURL
        }.first
        let chosenAudio = audioTracks.first { $0.url == defaultURL } ?? audioTracks[0]
        guard let audioURL = chosenAudio.url else { return (video, nil, true) }
        let (audioText, effectiveAudio) = try await playlist(audioURL)
        return (video, try HLSFilePlaylist.parse(audioText, relativeTo: effectiveAudio), true)
    }

    private func playlist(_ url: URL) async throws -> (String, URL) {
        try check()
        guard MediaCookiePolicy.validHTTPURL(url) else { throw DownloadIssue.invalidURL }
        let (stream, response) = try await client.session.bytes(for: client.request(url))
        defer { stream.task.cancel() }
        let http = try validResponse(response, requested: url)
        guard http.statusCode == 200 else { throw DownloadIssue.http(http.statusCode) }
        guard http.expectedContentLength <= 2_000_000 else { throw DownloadIssue.oversizedManifest }
        var data = Data()
        for try await byte in stream {
            if data.count % 65536 == 0 { try check() }
            data.append(byte)
            if data.count > 2_000_000 { throw DownloadIssue.oversizedManifest }
        }
        guard http.expectedContentLength < 0 || data.count == http.expectedContentLength,
              let text = String(data: data, encoding: .utf8), let effective = response.url else { throw failure(.playlistLength, observed: Double(data.count), expected: Double(http.expectedContentLength)) }
        return (text, effective)
    }

    private func assemble(_ playlist: HLSFilePlaylist, into track: URL, stage: URL) async throws {
        guard FileManager.default.createFile(atPath: track.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw DownloadIssue.invalidMedia }
        try Self.protect(track)
        let handle = try FileHandle(forWritingTo: track)
        defer { try? handle.close() }
        let resources = [playlist.initialization] + playlist.segments.map(\.resource)
        for (index, resource) in resources.enumerated() {
            try check()
            try Self.requireSpace(at: stage, bytes: 128 * 1024 * 1024)
            let part = stage.appendingPathComponent("part")
            defer { try? FileManager.default.removeItem(at: part) }
            phase = .resource
            let size = try await download(resource, to: part)
            phase = .structure
            try Self.verifyAtoms(part, size: UInt64(size), initialization: index == 0)
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }
            while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
                try check(); try handle.write(contentsOf: data)
            }
            completedResources += 1
            await report(force: completedResources == totalResources)
        }
        try handle.synchronize()
    }

    private func download(_ resource: HLSFilePlaylist.Resource, to file: URL) async throws -> Int64 {
        if preparedPlan != nil {
            guard let source = cachedResources[resource] else { throw DownloadIssue.incompleteMedia }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            let size = Int64(values.fileSize ?? 0)
            guard values.isRegularFile == true, values.isSymbolicLink != true, size > 0, size <= 64 * 1024 * 1024,
                  resource.range == nil || resource.range?.length == size else { throw DownloadIssue.incompleteMedia }
            bytes += size
            guard bytes <= byteLimit else { throw HLSFileExportError.limitExceeded }
            try FileManager.default.copyItem(at: source, to: file)
            return size
        }
        var request = client.request(resource.url)
        if let range = resource.range { request.setValue(range.header, forHTTPHeaderField: "Range") }
        let (stream, response) = try await client.session.bytes(for: request)
        defer { stream.task.cancel() }
        let http = try validResponse(response, requested: resource.url)
        let expected: Int64?
        if let range = resource.range {
            guard http.statusCode == 206,
                  let value = http.value(forHTTPHeaderField: "Content-Range"), let actual = HLSRelayContentRange(value),
                  actual.start == range.offset, actual.length == range.length,
                  http.expectedContentLength < 0 || http.expectedContentLength == range.length else { throw failure(.resourceRange, observed: Double(http.expectedContentLength), expected: Double(range.length)) }
            expected = range.length
        } else {
            guard http.statusCode == 200 else { throw DownloadIssue.http(http.statusCode) }
            expected = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        }
        guard (expected ?? 0) <= 64 * 1024 * 1024 else { throw HLSFileExportError.limitExceeded }
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw DownloadIssue.invalidMedia }
        try Self.protect(file)
        let output = try FileHandle(forWritingTo: file)
        defer { try? output.close() }
        var chunk = Data(), received: Int64 = 0
        for try await byte in stream {
            chunk.append(byte)
            if chunk.count == 64 * 1024 {
                try check(); received += Int64(chunk.count); bytes += Int64(chunk.count)
                guard received <= 64 * 1024 * 1024, bytes <= byteLimit else { throw HLSFileExportError.limitExceeded }
                try output.write(contentsOf: chunk); chunk.removeAll(keepingCapacity: true)
                await report()
            }
        }
        try check()
        received += Int64(chunk.count); bytes += Int64(chunk.count)
        guard received > 0, received <= 64 * 1024 * 1024, bytes <= byteLimit else { throw HLSFileExportError.limitExceeded }
        guard expected == nil || expected == received else { throw failure(.resourceLength, observed: Double(received), expected: expected.map(Double.init)) }
        try output.write(contentsOf: chunk)
        try output.synchronize()
        return received
    }

    private func validResponse(_ response: URLResponse, requested: URL) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw DownloadIssue.invalidMedia }
        guard [200, 206].contains(http.statusCode) else { throw DownloadIssue.http(http.statusCode) }
        guard !MediaFileResponse.isWebPage(http), let effective = response.url, MediaCookiePolicy.validHTTPURL(effective),
              !(requested.scheme?.lowercased() == "https" && effective.scheme?.lowercased() == "http") else { throw DownloadIssue.invalidMedia }
        return http
    }

    private struct MediaSegment {
        let source: CMTimeRange
        let target: CMTimeRange
    }
    private struct MediaTrack {
        let track: AVAssetTrack
        let segments: [MediaSegment]
        var mediaDuration: Double { segments.reduce(0) { $0 + $1.target.duration.seconds } }
    }

    private func inspect(_ asset: AVURLAsset, expectedDuration: Double, requiredType: AVMediaType) async throws -> [MediaTrack] {
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            asset.cancelLoading()
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try check()
            guard try await !asset.load(.hasProtectedContent) else { throw DownloadIssue.protectedContent }
            guard try await asset.load(.isPlayable), try await asset.load(.isReadable),
                  try await asset.load(.isComposable) else { throw DownloadIssue.invalidMedia }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw failure(.assetDuration, observed: duration, expected: expectedDuration) }
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let tracks = video + audio
            guard video.count <= 1, audio.count <= 1 else { throw HLSFileExportError.unsupported }
            guard tracks.contains(where: { $0.mediaType == requiredType }) else { throw DownloadIssue.invalidMedia }
            var result: [MediaTrack] = []
            for track in tracks {
                let editList = try await track.load(.segments)
                guard editList.count <= 4096 else { throw HLSFileExportError.limitExceeded }
                let segments = try editList.filter { !$0.isEmpty }.map { value -> MediaSegment in
                    let mapping = value.timeMapping
                    for range in [mapping.source, mapping.target] {
                        guard range.start.seconds.isFinite, range.duration.seconds.isFinite, range.duration.seconds > 0,
                              CMTimeRangeGetEnd(range).seconds.isFinite else { throw failure(.trackDuration) }
                    }
                    // A rate-changing edit needs a separate composition path.
                    guard abs(mapping.source.duration.seconds - mapping.target.duration.seconds) <= 0.001 else { throw HLSFileExportError.unsupported }
                    return MediaSegment(source: mapping.source, target: mapping.target)
                }
                guard !segments.isEmpty, segments.count <= 2048 else { throw HLSFileExportError.unsupported }
                var editGaps = 0.0
                for (previous, current) in zip(segments, segments.dropFirst()) {
                    let targetGap = current.target.start.seconds - CMTimeRangeGetEnd(previous.target).seconds
                    let sourceGap = current.source.start.seconds - CMTimeRangeGetEnd(previous.source).seconds
                    // Keep the portable path limited to forward, contiguous edits.
                    // Other valid edit plans need the system's HLS representation.
                    editGaps += max(0, targetGap) + max(0, sourceGap)
                    guard targetGap >= -0.001, sourceGap >= -0.001, editGaps <= 0.25 else { throw HLSFileExportError.unsupported }
                }
                // A fragment decode-time offset may inflate even the nonempty
                // metadata range. Admission uses the actual sample coverage below.
                result.append(MediaTrack(track: track, segments: segments))
            }
            return result
        } onCancel: { asset.cancelLoading() }
    }

    private func export(_ composition: AVMutableComposition, to output: URL) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw HLSFileExportError.unsupported }
        let type: AVFileType = output.pathExtension.lowercased() == "mov" ? .mov : .mp4
        guard session.supportedFileTypes.contains(type) else { throw HLSFileExportError.unsupported }
        session.outputURL = output; session.outputFileType = type; session.shouldOptimizeForNetworkUse = true
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            session.cancelExport()
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            await session.export()
            try check()
            guard session.status == .completed else { throw session.error ?? failure(.exportCompletion) }
        } onCancel: { session.cancelExport() }
    }

    private struct SampleInterval {
        let start: Double
        let end: Double
    }

    private func verifySamples(asset: AVURLAsset, tracks: [MediaTrack], expectedDuration: Double? = nil) async throws -> [MediaTrack] {
        let reader = try AVAssetReader(asset: asset)
        let outputs = try tracks.map { input in
            let output = AVAssetReaderTrackOutput(track: input.track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw DownloadIssue.invalidMedia }
            reader.add(output); return output
        }
        defer { reader.cancelReading() }
        guard reader.startReading() else { throw reader.error ?? DownloadIssue.invalidMedia }
        var finished = Set<Int>(), intervals = Array(repeating: [SampleInterval](), count: tracks.count)
        let readDeadline = ContinuousClock.now.advanced(by: .seconds(120))
        while finished.count < outputs.count {
            for index in outputs.indices where !finished.contains(index) {
                try check()
                guard ContinuousClock.now < readDeadline else { throw URLError(.timedOut) }
                let interval: SampleInterval? = try autoreleasepool {
                    guard let sample = outputs[index].copyNextSampleBuffer() else { finished.insert(index); return nil }
                    guard CMSampleBufferDataIsReady(sample) else { throw failure(.sampleData) }
                    guard CMSampleBufferGetNumSamples(sample) > 0 else { return nil }
                    let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    let duration = CMSampleBufferGetDuration(sample).seconds
                    guard start.isFinite, duration.isFinite, duration > 0, (start + duration).isFinite else { throw failure(.sampleTiming, observed: duration) }
                    return SampleInterval(start: start, end: start + duration)
                }
                if let interval {
                    guard intervals[index].count < 1_000_000 else { throw HLSFileExportError.limitExceeded }
                    intervals[index].append(interval)
                }
            }
            guard reader.status != .failed else { throw reader.error ?? failure(.sampleData) }
            await Task.yield()
        }
        guard reader.status == .completed else { throw reader.error ?? failure(.sampleData) }
        var verified: [MediaTrack] = []
        for index in tracks.indices {
            // Compressed B frames arrive in decode order. Their presentation
            // durations cannot be added to DTS to predict the next DTS, especially
            // with variable frame rate. Validate presentation coverage instead.
            let sorted = intervals[index].sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
            guard !sorted.isEmpty else { throw failure(.sampleCoverage) }
            var spans: [SampleInterval] = []
            for (offset, sample) in sorted.enumerated() {
                if offset > 0 {
                    let previous = sorted[offset - 1]
                    if abs(previous.start - sample.start) < 0.000001 && abs(previous.end - sample.end) < 0.000001 {
                        throw failure(.sampleContinuity, observed: sample.start - previous.start)
                    }
                }
                if let last = spans.last, sample.start <= last.end + 0.000001 {
                    spans[spans.count - 1] = SampleInterval(start: last.start, end: max(last.end, sample.end))
                } else { spans.append(sample) }
            }
            var missing = 0.0, actualSegments: [MediaSegment] = []
            for segment in tracks[index].segments {
                // AVAssetReader returns source timestamps. Empty presentation
                // edits are not missing media and do not extend this source range.
                let declaredStart = segment.source.start.seconds, declaredEnd = CMTimeRangeGetEnd(segment.source).seconds
                // Trim metadata-only prefix/suffix, never an internal sample gap.
                // The remaining length must still match this fetched playlist.
                let start = max(declaredStart, spans[0].start), end = min(declaredEnd, spans[spans.count - 1].end)
                guard end > start else { continue }
                var low = 0, high = spans.count
                while low < high {
                    let middle = (low + high) / 2
                    if spans[middle].end <= start { low = middle + 1 } else { high = middle }
                }
                var cursor = start, covered = 0.0, spanIndex = low
                while spanIndex < spans.count, spans[spanIndex].start < end {
                    try check()
                    let span = spans[spanIndex]
                    let begin = max(start, span.start), finish = min(end, span.end)
                    if begin > cursor + 0.25 { throw failure(.sampleContinuity, observed: begin - cursor, expected: 0) }
                    covered += max(0, finish - begin); cursor = max(cursor, finish)
                    spanIndex += 1
                }
                missing += max(0, end - start - covered)
                guard missing <= 0.25 else { throw failure(.sampleCoverage, observed: covered, expected: end - start) }
                let sourceStart = abs(start - declaredStart) < 0.000001 ? segment.source.start : CMTime(seconds: start, preferredTimescale: 1_000_000_000)
                let sourceEnd = abs(end - declaredEnd) < 0.000001 ? CMTimeRangeGetEnd(segment.source) : CMTime(seconds: end, preferredTimescale: 1_000_000_000)
                let targetStart = CMTimeMapTimeFromRangeToRange(sourceStart, fromRange: segment.source, toRange: segment.target)
                let targetEnd = CMTimeMapTimeFromRangeToRange(sourceEnd, fromRange: segment.source, toRange: segment.target)
                guard targetStart.seconds.isFinite, targetEnd.seconds.isFinite else { throw failure(.sampleTiming) }
                actualSegments.append(MediaSegment(source: CMTimeRange(start: sourceStart, end: sourceEnd),
                    target: CMTimeRange(start: targetStart, end: targetEnd)))
            }
            let input = MediaTrack(track: tracks[index].track, segments: actualSegments)
            guard !actualSegments.isEmpty else { throw failure(.sampleCoverage) }
            if let expectedDuration,
               input.mediaDuration < expectedDuration - 0.25 || input.mediaDuration > expectedDuration + 1 {
                throw HLSFileValidationFailure(phase, .trackDuration, observed: input.mediaDuration, expected: expectedDuration,
                    timelineStart: actualSegments.map { $0.target.start.seconds }.min(),
                    timelineEnd: actualSegments.map { CMTimeRangeGetEnd($0.target).seconds }.max())
            }
            verified.append(input)
        }
        return verified
    }

    private static func verifyAtoms(_ url: URL, size: UInt64, initialization: Bool) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var offset: UInt64 = 0, atoms = Set<String>(), count = 0
        while offset < size {
            try Task.checkCancellation()
            guard count < 100_000, size - offset >= 8 else { throw HLSFileValidationFailure(.structure, .atomBoundary) }
            try input.seek(toOffset: offset)
            guard let header = try input.read(upToCount: 8), header.count == 8 else { throw HLSFileValidationFailure(.structure, .atomBoundary) }
            let shortSize = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let length: UInt64, headerSize: UInt64
            if shortSize == 1 {
                guard let extended = try input.read(upToCount: 8), extended.count == 8 else { throw HLSFileValidationFailure(.structure, .atomBoundary) }
                length = extended.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }; headerSize = 16
            } else { length = shortSize == 0 ? size - offset : shortSize; headerSize = 8 }
            guard length >= headerSize, length <= size - offset else { throw HLSFileValidationFailure(.structure, .atomBoundary) }
            atoms.insert(String(decoding: header.suffix(4), as: UTF8.self)); offset += length; count += 1
        }
        if initialization {
            guard atoms.contains("ftyp"), atoms.contains("moov"), !atoms.contains("moof"), !atoms.contains("mdat") else { throw DownloadIssue.invalidMedia }
        } else {
            guard atoms.contains("moof"), atoms.contains("mdat"), !atoms.contains("moov") else { throw DownloadIssue.invalidMedia }
        }
    }

    private static func protect(_ url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        var protected = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
    }
    private static func requireSpace(at url: URL, bytes: Int64) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < bytes + 16 * 1024 * 1024 { throw HLSFileExportError.limitExceeded }
    }
    private func failure(_ check: HLSFileValidationFailure.Check, observed: Double? = nil, expected: Double? = nil) -> HLSFileValidationFailure {
        HLSFileValidationFailure(phase, check, observed: observed, expected: expected)
    }
    private func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
    }
    private func report(force: Bool = false) async {
        let now = ContinuousClock.now
        guard force || now - lastProgress >= .milliseconds(250) else { return }
        lastProgress = now
        await onProgress(HLSFileExportProgress(bytes: bytes, fraction: min(0.88, 0.88 * Double(completedResources) / Double(totalResources)), stage: .transferring))
    }
}
