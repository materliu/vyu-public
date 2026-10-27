import Combine
import Foundation
import XCTest
@testable import VYu

@MainActor final class VideoRenameTests: XCTestCase {
    private var roots: [URL] = []
    private var managers: [DownloadManager] = []

    override func tearDown() async throws {
        for manager in managers {
            manager.pauseDownloads(ids: Set(manager.records.map(\.id)))
            for id in manager.records.map(\.id) { manager.removeRecord(id: id) }
        }
        for root in roots { try? FileManager.default.removeItem(at: root) }
        managers = []; roots = []
    }

    func testRenamePersistsTrimmedNameAndSearchUsesDisplayNameAfterRestart() throws {
        let root = try temporaryRoot(), id = UUID()
        let store = VideoMetadataStore(rootDirectory: root)
        try store.setTags(["练习"], for: id)
        try store.rename("  湖边笔记 / 第一段：春日  \n", for: id, fallback: "原始卡片标题")
        let restarted = VideoMetadataStore(rootDirectory: root)
        let title = restarted.displayTitle(for: id, fallback: "下载后来更新的原始标题")
        XCTAssertEqual(title, "湖边笔记 / 第一段：春日")
        XCTAssertTrue(VideoMetadataSearch.matches(title: title, tags: restarted.tags(for: id), query: "湖边 #练习"))
        XCTAssertFalse(VideoMetadataSearch.matches(title: title, tags: restarted.tags(for: id), query: "原始卡片"))
        XCTAssertEqual(restarted.entries, store.entries)
    }

