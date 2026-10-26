import XCTest
@testable import VYu

@MainActor final class LibraryTests: XCTestCase {
    func testLibraryPersistenceAndIndependentPosition() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let url = URL(string: "https://example.org/watch")!
        let id = UUID()
        store.visit(url: url, title: "My video")
        store.visit(url: url, title: "Updated title")
        store.toggleFavorite(url: url, title: "My video")
        store.setPosition(3.2, for: id)
        let restored = LibraryStore(directory: directory)
        XCTAssertEqual(restored.recent.count, 1)
        XCTAssertEqual(restored.recent.first?.title, "Updated title")
        XCTAssertTrue(restored.isFavorite(url))
        XCTAssertEqual(restored.positions[id.uuidString], 3.2)
        restored.removePosition(for: id)
        XCTAssertTrue(restored.isFavorite(url))
    }

    func testRefusesCredentialURLsAndInvalidPosition() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        store.visit(url: URL(string: "https://user:password@example.org")!, title: "secret")
        XCTAssertTrue(store.recent.isEmpty)
        let id = UUID(); store.setPosition(.nan, for: id)
        XCTAssertNil(store.positions[id.uuidString])
    }

    func testClearRecentPersistsAndPreservesFavoritesAndPositions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let favoriteURL = URL(string: "https://example.org/favorite")!
        let positionID = UUID()
        store.visit(url: favoriteURL, title: "收藏的视频")
        store.visit(url: URL(string: "https://example.org/other")!, title: "另一条访问")
        store.toggleFavorite(url: favoriteURL, title: "收藏的视频")
        store.setPosition(91.5, for: positionID)
        let favorites = store.favorites
        let positions = store.positions

        try store.clearRecent()

        XCTAssertTrue(store.recent.isEmpty)
        XCTAssertEqual(store.favorites, favorites)
        XCTAssertEqual(store.positions, positions)
        let restored = LibraryStore(directory: directory)
        XCTAssertTrue(restored.recent.isEmpty)
        XCTAssertEqual(restored.favorites, favorites)
        XCTAssertEqual(restored.positions, positions)
    }

    func testRemoveRecentDeletesOnlyMatchingURLAndAllItsDuplicates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let removedURL = URL(string: "https://example.org/watch?id=1")!
        let retainedURL = URL(string: "https://example.org/watch?id=2")!
        let removed = SavedPage(url: removedURL, title: "删除", lastVisited: Date(timeIntervalSince1970: 1))
        let retained = SavedPage(url: retainedURL, title: "保留", lastVisited: Date(timeIntervalSince1970: 2))
        let positionID = UUID()
        let snapshot = LibrarySnapshot(recent: [removed, retained, removed], favorites: [removed], positions: [positionID.uuidString: 12])
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("library.json"))
        let store = LibraryStore(directory: directory)

        try store.removeRecent(url: removedURL)

        XCTAssertEqual(store.recent, [retained])
        XCTAssertEqual(store.favorites, [removed])
        XCTAssertEqual(store.positions, snapshot.positions)
        let restored = LibraryStore(directory: directory)
        XCTAssertEqual(restored.recent, [retained])
        XCTAssertEqual(restored.favorites, snapshot.favorites)
        XCTAssertEqual(restored.positions, snapshot.positions)
    }

    func testRemovingUnknownRecentAndClearingEmptyRecentAreSafe() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let url = URL(string: "https://example.org/watch")!
        store.visit(url: url, title: "保留")
        let original = store.recent
        try store.removeRecent(url: URL(string: "https://example.org/missing")!)
        XCTAssertEqual(store.recent, original)
        try store.clearRecent()
        try store.clearRecent()
        XCTAssertTrue(LibraryStore(directory: directory).recent.isEmpty)
    }

    func testClearRecentWriteFailureThrowsWithoutChangingMemory() throws {
        try verifyRecentWriteFailure { try $0.clearRecent() }
    }

    func testRemoveRecentWriteFailureThrowsWithoutChangingMemory() throws {
        try verifyRecentWriteFailure { store in
            try store.removeRecent(url: URL(string: "https://example.org/watch")!)
        }
    }

    func testTitleUpdatePreservesVisitDateAndOrderAndPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let firstURL = URL(string: "https://example.org/first")!
        let secondURL = URL(string: "https://example.org/second")!
        store.visit(url: firstURL, title: "原标题")
        store.visit(url: secondURL, title: "第二页")
        let original = store.recent

        store.updateRecentTitle(url: firstURL, title: "网页加载完成后的标题")

        XCTAssertEqual(store.recent.map(\.url), original.map(\.url))
        XCTAssertEqual(store.recent.map(\.lastVisited), original.map(\.lastVisited))
        XCTAssertEqual(store.recent.last?.title, "网页加载完成后的标题")
        XCTAssertEqual(LibraryStore(directory: directory).recent, store.recent)
    }

    func testLateTitleUpdateDoesNotRestoreClearedOrRemovedHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let url = URL(string: "https://example.org/watch")!
        store.visit(url: url, title: "原标题")
        try store.clearRecent()
        store.updateRecentTitle(url: url, title: "清空后的标题")
        XCTAssertTrue(store.recent.isEmpty)
        XCTAssertTrue(LibraryStore(directory: directory).recent.isEmpty)

        store.visit(url: url, title: "再次访问")
        try store.removeRecent(url: url)
        store.updateRecentTitle(url: url, title: "删除后的标题")
        XCTAssertTrue(store.recent.isEmpty)
        XCTAssertTrue(LibraryStore(directory: directory).recent.isEmpty)
    }

    private func verifyRecentWriteFailure(_ mutation: (LibraryStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let url = URL(string: "https://example.org/watch")!
        store.visit(url: url, title: "原访问")
        store.toggleFavorite(url: url, title: "原收藏")
        store.setPosition(32, for: UUID())
        let original = LibrarySnapshot(recent: store.recent, favorites: store.favorites, positions: store.positions)
        let file = directory.appendingPathComponent("library.json")
        let backup = directory.appendingPathComponent("library-backup.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

        XCTAssertThrowsError(try mutation(store))
        XCTAssertEqual(store.recent, original.recent)
        XCTAssertEqual(store.favorites, original.favorites)
        XCTAssertEqual(store.positions, original.positions)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        let restored = LibraryStore(directory: directory)
        XCTAssertEqual(restored.recent, original.recent)
        XCTAssertEqual(restored.favorites, original.favorites)
        XCTAssertEqual(restored.positions, original.positions)
    }
}

private struct LibrarySnapshot: Encodable {
    let recent: [SavedPage]
    let favorites: [SavedPage]
    let positions: [String: Double]
}
