import Foundation
import Network

/// A foreground-only loopback transport for one inspected HLS asset. Remote URLs
/// and credentials stay in memory; clients can request only registered opaque paths.
@MainActor final class HLSDownloadRelay {
    private(set) var failure: Error?
    private(set) var bytesTransferred: Int64 = 0
    var onBytesTransferred: (@MainActor (Int64) -> Void)?
    private var publishedBytes: Int64 = 0
    private var lastBytesNotification: ContinuousClock.Instant?
    private var pendingBytesNotification: Task<Void, Never>?
    private let client: MediaHTTPClient
    private let sourceScheme: String?
    private let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
    private let queue = DispatchQueue(label: "app.vyu.ios.hls-relay")
    private var listener: NWListener?
    private var ready: CheckedContinuation<Void, Error>?
    private var port: UInt16?
    private var stopped = false
    private var resources: [String: HLSRelayResource] = [:]
    private var paths: [HLSRelayResource: String] = [:]
    private var connections: [UUID: NWConnection] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var activeRequests: Set<UUID> = []
    private var waitingOrder: [UUID] = []
    private var waitingRequests: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(candidate: MediaCandidate, cookies: [HTTPCookie]) {
        client = MediaHTTPClient(candidate: candidate, cookies: cookies)
        sourceScheme = candidate.url.scheme?.lowercased()
    }

