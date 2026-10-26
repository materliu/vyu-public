import Combine
import Foundation

struct VideoMetadata: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var isFavorite: Bool
    var tags: [String]
    var updatedAt: Date
    var revision: UUID

    static let maximumTags = 20
    static let maximumTagLength = 30

    static func normalizedTags(_ tags: [String]) throws -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for input in tags {
            guard !input.unicodeScalars.contains(where: { scalar in
                switch scalar.properties.generalCategory {
                case .control, .lineSeparator, .paragraphSeparator: return true
                default: return false
                }
            }) else { throw VideoMetadataError.invalidTag }
            var tag = input.trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
            while tag.hasPrefix("#") || tag.hasPrefix("＃") { tag.removeFirst() }
            tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            guard tag.count <= maximumTagLength else { throw VideoMetadataError.tagTooLong }
            guard seen.insert(VideoMetadataSearch.folded(tag)).inserted else { continue }
            result.append(tag)
            guard result.count <= maximumTags else { throw VideoMetadataError.tooManyTags }
        }
        return result
    }

    func validate() throws {
        let seconds = updatedAt.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, updatedAt <= .distantFuture,
              tags == (try Self.normalizedTags(tags)) else { throw VideoMetadataError.invalidMetadata }
    }

    func isNewer(than other: VideoMetadata) -> Bool {
        Self.isNewer(self, than: other)
    }

    static func isNewer(_ candidate: VideoMetadata, than other: VideoMetadata) -> Bool {
        if candidate.updatedAt != other.updatedAt { return candidate.updatedAt > other.updatedAt }
        return candidate.revision.uuidString.lowercased() > other.revision.uuidString.lowercased()
    }
}

enum VideoMetadataError: LocalizedError, Equatable {
    case invalidTag
    case tagTooLong
    case tooManyTags
    case invalidMetadata
    case unreadableStore
    case archiveTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidTag: return "标签不能包含换行或控制字符"
        case .tagTooLong: return "每个标签最多 30 个字"
        case .tooManyTags: return "每个视频最多添加 20 个标签"
        case .invalidMetadata: return "收藏或标签资料无效"
        case .unreadableStore: return "无法读取已保存的收藏和标签，请稍后重试"
        case .archiveTooLarge: return "收藏和标签资料过大，无法保存"
        }
    }
}

@MainActor final class VideoMetadataStore: ObservableObject {
    @Published private(set) var entries: [UUID: VideoMetadata] = [:]

    private struct Archive: Codable {
        var schemaVersion: Int
        var entries: [VideoMetadata]
    }

    private static let maximumArchiveBytes = 16 * 1_024 * 1_024
    private static let maximumEntries = 20_000
    private let directory: URL
    private let file: URL
    private var stateReadable = true

    init(rootDirectory: URL) {
        directory = rootDirectory.appendingPathComponent("VideoMetadata", isDirectory: true)
        file = directory.appendingPathComponent("metadata.json")
        do {
            try prepareDirectory()
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            } catch let error as NSError where Self.isMissingFile(error) {
                return
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  size <= Self.maximumArchiveBytes else { throw VideoMetadataError.invalidMetadata }
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
            guard archive.schemaVersion == 1, archive.entries.count <= Self.maximumEntries else {
                throw VideoMetadataError.invalidMetadata
            }
            var restored: [UUID: VideoMetadata] = [:]
            for entry in archive.entries {
                try entry.validate()
                guard restored.updateValue(entry, forKey: entry.id) == nil else {
                    throw VideoMetadataError.invalidMetadata
                }
            }
            entries = restored
        } catch {
            // Preserve an unreadable archive. A later edit must not replace it
            // with the empty in-memory state.
            stateReadable = false
        }
    }

    func metadata(for id: UUID) -> VideoMetadata? { entries[id] }
    func isFavorite(_ id: UUID) -> Bool { entries[id]?.isFavorite ?? false }
    func tags(for id: UUID) -> [String] { entries[id]?.tags ?? [] }

