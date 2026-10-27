import AVFoundation
import Combine
import CoreImage
import CryptoKit
import UIKit

/// Cached images are generated from local media, never fetched from a video's webpage.
@MainActor final class VideoThumbnailStore: ObservableObject {
    typealias Renderer = @MainActor (URL, Double?) async -> Data?
    typealias FrameRenderer = @MainActor (URL, Double, Double?) async -> Data?
    private struct Request {
        let key: String
        let token: UUID
        let task: Task<Data?, Never>
    }

    private let directory: URL
    private let renderer: Renderer
    private let frameRenderer: FrameRenderer
    private let now: () -> Date
    private let images = NSCache<NSString, UIImage>()
    private var keys: [UUID: String] = [:]
    private var requests: [UUID: Request] = [:]
    private var failures: [String: Date] = [:]
    private var activeGenerations = 0

    init(directory: URL? = nil, now: @escaping () -> Date = Date.init,
         frameRenderer: FrameRenderer? = nil, renderer: Renderer? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VYu/Thumbnails", isDirectory: true)
        self.renderer = renderer ?? LocalVideoThumbnailRenderer.jpeg
        self.frameRenderer = frameRenderer ?? LocalVideoThumbnailRenderer.frameJPEG
        self.now = now
        images.countLimit = 60
        images.totalCostLimit = 24 * 1_024 * 1_024
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var protectedDirectory = self.directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? protectedDirectory.setResourceValues(values)
    }

