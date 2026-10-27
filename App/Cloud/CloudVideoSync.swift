import Combine
import CryptoKit
import Foundation
import UIKit

@MainActor
final class CloudVideoSync: ObservableObject {
    nonisolated static let containerIdentifier = "iCloud.app.vyu.ios"
    private static let localOnlyMessage = "此本机构建未启用 iCloud，本机视频仍可播放"
    @Published private(set) var entries: [UUID: CloudVideoEntry] = [:]
    @Published private(set) var operations: [UUID: String] = [:]
    @Published private(set) var message = "正在检查 iCloud"
    @Published private(set) var isAvailable = false
    @Published private(set) var accountChanged = false
    @Published private(set) var metadataMessage: String?
    @Published var readyToPlay: DownloadRecord?

    private struct LocalState: Codable {
        var acceptedAccount: String?
        var owners: [UUID: String] = [:]
        var hidden: [String: Set<UUID>] = [:]
        var deletions: [String: Set<UUID>] = [:]
    }
    private let downloads: DownloadManager
    private let metadataStore: VideoMetadataStore?
    private let directory: URL
    private let containerOverride: URL?
    private let identityOverride: @Sendable () -> String?
    private let isSyncEnabled: Bool
    private var access: CloudSyncAccess?
    private var state = LocalState()
    private var stateReadable = true
    private var account: String?
    private var container: URL?
    private var generation = UUID()
    private var query: NSMetadataQuery?
    private var queryReady = false
    private var observations: [NSObjectProtocol] = []
    private var subscription: AnyCancellable?
    private var metadataSubscription: AnyCancellable?
    private var localUseSubscription: AnyCancellable?
    private var refreshing = false
    private var refreshAgain = false
    private var restoreRequests: Set<UUID> = []
    private var pendingPlaybackID: UUID?
    private var uploadFailures: Set<UUID> = []
    private struct CoverWork {
        let metadata: VideoMetadata
        let record: DownloadRecord
        let access: CloudCoverWriteAccess
    }
    private var coverWork: [UUID: CoverWork] = [:]
    private var cacheEvictionWork: [UUID: CloudCoverWriteAccess] = [:]

