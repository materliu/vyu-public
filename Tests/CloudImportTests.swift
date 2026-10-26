import AVFoundation
import XCTest
@testable import VYu

/// Cloud transport is not involved: these packages contain only the generated local fixture.
@MainActor final class CloudImportTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8765")!
    private var directories: [URL] = []
    private var managers: [DownloadManager] = []
    private var fixtureReady = false

    override func setUp() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(from: base.appendingPathComponent("__health")) }
        catch let error as URLError where error.code == .cannotConnectToHost {
            throw XCTSkip("Generate fixtures and start fixtures/server.py to run cloud import tests.")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let health = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              health["ready"] as? Bool == true else {
            XCTFail("Fixture server is reachable but media generation is incomplete.")
            throw CloudVideoArchiveError.invalidMedia
        }
        fixtureReady = true
        try await setOffline(false)
    }

    override func tearDown() async throws {
        defer {
            for manager in managers {
                for id in manager.records.map(\.id) { manager.removeRecord(id: id) }
            }
            managers = []
            for directory in directories { try? FileManager.default.removeItem(at: directory) }
            directories = []
        }
        if fixtureReady { try await setOffline(false) }
    }

    func testImportedVideoPlaysWithoutSourceAndKeepsOnlySafeMetadata() async throws {
        let (manifest, package) = try await makePackage()
        let manager = try makeManager()
        try await setOffline(true)
        let (_, unavailable) = try await URLSession.shared.data(from: base.appendingPathComponent("media/direct.mp4"))
        XCTAssertEqual((unavailable as? HTTPURLResponse)?.statusCode, 503)

        let record = try await manager.importCloudVideo(manifest: manifest, from: package)
        XCTAssertEqual(record.id, manifest.id)
        XCTAssertEqual(record.phase, .complete)
        XCTAssertEqual(record.hasAudio, true)
        XCTAssertEqual(record.duration ?? 0, 8, accuracy: 0.2)
        XCTAssertEqual(record.candidate.source, "iCloud")
        XCTAssertEqual(record.candidate.url.absoluteString, "https://icloud.invalid/video/\(manifest.id.uuidString)")
        XCTAssertEqual(record.candidate.pageURL.absoluteString, "https://example.test/")
        XCTAssertEqual(record.candidate.frameURL, record.candidate.pageURL)
        let local = try XCTUnwrap(manager.localURL(for: record))
        XCTAssertTrue(local.path.hasPrefix(manager.rootDirectory.appendingPathComponent("Media").path + "/"))
        let asset = AVURLAsset(url: local, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        player.play()
        try await waitUntil { player.currentTime().seconds > 0.3 || player.currentItem?.status == .failed }
        XCTAssertNotEqual(player.currentItem?.status, .failed)
        XCTAssertGreaterThan(player.currentTime().seconds, 0.3)

        let archive = try String(contentsOf: manager.rootDirectory.appendingPathComponent("downloads.json"), encoding: .utf8)
        XCTAssertFalse(archive.contains("secret"))
        XCTAssertFalse(archive.contains("signed-token"))
        let restored = DownloadManager(rootDirectory: manager.rootDirectory)
        managers.append(restored)
        XCTAssertEqual(restored.records.first?.id, manifest.id)
        XCTAssertNotNil(restored.records.first.flatMap { restored.localURL(for: $0) })
    }

    func testTamperedPackageDoesNotCreateRecordOrMedia() async throws {
        let (manifest, package) = try await makePackage()
        try Data("tampered".utf8).write(to: package.appendingPathComponent("video.mp4"))
        let manager = try makeManager()
        do {
            _ = try await manager.importCloudVideo(manifest: manifest, from: package)
            XCTFail("An altered cloud file must fail its size and SHA-256 checks.")
        } catch { XCTAssertTrue(error is CloudVideoArchiveError) }
        try assertEmptyImport(manager)
    }

    func testAccountChangeAfterCopyPreventsLateImport() async throws {
        let (manifest, package) = try await makePackage()
        let manager = try makeManager()
        var checks = 0
        do {
            _ = try await manager.importCloudVideo(manifest: manifest, from: package) {
                checks += 1
                return checks == 1
            }
            XCTFail("An outdated cloud operation must not commit its copied video.")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertGreaterThanOrEqual(checks, 2, "Cancellation is checked again after asynchronous work.")
        try assertEmptyImport(manager)
    }

    func testExistingCompleteVideoIsNeverOverwrittenAndDeletedCacheCanBeRestored() async throws {
        let (manifest, package) = try await makePackage()
        let manager = try makeManager()
        let original = try await manager.importCloudVideo(manifest: manifest, from: package)
        let originalURL = try XCTUnwrap(manager.localURL(for: original))
        let originalData = try Data(contentsOf: originalURL)
        let changedMetadata = replacing(manifest, title: "Do not replace the local title")
        let repeated = try await manager.importCloudVideo(manifest: changedMetadata, from: package)
        XCTAssertEqual(repeated, original)
        XCTAssertEqual(manager.records, [original])
        XCTAssertEqual(try Data(contentsOf: originalURL), originalData)
        XCTAssertEqual(try contents("Media", of: manager).count, 1)

        manager.removeCache(id: original.id)
        XCTAssertEqual(manager.records.first?.phase, .cancelled)
        let restored = try await manager.importCloudVideo(manifest: manifest, from: package)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.phase, .complete)
        XCTAssertEqual(manager.records.count, 1)
        XCTAssertNotEqual(restored.localRelativePath, original.localRelativePath)
        XCTAssertEqual(try contents("Media", of: manager).count, 1)
    }

    func testPausedDownloadWithSameIdentityIsPreserved() async throws {
        let (manifest, package) = try await makePackage()
        let directory = try temporaryDirectory()
        var paused = sourceRecord(id: manifest.id)
        paused.phase = .paused; paused.progress = 0.25; paused.localRelativePath = nil
        let saved = try JSONEncoder().encode([paused])
        try saved.write(to: directory.appendingPathComponent("downloads.json"))
        let manager = DownloadManager(rootDirectory: directory)
        managers.append(manager)
        do {
            _ = try await manager.importCloudVideo(manifest: manifest, from: package)
            XCTFail("A paused local download must remain available to resume.")
        } catch { XCTAssertTrue(error is DownloadIssue) }
        XCTAssertEqual(manager.records, [paused])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("downloads.json")), saved)
        XCTAssertTrue(try contents("Media", of: manager).isEmpty)
    }

    func testPersistenceFailureLeavesNoImportedRecordOrFile() async throws {
        let (manifest, package) = try await makePackage()
        let manager = try makeManager()
        // A directory at the state-file path makes the atomic state write fail without relying on disk pressure.
        try FileManager.default.createDirectory(at: manager.rootDirectory.appendingPathComponent("downloads.json"), withIntermediateDirectories: false)
        do {
            _ = try await manager.importCloudVideo(manifest: manifest, from: package)
            XCTFail("A video must not be published when its state cannot be persisted.")
        } catch { XCTAssertTrue(error is CloudVideoArchiveError) }
        XCTAssertNotNil(manager.storageError)
        try assertEmptyImport(manager)
    }

    func testIncorrectDurationOrAudioMetadataCannotMarkVideoComplete() async throws {
        let (manifest, package) = try await makePackage()
        for invalid in [replacing(manifest, duration: 80), replacing(manifest, hasAudio: false)] {
            let manager = try makeManager()
            do {
                _ = try await manager.importCloudVideo(manifest: invalid, from: package)
                XCTFail("Matching bytes alone do not validate media duration and audio tracks.")
            } catch { XCTAssertTrue(error is CloudVideoArchiveError) }
            try assertEmptyImport(manager)
        }
    }

    private func makePackage() async throws -> (CloudVideoManifest, URL) {
        let directory = try temporaryDirectory()
        let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("media/direct.mp4"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let source = directory.appendingPathComponent("source.mp4")
        try data.write(to: source)
        let record = sourceRecord(id: UUID())
        let package = directory.appendingPathComponent(record.id.uuidString, isDirectory: true)
        return (try CloudVideoArchive.createStagingPackage(record: record, mediaURL: source, at: package), package)
    }

    private func sourceRecord(id: UUID) -> DownloadRecord {
        let page = URL(string: "https://example.test/private/secret?session=signed-token")!
        let source = URL(string: "https://cdn.example.test/video.mp4?signature=signed-token")!
        let candidate = MediaCandidate(url: source, pageURL: page, frameURL: page, title: "Cloud fixture",
            kind: .file, source: "test-fixture")
        return DownloadRecord(id: id, candidate: candidate, phase: .complete, progress: 1, bytesWritten: 1,
            expectedBytes: nil, localRelativePath: nil, failure: nil, duration: 8, hasAudio: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func replacing(_ manifest: CloudVideoManifest, title: String? = nil,
                           duration: Double? = nil, hasAudio: Bool? = nil) -> CloudVideoManifest {
        CloudVideoManifest(schemaVersion: manifest.schemaVersion, id: manifest.id, title: title ?? manifest.title,
            sourceHost: manifest.sourceHost, createdAt: manifest.createdAt, duration: duration ?? manifest.duration,
            hasAudio: hasAudio ?? manifest.hasAudio, fileExtension: manifest.fileExtension,
            byteCount: manifest.byteCount, sha256: manifest.sha256)
    }

    private func makeManager() throws -> DownloadManager {
        let manager = DownloadManager(rootDirectory: try temporaryDirectory())
        managers.append(manager)
        return manager
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-cloud-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    private func contents(_ name: String, of manager: DownloadManager) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: manager.rootDirectory.appendingPathComponent(name), includingPropertiesForKeys: nil)
    }

    private func assertEmptyImport(_ manager: DownloadManager, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(manager.records.isEmpty, file: file, line: line)
        XCTAssertTrue(try contents("Media", of: manager).isEmpty, file: file, line: line)
        XCTAssertTrue(try contents("Staging", of: manager).isEmpty, file: file, line: line)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard condition() else { XCTFail("The imported local video did not start playing."); throw CloudVideoArchiveError.invalidMedia }
    }

    private func setOffline(_ offline: Bool) async throws {
        var request = URLRequest(url: base.appendingPathComponent("__control"))
        request.httpMethod = "POST"
        request.httpBody = Data("{\"offline\":\(offline)}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
}
