import Combine
import Foundation
import Network
import XCTest
@testable import VYu

@MainActor final class DownloadBatchTests: XCTestCase {
    private var managers: [DownloadManager] = []
    private var servers: [BatchResponseGate] = []

    override func tearDown() async throws {
        for manager in managers {
            manager.pauseDownloads(ids: Set(manager.records.map(\.id)))
            for id in manager.records.map(\.id) { manager.removeRecord(id: id) }
            try? FileManager.default.removeItem(at: manager.rootDirectory)
        }
        for server in servers { server.stop() }
        managers = []; servers = []
    }

    func testRepeatedResumeAllIsBoundedAndBatchPauseClearsEveryWaitingIntention() async throws {
        let server = try await gate()
        let (manager, ids) = try seeded(url: server.url, phases: Array(repeating: .paused, count: 5) + [.failed, .cancelled, .complete], kind: .hls)
        let untouched = Array(manager.records.suffix(3))
        manager.resumeAllDownloads()
        manager.resumeAllDownloads()
        XCTAssertEqual(manager.pendingResumeIDs, Set(ids.prefix(5)))
        XCTAssertFalse(manager.hasActiveDownloads, "A waiting queue has not started network work.")
        try await waitUntil("only two HLS preflights start") { server.requests.count == 2 }
        XCTAssertEqual(manager.records.filter { $0.phase == .queued }.count, 2)
        XCTAssertEqual(manager.pendingResumeIDs.count, 3)
        XCTAssertTrue(manager.hasActiveDownloads)
        XCTAssertTrue(manager.pendingResumeIDs.allSatisfy { manager.canPause(id: $0) && !manager.canResume(id: $0) })
        XCTAssertTrue(manager.pendingResumeIDs.allSatisfy { manager.resumeBlockReason(id: $0) == nil })
        manager.resumeAllDownloads()
        manager.pauseDownloads(ids: Set(ids))
        XCTAssertTrue(manager.pendingResumeIDs.isEmpty)
        XCTAssertFalse(manager.hasActiveDownloads)
        server.release()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(server.requests.count, 2, "A late preflight must not launch waiting or paused tasks.")
        XCTAssertTrue(manager.records.prefix(5).allSatisfy { $0.phase == .paused && $0.localRelativePath == nil })
        XCTAssertEqual(Array(manager.records.suffix(3)), untouched)
    }

