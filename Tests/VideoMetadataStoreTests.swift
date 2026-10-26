import Combine
import XCTest
@testable import VYu

@MainActor final class VideoMetadataStoreTests: XCTestCase {
    func testNewStoreDoesNotCreateRecordsForUneditedVideos() throws {
        try withDirectory { directory in
            let store = VideoMetadataStore(rootDirectory: directory)
            let id = UUID()
            XCTAssertNil(store.metadata(for: id))
            XCTAssertFalse(store.isFavorite(id))
            XCTAssertEqual(store.tags(for: id), [])
            XCTAssertNil(store.coverFrameSeconds(for: id))
            try store.setCoverFrameSeconds(nil, for: id)
            try store.setTags([], for: id)
            try store.setTags(["  ", "#"], for: id)
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: metadataFile(directory).path))
        }
    }

    func testCoverSelectionPersistsAndOtherEditsKeepItsFrame() throws {
        try withDirectory { directory in
            let store = VideoMetadataStore(rootDirectory: directory)
            let id = UUID()
            try store.setCoverFrameSeconds(3.25, for: id)
            let selected = try XCTUnwrap(store.metadata(for: id))
            XCTAssertEqual(store.coverFrameSeconds(for: id), 3.25)
            try store.setCoverFrameSeconds(3.25, for: id)
            XCTAssertEqual(store.metadata(for: id), selected, "Selecting the same frame must not create another revision.")
            try store.toggleFavorite(id)
            try store.setTags(["封面测试"], for: id)
            XCTAssertEqual(store.coverFrameSeconds(for: id), 3.25)
            XCTAssertTrue(store.isFavorite(id))
            XCTAssertEqual(store.tags(for: id), ["封面测试"])
            let restarted = VideoMetadataStore(rootDirectory: directory)
            XCTAssertEqual(restarted.entries, store.entries)
            try restarted.setCoverFrameSeconds(0, for: id)
            XCTAssertEqual(restarted.coverFrameSeconds(for: id), 0, "A deliberately selected first frame is distinct from automatic selection.")
        }
    }

    func testClearingCoverPersistsNewRevisionAndKeepsTagsAndFavorite() throws {
        try withDirectory { directory in
            let store = VideoMetadataStore(rootDirectory: directory)
            let id = UUID()
            try store.toggleFavorite(id)
            try store.setTags(["保留"], for: id)
            try store.setCoverFrameSeconds(4, for: id)
            let selected = try XCTUnwrap(store.metadata(for: id))
            try store.setCoverFrameSeconds(nil, for: id)
            let automatic = try XCTUnwrap(store.metadata(for: id))
            XCTAssertNil(automatic.coverFrameSeconds)
            XCTAssertTrue(automatic.isNewer(than: selected))
            XCTAssertTrue(automatic.isFavorite)
            XCTAssertEqual(automatic.tags, ["保留"])
            try store.merge([id: selected])
            XCTAssertEqual(store.metadata(for: id), automatic)
            XCTAssertEqual(VideoMetadataStore(rootDirectory: directory).metadata(for: id), automatic)
        }
    }

    func testLegacyArchiveWithoutCoverFieldRestoresAndCanBeEdited() throws {
        try withDirectory { directory in
            let entry = makeMetadata()
            let file = metadataFile(directory)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(MetadataArchiveFixture(schemaVersion: 1, entries: [entry]))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("coverFrameSeconds"))
            try data.write(to: file)
            let store = VideoMetadataStore(rootDirectory: directory)
            XCTAssertEqual(store.metadata(for: entry.id), entry)
            XCTAssertNil(store.coverFrameSeconds(for: entry.id))
            try store.setCoverFrameSeconds(1.5, for: entry.id)
            XCTAssertEqual(store.tags(for: entry.id), entry.tags)
            XCTAssertTrue(store.isFavorite(entry.id))
            XCTAssertEqual(VideoMetadataStore(rootDirectory: directory).coverFrameSeconds(for: entry.id), 1.5)
        }
    }

    func testInvalidCoverTimesAreRejectedWithoutPublishingOrSaving() throws {
        try withDirectory { directory in
            let store = VideoMetadataStore(rootDirectory: directory)
            let id = UUID()
            try store.setCoverFrameSeconds(2, for: id)
            let before = store.entries
            let bytes = try Data(contentsOf: metadataFile(directory))
            var publications = 0
            let observation = store.$entries.dropFirst().sink { _ in publications += 1 }
            defer { observation.cancel() }
            for value in [Double.nan, .infinity, -.infinity, -1] {
                XCTAssertThrowsError(try store.setCoverFrameSeconds(value, for: id))
                var invalid = try XCTUnwrap(store.metadata(for: id))
                invalid.coverFrameSeconds = value
                XCTAssertThrowsError(try invalid.validate())
                XCTAssertThrowsError(try store.merge([id: invalid]))
            }
            XCTAssertEqual(publications, 0)
            XCTAssertEqual(store.entries, before)
            XCTAssertEqual(try Data(contentsOf: metadataFile(directory)), bytes)
        }
    }

    func testFavoriteAndTagsPersistAcrossRestart() throws {
        try withDirectory { directory in
            let store = VideoMetadataStore(rootDirectory: directory)
            let id = UUID()
            try store.toggleFavorite(id)
            try store.setTags(["旅行", " #Café ", "ＣＡＦÉ"], for: id)
            XCTAssertTrue(store.isFavorite(id))
            XCTAssertEqual(store.tags(for: id), ["旅行", "Café"])
            let restored = VideoMetadataStore(rootDirectory: directory)
            XCTAssertEqual(restored.entries, store.entries)
            let values = try directory.appendingPathComponent("VideoMetadata").resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true)
            let attributes = try FileManager.default.attributesOfItem(atPath: metadataFile(directory).path)
            let control = directory.appendingPathComponent("protected-control")
            try Data([1]).write(to: control, options: [.completeFileProtectionUntilFirstUserAuthentication])
            let controlAttributes = try FileManager.default.attributesOfItem(atPath: control.path)
            let protection = attributes[.protectionKey] as? String
            let expectedProtection = FileProtectionType.completeUntilFirstUserAuthentication.rawValue
            #if targetEnvironment(simulator)
            if controlAttributes[.protectionKey] == nil {
                XCTAssertNil(protection)
                print("Simulator reports no Data Protection attribute for either metadata or the protected control file; device enforcement remains unverified.")
            } else { XCTAssertEqual(protection, expectedProtection) }
            #else
            XCTAssertEqual(controlAttributes[.protectionKey] as? String, expectedProtection)
            XCTAssertEqual(protection, expectedProtection)
            #endif
        }
    }

    func testClearingFavoriteAndTagsKeepsANewerEmptyRevision() throws {
        try withDirectory { directory in
            let store = VideoMetadataStore(rootDirectory: directory)
            let id = UUID()
            try store.toggleFavorite(id)
            try store.setTags(["保留"], for: id)
            let original = try XCTUnwrap(store.metadata(for: id))
            try store.toggleFavorite(id)
            try store.setTags([], for: id)
            let cleared = try XCTUnwrap(store.metadata(for: id))
            XCTAssertFalse(cleared.isFavorite)
            XCTAssertEqual(cleared.tags, [])
            XCTAssertNotEqual(cleared.revision, original.revision)
            XCTAssertTrue(cleared.isNewer(than: original))
            try store.merge([id: original])
            XCTAssertEqual(store.metadata(for: id), cleared)
            XCTAssertEqual(VideoMetadataStore(rootDirectory: directory).metadata(for: id), cleared)
        }
    }

    func testSettingSameNormalizedTagsDoesNotCreateAnotherRevision() throws {
        try withDirectory { directory in
            let store = VideoMetadataStore(rootDirectory: directory)
            let id = UUID()
            try store.setTags(["  #旅行  ", "Swift"], for: id)
            let original = store.metadata(for: id)
            try store.setTags(["旅行", "Swift", "ＳＷＩＦＴ"], for: id)
            XCTAssertEqual(store.metadata(for: id), original)
        }
    }

    func testNormalizationPreservesDisplaySpellingAndEmoji() throws {
        XCTAssertEqual(try VideoMetadata.normalizedTags([" #Café ", "CAFÉ", "cafe", "＃旅行", "旅行", "👨‍👩‍👧‍👦", "   "]),
                       ["Café", "旅行", "👨‍👩‍👧‍👦"])
        XCTAssertEqual(try VideoMetadata.normalizedTags([String(repeating: "👨‍👩‍👧‍👦", count: 30)]).first?.count, 30)
    }

    func testTagLimitsRejectInvalidInputWithoutChangingStoredValues() throws {
        try withDirectory { directory in
            let store = VideoMetadataStore(rootDirectory: directory)
            let id = UUID()
            try store.setTags(["原标签"], for: id)
            let original = store.entries
            let invalidLists = [[String(repeating: "字", count: 31)], (0...20).map { "标签\($0)" },
                                ["行\n分隔"], ["制\u{0000}表"], ["行\u{2028}分隔"], ["行\u{2029}分隔"]]
            for tags in invalidLists {
                XCTAssertThrowsError(try store.setTags(tags, for: id))
                XCTAssertEqual(store.entries, original)
            }
            XCTAssertEqual(VideoMetadataStore(rootDirectory: directory).entries, original)
            XCTAssertNoThrow(try VideoMetadata.normalizedTags((0..<20).map { "标签\($0)" }))
            XCTAssertEqual(try VideoMetadata.normalizedTags(Array(repeating: "重复", count: 21)), ["重复"])
        }
    }

    func testCorruptArchiveIsNotOverwrittenByEditsMergeOrRemove() throws {
        try withDirectory { directory in
            let original = Data("not JSON — keep original bytes".utf8)
            let file = metadataFile(directory)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try original.write(to: file)
            let store = VideoMetadataStore(rootDirectory: directory)
            let entry = makeMetadata()
            XCTAssertThrowsError(try store.toggleFavorite(entry.id))
            XCTAssertThrowsError(try store.setTags([], for: entry.id))
            XCTAssertThrowsError(try store.setCoverFrameSeconds(2, for: entry.id))
            XCTAssertThrowsError(try store.merge([entry.id: entry]))
            XCTAssertThrowsError(try store.remove(ids: [entry.id]))
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }

    func testUnknownSchemaDuplicateIDsAndUnnormalizedArchiveArePreserved() throws {
        for invalid in [0, 1, 2] {
            try withDirectory { directory in
                var entry = makeMetadata()
                if invalid == 2 { entry.tags = [" #not-normalized "] }
                let entries = invalid == 1 ? [entry, entry] : [entry]
                let data = try JSONEncoder().encode(MetadataArchiveFixture(schemaVersion: invalid == 0 ? 99 : 1, entries: entries))
                let file = metadataFile(directory)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file)
                let store = VideoMetadataStore(rootDirectory: directory)
                XCTAssertThrowsError(try store.toggleFavorite(UUID()))
                XCTAssertEqual(try Data(contentsOf: file), data)
            }
        }
    }

    func testWritingFailureDoesNotPublishFavoriteTagsMergeOrRemoval() throws {
        try withDirectory { directory in
            let store = VideoMetadataStore(rootDirectory: directory)
            let id = UUID()
            try store.toggleFavorite(id)
            try store.setTags(["原标签"], for: id)
            let original = store.entries
            let file = metadataFile(directory)
            let backup = file.appendingPathExtension("backup")
            try FileManager.default.moveItem(at: file, to: backup)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            var publications = 0
            let observation = store.$entries.dropFirst().sink { _ in publications += 1 }
            defer { observation.cancel() }
            XCTAssertThrowsError(try store.toggleFavorite(id))
            XCTAssertThrowsError(try store.setTags(["新标签"], for: id))
            XCTAssertThrowsError(try store.setCoverFrameSeconds(2, for: id))
            let incoming = makeMetadata()
            XCTAssertThrowsError(try store.merge([incoming.id: incoming]))
            XCTAssertThrowsError(try store.remove(ids: [id]))
            XCTAssertEqual(publications, 0)
            XCTAssertEqual(store.entries, original)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: backup, to: file)
            XCTAssertEqual(VideoMetadataStore(rootDirectory: directory).entries, original)
        }
    }

    func testSymlinkedArchiveIsNeverReadOrReplaced() throws {
        try withDirectory { directory in
            let outside = directory.appendingPathComponent("original.json")
            let entry = makeMetadata()
            let data = try JSONEncoder().encode(MetadataArchiveFixture(schemaVersion: 1, entries: [entry]))
            try data.write(to: outside)
            let file = metadataFile(directory)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
            let store = VideoMetadataStore(rootDirectory: directory)
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertThrowsError(try store.toggleFavorite(entry.id))
            XCTAssertEqual(try Data(contentsOf: outside), data)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType, .typeSymbolicLink)
        }
    }

    func testMergeAcceptsNewerVersionsAndIgnoresOlderOnes() throws {
        try withDirectory { directory in
            let store = VideoMetadataStore(rootDirectory: directory)
            let entry = makeMetadata()
            try store.merge([entry.id: entry])
            var older = entry
            older.updatedAt = older.updatedAt.addingTimeInterval(-1)
            older.tags = ["旧标签"]
            try store.merge([older.id: older])
            XCTAssertEqual(store.metadata(for: entry.id), entry)
            var newer = entry
            newer.updatedAt = newer.updatedAt.addingTimeInterval(1)
            newer.tags = []
            newer.isFavorite = false
            newer.revision = UUID()
            try store.merge([newer.id: newer])
            XCTAssertEqual(store.metadata(for: entry.id), newer)
            XCTAssertEqual(VideoMetadataStore(rootDirectory: directory).entries, store.entries)
        }
    }

    func testSimultaneousRevisionsUseDeterministicUUIDOrdering() throws {
        try withDirectory { firstDirectory in
            try withDirectory { secondDirectory in
                let first = VideoMetadataStore(rootDirectory: firstDirectory)
                let second = VideoMetadataStore(rootDirectory: secondDirectory)
                var earlier = makeMetadata()
                earlier.revision = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                var later = earlier
                later.revision = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
                later.tags = []
                later.isFavorite = false
                XCTAssertTrue(later.isNewer(than: earlier))
                XCTAssertTrue(VideoMetadata.isNewer(later, than: earlier))
                XCTAssertFalse(earlier.isNewer(than: later))
                try first.merge([earlier.id: earlier])
                try first.merge([later.id: later])
                try second.merge([later.id: later])
                try second.merge([earlier.id: earlier])
                XCTAssertEqual(first.entries, second.entries)
                XCTAssertEqual(first.metadata(for: later.id), later)
            }
        }
    }

    func testInvalidIncomingBatchIsRejectedWithoutPartialMerge() throws {
        try withDirectory { directory in
            let store = VideoMetadataStore(rootDirectory: directory)
            let original = makeMetadata()
            try store.merge([original.id: original])
            let valid = makeMetadata()
            var invalid = makeMetadata()
            invalid.tags = ["duplicate", "DUPLICATE"]
            XCTAssertThrowsError(try store.merge([valid.id: valid, invalid.id: invalid]))
            XCTAssertThrowsError(try store.merge([UUID(): valid]))
            XCTAssertEqual(store.entries, [original.id: original])
            XCTAssertEqual(VideoMetadataStore(rootDirectory: directory).entries, store.entries)
        }
    }

    func testInvalidDatesAreRejected() throws {
        for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity),
                     Date(timeIntervalSince1970: -1), Date.distantFuture.addingTimeInterval(1)] {
            var entry = makeMetadata()
            entry.updatedAt = date
            XCTAssertThrowsError(try entry.validate())
        }
    }

    func testLocalEditAdvancesPastFutureImportedTimestamp() throws {
        try withDirectory { directory in
            let store = VideoMetadataStore(rootDirectory: directory)
            var remote = makeMetadata()
            remote.updatedAt = Date().addingTimeInterval(60 * 60)
            try store.merge([remote.id: remote])
            try store.toggleFavorite(remote.id)
            let edited = try XCTUnwrap(store.metadata(for: remote.id))
            XCTAssertTrue(edited.isNewer(than: remote))
            XCTAssertGreaterThan(edited.updatedAt, remote.updatedAt)
            XCTAssertFalse(edited.isFavorite)
            let cloudEncoder = JSONEncoder()
            cloudEncoder.dateEncodingStrategy = .millisecondsSince1970
            let cloudDecoder = JSONDecoder()
            cloudDecoder.dateDecodingStrategy = .millisecondsSince1970
            XCTAssertEqual(try cloudDecoder.decode(VideoMetadata.self, from: cloudEncoder.encode(edited)), edited)
        }
    }

    func testRemoveOnlySpecifiedMetadataAndPersist() throws {
        try withDirectory { directory in
            let store = VideoMetadataStore(rootDirectory: directory)
            let first = makeMetadata()
            let second = makeMetadata()
            try store.merge([first.id: first, second.id: second])
            try store.remove(ids: [first.id, UUID()])
            XCTAssertEqual(store.entries, [second.id: second])
            XCTAssertEqual(VideoMetadataStore(rootDirectory: directory).entries, store.entries)
        }
    }

    func testSearchMatchesChineseTitleOrTagsWithMultipleTerms() {
        XCTAssertTrue(VideoMetadataSearch.matches(title: "日本旅行记录", tags: ["美食", "家庭"], query: "旅行 美食"))
        XCTAssertTrue(VideoMetadataSearch.matches(title: "日本旅行记录", tags: ["美食", "家庭"], query: " 家庭\n日本 "))
        XCTAssertFalse(VideoMetadataSearch.matches(title: "日本旅行记录", tags: ["美食", "家庭"], query: "旅行 海边"))
        XCTAssertTrue(VideoMetadataSearch.matches(title: "视频", tags: [], query: "  \n  "))
    }

    func testSearchIgnoresCaseAccentsAndWidthAndSupportsHashtags() {
        XCTAssertTrue(VideoMetadataSearch.matches(title: "Swift Café", tags: ["旅行", "Tutorial"], query: "ＳＷＩＦＴ cafe"))
        XCTAssertTrue(VideoMetadataSearch.matches(title: "Swift Café", tags: ["旅行", "Tutorial"], query: "#旅行 ＴＵＴＯＲＩＡＬ"))
        XCTAssertTrue(VideoMetadataSearch.matches(title: "其他", tags: ["Café"], query: "＃ＣＡＦＥ"))
        XCTAssertFalse(VideoMetadataSearch.matches(title: "旅行", tags: [], query: "#旅行"))
        XCTAssertTrue(VideoMetadataSearch.matches(title: "视频", tags: [], query: "#"))
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VYuMetadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func metadataFile(_ directory: URL) -> URL {
        directory.appendingPathComponent("VideoMetadata/metadata.json")
    }

    private func makeMetadata() -> VideoMetadata {
        VideoMetadata(id: UUID(), isFavorite: true, tags: ["示例"],
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000), revision: UUID())
    }
}

private struct MetadataArchiveFixture: Encodable {
    var schemaVersion: Int
    var entries: [VideoMetadata]
}
