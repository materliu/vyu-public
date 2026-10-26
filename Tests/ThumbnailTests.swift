import AVFoundation
import UIKit
import XCTest
@testable import VYu

@MainActor final class ThumbnailTests: XCTestCase {
    func testLocalVideoFrameRespectsRotationAndSize() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("rotated.mov")
        try await writeRotatedVideo(to: source)
        let store = VideoThumbnailStore(directory: directory.appendingPathComponent("Thumbnails"))
        let result = await store.image(for: record(), localURL: source)
        let image = try XCTUnwrap(result?.cgImage)
        XCTAssertLessThan(image.width, image.height, "The portrait track transform must be applied.")
        XCTAssertEqual(Double(image.width) / Double(image.height), 0.5, accuracy: 0.03)
        XCTAssertLessThanOrEqual(image.width, 480)
        XCTAssertLessThanOrEqual(image.height, 270)
    }

    func testPausedDecoderProducesRotatedFrameWithoutAPlayerViewOrAudioSessionChanges() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("paused-rotated.mov")
        try await writeRotatedVideo(to: source)
        let asset = AVURLAsset(url: source, options: [AVURLAssetReferenceRestrictionsKey:
            AVAssetReferenceRestrictions.forbidLocalReferenceToRemote.rawValue])
        let item = AVPlayerItem(asset: asset)
        let audio = AVAudioSession.sharedInstance()
        let category = audio.category, mode = audio.mode
        // Exercise the same paused seek/preroll/video-output path as offline
        // HLS, using a generated local movie and no UIWindow/UIView/AVPlayerLayer.
        let data = await LocalVideoThumbnailRenderer.playerJPEG(item: item, seconds: 0.25)
        let image = try XCTUnwrap(data.flatMap(UIImage.init(data:))?.cgImage)
        XCTAssertLessThan(image.width, image.height)
        XCTAssertEqual(Double(image.width) / Double(image.height), 0.5, accuracy: 0.03)
        XCTAssertLessThanOrEqual(image.width, 480)
        XCTAssertLessThanOrEqual(image.height, 270)
        XCTAssertEqual(audio.category, category)
        XCTAssertEqual(audio.mode, mode)
        XCTAssertTrue(item.outputs.isEmpty, "Temporary video output must be detached after extraction.")
    }

    func testTransientFailureCanRetryAfterCooldownWithoutChangingTheVideo() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fakeSource(in: directory)
        let entry = record()
        var now = Date(timeIntervalSince1970: 100)
        var calls = 0
        let store = VideoThumbnailStore(directory: directory.appendingPathComponent("Thumbnails"), now: { now }) { _, _ in
            calls += 1
            return calls == 1 ? nil : self.jpeg()
        }
        let unavailable = await store.image(for: entry, localURL: source)
        XCTAssertNil(unavailable)
        now.addTimeInterval(10)
        let coolingDown = await store.image(for: entry, localURL: source)
        XCTAssertNil(coolingDown)
        XCTAssertEqual(calls, 1, "Scrolling must not immediately restart a failing decoder.")
        now.addTimeInterval(21)
        let recovered = await store.image(for: entry, localURL: source)
        XCTAssertNotNil(recovered)
        XCTAssertEqual(calls, 2)
    }

    func testConcurrentRequestsShareGenerationAndDiskCacheSurvivesRestart() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fakeSource(in: directory)
        let cache = directory.appendingPathComponent("Thumbnails")
        let data = jpeg()
        var calls = 0
        let store = VideoThumbnailStore(directory: cache) { _, _ in
            calls += 1
            try? await Task.sleep(for: .milliseconds(50))
            return data
        }
        let entry = record()
        async let first = store.image(for: entry, localURL: source)
        async let second = store.image(for: entry, localURL: source)
        let images = await (first, second)
        XCTAssertNotNil(images.0)
        XCTAssertNotNil(images.1)
        XCTAssertEqual(calls, 1)
        let cached = try XCTUnwrap(cacheFiles(cache).first)
        let attributes = try FileManager.default.attributesOfItem(atPath: cached.path)
        let control = directory.appendingPathComponent("protected-control")
        try Data([1]).write(to: control, options: [.completeFileProtectionUntilFirstUserAuthentication])
        let controlAttributes = try FileManager.default.attributesOfItem(atPath: control.path)
        let protection = attributes[.protectionKey] as? String
        let expectedProtection = FileProtectionType.completeUntilFirstUserAuthentication.rawValue
        #if targetEnvironment(simulator)
        if controlAttributes[.protectionKey] == nil {
            XCTAssertNil(protection)
            print("Simulator reports no Data Protection attribute for either the cache or the protected control file; device enforcement remains unverified.")
        } else { XCTAssertEqual(protection, expectedProtection) }
        #else
        XCTAssertEqual(controlAttributes[.protectionKey] as? String, expectedProtection)
        XCTAssertEqual(protection, expectedProtection)
        #endif
        XCTAssertEqual(try cache.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        var restoredCalls = 0
        let restored = VideoThumbnailStore(directory: cache) { _, _ in restoredCalls += 1; return nil }
        let restoredImage = await restored.image(for: entry, localURL: source)
        XCTAssertNotNil(restoredImage)
        XCTAssertEqual(restoredCalls, 0)
        restored.retainRecords([])
        XCTAssertTrue(cacheFiles(cache).isEmpty)
    }

    func testDeletionWhileGeneratingCannotRestoreCache() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fakeSource(in: directory)
        let cache = directory.appendingPathComponent("Thumbnails")
        var continuation: CheckedContinuation<Data?, Never>?
        let store = VideoThumbnailStore(directory: cache) { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        let entry = record()
        let pending = Task { await store.image(for: entry, localURL: source) }
        try await waitUntil { continuation != nil }
        store.remove(id: entry.id)
        continuation?.resume(returning: jpeg())
        let image = await pending.value
        XCTAssertNil(image)
        XCTAssertTrue(cacheFiles(cache).isEmpty)
    }

    func testSourceReplacementInvalidatesOlderPreview() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fakeSource(in: directory)
        let cache = directory.appendingPathComponent("Thumbnails")
        var calls = 0
        let store = VideoThumbnailStore(directory: cache) { _, _ in calls += 1; return self.jpeg() }
        let entry = record()
        let first = await store.image(for: entry, localURL: source)
        XCTAssertNotNil(first)
        let firstName = try XCTUnwrap(cacheFiles(cache).first?.lastPathComponent)
        try Data(repeating: 7, count: 100).write(to: source)
        let replaced = await store.image(for: entry, localURL: source)
        XCTAssertNotNil(replaced)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(cacheFiles(cache).count, 1)
        XCTAssertNotEqual(cacheFiles(cache).first?.lastPathComponent, firstName)
        try FileManager.default.removeItem(at: source)
        let missing = await store.image(for: entry, localURL: source)
        XCTAssertNil(missing)
        XCTAssertTrue(cacheFiles(cache).isEmpty)
    }

    func testRejectsRemoteAndUnfinishedSourcesBeforeRendering() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fakeSource(in: directory)
        var calls = 0
        let store = VideoThumbnailStore(directory: directory.appendingPathComponent("Thumbnails")) { _, _ in
            calls += 1; return self.jpeg()
        }
        var unfinished = record(); unfinished.phase = .downloading
        let remote = await store.image(for: record(), localURL: URL(string: "https://example.test/video.mp4"))
        let downloading = await store.image(for: unfinished, localURL: source)
        XCTAssertNil(remote)
        XCTAssertNil(downloading)
        XCTAssertEqual(calls, 0)
    }

    func testConcurrentDecodingIsLimitedToTwo() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fakeSource(in: directory)
        var active = 0, maximumActive = 0
        let store = VideoThumbnailStore(directory: directory.appendingPathComponent("Thumbnails")) { _, _ in
            active += 1
            maximumActive = max(active, maximumActive)
            defer { active -= 1 }
            try? await Task.sleep(for: .milliseconds(70))
            return self.jpeg()
        }
        let pending = (0..<5).map { _ in
            let entry = record()
            return Task { await store.image(for: entry, localURL: source) }
        }
        for task in pending {
            let result = await task.value
            XCTAssertNotNil(result)
        }
        XCTAssertEqual(maximumActive, 2)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func fakeSource(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("source.mp4")
        try Data([0, 1, 2]).write(to: url)
        return url
    }
    private func cacheFiles(_ directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }
    private func jpeg() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }
    }
    private func record() -> DownloadRecord {
        let url = URL(string: "https://example.test/video.mp4")!
        let candidate = MediaCandidate(url: url, pageURL: url, frameURL: url, title: "Fixture", kind: .file, source: "test")
        return DownloadRecord(id: UUID(), candidate: candidate, phase: .complete, progress: 1,
            bytesWritten: 1, expectedBytes: nil, localRelativePath: "source.mp4", failure: nil,
            duration: 1, hasAudio: false, createdAt: Date())
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Thumbnail operation did not start.")
        throw NSError(domain: "ThumbnailTests", code: 1)
    }

    /// A landscape pixel buffer with a 90-degree display transform becomes portrait video.
    private func writeRotatedVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 80, AVVideoHeightKey: 40])
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 40, ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 80, kCVPixelBufferHeightKey as String: 40])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 80, 40, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 80, height: 40,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(UIColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        context.setFillColor(UIColor.blue.cgColor); context.fill(CGRect(x: 40, y: 0, width: 40, height: 40))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for index in 0..<3 {
            try await waitUntil { input.isReadyForMoreMediaData }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 2)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
}