    func toggleFavorite(_ id: UUID) throws {
        let existing = entries[id]
        try update(id: id, isFavorite: !(existing?.isFavorite ?? false), tags: existing?.tags ?? [])
    }

    func setTags(_ tags: [String], for id: UUID) throws {
        guard stateReadable else { throw VideoMetadataError.unreadableStore }
        let normalized = try VideoMetadata.normalizedTags(tags)
        let existing = entries[id]
        guard normalized != (existing?.tags ?? []) else { return }
        try update(id: id, isFavorite: existing?.isFavorite ?? false, tags: normalized)
    }

    func merge(_ incoming: [UUID: VideoMetadata]) throws {
        guard stateReadable else { throw VideoMetadataError.unreadableStore }
        guard incoming.count <= Self.maximumEntries else { throw VideoMetadataError.archiveTooLarge }
        // Validate the entire batch before accepting any of it.
        for (id, entry) in incoming {
            guard id == entry.id else { throw VideoMetadataError.invalidMetadata }
            try entry.validate()
        }
        var proposed = entries
        for (id, entry) in incoming {
            if let prior = proposed[id], !entry.isNewer(than: prior) { continue }
            proposed[id] = entry
        }
        guard proposed != entries else { return }
        try persist(proposed)
        entries = proposed
    }

    func remove(ids: Set<UUID>) throws {
        guard stateReadable else { throw VideoMetadataError.unreadableStore }
        var proposed = entries
        for id in ids { proposed.removeValue(forKey: id) }
        guard proposed != entries else { return }
        try persist(proposed)
        entries = proposed
    }

    private func update(id: UUID, isFavorite: Bool, tags: [String]) throws {
        guard stateReadable else { throw VideoMetadataError.unreadableStore }
        // Millisecond timestamps survive the cloud sidecar's JSON date format.
        // Advance beyond the last revision even if this device's clock moved back.
        let currentMilliseconds = floor(Date().timeIntervalSince1970 * 1_000)
        let priorMilliseconds = entries[id].map { ceil($0.updatedAt.timeIntervalSince1970 * 1_000) + 1 } ?? 0
        let updatedAt = Date(timeIntervalSince1970: max(currentMilliseconds, priorMilliseconds) / 1_000)
        let entry = VideoMetadata(id: id, isFavorite: isFavorite, tags: tags, updatedAt: updatedAt, revision: UUID())
        try entry.validate()
        var proposed = entries
        proposed[id] = entry
        try persist(proposed)
        entries = proposed
    }

    private func persist(_ proposed: [UUID: VideoMetadata]) throws {
        guard stateReadable else { throw VideoMetadataError.unreadableStore }
        guard proposed.count <= Self.maximumEntries else { throw VideoMetadataError.archiveTooLarge }
        try prepareDirectory()
        // Refuse a linked or non-file destination instead of writing through it.
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw VideoMetadataError.invalidMetadata
            }
        } catch let error as NSError where Self.isMissingFile(error) { }
        let ordered = proposed.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let data = try JSONEncoder().encode(Archive(schemaVersion: 1, entries: ordered))
        guard data.count <= Self.maximumArchiveBytes else { throw VideoMetadataError.archiveTooLarge }
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw VideoMetadataError.invalidMetadata
        }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path)
        var protectedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(values)
    }

    private static func isMissingFile(_ error: NSError) -> Bool {
        error.domain == NSCocoaErrorDomain && [CocoaError.fileReadNoSuchFile.rawValue, CocoaError.fileNoSuchFile.rawValue].contains(error.code)
    }
}

enum VideoMetadataSearch {
    static func matches(title: String, tags: [String], query: String) -> Bool {
        let title = folded(title)
        let tags = tags.map(folded)
        let tokens = folded(query).split(whereSeparator: \.isWhitespace)
        return tokens.allSatisfy { token in
            let searchesTagsOnly = token.hasPrefix("#")
            let value = String(token.drop(while: { $0 == "#" }))
            guard !value.isEmpty else { return true }
            return (!searchesTagsOnly && title.contains(value)) || tags.contains(where: { $0.contains(value) })
        }
    }

    fileprivate static func folded(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
    }
}
