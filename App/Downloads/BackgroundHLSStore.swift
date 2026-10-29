import CryptoKit
import Foundation
import UIKit

/// The daemon downloads HTTP resources. Only the foreground exporter may turn
/// verified, complete resources into a playable MP4. This directory is local only.
@MainActor
final class BackgroundHLSStore {
    struct Receipt: Codable { let bytes: Int64; let digest: String }
    struct Job: Codable {
        let id: UUID
        let attempt: String
        let plan: HLSFileDownloadPlan
        let userAgent: String?
        var receipts: [Int: Receipt] = [:]
        var paused = false
        var ready: Bool { receipts.count == plan.resourceCount }
    }
    private(set) var jobs: [UUID: Job] = [:]
    var onChange: ((Job) -> Void)?
    var onFailure: ((UUID, String, Error) -> Void)?
    var onEventsFinished: ((String) -> Void)?
    private let directory: URL
    private let identifier: String
    private let delegate: BackgroundHLSDelegate
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var finishingTokens: Set<String> = []
    private var changedJobs: Set<UUID> = []
    private var changeNotification: Task<Void, Never>?
    private var inFlightBytes: [String: Int64] = [:]
    private var resourceLists: [UUID: [HLSFilePlaylist.Resource]] = [:]
    private var taskTokens: [UUID: [Int: String]] = [:]
    private var enqueuers: [UUID: Task<Void, Never>] = [:]
    private var enqueueGenerations: [UUID: UUID] = [:]
    private var restoring = false
    private var restored = false
    private var session: URLSession!
    var scheduledResourceCount: Int { tasks.count }

