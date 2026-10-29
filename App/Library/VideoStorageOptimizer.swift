import Combine
import Foundation

/// This policy applies only to replaceable video copies. A cloud backup must be
/// proven again by CloudVideoSync before any local file can be released.
@MainActor final class VideoStorageOptimizer: ObservableObject {
    static let defaultBudgetBytes: Int64 = 1_000_000_000
    @Published private(set) var isEnabled = false
    @Published private(set) var localVideoBytes: Int64 = 0
    @Published private(set) var cloudCacheBytes: Int64 = 0
    @Published private(set) var isMaintaining = false
    @Published private(set) var usageAvailable = false
    @Published private(set) var message: String?
    let budgetBytes: Int64
    var localBytes: Int64 { Self.add(localVideoBytes, cloudCacheBytes) }

    /// Transfer byte/progress updates do not change the set of cache files.
    /// Keep phase/path changes observable, including validation and eviction.
    private struct StorageRecord: Equatable {
        let id: UUID
        let phase: DownloadPhase
        let path: String?
        let evicted: Bool
        init(_ record: DownloadRecord) {
            id = record.id; phase = record.phase; path = record.localRelativePath
            evicted = record.localCacheEvicted == true
        }
    }
    private struct State: Codable {
        var schemaVersion = 1
        var isEnabled = false
        var lastUsed: [String: Date] = [:]
    }
    private let downloads: DownloadManager
    private let cloud: CloudVideoSync
    private let metadataStore: VideoMetadataStore
    private let directory: URL
    private let now: () -> Date
    private let automaticallyMaintain: Bool
    private var state = State()
    private var stateReadable = true
    private var appActive = true
    private var generation = UUID()
    private var subscriptions: Set<AnyCancellable> = []
    private var scheduled: Task<Void, Never>?
    private var maintenanceRequested = false
    private var usageGeneration = UUID()