    func testUnchangedNameDoesNotCreateOrRewriteMetadata() throws {
        let root = try temporaryRoot(), id = UUID()
        let store = VideoMetadataStore(rootDirectory: root)
        XCTAssertEqual(store.displayTitle(for: id, fallback: " \n"), "视频")
        try store.rename("  原始名称 \n", for: id, fallback: " 原始名称 ")
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataFile(root).path))
        try store.rename("新的名称", for: id, fallback: "原始名称")
        let saved = store.metadata(for: id)
        let bytes = try Data(contentsOf: metadataFile(root))
        var publications = 0
        let observation = store.$entries.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        for _ in 0..<3 { try store.rename("  新的名称 \n", for: id, fallback: "原始名称") }
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(store.metadata(for: id), saved)
        XCTAssertEqual(try Data(contentsOf: metadataFile(root)), bytes)
    }

    func testEmptyAndOversizedNamesLeaveSavedStateUntouched() throws {
        let root = try temporaryRoot(), id = UUID()
        let store = VideoMetadataStore(rootDirectory: root)
        try store.rename("保留名称", for: id, fallback: "原名")
        let saved = store.entries, bytes = try Data(contentsOf: metadataFile(root))
        var publications = 0
        let observation = store.$entries.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        for title in ["", "  ", "\n\r\t", "　 \n"] {
            XCTAssertThrowsError(try store.rename(title, for: id, fallback: "原名")) {
                XCTAssertEqual($0 as? VideoMetadataError, .emptyTitle)
            }
        }
        for title in [String(repeating: "a", count: 4_097), String(repeating: "🙂", count: 1_025)] {
            XCTAssertThrowsError(try store.rename(title, for: id, fallback: "原名")) {
                XCTAssertEqual($0 as? VideoMetadataError, .titleTooLong)
            }
        }
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(store.entries, saved)
        XCTAssertEqual(try Data(contentsOf: metadataFile(root)), bytes)
    }

    func testLongUnicodeAndDuplicateNamesAreNotTruncatedOrMadeUnique() throws {
        let root = try temporaryRoot(), first = UUID(), second = UUID()
        let store = VideoMetadataStore(rootDirectory: root)
        let title = String(repeating: "🙂", count: 1_024)
        XCTAssertGreaterThan(title.count, 240)
        XCTAssertEqual(title.utf8.count, 4_096)
        try store.rename(title, for: first, fallback: "原名甲")
        try store.rename(title, for: second, fallback: "原名乙")
        let restarted = VideoMetadataStore(rootDirectory: root)
        XCTAssertEqual(restarted.displayTitle(for: first, fallback: "原名甲"), title)
        XCTAssertEqual(restarted.displayTitle(for: second, fallback: "原名乙"), title)
        XCTAssertEqual(restarted.entries.count, 2)
    }

    func testRenameAndOrganizationEditsPreserveEachOthersFields() throws {
        let root = try temporaryRoot(), id = UUID()
        let store = VideoMetadataStore(rootDirectory: root)
        try store.toggleFavorite(id)
        try store.setTags(["保留标签"], for: id)
        try store.setCoverFrameSeconds(3.25, for: id)
        try store.rename("新名称", for: id, fallback: "原名")
        XCTAssertTrue(store.isFavorite(id))
        XCTAssertEqual(store.tags(for: id), ["保留标签"])
        XCTAssertEqual(store.coverFrameSeconds(for: id), 3.25)
        try store.toggleFavorite(id)
        try store.setTags(["后来编辑"], for: id)
        try store.setCoverFrameSeconds(1.5, for: id)
        XCTAssertEqual(store.displayTitle(for: id, fallback: "原名"), "新名称")
        try store.setCoverFrameSeconds(nil, for: id)
        try store.rename("第二次名称", for: id, fallback: "原名")
        let restarted = VideoMetadataStore(rootDirectory: root)
        XCTAssertEqual(restarted.displayTitle(for: id, fallback: "原名"), "第二次名称")
        XCTAssertFalse(restarted.isFavorite(id))
        XCTAssertEqual(restarted.tags(for: id), ["后来编辑"])
        XCTAssertNil(restarted.coverFrameSeconds(for: id))
    }

    func testLegacyArchiveWithoutCustomTitleRetainsOtherMetadata() throws {
        let root = try temporaryRoot(), id = UUID()
        let entry = VideoMetadata(id: id, isFavorite: true, tags: ["旧标签"], updatedAt: Date(timeIntervalSince1970: 100),
            revision: UUID(), coverFrameSeconds: 2.5)
        let file = metadataFile(root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Archive(schemaVersion: 1, entries: [entry]))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("customTitle"))
        try data.write(to: file)
        let store = VideoMetadataStore(rootDirectory: root)
        XCTAssertNil(store.metadata(for: id)?.customTitle)
        XCTAssertEqual(store.displayTitle(for: id, fallback: "旧标题"), "旧标题")
        try store.rename("新标题", for: id, fallback: "旧标题")
        XCTAssertTrue(store.isFavorite(id))
        XCTAssertEqual(store.tags(for: id), ["旧标签"])
        XCTAssertEqual(store.coverFrameSeconds(for: id), 2.5)
        XCTAssertEqual(VideoMetadataStore(rootDirectory: root).displayTitle(for: id, fallback: "旧标题"), "新标题")
    }

    func testStaleMergeCannotReplaceRenamedTitleAndNewerMergeUsesExistingConflictOrder() throws {
        let root = try temporaryRoot(), id = UUID()
        let store = VideoMetadataStore(rootDirectory: root)
        try store.setTags(["原标签"], for: id)
        let stale = try XCTUnwrap(store.metadata(for: id))
        try store.rename("较新名称", for: id, fallback: "原名")
        let renamed = try XCTUnwrap(store.metadata(for: id))
        try store.merge([id: stale])
        XCTAssertEqual(store.metadata(for: id), renamed)
        var newer = renamed
        newer.customTitle = "另一设备的新名称"
        newer.updatedAt = renamed.updatedAt.addingTimeInterval(1)
        newer.revision = UUID()
        try store.merge([id: newer])
        XCTAssertEqual(store.metadata(for: id), newer)
        XCTAssertEqual(VideoMetadataStore(rootDirectory: root).displayTitle(for: id, fallback: "原名"), newer.customTitle)
    }

    func testInvalidIncomingTitlesCannotReplaceLocalMetadata() throws {
        let root = try temporaryRoot(), id = UUID()
        let store = VideoMetadataStore(rootDirectory: root)
        try store.rename("保留名称", for: id, fallback: "原名")
        let original = try XCTUnwrap(store.metadata(for: id))
        let bytes = try Data(contentsOf: metadataFile(root))
        for title in ["", "  ", " 未规范化 ", String(repeating: "a", count: 4_097)] {
            var incoming = original
            incoming.customTitle = title
            incoming.updatedAt = original.updatedAt.addingTimeInterval(10)
            incoming.revision = UUID()
            XCTAssertThrowsError(try store.merge([id: incoming]))
        }
        XCTAssertEqual(store.metadata(for: id), original)
        XCTAssertEqual(try Data(contentsOf: metadataFile(root)), bytes)
    }

    func testLongTitleCloudSidecarRoundTripKeepsFavoriteTagsAndCover() throws {
        let firstRoot = try temporaryRoot(), secondRoot = try temporaryRoot(), cloud = try temporaryRoot(), id = UUID()
        let first = VideoMetadataStore(rootDirectory: firstRoot)
        let title = String(repeating: "🙂", count: 1_024)
        try first.toggleFavorite(id)
        try first.setTags((0..<20).map { "测试标签\($0)" }, for: id)
        try first.setCoverFrameSeconds(4.5, for: id)
        try first.rename(title, for: id, fallback: "原名")
        let result = try CloudVideoMetadataFiles.synchronize(local: first.entries, allowedIDs: [id], deletedIDs: [],
            container: cloud, metadataURLs: [], ubiquitous: false)
        XCTAssertEqual(result.invalidCount, 0)
        let second = VideoMetadataStore(rootDirectory: secondRoot)
        let coldRead = try CloudVideoMetadataFiles.synchronize(local: [:], allowedIDs: [id], deletedIDs: [],
            container: cloud, metadataURLs: [], ubiquitous: false)
        XCTAssertEqual(coldRead.invalidCount, 0)
        XCTAssertEqual(coldRead.entries[id]?.customTitle, title)
        try second.merge(coldRead.entries)
        XCTAssertEqual(second.entries, first.entries)
        XCTAssertEqual(second.displayTitle(for: id, fallback: "云端旧标题"), title)
        let sidecar = CloudVideoMetadataFiles.fileURL(id, container: cloud)
        let saved = try Data(contentsOf: sidecar)
        XCTAssertLessThan(saved.count, CloudVideoMetadataFiles.maximumBytes)
        let repeated = try CloudVideoMetadataFiles.synchronize(local: second.entries, allowedIDs: [id], deletedIDs: [],
            container: cloud, metadataURLs: [], ubiquitous: false)
        XCTAssertEqual(repeated.entries, result.entries)
        XCTAssertEqual(try Data(contentsOf: sidecar), saved)
    }

    func testUnreadableArchiveCannotBeOverwrittenByRename() throws {
        let root = try temporaryRoot(), file = metadataFile(root), id = UUID()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("unreadable synthetic metadata".utf8)
        try original.write(to: file)
        let store = VideoMetadataStore(rootDirectory: root)
        XCTAssertThrowsError(try store.rename("新名称", for: id, fallback: "原名")) {
            XCTAssertEqual($0 as? VideoMetadataError, .unreadableStore)
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testFailedRenameWriteKeepsPublishedTitleAndRevision() throws {
        let root = try temporaryRoot(), id = UUID()
        let store = VideoMetadataStore(rootDirectory: root)
        try store.rename("已保存名称", for: id, fallback: "原名")
        let saved = store.entries, file = metadataFile(root)
        let bytes = try Data(contentsOf: file)
        let backup = root.appendingPathComponent("preserved-metadata.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var publications = 0
        let observation = store.$entries.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        XCTAssertThrowsError(try store.rename("无法写入的新名称", for: id, fallback: "原名"))
        XCTAssertEqual(store.entries, saved)
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(store.displayTitle(for: id, fallback: "原名"), "已保存名称")
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        XCTAssertEqual(VideoMetadataStore(rootDirectory: root).entries, saved)
    }

    func testRenamingPersistedTaskStatesPreservesIDsRecordsAndResumeBytes() throws {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Media"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Resume"), withIntermediateDirectories: true)
        let phases: [DownloadPhase] = [.queued, .downloading, .paused, .validating, .complete, .failed, .cancelled]
        let records = try phases.map { phase -> DownloadRecord in
            let id = UUID()
            var record = DownloadRecord(id: id, candidate: candidate("slow.mp4", title: "原始\(phase.rawValue)"),
                phase: phase, progress: 0.25, bytesWritten: 16_384, expectedBytes: 65_536,
                localRelativePath: nil, failure: phase == .failed ? "合成失败" : nil,
                duration: nil, hasAudio: nil, createdAt: Date())
            if phase == .complete {
                record.localRelativePath = "Media/\(id.uuidString).mp4"
                try Data("preserved synthetic media bytes".utf8).write(to: root.appendingPathComponent(record.localRelativePath!))
            }
            if phase == .paused {
                try Data("synthetic continuation bytes".utf8).write(to: resumeFile(id, root: root))
            }
            return record
        }
        try JSONEncoder().encode(records).write(to: root.appendingPathComponent("downloads.json"))
        let manager = DownloadManager(rootDirectory: root); managers.append(manager)
        let store = VideoMetadataStore(rootDirectory: root)
        // No actor suspension: restoring system tasks cannot alter the seeded states during these edits.
        for record in records {
            try renameWithoutChangingDownload("自定\(record.phase.rawValue)", id: record.id, manager: manager, store: store)
        }
        let restarted = VideoMetadataStore(rootDirectory: root)
        for record in records {
            XCTAssertEqual(restarted.displayTitle(for: record.id, fallback: record.candidate.title), "自定\(record.phase.rawValue)")
        }
    }

    func testRenameSurvivesRealProgressPauseResumeCompletionAndReload() async throws {
        try await requireFixtures()
        let root = try temporaryRoot(), manager = DownloadManager(rootDirectory: root)
        managers.append(manager)
        let store = VideoMetadataStore(rootDirectory: root)
        let original = candidate("slow.mp4", title: "原始卡片名称")
        let id = await manager.start(candidate: original, cookies: [])
        try await waitUntil("slow transfer receives bytes") { (manager.records.first?.bytesWritten ?? 0) >= 16_384 }
        let beforeProgress = try XCTUnwrap(manager.records.first).bytesWritten
        try renameWithoutChangingDownload("下载中的新名称", id: id, manager: manager, store: store)
        try await waitUntil("download progress advances after rename") { (manager.records.first?.bytesWritten ?? 0) > beforeProgress }
        XCTAssertEqual(store.displayTitle(for: id, fallback: original.title), "下载中的新名称")
        manager.pause(id: id)
        try await waitUntil("paused transfer retains continuation data") {
            manager.records.first?.phase == .paused && FileManager.default.fileExists(atPath: self.resumeFile(id, root: root).path)
        }
        try renameWithoutChangingDownload("暂停后的新名称", id: id, manager: manager, store: store)
        manager.resume(id: id)
        manager.resume(id: id)
        try await waitUntil("resumed download completes validation", timeout: 90) {
            [.complete, .failed].contains(manager.records.first?.phase ?? .queued)
        }
        let complete = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(complete.phase, .complete, complete.failure ?? "")
        XCTAssertEqual(complete.id, id)
        XCTAssertEqual(complete.candidate, original)
        XCTAssertEqual(store.displayTitle(for: id, fallback: original.title), "暂停后的新名称")
        try renameWithoutChangingDownload("完成后的新名称", id: id, manager: manager, store: store)
        let restartedStore = VideoMetadataStore(rootDirectory: root)
        let restartedDownloads = DownloadManager(rootDirectory: root); managers.append(restartedDownloads)
        let reloaded = try XCTUnwrap(restartedDownloads.records.first)
        XCTAssertEqual(reloaded, complete)
        XCTAssertEqual(restartedDownloads.localURL(for: reloaded), manager.localURL(for: complete))
        XCTAssertEqual(restartedStore.displayTitle(for: id, fallback: reloaded.candidate.title), "完成后的新名称")
    }

    func testRenameSurvivesFailedRetryAndReloadWithoutChangingSource() async throws {
        try await requireFixtures()
        let root = try temporaryRoot(), manager = DownloadManager(rootDirectory: root)
        managers.append(manager)
        let store = VideoMetadataStore(rootDirectory: root)
        let source = candidate("forbidden.mp4", title: "合成失败条目")
        let id = await manager.start(candidate: source, cookies: [])
        XCTAssertEqual(manager.records.first?.phase, .failed)
        try renameWithoutChangingDownload("失败任务的新名称", id: id, manager: manager, store: store)
        await manager.retry(id: id, cookies: [])
        let failed = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(failed.id, id)
        XCTAssertEqual(failed.candidate, source)
        XCTAssertNil(failed.localRelativePath)
        XCTAssertEqual(store.displayTitle(for: id, fallback: source.title), "失败任务的新名称")
        try renameWithoutChangingDownload("失败任务的新名称", id: id, manager: manager, store: store)
        let restarted = VideoMetadataStore(rootDirectory: root)
        XCTAssertEqual(restarted.displayTitle(for: id, fallback: source.title), "失败任务的新名称")
    }

    private func renameWithoutChangingDownload(_ title: String, id: UUID, manager: DownloadManager,
                                               store: VideoMetadataStore) throws {
        let before = try XCTUnwrap(manager.records.first { $0.id == id })
        let state = manager.rootDirectory.appendingPathComponent("downloads.json")
        let stateBytes = try Data(contentsOf: state)
        let resume = resumeFile(id, root: manager.rootDirectory)
        let resumeBytes = try optionalData(at: resume)
        let local = manager.localURL(for: before)
        let localBytes = try local.map { try Data(contentsOf: $0) }
        try store.rename(title, for: id, fallback: before.candidate.title)
        XCTAssertEqual(manager.records.first { $0.id == id }, before)
        XCTAssertEqual(try Data(contentsOf: state), stateBytes)
        XCTAssertEqual(try optionalData(at: resume), resumeBytes)
        XCTAssertEqual(manager.localURL(for: before), local)
        if let local { XCTAssertEqual(try Data(contentsOf: local), localBytes) }
    }

    private func candidate(_ path: String, title: String) -> MediaCandidate {
        let url = URL(string: "http://127.0.0.1:8765/" + path)!
        return MediaCandidate(url: url, pageURL: url, frameURL: url, title: title, kind: .file, source: "fixture")
    }
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-rename-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }
    private func metadataFile(_ root: URL) -> URL { root.appendingPathComponent("VideoMetadata/metadata.json") }
    private func resumeFile(_ id: UUID, root: URL) -> URL { root.appendingPathComponent("Resume/\(id.uuidString).data") }
    private func optionalData(at url: URL) throws -> Data? {
        FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }
    private func waitUntil(_ reason: String, timeout: TimeInterval = 15, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        guard predicate() else { XCTFail(reason); throw TestFailure.timeout }
    }
    private func requireFixtures() async throws {
        let url = URL(string: "http://127.0.0.1:8765/__health")!
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let health = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(health["ready"] as? Bool, true)
            XCTAssertEqual(health["offline"] as? Bool, false)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw XCTSkip("Start the generated loopback fixture server to test rename during downloads.")
        }
    }
    private struct Archive: Codable { let schemaVersion: Int; let entries: [VideoMetadata] }
    private enum TestFailure: Error { case timeout }
}
