import AVFoundation
import XCTest
@testable import VYu

final class HLSFilePlaylistTests: XCTestCase {
    private let base = URL(string: "https://media.example.test/path/index.m3u8?signature=private")!
    private let header = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-MAP:URI=\"init.mp4\"\n"

    func testResolvesOnlyDeclaredResourcesAndRanges() throws {
        let text = "#EXTM3U\n#EXT-X-MAP:URI=\"stream.mp4\",BYTERANGE=\"100@0\"\n#EXTINF:2,\n#EXT-X-BYTERANGE:200@100\nstream.mp4\n#EXTINF:2,\n#EXT-X-BYTERANGE:300\nstream.mp4\n#EXT-X-ENDLIST\n"
        let value = try HLSFilePlaylist.parse(text, relativeTo: base)
        XCTAssertEqual(value.initialization.range?.header, "bytes=0-99")
        XCTAssertEqual(value.segments.map { $0.resource.range?.header }, ["bytes=100-299", "bytes=300-599"])
        XCTAssertEqual(value.segments[0].resource.url.absoluteString, "https://media.example.test/path/stream.mp4")
        XCTAssertEqual(value.duration, 4)
    }

    func testRejectsAmbiguousAndOverflowingRanges() {
        let ranges = ["200", "-1@0", "200@-1", "200@9223372036854775800", "1@0@1"]
        for range in ranges {
            XCTAssertThrowsError(try HLSFilePlaylist.parse(header + "#EXTINF:2,\n#EXT-X-BYTERANGE:\(range)\nstream.mp4\n#EXT-X-ENDLIST\n", relativeTo: base))
        }
        XCTAssertThrowsError(try HLSFilePlaylist.parse(header + "#EXTINF:2,\n#EXT-X-BYTERANGE:200@100\none.mp4\n#EXTINF:2,\n#EXT-X-BYTERANGE:200\ntwo.mp4\n#EXT-X-ENDLIST\n", relativeTo: base))
    }

    func testRejectsEncryptionBeforeAnyExportFallback() {
        XCTAssertThrowsError(try HLSFilePlaylist.parse(header + "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key\"\n#EXTINF:2,\none.m4s\n#EXT-X-ENDLIST\n", relativeTo: base)) { error in
            guard case DownloadIssue.protectedContent = error else { return XCTFail("Encryption must never be classified as a format fallback") }
        }
    }

    func testUnsupportedFormatIsDistinctFromMalformedMedia() {
        for body in ["#EXTM3U\n#EXTINF:2,\none.ts\n#EXT-X-ENDLIST\n", header + "#EXT-X-DISCONTINUITY\n#EXTINF:2,\none.m4s\n#EXT-X-ENDLIST\n"] {
            XCTAssertThrowsError(try HLSFilePlaylist.parse(body, relativeTo: base)) { error in
                guard case HLSFileExportError.unsupported = error else { return XCTFail("Valid unsupported structure should allow the system HLS path") }
            }
        }
        for body in [header + "#EXTINF:2,\n#EXT-X-ENDLIST\n", header + "#EXTINF:NaN,\none.m4s\n#EXT-X-ENDLIST\n", header + "#EXTINF:2,\none.m4s\n#EXT-X-ENDLIST\n#EXTINF:2,\ntwo.m4s\n"] {
            XCTAssertThrowsError(try HLSFilePlaylist.parse(body, relativeTo: base)) { error in
                XCTAssertFalse(error is HLSFileExportError, "Malformed media must not silently fall back and redownload")
            }
        }
    }

    func testRejectsResourceDowngradesAndChangingInitialization() {
        XCTAssertThrowsError(try HLSFilePlaylist.parse(header + "#EXTINF:2,\nhttp://media.example.test/segment.m4s\n#EXT-X-ENDLIST\n", relativeTo: base))
        XCTAssertThrowsError(try HLSFilePlaylist.parse(header + "#EXTINF:2,\none.m4s\n#EXT-X-MAP:URI=\"changed.mp4\"\n#EXTINF:2,\ntwo.m4s\n#EXT-X-ENDLIST\n", relativeTo: base)) { error in
            guard case HLSFileExportError.unsupported = error else { return XCTFail("Changing initialization requires a different assembly path") }
        }
    }
}

