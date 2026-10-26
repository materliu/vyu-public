import Foundation
import Combine

struct SavedPage: Identifiable, Codable, Equatable {
    var id: String { url.absoluteString }
    let url: URL
    var title: String
    var lastVisited: Date
}

@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var recent: [SavedPage] = []
    @Published private(set) var favorites: [SavedPage] = []
    @Published private(set) var positions: [String: Double] = [:]
    private let file: URL
    private struct State: Codable {
        var recent: [SavedPage]
        var favorites: [SavedPage]
        var positions: [String: Double]
    }
    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VYu", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        file = root.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: file), let state = try? JSONDecoder().decode(State.self, from: data) {
            recent = state.recent; favorites = state.favorites; positions = state.positions
        }
    }
    func visit(url: URL, title: String) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return }
        recent.removeAll { $0.url == url }
        recent.insert(SavedPage(url: url, title: title.isEmpty ? (url.host ?? "网页") : String(title.prefix(240)), lastVisited: Date()), at: 0)
        recent = Array(recent.prefix(50)); save()
    }
    func updateRecentTitle(url: URL, title: String) {
        guard let index = recent.firstIndex(where: { $0.url == url }) else { return }
        let updatedTitle = title.isEmpty ? (url.host ?? "网页") : String(title.prefix(240))
        guard recent[index].title != updatedTitle else { return }
        var updated = recent
        updated[index].title = updatedTitle
        guard (try? persist(recent: updated)) != nil else { return }
        recent = updated
    }
    func removeRecent(url: URL) throws {
        let remaining = recent.filter { $0.url != url }
        try persist(recent: remaining)
        recent = remaining
    }
    func clearRecent() throws {
        try persist(recent: [])
        recent = []
    }
    func isFavorite(_ url: URL) -> Bool { favorites.contains { $0.url == url } }
    func toggleFavorite(url: URL, title: String) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return }
        if isFavorite(url) { favorites.removeAll { $0.url == url } }
        else { favorites.insert(SavedPage(url: url, title: title.isEmpty ? (url.host ?? "网页") : String(title.prefix(240)), lastVisited: Date()), at: 0) }
        save()
    }
    func setPosition(_ seconds: Double, for id: UUID) {
        guard seconds.isFinite, seconds >= 0 else { return }
        positions[id.uuidString] = seconds; save()
    }
    func removePosition(for id: UUID) { positions.removeValue(forKey: id.uuidString); save() }
    private func save() {
        try? persist(recent: recent)
    }
    private func persist(recent: [SavedPage]) throws {
        let data = try JSONEncoder().encode(State(recent: recent, favorites: favorites, positions: positions))
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