    func start(sourceURL: URL) async throws -> URL {
        guard listener == nil, !stopped, MediaCookiePolicy.validHTTPURL(sourceURL),
              !(sourceScheme == "https" && sourceURL.scheme?.lowercased() == "http") else {
            throw DownloadIssue.invalidURL
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue
                    self.ready?.resume(); self.ready = nil
                case .failed(let error):
                    self.failure = error
                    self.ready?.resume(throwing: error); self.ready = nil
                    self.stop()
                case .cancelled:
                    self.ready?.resume(throwing: CancellationError()); self.ready = nil
                default: break
                }
            }
        }
        let startupTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.ready != nil else { return }
            let error = URLError(.timedOut)
            self.failure = error
            self.ready?.resume(throwing: error); self.ready = nil
            self.stop()
        }
        defer { startupTimeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.start(queue: queue)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
        guard !stopped, port != nil else { throw CancellationError() }
        return try register(sourceURL, playlist: true)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        pendingBytesNotification?.cancel(); pendingBytesNotification = nil
        ready?.resume(throwing: CancellationError()); ready = nil
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel(); listener = nil
        for job in jobs.values { job.cancel() }
        for connection in connections.values { connection.cancel() }
        let waiters = Array(waitingRequests.values)
        waitingRequests.removeAll(); waitingOrder.removeAll(); activeRequests.removeAll()
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
        jobs.removeAll(); connections.removeAll()
        resources.removeAll(); paths.removeAll()
        client.close()
    }

    private func register(_ url: URL, playlist: Bool) throws -> URL {
        guard !stopped, let port, MediaCookiePolicy.validHTTPURL(url) else { throw DownloadIssue.invalidURL }
        let resource = HLSRelayResource(url: url, playlist: playlist)
        let path: String
        if let existing = paths[resource] { path = existing }
        else {
            guard resources.count < 10_000 else { throw HLSRelayError.limit }
            path = "/" + token + "/" + UUID().uuidString + (playlist ? ".m3u8" : ".media")
            paths[resource] = path; resources[path] = resource
        }
        return URL(string: "http://127.0.0.1:\(port)" + path)!
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        // AVFoundation opens several connections before submitting its video
        // and audio requests. These sockets must not consume upstream permits.
        guard connections.count < 32 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in
                    self?.jobs[id]?.cancel()
                    self?.cancelWaitingRequest(id)
                }
            default: break
            }
        }
        connection.start(queue: queue)
        jobs[id] = Task { [weak self] in
            guard let self else { connection.cancel(); return }
            let watchdog = Task {
                do {
                    try await Task.sleep(for: .seconds(90))
                    self.jobs[id]?.cancel()
                    self.cancelWaitingRequest(id)
                    connection.cancel()
                }
                catch { }
            }
            defer {
                watchdog.cancel(); connection.stateUpdateHandler = nil; connection.cancel()
                self.cancelWaitingRequest(id)
                self.connections.removeValue(forKey: id); self.jobs.removeValue(forKey: id)
            }
            do {
                let data = try await Self.readHeaders(connection)
                guard let port = self.port,
                      let request = HLSRelayRequest.parse(data, token: self.token, port: port),
                      let resource = self.resources[request.path] else {
                    try await Self.sendError(connection, status: 404); return
                }
                try await self.acquireRequest(id)
                defer { self.releaseRequest(id) }
                var responseStarted = false
                do {
                    try await self.serve(resource, request: request, connection: connection) { responseStarted = true }
                    try await Self.finish(connection)
                }
                catch {
                    guard !self.stopped, !Task.isCancelled else { return }
                    if !(error is NWError) { self.failure = error }
                    if !responseStarted { try? await Self.sendError(connection, status: 502) }
                }
            } catch { /* A local client may cancel a probe or disconnect. */ }
        }
    }

    private func acquireRequest(_ id: UUID) async throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        if activeRequests.count < 4, waitingOrder.isEmpty {
            activeRequests.insert(id)
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !stopped, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError()); return
                }
                waitingOrder.append(id)
                waitingRequests[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaitingRequest(id) }
        }
        do { try Task.checkCancellation() }
        catch {
            // A queued task can be cancelled just after its permit is granted,
            // before its caller has installed the release defer.
            releaseRequest(id)
            throw error
        }
    }

    private func cancelWaitingRequest(_ id: UUID) {
        guard let waiter = waitingRequests.removeValue(forKey: id) else { return }
        waitingOrder.removeAll { $0 == id }
        waiter.resume(throwing: CancellationError())
    }

    private func releaseRequest(_ id: UUID) {
        activeRequests.remove(id)
        guard !stopped else { return }
        while activeRequests.count < 4, !waitingOrder.isEmpty {
            let next = waitingOrder.removeFirst()
            guard let waiter = waitingRequests.removeValue(forKey: next) else { continue }
            guard connections[next] != nil, jobs[next]?.isCancelled == false else {
                waiter.resume(throwing: CancellationError()); continue
            }
            activeRequests.insert(next)
            waiter.resume()
        }
    }

    private func serve(_ resource: HLSRelayResource, request: HLSRelayRequest, connection: NWConnection, responseStarted: () -> Void) async throws {
        // A playlist HEAD still needs rewriting to report its correct local length.
        var upstream = client.request(resource.url, method: resource.playlist ? "GET" : request.method)
        if let range = request.range, !resource.playlist { upstream.setValue(range, forHTTPHeaderField: "Range") }
        let (bytes, response) = try await client.session.bytes(for: upstream)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw DownloadIssue.invalidMedia }
        guard [200, 206].contains(http.statusCode) else { throw DownloadIssue.http(http.statusCode) }
        guard let effectiveURL = response.url, MediaCookiePolicy.validHTTPURL(effectiveURL),
              !(resource.url.scheme?.lowercased() == "https" && effectiveURL.scheme?.lowercased() == "http") else {
            throw DownloadIssue.invalidURL
        }
        let mime = response.mimeType?.lowercased() ?? "application/octet-stream"
        let isPlaylist = resource.playlist || ["application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl"].contains(mime)
        guard !MediaFileResponse.isWebPage(http) else { throw DownloadIssue.invalidMedia }
        let declaredLength = try HLSRelayResponseLength.declared(http)
        if isPlaylist {
            guard http.statusCode == 200, (declaredLength ?? 0) <= 2_000_000 else { throw DownloadIssue.oversizedManifest }
            let data = try await Self.readPlaylist(bytes)
            guard let text = String(data: data, encoding: .utf8) else { throw DownloadIssue.invalidMedia }
            let rewritten = try HLSRelayManifest.rewrite(text, baseURL: effectiveURL) { url, playlist in
                try self.register(url, playlist: playlist)
            }
            let body = Data(rewritten.utf8)
            responseStarted()
            try await Self.sendHeaders(connection, status: 200, mime: "application/vnd.apple.mpegurl", length: Int64(body.count))
            if request.method == "GET" { try await Self.send(connection, data: body) }
            return
        }
        guard (declaredLength ?? 0) <= 64 * 1024 * 1024 else { throw HLSRelayError.limit }
        let contentRange: String?
        let rangeLength: Int64?
        if http.statusCode == 206 {
            guard let requestedRange = request.range, let value = http.value(forHTTPHeaderField: "Content-Range"),
                  let range = HLSRelayContentRange(value), range.matches(requestedRange),
                  declaredLength == nil || declaredLength == range.length else {
                throw DownloadIssue.incompleteMedia
            }
            contentRange = value
            rangeLength = range.length
        } else { contentRange = nil; rangeLength = nil }
        let length = rangeLength ?? declaredLength
        if let length, length > 64 * 1024 * 1024 { throw HLSRelayError.limit }
        if request.method == "HEAD" {
            responseStarted()
            try await Self.sendHeaders(connection, status: http.statusCode, mime: mime, length: length,
                                       contentRange: contentRange, chunked: length == nil)
            return
        }
        // CFNetwork sometimes accepts an interrupted chunked response as a
        // successful partial body, even without its terminating zero chunk.
        // Validate unknown (and zero) lengths before exposing success headers.
        // Disk staging keeps RAM bounded to 64 KiB for each of four requests.
        if length == nil || length == 0 {
            let staged = try await Self.stageBody(bytes, expectedLength: length)
            defer { try? FileManager.default.removeItem(at: staged.directory) }
            responseStarted()
            try await Self.sendHeaders(connection, status: http.statusCode, mime: mime,
                                       length: staged.length, contentRange: contentRange)
            try await Self.sendStagedBody(staged.url, connection: connection) { [weak self] count in
                await self?.recordTransferredBytes(count)
            }
            return
        }
        responseStarted()
        try await Self.sendHeaders(connection, status: http.statusCode, mime: mime, length: length, contentRange: contentRange)
        try await Self.streamBody(bytes, connection: connection, length: length, chunked: false) { [weak self] count in
            await self?.recordTransferredBytes(count)
        }
    }

    private nonisolated static func stageBody(_ bytes: URLSession.AsyncBytes, expectedLength: Int64?) async throws -> (directory: URL, url: URL, length: Int64) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-relay-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var kept = false
        defer { if !kept { try? FileManager.default.removeItem(at: directory) } }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        let url = directory.appendingPathComponent("body")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw DownloadIssue.incompleteMedia
        }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        var protected = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var chunk = Data(); chunk.reserveCapacity(65_536)
        var total: Int64 = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            guard total < 64 * 1024 * 1024 else { throw HLSRelayError.limit }
            if let expectedLength, total >= expectedLength { throw DownloadIssue.incompleteMedia }
            chunk.append(byte); total += 1
            if chunk.count == 65_536 {
                try handle.write(contentsOf: chunk); chunk.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        if let expectedLength, total != expectedLength { throw DownloadIssue.incompleteMedia }
        if !chunk.isEmpty { try handle.write(contentsOf: chunk) }
        try handle.synchronize()
        kept = true
        return (directory, url, total)
    }

    private nonisolated static func sendStagedBody(_ url: URL, connection: NWConnection,
                                                  onChunkSent: @Sendable (Int64) async -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
            try Task.checkCancellation()
            try await Self.send(connection, data: data)
            await onChunkSent(Int64(data.count))
        }
    }

    private func recordTransferredBytes(_ count: Int64) {
        guard count > 0 else { return }
        let (total, overflow) = bytesTransferred.addingReportingOverflow(count)
        bytesTransferred = overflow ? .max : total
        // A completed Network send can race with stop. Keep its accounting,
        // while never publishing another UI callback after cancellation.
        guard !stopped else { return }
        let now = ContinuousClock.now
        guard let last = lastBytesNotification, now < last.advanced(by: .milliseconds(250)) else {
            publishTransferredBytes()
            return
        }
        // Coalesce all four upstream transfers into one UI notification. A
        // trailing notification includes the last body chunk even if no more
        // chunks arrive; media delivery never waits for the UI throttle.
        guard pendingBytesNotification == nil else { return }
        let deadline = last.advanced(by: .milliseconds(250))
        pendingBytesNotification = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.pendingBytesNotification = nil
            self.publishTransferredBytes()
        }
    }

    private func publishTransferredBytes() {
        guard !stopped, bytesTransferred > publishedBytes else { return }
        pendingBytesNotification?.cancel(); pendingBytesNotification = nil
        lastBytesNotification = .now
        publishedBytes = bytesTransferred
        onBytesTransferred?(bytesTransferred)
    }

    // AsyncBytes yields individual bytes. Keep iteration off MainActor so each
    // next() does not need to return to the UI executor before reading the next.
    private nonisolated static func readPlaylist(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 2_000_000 else { throw DownloadIssue.oversizedManifest }
            data.append(byte)
        }
        return data
    }

    private nonisolated static func streamBody(_ bytes: URLSession.AsyncBytes, connection: NWConnection,
                                              length: Int64?, chunked: Bool,
                                              onChunkSent: @Sendable (Int64) async -> Void) async throws {
        // Bound memory to one 64 KiB chunk per connection. Each send completes
        // before the next chunk is read, applying TCP backpressure to URLSession.
        var chunk = Data(); chunk.reserveCapacity(65_536)
        var total: Int64 = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            guard total < 64 * 1024 * 1024 else { throw HLSRelayError.limit }
            if let length, total >= length { throw DownloadIssue.incompleteMedia }
            chunk.append(byte); total += 1
            // Hold the final known-length chunk until upstream completion is
            // checked, so a client cannot finish before a late transfer error.
            if chunk.count == 65_536, length.map({ total < $0 }) ?? true {
                try await Self.send(connection, data: chunked ? HLSRelayChunkEncoding.encode(chunk) : chunk)
                await onChunkSent(Int64(chunk.count))
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if let length, total != length { throw DownloadIssue.incompleteMedia }
        if !chunk.isEmpty {
            try await Self.send(connection, data: chunked ? HLSRelayChunkEncoding.encode(chunk) : chunk)
            await onChunkSent(Int64(chunk.count))
        }
        // Only a fully read and validated upstream body gets the terminal chunk.
        // Closing an interrupted stream without it is an HTTP framing error.
        if chunked { try await Self.send(connection, data: HLSRelayChunkEncoding.end) }
    }

    private nonisolated static func readHeaders(_ connection: NWConnection) async throws -> Data {
        var result = Data()
        while result.count < 16_384 {
            let next: (Data?, Bool) = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: min(4096, 16_384 - result.count)) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: (data, complete)) }
                }
            }
            if let data = next.0 { result.append(data) }
            if result.range(of: Data("\r\n\r\n".utf8)) != nil { return result }
            if next.1 { break }
        }
        throw HLSRelayError.invalidRequest
    }

    private nonisolated static func sendHeaders(_ connection: NWConnection, status: Int, mime: String, length: Int64?, contentRange: String? = nil, chunked: Bool = false) async throws {
        guard !mime.contains("\r"), !mime.contains("\n"), mime.utf8.count < 256 else { throw DownloadIssue.invalidMedia }
        var headers = "HTTP/1.1 \(status) \(status == 206 ? "Partial Content" : "OK")\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: \(mime)\r\nAccept-Ranges: bytes\r\n"
        if let length { headers += "Content-Length: \(length)\r\n" }
        else if chunked { headers += "Transfer-Encoding: chunked\r\n" }
        if let contentRange { headers += "Content-Range: \(contentRange)\r\n" }
        headers += "\r\n"
        try await send(connection, data: Data(headers.utf8))
    }

    private nonisolated static func sendError(_ connection: NWConnection, status: Int) async throws {
        try await send(connection, data: Data("HTTP/1.1 \(status) Error\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
    }

    private nonisolated static func send(_ connection: NWConnection, data: Data) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private nonisolated static func finish(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}

private struct HLSRelayResource: Hashable {
    let url: URL
    let playlist: Bool
}

enum HLSRelayError: LocalizedError {
    case invalidRequest, limit, unsupportedManifest
    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "本机视频传输请求无效。"
        case .limit: return "视频清单或单个分片超出当前保存上限。"
        case .unsupportedManifest: return "此播放清单包含当前不能离线保存的引用。"
        }
    }
}