    func testFailedBatchSlotAdvancesQueueWithoutRetryingTerminalRecordsOrDuplicatingRequests() async throws {
        let server = try await gate()
        let (manager, ids) = try seeded(url: server.url, phases: Array(repeating: .paused, count: 5) + [.cancelled, .complete])
        let untouched = Array(manager.records.suffix(2))
        manager.resumeAllDownloads()
        try await waitUntil("first slots have real preflights") { server.requests.count == 2 }
        XCTAssertEqual(manager.pendingResumeIDs.count, 3)
        manager.resumeDownloads(ids: Set(ids))
        server.release()
        try await waitUntil("all resumed candidates fail exactly once") { manager.records.prefix(5).allSatisfy { $0.phase == .failed } }
        XCTAssertTrue(manager.pendingResumeIDs.isEmpty)
        XCTAssertFalse(manager.hasActiveDownloads)
        XCTAssertEqual(Array(manager.records.suffix(2)), untouched)
        for index in 0..<5 {
            XCTAssertEqual(server.requests.filter { $0 == "HEAD /video-\(index).mp4" }.count, 1)
            XCTAssertEqual(server.requests.filter { $0 == "GET /video-\(index).mp4" }.count, 1)
        }
        manager.resumeAllDownloads()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.requests.count, 10)
    }

    func testCancellingQueuedAndWaitingResumesCannotRestartOnLateResponse() async throws {
        let server = try await gate()
        let (manager, ids) = try seeded(url: server.url, phases: Array(repeating: .paused, count: 4))
        manager.resumeAllDownloads()
        try await waitUntil("two queued preflights reach gate") { server.requests.count == 2 }
        // Cancel both active preflights and both waiting entries in one actor turn.
        for id in ids { manager.cancel(id: id) }
        XCTAssertTrue(manager.pendingResumeIDs.isEmpty)
        XCTAssertFalse(manager.hasActiveDownloads)
        server.release()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertTrue(manager.records.allSatisfy { $0.phase == .cancelled && $0.localRelativePath == nil })
        XCTAssertTrue(ids.allSatisfy { !manager.canResume(id: $0) && !manager.canPause(id: $0) })
    }

    func testResumeDoesNotUseMissingAuthorizationOrSyntheticImportSources() async throws {
        let server = try await gate()
        let root = temporaryRoot()
        let cookieID = UUID(), localID = UUID(), cloudID = UUID()
        let records = [(cookieID, "fixture"), (localID, "localImport"), (cloudID, "iCloud")].map { id, source in
            makeRecord(id: id, url: server.url.deletingLastPathComponent().appendingPathComponent("\(source).mp4"),
                       phase: .paused, source: source)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: root.appendingPathComponent("downloads.json"))
        try JSONEncoder().encode([cookieID]).write(to: root.appendingPathComponent("transfer-modes.json"))
        let manager = DownloadManager(rootDirectory: root); managers.append(manager)
        let resumeData = root.appendingPathComponent("Resume/\(cookieID.uuidString).data")
        try Data("synthetic expired resume context".utf8).write(to: resumeData)
        manager.resumeAllDownloads()
        for id in [cookieID, localID, cloudID] { XCTAssertFalse(manager.canResume(id: id)) }
        XCTAssertEqual(manager.resumeBlockReason(id: cookieID), "登录状态已失效，请回到网页重新登录后重试。")
        XCTAssertNotNil(manager.resumeBlockReason(id: localID))
        XCTAssertNotNil(manager.resumeBlockReason(id: cloudID))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(manager.records, records)
        XCTAssertTrue(manager.pendingResumeIDs.isEmpty)
        XCTAssertFalse(manager.hasActiveDownloads)
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resumeData.path), "Bulk continuation must leave skipped records untouched.")

        manager.resume(id: cookieID)
        let failed = try XCTUnwrap(manager.records.first { $0.id == cookieID })
        XCTAssertEqual(failed.phase, .failed, "Direct continuation must preserve the existing fresh-webpage retry path.")
        XCTAssertEqual(failed.failure, "登录状态已失效，请回到网页重新登录后重试。")
        XCTAssertNil(BrowserDownloadPolicy.existingDownload(failed.candidate, in: manager),
                     "The next explicit webpage selection must be able to collect fresh request context.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: resumeData.path))
        XCTAssertTrue(manager.records.filter { $0.id != cookieID }.allSatisfy { $0.phase == .paused })
        XCTAssertTrue(manager.pendingResumeIDs.isEmpty)
        XCTAssertFalse(manager.hasActiveDownloads)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(server.requests.isEmpty, "Expired authorization must never start a request.")
    }

    func testPausingThenResumingPreflightDoesNotLetOldCleanupClearTheNewAttempt() async throws {
        let server = try await gate()
        let (manager, ids) = try seeded(url: server.url, phases: [.paused], kind: .hls)
        let id = try XCTUnwrap(ids.first)
        manager.resume(id: id)
        try await waitUntil("first preflight is held") { server.requests.count == 1 }
        manager.pause(id: id)
        manager.resume(id: id)
        manager.resume(id: id)
        try await waitUntil("new preflight is held independently") { server.requests.count == 2 }
        XCTAssertTrue(manager.hasActiveDownloads)
        XCTAssertTrue(manager.canPause(id: id))
        XCTAssertTrue(manager.pendingResumeIDs.isEmpty)
        server.release()
        try await waitUntil("only the current preflight reaches failure") { manager.records.first?.phase == .failed }
        XCTAssertEqual(manager.records.count, 1)
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertFalse(manager.hasActiveDownloads)
        XCTAssertFalse(manager.canResume(id: id))
    }

    func testConfirmationOnlyInspectionNeverCountsAsAnActiveDownload() async throws {
        let server = try await gate()
        let manager = DownloadManager(rootDirectory: temporaryRoot()); managers.append(manager)
        let source = makeRecord(url: server.url, phase: .paused).candidate
        let inspection = Task { await manager.inspect(candidate: source, cookies: []) }
        try await waitUntil("confirmation inspection reaches gate") { server.requests.count == 1 }
        XCTAssertFalse(manager.hasActiveDownloads, "Inspecting a confirmation does not authorize or start a download.")
        XCTAssertTrue(manager.records.isEmpty)
        server.release()
        let result = await inspection.value
        XCTAssertFalse(result.downloadable)
        XCTAssertFalse(manager.hasActiveDownloads)
    }

    func testPausedPreflightRetainsAuthorizedCookieAcrossAnInScopeRedirectOnly() async throws {
        for target in ["/scoped/target.mp4", "/outside/target.mp4"] {
            let server = BatchResponseGate(redirectTarget: target); servers.append(server)
            try await server.start()
            let manager = DownloadManager(rootDirectory: temporaryRoot()); managers.append(manager)
            let url = server.url.deletingLastPathComponent().appendingPathComponent("scoped/start.mp4")
            let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "batch_fixture", .value: "authorized",
                .domain: "127.0.0.1", .path: "/scoped"]))
            let start = Task { await manager.start(candidate: makeRecord(url: url, phase: .paused).candidate, cookies: [cookie]) }
            try await waitUntil("authorized preflight reaches gate") { server.requests.count == 1 }
            let id = try XCTUnwrap(manager.records.first?.id)
            manager.pause(id: id)
            XCTAssertTrue(manager.canResume(id: id), "Pausing preflight must retain its valid authorization scope.")
            manager.resume(id: id)
            try await waitUntil("authorized preflight resumes") { server.requests.count == 2 }
            server.release()
            await start.value
            try await waitUntil("redirect is checked and synthetic payload is rejected", timeout: 30) {
                manager.records.first?.phase == .failed
            }
            XCTAssertEqual(server.receivedScopedCookie["HEAD /scoped/start.mp4"], true)
            XCTAssertEqual(server.receivedScopedCookie["HEAD " + target], target.hasPrefix("/scoped/"))
            if target.hasPrefix("/scoped/") {
                XCTAssertEqual(server.receivedScopedCookie["GET " + target], true,
                               "The valid in-scope preflight must reach the real transfer with the same scope.")
                XCTAssertEqual(manager.records.first?.expectedBytes, 9)
            } else {
                XCTAssertTrue(manager.records.first?.failure?.contains("403") == true)
            }
            XCTAssertFalse(manager.hasActiveDownloads)
        }
    }

    func testPauseResumePauseBeforeResumeDataReturnsDoesNotRestartTransfer() async throws {
        let fixture = URL(string: "http://127.0.0.1:8765/slow.mp4")!
        try await requireFixtures()
        let manager = DownloadManager(rootDirectory: temporaryRoot()); managers.append(manager)
        await manager.start(candidate: makeRecord(url: fixture, phase: .paused).candidate, cookies: [])
        let id = try XCTUnwrap(manager.records.first?.id)
        try await waitUntil("slow fixture has started receiving bytes") { (manager.records.first?.bytesWritten ?? 0) >= 16_384 }
        XCTAssertTrue(manager.hasActiveDownloads)
        manager.pause(id: id)
        manager.resume(id: id)
        manager.pauseDownloads(ids: [id])
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(manager.records.first?.phase, .paused)
        XCTAssertTrue(manager.pendingResumeIDs.isEmpty)
        XCTAssertFalse(manager.hasActiveDownloads)
        XCTAssertTrue(manager.canResume(id: id))
    }

    func testCompletedTransferReleasesActivityAfterValidation() async throws {
        try await requireFixtures()
        let manager = DownloadManager(rootDirectory: temporaryRoot()); managers.append(manager)
        var activity: [Bool] = []
        let observation = manager.$hasActiveDownloads.sink { activity.append($0) }
        defer { observation.cancel() }
        let source = makeRecord(url: URL(string: "http://127.0.0.1:8765/media/direct.mp4")!, phase: .paused).candidate
        await manager.start(candidate: source, cookies: [])
        try await waitUntil("download and asset validation complete", timeout: 45) {
            [.complete, .failed].contains(manager.records.first?.phase ?? .queued)
        }
        let record = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(record.phase, .complete, record.failure ?? "")
        XCTAssertNotNil(manager.localURL(for: record))
        XCTAssertTrue(activity.contains(true))
        XCTAssertFalse(manager.hasActiveDownloads)
        XCTAssertEqual(activity.last, false)
        manager.resumeAllDownloads()
        XCTAssertFalse(manager.hasActiveDownloads)
        XCTAssertTrue(manager.pendingResumeIDs.isEmpty)
    }

    private func seeded(url: URL, phases: [DownloadPhase], kind: MediaKind = .file) throws -> (DownloadManager, [UUID]) {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Media"), withIntermediateDirectories: true)
        var records: [DownloadRecord] = []
        for (index, phase) in phases.enumerated() {
            var record = makeRecord(url: url.deletingLastPathComponent().appendingPathComponent("video-\(index).mp4"), phase: phase, kind: kind)
            if phase == .complete {
                record.localRelativePath = "Media/finished.mp4"
                try Data("synthetic existing file".utf8).write(to: root.appendingPathComponent("Media/finished.mp4"))
            }
            records.append(record)
        }
        try JSONEncoder().encode(records).write(to: root.appendingPathComponent("downloads.json"))
        let manager = DownloadManager(rootDirectory: root); managers.append(manager)
        return (manager, records.map(\.id))
    }

    private func makeRecord(id: UUID = UUID(), url: URL, phase: DownloadPhase, source: String = "fixture", kind: MediaKind = .file) -> DownloadRecord {
        let candidate = MediaCandidate(url: url, pageURL: url, frameURL: url, title: "Generated batch test", kind: kind, source: source)
        return DownloadRecord(id: id, candidate: candidate, phase: phase, progress: 0, bytesWritten: 0,
            expectedBytes: nil, localRelativePath: nil, failure: nil, duration: nil, hasAudio: nil, createdAt: Date())
    }
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("VYu-batch-" + UUID().uuidString)
    }
    private func gate() async throws -> BatchResponseGate {
        let server = BatchResponseGate(); servers.append(server)
        try await server.start(); return server
    }
    private func waitUntil(_ reason: String, timeout: TimeInterval = 15, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        guard predicate() else { XCTFail(reason); throw TestFailure.timeout }
    }
    private func requireFixtures() async throws {
        let url = URL(string: "http://127.0.0.1:8765/__health")!
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let health = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(health["ready"] as? Bool, true)
            XCTAssertEqual(health["offline"] as? Bool, false)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw XCTSkip("Start the generated fixture server to run actual transfer tests.")
        }
    }
    private enum TestFailure: Error { case timeout }
}

