import XCTest
@testable import VYu

final class SelectedVideoFileTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
    }

    func testPickerCopyOutlivesProviderURLAndRemovesOnlyOwnedTemporaryFile() throws {
        let root = try makeDirectory()
        let provider = root.appendingPathComponent("source.mov")
        let bytes = Data(repeating: 0x51, count: 128)
        try bytes.write(to: provider)
        var selected: SelectedVideoFile? = try SelectedVideoFile.copy(from: provider, temporaryDirectory: root)
        let copy = try XCTUnwrap(selected?.url)
        XCTAssertNotEqual(copy, provider)
        try FileManager.default.removeItem(at: provider)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        withExtendedLifetime(selected) { XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path)) }
        selected = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testRejectsEmptySymbolicAndUnsupportedFilesWithoutCreatingTemporaryDirectories() throws {
        let root = try makeDirectory()
        let empty = root.appendingPathComponent("empty.mp4")
        let unsupported = root.appendingPathComponent("source.txt")
        let link = root.appendingPathComponent("link.mp4")
        try Data().write(to: empty)
        try Data([1, 2, 3]).write(to: unsupported)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unsupported)
        for source in [empty, unsupported, link, URL(string: "https://example.test/video.mp4")!] {
            XCTAssertThrowsError(try SelectedVideoFile.copy(from: source, temporaryDirectory: root))
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(remaining.contains { $0.hasPrefix("VYuVideoImport-") })
    }

    func testCancelledPickerTransferDoesNotLeaveCopy() async throws {
        let root = try makeDirectory()
        let provider = root.appendingPathComponent("source.mp4")
        try Data([1, 2, 3]).write(to: provider)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SelectedVideoFile.copy(from: provider, temporaryDirectory: root)
        }
        do { _ = try await task.value; XCTFail("A cancelled transfer must not create an owned file.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source.mp4"])
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SelectedVideoFileTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }
}