struct HLSRelayRequest {
    let method: String
    let path: String
    let range: String?

    static func parse(_ data: Data, token: String, port: UInt16) -> HLSRelayRequest? {
        guard data.count <= 16_384, let text = String(data: data, encoding: .utf8),
              let ending = text.range(of: "\r\n\r\n"), ending.upperBound == text.endIndex else { return nil }
        let lines = text[..<ending.lowerBound].components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let fields = first.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3, ["GET", "HEAD"].contains(String(fields[0])),
              ["HTTP/1.1", "HTTP/1.0"].contains(String(fields[2])) else { return nil }
        let path = String(fields[1])
        guard path.hasPrefix("/" + token + "/"), !path.contains("?"), !path.contains("#"),
              !path.contains("%"), !path.contains(".."), path.utf8.count <= 256 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let separator = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<separator]).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard headers[name] == nil, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            headers[name] = value
        }
        guard headers["host"] == "127.0.0.1:\(port)", headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0" else { return nil }
        if let range = headers["range"], !validRange(range) { return nil }
        return HLSRelayRequest(method: String(fields[0]), path: path, range: headers["range"])
    }

    static func validRange(_ value: String) -> Bool {
        guard value.hasPrefix("bytes="), value.utf8.count <= 64 else { return false }
        let pieces = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces.allSatisfy({ $0.allSatisfy({ $0 >= "0" && $0 <= "9" }) }) else { return false }
        if pieces[0].isEmpty { return Int64(pieces[1]).map { $0 > 0 } ?? false }
        guard let start = Int64(pieces[0]), start >= 0 else { return false }
        return pieces[1].isEmpty || (Int64(pieces[1]).map { $0 >= start } ?? false)
    }

    static func validContentRange(_ value: String) -> Bool {
        HLSRelayContentRange(value) != nil
    }
}

