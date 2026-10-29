import Foundation
import XCTest
@testable import VYu

/// Large plans use a URLProtocol that never leaves the process. Media/file and
/// UI integration tests separately exercise the loopback download service.
@MainActor final class BackgroundHLSStartupTests: XCTestCase {
    private var roots: [URL] = []
    private var stores: [BackgroundHLSStore] = []

    override func tearDown() async throws {
        for store in stores { for id in Array(store.jobs.keys) { store.cancel(id: id) } }
        stores = []
        try await Task.sleep(for: .milliseconds(50))
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }

    func testLongActivePlanYieldsToMainActorAndPauseStopsUnsubmittedResources() async throws {
        let (store, root) = try makeStore()
        let id = UUID(), attempt = UUID().uuidString
        let plan = makePlan(segments: 1024)
        try store.create(id: id, attempt: id.uuidString + "|" + attempt, plan: plan, userAgent: nil)
        var beats = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                beats += 1
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
            }
        }
        defer { heartbeat.cancel() }
        let started = Date()
        await store.restore { _ in true }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "Restoration must not synchronously enqueue an entire long plan.")
        try await waitUntil { store.scheduledResourceCount > 0 }
        XCTAssertLessThan(store.scheduledResourceCount, plan.resourceCount)
        try store.pause(id: id)
        XCTAssertEqual(store.scheduledResourceCount, 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.scheduledResourceCount, 0, "Cancelled enqueuer must not submit another batch.")
        XCTAssertGreaterThan(beats, 5)
        let saved = try JSONDecoder().decode(BackgroundHLSStore.Job.self, from: Data(contentsOf:
            root.appendingPathComponent("BackgroundHLS/\(id.uuidString)/job.json")))
        XCTAssertTrue(saved.paused)
        XCTAssertEqual(saved.plan.resourceCount, plan.resourceCount)

        try store.resume(id: id)
        try store.resume(id: id)
        await store.restore { _ in true }
        try await waitUntil { store.scheduledResourceCount == plan.resourceCount }
        XCTAssertGreaterThan(beats, 20)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.scheduledResourceCount, plan.resourceCount, "Repeated resume/restore must not duplicate a resource.")
    }

    func testReplacingAttemptWhileEnqueuingCannotSubmitOldRemainingResources() async throws {
        let (store, _) = try makeStore()
        let id = UUID()
        try store.create(id: id, attempt: id.uuidString + "|" + UUID().uuidString, plan: makePlan(segments: 1024), userAgent: nil)
        await store.restore { _ in true }
        try await waitUntil { store.scheduledResourceCount > 0 }
        let newAttempt = id.uuidString + "|" + UUID().uuidString
        try store.create(id: id, attempt: newAttempt, plan: makePlan(segments: 2), userAgent: nil)
        try await waitUntil { store.scheduledResourceCount == 3 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.scheduledResourceCount, 3)
        XCTAssertEqual(store.jobs[id]?.attempt, newAttempt)
        store.cancel(id: id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.scheduledResourceCount, 0)
        XCTAssertNil(store.jobs[id])
    }

    func testExpiredQueueWindowContinuesOnForegroundWithoutDuplicateResources() async throws {
        let (store, _) = try makeStore()
        let id = UUID(), plan = makePlan(segments: 1024)
        try store.create(id: id, attempt: id.uuidString + "|" + UUID().uuidString, plan: plan, userAgent: nil)
        await store.restore { _ in true }
        try await waitUntil { store.scheduledResourceCount > 0 }
        store.suspendScheduling(id: id)
        let submitted = store.scheduledResourceCount
        XCTAssertLessThan(submitted, plan.resourceCount)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.scheduledResourceCount, submitted)
        XCTAssertFalse(try XCTUnwrap(store.jobs[id]).paused)
        store.resumeScheduling()
        store.resumeScheduling()
        try await waitUntil { store.scheduledResourceCount == plan.resourceCount }
        XCTAssertEqual(store.jobs[id]?.plan.resourceCount, plan.resourceCount)
        try store.pause(id: id)
        store.resumeScheduling()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.scheduledResourceCount, 0, "Foreground entry must not resume a user-paused job.")
    }

    func testResourceFinishedBeforeSessionAdoptionIsDurableAndNotDownloadedAgain() async throws {
        let (store, root) = try makeStore()
        let id = UUID(), attempt = id.uuidString + "|" + UUID().uuidString, plan = makePlan(segments: 4)
        try store.create(id: id, attempt: attempt, plan: plan, userAgent: nil)
        let staged = root.appendingPathComponent("staged-synthetic-resource")
        let data = Data(repeating: 0x5a, count: 100_000)
        try data.write(to: staged)
        let response = HTTPURLResponse(url: plan.resources[0].url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(data.count)])!
        let completion = Task { await store.finished(token: attempt + "|0|" + UUID().uuidString,
                                                     staged: staged, response: response, error: nil) }
        await store.restore { _ in true }
        await completion.value
        try await waitUntil { store.scheduledResourceCount == plan.resourceCount - 1 }
        XCTAssertEqual(store.jobs[id]?.receipts[0]?.bytes, Int64(data.count))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("BackgroundHLS/\(id.uuidString)/0.part")), data)
        try store.pause(id: id)
        XCTAssertEqual(store.jobs[id]?.receipts[0]?.bytes, Int64(data.count))
    }

    func testMaximumPausedPlansColdLoadPreserveReceiptsAndNeverQueueTransfers() async throws {
        let root = temporaryRoot()
        let plan = makePlan(segments: 2048, separateAudio: true)
        XCTAssertEqual(plan.resourceCount, 4098)
        let receipts = Dictionary(uniqueKeysWithValues: (0..<plan.resourceCount).map {
            ($0, BackgroundHLSStore.Receipt(bytes: 1, digest: "synthetic-receipt"))
        })
        var original: [UUID: Data] = [:]
        for _ in 0..<4 {
            let id = UUID()
            let job = BackgroundHLSStore.Job(id: id, attempt: id.uuidString + "|" + UUID().uuidString,
                plan: plan, userAgent: nil, receipts: receipts, paused: true)
            let directory = root.appendingPathComponent("BackgroundHLS/\(id.uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(job)
            try data.write(to: directory.appendingPathComponent("job.json"))
            original[id] = data
        }
        let began = Date()
        let store = newStore(root: root)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.5, "Receipt index checking must be linear, including paused jobs.")
        await store.restore { _ in true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.jobs.count, 4)
        XCTAssertEqual(store.scheduledResourceCount, 0)
        for (id, bytes) in original {
            XCTAssertTrue(store.jobs[id]?.paused == true)
            XCTAssertTrue(store.jobs[id]?.ready == true)
            XCTAssertEqual(store.jobs[id]?.receipts.count, 4098)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("BackgroundHLS/\(id.uuidString)/job.json")), bytes)
        }
    }

    func testReadyColdPlanDoesNotRedownloadCommittedResources() async throws {
        let root = temporaryRoot(), id = UUID(), plan = makePlan(segments: 4)
        let receipts = Dictionary(uniqueKeysWithValues: (0..<plan.resourceCount).map {
            ($0, BackgroundHLSStore.Receipt(bytes: 2, digest: "synthetic-receipt"))
        })
        let job = BackgroundHLSStore.Job(id: id, attempt: id.uuidString + "|" + UUID().uuidString,
                                        plan: plan, userAgent: nil, receipts: receipts)
        let directory = root.appendingPathComponent("BackgroundHLS/\(id.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(job).write(to: directory.appendingPathComponent("job.json"))
        let store = newStore(root: root)
        var ready = false
        store.onChange = { ready = $0.ready }
        await store.restore { _ in true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(ready)
        XCTAssertEqual(store.scheduledResourceCount, 0)
        XCTAssertEqual(store.progress(id: id).0, 10)
    }

    func testBurstCompletionsKeepMainActorResponsiveAndCoalesceProgressNotifications() async throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Staging"), withIntermediateDirectories: true)
        let store = newStore(root: root, held: false), id = UUID()
        func resource(_ index: Int) -> HLSFilePlaylist.Resource {
            .init(url: URL(string: "http://127.0.0.1:8765/media/direct.mp4?startup=\(index)")!, range: nil)
        }
        let playlist = HLSFilePlaylist(initialization: resource(-1), segments: (0..<95).map {
            HLSFilePlaylist.Segment(resource: resource($0), duration: 1)
        })
        let plan = HLSFileDownloadPlan(video: playlist, audio: nil, requiresAudio: false)
        var notifications = 0, failure = false, maximumGap = 0.0, lastBeat = Date()
        store.onChange = { _ in notifications += 1 }
        store.onFailure = { _, _, _ in failure = true }
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                let now = Date(); maximumGap = max(maximumGap, now.timeIntervalSince(lastBeat)); lastBeat = now
            }
        }
        defer { heartbeat.cancel() }
        try store.create(id: id, attempt: id.uuidString + "|" + UUID().uuidString, plan: plan, userAgent: nil)
        await store.restore { _ in true }
        try await waitUntil { store.jobs[id]?.ready == true || failure }
        XCTAssertFalse(failure, "The local generated media service must be running for this integration test.")
        XCTAssertEqual(store.jobs[id]?.receipts.count, 96)
        XCTAssertLessThan(maximumGap, 1, "Completion receipt writes must leave the UI run loop responsive.")
        XCTAssertLessThan(notifications, 24, "Every completed part must not rewrite the outer download index.")
        XCTAssertEqual(store.scheduledResourceCount, 0)
    }

    private func makeStore() throws -> (BackgroundHLSStore, URL) {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (newStore(root: root), root)
    }
    private func newStore(root: URL, held: Bool = true) -> BackgroundHLSStore {
        let configuration = URLSessionConfiguration.ephemeral
        if held { configuration.protocolClasses = [HeldStartupResource.self] }
        let store = BackgroundHLSStore(root: root, identifier: "startup-tests.\(UUID().uuidString)", sessionConfiguration: configuration)
        stores.append(store)
        return store
    }
    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYuStartup-\(UUID().uuidString)")
        roots.append(root); return root
    }
    private func makePlan(segments: Int, separateAudio: Bool = false) -> HLSFileDownloadPlan {
        func playlist(_ track: String) -> HLSFilePlaylist {
            func resource(_ index: Int) -> HLSFilePlaylist.Resource {
                .init(url: URL(string: "http://127.0.0.1:8765/synthetic-startup/\(track)/\(index)")!, range: nil)
            }
            return HLSFilePlaylist(initialization: resource(-1), segments: (0..<segments).map {
                .init(resource: resource($0), duration: 1)
            })
        }
        return HLSFileDownloadPlan(video: playlist("video"), audio: separateAudio ? playlist("audio") : nil, requiresAudio: separateAudio)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Resource scheduling did not settle within its bounded timeout.")
    }
}

private final class HeldStartupResource: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "1048576"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Intentionally held until the tested pause/cancel. No socket is opened.
    }
    override func stopLoading() {}
}
