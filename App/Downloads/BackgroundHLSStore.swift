import CryptoKit
import Foundation

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
        var ready: Bool { receipts.count == plan.resources.count }
    }
    private(set) var jobs: [UUID: Job] = [:]
    var onChange: ((Job) -> Void)?
    var onFailure: ((UUID, String, Error) -> Void)?
    var onEventsFinished: ((String) -> Void)?
    private let directory: URL
    private let identifier: String
    private let delegate: BackgroundHLSDelegate
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var inFlightBytes: [String: Int64] = [:]
    private var restored = false
    private var session: URLSession!

    init(root: URL, identifier: String) {
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
                    guard job.receipts.keys.allSatisfy({ job.plan.resources.indices.contains($0) }) else { continue }
                    jobs[id] = job
                } catch { /* Never adopt an unreadable resource directory. */ }
            }
        } catch { /* create() will report a durable-write failure. */ }
        delegate.owner = self
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 86400
        config.isDiscretionary = false; config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func restore(accepts: (Job) -> Bool) async {
        let existing = await session.allTasks
        for task in existing {
            guard let token = task.taskDescription, let (id, index) = lookup(token), let job = jobs[id],
                  accepts(job), !job.paused, job.receipts[index] == nil,
                  let download = task as? URLSessionDownloadTask, tasks[token] == nil else { task.cancel(); continue }
            tasks[token] = download; task.resume()
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
        try? FileManager.default.removeItem(at: folder(id))
    }
    func progress(id: UUID) -> (Int64, Double) {
        guard let job = jobs[id] else { return (0, 0) }
        let committed = job.receipts.values.reduce(Int64(0)) { $0 + $1.bytes }
        let running = inFlightBytes.filter { $0.key.hasPrefix(job.attempt + "|") }.values.reduce(Int64(0), +)
        return (committed + running, Double(job.receipts.count) / Double(job.plan.resources.count) * 0.85)
    }
    /// Recheck hashes off the main actor before the local exporter uses bytes.
    func resources(id: UUID) async throws -> [HLSFilePlaylist.Resource: URL] {
        guard let job = jobs[id], job.ready else { throw DownloadIssue.incompleteMedia }
        let folder = folder(id)
        return try await Task.detached(priority: .utility) {
            var result: [HLSFilePlaylist.Resource: URL] = [:]
            var total: Int64 = 0
            for index in job.plan.resources.indices {
                let file = folder.appendingPathComponent("\(index).part")
                guard let receipt = job.receipts[index], try Self.receipt(file) == receipt else { throw DownloadIssue.incompleteMedia }
                total += receipt.bytes
                guard total <= 2 * 1024 * 1024 * 1024 else { throw HLSFileExportError.limitExceeded }
                result[job.plan.resources[index]] = file
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
        for token in Array(tasks.keys) where DownloadManager.recordID(token) == id {
            tasks.removeValue(forKey: token)?.cancel(); inFlightBytes.removeValue(forKey: token)
        }
    }
    private func enqueue(_ id: UUID) {
        guard restored, let job = jobs[id], !job.paused else { return }
        // Queue the full bounded plan while foreground is available; the daemon
        // can continue without asking this process for the next segment.
        for (index, resource) in job.plan.resources.enumerated() where job.receipts[index] == nil {
            guard !tasks.keys.contains(where: { lookup($0).map { $0.0 == id && $0.1 == index } ?? false }) else { continue }
            let token = job.attempt + "|\(index)|" + UUID().uuidString
            var request = URLRequest(url: resource.url)
            // Background redirects are automatic. Never attach cookies, page
            // URLs, Authorization, or Origin to a request we cannot redirect-scope.
            if let ua = job.userAgent { request.setValue(ua, forHTTPHeaderField: "User-Agent") }
            if let range = resource.range { request.setValue(range.header, forHTTPHeaderField: "Range") }
            let task = session.downloadTask(with: request)
            task.taskDescription = token; tasks[token] = task; task.resume()
        }
    }
    private func lookup(_ token: String) -> (UUID, Int)? {
        let parts = token.split(separator: "|")
        guard parts.count == 4, let id = UUID(uuidString: String(parts[0])), let index = Int(parts[2]),
              let job = jobs[id], job.attempt == parts.prefix(2).joined(separator: "|"),
              job.plan.resources.indices.contains(index) else { return nil }
        return (id, index)
    }
    fileprivate func progress(token: String, bytes: Int64) {
        guard let (id, _) = lookup(token), tasks[token] != nil, let job = jobs[id], !job.paused else { return }
        inFlightBytes[token] = max(0, bytes)
        if bytes > 64 * 1024 * 1024 { failed(token: token, error: HLSFileExportError.limitExceeded); return }
        onChange?(job)
    }
    fileprivate func finished(token: String, staged: URL?, response: URLResponse?, error: Error?) async {
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
        guard let (id, index) = lookup(token), let job = jobs[id], !job.paused, tasks[token] != nil else { return }
        do {
            if let error { throw error }
            guard let staged, let http = response as? HTTPURLResponse, let final = http.url,
                  MediaCookiePolicy.validHTTPURL(final),
                  !(job.plan.resources[index].url.scheme == "https" && final.scheme != "https") else { throw DownloadIssue.invalidMedia }
            let resource = job.plan.resources[index]
            guard http.statusCode == (resource.range == nil ? 200 : 206) else { throw DownloadIssue.http(http.statusCode) }
            guard !MediaFileResponse.isWebPage(http) else { throw DownloadIssue.invalidMedia }
            if let range = resource.range {
                guard http.statusCode == 206,
                      let raw = http.value(forHTTPHeaderField: "Content-Range"), let actual = HLSRelayContentRange(raw),
                      actual.start == range.offset, actual.length == range.length else { throw DownloadIssue.incompleteMedia }
            } else { guard http.statusCode == 200 else { throw DownloadIssue.http(http.statusCode) } }
            let receipt = try await Task.detached(priority: .utility) { try Self.receipt(staged) }.value
            guard let current = jobs[id], current.attempt == job.attempt, !current.paused, tasks[token] != nil else { return }
            guard (http.expectedContentLength < 0 || http.expectedContentLength == receipt.bytes),
                  resource.range == nil || resource.range?.length == receipt.bytes,
                  current.receipts.values.reduce(Int64(0), { $0 + $1.bytes }) + receipt.bytes <= 2 * 1024 * 1024 * 1024 else { throw DownloadIssue.incompleteMedia }
            let target = folder(id).appendingPathComponent("\(index).part")
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: staged, to: target)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            var updated = current; updated.receipts[index] = receipt
            try persist(updated); jobs[id] = updated
            tasks.removeValue(forKey: token); inFlightBytes.removeValue(forKey: token)
            onChange?(updated)
        } catch { failed(token: token, error: error) }
    }
    fileprivate func failed(token: String, error: Error) {
        guard let (id, _) = lookup(token), let job = jobs[id], tasks[token] != nil, !job.paused else { return }
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
    init(staging: URL) { self.staging = staging }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let token = downloadTask.taskDescription else { return }
        Task { @MainActor [weak owner] in owner?.progress(token: token, bytes: totalBytesWritten) }
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