    /// The override is used only by tests with temporary, local synthetic data.
    init(downloads: DownloadManager, metadataStore: VideoMetadataStore? = nil, containerOverride: URL? = nil,
         identityOverride: @escaping @Sendable () -> String? = { "fixture-account" }, iCloudEnabled: Bool? = nil) {
        self.downloads = downloads
        self.metadataStore = metadataStore
        self.containerOverride = containerOverride
        self.identityOverride = identityOverride
        isSyncEnabled = containerOverride != nil || (iCloudEnabled ?? Self.iCloudEnabled(
            infoValue: Bundle.main.object(forInfoDictionaryKey: "VYuICloudEnabled")))
        directory = downloads.rootDirectory.appendingPathComponent("CloudSync", isDirectory: true)
        guard isSyncEnabled else { message = Self.localOnlyMessage; return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let stateURL = directory.appendingPathComponent("state.json")
            if FileManager.default.fileExists(atPath: stateURL.path) {
                state = try JSONDecoder().decode(LocalState.self, from: Data(contentsOf: stateURL))
            }
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let parts = url.lastPathComponent.split(separator: "-", maxSplits: 1).map(String.init)
                if parts.count == 2, ["Upload", "Import"].contains(parts[0]), UUID(uuidString: parts[1]) != nil {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        } catch { stateReadable = false; message = "无法读取同步状态，本机视频仍可播放" }
        observations.append(NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
                self?.access?.cancel()
                self?.generation = UUID()
                self?.query?.stop(); self?.query = nil; self?.queryReady = false
                await self?.refreshAccount()
            } })
        subscription = downloads.$records.dropFirst().handleEvents(receiveOutput: { [weak self] records in
            self?.invalidateCoverWork(records: records)
        }).debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in await self?.synchronize() } }
        metadataSubscription = metadataStore?.$entries.dropFirst().handleEvents(receiveOutput: { [weak self] entries in
            self?.invalidateCoverWork(metadata: entries)
        }).debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in await self?.synchronize() } }
        localUseSubscription = downloads.$localVideoUseIDs.dropFirst().sink { [weak self] ids in
            for id in ids { self?.cacheEvictionWork[id]?.cancel() }
        }
    }

    deinit {
        query?.stop()
        observations.forEach(NotificationCenter.default.removeObserver)
    }

    var visibleEntries: [CloudVideoEntry] {
        let hidden = account.flatMap { state.hidden[$0] } ?? []
        let deleted = account.flatMap { state.deletions[$0] } ?? []
        return entries.values.filter { !hidden.contains($0.id) && !deleted.contains($0.id) }
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    func entry(for id: UUID) -> CloudVideoEntry? { visibleEntries.first { $0.id == id } }

    nonisolated static func iCloudEnabled(infoValue: Any?) -> Bool {
        if let value = infoValue as? Bool { return value }
        if let value = infoValue as? String {
            return !["NO", "FALSE", "0"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
        }
        return true
    }

    func status(for record: DownloadRecord) -> String? {
        guard isSyncEnabled else { return record.phase == .complete ? Self.localOnlyMessage : nil }
        if downloads.cloudPreparationStatus[record.id] != nil { return nil }
        if record.candidate.kind == .hls && record.phase == .complete,
           !(downloads.localURL(for: record).map { CloudVideoArchive.isEligibleForSync(record: record, mediaURL: $0) } ?? false) {
            return "可在本机离线播放，暂不支持跨设备同步"
        }
        if let operation = operations[record.id] { return operation }
        if let owner = state.owners[record.id], let account, owner != account { return "保留在本机，未同步到当前 iCloud 账号" }
        if let entry = entries[record.id] {
            if entry.transferError { return "iCloud 传输失败，请检查网络和云端空间" }
            return entry.uploaded ? "已同步到 iCloud" : "等待 iCloud 完成上传"
        }
        if record.phase == .complete { return isAvailable ? "等待上传到 iCloud" : "尚未同步到 iCloud" }
        return nil
    }

    func refreshAccount() async {
        guard isSyncEnabled, stateReadable else { return }
        let expected = generation
        let override = containerOverride
        let identityOverride = self.identityOverride
        let resolved = await Task.detached(priority: .utility) { () -> (String?, URL?) in
            if let override { return (identityOverride(), override) }
            guard let key = Self.identityKey() else { return (nil, nil) }
            let url = FileManager.default.url(forUbiquityContainerIdentifier: Self.containerIdentifier)?.appendingPathComponent("Documents", isDirectory: true)
            return (key, url)
        }.value
        guard expected == generation else { return }
        if resolved.0 != account || resolved.1 != container {
            access?.cancel()
            if let previous = state.acceptedAccount, previous != resolved.0 {
                for record in downloads.records where state.owners[record.id] == nil { state.owners[record.id] = previous }
                guard saveState() else { return }
            }
            generation = UUID()
            query?.stop(); query = nil; queryReady = false
            entries = [:]; operations = [:]; restoreRequests = []; uploadFailures = []; metadataMessage = nil
            pendingPlaybackID = nil
            readyToPlay = nil
            account = resolved.0; container = resolved.1
        }
        guard let account, let container else {
            isAvailable = false
            message = "iCloud 不可用，请检查账号、iCloud Drive 和 App 的 iCloud 权限"
            return
        }
        if state.acceptedAccount == nil {
            state.acceptedAccount = account
            guard saveState() else { return }
        }
        accountChanged = state.acceptedAccount != account
        guard !accountChanged else {
            isAvailable = false; message = "iCloud 账号已更换，请确认后继续同步"; return
        }
        let current = generation
        let provider: @Sendable () -> String?
        if override == nil { provider = { Self.identityKey() } } else { provider = identityOverride }
        let access = CloudSyncAccess(account: account, identity: provider)
        self.access = access
        do {
            try await Task.detached(priority: .utility) { try CloudVideoFiles.prepare(container: container, access: access) }.value
            guard current == generation else { return }
            isAvailable = true
            if query == nil && containerOverride == nil { startQuery(container: container) }
            if containerOverride != nil { queryReady = true }
            await synchronize()
        } catch { if current == generation { isAvailable = false; message = "无法访问 iCloud，请检查网络和云端空间后重试" } }
    }

    func acceptCurrentAccount() async {
        guard let account else { return }
        state.acceptedAccount = account
        guard saveState() else { return }
        // Ownership of previously synced files remains tied to the original account.
        await refreshAccount()
    }

    func retrySync() async {
        uploadFailures = []
        operations = operations.filter { restoreRequests.contains($0.key) }
        await refreshAccount()
    }

    func restore(id: UUID) async {
        guard isAvailable, entries[id] != nil, let account,
              state.owners[id] == nil || state.owners[id] == account else { return }
        cacheEvictionWork[id]?.cancel()
        pendingPlaybackID = id
        restoreRequests.insert(id)
        operations[id] = "正在从 iCloud 下载，完成后播放"
        await synchronize()
    }

    func cancelRestore(id: UUID) {
        restoreRequests.remove(id); operations.removeValue(forKey: id)
        if pendingPlaybackID == id { cancelPendingPlayback() }
    }

    func cancelPendingPlayback() { pendingPlaybackID = nil; readyToPlay = nil }

    func cancelCacheEvictions() {
        for access in cacheEvictionWork.values { access.cancel() }
    }

    /// Removes an owned local media file only after independently checking its cloud copy.
    /// The caller owns the preference/budget decision and may revoke it at any await point.
    func evictLocalCacheIfRecoverable(id: UUID, isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        guard isCurrent(), cacheEvictionWork[id] == nil,
              let account, let container, let access,
              cacheEvictionAllowed(id: id, account: account),
              let entry = entries[id], entry.uploaded, !entry.transferError,
              let record = downloads.records.first(where: { $0.id == id }),
              downloads.canEvictLocalCache(record),
              let identity = downloads.cacheFileIdentity(for: record) else { return false }
        let current = generation
        let metadata = metadataStore?.metadata(for: id)
        let evictionAccess = CloudCoverWriteAccess()
        cacheEvictionWork[id] = evictionAccess
        defer { if cacheEvictionWork[id] === evictionAccess { cacheEvictionWork.removeValue(forKey: id) } }
        let ubiquitous = containerOverride == nil
        let recoverable = try await Task.detached(priority: .utility) {
            try evictionAccess.check()
            let result = try CloudVideoFiles.canRemoveLocalCache(entry: entry, localURL: identity.url,
                container: container, ubiquitous: ubiquitous, access: access, metadata: metadata)
            try evictionAccess.check()
            return result
        }.value
        try access.check(); try evictionAccess.check()
        guard recoverable, isCurrent(), generation == current,
              cacheEvictionAllowed(id: id, account: account), entries[id] == entry,
              metadataStore?.metadata(for: id) == metadata,
              downloads.records.contains(record), downloads.canEvictLocalCache(record),
              downloads.cacheFileIdentity(for: record) == identity else { return false }
        try access.check(); try evictionAccess.check()
        // No suspension between the final use/account checks and the durable local removal.
        let removed = try downloads.evictLocalCache(record: record, expectedIdentity: identity)
        guard removed else { return false }
        // Removing the extra iCloud cache is optional. Failure must not turn a successful
        // local removal into a retry that could touch another record.
        if ubiquitous, isCurrent(), generation == current, cacheEvictionAllowed(id: id, account: account) {
            _ = try? await Task.detached(priority: .utility) {
                try CloudVideoFiles.evictResidentMedia(entry: entry, container: container, ubiquitous: true,
                    access: access, evictionAccess: evictionAccess)
            }.value
        }
        return true
    }

    func localCloudMediaUsage() async throws -> Int64 {
        if containerOverride != nil { return 0 }
        guard let container, let access, let account, isAvailable,
              !accountChanged, state.acceptedAccount == account else { throw CloudVideoArchiveError.fileOperationFailed }
        let current = generation
        let values = Array(entries.values)
        let ubiquitous = containerOverride == nil
        let bytes = try await Task.detached(priority: .utility) {
            try CloudVideoFiles.residentMediaBytes(entries: values, container: container,
                ubiquitous: ubiquitous, access: access)
        }.value
        try access.check()
        guard current == generation else { throw CancellationError() }
        return bytes
    }

    /// Reclaims redundant native iCloud media cache, including a second local media copy.
    @discardableResult
    func evictCloudOnlyMediaCaches(ids: Set<UUID>? = nil,
                                  onlyRedundant: Bool = false,
                                  isCurrent: @escaping @MainActor () -> Bool) async -> Int64 {
        guard containerOverride == nil, let account, let container, let access else { return 0 }
        let current = generation
        var reclaimed: Int64 = 0
        for entry in Array(entries.values) {
            let id = entry.id
            if let ids, !ids.contains(id) { continue }
            guard isCurrent(), generation == current else { break }
            guard cacheEvictionWork[id] == nil, cacheEvictionAllowed(id: id, account: account),
                  entry.uploaded, !entry.transferError else { continue }
            if onlyRedundant {
                guard let record = downloads.records.first(where: { $0.id == id }),
                      downloads.localURL(for: record) != nil, downloads.canEvictLocalCache(record) else { continue }
            }
            if let record = downloads.records.first(where: { $0.id == id }),
               [.queued, .downloading, .paused, .validating].contains(record.phase) { continue }
            if let record = downloads.records.first(where: { $0.id == id }),
               downloads.localURL(for: record) != nil, !downloads.canEvictLocalCache(record) { continue }
            let evictionAccess = CloudCoverWriteAccess()
            cacheEvictionWork[id] = evictionAccess
            let bytes = (try? await Task.detached(priority: .utility) {
                try CloudVideoFiles.evictResidentMedia(entry: entry, container: container, ubiquitous: true,
                    access: access, evictionAccess: evictionAccess)
            }.value) ?? 0
            if cacheEvictionWork[id] === evictionAccess { cacheEvictionWork.removeValue(forKey: id) }
            reclaimed = bytes > Int64.max - reclaimed ? Int64.max : reclaimed + bytes
        }
        return reclaimed
    }

    private func cacheEvictionAllowed(id: UUID, account: String) -> Bool {
        isSyncEnabled && isAvailable && !accountChanged && self.account == account &&
            state.acceptedAccount == account && (state.owners[id] == nil || state.owners[id] == account) &&
            !(state.deletions[account]?.contains(id) ?? false) && !(state.hidden[account]?.contains(id) ?? false) &&
            operations[id] == nil && !restoreRequests.contains(id) && pendingPlaybackID != id &&
            readyToPlay?.id != id && coverWork[id] == nil && !downloads.isLocalVideoInUse(id: id)
    }

    func removeLocalCache(id: UUID) {
        downloads.removeCache(id: id)
        guard containerOverride == nil, let entry = entries[id], entry.uploaded,
              let container, let access else { return }
        let media = CloudVideoFiles.packageURL(id, container: container).appendingPathComponent("video.\(entry.manifest.fileExtension)")
        Task.detached(priority: .utility) {
            do {
                try access.check()
                // Eviction preserves the server copy and performs its own coordination.
                try FileManager.default.evictUbiquitousItem(at: media)
            } catch { /* The system can reclaim this additional local iCloud cache later. */ }
        }
    }

    func hideFromThisDevice(id: UUID) {
        cancelRestore(id: id)
        if let account { state.hidden[account, default: []].insert(id); guard saveState() else { return } }
        downloads.removeRecord(id: id)
    }

    func showCloudVideos() {
        if let account { state.hidden[account] = []; _ = saveState(); objectWillChange.send() }
    }

    func deleteEverywhere(id: UUID) async {
        guard let account, isAvailable else { return }
        guard state.owners[id] == nil || state.owners[id] == account else { return }
        state.owners[id] = account
        state.deletions[account, default: []].insert(id)
        // Persist intent before removing anything; it survives app termination and failed uploads.
        guard saveState() else { return }
        cancelRestore(id: id)
        downloads.removeRecord(id: id)
        entries.removeValue(forKey: id)
        await synchronize()
    }

    private func startQuery(container: URL) {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(value: true)
        query.notificationBatchingInterval = 1
        let current = generation
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] note in
                let finished = note.name == .NSMetadataQueryDidFinishGathering
                Task { @MainActor in
                    guard let self, self.generation == current, self.query != nil else { return }
                    if finished { self.queryReady = true }
                    await self.synchronize()
                }
            })
        }
        self.query = query
        if !query.start() {
            query.stop(); self.query = nil; queryReady = false; isAvailable = false
            message = "无法读取 iCloud 视频列表，请重试"
        }
    }

    private func metadataURLs() -> [URL] {
        guard let query else { return [] }
        query.disableUpdates(); defer { query.enableUpdates() }
        return (query.results as? [NSMetadataItem] ?? []).compactMap { $0.value(forAttribute: NSMetadataItemURLKey) as? URL }
    }

    func synchronize() async {
        guard isSyncEnabled, isAvailable, queryReady, let account, let container, let access else { return }
        if refreshing { refreshAgain = true; return }
        refreshing = true
        let current = generation
        let ubiquitous = containerOverride == nil
        defer {
            refreshing = false
            if refreshAgain { refreshAgain = false; Task { await synchronize() } }
        }
        func valid() -> Bool {
            guard current == generation, isAvailable, self.account == account else { return false }
            do { try access.check(); return true } catch { return false }
        }
        do {
            for id in state.deletions[account] ?? [] {
                try await Task.detached(priority: .utility) { try CloudVideoFiles.delete(id: id, container: container, access: access) }.value
                guard valid() else { return }
            }
            let urls = metadataURLs()
            let snapshot = try await Task.detached(priority: .utility) {
                try CloudVideoFiles.snapshot(container: container, metadataURLs: urls, ubiquitous: ubiquitous)
            }.value
            guard valid() else { return }
            state.deletions[account, default: []].formUnion(snapshot.deleted)
            guard saveState() else { return }
            for id in snapshot.deleted {
                cancelRestore(id: id)
                if state.owners[id] == account, downloads.records.contains(where: { $0.id == id }) { downloads.removeRecord(id: id) }
                try await Task.detached(priority: .utility) { try CloudVideoFiles.purgeDeletedPackage(id: id, container: container, access: access) }.value
                guard valid() else { return }
            }
            let deleted = state.deletions[account] ?? []
            entries = snapshot.entries.filter { !deleted.contains($0.id) }.reduce(into: [:]) { result, entry in
                if result[entry.id] == nil { result[entry.id] = entry }
            }
            // Even a cloud-only video owns its local annotations. Keep this binding
            // when changing accounts so they can never be uploaded to the new account.
            if metadataStore != nil {
                var claimed = false
                for id in entries.keys where state.owners[id] == nil { state.owners[id] = account; claimed = true }
                if claimed { guard saveState() else { return } }
            }

            for id in Array(restoreRequests) {
                guard state.owners[id] == nil || state.owners[id] == account else {
                    cancelRestore(id: id)
                    continue
                }
                guard let entry = entries[id] else { continue }
                let stage = directory.appendingPathComponent("Import-\(UUID().uuidString)", isDirectory: true)
                do {
                    let package = try await Task.detached(priority: .utility) {
                        try CloudVideoFiles.downloadCopy(entry: entry, container: container, stagingParent: stage, ubiquitous: ubiquitous, access: access)
                    }.value
                    defer { try? FileManager.default.removeItem(at: stage) }
                    guard valid(), restoreRequests.contains(id) else { continue }
                    guard let package else {
                        if entry.transferError { operations[id] = "iCloud 下载未完成，可轻点重试" }
                        continue
                    }
                    operations[id] = "正在检查 iCloud 视频"
                    let record = try await downloads.importCloudVideo(manifest: entry.manifest, from: package,
                        isCurrent: { valid() && self.restoreRequests.contains(id) && !(self.state.deletions[account]?.contains(id) ?? false) })
                    guard valid(), restoreRequests.remove(id) != nil else { continue }
                    state.owners[id] = account
                    guard saveState() else { return }
                    operations.removeValue(forKey: id)
                    if pendingPlaybackID == id { pendingPlaybackID = nil; readyToPlay = record }
                } catch {
                    guard valid() else { return }
                    restoreRequests.remove(id)
                    operations[id] = "iCloud 视频恢复失败，请重试"
                }
            }

            for record in downloads.records where record.phase == .complete {
                guard valid() else { return }
                guard entries[record.id] == nil, !deleted.contains(record.id), !uploadFailures.contains(record.id),
                      state.owners[record.id] == nil || state.owners[record.id] == account,
                      let local = downloads.localURL(for: record) else { continue }
                if record.candidate.kind == .hls, local.pathExtension.lowercased() == "movpkg" {
                    downloads.prepareCloudCopy(id: record.id)
                    continue
                }
                guard CloudVideoArchive.isEligibleForSync(record: record, mediaURL: local) else { continue }
                state.owners[record.id] = account
                guard saveState() else { return }
                operations[record.id] = "正在准备 iCloud 视频"
                let selection = metadataStore?.metadata(for: record.id)
                let thumbnail = await downloads.thumbnailStore.image(for: record, localURL: local,
                    frameSeconds: selection?.coverFrameSeconds)?.jpegData(compressionQuality: 0.78)
                guard valid(), downloads.records.contains(where: { $0.id == record.id && $0.phase == .complete }),
                      !(state.deletions[account]?.contains(record.id) ?? false) else { continue }
                let parent = directory.appendingPathComponent("Upload-\(UUID().uuidString)", isDirectory: true)
                let stage = parent.appendingPathComponent(record.id.uuidString, isDirectory: true)
                do {
                    let manifest = try await Task.detached(priority: .utility) {
                        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                        return try CloudVideoArchive.createStagingPackage(record: record, mediaURL: local, thumbnailJPEG: thumbnail, at: stage)
                    }.value
                    defer { try? FileManager.default.removeItem(at: parent) }
                    guard valid(), downloads.records.contains(where: { $0.id == record.id && $0.phase == .complete }),
                          !(state.deletions[account]?.contains(record.id) ?? false) else { continue }
                    try await Task.detached(priority: .utility) {
                        try CloudVideoFiles.publish(staging: stage, manifest: manifest, container: container, ubiquitous: ubiquitous, access: access)
                    }.value
                    guard valid() else { return }
                    if state.deletions[account]?.contains(record.id) == true { refreshAgain = true; continue }
                    entries[record.id] = CloudVideoEntry(manifest: manifest, thumbnail: thumbnail, uploaded: !ubiquitous, transferError: false)
                    operations.removeValue(forKey: record.id)
                } catch {
                    try? FileManager.default.removeItem(at: parent)
                    guard valid() else { return }
                    uploadFailures.insert(record.id)
                    operations[record.id] = "上传未完成，请检查网络和存储空间后重试"
                }
            }
            guard valid() else { return }
            if let metadataStore {
                let allowed = Set(entries.keys.filter { state.owners[$0] == account && !deleted.contains($0) })
                let ownedDeleted = Set(deleted.filter { state.owners[$0] == account })
                var localFailure = false
                do { try metadataStore.remove(ids: ownedDeleted) }
                catch { localFailure = true }
                do {
                    let localMetadata = metadataStore.entries.filter { allowed.contains($0.key) }
                    let annotations = try await Task.detached(priority: .utility) {
                        try CloudVideoMetadataFiles.synchronize(local: localMetadata, allowedIDs: allowed,
                            deletedIDs: ownedDeleted, container: container, metadataURLs: urls,
                            ubiquitous: ubiquitous, access: access)
                    }.value
                    guard valid() else { return }
                    // A deletion can arrive after the video snapshot. Do not import its edits.
                    let newlyDeleted = annotations.deleted.subtracting(deleted)
                    if !newlyDeleted.isEmpty {
                        state.deletions[account, default: []].formUnion(newlyDeleted)
                        guard saveState() else { return }
                        for id in newlyDeleted {
                            cancelRestore(id: id)
                            if readyToPlay?.id == id { readyToPlay = nil }
                            if state.owners[id] == account { downloads.removeRecord(id: id) }
                            entries.removeValue(forKey: id)
                        }
                        try metadataStore.remove(ids: newlyDeleted)
                        refreshAgain = true
                    }
                    try metadataStore.merge(annotations.entries)
                    metadataMessage = localFailure || annotations.invalidCount > 0 ? "视频资料暂未同步，可稍后重试" : nil
                    // A cloud-only device imports the chosen time without restoring media.
                    // Devices with a complete local copy can publish the corresponding small JPEG.
                    for id in allowed.sorted(by: { $0.uuidString < $1.uuidString }) {
                        guard valid(), state.owners[id] == account,
                              !(state.deletions[account]?.contains(id) ?? false),
                              let annotation = metadataStore.metadata(for: id),
                              let entry = entries[id],
                              let record = downloads.records.first(where: { $0.id == id && $0.phase == .complete }),
                              let local = downloads.localURL(for: record) else { continue }
                        do {
                            let currentCover = try await Task.detached(priority: .utility) {
                                try CloudVideoFiles.hasCurrentCover(metadata: annotation, manifest: entry.manifest,
                                    container: container, ubiquitous: ubiquitous, access: access)
                            }.value
                            guard valid(), metadataStore.metadata(for: id) == annotation,
                                  downloads.records.contains(record), entries[id] != nil,
                                  !(state.deletions[account]?.contains(id) ?? false) else { continue }
                            guard !currentCover else { continue }
                            let writeAccess = CloudCoverWriteAccess()
                            coverWork[id]?.access.cancel()
                            coverWork[id] = CoverWork(metadata: annotation, record: record, access: writeAccess)
                            defer { if coverWork[id]?.access === writeAccess { coverWork.removeValue(forKey: id) } }
                            let thumbnail = await downloads.thumbnailStore.image(for: record, localURL: local,
                                frameSeconds: annotation.coverFrameSeconds)?.jpegData(compressionQuality: 0.78)
                            try writeAccess.check()
                            guard valid(), metadataStore.metadata(for: id) == annotation,
                                  downloads.records.contains(record), entries[id] != nil,
                                  !(state.deletions[account]?.contains(id) ?? false) else { continue }
                            guard let thumbnail else { throw CloudVideoArchiveError.invalidThumbnail }
                            let wrote = try await Task.detached(priority: .utility) {
                                try CloudVideoFiles.updateCover(thumbnailJPEG: thumbnail, metadata: annotation,
                                    manifest: entry.manifest, container: container, ubiquitous: ubiquitous,
                                    access: access, writeAccess: writeAccess)
                            }.value
                            try writeAccess.check()
                            guard valid(), metadataStore.metadata(for: id) == annotation,
                                  downloads.records.contains(record), let currentEntry = entries[id],
                                  !(state.deletions[account]?.contains(id) ?? false) else { continue }
                            if wrote {
                                entries[id] = CloudVideoEntry(manifest: currentEntry.manifest, thumbnail: thumbnail,
                                    uploaded: !ubiquitous, transferError: currentEntry.transferError)
                            }
                        } catch is CancellationError {
                            guard valid() else { return }
                            refreshAgain = true
                        } catch {
                            guard valid() else { return }
                            metadataMessage = "封面暂未同步，可稍后重试"
                        }
                    }
                } catch {
                    guard valid() else { return }
                    metadataMessage = "视频资料暂未同步，可稍后重试"
                }
            }
            guard valid() else { return }
            let count = entries.values.filter(\.uploaded).count
            message = snapshot.invalidCount > 0 ? "部分 iCloud 视频信息暂不可用，可稍后重试" :
                "\(count) 个视频已同步 · 换手机后使用同一 iCloud 账号恢复"
        } catch {
            if valid() { message = "iCloud 同步未完成，请检查网络和存储空间后重试" }
        }
    }

    private func invalidateCoverWork(records: [DownloadRecord]) {
        for work in coverWork.values where !records.contains(work.record) { work.access.cancel() }
    }

    private func invalidateCoverWork(metadata: [UUID: VideoMetadata]) {
        for (id, work) in coverWork where metadata[id] != work.metadata { work.access.cancel() }
    }

    @discardableResult private func saveState() -> Bool {
        do {
            try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("state.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            isAvailable = false; message = "同步状态未能保存，本机视频仍可播放"; return false
        }
    }

    nonisolated private static func identityKey() -> String? {
        guard let token = FileManager.default.ubiquityIdentityToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
