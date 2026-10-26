import AVFoundation
import XCTest
@testable import VYu

@MainActor final class DownloadDiagnosticsTests: XCTestCase {
    func testFailureStoresOnlyAllowlistedDomainCodesAndKnownIssueTags() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = DownloadDiagnostics(rootDirectory: root)
        let token = UUID().uuidString + "|" + UUID().uuidString
        let secret = "https://private.invalid/path?signature=secret-cookie"
        let core = NSError(domain: "CoreMediaErrorDomain", code: -12893, userInfo: [
            NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLStringErrorKey: secret
        ])
        let outer = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [
            NSLocalizedDescriptionKey: secret, NSUnderlyingErrorKey: core, "Cookie": "secret-cookie"
        ])
        diagnostics.start(token: token, kind: .hls)
        diagnostics.update(token: token, stage: .preroll, duration: 8, playable: true, playableOffline: true, error: outer)
        let data = try Data(contentsOf: root.appendingPathComponent("download-diagnostics.json"))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("private.invalid"))
        XCTAssertFalse(text.contains("secret-cookie"))
        XCTAssertFalse(text.contains("userInfo"))
        let saved = DownloadDiagnostics(rootDirectory: root)
        let entry = try XCTUnwrap(saved.entries.first)
        XCTAssertEqual(entry.stage, .preroll)
        XCTAssertEqual(entry.failure?.domain, AVFoundationErrorDomain)
        XCTAssertEqual(entry.failure?.code, -11800)
        XCTAssertEqual(entry.failure?.underlying.first?.domain, "CoreMediaErrorDomain")
        XCTAssertEqual(entry.failure?.underlying.first?.code, -12893)
        XCTAssertEqual(entry.duration, 8)
    }

    func testUntrustedErrorDomainAndUnsupportedMessageCannotLeakIntoArchive() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = DownloadDiagnostics(rootDirectory: root)
        let token = UUID().uuidString + "|" + UUID().uuidString
        diagnostics.start(token: token, kind: .file)
        diagnostics.update(token: token, error: NSError(domain: "private-url-with-secret", code: 42))
        XCTAssertEqual(diagnostics.entries.first?.failure?.domain, "Other")
        diagnostics.update(token: token, error: DownloadIssue.unsupported("private-url-with-secret"))
        XCTAssertEqual(diagnostics.entries.first?.failure?.issue, "unsupported")
        let text = try String(contentsOf: root.appendingPathComponent("download-diagnostics.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("private-url-with-secret"))
    }

    func testArchiveKeepsOnlyRecentAttemptsAndRejectsUnstructuredIdentifiers() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = DownloadDiagnostics(rootDirectory: root)
        diagnostics.start(token: "https://private.invalid", kind: .file)
        XCTAssertTrue(diagnostics.entries.isEmpty)
        var ids: [UUID] = []
        for _ in 0..<40 {
            let id = UUID(); ids.append(id)
            let token = UUID().uuidString + "|" + id.uuidString
            diagnostics.start(token: token, kind: .hls)
            diagnostics.update(token: token, stage: .transfer, bytes: 123, expectedDuration: .infinity, duration: .nan)
        }
        XCTAssertEqual(diagnostics.entries.count, 32)
        XCTAssertEqual(diagnostics.entries.map(\.attempt), Array(ids.suffix(32)))
        XCTAssertTrue(diagnostics.entries.allSatisfy { $0.duration == nil && $0.expectedDuration == nil })
        let saved = DownloadDiagnostics(rootDirectory: root)
        XCTAssertEqual(saved.entries, diagnostics.entries)
        let values = try root.appendingPathComponent("download-diagnostics.json").resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testHLSCompletenessFailurePreservesExactCheckAndOnlyFiniteNumbers() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = DownloadDiagnostics(rootDirectory: root)
        let token = UUID().uuidString + "|" + UUID().uuidString
        diagnostics.start(token: token, kind: .hls)
        diagnostics.update(token: token, error: HLSFileValidationFailure(.sourceSamples, .sampleContinuity,
            observed: 0.375, expected: .nan))
        let restored = DownloadDiagnostics(rootDirectory: root)
        let failure = try XCTUnwrap(restored.entries.first?.failure)
        XCTAssertEqual(failure.domain, "VYuHLSValidation")
        XCTAssertEqual(failure.issue, "incomplete-media")
        XCTAssertEqual(failure.hlsPhase, .sourceSamples)
        XCTAssertEqual(failure.hlsCheck, .sampleContinuity)
        XCTAssertEqual(failure.observed, 0.375)
        XCTAssertNil(failure.expected)
        XCTAssertTrue(failure.underlying.isEmpty)
    }

    func testUnderlyingErrorDepthAndBranchesAreBounded() {
        var error = NSError(domain: NSOSStatusErrorDomain, code: 1)
        for code in 2...20 {
            error = NSError(domain: AVFoundationErrorDomain, code: code, userInfo: [
                NSUnderlyingErrorKey: error,
                "NSMultipleUnderlyingErrors": Array(repeating: error, count: 10)
            ])
        }
        let failure = DownloadDiagnostics.Failure(error)
        XCTAssertEqual(failure.underlying.count, 3)
        XCTAssertEqual(failure.underlying.first?.underlying.count, 3)
        XCTAssertTrue(failure.underlying.flatMap(\.underlying).flatMap(\.underlying).allSatisfy { $0.underlying.isEmpty })
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VYu-diagnostics-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