/// All requests stay on loopback and wait until the test explicitly releases them.
@MainActor private final class BatchResponseGate {
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var readiness: CheckedContinuation<Void, Error>?
    private var released = false
    private let redirectTarget: String?
    private var requestKeys: [UUID: String] = [:]
    private(set) var requests: [String] = []
    private(set) var receivedScopedCookie: [String: Bool] = [:]
    private(set) var url = URL(string: "http://127.0.0.1/unused.mp4")!

    init(redirectTarget: String? = nil) { self.redirectTarget = redirectTarget }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = listener?.port {
                        self.url = URL(string: "http://127.0.0.1:\(port.rawValue)/media.mp4")!
                        self.readiness?.resume(); self.readiness = nil
                    }
                case .failed(let error): self.readiness?.resume(throwing: error); self.readiness = nil
                case .cancelled: self.readiness?.resume(throwing: CancellationError()); self.readiness = nil
                default: break
                }
            }
        }
        try await withCheckedThrowingContinuation { continuation in
            readiness = continuation; listener.start(queue: .main)
        }
    }
    func release() {
        released = true
        for (id, connection) in connections { respond(id, connection) }
    }
    func stop() {
        readiness?.resume(throwing: CancellationError()); readiness = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
    }
    private func accept(_ connection: NWConnection) {
        let id = UUID(); connections[id] = connection
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { connection.cancel(); return }
                guard error == nil, let data, let text = String(data: data, encoding: .utf8) else {
                    self.connections.removeValue(forKey: id); connection.cancel(); return
                }
                let words = text.split(separator: "\r\n").first?.split(separator: " ") ?? []
                if words.count >= 2 {
                    let key = "\(words[0]) \(words[1])"
                    self.requests.append(key)
                    self.requestKeys[id] = key
                    // Keep only a boolean about the synthetic test credential.
                    self.receivedScopedCookie[key] = text.components(separatedBy: "\r\n")
                        .contains { $0.lowercased().hasPrefix("cookie:") && $0.contains("batch_fixture=authorized") }
                }
                if self.released { self.respond(id, connection) }
            }
        }
    }
    private func respond(_ id: UUID, _ connection: NWConnection) {
        connections.removeValue(forKey: id)
        let key = requestKeys.removeValue(forKey: id) ?? ""
        let text: String
        if let redirectTarget, key.hasSuffix(" /scoped/start.mp4") {
            text = "HTTP/1.1 302 Found\r\nLocation: \(redirectTarget)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        } else if let redirectTarget, key.hasSuffix(" " + redirectTarget), receivedScopedCookie[key] == true {
            text = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: 9\r\nConnection: close\r\n\r\n" + (key.hasPrefix("HEAD ") ? "" : "synthetic")
        } else {
            text = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }
        let response = Data(text.utf8)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