    init(root: URL, identifier: String, sessionConfiguration: URLSessionConfiguration? = nil) {
        directory = root.appendingPathComponent("BackgroundHLS", isDirectory: true)
        self.identifier = identifier
        delegate = BackgroundHLSDelegate(staging: root.appendingPathComponent("Staging", isDirectory: true))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            for folder in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
                do {
                    let value = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard value.isDirectory == true, value.isSymbolicLink != true else { continue }
                    let state = folder.appendingPathComponent("job.json")
                    let stateValues = try state.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard stateValues.isRegularFile == true, stateValues.isSymbolicLink != true,
                          (stateValues.fileSize ?? Int.max) <= 8_000_000 else { continue }
                    let data = try Data(contentsOf: state)
                    let job = try JSONDecoder().decode(Job.self, from: data)
                    guard job.id == id, DownloadManager.recordID(job.attempt) == id else { continue }
                    try job.plan.validate()
                    guard job.receipts.keys.allSatisfy({ (0..<job.plan.resourceCount).contains($0) }) else { continue }
                    jobs[id] = job
                    resourceLists[id] = job.plan.resources
                } catch { /* Never adopt an unreadable resource directory. */ }
            }
        } catch { /* create() will report a durable-write failure. */ }
        delegate.owner = self
        let config = sessionConfiguration ?? URLSessionConfiguration.background(withIdentifier: identifier)
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 86400
        config.isDiscretionary = false; config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func restore(accepts: (Job) -> Bool) async {
        guard !restored, !restoring else { return }
        restoring = true
        defer { restoring = false }
        let existing = await session.allTasks
        for (offset, task) in existing.enumerated() {
            // Reattaching thousands of daemon tasks must leave time for UI work.
            if offset.isMultiple(of: 16) { try? await Task.sleep(for: .milliseconds(1)) }
            guard let token = task.taskDescription, let (id, index) = lookup(token), let job = jobs[id],
                  accepts(job), !job.paused, job.receipts[index] == nil,
                  let download = task as? URLSessionDownloadTask else { task.cancel(); continue }
            if finishingTokens.contains(token) { continue }
            guard task.state != .completed, task.state != .canceling,
                  taskTokens[id]?[index] == nil else { task.cancel(); continue }
            tasks[token] = download; taskTokens[id, default: [:]][index] = token; task.resume()
        }
        restored = true
        for job in Array(jobs.values) {
            guard accepts(job) else { cancel(id: job.id); continue }
            if !job.paused { enqueue(job.id) }
            if let current = jobs[job.id] { onChange?(current) }
        }
    }

    func create(id: UUID, attempt: String, plan: HLSFileDownloadPlan, userAgent: String?) throws {
        try plan.validate()
        cancel(id: id)
        let job = Job(id: id, attempt: attempt, plan: plan, userAgent: MediaCookiePolicy.validUserAgent(userAgent))
        try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try persist(job); jobs[id] = job
        resourceLists[id] = plan.resources
        if restored { enqueue(id) }
        onChange?(job)
    }
    func pause(id: UUID) throws {
        guard var job = jobs[id] else { return }
        job.paused = true; try persist(job); jobs[id] = job
        cancelTasks(id)
    }
    func resume(id: UUID) throws {
        guard var job = jobs[id] else { return }
        job.paused = false; try persist(job); jobs[id] = job
        enqueue(id); onChange?(job)
    }
    func cancel(id: UUID) {
        jobs.removeValue(forKey: id); cancelTasks(id)
        resourceLists.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: folder(id))
    }
    func progress(id: UUID) -> (Int64, Double) {
        guard let job = jobs[id] else { return (0, 0) }
        let committed = job.receipts.values.reduce(Int64(0)) { $0 + $1.bytes }
        let running = inFlightBytes.filter { $0.key.hasPrefix(job.attempt + "|") }.values.reduce(Int64(0), +)
        return (committed + running, Double(job.receipts.count) / Double(job.plan.resourceCount) * 0.85)
    }
    /// Recheck hashes off the main actor before the local exporter uses bytes.
    func resources(id: UUID) async throws -> [HLSFilePlaylist.Resource: URL] {
        guard let job = jobs[id], job.ready, let resources = resourceLists[id] else { throw DownloadIssue.incompleteMedia }
        let folder = folder(id)
        return try await Task.detached(priority: .utility) {
            var result: [HLSFilePlaylist.Resource: URL] = [:]
            var total: Int64 = 0
            for index in resources.indices {
                let file = folder.appendingPathComponent("\(index).part")
                guard let receipt = job.receipts[index], try Self.receipt(file) == receipt else { throw DownloadIssue.incompleteMedia }
                total += receipt.bytes
                guard total <= 2 * 1024 * 1024 * 1024 else { throw HLSFileExportError.limitExceeded }
                result[resources[index]] = file
            }
            return result
        }.value
    }
    private func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func persist(_ job: Job) throws {
        let data = try JSONEncoder().encode(job)
        guard data.count <= 8_000_000 else { throw HLSFileExportError.limitExceeded }
        try data.write(to: folder(job.id).appendingPathComponent("job.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func cancelTasks(_ id: UUID) {
        enqueueGenerations.removeValue(forKey: id)
        enqueuers.removeValue(forKey: id)?.cancel()
        changedJobs.remove(id)
        for token in taskTokens.removeValue(forKey: id)?.values ?? Dictionary<Int, String>().values {
            tasks.removeValue(forKey: token)?.cancel(); inFlightBytes.removeValue(forKey: token)
            finishingTokens.remove(token)
        }
    }
    /// Expiration stops submitting new work, without pausing already owned
    /// daemon tasks or removing their durable resources.
    func suspendScheduling(id: UUID) {
        enqueueGenerations.removeValue(forKey: id)
        enqueuers.removeValue(forKey: id)?.cancel()
    }
    func resumeScheduling() {
        for job in Array(jobs.values) where !job.paused { enqueue(job.id) }
    }
    private func enqueue(_ id: UUID) {
        guard restored, let job = jobs[id], !job.paused, enqueuers[id] == nil else { return }
        let attempt = job.attempt, generation = UUID()
        enqueueGenerations[id] = generation
        enqueuers[id] = Task { [weak self] in
            guard let self else { return }
            // A short system extension lets queuing finish when the user leaves
            // the app. Unsubmitted resources remain durable if time expires.
            let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Queue HLS resources") { [weak self] in
                Task { @MainActor in
                    guard self?.enqueueGenerations[id] == generation else { return }
                    self?.suspendScheduling(id: id)
                }
            }
            defer {
                if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
                if self.enqueueGenerations[id] == generation {
                    self.enqueueGenerations.removeValue(forKey: id)
                    self.enqueuers.removeValue(forKey: id)
                }
            }
            guard let resources = self.resourceLists[id] else { return }
            var next = 0
            while next < resources.count {
                guard !Task.isCancelled, self.enqueueGenerations[id] == generation,
                      let current = self.jobs[id], current.attempt == attempt, !current.paused else { return }
                let end = min(next + 8, resources.count)
                for index in next..<end where current.receipts[index] == nil && self.taskTokens[id]?[index] == nil {
                    let resource = resources[index]
                    let token = attempt + "|\(index)|" + UUID().uuidString
                    var request = URLRequest(url: resource.url)
                    // Automatic background redirects must never carry page credentials.
                    if let ua = current.userAgent { request.setValue(ua, forHTTPHeaderField: "User-Agent") }
                    if let range = resource.range { request.setValue(range.header, forHTTPHeaderField: "Range") }
                    let task = self.session.downloadTask(with: request)
                    task.taskDescription = token
                    self.tasks[token] = task; self.taskTokens[id, default: [:]][index] = token
                    task.resume()
                }
                next = end
                // A real suspension (not only yield) gives run-loop input and
                // pause/cancel actions a chance between bounded batches.
                if next < resources.count {
                    do { try await Task.sleep(for: .milliseconds(1)) } catch { return }
                }
            }
        }
    }
    private func lookup(_ token: String) -> (UUID, Int)? {
        let parts = token.split(separator: "|")
        guard parts.count == 4, let id = UUID(uuidString: String(parts[0])), let index = Int(parts[2]),
              let job = jobs[id], job.attempt == parts.prefix(2).joined(separator: "|"),
              (0..<job.plan.resourceCount).contains(index) else { return nil }
        return (id, index)
    }
    fileprivate func progress(updates: [String: Int64]) {
        var changed: Set<UUID> = []
        for (token, bytes) in updates {
            guard let (id, _) = lookup(token), tasks[token] != nil, let job = jobs[id], !job.paused else { continue }
            inFlightBytes[token] = max(0, bytes)
            if bytes > 64 * 1024 * 1024 { failed(token: token, error: HLSFileExportError.limitExceeded); continue }
            changed.insert(id)
        }
        // One publication and index write per job, not one per segment callback.
        for id in changed { scheduleProgressNotification(id) }
    }
    private func scheduleProgressNotification(_ id: UUID) {
        changedJobs.insert(id)
        guard changeNotification == nil else { return }
        changeNotification = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            let ids = self.changedJobs
            self.changedJobs = []; self.changeNotification = nil
            for id in ids {
                if let job = self.jobs[id], !job.paused { self.onChange?(job) }
            }
        }
    }
    func finished(token: String, staged: URL?, response: URLResponse?, error: Error?) async {
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
        guard let (id, index) = lookup(token), let job = jobs[id], let resources = resourceLists[id], !job.paused,
              job.receipts[index] == nil, !finishingTokens.contains(token),
              tasks[token] != nil || (!restored && taskTokens[id]?[index] == nil) else { return }
        // A daemon can finish before allTasks adoption. Reserve the resource
        // while its staged bytes are verified so restore cannot duplicate it.
        taskTokens[id, default: [:]][index] = token
        finishingTokens.insert(token)
        defer { finishingTokens.remove(token) }
        do {
            if let error { throw error }
            guard let staged, let http = response as? HTTPURLResponse, let final = http.url,
                  MediaCookiePolicy.validHTTPURL(final),
                  !(resources[index].url.scheme == "https" && final.scheme != "https") else { throw DownloadIssue.invalidMedia }
            let resource = resources[index]
            guard http.statusCode == (resource.range == nil ? 200 : 206) else { throw DownloadIssue.http(http.statusCode) }
            guard !MediaFileResponse.isWebPage(http) else { throw DownloadIssue.invalidMedia }
            if let range = resource.range {
                guard http.statusCode == 206,
                      let raw = http.value(forHTTPHeaderField: "Content-Range"), let actual = HLSRelayContentRange(raw),
                      actual.start == range.offset, actual.length == range.length else { throw DownloadIssue.incompleteMedia }
            } else { guard http.statusCode == 200 else { throw DownloadIssue.http(http.statusCode) } }
            let receipt = try await Task.detached(priority: .utility) { try Self.receipt(staged) }.value
            guard let current = jobs[id], current.attempt == job.attempt, !current.paused, finishingTokens.contains(token) else { return }
            guard (http.expectedContentLength < 0 || http.expectedContentLength == receipt.bytes),
                  resource.range == nil || resource.range?.length == receipt.bytes,
                  current.receipts.values.reduce(Int64(0), { $0 + $1.bytes }) + receipt.bytes <= 2 * 1024 * 1024 * 1024 else { throw DownloadIssue.incompleteMedia }
            let target = folder(id).appendingPathComponent("\(index).part")
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: staged, to: target)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            var updated = current; updated.receipts[index] = receipt
            try persist(updated); jobs[id] = updated
            tasks.removeValue(forKey: token); taskTokens[id]?.removeValue(forKey: index)
            inFlightBytes.removeValue(forKey: token)
            if updated.ready {
                changedJobs.remove(id); onChange?(updated)
            } else { scheduleProgressNotification(id) }
        } catch { failed(token: token, error: error) }
    }
    fileprivate func failed(token: String, error: Error) {
        guard let (id, _) = lookup(token), let job = jobs[id], tasks[token] != nil || finishingTokens.contains(token), !job.paused else { return }
        cancelTasks(id)
        onFailure?(id, job.attempt, error)
    }
    nonisolated private static func receipt(_ url: URL) throws -> Receipt {
        let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let bytes = Int64(value.fileSize ?? 0)
        guard value.isRegularFile == true, value.isSymbolicLink != true, bytes > 0, bytes <= 64 * 1024 * 1024 else { throw DownloadIssue.incompleteMedia }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty { hash.update(data: chunk) }
        return Receipt(bytes: bytes, digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    fileprivate func eventsFinished(_ identifier: String) { onEventsFinished?(identifier) }
}
extension BackgroundHLSStore.Receipt: Equatable {}

private final class BackgroundHLSDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var owner: BackgroundHLSStore?
    private let staging: URL
    private let callbacks = DispatchGroup()
    private let progressLock = NSLock()
    private var pendingProgress: [String: Int64] = [:]
    private var progressScheduled = false
    init(staging: URL) { self.staging = staging }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let token = downloadTask.taskDescription else { return }
        progressLock.lock()
        pendingProgress[token] = totalBytesWritten
        let schedule = !progressScheduled
        progressScheduled = true
        progressLock.unlock()
        guard schedule else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.owner?.progress(updates: self.takeProgress())
        }
    }
    private func takeProgress() -> [String: Int64] {
        progressLock.lock(); defer { progressLock.unlock() }
        let value = pendingProgress
        pendingProgress = [:]; progressScheduled = false
        return value
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let token = downloadTask.taskDescription else { return }
        let staged = staging.appendingPathComponent("hls-part-" + UUID().uuidString)
        var error: Error?
        do { try FileManager.default.moveItem(at: location, to: staged) } catch let caught { error = caught }
        let failure = error; let response = downloadTask.response
        callbacks.enter()
        Task { @MainActor [weak owner, callbacks] in
            await owner?.finished(token: token, staged: failure == nil ? staged : nil, response: response, error: failure)
            if failure == nil { try? FileManager.default.removeItem(at: staged) }
            callbacks.leave()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let token = task.taskDescription else { return }
        callbacks.enter()
        Task { @MainActor [weak owner, callbacks] in owner?.failed(token: token, error: error); callbacks.leave() }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        callbacks.notify(queue: .main) { [weak owner] in
            Task { @MainActor in owner?.eventsFinished(identifier) }
        }
    }
}
