import AVFoundation
import UIKit
import XCTest
@testable import VYu

@MainActor final class VideoCoverFrameTests: XCTestCase {
    func testSelectedFrameUsesRequestedTimeInsteadOfOpeningKeyframe() async throws {
        try await withTimeline { source in
            for (seconds, expected) in [(1.0, Color.black), (3.0, .red), (5.0, .green), (7.0, .blue)] {
                let data = await LocalVideoThumbnailRenderer.frameJPEG(url: source, seconds: seconds, duration: 8)
                let color = try self.sample(XCTUnwrap(data))
                self.assert(color, is: expected)
            }
        }
    }

    func testAutomaticCoverSkipsBlackOpening() async throws {
        try await withTimeline { source in
            let data = await LocalVideoThumbnailRenderer.jpeg(url: source, duration: 8)
            let color = try self.sample(XCTUnwrap(data))
            self.assert(color, is: .red)
        }
    }

    func testSelectedFrameRejectsInvalidAndEndTimesWithoutOpeningFallback() async throws {
        try await withTimeline { source in
            for seconds in [-0.1, .nan, .infinity, -.infinity, 8, 9] {
                let data = await LocalVideoThumbnailRenderer.frameJPEG(url: source, seconds: seconds, duration: 100)
                XCTAssertNil(data, "No frame exists at invalid or end time \(seconds).")
            }
        }
    }

    func testActualAssetDurationControlsBoundsEvenWhenSavedMetadataIsWrong() async throws {
        try await withTimeline { source in
            let data = await LocalVideoThumbnailRenderer.frameJPEG(url: source, seconds: 7, duration: 1)
            let color = try self.sample(XCTUnwrap(data))
            self.assert(color, is: .blue)
        }
    }

    func testSelectedFrameRejectsRemoteMissingAndCancelledInputs() async throws {
        let remote = await LocalVideoThumbnailRenderer.frameJPEG(
            url: URL(string: "https://example.test/video.mp4")!, seconds: 0, duration: 8)
        XCTAssertNil(remote)
        let missing = await LocalVideoThumbnailRenderer.frameJPEG(
            url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4"),
            seconds: 0, duration: 8)
        XCTAssertNil(missing)
        try await withTimeline { source in
            let operation = Task { await LocalVideoThumbnailRenderer.frameJPEG(url: source, seconds: 3, duration: 8) }
            operation.cancel()
            let cancelled = await operation.value
            XCTAssertNil(cancelled)
        }
    }

    func testAllBlackVideoStillHasUsableAutomaticCover() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("black.mov")
        try await writeBlackVideo(to: source)
        let data = await LocalVideoThumbnailRenderer.jpeg(url: source, duration: 1)
        let color = try sample(XCTUnwrap(data))
        assert(color, is: .black)
    }

    private func withTimeline(_ body: (URL) async throws -> Void) async throws {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8765/media/cover-timeline.mp4")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("Generate the cover timeline fixture and start fixtures/server.py before running cover tests.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("cover-timeline.mp4")
        try data.write(to: source, options: [.completeFileProtectionUntilFirstUserAuthentication])
        try await body(source)
    }

    private enum Color { case black, red, green, blue }
    private func sample(_ data: Data) throws -> [UInt8] {
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        var pixels = [UInt8](repeating: 0, count: 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        XCTAssertTrue(rendered)
        return pixels
    }

    private func assert(_ pixels: [UInt8], is expected: Color, file: StaticString = #filePath, line: UInt = #line) {
        let red = Int(pixels[0]), green = Int(pixels[1]), blue = Int(pixels[2])
        switch expected {
        case .black: XCTAssertLessThan(max(red, green, blue), 20, file: file, line: line)
        case .red:
            XCTAssertGreaterThan(red, 150, file: file, line: line)
            XCTAssertGreaterThan(red, max(green, blue) * 3, file: file, line: line)
        case .green:
            XCTAssertGreaterThan(green, 75, file: file, line: line)
            XCTAssertGreaterThan(green, max(red, blue) * 3, file: file, line: line)
        case .blue:
            XCTAssertGreaterThan(blue, 150, file: file, line: line)
            XCTAssertGreaterThan(blue, max(red, green) * 3, file: file, line: line)
        }
    }

    private func writeBlackVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 18])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 18])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 18, kCVPixelFormatType_32BGRA,
            nil, &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let address = CVPixelBufferGetBaseAddress(buffer) {
            memset(address, 0, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for index in 0..<4 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 4)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
}
