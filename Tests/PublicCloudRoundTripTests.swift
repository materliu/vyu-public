import CryptoKit
import Foundation
import UIKit
import XCTest
@testable import VYu

/// Explicitly opted-in native iCloud probe. Every cloud operation is confined to
/// a fresh VYuProbe-UUID directory; this test never opens the user's library.
@MainActor final class PublicCloudRoundTripTests: XCTestCase {
    func testOptInPublicVideoUploadsEvictsAndDownloadsFromNativeICloud() async throws {
        guard ProcessInfo.processInfo.environment["VYU_PUBLIC_CLOUD_PROBE"] == "1" else {
            throw XCTSkip("Explicit native iCloud public-media probe opt-in required.")
        }
        guard ProcessInfo.processInfo.environment["VYU_TEST_LIBRARY_ID"].flatMap(UUID.init(uuidString:)) != nil else {
            throw XCTSkip("A fresh isolated host-app library ID is required for the native cloud probe.")
        }
        guard let account = Self.identityKey() else { throw XCTSkip("Native iCloud account is unavailable.") }
        print("VYu public native iCloud phase=container")
        let container = await Task.detached(priority: .utility) {
            FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.app.vyu.ios")
        }.value
        guard let container else { throw XCTSkip("The dedicated VYu iCloud container is unavailable.") }
        let probeName = "VYuProbe-" + UUID().uuidString
        let cloudRoot = container.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent(probeName, isDirectory: true)
        let localRoot = FileManager.default.temporaryDirectory.appendingPathComponent(probeName, isDirectory: true)
        let access = CloudSyncAccess(account: account, identity: { Self.identityKey() })
        var createdCloudRoot = false
        defer {
            // Keep cleanup synchronous so the test process cannot exit before
            // submitting deletion of this probe's own cloud files.
            if createdCloudRoot {
                do {
                    print("VYu public native iCloud phase=cleanup")
                    try access.check()
                    try Self.removeProbe(cloudRoot, expectedName: probeName)
                    print("VYu public native iCloud phase=cleanup-complete")
                } catch { XCTFail("Could not clean up this probe's unique cloud directory: \(Self.safeCode(error))") }
            }
            try? FileManager.default.removeItem(at: localRoot)
        }
        do {
            try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: false,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let page = URL(string: "https://x.com/")!
            let candidate = MediaCandidate(
                url: URL(string: "https://video.twimg.com/amplify_video/2059310686539517955/pl/5Zmh0DCW3Jy5MVuF.m3u8?tag=27")!,
                pageURL: page, frameURL: page, title: "Public Earth-orbit iCloud probe", kind: .hls,
                source: "public-cloud-test", requestContext: MediaRequestContext(corsMode: .none, referrerPolicy: .strictOriginWhenCrossOrigin))
            let inspection = MediaInspection(summary: "Public sample", variants: [], audioTracks: [], expectedBytes: nil,
                downloadable: true, expectedDuration: 50)
            let media = localRoot.appendingPathComponent("public.mp4")
            print("VYu public native iCloud phase=public-export")
            let export = Task { try await HLSFileExporter.export(candidate: candidate, cookies: [], inspection: inspection, destination: media) }
            let exportDeadline = Task {
                do { try await Task.sleep(for: .seconds(90)); export.cancel() } catch { }
            }
            defer { exportDeadline.cancel(); export.cancel() }
            let result = try await withTaskCancellationHandler { try await export.value } onCancel: { export.cancel() }
            guard result.bytes > 0, result.bytes <= 32 * 1024 * 1024 else { throw ProbeError.mediaSize }
            print("VYu public native iCloud phase=public-media-ready bytes=\(result.bytes)")
            let record = DownloadRecord(id: UUID(), candidate: candidate, phase: .complete, progress: 1,
                bytesWritten: result.bytes, expectedBytes: result.bytes, localRelativePath: "public.mp4", failure: nil,
                duration: result.duration, hasAudio: result.hasAudio,
                createdAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)))
            let thumbnails = VideoThumbnailStore(directory: localRoot.appendingPathComponent("Thumbnails", isDirectory: true))
            guard let image = await thumbnails.image(for: record, localURL: media),
                  let jpeg = image.jpegData(compressionQuality: 0.78) else { throw ProbeError.thumbnail }
            let staging = localRoot.appendingPathComponent(record.id.uuidString, isDirectory: true)
            let manifest = try await Task.detached(priority: .utility) {
                try CloudVideoArchive.createStagingPackage(record: record, mediaURL: media, thumbnailJPEG: jpeg, at: staging)
            }.value
            let deadline = ContinuousClock.now.advanced(by: .seconds(240))
            try access.check()
            // The generated name is not reused. No production Videos/Deleted
            // directory is read or changed by the probe.
            guard !FileManager.default.fileExists(atPath: cloudRoot.path) else { throw ProbeError.existingDirectory }
            createdCloudRoot = true
            print("VYu public native iCloud phase=publish")
            try await Task.detached(priority: .utility) {
                try CloudVideoFiles.prepare(container: cloudRoot, access: access)
                try CloudVideoFiles.publish(staging: staging, manifest: manifest, container: cloudRoot, ubiquitous: true, access: access)
            }.value
            print("VYu public native iCloud phase=published")
            let package = CloudVideoFiles.packageURL(record.id, container: cloudRoot)
            let cloudMedia = package.appendingPathComponent("video.mp4")
            let cloudPreview = package.appendingPathComponent(CloudVideoArchive.thumbnailFilename)
            let cloudManifest = package.appendingPathComponent(CloudVideoArchive.manifestFilename)
            try await waitFor([cloudMedia, cloudPreview, cloudManifest], stage: .uploaded, deadline: deadline, access: access)
            try await Task.detached(priority: .utility) {
                try access.check()
                try FileManager.default.evictUbiquitousItem(at: cloudMedia)
                try FileManager.default.evictUbiquitousItem(at: cloudPreview)
            }.value
            try await waitFor([cloudMedia, cloudPreview], stage: .evicted, deadline: deadline, access: access)
            try await Task.detached(priority: .utility) {
                try access.check()
                try FileManager.default.startDownloadingUbiquitousItem(at: cloudMedia)
                try FileManager.default.startDownloadingUbiquitousItem(at: cloudPreview)
            }.value
            try await waitFor([cloudMedia, cloudPreview], stage: .downloaded, deadline: deadline, access: access)
            let verified = try await Task.detached(priority: .utility) {
                try access.check()
                return try Self.readProbe(package, manifest: manifest, preview: jpeg)
            }.value
            XCTAssertTrue(verified)
            let report: [String: Any] = ["nativeICloud": true, "uploaded": true, "evictionObserved": true,
                "downloaded": true, "sha256Matched": verified, "previewMatched": verified, "mediaBytes": result.bytes]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "native-icloud-public-roundtrip"; attachment.lifetime = .keepAlways; add(attachment)
            print("VYu public native iCloud upload, observed eviction, redownload and SHA-256 verification passed.")
        } catch {
            // Never let XCTest print an NSError description or userInfo that
            // could include account/container URLs.
            XCTFail("Native iCloud public probe failed: \(Self.safeCode(error))")
            return
        }
    }

    private enum Stage: String { case uploaded, evicted, downloaded }
    private enum ProbeError: Error { case failed, mediaSize, thumbnail, existingDirectory, timeout, transfer, invalidCleanup }
    private struct SafeError: Codable, Equatable, Sendable {
        let domain: String
        let code: Int
        init(_ error: Error) {
            let error = error as NSError
            let allowed = [NSCocoaErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, "AVFoundationErrorDomain"]
            domain = allowed.contains(error.domain) ? error.domain : "Other"
            code = error.code
        }
    }
    private struct FileState: Codable, Equatable, Sendable {
        let role: String
        var ubiquitous: Bool?
        var targetedByFileManager: Bool
        var uploading: Bool?
        var uploaded: Bool?
        var downloadStatus: String = "unknown"
        var uploadError: SafeError?
        var downloadError: SafeError?
        var metadataError: SafeError?
        var conflict = false
        var cacheAgrees: Bool?
    }
    private func waitFor(_ urls: [URL], stage: Stage, deadline: ContinuousClock.Instant, access: CloudSyncAccess) async throws {
        print("VYu public native iCloud waiting=\(stage.rawValue)")
        let started = ContinuousClock.now
        var nextReport = started
        var lastStates: [FileState] = []
        while ContinuousClock.now < deadline {
            try Task.checkCancellation(); try access.check()
            let states = await Task.detached(priority: .utility) {
                urls.enumerated().map { index, url in Self.fileState(url, role: ["video", "preview", "manifest"][index]) }
            }.value
            if states != lastStates || ContinuousClock.now >= nextReport {
                report(states, stage: stage, seconds: started.duration(to: .now).components.seconds)
                nextReport = .now.advanced(by: .seconds(15))
            }
            lastStates = states
            guard !states.contains(where: { $0.uploadError != nil || $0.downloadError != nil || $0.conflict }) else { throw ProbeError.transfer }
            let ready = states.allSatisfy { value in
                guard value.ubiquitous == true, value.metadataError == nil else { return false }
                switch stage {
                case .uploaded: return value.uploaded == true
                case .evicted: return value.downloadStatus == "not-downloaded"
                case .downloaded: return value.downloadStatus == "current"
                }
            }
            if ready { print("VYu public native iCloud stage verified: \(stage.rawValue)"); return }
            try await Task.sleep(for: .seconds(1))
        }
        report(lastStates, stage: stage, seconds: started.duration(to: .now).components.seconds)
        print("VYu public native iCloud stage timed out: \(stage.rawValue)")
        throw ProbeError.timeout
    }

    private func report(_ states: [FileState], stage: Stage, seconds: Int64) {
        struct Report: Codable { let stage: String; let seconds: Int64; let files: [FileState] }
        guard let data = try? JSONEncoder().encode(Report(stage: stage.rawValue, seconds: seconds, files: states)),
              let text = String(data: data, encoding: .utf8) else { return }
        print("VYu public native iCloud state: " + text)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "native-cloud-\(stage.rawValue)-\(seconds)"; attachment.lifetime = .keepAlways; add(attachment)
    }

    nonisolated private static func fileState(_ url: URL, role: String) -> FileState {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
            .ubiquitousItemDownloadingStatusKey, .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey,
            .ubiquitousItemHasUnresolvedConflictsKey]
        var state = FileState(role: role, targetedByFileManager: FileManager.default.isUbiquitousItem(at: url))
        do {
            var fresh = URL(fileURLWithPath: url.path); fresh.removeAllCachedResourceValues()
            let value = try fresh.resourceValues(forKeys: keys)
            state.ubiquitous = value.isUbiquitousItem; state.uploaded = value.ubiquitousItemIsUploaded
            state.uploading = value.ubiquitousItemIsUploading
            switch value.ubiquitousItemDownloadingStatus {
            case .current?: state.downloadStatus = "current"
            case .downloaded?: state.downloadStatus = "downloaded"
            case .notDownloaded?: state.downloadStatus = "not-downloaded"
            default: break
            }
            state.uploadError = value.ubiquitousItemUploadingError.map(SafeError.init)
            state.downloadError = value.ubiquitousItemDownloadingError.map(SafeError.init)
            state.conflict = value.ubiquitousItemHasUnresolvedConflicts == true
            // Compare a fresh URL with the caller's URL after clearing its
            // cache, without exporting either path.
            var original = url; original.removeAllCachedResourceValues()
            let comparison = try original.resourceValues(forKeys: keys)
            state.cacheAgrees = comparison.isUbiquitousItem == value.isUbiquitousItem &&
                comparison.ubiquitousItemIsUploaded == value.ubiquitousItemIsUploaded &&
                comparison.ubiquitousItemIsUploading == value.ubiquitousItemIsUploading &&
                comparison.ubiquitousItemDownloadingStatus == value.ubiquitousItemDownloadingStatus
        } catch { state.metadataError = SafeError(error) }
        return state
    }

    nonisolated private static func readProbe(_ package: URL, manifest: CloudVideoManifest, preview: Data) throws -> Bool {
        var coordinationError: NSError?, result: Result<Bool, Error>?
        NSFileCoordinator().coordinate(readingItemAt: package, options: .withoutChanges, error: &coordinationError) { target in
            result = Result {
                guard try CloudVideoArchive.readManifest(at: target) == manifest else { throw CloudVideoArchiveError.invalidManifest }
                _ = try CloudVideoArchive.verifyMedia(at: target, manifest: manifest)
                return try CloudVideoArchive.thumbnailData(at: target) == preview
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ProbeError.failed }
        return try result.get()
    }

    nonisolated private static func removeProbe(_ url: URL, expectedName: String) throws {
        guard url.lastPathComponent == expectedName, expectedName.hasPrefix("VYuProbe-"),
              UUID(uuidString: String(expectedName.dropFirst("VYuProbe-".count))) != nil else { throw ProbeError.invalidCleanup }
        var coordinationError: NSError?, removalError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            do { if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) } }
            catch { removalError = error }
        }
        if let error = coordinationError ?? removalError as NSError? { throw error }
    }

    nonisolated private static func identityKey() -> String? {
        guard let token = FileManager.default.ubiquityIdentityToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated private static func safeCode(_ error: Error) -> String {
        let value = error as NSError
        let allowed = [NSCocoaErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, "AVFoundationErrorDomain"]
        return "\(allowed.contains(value.domain) ? value.domain : "ProbeError") \(value.code)"
    }
}