    func image(for record: DownloadRecord, localURL: URL?, frameSeconds: Double? = nil) async -> UIImage? {
        if record.localCacheEvicted == true, localURL == nil {
            return cachedImage(for: record.id)
        }
        guard record.phase == .complete, let localURL, let key = sourceKey(id: record.id, url: localURL, frameSeconds: frameSeconds) else {
            remove(id: record.id)
            return nil
        }
        if let prior = keys[record.id], prior != key { remove(id: record.id) }
        keys[record.id] = key
        if let cached = images.object(forKey: key as NSString) { return cached }
        if let retryAfter = failures[key], now() < retryAfter { return nil }
        failures.removeValue(forKey: key)
        if let data = try? Data(contentsOf: cacheURL(key)), let cached = UIImage(data: data) {
            remember(cached, key: key)
            return cached
        }

        let request: Request
        if let running = requests[record.id], running.key == key {
            request = running
        } else {
            let token = UUID()
            let task = Task(priority: .utility) { [weak self] in
                guard let self else { return Optional<Data>.none }
                // A scrolling list may request many rows at once. Only two decoders run.
                while self.activeGenerations >= 2 {
                    do { try await Task.sleep(for: .milliseconds(30)) } catch { return nil }
                }
                guard !Task.isCancelled else { return nil }
                self.activeGenerations += 1
                defer { self.activeGenerations -= 1 }
                if let frameSeconds {
                    return await self.frameRenderer(localURL, frameSeconds, record.duration)
                }
                return await self.renderer(localURL, record.duration)
            }
            request = Request(key: key, token: token, task: task)
            requests[record.id] = request
        }

        let data = await request.task.value
        guard keys[record.id] == key else { return nil }
        // A completed or cancelled request must not invalidate a preview kept
        // after its media file was safely released.
        guard requests[record.id]?.token == request.token else { return images.object(forKey: key as NSString) }
        guard sourceKey(id: record.id, url: localURL, frameSeconds: frameSeconds) == key else {
            if requests[record.id]?.token == request.token { remove(id: record.id) }
            return nil
        }
        // Several visible consumers may be waiting for the same request.
        requests.removeValue(forKey: record.id)
        guard let data, let result = UIImage(data: data) else {
            // A decoder can be briefly unavailable while an offline package
            // settles. A failed attempt must not suppress this preview forever.
            failures[key] = now().addingTimeInterval(30)
            return nil
        }
        removeDiskImages(id: record.id)
        try? data.write(to: cacheURL(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        remember(result, key: key)
        return result
    }

    func prepareForCacheEviction(id: UUID) {
        requests.removeValue(forKey: id)?.task.cancel()
        if let key = keys.removeValue(forKey: id) { failures.removeValue(forKey: key) }
    }

    /// Last locally saved preview remains usable without the original media or
    /// a network connection. A current cloud JPEG takes priority in cloud rows.
    func cachedImage(for id: UUID) -> UIImage? {
        for url in diskImages().filter({ $0.lastPathComponent.hasPrefix(id.uuidString + "_") }) {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let count = values.fileSize, count <= 4_000_000,
                  let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { continue }
            return image
        }
        return nil
    }

    /// Cancelling a download or deleting its cache also invalidates any pending image.
    func remove(id: UUID) {
        requests.removeValue(forKey: id)?.task.cancel()
        if let key = keys.removeValue(forKey: id) {
            images.removeObject(forKey: key as NSString)
            failures.removeValue(forKey: key)
        }
        removeDiskImages(id: id)
    }

    func retainRecords(_ ids: Set<UUID>) {
        for id in Set(keys.keys).union(requests.keys) where !ids.contains(id) { remove(id: id) }
        for url in diskImages() {
            guard let id = UUID(uuidString: String(url.lastPathComponent.prefix(36))), !ids.contains(id) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func sourceKey(id: UUID, url: URL, frameSeconds: Double?) -> String? {
        if let frameSeconds, !frameSeconds.isFinite || frameSeconds < 0 { return nil }
        // URL.resourceValues may reuse cached metadata even after replacement or deletion.
        guard url.isFileURL, let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = values[.type] as? FileAttributeType,
              type == .typeRegular || (type == .typeDirectory && url.pathExtension.lowercased() == "movpkg") else { return nil }
        // Source addresses and metadata are hashed, rather than stored in cache filenames.
        let frameKey = frameSeconds.map { String(($0 == 0 ? 0 : $0).bitPattern, radix: 16) } ?? "automatic"
        let version = ["2", frameKey, url.standardizedFileURL.path, String((values[.size] as? NSNumber)?.int64Value ?? 0),
            String((values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0),
            String((values[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0)].joined(separator: "\n")
        let hash = SHA256.hash(data: Data(version.utf8)).map { String(format: "%02x", $0) }.joined()
        return id.uuidString + "_" + hash
    }

    private func remember(_ image: UIImage, key: String) {
        images.setObject(image, forKey: key as NSString, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0))
    }
    private func cacheURL(_ key: String) -> URL { directory.appendingPathComponent(key + ".jpg") }
    private func diskImages() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jpg" }
    }
    private func removeDiskImages(id: UUID) {
        for url in diskImages() where url.lastPathComponent.hasPrefix(id.uuidString + "_") {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

@MainActor enum LocalVideoThumbnailRenderer {
    private static let maximumSize = CGSize(width: 480, height: 270)
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Tries a few positions so a black opening does not become the default cover.
    static func jpeg(url: URL, duration: Double?) async -> Data? {
        await render(url: url, selectedSeconds: nil)
    }

    /// A requested frame is never replaced with the opening frame on failure.
    static func frameJPEG(url: URL, seconds: Double, duration: Double?) async -> Data? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return await render(url: url, selectedSeconds: seconds)
    }

    private static func render(url: URL, selectedSeconds: Double?) async -> Data? {
        guard isLocalMedia(url), !Task.isCancelled else { return nil }
        let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey:
            AVAssetReferenceRestrictions.forbidLocalReferenceToRemote.rawValue])
        let package = url.pathExtension.lowercased() == "movpkg"
        let deadline = ContinuousClock.now.advanced(by: .seconds(package ? 10 : 5))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = maximumSize
        generator.appliesPreferredTrackTransform = true
        // ImageGenerator's default infinite tolerance can return a black opening
        // keyframe even when the requested time is several seconds later.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let timeout = Task {
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            generator.cancelAllCGImageGeneration()
            asset.cancelLoading()
        }
        defer { timeout.cancel(); generator.cancelAllCGImageGeneration(); asset.cancelLoading() }
        return await withTaskCancellationHandler {
            // Download metadata is a hint; only the local asset defines valid
            // frame boundaries. In particular the end timestamp has no frame.
            guard let loadedDuration = try? await asset.load(.duration),
                  let actualDuration = finiteDuration(loadedDuration),
                  !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            if let selectedSeconds, selectedSeconds >= actualDuration { return nil }
            let positions = selectedSeconds.map { [$0] } ?? automaticPositions(duration: actualDuration)
            if package {
                return await packageJPEG(asset: asset, positions: positions,
                    exact: selectedSeconds != nil, deadline: deadline)
            }
            var firstFrame: Data?
            for seconds in positions {
                guard !Task.isCancelled else { return nil }
                guard ContinuousClock.now < deadline else { return firstFrame }
                guard let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 60_000)),
                      !Task.isCancelled, ContinuousClock.now < deadline,
                      let data = UIImage(cgImage: result.image).jpegData(compressionQuality: 0.78) else { continue }
                if selectedSeconds != nil || !isNearlyBlack(result.image) { return data }
                if firstFrame == nil { firstFrame = data }
            }
            return Task.isCancelled ? nil : firstFrame
        } onCancel: {
            generator.cancelAllCGImageGeneration()
            asset.cancelLoading()
        }
    }

    private static func isLocalMedia(_ url: URL) -> Bool {
        guard url.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else { return false }
        return type == .typeRegular || (type == .typeDirectory && url.pathExtension.lowercased() == "movpkg")
    }

    private static func finiteDuration(_ time: CMTime) -> Double? {
        let seconds = time.seconds
        return time.isNumeric && seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private static func automaticPositions(duration: Double) -> [Double] {
        var result: [Double] = []
        for seconds in [min(1, duration * 0.1), duration * 0.35, duration * 0.6, duration * 0.85, 0] {
            if seconds >= 0, seconds < duration, !result.contains(seconds) { result.append(seconds) }
        }
        return result
    }

    /// Samples an opaque small RGB image. Letterboxing alone is not enough to
    /// reject a frame, and a completely dark video still keeps its first image.
    private static func isNearlyBlack(_ image: CGImage) -> Bool {
        let width = 32, height = 18
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let bitmap = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            bitmap.interpolationQuality = .low
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return false }
        var total = 0.0, dark = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let luma = (0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1])
                + 0.0722 * Double(pixels[offset + 2])) / 255
            total += luma
            if luma < 0.06 { dark += 1 }
        }
        return total / Double(width * height) < 0.035 && Double(dark) / Double(width * height) > 0.96
    }

    /// Ordinary offline HLS packages do not necessarily contain an I-frame
    /// playlist, so AVAssetImageGenerator is not a general HLS thumbnail API.
    private static func packageJPEG(asset: AVURLAsset, positions: [Double], exact: Bool,
                                    deadline: ContinuousClock.Instant) async -> Data? {
        let prepared = try? await OfflineMediaPreparation.makeItem(asset: asset)
        guard let item = prepared, asset.assetCache?.isPlayableOffline == true,
              !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
        var firstFrame: Data?
        for seconds in positions {
            guard !Task.isCancelled else { return nil }
            guard ContinuousClock.now < deadline else { return firstFrame }
            guard let data = await playerJPEG(item: item, seconds: seconds, deadline: deadline,
                exact: exact, fallbackToStart: false), let image = UIImage(data: data)?.cgImage else { continue }
            if exact || !isNearlyBlack(image) { return data }
            if firstFrame == nil { firstFrame = data }
        }
        return Task.isCancelled ? nil : firstFrame
    }

    /// Decode while paused. This does not require a visible player layer, a
    /// running playback clock, a window, or changes to the shared audio session.
    static func playerJPEG(item: AVPlayerItem, seconds: Double,
                           deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(10)),
                           exact: Bool = false, fallbackToStart: Bool = true) async -> Data? {
        guard seconds.isFinite, seconds >= 0,
              let localAsset = item.asset as? AVURLAsset, isLocalMedia(localAsset.url),
              !Task.isCancelled else { return nil }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.suppressesPlayerRendering = true
        let readiness = ThumbnailOutputReadiness()
        output.setDelegate(readiness, queue: .main)
        item.add(output)
        let player = AVPlayer()
        player.isMuted = true
        player.volume = 0
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.replaceCurrentItem(with: item)
        defer {
            player.cancelPendingPrerolls(); item.cancelPendingSeeks()
            player.pause(); player.replaceCurrentItem(with: nil)
            output.setDelegate(nil, queue: nil); item.remove(output)
        }
        while player.status != .readyToPlay || item.status != .readyToPlay {
            guard !Task.isCancelled, player.status != .failed, item.status != .failed,
                  ContinuousClock.now < deadline else { return nil }
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return nil }
        }
        for seconds in fallbackToStart && seconds > 0 ? [seconds, 0] : [seconds] {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            let target = CMTime(seconds: seconds, preferredTimescale: 60_000)
            let seek = ThumbnailPreparationState()
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: exact ? .zero : CMTime(seconds: 0.25, preferredTimescale: 600)) { finished in
                Task { @MainActor in seek.finished = finished }
            }
            let seekDeadline = min(deadline, ContinuousClock.now.advanced(by: .seconds(3)))
            while seek.finished == nil && ContinuousClock.now < seekDeadline {
                guard !Task.isCancelled, item.status != .failed else { return nil }
                do { try await Task.sleep(for: .milliseconds(30)) } catch { return nil }
            }
            guard !Task.isCancelled else { return nil }
            if seek.finished != true { item.cancelPendingSeeks(); continue }
            guard player.status == .readyToPlay else { return nil }
            let preroll = ThumbnailPreparationState()
            readiness.available = false
            output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
            // preroll primes decode at the completed seek while rate remains 0.
            // Calling play immediately after seek can leave a headless HLS
            // player stalled, with no usable clock or output frame.
            player.preroll(atRate: 1) { finished in
                Task { @MainActor in preroll.finished = finished }
            }
            let frameDeadline = min(deadline, ContinuousClock.now.advanced(by: .seconds(3)))
            while ContinuousClock.now < frameDeadline {
                guard !Task.isCancelled, item.status != .failed else { return nil }
                // Prefer the requested position; the resolved paused clock is
                // useful once seek updates it. Neither advances playback.
                for time in [target, item.currentTime()] where time.isNumeric {
                    if let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                        return await jpeg(buffer: buffer, item: item)
                    }
                }
                if preroll.finished == false { break }
                do { try await Task.sleep(for: .milliseconds(readiness.available ? 15 : 30)) } catch { return nil }
            }
            player.cancelPendingPrerolls()
        }
        return nil
    }

    private static func jpeg(buffer: CVPixelBuffer, item: AVPlayerItem) async -> Data? {
        let track = item.tracks.first(where: { $0.assetTrack?.mediaType == .video })?.assetTrack
        let transform = (try? await track?.load(.preferredTransform)) ?? .identity
        guard !Task.isCancelled else { return nil }
        var frame = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
        let extent = frame.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1, maximumSize.width / extent.width, maximumSize.height / extent.height)
        frame = frame.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = CGRect(x: 0, y: 0, width: floor(extent.width * scale), height: floor(extent.height * scale))
        guard let image = context.createCGImage(frame, from: bounds) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.78)
    }
}

@MainActor private final class ThumbnailPreparationState {
    var finished: Bool?
}

@MainActor private final class ThumbnailOutputReadiness: NSObject, AVPlayerItemOutputPullDelegate {
    var available = false
    nonisolated func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        Task { @MainActor [weak self] in self?.available = true }
    }
}