    init(downloads: DownloadManager, cloud: CloudVideoSync, metadataStore: VideoMetadataStore,
         budgetBytes: Int64 = 1_000_000_000, now: @escaping () -> Date = Date.init,
         automaticallyMaintain: Bool = true) {
        self.downloads = downloads; self.cloud = cloud
        self.metadataStore = metadataStore
        self.budgetBytes = max(1, budgetBytes); self.now = now
        self.automaticallyMaintain = automaticallyMaintain
        directory = downloads.rootDirectory.appendingPathComponent("VideoStorage", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw StorageIssue.unreadable }
            let url = directory.appendingPathComponent("state.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                      let size = attributes.fileSize, size <= 2_000_000 else { throw StorageIssue.unreadable }
                let decoded = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
                guard decoded.schemaVersion == 1, decoded.lastUsed.count <= 20_000,
                      decoded.lastUsed.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.timeIntervalSince1970.isFinite })
                else { throw StorageIssue.unreadable }
                state = decoded; isEnabled = decoded.isEnabled
            }
        } catch {
            stateReadable = false; message = "无法读取本地存储设置，已暂停自动优化。"
        }
        metadataStore.$entries.dropFirst().removeDuplicates().sink { [weak self] _ in
            // A favorite/edit made while cloud proof is running changes which
            // file should survive. Revoke that pass before it can remove bytes.
            guard let self else { return }
            self.generation = UUID(); self.cloud.cancelCacheEvictions()
            if self.automaticallyMaintain { self.requestMaintenance() }
        }.store(in: &subscriptions)
        if automaticallyMaintain {
            downloads.$records.map { $0.map(StorageRecord.init) }.removeDuplicates().dropFirst()
                .sink { [weak self] _ in self?.requestMaintenance() }.store(in: &subscriptions)
            downloads.$localVideoUseIDs.dropFirst().sink { [weak self] _ in self?.requestMaintenance() }.store(in: &subscriptions)
            cloud.$entries.dropFirst().removeDuplicates().sink { [weak self] _ in self?.requestMaintenance() }.store(in: &subscriptions)
            cloud.$operations.dropFirst().removeDuplicates().sink { [weak self] _ in self?.requestMaintenance() }.store(in: &subscriptions)
            cloud.$message.dropFirst().removeDuplicates().sink { [weak self] _ in self?.requestMaintenance() }.store(in: &subscriptions)
            cloud.$isAvailable.dropFirst().removeDuplicates().sink { [weak self] _ in self?.requestMaintenance() }.store(in: &subscriptions)
            requestMaintenance()
        }
    }

    deinit { scheduled?.cancel() }

    func setEnabled(_ value: Bool) throws {
        if !value {
            // A failed settings write must not leave an in-flight deletion authorized.
            generation = UUID(); cloud.cancelCacheEvictions()
            isEnabled = false; state.isEnabled = false
        }
        guard stateReadable else { throw StorageIssue.unreadable }
        var proposed = state; proposed.isEnabled = value
        try persist(proposed)
        generation = UUID()
        cloud.cancelCacheEvictions()
        state = proposed; isEnabled = value
        message = nil
        if automaticallyMaintain { requestMaintenance() }
    }

    func markUsed(_ id: UUID) {
        // Keep an in-memory timestamp even if storage is currently unavailable.
        var proposed = state; proposed.lastUsed[id.uuidString] = now()
        let known = Set(downloads.records.map { $0.id.uuidString }).union(cloud.entries.keys.map(\.uuidString)).union([id.uuidString])
        proposed.lastUsed = proposed.lastUsed.filter { known.contains($0.key) }
        if proposed.lastUsed.count > 20_000 {
            proposed.lastUsed = Dictionary(uniqueKeysWithValues: proposed.lastUsed.sorted { $0.value > $1.value }
                .prefix(20_000).map { ($0.key, $0.value) })
        }
        guard stateReadable else { state = proposed; return }
        do { try persist(proposed); state = proposed }
        catch {
            state = proposed; stateReadable = false
            cloud.cancelCacheEvictions(); generation = UUID()
            message = "使用记录未能保存，已暂停自动优化。"
        }
    }

    func setAppActive(_ active: Bool) {
        appActive = active
        if !active {
            generation = UUID(); cloud.cancelCacheEvictions(); scheduled?.cancel(); scheduled = nil
        } else if automaticallyMaintain { requestMaintenance() }
    }

    private func requestMaintenance() {
        guard appActive else { return }
        if isMaintaining { maintenanceRequested = true; return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.scheduled = nil
            await self.maintain()
        }
    }

    @discardableResult func refreshUsage() async -> Bool {
        let current = UUID(); usageGeneration = current
        usageAvailable = false
        let directory = downloads.rootDirectory.appendingPathComponent("Media", isDirectory: true)
        let systemAssets = downloads.records.compactMap { record -> URL? in
            guard let url = downloads.localURL(for: record), url.pathExtension.lowercased() == "movpkg" else { return nil }
            return url
        }
        do {
            let appBytes = try await Task.detached(priority: .utility) {
                try Self.residentBytes(in: [directory] + systemAssets)
            }.value
            guard usageGeneration == current else { return false }
            localVideoBytes = appBytes
            let cloudBytes = try await cloud.localCloudMediaUsage()
            guard usageGeneration == current else { return false }
            cloudCacheBytes = max(0, cloudBytes); usageAvailable = true
            return true
        } catch {
            guard usageGeneration == current else { return false }
            usageAvailable = false
            // Keep the previous count rather than presenting a failed scan as 0.
            if isEnabled { message = "iCloud 占用暂时无法确认，已保留本地副本。" }
            return false
        }
    }

    func maintain() async {
        guard !isMaintaining else { maintenanceRequested = true; return }
        isMaintaining = true
        defer {
            isMaintaining = false
            if maintenanceRequested {
                maintenanceRequested = false
                if automaticallyMaintain { requestMaintenance() }
            }
        }
        guard await refreshUsage() else { return }
        guard isEnabled, stateReadable, appActive, !Task.isCancelled else { return }
        guard usageAvailable else { return }
        guard metadataStore.isReadable else {
            message = "无法读取收藏和更新记录，已保留本地副本。"
            return
        }
        guard cloud.isAvailable, !cloud.accountChanged else {
            message = "连接当前 iCloud 账号后，才能校验并释放本地副本。"
            return
        }
        let current = generation
        func valid() -> Bool {
            isEnabled && stateReadable && metadataStore.isReadable && appActive && generation == current && !Task.isCancelled
        }
        var released = 0
        var verificationFailed = false
        if localBytes > budgetBytes {
            if cloudCacheBytes > 0 {
                // Drop redundant native copies before choosing any video to
                // remove. Keeping two copies of a favorite must not displace
                // the only local copy of another video.
                _ = await cloud.evictCloudOnlyMediaCaches(onlyRedundant: true, isCurrent: { valid() })
                guard valid() else { return }
                guard await refreshUsage() else { return }
                guard usageAvailable else { return }
            }
            // Rank both native cloud caches and app files together. Otherwise a
            // favorite cached only by iCloud could be evicted before an old
            // nonfavorite in Media just because the two copies use different paths.
            for id in evictionCandidateIDs() {
                guard valid(), localBytes > budgetBytes else { break }
                if cloudCacheBytes > 0 {
                    _ = await cloud.evictCloudOnlyMediaCaches(ids: [id], isCurrent: { valid() })
                    guard valid() else { return }
                    guard await refreshUsage() else { return }
                    guard usageAvailable else { return }
                }
                guard valid(), localBytes > budgetBytes else { break }
                do {
                    if try await cloud.evictLocalCacheIfRecoverable(id: id, isCurrent: { valid() }) {
                        released += 1
                        guard await refreshUsage() else { return }
                        guard usageAvailable else { return }
                    }
                } catch { verificationFailed = true }
            }
        }
        guard valid() else { return }
        guard await refreshUsage() else { return }
        guard usageAvailable else { return }
        if localBytes > budgetBytes {
            message = "部分视频尚未通过 iCloud 校验或正在使用，暂时超出缓存上限。"
        } else if verificationFailed {
            message = "部分副本暂时无法校验，已保留在本机。"
        } else if released > 0 {
            message = "已释放 \(released) 个本地副本，需要播放时会从 iCloud 下载。"
        } else { message = "视频缓存已在上限内，需要播放时可从 iCloud 下载。" }
    }

    /// Least valuable copies go first: nonfavorites, then older edits/additions.
    /// Playback access is kept in the legacy local ledger but does not rank updates.
    func evictionCandidateIDs() -> [UUID] {
        var additions = cloud.entries.mapValues { $0.manifest.createdAt }
        for record in downloads.records {
            if additions[record.id] != nil || downloads.canEvictLocalCache(record) {
                additions[record.id] = max(additions[record.id] ?? record.createdAt, record.createdAt)
            }
        }
        return additions.keys.sorted { lhs, rhs in
            let left = metadataStore.metadata(for: lhs)
            let right = metadataStore.metadata(for: rhs)
            let leftFavorite = left?.isFavorite ?? false
            let rightFavorite = right?.isFavorite ?? false
            if leftFavorite != rightFavorite { return !leftFavorite }
            let a = max(additions[lhs]!, left?.updatedAt ?? additions[lhs]!)
            let b = max(additions[rhs]!, right?.updatedAt ?? additions[rhs]!)
            return a == b ? lhs.uuidString < rhs.uuidString : a < b
        }
    }

    private func persist(_ proposed: State) throws {
        do {
            let data = try JSONEncoder().encode(proposed)
            guard data.count <= 2_000_000 else { throw StorageIssue.writeFailed }
            try data.write(to: directory.appendingPathComponent("state.json"),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { throw StorageIssue.writeFailed }
    }

    nonisolated private static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int64.max : max(0, sum)
    }

    /// Do not follow directory links, count directories twice, or undercount a
    /// sparse file's eventual logical size against the video cache budget.
    nonisolated private static func residentBytes(in roots: [URL]) throws -> Int64 {
        var total: Int64 = 0
        var seen: Set<String> = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                        .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        for root in roots {
            guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else {
                throw StorageIssue.unreadable
            }
            for case let file as URL in files {
                let values = try file.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { files.skipDescendants(); continue }
                guard values.isRegularFile == true, seen.insert(file.standardizedFileURL.path).inserted else { continue }
                let count = max(values.fileSize ?? 0, values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                total = add(total, Int64(max(0, count)))
            }
        }
        return total
    }

    private enum StorageIssue: LocalizedError {
        case unreadable, writeFailed
        var errorDescription: String? {
            switch self {
            case .unreadable: return "本地存储设置暂不可用，已保留全部视频副本。"
            case .writeFailed: return "无法保存本地存储设置，请检查可用空间后重试。"
            }
        }
    }
}
