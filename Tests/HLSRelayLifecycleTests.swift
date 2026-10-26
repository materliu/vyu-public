import Foundation
import Network
import XCTest
@testable import VYu

/// A gated loopback redirect makes the preflight/lifecycle race deterministic.
/// The target is generated fixture media; no real browser or account data is read.
@MainActor final class HLSRelayLifecycleTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8765")!
    private var managers: [DownloadManager] = []
    private var servers: [GatedHLSRedirectServer] = []

    override func setUp() async throws {
        continueAfterFailure = false
        let result: (Data, URLResponse)
        do { result = try await URLSession.shared.data(from: base.appendingPathComponent("__health")) }
        catch let error as URLError where error.code == .cannotConnectToHost {
            throw XCTSkip("Generate fixture media and start fixtures/server.py before HLS lifecycle tests.")
        }
        let health = try XCTUnwrap(JSONSerialization.jsonObject(with: result.0) as? [String: Any])
        XCTAssertEqual((result.1 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(health["ready"] as? Bool, true)
        var request = URLRequest(url: base.appendingPathComponent("__control"))
        request.httpMethod = "POST"; request.httpBody = Data("{\"offline\":false}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    override func tearDown() async throws {
        for manager in managers {
            for id in manager.records.map(\.id) { manager.removeRecord(id: id) }
            try? FileManager.default.removeItem(at: manager.rootDirectory)
        }
        managers = []
        for server in servers { server.stop() }
        servers = []
    }

    func testBackgroundDuringPreflightStaysPausedUntilForegroundResume() async throws {
        let (server, source) = try await gatedSource()
        let manager = makeManager()
        let start = Task { await manager.start(candidate: source, cookies: []) }
        try await waitUntil("HLS inspection reached the response gate") { server.requestCount == 1 }
        let id = try XCTUnwrap(manager.records.first?.id)
        XCTAssertEqual(manager.records.first?.phase, .queued)

        manager.setAppInBackground(true)
        XCTAssertEqual(manager.records.first?.phase, .paused)
        server.releaseResponses()
        await start.value
        XCTAssertEqual(manager.records.first?.phase, .paused,
                       "A late inspection result must not start a foreground relay in background.")
        XCTAssertNil(manager.records.first?.localRelativePath)
        manager.resume(id: id)
        await Task.yield()
        XCTAssertEqual(manager.records.first?.phase, .paused)
        XCTAssertEqual(server.requestCount, 1, "Resume in background must not restart inspection.")

        manager.setAppInBackground(false)
        manager.resume(id: id)
        try await waitUntil("foreground retry finishes", timeout: 60) {
            guard let phase = manager.records.first?.phase else { return false }
            return phase == .complete || phase == .failed
        }
        let record = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(record.phase, .complete, record.failure ?? "")
        XCTAssertGreaterThanOrEqual(server.requestCount, 2, "Continuation starts a fresh inspected transfer.")
        XCTAssertEqual(record.duration ?? 0, 8, accuracy: 0.25)
        XCTAssertNotNil(manager.localURL(for: record))
    }

    func testCancelledPreflightCannotRecreateRelayOrDownloadedRecord() async throws {
        let (server, source) = try await gatedSource()
        let manager = makeManager()
        let start = Task { await manager.start(candidate: source, cookies: []) }
        try await waitUntil("inspection waits for response") { server.requestCount == 1 }
        let id = try XCTUnwrap(manager.records.first?.id)
        manager.cancel(id: id)
        server.releaseResponses()
        await start.value
        let record = try XCTUnwrap(manager.records.first)
        XCTAssertEqual(record.phase, .cancelled)
        XCTAssertNil(record.localRelativePath)
        XCTAssertNil(manager.localURL(for: record))
        XCTAssertEqual(server.requestCount, 1)
    }

    func testStartingInBackgroundDoesNotEvenRequestThePlaylist() async throws {
        let (server, source) = try await gatedSource()
        let manager = makeManager()
        manager.setAppInBackground(true)
        await manager.start(candidate: source, cookies: [])
        let id = try XCTUnwrap(manager.records.first?.id)
        manager.resume(id: id)
        await Task.yield()
        XCTAssertEqual(manager.records.first?.phase, .paused)
        XCTAssertEqual(server.requestCount, 0)
        XCTAssertNil(manager.records.first?.localRelativePath)
    }

    func testInterruptedForegroundRecordDiscardsItsPartialPackageOnRestore() async throws {
        let root = temporaryRoot()
        let partial = root.appendingPathComponent("Media/partial.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("unfinished fixture package".utf8).write(to: partial.appendingPathComponent("partial.data"))
        let source = candidate(base.appendingPathComponent("media/hls/master.m3u8"))
        let record = DownloadRecord(id: UUID(), candidate: source, phase: .downloading, progress: 0.2,
            bytesWritten: 20, expectedBytes: nil, localRelativePath: "Media/partial.movpkg", failure: nil,
            duration: nil, hasAudio: nil, createdAt: Date())
        try JSONEncoder().encode([record]).write(to: root.appendingPathComponent("downloads.json"))
        let manager = DownloadManager(rootDirectory: root); managers.append(manager)
        try await waitUntil("restored foreground transfer fails without a live relay") {
            manager.records.first?.phase == .failed
        }
        XCTAssertNil(manager.records.first?.localRelativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertNil(manager.localURL(for: manager.records[0]))
    }

    private func gatedSource() async throws -> (GatedHLSRedirectServer, MediaCandidate) {
        let server = GatedHLSRedirectServer(destination: base.appendingPathComponent("media/hls/180p/index.m3u8"))
        servers.append(server)
        return (server, candidate(try await server.start()))
    }

    private func candidate(_ url: URL) -> MediaCandidate {
        MediaCandidate(url: url, pageURL: base.appendingPathComponent("hls"), frameURL: base.appendingPathComponent("hls"),
            title: "Generated lifecycle video", kind: .hls, source: "video",
            requestContext: MediaRequestContext(corsMode: .none, referrerPolicy: .strictOriginWhenCrossOrigin))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("VYu-hls-lifecycle-" + UUID().uuidString)
    }

    private func makeManager() -> DownloadManager {
        let manager = DownloadManager(rootDirectory: temporaryRoot()); managers.append(manager); return manager
    }

    private func waitUntil(_ reason: String, timeout: TimeInterval = 15, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard predicate() else { XCTFail(reason); throw LifecycleFailure.timeout }
    }

    private enum LifecycleFailure: Error { case timeout }
}

@MainActor private final class GatedHLSRedirectServer {
    private let destination: URL
    private var listener: NWListener?
    private var pending: [UUID: NWConnection] = [:]
    private var readiness: CheckedContinuation<URL, Error>?
    private var released = false
    private(set) var requestCount = 0

    init(destination: URL) { self.destination = destination }

    func start() async throws -> URL {
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
                        self.readiness?.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/master.m3u8")!)
                        self.readiness = nil
                    }
                case .failed(let error): self.readiness?.resume(throwing: error); self.readiness = nil
                case .cancelled: self.readiness?.resume(throwing: CancellationError()); self.readiness = nil
                default: break
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            readiness = continuation; listener.start(queue: .main)
        }
    }

    func releaseResponses() {
        released = true
        for (id, connection) in pending { respond(id: id, connection: connection) }
    }

    func stop() {
        readiness?.resume(throwing: CancellationError()); readiness = nil
        listener?.cancel(); listener = nil
        for connection in pending.values { connection.cancel() }
        pending = [:]
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        pending[id] = connection
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, self.pending[id] != nil else { connection.cancel(); return }
                guard error == nil, data?.isEmpty == false else {
                    self.pending.removeValue(forKey: id); connection.cancel(); return
                }
                self.requestCount += 1
                if self.released { self.respond(id: id, connection: connection) }
            }
        }
    }

    private func respond(id: UUID, connection: NWConnection) {
        pending.removeValue(forKey: id)
        let response = "HTTP/1.1 302 Found\r\nLocation: \(destination.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