enum HLSRelayChunkEncoding {
    static let end = Data("0\r\n\r\n".utf8)

    static func encode(_ data: Data) -> Data {
        // An empty buffer is not a data chunk: only `end` completes a response.
        guard !data.isEmpty else { return Data() }
        var chunk = Data((String(data.count, radix: 16) + "\r\n").utf8)
        chunk.append(data)
        chunk.append(Data("\r\n".utf8))
        return chunk
    }
}

/// URLResponse.expectedContentLength may be inferred or normalized after a
/// transfer error. Only explicit, undecoded HTTP framing describes our body.
enum HLSRelayResponseLength {
    static func declared(_ response: HTTPURLResponse) throws -> Int64? {
        if response.value(forHTTPHeaderField: "Transfer-Encoding") != nil { return nil }
        if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"),
           encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "identity" { return nil }
        guard let raw = response.value(forHTTPHeaderField: "Content-Length") else { return nil }
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.utf8.count <= 19, value.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let length = Int64(value) else { throw DownloadIssue.incompleteMedia }
        return length
    }
}

struct HLSRelayContentRange {
    let start: Int64
    let end: Int64
    let total: Int64
    var length: Int64 { end - start + 1 }

    init?(_ value: String) {
        guard value.hasPrefix("bytes "), value.utf8.count <= 96 else { return nil }
        let pieces = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[1].allSatisfy({ $0 >= "0" && $0 <= "9" }), let total = Int64(pieces[1]), total > 0 else { return nil }
        let bounds = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, bounds.allSatisfy({ $0.allSatisfy({ $0 >= "0" && $0 <= "9" }) }),
              let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, end >= start, end < total else { return nil }
        self.start = start; self.end = end; self.total = total
    }