@MainActor final class HLSFileExporterTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8765")!
    private var root: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-file-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var request = URLRequest(url: base.appendingPathComponent("__control"))
        request.httpMethod = "POST"; request.httpBody = Data("{\"offline\":false}".utf8)
        do { _ = try await URLSession.shared.data(for: request) }
        catch { throw XCTSkip("Generate fixtures and start fixtures/server.py first") }
    }
    override func tearDown() async throws { if let root { try? FileManager.default.removeItem(at: root) } }

    func testExportsSeparateFMP4VideoAndMatchingAudioToStandaloneMP4() async throws {
        try await verify(path: "media/hls-fmp4-separate/master.m3u8")
    }
    func testExportsMuxedFMP4ByteRangesToStandaloneMP4() async throws {
        try await verify(path: "media/hls-fmp4/index.m3u8")
    }
    func testExportsTwoFPSBFramesWithoutTreatingPresentationOffsetAsMissingMedia() async throws {
        try await verifyTimingFixture("2fps", expectedFrames: 24)
    }
    func testExportsOneFPSBFramesWithoutTreatingPresentationOffsetAsMissingMedia() async throws {
        try await verifyTimingFixture("1fps", expectedFrames: 12)
    }
    func testExportsVariableFrameRateBFramesWithoutUsingPresentationDurationAsDecodeDuration() async throws {
        try await verifyTimingFixture("vfr", expectedFrames: 49)
    }
    func testRemovesCommonLeadingEmptyEditWithoutDoublingVideoDuration() async throws {
        // A complete twelve-second presentation starts at a nonzero tfdt. Its
        // unedited AVAsset duration is about 24.333 seconds, including the empty
        // lead-in. Preserve the actual content and its audio synchronization.
        try await verifyTimingFixture("offset", expectedFrames: 292, maximumDuration: 12.5, maximumFirstTime: 0.2)
    }
    func testExportsAbsoluteFragmentTimestampsWithoutAnExplicitEmptyEdit() async throws {
        try await verifyTimingFixture("offset-no-edit", expectedFrames: 292, maximumDuration: 12.5, maximumFirstTime: 0.2)
    }
    func testExportsCompleteFragmentsWhenHeaderDurationInflatesNonemptyTrackRange() async throws {
        // The redundant initialization-header duration makes AVFoundation
        // report a 24.333-second nonempty range for twelve seconds of samples.
        try await verifyTimingFixture("metadata-duration", expectedFrames: 292, maximumDuration: 12.5, maximumFirstTime: 0.2)
    }
    func testTruncatedFragmentNeverCreatesCompletedFile() async throws {
        let source = candidate("media/hls-export-invalid/truncated.m3u8")
        let client = MediaHTTPClient(candidate: source, cookies: []); defer { client.close() }
        let inspection = try await HLSPreflight.inspect(source.url, load: client.playlist)
        let destination = root.appendingPathComponent("incomplete.mp4")
        do {
            _ = try await HLSFileExporter.export(candidate: source, cookies: [], inspection: inspection, destination: destination)
            XCTFail("A complete HTTP response containing a truncated fMP4 must fail")
        } catch {
            XCTAssertFalse(error is HLSFileExportError, "Corruption must not trigger system fallback")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testMissingMiddleFragmentIsDetectedEvenWhenFinalTimestampIsPresent() async throws {
        let source = candidate("media/hls-export-invalid/repeated.m3u8")
        let client = MediaHTTPClient(candidate: source, cookies: []); defer { client.close() }
        let inspection = try await HLSPreflight.inspect(source.url, load: client.playlist)
        let destination = root.appendingPathComponent("missing-middle.mp4")
        do {
            _ = try await HLSFileExporter.export(candidate: source, cookies: [], inspection: inspection, destination: destination)
            XCTFail("Duplicating an earlier fragment cannot fill a missing middle interval")
        } catch { XCTAssertFalse(error is HLSFileExportError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testLowFrameRateMissingMiddleFragmentStillFailsWithFinalTimestampPresent() async throws {
        let source = candidate("media/hls-export-invalid/low-framerate-repeated.m3u8")
        let client = MediaHTTPClient(candidate: source, cookies: []); defer { client.close() }
        let inspection = try await HLSPreflight.inspect(source.url, load: client.playlist)
        let destination = root.appendingPathComponent("low-frame-rate-missing-middle.mp4")
        do {
            _ = try await HLSFileExporter.export(candidate: source, cookies: [], inspection: inspection, destination: destination)
            XCTFail("Low frame rate and presentation offsets must not hide a missing middle interval")
        } catch { XCTAssertFalse(error is HLSFileExportError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testMissingFirstHalfSecondFailsDespiteCompleteFragmentContainers() async throws {
        try await verifyMissingEdge("missing-prefix")
    }
    func testMissingLastHalfSecondFailsDespiteCompleteFragmentContainers() async throws {
        try await verifyMissingEdge("missing-suffix")
    }
    func testPreflightEmbeddedAudioRequirementSurvivesSelectionOfMediaPlaylist() async throws {
        let source = candidate("media/hls-export-invalid/missing-inline-audio.m3u8")
        let client = MediaHTTPClient(candidate: source, cookies: []); defer { client.close() }
        let inspection = try await HLSPreflight.inspect(source.url, load: client.playlist)
        XCTAssertFalse(inspection.audioTracks.isEmpty)
        XCTAssertEqual(inspection.hlsDownloadURL?.path, "/media/hls-fmp4-separate/video/360p/index.m3u8",
                       "Preflight intentionally chooses the self-contained media URL, so the exporter must retain its audio requirement separately")
        let destination = root.appendingPathComponent("missing-audio.mp4")
        do {
            _ = try await HLSFileExporter.export(candidate: source, cookies: [], inspection: inspection, destination: destination)
            XCTFail("A master that declares embedded audio must not produce a completed silent file")
        } catch {
            guard let failure = error as? HLSFileValidationFailure, failure.check == .missingAudio else {
                return XCTFail("Missing declared audio must fail without format fallback")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testCancellationDuringAssemblyCleansStagingAndDoesNotCommitFile() async throws {
        let source = candidate("media/hls-fmp4-separate/master.m3u8")
        let client = MediaHTTPClient(candidate: source, cookies: []); defer { client.close() }
        let inspection = try await HLSPreflight.inspect(source.url, load: client.playlist)
        let destination = root.appendingPathComponent("cancelled.mp4")
        var task: Task<Void, Error>!
        task = Task {
            _ = try await HLSFileExporter.export(candidate: source, cookies: [], inspection: inspection, destination: destination) { progress in
                if progress.stage == .assembling { task.cancel() }
            }
        }
        do { try await task.value; XCTFail("Cancelled export must throw") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testHTTP403DoesNotFallBackOrLeaveAFile() async throws {
        let source = candidate("forbidden.mp4")
        let inspection = MediaInspection(summary: "fixture", variants: [], audioTracks: [], expectedBytes: nil, downloadable: true)
        let destination = root.appendingPathComponent("denied.mp4")
        do {
            _ = try await HLSFileExporter.export(candidate: source, cookies: [], inspection: inspection, destination: destination)
            XCTFail("A denied request must remain denied")
        } catch {
            guard case DownloadIssue.http(403) = error else { return XCTFail("Expected the HTTP refusal without a fallback") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    private func verify(path: String) async throws {
        let source = candidate(path)
        let client = MediaHTTPClient(candidate: source, cookies: []); defer { client.close() }
        let inspection = try await HLSPreflight.inspect(source.url, load: client.playlist)
        var progress: [HLSFileExportProgress] = []
        let result = try await HLSFileExporter.export(candidate: source, cookies: [], inspection: inspection,
            destination: root.appendingPathComponent("video.mp4")) { progress.append($0) }
        XCTAssertEqual(result.duration, 8, accuracy: 0.25)
        XCTAssertTrue(result.hasAudio)
        XCTAssertGreaterThan(result.bytes, 0)
        XCTAssertTrue(progress.contains { $0.stage == .assembling })
        XCTAssertTrue(progress.contains { $0.stage == .validating })
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy { $0.bytes <= $1.bytes })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["video.mp4"])
        // No remote references are allowed when verifying the exported file.
        let asset = AVURLAsset(url: result.url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        let video = try await asset.loadTracks(withMediaType: .video), audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1); XCTAssertEqual(audio.count, 1)
        let generator = AVAssetImageGenerator(asset: asset)
        let image = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        XCTAssertGreaterThan(image.width, 0)
    }
    private func verifyMissingEdge(_ name: String) async throws {
        let source = candidate("media/hls-export-invalid/" + name + ".m3u8")
        let client = MediaHTTPClient(candidate: source, cookies: []); defer { client.close() }
        let inspection = try await HLSPreflight.inspect(source.url, load: client.playlist)
        let destination = root.appendingPathComponent("missing-edge.mp4")
        do {
            _ = try await HLSFileExporter.export(candidate: source, cookies: [], inspection: inspection, destination: destination)
            XCTFail("A valid zero-sample fragment cannot satisfy a declared half-second of content")
        } catch {
            let failure = try XCTUnwrap(error as? HLSFileValidationFailure)
            XCTAssertEqual(failure.phase, .sourceSamples)
            XCTAssertEqual(failure.check, .trackDuration)
            XCTAssertEqual(try XCTUnwrap(failure.observed), 7.5, accuracy: 0.01)
            XCTAssertEqual(try XCTUnwrap(failure.expected), 8, accuracy: 0.01)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    private func verifyTimingFixture(_ name: String, expectedFrames: Int,
                                     maximumDuration: Double = 13.5, maximumFirstTime: Double = 1.05) async throws {
        let source = candidate("media/hls-timing/" + name + "/index.m3u8")
        let client = MediaHTTPClient(candidate: source, cookies: []); defer { client.close() }
        let inspection = try await HLSPreflight.inspect(source.url, load: client.playlist)
        let result = try await HLSFileExporter.export(candidate: source, cookies: [], inspection: inspection,
            destination: root.appendingPathComponent("timing.mp4"))
        XCTAssertTrue(result.hasAudio)
        XCTAssertGreaterThanOrEqual(result.duration, 11.9)
        XCTAssertLessThan(result.duration, maximumDuration, "Only the source's initial presentation offset and short AAC tail may extend its twelve-second timeline")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["timing.mp4"])
        let asset = AVURLAsset(url: result.url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1); XCTAssertEqual(audio.count, 1)
        let audioDuration = try await XCTUnwrap(audio.first).load(.timeRange).duration.seconds
        XCTAssertGreaterThan(audioDuration, 11.9)
        let videoTrack = try XCTUnwrap(video.first)
        let contentRanges = try await videoTrack.load(.segments).filter { !$0.isEmpty }.map { $0.timeMapping.target }
        let contentStart = try XCTUnwrap(contentRanges.map(\.start).min { CMTimeCompare($0, $1) < 0 })
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        defer { reader.cancelReading() }
        var count = 0, first: CMTime?, last: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            XCTAssertNotNil(CMSampleBufferGetImageBuffer(sample), "Decode every frame, including the tail")
            let time = CMSampleBufferGetOutputPresentationTimeStamp(sample)
            XCTAssertTrue(time.seconds.isFinite)
            // AVAssetReader's decoded output synthesizes a frame at time zero
            // for a leading empty edit. It is not an encoded content frame.
            // Count only frames in this track's nonempty presentation ranges.
            guard contentRanges.contains(where: { CMTimeRangeContainsTime($0, time: time) }) else {
                XCTAssertLessThan(CMTimeCompare(time, contentStart), 0, "Only leading empty-edit fill may appear outside the content ranges")
                continue
            }
            if first == nil || CMTimeCompare(time, first!) < 0 { first = time }
            if last == nil || CMTimeCompare(time, last!) > 0 { last = time }
            count += CMSampleBufferGetNumSamples(sample)
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(count, expectedFrames, "Export must preserve every input video frame")
        let firstTime = try XCTUnwrap(first), lastTime = try XCTUnwrap(last)
        XCTAssertLessThanOrEqual(firstTime.seconds, maximumFirstTime, "Remove the common empty lead-in while retaining real initial-frame timing")
        XCTAssertGreaterThanOrEqual(CMTimeSubtract(lastTime, firstTime).seconds, 11)
        let generator = AVAssetImageGenerator(asset: asset)
        // Reader buffers may expose source timestamps even after an edit maps
        // them onto a different presentation timeline. Image generation takes
        // presentation time; request bounded windows at the exported endpoints.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        let firstImage = try await generator.image(at: CMTime(seconds: 0.25, preferredTimescale: 600))
        let lastImage = try await generator.image(at: CMTime(seconds: result.duration - 0.25, preferredTimescale: 600))
        XCTAssertGreaterThan(firstImage.image.width, 0); XCTAssertGreaterThan(lastImage.image.width, 0)
        XCTAssertLessThan(firstImage.actualTime.seconds, 1)
        XCTAssertGreaterThan(lastImage.actualTime.seconds, result.duration - 1.5)
    }
    private func candidate(_ path: String) -> MediaCandidate {
        MediaCandidate(url: base.appendingPathComponent(path), pageURL: base, frameURL: base,
            title: "Synthetic HLS export fixture", kind: .hls, source: "fixture", mimeType: "application/vnd.apple.mpegurl")
    }
}
