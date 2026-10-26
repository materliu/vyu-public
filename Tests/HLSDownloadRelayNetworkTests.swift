import Network
import XCTest
@testable import VYu

/// Generated loopback bytes verify transport integrity independently of decoding.
@MainActor final class HLSDownloadRelayNetworkTests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:8765")!
    private var session: URLSession!
    private var relays: [HLSDownloadRelay] = []
    private var payload: Data { Data((0..<131_072).map { UInt8($0 % 256) }) }

    override func setUp() async throws {
        continueAfterFailure = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        session = URLSession(configuration: configuration)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(from: base.appendingPathComponent("__health")) }
        catch let error as URLError where error.code == .cannotConnectToHost {
            throw XCTSkip("Generate fixture media and start fixtures/server.py before relay network tests.")
        }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let health = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(health["ready"] as? Bool, true)
        XCTAssertEqual(health["offline"] as? Bool, false)
    }

    override func tearDown() async throws {
        for relay in relays { relay.stop() }
        relays = []
        session?.invalidateAndCancel()
        session = nil
    }

    func testUnknownLengthBodiesAndRedirectsAreValidatedBeforeReturningACompleteResponse() async throws {
        for mode in ["complete", "close-delimited", "redirect"] {
            let (relay, local) = try await segment(mode)
            let (data, response) = try await session.data(from: local)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 200, mode)
            XCTAssertEqual(data, payload, mode)
            // Unknown upstream lengths are fully validated on disk before
            // the relay sends a success response with the actual byte count.
            let raw = try await rawResponse(local)
            XCTAssertTrue(raw.headers.contains("\r\ncontent-length: \(payload.count)\r\n"), mode)
            XCTAssertFalse(raw.headers.contains("\r\ntransfer-encoding:"), mode)
            XCTAssertEqual(raw.body, payload, mode)
            XCTAssertNil(relay.failure, mode)
        }
    }

    func testHEADHasNoBodyForAnUnknownLengthRepresentation() async throws {
        let (relay, local) = try await segment("complete")
        var request = URLRequest(url: local)
        request.httpMethod = "HEAD"
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertTrue(data.isEmpty)
        let raw = try await rawResponse(local, method: "HEAD")
        XCTAssertTrue(raw.headers.contains("\r\ntransfer-encoding: chunked\r\n"))
        XCTAssertTrue(raw.body.isEmpty)
        XCTAssertNil(relay.failure)
    }

    func testProgressCountsOnlySuccessfullySentMediaPayloadAndPublishesTheFinalChunk() async throws {
        let (relay, local) = try await segment("complete")
        // Loading and rewriting the manifest is not video download progress.
        XCTAssertEqual(relay.bytesTransferred, 0)
        var notifications: [(bytes: Int64, time: ContinuousClock.Instant)] = []
        relay.onBytesTransferred = { notifications.append(($0, .now)) }
        var head = URLRequest(url: local)
        head.httpMethod = "HEAD"
        let (headData, _) = try await session.data(for: head)
        XCTAssertTrue(headData.isEmpty)
        XCTAssertEqual(relay.bytesTransferred, 0)
        XCTAssertTrue(notifications.isEmpty)

        let (data, response) = try await session.data(from: local)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, payload)
        try await waitUntil { notifications.last?.bytes == 131_072 }
        XCTAssertEqual(relay.bytesTransferred, Int64(payload.count))
        XCTAssertEqual(notifications.first?.bytes, 65_536)
        XCTAssertEqual(notifications.last?.bytes, 131_072)
        for (previous, next) in zip(notifications, notifications.dropFirst()) {
            XCTAssertGreaterThan(next.bytes, previous.bytes)
            XCTAssertGreaterThanOrEqual(previous.time.duration(to: next.time), .milliseconds(240))
        }
        // A second GET is real additional transport (including repeat probes),
        // while chunked HTTP framing is never included in the payload count.
        let (again, _) = try await session.data(from: local)
        XCTAssertEqual(again, payload)
        try await waitUntil { notifications.last?.bytes == 262_144 }
        XCTAssertEqual(relay.bytesTransferred, 262_144)
        XCTAssertEqual(notifications.map(\.bytes), notifications.map(\.bytes).sorted())
    }

    func testStoppingRelayCancelsPendingProgressNotifications() async throws {
        let (relay, local) = try await segment("complete")
        var notifications: [Int64] = []
        relay.onBytesTransferred = { notifications.append($0) }
        _ = try await session.data(from: local)
        XCTAssertGreaterThan(relay.bytesTransferred, 0)
        relay.stop()
        let countAtStop = notifications.count
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(notifications.count, countAtStop)
    }

    func testTruncatedUpstreamChunkedBodyDoesNotBecomeASuccessfulLocalResponse() async throws {
        let stagesBefore = try relayStagingDirectories()
        let (relay, local) = try await segment("truncated")
        for _ in 0..<3 {
            let (data, response) = try await session.data(from: local)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
            XCTAssertTrue(data.isEmpty)
            // Check the actual wire too: a missing chunk terminator is not
            // sufficient because CFNetwork sometimes accepts that partial body.
            let raw = try await rawResponse(local, expectedStatus: 502)
            XCTAssertTrue(raw.headers.contains("\r\ncontent-length: 0\r\n"))
            XCTAssertFalse(raw.headers.contains("\r\ntransfer-encoding:"))
            XCTAssertTrue(raw.body.isEmpty)
        }
        XCTAssertNotNil(relay.failure)
        XCTAssertEqual(relay.bytesTransferred, 0, "Rejected upstream payload must never reach the local client")
        try await waitUntil { (try? self.relayStagingDirectories()) == stagesBefore }
    }

    func testByteRangesMatchTheRequestedIntervalIncludingOpenSuffixAndEOF() async throws {
        let (relay, local) = try await segment("range")
        let cases: [(String, Range<Int>)] = [
            ("bytes=128-1023", 128..<1024),
            ("bytes=131000-", 131000..<131072),
            ("bytes=-1024", 130048..<131072),
            ("bytes=131000-999999", 131000..<131072)
        ]
        for (range, expected) in cases {
            var request = URLRequest(url: local)
            request.setValue(range, forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 206, range)
            XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes \(expected.lowerBound)-\(expected.upperBound - 1)/131072")
            XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Length"), String(expected.count))
            XCTAssertEqual(data, payload.subdata(in: expected), range)
        }
        XCTAssertNil(relay.failure)
    }

    func testWrongRangeOrLengthIsRejectedBeforeForwardingTheBody() async throws {
        for mode in ["range-wrong", "range-length-mismatch"] {
            let (relay, local) = try await segment(mode)
            var request = URLRequest(url: local)
            request.setValue("bytes=128-1023", forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502, mode)
            XCTAssertTrue(data.isEmpty, mode)
            XCTAssertNotNil(relay.failure, mode)
        }
    }

    func testShortOrLongRangeBodyFailsEvenWhenUpstreamChunkingIsComplete() async throws {
        for mode in ["range-short", "range-long"] {
            let (relay, local) = try await segment(mode)
            var request = URLRequest(url: local)
            request.setValue("bytes=128-1023", forHTTPHeaderField: "Range")
            do {
                _ = try await session.data(for: request)
                XCTFail("A body inconsistent with Content-Range must fail: \(mode)")
            } catch {
                XCTAssertTrue(error is URLError, mode)
                XCTAssertNotNil(relay.failure, mode)
            }
        }
    }

    func testServerMayIgnoreRangeAndReturnTheCompleteRepresentation() async throws {
        let (relay, local) = try await segment("range-ignored")
        var request = URLRequest(url: local)
        request.setValue("bytes=128-1023", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, payload)
        XCTAssertNil(relay.failure)
    }

    func testForeignTokenAndUnregisteredPathsCannotFetchAnUpstreamResource() async throws {
        let (relay, local) = try await segment("complete")
        var invalid = try XCTUnwrap(URLComponents(url: local, resolvingAgainstBaseURL: false))
        for path in ["/other-token/segment.media", local.deletingLastPathComponent().path + "/unregistered.media"] {
            invalid.path = path
            let (data, response) = try await session.data(from: XCTUnwrap(invalid.url))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
            XCTAssertTrue(data.isEmpty)
            XCTAssertNil(relay.failure)
        }
        let (data, response) = try await session.data(from: local)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, payload)
    }

    private func relayStagingDirectories() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("VYu-relay-") })
    }

    private func rawResponse(_ url: URL, method: String = "GET", expectedStatus: Int = 200) async throws -> (headers: String, body: Data) {
        XCTAssertEqual(url.host, "127.0.0.1")
        let port = try XCTUnwrap(url.port.flatMap { UInt16(exactly: $0) }.flatMap(NWEndpoint.Port.init(rawValue:)))
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(10)); connection.cancel() }
            catch { }
        }
        defer { timeout.cancel(); connection.cancel() }
        connection.start(queue: DispatchQueue(label: "app.vyu.ios.fixture.raw-relay"))
        let data = try await withTaskCancellationHandler {
            let request = Data("\(method) \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port.rawValue)\r\nConnection: close\r\n\r\n".utf8)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: request, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
            var received = Data()
            while received.count < 256 * 1024 {
                let next: (Data?, Bool) = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: min(16_384, 256 * 1024 - received.count)) { data, _, complete, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: (data, complete)) }
                    }
                }
                if let bytes = next.0 { received.append(bytes) }
                if next.1 { return received }
            }
            throw URLError(.dataLengthExceedsMaximum)
        } onCancel: { connection.cancel() }
        let separator = try XCTUnwrap(data.range(of: Data("\r\n\r\n".utf8)))
        let headers = String(decoding: data[..<separator.upperBound], as: UTF8.self).lowercased()
        XCTAssertTrue(headers.hasPrefix("http/1.1 \(expectedStatus) "))
        return (headers, Data(data[separator.upperBound...]))
    }

    private func segment(_ mode: String) async throws -> (HLSDownloadRelay, URL) {
        let source = base.appendingPathComponent("hls-relay-wire/\(mode)/index.m3u8")
        let candidate = MediaCandidate(url: source, pageURL: base, frameURL: base,
                                       title: "Synthetic transport", kind: .hls, source: "fixture")
        let relay = HLSDownloadRelay(candidate: candidate, cookies: [])
        relays.append(relay)
        let local = try await relay.start(sourceURL: source)
        let (data, response) = try await session.data(from: local)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(lines.count, 1)
        let segment = try XCTUnwrap(lines.first.flatMap { URL(string: String($0)) })
        XCTAssertEqual(segment.host, "127.0.0.1")
        XCTAssertEqual(segment.port, local.port)
        XCTAssertFalse(segment.absoluteString.contains(mode))
        return (relay, segment)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}