    func matches(_ requested: String) -> Bool {
        guard HLSRelayRequest.validRange(requested) else { return false }
        let bounds = requested.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        if bounds[0].isEmpty {
            guard let suffix = Int64(bounds[1]) else { return false }
            return start == max(0, total - suffix) && end == total - 1
        }
        guard let requestedStart = Int64(bounds[0]), requestedStart < total else { return false }
        let requestedEnd = bounds[1].isEmpty ? total - 1 : min(Int64(bounds[1])!, total - 1)
        return start == requestedStart && end == requestedEnd
    }
}

enum HLSRelayManifest {
    static func rewrite(_ text: String, baseURL: URL, register: (URL, Bool) throws -> URL) throws -> String {
        let manifest = try HLSManifest.parse(text, relativeTo: baseURL)
        guard !manifest.encrypted else { throw DownloadIssue.protectedContent }
        if !manifest.isMaster {
            guard manifest.isVOD else { throw DownloadIssue.playlistProblem(.main, .live) }
            guard manifest.duration.isFinite, manifest.duration > 0 else { throw DownloadIssue.invalidMedia }
        }
        let pattern = try NSRegularExpression(pattern: #"(?:[:,])\s*URI="([^"]*)""#)
        var nextIsPlaylist = false
        var result: [String] = []
        func resolved(_ raw: String) throws -> URL {
            guard !raw.isEmpty, !raw.contains("{$"), let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
                  MediaCookiePolicy.validHTTPURL(url), !(baseURL.scheme?.lowercased() == "https" && url.scheme?.lowercased() == "http") else {
                throw DownloadIssue.invalidURL
            }
            return url
        }
        for original in text.components(separatedBy: .newlines) {
            var line = original.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-DEFINE:") || line.hasPrefix("#EXT-X-CONTENT-STEERING:") { throw HLSRelayError.unsupportedManifest }
            if line.hasPrefix("#") {
                let matches = pattern.matches(in: line, range: NSRange(line.startIndex..., in: line))
                if line.contains("URI="), matches.isEmpty { throw HLSRelayError.unsupportedManifest }
                for match in matches.reversed() {
                    guard let range = Range(match.range(at: 1), in: line) else { throw HLSRelayError.unsupportedManifest }
                    let url = try resolved(String(line[range]))
                    let playlist = line.hasPrefix("#EXT-X-MEDIA:") || line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") || line.hasPrefix("#EXT-X-RENDITION-REPORT:") || url.pathExtension.lowercased() == "m3u8"
                    let local = try register(url, playlist)
                    line.replaceSubrange(range, with: local.absoluteString)
                }
                if line.hasPrefix("#EXT-X-STREAM-INF:") { nextIsPlaylist = true }
            } else if !line.isEmpty {
                let url = try resolved(line)
                line = try register(url, nextIsPlaylist || url.pathExtension.lowercased() == "m3u8").absoluteString
                nextIsPlaylist = false
            }
            result.append(line)
        }
        return result.joined(separator: "\n")
    }
}
