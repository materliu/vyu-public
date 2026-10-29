import AVFoundation
import Combine
import CryptoKit
import Darwin
import Foundation
import WebKit

/// Identity captured without reading media bytes. Directory identities also
/// prevent a replaced Media directory from inheriting an earlier safety check.
struct VideoCacheFileIdentity: Sendable, Equatable, Codable {
    let url: URL
    let byteCount: Int64
    let modificationDate: Date
    let fileNumber: UInt64
    let deviceNumber: UInt64
    fileprivate let changeSeconds: Int64
    fileprivate let changeNanoseconds: Int64
    fileprivate let modificationNanoseconds: Int64
    fileprivate let rootFileNumber: UInt64
    fileprivate let mediaFileNumber: UInt64
    fileprivate let rootDeviceNumber: UInt64
    fileprivate let mediaDeviceNumber: UInt64
}

/// Hooks run before the real filesystem operation, allowing deterministic
/// storage-failure tests without substituting a successful fake deletion.
struct VideoCacheEvictionHooks {
    var beforeStateWrite: (() throws -> Void)?
    var beforeFileRemoval: (() throws -> Void)?
}

enum VideoCacheEvictionError: Error {
    case stateWriteFailed, fileRemovalFailed, recoveryRequired
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    @Published private(set) var records: [DownloadRecord] = [] { didSet { activityDidChange() } }
    @Published private(set) var storageError: String?
    @Published private(set) var cloudPreparationStatus: [UUID: String] = [:]
    /// Waiting for a resume slot is not an active download; these records remain paused.
    @Published private(set) var pendingResumeIDs: Set<UUID> = []
    @Published private(set) var hasActiveDownloads = false
    @Published private(set) var localVideoUseIDs: Set<UUID> = []
    private var localVideoUseLeases: [UUID: UUID] = [:]
    private let cacheEvictionHooks: VideoCacheEvictionHooks
    private let cacheRootURL: URL
    private var cacheRecoveryRequired = false
    private static let maximumResumedDownloads = 2
    private var resumeQueue: [UUID] = []
    private var resumeDrainScheduled = false
    private var restoringTasks = true
    private var launchingResumeTokens: [UUID: UUID] = [:] { didSet { activityDidChange() } }
    private var preflightTasks: [UUID: Task<MediaInspection, Error>] = [:] { didSet { activityDidChange() } }
    private var preflightTokens: [UUID: String] = [:]
    let rootDirectory: URL
    let thumbnailStore: VideoThumbnailStore
    private let diagnostics: DownloadDiagnostics
    private let delegateProxy: TransferDelegate
    private let identifier: String
    private var tasks: [UUID: URLSessionTask] = [:] { didSet { activityDidChange() } }
    private var browserTasks: [UUID: BrowserFileDownload] = [:] { didSet { activityDidChange() } }
    private var hlsRelays: [UUID: HLSDownloadRelay] = [:]
    private var assemblyGenerations: [UUID: UUID] = [:]
    private var foregroundOnlyHLS: Set<UUID> = []
    private var backgroundHLS: BackgroundHLSStore!
    private var portableTasks: [UUID: Task<Void, Never>] = [:] { didSet { activityDidChange() } }
    private var cloudPreparationTasks: [UUID: Task<Void, Never>] = [:] { didSet { activityDidChange() } }
    private var cloudPreparationTokens: [UUID: UUID] = [:]
    private let preferPortableHLS: Bool
    private var stateReadable = true
    private var appInBackground = false
    private var tokens: [UUID: String] = [:] { didSet { activityDidChange() } }
    private var authenticated: Set<UUID> = []
    private var contexts: [UUID: [HTTPCookie]] = [:]
    private var pendingPause: Set<UUID> = [] { didSet { activityDidChange() } }
    private var hlsLocations: [UUID: URL] = [:]
    private var validations: Set<String> = [] { didSet { activityDidChange() } }
    private var pendingCompletionWrites: Set<UUID> = []
    private var restoringIDs: Set<UUID> = []
    private var touchedIDs: Set<UUID> = []
    private struct ValidationExpectation: Codable { let duration: Double?; let requiresAudio: Bool }
    private var expectations: [UUID: ValidationExpectation] = [:]
    private struct DownloadArchive: Codable {
        let records: [DownloadRecord]
        let authenticated: Set<UUID>
        let expectations: [UUID: ValidationExpectation]
        let attempts: [UUID: String]
        var foregroundHLS: Set<UUID>? = nil
    }
    private struct CacheEvictionJournal: Codable {
        let original: DownloadRecord
        let evicted: DownloadRecord
        let identity: VideoCacheFileIdentity
    }
    private static var backgroundCompletions: [String: () -> Void] = [:]
    private static var finishedBackgroundIdentifiers: Set<String> = []

    private lazy var backgroundSession: URLSession = {
        URLSession(configuration: configuration(background: true, suffix: ".files"), delegate: delegateProxy, delegateQueue: nil)
    }()
    private lazy var foregroundSession: URLSession = {
        URLSession(configuration: configuration(background: false, suffix: ""), delegate: delegateProxy, delegateQueue: nil)
    }()
    private lazy var hlsSession: AVAssetDownloadURLSession = {
        AVAssetDownloadURLSession(configuration: configuration(background: true, suffix: ".hls"), assetDownloadDelegate: delegateProxy, delegateQueue: nil)
    }()

