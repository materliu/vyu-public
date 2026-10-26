import AVFoundation
import XCTest
@testable import VYu

@MainActor final class LocalVideoImportTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8765")!
    private var roots: [URL] = []
    private var managers: [DownloadManager] = []

    override func tearDown() async throws {
        for manager in managers {
            for id in manager.records.map(\.id) { manager.removeRecord(id: id) }
        }
        for root in roots { try? FileManager.default.removeItem(at: root) }
        managers = []; roots = []
    }

    func testImportedVideoIsVerifiedOfflineAndEligibleForCloudWithoutFakeWebsite() async throws {
        let source = try await fixture("direct.mp4")
        let manager = try makeManager()
        let record = try await manager.importLocalVideo(from: source, title: "  录屏片段  ")
        XCTAssertEqual(record.phase, .complete)
        XCTAssertEqual(record.candidate.title, "录屏片段")
        XCTAssertEqual(record.candidate.source, "localImport")
        XCTAssertEqual(record.candidate.url.scheme, "vyu-local")
        XCTAssertNil(record.candidate.pageURL.host)
        XCTAssertFalse(record.candidate.url.absoluteString.contains(source.path))
        XCTAssertEqual(record.duration ?? 0, 8, accuracy: 0.25)
        XCTAssertEqual(record.hasAudio, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "The picker owns the selected source copy.")
        let local = try XCTUnwrap(manager.localURL(for: record))
        XCTAssertNotEqual(local, source)
        XCTAssertEqual(try Data(contentsOf: local), try Data(contentsOf: source))
        let asset = AVURLAsset(url: local, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let packageRoot = try makeRoot()
        let package = packageRoot.appendingPathComponent(record.id.uuidString, isDirectory: true)
        let manifest = try CloudVideoArchive.createStagingPackage(record: record, mediaURL: local, at: package)
        XCTAssertNil(manifest.sourceHost)
        XCTAssertEqual(manifest.hasAudio, true)
        let restoredManifest = try CloudVideoArchive.readManifest(at: package)
        XCTAssertEqual(restoredManifest.id, manifest.id)
        XCTAssertEqual(restoredManifest.title, manifest.title)
        XCTAssertNil(restoredManifest.sourceHost)
        XCTAssertEqual(restoredManifest.byteCount, manifest.byteCount)
        XCTAssertEqual(restoredManifest.sha256, manifest.sha256)
        XCTAssertEqual(restoredManifest.duration, manifest.duration)
        XCTAssertEqual(restoredManifest.hasAudio, manifest.hasAudio)
        XCTAssertEqual(restoredManifest.fileExtension, manifest.fileExtension)
        XCTAssertEqual(restoredManifest.createdAt.timeIntervalSince1970, manifest.createdAt.timeIntervalSince1970, accuracy: 0.001)
        let restored = DownloadManager(rootDirectory: manager.rootDirectory)
        managers.append(restored)
        XCTAssertEqual(restored.records.first?.phase, .complete)
        XCTAssertEqual(restored.localURL(for: record), local)
    }

    func testSilentImportKeepsNoAudioStatus() async throws {
        let source = try await fixture("silent.mp4")
        let manager = try makeManager()
        let record = try await manager.importLocalVideo(from: source, title: "")
        XCTAssertEqual(record.phase, .complete)
        XCTAssertEqual(record.candidate.title, "导入的视频")
        XCTAssertEqual(record.hasAudio, false)
        XCTAssertTrue(record.failure?.contains("无声") == true)
    }

    func testPlaylistAndEmptyFilesCannotBecomeImportedVideos() async throws {
        let root = try makeRoot(), manager = try makeManager()
        for (name, data) in [("playlist.mp4", Data("#EXTM3U\n#EXTINF:8\nhttps://private.invalid/segment.ts\n#EXT-X-ENDLIST\n".utf8)),
                             ("empty.mov", Data())] {
            let source = root.appendingPathComponent(name)
            try data.write(to: source)
            do { _ = try await manager.importLocalVideo(from: source, title: "Rejected"); XCTFail("Invalid local media was imported.") }
            catch { }
            XCTAssertTrue(manager.records.isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: manager.rootDirectory.appendingPathComponent("Media").path).isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testCancelledImportLeavesNoRecordOrMedia() async throws {
        let source = try await fixture("direct.mp4"), manager = try makeManager()
        let task = Task { try await manager.importLocalVideo(from: source, title: "Cancelled") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled import must not complete.") }
        catch is CancellationError { }
        XCTAssertTrue(manager.records.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: manager.rootDirectory.appendingPathComponent("Media").path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testFastStartMovieWithMissingTailCannotBeImportedFromMetadataAlone() async throws {
        let complete = try await fixture("direct.mp4"), manager = try makeManager()
        let bytes = try Data(contentsOf: complete)
        let source = try makeRoot().appendingPathComponent("truncated.mp4")
        try bytes.prefix(bytes.count * 3 / 4).write(to: source)
        let metadata = AVURLAsset(url: source)
        let playable = try await metadata.load(.isPlayable)
        let duration = try await metadata.load(.duration).seconds
        XCTAssertTrue(playable, "Fast-start metadata still advertises a playable movie after its tail is removed.")
        XCTAssertEqual(duration, 8, accuracy: 0.25)
        do { _ = try await manager.importLocalVideo(from: source, title: "Truncated"); XCTFail("Metadata alone must not admit an incomplete imported movie.") }
        catch { }
        XCTAssertTrue(manager.records.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: manager.rootDirectory.appendingPathComponent("Media").path).isEmpty)
    }

    func testAudioOnlyFileCannotBecomeImportedVideo() async throws {
        let source = try await fixture("direct.mp4"), manager = try makeManager()
        let input = AVURLAsset(url: source)
        let composition = AVMutableComposition()
        let audioTracks = try await input.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(audioTracks.first)
        let outputTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try outputTrack.insertTimeRange(CMTimeRange(start: .zero, duration: try await input.load(.duration)), of: track, at: .zero)
        let exported = try makeRoot().appendingPathComponent("audio-only.mp4")
        let session = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A))
        session.outputURL = exported; session.outputFileType = .m4a
        await session.export()
        XCTAssertEqual(session.status, .completed)
        do { _ = try await manager.importLocalVideo(from: exported, title: "Audio"); XCTFail("Audio-only media was imported as a video.") }
        catch { }
        XCTAssertTrue(manager.records.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: manager.rootDirectory.appendingPathComponent("Media").path).isEmpty)
    }

    private func fixture(_ name: String) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("media/" + name))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Generate fixtures and run fixtures/server.py before integration tests.")
        let file = try makeRoot().appendingPathComponent(name)
        try data.write(to: file)
        return file
    }

    private func makeManager() throws -> DownloadManager {
        let manager = DownloadManager(rootDirectory: try makeRoot())
        managers.append(manager)
        return manager
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-local-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }
}