    init(rootDirectory: URL? = nil, preferPortableHLS: Bool = true, initiallyInBackground: Bool = false,
         cacheEvictionHooks: VideoCacheEvictionHooks = VideoCacheEvictionHooks()) {
        self.preferPortableHLS = preferPortableHLS
        self.appInBackground = initiallyInBackground
        let root = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VYu", isDirectory: true)
        self.rootDirectory = root
        self.cacheRootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        self.cacheEvictionHooks = cacheEvictionHooks
        thumbnailStore = VideoThumbnailStore(directory: root.appendingPathComponent("Thumbnails", isDirectory: true))
        diagnostics = DownloadDiagnostics(rootDirectory: root)
        let suffix = rootDirectory.map { String(SHA256.hash(data: Data($0.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)) } ?? "library"
        identifier = "app.vyu.ios.downloads.\(suffix)"
        delegateProxy = TransferDelegate(stagingDirectory: root.appendingPathComponent("Staging", isDirectory: true))
        super.init()
        delegateProxy.owner = self
        do {
            for name in ["", "Media", "Resume", "Staging"] {
                let url = name.isEmpty ? root : root.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                var mutableURL = url; try mutableURL.setResourceValues(values)
            }
            let savedState: Data?
            do { savedState = try Data(contentsOf: stateURL) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                savedState = nil
            }
            if let data = savedState {
                if let archive = try? JSONDecoder().decode(DownloadArchive.self, from: data) {
                    records = archive.records; authenticated = archive.authenticated
                    expectations = archive.expectations; tokens = archive.attempts
                    foregroundOnlyHLS = archive.foregroundHLS ?? []
                } else {
                    records = try JSONDecoder().decode([DownloadRecord].self, from: data)
                    if let data = try? Data(contentsOf: modeURL), let ids = try? JSONDecoder().decode([UUID].self, from: data) { authenticated = Set(ids) }
                    if let data = try? Data(contentsOf: attemptURL), let stored = try? JSONDecoder().decode([UUID: String].self, from: data) { tokens = stored }
                    if let data = try? Data(contentsOf: expectationURL), let stored = try? JSONDecoder().decode([UUID: ValidationExpectation].self, from: data) { expectations = stored }
                }
            }
            try recoverInterruptedCacheEviction()
            for index in records.indices where records[index].phase == .complete && localURL(for: records[index]) == nil {
                records[index].phase = .failed; records[index].failure = "本机视频文件已不存在，请重新下载。"
            }
            cleanupAbandonedHLSExports()
            let staging = root.appendingPathComponent("Staging", isDirectory: true)
            for file in try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
                let name = file.lastPathComponent
                if name.hasPrefix("hls-part-"), UUID(uuidString: String(name.dropFirst("hls-part-".count))) != nil {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        } catch {
            stateReadable = false
            storageError = "无法读取本机下载目录。请检查可用存储空间后重新打开 App。"
        }
        guard stateReadable else { return }
        thumbnailStore.retainRecords(Set(records.filter {
            $0.localCacheEvicted == true || ($0.phase == .complete && localURL(for: $0) != nil)
        }.map(\.id)))
        backgroundHLS = BackgroundHLSStore(root: root, identifier: identifier + ".parts")
        backgroundHLS.onChange = { [weak self] job in self?.backgroundHLSChanged(job) }
        backgroundHLS.onFailure = { [weak self] id, attempt, error in self?.backgroundHLSFailed(id: id, attempt: attempt, error: error) }
        backgroundHLS.onEventsFinished = { [weak self] identifier in self?.backgroundEventsFinished(identifier) }
        restoringIDs = Set(records.map(\.id))
        Task { await restoreTasks() }
    }

    static func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        if finishedBackgroundIdentifiers.remove(identifier) != nil { completionHandler() }
        else { backgroundCompletions[identifier] = completionHandler }
    }

    private func configuration(background: Bool, suffix: String) -> URLSessionConfiguration {
        let config = background ? URLSessionConfiguration.background(withIdentifier: identifier + suffix) : .default
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 24 * 60 * 60
        config.isDiscretionary = false
        if background { config.sessionSendsLaunchEvents = true }
        return config
    }
    private var stateURL: URL { rootDirectory.appendingPathComponent("downloads.json") }
    private var cacheEvictionJournalURL: URL { rootDirectory.appendingPathComponent("cache-eviction.json") }
    private var modeURL: URL { rootDirectory.appendingPathComponent("transfer-modes.json") }
    private var expectationURL: URL { rootDirectory.appendingPathComponent("validation-expectations.json") }
    private var attemptURL: URL { rootDirectory.appendingPathComponent("download-attempts.json") }
    private func resumeURL(_ id: UUID) -> URL { rootDirectory.appendingPathComponent("Resume/\(id.uuidString).data") }

    private func cleanupAbandonedHLSExports() {
        let media = rootDirectory.appendingPathComponent("Media", isDirectory: true)
        let owned = Set(records.compactMap(\.localRelativePath))
        for file in (try? FileManager.default.contentsOfDirectory(at: media, includingPropertiesForKeys: nil)) ?? [] {
            let name = file.lastPathComponent
            let stage = name.hasPrefix(".hls-export-") && UUID(uuidString: String(name.dropFirst(".hls-export-".count))) != nil
            let portable = name.hasPrefix("portable-") && name.hasSuffix(".mp4") &&
                UUID(uuidString: String(name.dropFirst("portable-".count).dropLast(4))) != nil
            if stage || (portable && !owned.contains("Media/" + name)) { try? FileManager.default.removeItem(at: file) }
        }
    }

    @discardableResult private func persist(_ proposedRecords: [DownloadRecord]? = nil) -> Bool {
        guard stateReadable else { return false }
        do {
            let archive = DownloadArchive(records: proposedRecords ?? records, authenticated: authenticated, expectations: expectations, attempts: tokens, foregroundHLS: foregroundOnlyHLS)
            try JSONEncoder().encode(archive).write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            storageError = nil; return true
        } catch { storageError = "下载状态未能写入本机，请检查存储空间。"; return false }
    }
    private func index(_ id: UUID) -> Int? { records.firstIndex { $0.id == id } }
    private func mutate(_ id: UUID, _ change: (inout DownloadRecord) -> Void) {
        guard let index = index(id) else { return }; change(&records[index]); persist()
    }
    /// Publish completion and file replacements only after the index is durable.
    @discardableResult private func commit(_ id: UUID, _ change: (inout DownloadRecord) -> Void) -> Bool {
        guard let index = index(id) else { return false }
        var updated = records
        change(&updated[index])
        guard persist(updated) else { return false }
        records = updated
        return true
    }

    func inspect(candidate: MediaCandidate, cookies: [HTTPCookie]) async -> MediaInspection {
        do { return try await inspectValidated(candidate: candidate, cookies: cookies) }
        catch {
            var webSessionRetryAllowed = false
            if candidate.kind == .file, case DownloadIssue.http(let status) = error, [401, 403].contains(status) {
                webSessionRetryAllowed = true
            }
            return MediaInspection(summary: safeMessage(error), variants: [], audioTracks: [], expectedBytes: nil,
                downloadable: false, webSessionRetryAllowed: webSessionRetryAllowed)
        }
    }
    private func inspectValidated(candidate: MediaCandidate, cookies: [HTTPCookie]) async throws -> MediaInspection {
        guard MediaCookiePolicy.validHTTPURL(candidate.url) else { throw DownloadIssue.invalidURL }
        switch candidate.kind {
        case .protected: throw DownloadIssue.protectedContent
        case .blob: throw DownloadIssue.unsupported("这是播放器的临时地址。请继续播放，等待识别实际媒体清单。")
        case .dash: throw DownloadIssue.unsupported("已识别 DASH 音视频分离清单，当前版本尚不能离线封装。仍可浏览和收藏网页。")
        case .file, .hls: break
        }
        let client = MediaHTTPClient(candidate: candidate, cookies: cookies)
        defer { client.close() }
        if candidate.kind == .hls {
            var inspection = try await HLSPreflight.inspect(candidate.url, load: client.playlist)
            // Cookie-authenticated HLS needs additional device acceptance for segment and key scopes.
            if !client.cookies.isEmpty { throw DownloadIssue.unsupported("此 HLS 视频需要登录凭据；当前版本尚未验证其安全离线流程。仍可在网页播放和收藏。") }
            inspection.requiresForeground = candidate.requestContext != nil || preferPortableHLS
            return inspection
        }
        let length = try await client.fileMetadata(candidate.url)
        let isAuthenticated = !client.cookies.isEmpty
        return MediaInspection(summary: isAuthenticated ? "视频文件 · 登录下载需保持 App 在前台 · 音轨在下载后校验" : "视频文件 · 支持后台下载 · 音轨在下载后校验",
                               variants: [], audioTracks: [], expectedBytes: length, downloadable: true)
    }

    @discardableResult func start(candidate: MediaCandidate, cookies: [HTTPCookie]) async -> UUID {
        let id = UUID()
        records.insert(DownloadRecord(id: id, candidate: candidate, phase: .queued, progress: 0, bytesWritten: 0,
            expectedBytes: nil, localRelativePath: nil, failure: nil, duration: nil, hasAudio: nil, createdAt: Date()), at: 0)
        guard persist() else { mutate(id) { $0.phase = .failed; $0.failure = "无法保存下载状态，请检查存储空间。" }; return id }
        await begin(id: id, cookies: cookies)
        return id
    }

    func isBrowserDownload(id: UUID) -> Bool { browserTasks[id] != nil }

    /// Upgrade an existing system package without removing the playable copy.
    /// Only the verified portable result replaces the record and enters sync.
    func prepareCloudCopy(id: UUID, retry: Bool = false) {
        guard cloudPreparationTasks[id] == nil, retry || cloudPreparationStatus[id] == nil,
              let record = records.first(where: { $0.id == id }), record.phase == .complete,
              record.candidate.kind == .hls, let original = localURL(for: record),
              original.pathExtension.lowercased() == "movpkg", !appInBackground else { return }
        let token = UUID()
        cloudPreparationTokens[id] = token
        cloudPreparationStatus[id] = "正在准备可同步的视频…"
        let relative = "Media/portable-\(token.uuidString).mp4"
        let destination = rootDirectory.appendingPathComponent(relative)
        cloudPreparationTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.cloudPreparationTokens[id] == token {
                    self.cloudPreparationTasks.removeValue(forKey: id)
                    self.cloudPreparationTokens.removeValue(forKey: id)
                }
            }
            do {
                let info = try await self.inspectValidated(candidate: record.candidate, cookies: [])
                let result = try await HLSFileExporter.export(candidate: record.candidate, cookies: [],
                    inspection: info, destination: destination) { [weak self] progress in
                        guard let self, self.cloudPreparationTokens[id] == token else { return }
                        self.cloudPreparationStatus[id] = progress.stage == .transferring
                            ? "正在准备同步 · " + ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file)
                            : "正在检查可同步的视频…"
                    }
                guard !Task.isCancelled, self.cloudPreparationTokens[id] == token,
                      let current = self.records.first(where: { $0.id == id }), current.phase == .complete,
                      current.localRelativePath == record.localRelativePath else {
                    try? FileManager.default.removeItem(at: destination)
                    if self.cloudPreparationTokens[id] == token {
                        self.cloudPreparationStatus[id] = "准备同步已暂停，原视频仍可离线播放"
                    }
                    return
                }
                let saved = self.commit(id) {
                    $0.localRelativePath = relative; $0.bytesWritten = result.bytes; $0.expectedBytes = result.bytes
                    $0.duration = result.duration; $0.hasAudio = result.hasAudio
                }
                if saved {
                    self.thumbnailStore.remove(id: id)
                    self.hlsLocations.removeValue(forKey: id)
                    try? FileManager.default.removeItem(at: original)
                    self.cloudPreparationStatus.removeValue(forKey: id)
                } else {
                    // The old index and playable package remain authoritative.
                    try? FileManager.default.removeItem(at: destination)
                    self.cloudPreparationStatus[id] = "无法保存同步状态，请检查本机存储空间"
                }
            } catch {
                guard self.cloudPreparationTokens[id] == token else { return }
                self.cloudPreparationStatus[id] = error is CancellationError
                    ? "准备同步已暂停，原视频仍可离线播放"
                    : "暂未生成可同步文件，原视频仍可离线播放；可回原网页重新下载"
            }
        }
    }

    /// The native confirmation sheet is the caller. Page script messages never call this.
    func startUsingBrowser(candidate: MediaCandidate, webView: WKWebView) {
        guard candidate.kind == .file, webView.url == candidate.pageURL,
              MediaMessageValidator.networkURL(candidate.url.absoluteString) != nil else { return }
        let id = UUID(), attempt = UUID().uuidString
        let token = id.uuidString + "|" + attempt
        records.insert(DownloadRecord(id: id, candidate: candidate, phase: .queued, progress: 0,
            bytesWritten: 0, expectedBytes: nil, localRelativePath: nil, failure: nil,
            duration: nil, hasAudio: nil, createdAt: Date()), at: 0)
        guard persist() else {
            fail(id, error: DownloadIssue.unsupported("无法保存下载状态，请检查存储空间。")); return
        }
        touchedIDs.insert(id)
        tokens[id] = token
        diagnostics.start(token: token, kind: candidate.kind, stage: .transfer)
        // Browser transfers cannot be restored without the originating page session.
        authenticated.insert(id)
        let stage = rootDirectory.appendingPathComponent("Staging/" + UUID().uuidString)
        let transfer = BrowserFileDownload(destination: stage, onProgress: { [weak self] written, expected in
            self?.progress(token: token, written: written, expected: expected)
        }, onCompletion: { [weak self] file, response, error in
            Task { @MainActor in
                guard let self else {
                    if let file { try? FileManager.default.removeItem(at: file) }; return
                }
                self.browserTasks.removeValue(forKey: id)
                await self.fileFinished(token: token, temporaryURL: file, response: response, error: error)
            }
        })
        browserTasks[id] = transfer
        mutate(id) { $0.phase = .downloading }
        guard storageError == nil else { cancel(id: id); return }
        transfer.start(candidate: candidate, webView: webView)
    }
    private func begin(id: UUID, cookies: [HTTPCookie], allowPortable: Bool = true) async {
        guard let record = records.first(where: { $0.id == id }), record.phase == .queued else { return }
        if appInBackground, requiresForeground(record) { pauseForegroundHLS(id: id); return }
        touchedIDs.insert(id)
        let attempt = id.uuidString + "|" + UUID().uuidString
        tokens[id] = attempt
        diagnostics.start(token: attempt, kind: record.candidate.kind)
        // Preserve the already-authorized context even if the user pauses during preflight.
        let scopedCookies = record.candidate.requestContext?.allowsCookies(for: record.candidate.url, frameURL: record.candidate.frameURL) == false
            ? [] : MediaCookiePolicy.matching(cookies, for: record.candidate.url)
        contexts[id] = scopedCookies
        if scopedCookies.isEmpty { authenticated.remove(id) } else { authenticated.insert(id) }
        let inspection = Task { try await self.inspectValidated(candidate: record.candidate, cookies: cookies) }
        preflightTokens[id] = attempt
        preflightTasks[id] = inspection
        defer {
            if preflightTokens[id] == attempt {
                preflightTokens.removeValue(forKey: id)
                preflightTasks.removeValue(forKey: id)
            }
            activityDidChange()
        }
        do {
            let info = try await withTaskCancellationHandler { try await inspection.value } onCancel: { inspection.cancel() }
            guard tokens[id] == attempt, let current = records.first(where: { $0.id == id }), current.phase == .queued else { return }
            if appInBackground, requiresForeground(current) { pauseForegroundHLS(id: id); return }
            mutate(id) { $0.expectedBytes = info.expectedBytes }
            expectations[id] = ValidationExpectation(duration: info.expectedDuration, requiresAudio: record.candidate.kind == .hls && !info.audioTracks.isEmpty)
            diagnostics.update(token: attempt, expectedDuration: info.expectedDuration)
            let selected = record.candidate.requestContext?.allowsCookies(for: record.candidate.url, frameURL: record.candidate.frameURL) == false
                ? [] : MediaCookiePolicy.matching(cookies, for: record.candidate.url)
            contexts[id] = selected
            if selected.isEmpty { authenticated.remove(id) } else { authenticated.insert(id) }
            if preferPortableHLS, allowPortable, record.candidate.kind == .hls {
                if foregroundOnlyHLS.contains(id) {
                    startPortableHLS(id: id, candidate: record.candidate, cookies: selected, inspection: info, attempt: attempt)
                } else {
                    try await startBackgroundHLS(id: id, candidate: record.candidate, inspection: info, attempt: attempt)
                }
                return
            }
            let task: URLSessionTask
            if record.candidate.kind == .hls {
                var options: [String: Any] = [:]
                if let userAgent = MediaCookiePolicy.validUserAgent(record.candidate.userAgent) {
                    options[AVURLAssetHTTPUserAgentKey] = userAgent
                }
                var source = info.hlsDownloadURL ?? record.candidate.url
                if record.candidate.requestContext != nil {
                    let relay = HLSDownloadRelay(candidate: record.candidate, cookies: selected)
                    relay.onBytesTransferred = { [weak self] written in
                        self?.progress(token: attempt, written: written, expected: 0)
                    }
                    hlsRelays[id] = relay
                    source = try await relay.start(sourceURL: source)
                    guard tokens[id] == attempt, records.first(where: { $0.id == id })?.phase == .queued else {
                        relay.stop(); return
                    }
                    if appInBackground { pauseForegroundHLS(id: id); return }
                }
                let asset = AVURLAsset(url: source, options: options)
                guard let assetTask = hlsSession.makeAssetDownloadTask(asset: asset, assetTitle: record.candidate.title,
                    assetArtworkData: nil, options: nil) else { throw DownloadIssue.unsupported("系统无法创建此视频的离线任务。") }
                task = assetTask
            } else {
                let request = MediaCookiePolicy.request(url: record.candidate.url, cookies: selected,
                    pageURL: record.candidate.frameURL, userAgent: record.candidate.userAgent, context: record.candidate.requestContext)
                task = (selected.isEmpty ? backgroundSession : foregroundSession).downloadTask(with: request)
            }
            activate(task, id: id, cookies: selected)
        } catch { if tokens[id] == attempt { fail(id, error: error) } }
    }
    private func startBackgroundHLS(id: UUID, candidate: MediaCandidate, inspection: MediaInspection, attempt: String) async throws {
        do {
            let plan = try await HLSFileExporter.prepare(candidate: candidate, inspection: inspection)
            guard tokens[id] == attempt, !Task.isCancelled, !appInBackground,
                  records.first(where: { $0.id == id })?.phase == .queued else { return }
            guard commit(id, { $0.phase = .downloading; $0.failure = nil }) else { throw DownloadIssue.invalidMedia }
            try backgroundHLS.create(id: id, attempt: attempt, plan: plan, userAgent: candidate.userAgent)
        } catch HLSFileExportError.unsupported {
            // TS and other system-supported HLS retain their existing path.
            mutate(id) { $0.phase = .queued }
            await begin(id: id, cookies: [], allowPortable: false)
        }
    }
    private func backgroundHLSChanged(_ job: BackgroundHLSStore.Job) {
        guard tokens[job.id] == job.attempt, let record = records.first(where: { $0.id == job.id }),
              [.downloading, .validating].contains(record.phase), !job.paused else { return }
        let update = backgroundHLS.progress(id: job.id)
        progress(token: job.attempt, written: update.0, expected: 0, fraction: update.1)
        if job.ready {
            mutate(job.id) { $0.phase = .validating }
            guard !appInBackground, portableTasks[job.id] == nil else { return }
            let expected = expectations[job.id]
            let inspection = MediaInspection(summary: "", variants: [], audioTracks: job.plan.requiresAudio ? ["audio"] : [],
                expectedBytes: nil, downloadable: true, expectedDuration: expected?.duration)
            startPortableHLS(id: job.id, candidate: record.candidate, cookies: [], inspection: inspection, attempt: job.attempt, job: job)
        }
        activityDidChange()
    }
    private func backgroundHLSFailed(id: UUID, attempt: String, error: Error) {
        guard tokens[id] == attempt else { return }
        backgroundHLS.cancel(id: id)
        // Retry an authorized page-context request only in the foreground. No
        // context is attached to automatically redirected background requests.
        if case DownloadIssue.http(let code) = error, [401, 403].contains(code) {
            foregroundOnlyHLS.insert(id)
            mutate(id) { $0.phase = .paused; $0.failure = "此站点需要网页会话，请在前台继续下载。" }
            if !appInBackground { resume(id: id) }
        } else { fail(id, error: error) }
    }
    func transferNeedsForeground(id: UUID) -> Bool {
        guard let record = records.first(where: { $0.id == id }) else { return false }
        return browserTasks[id] != nil || requiresForeground(record)
    }
    func backgroundTransferStatus(id: UUID) -> String? {
        guard let job = backgroundHLS?.jobs[id], job.ready, appInBackground else { return nil }
        return "分片已下载，返回 App 后整理"
    }

    private func startPortableHLS(id: UUID, candidate: MediaCandidate, cookies: [HTTPCookie], inspection: MediaInspection, attempt: String, job: BackgroundHLSStore.Job? = nil) {
        let assembly = UUID(); assemblyGenerations[id] = assembly
        let relative = "Media/portable-\(UUID().uuidString).mp4"
        let destination = rootDirectory.appendingPathComponent(relative)
        guard commit(id, { $0.phase = job == nil ? .downloading : .validating; $0.failure = nil }) else {
            fail(id, error: DownloadIssue.unsupported("无法保存下载状态，请检查存储空间。"))
            return
        }
        diagnostics.update(token: attempt, stage: .transfer)
        portableTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let cached: [HLSFilePlaylist.Resource: URL]
                if job != nil { cached = try await self.backgroundHLS.resources(id: id) } else { cached = [:] }
                try Task.checkCancellation()
                let result = try await HLSFileExporter.export(candidate: candidate, cookies: cookies,
                    inspection: inspection, destination: destination, plan: job?.plan, cachedResources: cached) { [weak self] update in
                        guard let self, self.tokens[id] == attempt, self.assemblyGenerations[id] == assembly else { return }
                        self.progress(token: attempt, written: update.bytes, expected: 0, fraction: update.fraction)
                        if update.stage != .transferring { self.mutate(id) { $0.phase = .validating } }
                    }
                guard self.tokens[id] == attempt, self.assemblyGenerations[id] == assembly, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: destination); return
                }
                self.portableTasks.removeValue(forKey: id)
                guard self.commit(id, { $0.phase = .validating; $0.localRelativePath = relative; $0.bytesWritten = result.bytes }) else {
                    try? FileManager.default.removeItem(at: destination)
                    self.fail(id, error: DownloadIssue.unsupported("无法保存下载状态，请检查存储空间。"))
                    return
                }
                await self.validate(id: id, url: result.url, isHLS: false)
                if self.backgroundHLS.jobs[id]?.attempt == attempt { self.backgroundHLS.cancel(id: id) }
                if self.assemblyGenerations[id] == assembly { self.assemblyGenerations.removeValue(forKey: id) }
            } catch {
                guard self.tokens[id] == attempt, self.assemblyGenerations[id] == assembly else { return }
                self.backgroundHLS.cancel(id: id)
                self.portableTasks.removeValue(forKey: id)
                if case HLSFileExportError.unsupported = error, !Task.isCancelled {
                    self.mutate(id) { $0.phase = .queued; $0.progress = 0; $0.bytesWritten = 0 }
                    await self.begin(id: id, cookies: cookies, allowPortable: false)
                } else { self.fail(id, error: error) }
            }
        }
    }
    private func activate(_ task: URLSessionTask, id: UUID, cookies: [HTTPCookie]) {
        let token = tokens[id] ?? (id.uuidString + "|" + UUID().uuidString)
        task.taskDescription = token; tokens[id] = token; tasks[id] = task
        if let record = records.first(where: { $0.id == id }) {
            diagnostics.start(token: token, kind: record.candidate.kind, stage: .transfer)
            diagnostics.update(token: token, stage: .transfer)
            delegateProxy.register(token: token, cookies: cookies, pageURL: record.candidate.frameURL, userAgent: record.candidate.userAgent, requestContext: record.candidate.requestContext)
        }
        mutate(id) { $0.phase = .downloading; $0.failure = nil }
        guard storageError == nil else {
            task.cancel(); tasks.removeValue(forKey: id); tokens.removeValue(forKey: id)
            hlsRelays.removeValue(forKey: id)?.stop()
            if let index = index(id) { records[index].phase = .failed; records[index].failure = "无法保存下载状态，请检查存储空间。" }
            return
        }
        task.resume()
    }
    /// Only paused network transfers with their original authorization can resume.
    func canResume(id: UUID) -> Bool {
        guard !pendingResumeIDs.contains(id), launchingResumeTokens[id] == nil,
              let record = records.first(where: { $0.id == id }) else { return false }
        return resumable(record)
    }

    /// Explain unavailable continuation without changing state or refreshing credentials.
    func resumeBlockReason(id: UUID) -> String? {
        guard !pendingResumeIDs.contains(id), launchingResumeTokens[id] == nil,
              let record = records.first(where: { $0.id == id }), record.phase == .paused else { return nil }
        if authenticated.contains(id), MediaCookiePolicy.matching(contexts[id] ?? [], for: record.candidate.url).isEmpty {
            return "登录状态已失效，请回到网页重新登录后重试。"
        }
        if !stateReadable { return "本机下载状态暂时无法读取，请重新打开 App 后再试。" }
        if ["localImport", "iCloud"].contains(record.candidate.source)
            || ![MediaKind.file, .hls].contains(record.candidate.kind)
            || !MediaCookiePolicy.validHTTPURL(record.candidate.url) {
            return "此记录无法继续下载，请重新选择视频来源。"
        }
        if appInBackground && requiresForeground(record) { return "此视频需在前台下载，请返回 App 后继续。" }
        return nil
    }

    private func resumable(_ record: DownloadRecord) -> Bool {
        guard stateReadable, record.phase == .paused,
              !["localImport", "iCloud"].contains(record.candidate.source),
              [.file, .hls].contains(record.candidate.kind),
              MediaCookiePolicy.validHTTPURL(record.candidate.url),
              !(appInBackground && requiresForeground(record)) else { return false }
        return !authenticated.contains(record.id)
            || !MediaCookiePolicy.matching(contexts[record.id] ?? [], for: record.candidate.url).isEmpty
    }

    func canPause(id: UUID) -> Bool {
        if pendingResumeIDs.contains(id) || launchingResumeTokens[id] != nil { return true }
        guard let record = records.first(where: { $0.id == id }), browserTasks[id] == nil else { return false }
        if record.phase == .queued { return preflightTasks[id] != nil || tasks[id] != nil }
        if record.phase == .downloading { return tasks[id] != nil || portableTasks[id] != nil || backgroundHLS?.jobs[id] != nil }
        return record.phase == .validating && (portableTasks[id] != nil || backgroundHLS?.jobs[id] != nil)
    }

    func resumeDownloads(ids: Set<UUID>) {
        for record in records where ids.contains(record.id) && canResume(id: record.id) {
            touchedIDs.insert(record.id)
            pendingResumeIDs.insert(record.id)
            resumeQueue.append(record.id)
        }
        activityDidChange()
    }

    func resumeAllDownloads() { resumeDownloads(ids: Set(records.map(\.id))) }
    func resume(id: UUID) {
        guard let record = records.first(where: { $0.id == id }), record.phase == .paused else { return }
        if appInBackground && requiresForeground(record) { return }
        if authenticated.contains(id), MediaCookiePolicy.matching(contexts[id] ?? [], for: record.candidate.url).isEmpty {
            // A direct continuation retains the original reauthorization path:
            // fail this attempt so a fresh webpage selection can supply new cookies.
            // Bulk continuation deliberately skips this case without changing it.
            touchedIDs.insert(id)
            removePendingResume(id)
            launchingResumeTokens.removeValue(forKey: id)
            tokens.removeValue(forKey: id)
            tasks.removeValue(forKey: id)?.cancel()
            pendingPause.remove(id)
            try? FileManager.default.removeItem(at: resumeURL(id))
            mutate(id) { $0.phase = .failed; $0.failure = "登录状态已失效，请回到网页重新登录后重试。" }
            return
        }
        resumeDownloads(ids: [id])
    }

    func pauseDownloads(ids: Set<UUID>) {
        // Clear all selected intentions before releasing any slots.
        for id in ids { removePendingResume(id) }
        for id in ids { pause(id: id) }
    }

    private func removePendingResume(_ id: UUID) {
        pendingResumeIDs.remove(id)
        resumeQueue.removeAll { $0 == id }
    }

    func pause(id: UUID) {
        removePendingResume(id)
        if launchingResumeTokens[id] != nil { launchingResumeTokens.removeValue(forKey: id) }
        guard let record = records.first(where: { $0.id == id }) else { return }
        if record.phase == .queued {
            touchedIDs.insert(id)
            preflightTokens.removeValue(forKey: id)
            preflightTasks.removeValue(forKey: id)?.cancel()
            tokens.removeValue(forKey: id)
            tasks.removeValue(forKey: id)?.cancel()
            hlsRelays.removeValue(forKey: id)?.stop()
            mutate(id) { $0.phase = .paused; $0.failure = nil }
            return
        }
        if backgroundHLS?.jobs[id] != nil {
            do {
                try backgroundHLS.pause(id: id)
                assemblyGenerations.removeValue(forKey: id)
                portableTasks.removeValue(forKey: id)?.cancel()
                mutate(id) { $0.phase = .paused; $0.failure = nil }
            } catch { fail(id, error: error) }
            return
        }
        if portableTasks[id] != nil { pauseForegroundHLS(id: id); return }
        guard let task = tasks[id], record.phase == .downloading else { activityDidChange(); return }
        if requiresForeground(record) { pauseForegroundHLS(id: id); return }
        touchedIDs.insert(id)
        let pauseToken = task.taskDescription
        mutate(id) { $0.phase = .paused }
        if let download = task as? URLSessionDownloadTask {
            pendingPause.insert(id)
            download.cancel { [weak self] data in
                Task { @MainActor in
                    guard let self, self.tokens[id] == pauseToken else { return }
                    if let record = self.records.first(where: { $0.id == id }), record.phase == .paused {
                        if let data { try? data.write(to: self.resumeURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                        self.tasks.removeValue(forKey: id)
                    }
                    self.pendingPause.remove(id)
                }
            }
        } else { task.suspend() }
        activityDidChange()
    }

    private func resumeImmediately(id: UUID) {
        guard let record = records.first(where: { $0.id == id }), resumable(record), !pendingPause.contains(id) else { return }
        touchedIDs.insert(id)
        if backgroundHLS?.jobs[id] != nil {
            mutate(id) { $0.phase = .downloading; $0.failure = nil }
            do { try backgroundHLS.resume(id: id) } catch { fail(id, error: error) }
            return
        }
        if let task = tasks[id], task.state == .suspended,
           task is AVAssetDownloadTask || task is URLSessionDownloadTask {
            // Restored ordinary background tasks are suspended too. Reuse their
            // transfer instead of leaving one suspended while creating a duplicate.
            mutate(id) { $0.phase = .downloading }; task.resume(); return
        }
        // A cancelling/completed task cannot be resumed and must not remain orphaned.
        tasks.removeValue(forKey: id)?.cancel()
        if let data = try? Data(contentsOf: resumeURL(id)) {
            let task = (authenticated.contains(id) ? foregroundSession : backgroundSession).downloadTask(withResumeData: data)
            tokens.removeValue(forKey: id)
            activate(task, id: id, cookies: contexts[id] ?? [])
        } else {
            mutate(id) { $0.phase = .queued; $0.progress = 0; $0.bytesWritten = 0 }
            let launch = UUID()
            launchingResumeTokens[id] = launch
            Task { [weak self] in
                guard let self, self.launchingResumeTokens[id] == launch else { return }
                // A cancelled attempt's deferred cleanup must not clear a newer resume.
                defer {
                    if self.launchingResumeTokens[id] == launch { self.launchingResumeTokens.removeValue(forKey: id) }
                }
                await self.begin(id: id, cookies: self.contexts[id] ?? [])
            }
        }
    }

    /// A started download's preflight, transfer, export, or validation keeps the
    /// foreground awake. Confirmation-only inspection, waiting, paused tasks,
    /// imports, and terminal records do not.
    private var activeDownloadIDs: Set<UUID> {
        Set(records.compactMap { record in
            let id = record.id
            if record.phase == .queued {
                if let token = preflightTokens[id], token == tokens[id], preflightTasks[id] != nil { return id }
                if tasks[id] != nil { return id } // A restored system task may still carry its queued record.
            }
            if record.phase == .downloading, tasks[id] != nil || browserTasks[id] != nil || portableTasks[id] != nil || backgroundHLS?.jobs[id] != nil { return id }
            if record.phase == .validating,
               portableTasks[id] != nil || tokens[id].map({ validations.contains($0) }) == true { return id }
            return nil
        })
    }

    private func activityDidChange() {
        let active = !activeDownloadIDs.isEmpty || !cloudPreparationTasks.isEmpty
        if hasActiveDownloads != active { hasActiveDownloads = active }
        guard !pendingResumeIDs.isEmpty, !resumeDrainScheduled else { return }
        resumeDrainScheduled = true
        Task { [weak self] in
            guard let self else { return }
            self.drainResumeQueue()
            self.resumeDrainScheduled = false
        }
    }

    private func drainResumeQueue() {
        guard !restoringTasks else { return }
        var occupied = activeDownloadIDs.union(launchingResumeTokens.keys).union(pendingPause)
        for id in resumeQueue {
            guard let record = records.first(where: { $0.id == id }), resumable(record) else {
                removePendingResume(id); continue
            }
            guard occupied.count < Self.maximumResumedDownloads else { break }
            guard !pendingPause.contains(id) else { continue }
            removePendingResume(id)
            resumeImmediately(id: id)
            if activeDownloadIDs.contains(id) || launchingResumeTokens[id] != nil { occupied.insert(id) }
        }
    }
    func retry(id: UUID, cookies: [HTTPCookie]) async {
        guard let record = records.first(where: { $0.id == id }), [.failed, .cancelled].contains(record.phase) else { return }
        // A cache eviction preserves the cloud identity; its expired source URL
        // must not start a second network download through the Retry action.
        guard record.localCacheEvicted != true else { return }
        if pendingCompletionWrites.contains(id), record.phase == .failed, let local = localURL(for: record) {
            // A completed transfer whose final index write failed can be
            // admitted again without discarding or downloading the file twice.
            guard commit(id, { $0.phase = .validating; $0.failure = nil }) else { return }
            pendingCompletionWrites.remove(id)
            await validate(id: id, url: local, isHLS: local.pathExtension.lowercased() == "movpkg")
            return
        }
        guard record.candidate.source != "localImport" else {
            mutate(id) { $0.failure = "请重新选择本机视频进行导入。" }; return
        }
        thumbnailStore.remove(id: id)
        try? FileManager.default.removeItem(at: resumeURL(id))
        mutate(id) { $0.phase = .queued; $0.progress = 0; $0.bytesWritten = 0; $0.failure = nil }
        await begin(id: id, cookies: cookies)
    }
    func cancel(id: UUID) {
        backgroundHLS?.cancel(id: id)
        assemblyGenerations.removeValue(forKey: id)
        removePendingResume(id)
        launchingResumeTokens.removeValue(forKey: id)
        preflightTokens.removeValue(forKey: id)
        preflightTasks.removeValue(forKey: id)?.cancel()
        pendingCompletionWrites.remove(id)
        cloudPreparationTokens.removeValue(forKey: id)
        cloudPreparationTasks.removeValue(forKey: id)?.cancel()
        cloudPreparationStatus.removeValue(forKey: id)
        thumbnailStore.remove(id: id)
        if let record = records.first(where: { $0.id == id }), record.phase != .complete,
           let ownedFile = localURL(for: record) {
            try? FileManager.default.removeItem(at: ownedFile)
        }
        touchedIDs.insert(id)
        tokens.removeValue(forKey: id); tasks.removeValue(forKey: id)?.cancel()
        browserTasks.removeValue(forKey: id)?.cancel()
        portableTasks.removeValue(forKey: id)?.cancel()
        hlsRelays.removeValue(forKey: id)?.stop()
        pendingPause.remove(id); contexts.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: resumeURL(id))
        if let location = hlsLocations.removeValue(forKey: id) { try? FileManager.default.removeItem(at: location) }
        mutate(id) {
            if $0.phase != .complete { $0.localRelativePath = nil }
            $0.phase = .cancelled; $0.failure = "下载已取消，可重试。"
        }
    }
    /// Loopback media delivery needs this process. Do not leave a background task
    /// talking to a suspended listener or mistake its partial package for a video.
    func setAppInBackground(_ value: Bool) {
        appInBackground = value
        if value {
            for id in Array(portableTasks.keys) where backgroundHLS?.jobs[id] != nil {
                assemblyGenerations.removeValue(forKey: id)
                portableTasks.removeValue(forKey: id)?.cancel()
                mutate(id) { $0.phase = .validating }
            }
            pauseForegroundHLSDownloads()
            for task in cloudPreparationTasks.values { task.cancel() }
        } else {
            backgroundHLS?.resumeScheduling()
            for job in backgroundHLS?.jobs.values.map({ $0 }) ?? [] where job.ready { backgroundHLSChanged(job) }
        }
        activityDidChange()
    }

    func pauseForegroundHLSDownloads() {
        // Include queued inspections: they do not own a relay yet, but their
        // asynchronous result must not start one after the app has left foreground.
        for id in records.filter({ requiresForeground($0) && ([.queued, .downloading, .paused].contains($0.phase) || portableTasks[$0.id] != nil) }).map(\.id) {
            pauseForegroundHLS(id: id)
        }
    }

    private func requiresForeground(_ record: DownloadRecord) -> Bool {
        if tasks[record.id] is AVAssetDownloadTask, hlsRelays[record.id] == nil { return false }
        return record.candidate.kind == .hls && backgroundHLS?.jobs[record.id] == nil && (record.candidate.requestContext != nil || preferPortableHLS)
    }

    private func pauseForegroundHLS(id: UUID) {
        guard let record = records.first(where: { $0.id == id }), requiresForeground(record),
              [.queued, .downloading, .paused].contains(record.phase) || portableTasks[id] != nil else { return }
        touchedIDs.insert(id)
        removePendingResume(id)
        launchingResumeTokens.removeValue(forKey: id)
        preflightTokens.removeValue(forKey: id)
        preflightTasks.removeValue(forKey: id)?.cancel()
        tokens.removeValue(forKey: id)
        tasks.removeValue(forKey: id)?.cancel()
        portableTasks.removeValue(forKey: id)?.cancel()
        hlsRelays.removeValue(forKey: id)?.stop()
        pendingPause.remove(id)
        if let location = hlsLocations.removeValue(forKey: id) { try? FileManager.default.removeItem(at: location) }
        if let location = localURL(for: record) { try? FileManager.default.removeItem(at: location) }
        try? FileManager.default.removeItem(at: resumeURL(id))
        mutate(id) {
            $0.phase = .paused; $0.localRelativePath = nil; $0.progress = 0; $0.bytesWritten = 0
            $0.failure = "此视频需在前台下载。返回 App 后点继续，将重新下载。"
        }
    }
    func removeCache(id: UUID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        if let url = localURL(for: record) { try? FileManager.default.removeItem(at: url) }
        cancel(id: id)
        mutate(id) { $0.localRelativePath = nil; $0.progress = 0; $0.bytesWritten = 0; $0.failure = "本机缓存已删除，视频记录仍保留。" }
    }
    func removeRecord(id: UUID) {
        removeCache(id: id); records.removeAll { $0.id == id }; authenticated.remove(id); expectations.removeValue(forKey: id); persist()
    }

    func beginUsingLocalVideo(id: UUID) -> UUID {
        let token = UUID()
        localVideoUseLeases[token] = id
        localVideoUseIDs.insert(id)
        return token
    }

    func endUsingLocalVideo(_ token: UUID) {
        guard let id = localVideoUseLeases.removeValue(forKey: token) else { return }
        if !localVideoUseLeases.values.contains(id) { localVideoUseIDs.remove(id) }
    }

    func isLocalVideoInUse(id: UUID) -> Bool { localVideoUseIDs.contains(id) }

    /// Only completed, validated, app-owned plain files qualify. System-managed
    /// HLS packages and records participating in any unfinished operation stay.
    func canEvictLocalCache(_ record: DownloadRecord) -> Bool {
        let id = record.id
        guard stateReadable, !cacheRecoveryRequired,
              records.first(where: { $0.id == id }) == record,
              !records.contains(where: { $0.id != id && $0.localRelativePath == record.localRelativePath }),
              record.phase == .complete, record.localCacheEvicted != true,
              let duration = record.duration, duration.isFinite, duration > 0,
              record.hasAudio != nil, !localVideoUseIDs.contains(id),
              tasks[id] == nil, browserTasks[id] == nil, portableTasks[id] == nil,
              cloudPreparationTasks[id] == nil, cloudPreparationTokens[id] == nil,
              preflightTasks[id] == nil, preflightTokens[id] == nil,
              launchingResumeTokens[id] == nil, !pendingResumeIDs.contains(id),
              !pendingPause.contains(id), !pendingCompletionWrites.contains(id),
              !validations.contains(where: { Self.recordID($0) == id }),
              cacheFileIdentity(for: record) != nil else { return false }
        return true
    }

    /// This is deliberately O(1): no media hashing, decoding or directory walk.
    func cacheFileIdentity(for record: DownloadRecord) -> VideoCacheFileIdentity? {
        guard let name = cacheFileName(for: record) else { return nil }
        return try? withCacheMediaDirectory { root, media, rootInfo, mediaInfo in
            try cacheFileIdentity(name: name, root: root, media: media, rootInfo: rootInfo, mediaInfo: mediaInfo)
        }
    }

    /// The caller must already have verified a recoverable cloud copy. The
    /// expected identity binds that verification to the exact local bytes.
    @discardableResult
    func evictLocalCache(record: DownloadRecord, expectedIdentity: VideoCacheFileIdentity) throws -> Bool {
        guard canEvictLocalCache(record), let name = cacheFileName(for: record),
              cacheFileIdentity(for: record) == expectedIdentity,
              let position = index(record.id) else { return false }
        return try withCacheMediaDirectory { root, media, rootInfo, mediaInfo in
            guard try cacheFileIdentity(name: name, root: root, media: media, rootInfo: rootInfo, mediaInfo: mediaInfo) == expectedIdentity else { return false }
            let original = records
            var updated = original
            updated[position].phase = .cancelled
            updated[position].localRelativePath = nil
            updated[position].localCacheEvicted = true
            updated[position].failure = nil
            let journal = CacheEvictionJournal(original: record, evicted: updated[position], identity: expectedIdentity)
            // Keep a protected recovery record across a crash between the state
            // write and unlink. It contains no additional exported credentials.
            do {
                try JSONEncoder().encode(journal).write(to: cacheEvictionJournalURL,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try persistCacheState(updated)
            } catch {
                // No file operation has occurred. A retained journal is harmless
                // and is reconciled against the unchanged archive on launch.
                cacheRecoveryRequired = true
                storageError = "无法保存缓存清理状态，本机视频已保留。"
                throw VideoCacheEvictionError.stateWriteFailed
            }
            do {
                try cacheEvictionHooks.beforeFileRemoval?()
                // Recheck after the durable write while holding the same parent
                // directory descriptors, then unlink that exact directory entry.
                guard try cacheFileIdentity(name: name, root: root, media: media,
                    rootInfo: rootInfo, mediaInfo: mediaInfo) == expectedIdentity else {
                    throw VideoCacheEvictionError.fileRemovalFailed
                }
                thumbnailStore.prepareForCacheEviction(id: record.id)
                guard unlinkat(media, name, 0) == 0 else {
                    throw VideoCacheEvictionError.fileRemovalFailed
                }
            } catch {
                do {
                    try persistCacheState(original)
                    try? FileManager.default.removeItem(at: cacheEvictionJournalURL)
                    storageError = "缓存清理未完成，本机视频已保留。"
                } catch {
                    cacheRecoveryRequired = true
                    storageError = "本机视频已保留，但清理状态尚未恢复。请重新打开 App 后重试。"
                }
                // Do not publish the evicted record when its file was retained.
                throw VideoCacheEvictionError.fileRemovalFailed
            }
            records = updated
            storageError = nil
            try? FileManager.default.removeItem(at: cacheEvictionJournalURL)
            return true
        }
    }

    private func persistCacheState(_ proposed: [DownloadRecord]) throws {
        try cacheEvictionHooks.beforeStateWrite?()
        let archive = DownloadArchive(records: proposed, authenticated: authenticated,
            expectations: expectations, attempts: tokens, foregroundHLS: foregroundOnlyHLS)
        try JSONEncoder().encode(archive).write(to: stateURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // Complete the file write before reclaiming the media it describes.
        let handle = try FileHandle(forReadingFrom: stateURL)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func recoverInterruptedCacheEviction() throws {
        guard FileManager.default.fileExists(atPath: cacheEvictionJournalURL.path) else { return }
        let journal = try JSONDecoder().decode(CacheEvictionJournal.self,
            from: Data(contentsOf: cacheEvictionJournalURL))
        if let position = index(journal.original.id), records[position] == journal.evicted {
            if cacheFileIdentity(for: journal.original) == journal.identity {
                var recovered = records
                recovered[position] = journal.original
                try persistCacheState(recovered)
                records = recovered
            } else if let name = cacheFileName(for: journal.original) {
                // A missing file means unlink succeeded. A different file is
                // never admitted as a validated complete video or deleted.
                try withCacheMediaDirectory { _, media, _, _ in
                    var info = stat()
                    if fstatat(media, name, &info, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT {
                        throw VideoCacheEvictionError.recoveryRequired
                    }
                }
            } else { throw VideoCacheEvictionError.recoveryRequired }
        }
        try FileManager.default.removeItem(at: cacheEvictionJournalURL)
    }

    private func cacheFileName(for record: DownloadRecord) -> String? {
        guard let relative = record.localRelativePath else { return nil }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "Media", !parts[1].isEmpty,
              parts[1] != ".", parts[1] != "..", !relative.contains("\0"),
              ["mp4", "mov", "m4v"].contains((String(parts[1]) as NSString).pathExtension.lowercased()) else { return nil }
        return String(parts[1])
    }

    private func withCacheMediaDirectory<T>(_ operation: (Int32, Int32, stat, stat) throws -> T) throws -> T {
        // Resolve system aliases outside the owned root once, then reject a
        // changed root or any alias at the root/Media boundary.
        guard rootDirectory.standardizedFileURL.resolvingSymlinksInPath() == cacheRootURL,
              (try FileManager.default.attributesOfItem(atPath: rootDirectory.path)[.type] as? FileAttributeType) == .typeDirectory else {
            throw VideoCacheEvictionError.fileRemovalFailed
        }
        let root = open(cacheRootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { throw VideoCacheEvictionError.fileRemovalFailed }
        defer { close(root) }
        let media = openat(root, "Media", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard media >= 0 else { throw VideoCacheEvictionError.fileRemovalFailed }
        defer { close(media) }
        var rootInfo = stat(), mediaInfo = stat()
        guard fstat(root, &rootInfo) == 0, fstat(media, &mediaInfo) == 0 else {
            throw VideoCacheEvictionError.fileRemovalFailed
        }
        return try operation(root, media, rootInfo, mediaInfo)
    }

    private func cacheFileIdentity(name: String, root: Int32, media: Int32,
                                   rootInfo: stat, mediaInfo: stat) throws -> VideoCacheFileIdentity {
        var info = stat()
        guard fstatat(media, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size > 0 else {
            throw VideoCacheEvictionError.fileRemovalFailed
        }
        return VideoCacheFileIdentity(url: rootDirectory.appendingPathComponent("Media/" + name).standardizedFileURL,
            byteCount: Int64(info.st_size),
            modificationDate: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000),
            fileNumber: UInt64(info.st_ino), deviceNumber: UInt64(UInt32(bitPattern: info.st_dev)),
            changeSeconds: Int64(info.st_ctimespec.tv_sec), changeNanoseconds: Int64(info.st_ctimespec.tv_nsec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec), rootFileNumber: UInt64(rootInfo.st_ino),
            mediaFileNumber: UInt64(mediaInfo.st_ino), rootDeviceNumber: UInt64(UInt32(bitPattern: rootInfo.st_dev)),
            mediaDeviceNumber: UInt64(UInt32(bitPattern: mediaInfo.st_dev)))
    }

    func localURL(for record: DownloadRecord) -> URL? {
        guard let relative = record.localRelativePath else { return nil }
        let url: URL, base: URL
        if HLSLocalAssetLocation.isSystemPath(relative) {
            guard let assetURL = HLSLocalAssetLocation.url(for: relative, home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)),
                  FileManager.default.fileExists(atPath: assetURL.path) else { return nil }
            return assetURL
        } else { base = rootDirectory; url = base.appendingPathComponent(relative).standardizedFileURL }
        guard url.path.hasPrefix(base.standardizedFileURL.path + "/"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Imports only a user-selected local file. Page script messages never call this.
    /// The source belongs to the caller; this method copies it and leaves it intact.
    func importLocalVideo(from sourceURL: URL, title: String) async throws -> DownloadRecord {
        try Task.checkCancellation()
        guard sourceURL.isFileURL else { throw DownloadIssue.invalidURL }
        let ext = sourceURL.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else {
            throw DownloadIssue.unsupported("请选择 MP4 或 MOV 视频文件。")
        }
        let id = UUID(), token = UUID().uuidString + "|" + UUID().uuidString
        let relative = "Media/\(id.uuidString).\(ext)"
        let destination = rootDirectory.appendingPathComponent(relative)
        diagnostics.start(token: token, kind: .file, stage: .transfer)
        do {
            let size = try await Self.copyImport(sourceURL, to: destination)
            try Task.checkCancellation()
            diagnostics.update(token: token, stage: .assetMetadata, bytes: size)
            let asset = AVURLAsset(url: destination, options: [
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
            ])
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                asset.cancelLoading()
            }
            defer { timeout.cancel(); asset.cancelLoading() }
            let properties = try await withTaskCancellationHandler {
                let playable = try await asset.load(.isPlayable)
                let protected = try await asset.load(.hasProtectedContent)
                let duration = try await asset.load(.duration).seconds
                diagnostics.update(token: token, duration: duration, playable: playable, protectedContent: protected)
                guard !protected else { throw DownloadIssue.protectedContent }
                guard playable, duration.isFinite, duration > 0 else { throw DownloadIssue.invalidMedia }
                diagnostics.update(token: token, stage: .tracks)
                let video = try await asset.loadTracks(withMediaType: .video)
                let audio = try await asset.loadTracks(withMediaType: .audio)
                diagnostics.update(token: token, video: !video.isEmpty, audio: !audio.isEmpty)
                guard !video.isEmpty else { throw DownloadIssue.invalidMedia }
                timeout.cancel()
                diagnostics.update(token: token, stage: .sampleRead)
                // Fast-start MP4 metadata can remain intact after media bytes
                // are truncated. Read every compressed sample before admitting
                // an imported file into the offline library or cloud archive.
                try await Self.verifyLocalSamples(asset: asset, tracks: video + audio)
                try Task.checkCancellation()
                return (duration: duration, hasAudio: !audio.isEmpty)
            } onCancel: { asset.cancelLoading() }
            try Task.checkCancellation()
            let source = URL(string: "vyu-local:///video/" + id.uuidString)!
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = MediaCandidate(url: source, pageURL: source, frameURL: source,
                title: String((trimmedTitle.isEmpty ? "导入的视频" : trimmedTitle).prefix(240)),
                kind: .file, source: "localImport", mimeType: ext == "mov" ? "video/quicktime" : "video/mp4")
            let record = DownloadRecord(id: id, candidate: candidate, phase: .complete, progress: 1,
                bytesWritten: size, expectedBytes: size, localRelativePath: relative,
                failure: properties.hasAudio ? nil : "视频没有音轨，离线播放将无声。",
                duration: properties.duration, hasAudio: properties.hasAudio, createdAt: Date())
            records.insert(record, at: 0)
            guard persist() else {
                records.removeAll { $0.id == id }
                throw DownloadIssue.unsupported("无法保存导入记录，请检查存储空间。")
            }
            diagnostics.update(token: token, stage: .complete)
            return record
        } catch {
            diagnostics.update(token: token, error: error)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private nonisolated static func copyImport(_ source: URL, to destination: URL) async throws -> Int64 {
        try Task.checkCancellation()
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0 else {
            throw DownloadIssue.invalidMedia
        }
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        let copiedSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard copiedSize == size else { throw DownloadIssue.incompleteMedia }
        try verifyMovieContainerBounds(destination, size: UInt64(size))
        try Task.checkCancellation()
        return Int64(size)
    }

    private nonisolated static func verifyMovieContainerBounds(_ url: URL, size: UInt64) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset: UInt64 = 0, count = 0
        while offset < size {
            try Task.checkCancellation()
            guard count < 100_000, size - offset >= 8 else { throw DownloadIssue.incompleteMedia }
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 8), header.count == 8 else { throw DownloadIssue.incompleteMedia }
            let shortSize = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let atomSize: UInt64, headerSize: UInt64
            if shortSize == 0 { atomSize = size - offset; headerSize = 8 }
            else if shortSize == 1 {
                guard let extended = try handle.read(upToCount: 8), extended.count == 8 else { throw DownloadIssue.incompleteMedia }
                atomSize = extended.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }; headerSize = 16
            } else { atomSize = shortSize; headerSize = 8 }
            // MP4/MOV top-level sizes include their headers. Check by
            // subtraction so a malicious 64-bit size cannot overflow.
            guard atomSize >= headerSize, atomSize <= size - offset else { throw DownloadIssue.incompleteMedia }
            offset += atomSize; count += 1
        }
        guard count > 0 else { throw DownloadIssue.invalidMedia }
    }

    private nonisolated static func verifyLocalSamples(asset: AVURLAsset, tracks: [AVAssetTrack]) async throws {
        try Task.checkCancellation()
        var expectedEnds: [Double] = []
        for track in tracks {
            let segments = try await track.load(.segments)
            let ends = segments.filter { !$0.isEmpty }.map { CMTimeRangeGetEnd($0.timeMapping.target).seconds }.filter(\.isFinite)
            let range = try await track.load(.timeRange)
            expectedEnds.append(ends.max() ?? CMTimeRangeGetEnd(range).seconds)
        }
        let reader = try AVAssetReader(asset: asset)
        let outputs = try tracks.map { track in
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw DownloadIssue.invalidMedia }
            reader.add(output)
            return output
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        // AVAssetReader explicitly forbids cancelling concurrently with a
        // sample read. Check cancellation/deadline between local reads and
        // cancel on this same executor when leaving the loop.
        defer { reader.cancelReading() }
        guard reader.startReading() else { throw reader.error ?? DownloadIssue.invalidMedia }
        var finished = Set<Int>(), sampleCounts = Array(repeating: 0, count: outputs.count)
        var actualEnds = Array(repeating: -Double.infinity, count: outputs.count)
        while finished.count < outputs.count {
            // Round-robin reads prevent either audio or video from queuing
            // an entire track. No sample buffers are retained between reads.
            for index in outputs.indices where !finished.contains(index) {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
                let sampleCount: Int? = try autoreleasepool {
                    guard let sample = outputs[index].copyNextSampleBuffer() else { return nil }
                    guard CMSampleBufferDataIsReady(sample) else {
                        throw DownloadIssue.incompleteMedia
                    }
                    // Zero-sample buffers are valid timing/end markers; only
                    // a nil buffer terminates an output. Do not count markers
                    // as proof that the track contains media samples.
                    let count = CMSampleBufferGetNumSamples(sample)
                    if count > 0 {
                        let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        let duration = CMSampleBufferGetDuration(sample).seconds
                        guard start.isFinite else { throw DownloadIssue.incompleteMedia }
                        actualEnds[index] = max(actualEnds[index], start + (duration.isFinite && duration > 0 ? duration : 0))
                    }
                    return count
                }
                if let sampleCount { sampleCounts[index] += sampleCount }
                else { finished.insert(index) }
            }
            if reader.status == .failed { throw reader.error ?? DownloadIssue.incompleteMedia }
            await Task.yield()
        }
        try Task.checkCancellation()
        guard reader.status == .completed, sampleCounts.allSatisfy({ $0 > 0 }) else {
            throw reader.error ?? DownloadIssue.incompleteMedia
        }
        // A reader may replace unavailable tail data with empty timing markers
        // and still report completed. Require actual samples through each
        // nonempty track segment, allowing ordinary audio/video rounding.
        guard zip(expectedEnds, actualEnds).allSatisfy({ expected, actual in
            expected.isFinite && actual.isFinite && actual >= expected - 0.25
        }) else { throw DownloadIssue.incompleteMedia }
    }

    /// Imports a verified cloud copy without replacing a completed local video or an active transfer.
    func importCloudVideo(manifest: CloudVideoManifest, from packageURL: URL,
                          isCurrent: @escaping () -> Bool = { true }) async throws -> DownloadRecord {
        try Task.checkCancellation()
        guard stateReadable else { throw CloudVideoArchiveError.fileOperationFailed }
        guard isCurrent() else { throw CancellationError() }
        try CloudVideoArchive.validateManifest(manifest)
        let original = records.first { $0.id == manifest.id }
        if let existing = try cloudImportExistingRecord(id: manifest.id) { return existing }

        let attempt = UUID().uuidString
        let staging = rootDirectory.appendingPathComponent("Staging/CloudImport-\(attempt)", isDirectory: true)
        let relative = "Media/cloud-\(manifest.id.uuidString)-\(attempt).\(manifest.fileExtension)"
        let destination = rootDirectory.appendingPathComponent(relative)
        var committed = false
        defer {
            try? FileManager.default.removeItem(at: staging)
            if !committed { try? FileManager.default.removeItem(at: destination) }
        }
        do {
            let copy = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let source = try CloudVideoArchive.verifyMedia(at: packageURL, manifest: manifest)
                try Task.checkCancellation()
                let stagedPackage = staging.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: stagedPackage, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                let stagedMedia = stagedPackage.appendingPathComponent("video.\(manifest.fileExtension)")
                try FileManager.default.copyItem(at: source, to: stagedMedia)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: stagedMedia.path)
                // The cloud item may change during copying. Verify the owned copy as well.
                let verified = try CloudVideoArchive.verifyMedia(at: stagedPackage, manifest: manifest)
                try Task.checkCancellation()
                return verified
            }
            let stagedMedia = try await withTaskCancellationHandler {
                try await copy.value
            } onCancel: { copy.cancel() }
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let properties = try await validateCloudVideo(at: stagedMedia, manifest: manifest)
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            if let existing = try cloudImportExistingRecord(id: manifest.id) { return existing }
            // A deletion, retry, or another restoration during validation must win over this attempt.
            guard records.first(where: { $0.id == manifest.id }) == original else { throw CancellationError() }

            let sourceURL = URL(string: "https://icloud.invalid/video/\(manifest.id.uuidString)")!
            var components = URLComponents()
            components.scheme = "https"; components.host = manifest.sourceHost ?? "icloud.invalid"; components.path = "/"
            guard let pageURL = components.url else { throw CloudVideoArchiveError.invalidManifest }
            let candidate = MediaCandidate(url: sourceURL, pageURL: pageURL, frameURL: pageURL,
                title: manifest.title, kind: .file, source: "iCloud")
            let imported = DownloadRecord(id: manifest.id, candidate: candidate, phase: .complete, progress: 1,
                bytesWritten: manifest.byteCount, expectedBytes: manifest.byteCount, localRelativePath: relative,
                failure: properties.hasAudio ? nil : "视频没有音轨，离线播放将无声。",
                duration: properties.duration, hasAudio: properties.hasAudio, createdAt: manifest.createdAt)
            var updated = records
            if let index = updated.firstIndex(where: { $0.id == manifest.id }) { updated[index] = imported }
            else { updated.insert(imported, at: 0) }
            let updatedAuthentication = authenticated.subtracting([manifest.id])
            var updatedExpectations = expectations; updatedExpectations.removeValue(forKey: manifest.id)
            var updatedAttempts = tokens; updatedAttempts.removeValue(forKey: manifest.id)
            let archive = DownloadArchive(records: updated, authenticated: updatedAuthentication,
                expectations: updatedExpectations, attempts: updatedAttempts, foregroundHLS: foregroundOnlyHLS)
            let state = try JSONEncoder().encode(archive)

            guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
            try FileManager.default.moveItem(at: stagedMedia, to: destination)
            do {
                try state.write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                storageError = "下载状态未能写入本机，请检查存储空间。"
                throw CloudVideoArchiveError.fileOperationFailed
            }
            // Publish only after the atomic state write. Failure leaves the original records untouched.
            committed = true
            authenticated = updatedAuthentication; expectations = updatedExpectations; tokens = updatedAttempts
            contexts.removeValue(forKey: manifest.id); pendingPause.remove(manifest.id)
            touchedIDs.insert(manifest.id)
            thumbnailStore.remove(id: manifest.id)
            storageError = nil; records = updated
            return imported
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CloudVideoArchiveError {
            throw error
        } catch let error as DownloadIssue {
            throw error
        } catch {
            throw CloudVideoArchiveError.fileOperationFailed
        }
    }

    private func cloudImportExistingRecord(id: UUID) throws -> DownloadRecord? {
        guard let record = records.first(where: { $0.id == id }) else { return nil }
        if record.phase == .complete, localURL(for: record) != nil { return record }
        guard ![.queued, .downloading, .paused, .validating].contains(record.phase), tasks[id] == nil else {
            throw DownloadIssue.unsupported("本机下载尚未结束，暂不能从 iCloud 恢复此视频。")
        }
        return nil
    }

    private func validateCloudVideo(at url: URL, manifest: CloudVideoManifest) async throws -> (duration: Double, hasAudio: Bool) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            asset.cancelLoading()
        }
        defer { timeout.cancel(); asset.cancelLoading() }
        return try await withTaskCancellationHandler {
            let playable = try await asset.load(.isPlayable)
            let protected = try await asset.load(.hasProtectedContent)
            let duration = try await asset.load(.duration).seconds
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            try Task.checkCancellation()
            let tolerance = max(0.25, min(1, manifest.duration * 0.01))
            guard playable, !protected, !video.isEmpty, duration.isFinite, duration > 0,
                  abs(duration - manifest.duration) <= tolerance, !audio.isEmpty == manifest.hasAudio else {
                throw CloudVideoArchiveError.invalidMedia
            }
            return (duration, !audio.isEmpty)
        } onCancel: { asset.cancelLoading() }
    }

    private func restoreTasks() async {
        defer { restoringTasks = false; activityDidChange() }
        await backgroundHLS.restore { job in
            guard self.tokens[job.id] == job.attempt,
                  let record = self.records.first(where: { $0.id == job.id }),
                  [.downloading, .validating, .paused].contains(record.phase) else { return false }
            // Export already committed its complete MP4 before a process exit.
            // Keep that owned file and let the ordinary validator finish it;
            // do not export a second movie and orphan the first one.
            return !(record.phase == .validating && self.localURL(for: record) != nil)
        }
        let fileTasks = await backgroundSession.allTasks
        let assetTasks = await hlsSession.allTasks
        for task in fileTasks + assetTasks {
            guard let token = task.taskDescription, let id = Self.recordID(token), let record = records.first(where: { $0.id == id }),
                  [.downloading, .paused, .queued].contains(record.phase) else { task.cancel(); continue }
            guard !touchedIDs.contains(id) else {
                if tasks[id]?.taskDescription != token { task.cancel() }
                continue
            }
            guard tokens[id] == token else { task.cancel(); continue }
            if task is AVAssetDownloadTask, record.candidate.requestContext != nil {
                // A prior process's random loopback port and token cannot be restored.
                task.cancel(); tokens.removeValue(forKey: id)
                if let local = localURL(for: record) { try? FileManager.default.removeItem(at: local) }
                mutate(id) {
                    $0.phase = .failed; $0.localRelativePath = nil
                    $0.failure = "前台下载已中断，请回到网页重新选择视频。"
                }
                continue
            }
            tasks[id] = task
            delegateProxy.register(token: token, cookies: [], pageURL: record.candidate.frameURL, userAgent: record.candidate.userAgent, requestContext: record.candidate.requestContext)
            if record.phase == .paused { task.suspend() } else { task.resume() }
        }
        for id in restoringIDs {
            guard !touchedIDs.contains(id), tasks[id] == nil, backgroundHLS.jobs[id] == nil,
                  let record = records.first(where: { $0.id == id }),
                  !validations.contains(tokens[id] ?? "") else { continue }
            if record.phase == .validating, let url = localURL(for: record) {
                await validate(id: record.id, url: url, isHLS: url.pathExtension.lowercased() == "movpkg")
            } else if [.downloading, .queued, .validating].contains(record.phase) {
                if requiresForeground(record), let local = localURL(for: record) { try? FileManager.default.removeItem(at: local) }
                mutate(record.id) {
                    $0.phase = .failed; $0.failure = "下载已中断。系统可能在 App 强退后取消任务，请重试。"
                    if requiresForeground($0) { $0.localRelativePath = nil }
                }
            }
        }
    }
    nonisolated static func recordID(_ token: String) -> UUID? { token.split(separator: "|").first.flatMap { UUID(uuidString: String($0)) } }
    private func accepts(_ token: String) -> UUID? {
        guard let id = Self.recordID(token), tokens[id] == token, let record = records.first(where: { $0.id == id }),
              [.downloading, .validating].contains(record.phase) else { return nil }; return id
    }
    fileprivate func progress(token: String, written: Int64, expected: Int64, fraction: Double? = nil) {
        guard let id = accepts(token) else { return }
        mutate(id) {
            $0.bytesWritten = $0.candidate.kind == .hls ? max($0.bytesWritten, max(0, written)) : max(0, written)
            if expected > 0 { $0.expectedBytes = expected }
            if let value = fraction ?? (expected > 0 ? Double(written) / Double(expected) : nil), value.isFinite {
                $0.progress = min(0.99, $0.candidate.kind == .hls ? max($0.progress, max(0, value)) : max(0, value))
            }
        }
    }
    fileprivate func fileFinished(token: String, temporaryURL: URL?, response: URLResponse?, error: Error?) async {
        guard let id = accepts(token), let record = records.first(where: { $0.id == id }) else {
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }; return
        }
        do {
            if let error { throw error }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw DownloadIssue.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
            guard let temporaryURL else { throw DownloadIssue.invalidMedia }
            let size = (try temporaryURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size > 0 else { throw DownloadIssue.invalidMedia }
            let expectedBytes = MediaFileResponse.expectedBytes(http)
            if http.statusCode == 206 && expectedBytes == nil { throw DownloadIssue.incompleteMedia }
            if let expectedBytes, Int64(size) < expectedBytes { throw DownloadIssue.incompleteMedia }
            let ext = ["mp4", "mov", "m4v"].contains(record.candidate.url.pathExtension.lowercased()) ? record.candidate.url.pathExtension.lowercased() : "mp4"
            let relative = "Media/\(id.uuidString)-\(token.split(separator: "|").last ?? "file").\(ext)"
            let destination = rootDirectory.appendingPathComponent(relative)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            mutate(id) { $0.phase = .validating; $0.localRelativePath = relative; $0.bytesWritten = Int64(size) }
            await validate(id: id, url: destination, isHLS: false)
        } catch {
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            fail(id, error: error)
        }
    }
    fileprivate func assetLocation(token: String, location: URL) {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        guard let relative = HLSLocalAssetLocation.relativePath(for: location, home: home),
              let savedURL = HLSLocalAssetLocation.url(for: relative, home: home) else { return }
        guard let id = accepts(token) else {
            // AVFoundation may report its package only after cancellation. Delete
            // that orphan, while preserving any path already owned by a live record.
            if !records.contains(where: { localURL(for: $0) == savedURL }), !hlsLocations.values.contains(savedURL) {
                try? FileManager.default.removeItem(at: savedURL)
            }
            return
        }
        // Validate ownership above, but keep the exact system URL. In particular,
        // resolving aliases under /.nofollow changes the path's kernel semantics.
        hlsLocations[id] = location
        mutate(id) { $0.localRelativePath = relative }
    }
    fileprivate func completed(token: String, error: Error?, isHLS: Bool) async {
        guard let id = accepts(token) else { return }
        let relayFailure = hlsRelays[id]?.failure
        if let relay = hlsRelays[id] {
            progress(token: token, written: relay.bytesTransferred, expected: 0)
        }
        // Offline validation must succeed after the relay has stopped.
        if isHLS { hlsRelays.removeValue(forKey: id)?.stop() }
        if let error = relayFailure ?? error {
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? data.write(to: resumeURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            fail(id, error: error)
        } else if isHLS {
            guard let record = records.first(where: { $0.id == id }), let url = hlsLocations[id] ?? localURL(for: record) else { fail(id, error: DownloadIssue.unsupported("系统未返回 HLS 本机资源位置，未标记为完成。")); return }
            mutate(id) { $0.phase = .validating }
            await validate(id: id, url: url, isHLS: true)
        }
    }
    private func validate(id: UUID, url: URL, isHLS: Bool) async {
        let attempt = tokens[id] ?? (id.uuidString + "|" + UUID().uuidString)
        tokens[id] = attempt
        validations.insert(attempt)
        if let record = records.first(where: { $0.id == id }) {
            diagnostics.start(token: attempt, kind: record.candidate.kind)
            diagnostics.update(token: attempt, stage: .assetMetadata, bytes: record.bytesWritten,
                               expectedDuration: expectations[id]?.duration)
        }
        defer { validations.remove(attempt); completePendingBackgroundEvents() }
        do {
            let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidLocalReferenceToRemote.rawValue])
            let playable = try await asset.load(.isPlayable)
            let protected = try await asset.load(.hasProtectedContent)
            let duration = try await asset.load(.duration).seconds
            diagnostics.update(token: attempt, duration: duration, playable: playable, protectedContent: protected)
            guard !protected else { throw DownloadIssue.protectedContent }
            guard playable, duration.isFinite, duration > 0 else { throw DownloadIssue.invalidMedia }
            let hasAudio: Bool
            if isHLS {
                diagnostics.update(token: attempt, stage: .offlineCache, playableOffline: asset.assetCache?.isPlayableOffline == true)
                guard let cache = asset.assetCache, cache.isPlayableOffline else { throw DownloadIssue.unsupported("系统离线缓存尚不完整，未标记为完成。") }
                if let expected = expectations[id]?.duration, duration < expected - 1 { throw DownloadIssue.unsupported("离线视频时长短于播放清单，未标记为完成。") }
                let tracks = try await preparedHLSTracks(asset: asset, id: id, attempt: attempt,
                    requiresAudio: expectations[id]?.requiresAudio == true)
                guard tracks.video else { throw DownloadIssue.invalidMedia }
                if expectations[id]?.requiresAudio == true && !tracks.audio { throw DownloadIssue.unsupported("下载缺少清单中的音轨，未标记为完成。") }
                hasAudio = tracks.audio
            } else {
                diagnostics.update(token: attempt, stage: .tracks)
                let video = try await asset.loadTracks(withMediaType: .video)
                let audio = try await asset.loadTracks(withMediaType: .audio)
                diagnostics.update(token: attempt, video: !video.isEmpty, audio: !audio.isEmpty)
                guard !video.isEmpty else { throw DownloadIssue.invalidMedia }
                hasAudio = !audio.isEmpty
            }
            guard tokens[id] == attempt, let record = records.first(where: { $0.id == id }), record.phase == .validating else { return }
            let saved = commit(id) { $0.phase = .complete; $0.progress = 1; $0.duration = duration; $0.hasAudio = hasAudio; $0.failure = !hasAudio ? "视频没有音轨，离线播放将无声。" : nil }
            if saved { diagnostics.update(token: attempt, stage: .complete) }
            else if let index = index(id) {
                // Keep the validated file and the persisted validating path.
                // Never expose a completed/cloud-eligible record on write failure.
                records[index].phase = .failed
                records[index].failure = "视频已保存，但完成状态未能写入。请检查存储空间后重试。"
                pendingCompletionWrites.insert(id)
            }
            tasks.removeValue(forKey: id); tokens.removeValue(forKey: id); contexts.removeValue(forKey: id)
            try? FileManager.default.removeItem(at: resumeURL(id))
        } catch {
            guard tokens[id] == attempt, let current = records.first(where: { $0.id == id }), current.phase == .validating else { return }
            try? FileManager.default.removeItem(at: url)
            mutate(id) { $0.localRelativePath = nil }
            fail(id, error: error)
        }
    }
    private func preparedHLSTracks(asset: AVURLAsset, id: UUID, attempt: String, requiresAudio: Bool) async throws -> (video: Bool, audio: Bool) {
        diagnostics.update(token: attempt, stage: .mediaSelection)
        let item = try await OfflineMediaPreparation.makeItem(asset: asset, requiresAudio: requiresAudio)
        let player = AVPlayer(playerItem: item)
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.isMuted = true
        defer { player.cancelPendingPrerolls(); player.pause(); player.replaceCurrentItem(with: nil) }
        let deadline = Date().addingTimeInterval(15)
        diagnostics.update(token: attempt, stage: .playerPreparation)
        while item.status == .unknown && Date() < deadline {
            guard tokens[id] == attempt else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard item.status == .readyToPlay else { throw item.error ?? DownloadIssue.invalidMedia }
        diagnostics.update(token: attempt, stage: .preroll)
        var prepared: Bool?
        player.preroll(atRate: 1) { success in Task { @MainActor in prepared = success } }
        while prepared == nil && Date() < deadline {
            guard tokens[id] == attempt else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard prepared == true, item.status == .readyToPlay else { throw item.error ?? DownloadIssue.incompleteMedia }
        let types = item.tracks.compactMap { $0.assetTrack?.mediaType }
        diagnostics.update(token: attempt, stage: .tracks, video: types.contains(.video), audio: types.contains(.audio))
        return (types.contains(.video), types.contains(.audio))
    }

    private func fail(_ id: UUID, error: Error) {
        guard let record = records.first(where: { $0.id == id }), ![.cancelled, .paused, .complete].contains(record.phase) else { return }
        backgroundHLS?.cancel(id: id)
        assemblyGenerations.removeValue(forKey: id)
        if let token = tokens[id] { diagnostics.update(token: token, bytes: record.bytesWritten, error: error) }
        mutate(id) { $0.phase = .failed; $0.failure = safeMessage(error) }
        tasks.removeValue(forKey: id)?.cancel(); tokens.removeValue(forKey: id)
        portableTasks.removeValue(forKey: id)?.cancel()
        hlsRelays.removeValue(forKey: id)?.stop()
        if let location = hlsLocations.removeValue(forKey: id) { try? FileManager.default.removeItem(at: location) }
        mutate(id) { $0.localRelativePath = nil }
    }
    private func safeMessage(_ error: Error) -> String {
        if let issue = error as? DownloadIssue { return issue.localizedDescription }
        if let issue = error as? HLSRelayError { return issue.localizedDescription }
        if let issue = error as? HLSFileExportError { return issue.localizedDescription }
        if let issue = error as? HLSFileValidationFailure { return issue.localizedDescription }
        let code = (error as NSError).code
        if code == NSURLErrorNotConnectedToInternet { return "网络已断开，请联网后重试。" }
        if code == NSURLErrorTimedOut { return "下载连接超时，请重试。" }
        if code == NSURLErrorCancelled { return "下载已中断，请重试。" }
        if (error as NSError).domain == AVFoundationErrorDomain { return DownloadIssue.invalidMedia.localizedDescription }
        return "下载或校验失败（错误 \(code)）。请重试，或回到网页重新识别。"
    }
    fileprivate func backgroundEventsFinished(_ identifier: String) {
        Self.finishedBackgroundIdentifiers.insert(identifier); completePendingBackgroundEvents()
    }
    private func completePendingBackgroundEvents() {
        guard validations.isEmpty else { return }
        for identifier in Array(Self.finishedBackgroundIdentifiers) {
            if let completion = Self.backgroundCompletions.removeValue(forKey: identifier) {
                Self.finishedBackgroundIdentifiers.remove(identifier); completion()
            }
        }
    }
}

@MainActor
enum OfflineMediaPreparation {
    /// Select only downloaded HLS audio options. Legible alternatives remain off until explicitly cached.
    static func makeItem(asset: AVURLAsset, requiresAudio: Bool = false) async throws -> AVPlayerItem {
        guard asset.url.isFileURL, try await asset.load(.isPlayable) else { throw DownloadIssue.invalidMedia }
        let item = AVPlayerItem(asset: asset)
        guard let cache = asset.assetCache else { return item }
        guard cache.isPlayableOffline else { throw DownloadIssue.incompleteMedia }
        if let audible = try await asset.loadMediaSelectionGroup(for: .audible) {
            let cached = cache.mediaSelectionOptions(in: audible)
            guard let chosen = cached.first(where: { $0 == audible.defaultOption }) ?? cached.first else {
                if requiresAudio || !audible.options.isEmpty { throw DownloadIssue.unsupported("下载缺少可离线使用的音轨，未标记为完成。") }
                return item
            }
            item.select(chosen, in: audible)
        }
        if let legible = try await asset.loadMediaSelectionGroup(for: .legible) {
            item.select(nil, in: legible)
        }
        return item
    }
}

private final class TransferDelegate: NSObject, URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    weak var owner: DownloadManager?
    let stagingDirectory: URL
    private let lock = NSLock()
    private var context: [String: ([HTTPCookie], URL, String?, MediaRequestContext?)] = [:]
    init(stagingDirectory: URL) { self.stagingDirectory = stagingDirectory }
    func register(token: String, cookies: [HTTPCookie], pageURL: URL, userAgent: String?, requestContext: MediaRequestContext? = nil) {
        lock.lock(); context[token] = (cookies, pageURL, MediaCookiePolicy.validUserAgent(userAgent), requestContext); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, MediaCookiePolicy.validHTTPURL(url),
              !(response.url?.scheme == "https" && url.scheme == "http") else { completionHandler(nil); return }
        lock.lock(); let values = context[task.taskDescription ?? ""]; lock.unlock()
        var redirected = MediaCookiePolicy.request(url: url, cookies: values?.0 ?? [], pageURL: values?.1,
            method: request.httpMethod ?? "GET", userAgent: values?.2, context: values?.3)
        // Preserve only transfer range controls, never arbitrary credentials from a redirect.
        for field in ["Range", "If-Range"] {
            if let value = request.value(forHTTPHeaderField: field) { redirected.setValue(value, forHTTPHeaderField: field) }
        }
        completionHandler(redirected)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let token = downloadTask.taskDescription ?? ""
        let destination = stagingDirectory.appendingPathComponent(UUID().uuidString)
        // URLSession deletes its temporary file when this delegate returns; take ownership synchronously.
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor [weak owner] in await owner?.fileFinished(token: token, temporaryURL: destination, response: downloadTask.response, error: nil) }
        } catch {
            Task { @MainActor [weak owner] in await owner?.fileFinished(token: token, temporaryURL: nil, response: downloadTask.response, error: error) }
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let token = downloadTask.taskDescription ?? ""
        Task { @MainActor [weak owner] in owner?.progress(token: token, written: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let token = task.taskDescription ?? ""
        lock.lock(); context.removeValue(forKey: token); lock.unlock()
        Task { @MainActor [weak owner] in await owner?.completed(token: token, error: error, isHLS: task is AVAssetDownloadTask) }
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        let token = assetDownloadTask.taskDescription ?? ""
        Task { @MainActor [weak owner] in owner?.assetLocation(token: token, location: location) }
    }
    @available(iOS 18.0, *)
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        let token = assetDownloadTask.taskDescription ?? ""
        Task { @MainActor [weak owner] in owner?.assetLocation(token: token, location: location) }
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        let loaded = loadedTimeRanges.reduce(0) { $0 + $1.timeRangeValue.duration.seconds }
        let expected = timeRangeExpectedToLoad.duration.seconds
        let token = assetDownloadTask.taskDescription ?? ""
        Task { @MainActor [weak owner] in owner?.progress(token: token, written: 0, expected: 0, fraction: expected > 0 ? loaded / expected : 0) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor [weak owner] in owner?.backgroundEventsFinished(identifier) }
    }
}
