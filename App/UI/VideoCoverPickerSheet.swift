import AVFoundation
import SwiftUI

@MainActor struct VideoCoverPickerSheet: View {
    let videoID: UUID
    let title: String
    let localURL: URL
    @ObservedObject var downloads: DownloadManager
    @ObservedObject var videoMetadata: VideoMetadataStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSeconds: Double
    @State private var duration: Double?
    @State private var previewImage: UIImage?
    @State private var previewSeconds: Double?
    @State private var previewGeneration = UUID()
    @State private var isLoadingDuration = true
    @State private var previewError: String?
    @State private var saveError: String?

    private struct PreviewRequest: Hashable {
        let seconds: Double
        let duration: Double?
        let available: Bool
    }

    init(videoID: UUID, title: String, localURL: URL, downloads: DownloadManager, videoMetadata: VideoMetadataStore) {
        self.videoID = videoID
        self.title = title
        self.localURL = localURL
        self.downloads = downloads
        self.videoMetadata = videoMetadata
        _selectedSeconds = State(initialValue: 0)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(title).font(.headline).lineLimit(3)
                    preview
                    VStack(spacing: 12) {
                        Slider(value: $selectedSeconds, in: 0...maximumSeconds)
                            .disabled(duration == nil || !isLocalVideoAvailable)
                            .accessibilityLabel("封面位置")
                            .accessibilityValue(String(format: "%.3f 秒", selectedSeconds))
                            .accessibilityIdentifier("videoCoverSlider")
                        Text("\(time(selectedSeconds)) / \(duration.map(time) ?? "--:--.---")")
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("当前时间与总时长")
                            .accessibilityIdentifier("videoCoverTime")
                        HStack {
                            Button("前一秒", systemImage: "gobackward") { move(by: -1) }
                                .disabled(selectedSeconds <= 0 || duration == nil || !isLocalVideoAvailable)
                                .accessibilityIdentifier("previousVideoCoverSecond")
                            Spacer()
                            Button("后一秒", systemImage: "goforward") { move(by: 1) }
                                .disabled(selectedSeconds >= maximumSeconds || duration == nil || !isLocalVideoAvailable)
                                .accessibilityIdentifier("nextVideoCoverSecond")
                        }.buttonStyle(.bordered)
                    }
                    if !isLocalVideoAvailable {
                        Text("本机视频已移除，请下载后再选择封面。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("拖动选择画面，确认后保存。预览不会播放声音。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Button("使用自动封面", systemImage: "arrow.counterclockwise", action: useAutomaticCover)
                        .disabled(!isLocalVideoAvailable)
                        .accessibilityIdentifier("useAutomaticVideoCover")
                }.padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .navigationTitle("选择封面").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.accessibilityIdentifier("cancelVideoCover")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).fontWeight(.semibold).disabled(!canSave)
                        .accessibilityIdentifier("saveVideoCover")
                }
            }
            .alert("封面未能保存", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("好") { saveError = nil }
            } message: { Text(saveError ?? "请重试。") }
            .task { await loadDuration() }
            .task(id: PreviewRequest(seconds: selectedSeconds, duration: duration, available: isLocalVideoAvailable)) {
                await loadPreview()
            }
        }
    }

    private var matchingPreview: UIImage? { previewSeconds == selectedSeconds ? previewImage : nil }
    private var maximumSeconds: Double {
        guard let duration else { return 1 }
        return max(0, min(duration.nextDown, duration - min(1.0 / 600, duration * 0.1)))
    }
    private var canSave: Bool { isLocalVideoAvailable && duration != nil && matchingPreview != nil }

    private var isLocalVideoAvailable: Bool {
        guard localURL.isFileURL,
              let record = downloads.records.first(where: { $0.id == videoID }), record.phase == .complete,
              downloads.localURL(for: record)?.standardizedFileURL == localURL.standardizedFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path),
              let type = attributes[.type] as? FileAttributeType else { return false }
        return type == .typeRegular || (type == .typeDirectory && localURL.pathExtension.lowercased() == "movpkg")
    }

    private var preview: some View {
        ZStack {
            Color.black
            if let image = matchingPreview {
                Image(uiImage: image).resizable().scaledToFit()
            } else if let previewError {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark").font(.title)
                    Text(previewError).font(.subheadline).multilineTextAlignment(.center)
                }.foregroundStyle(.white).padding(20)
            } else {
                ProgressView(isLoadingDuration ? "正在读取视频" : "正在提取画面").tint(.white).foregroundStyle(.white)
            }
        }
        .aspectRatio(16.0 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("封面预览")
        .accessibilityValue(String(format: "%.3f 秒，", selectedSeconds) +
            (matchingPreview != nil ? "已载入" : previewError == nil ? "正在提取" : "提取失败"))
        .accessibilityIdentifier("videoCoverPreview")
    }

    private func loadDuration() async {
        guard isLocalVideoAvailable else {
            isLoadingDuration = false
            previewError = "本机视频不可用。"
            return
        }
        let asset = AVURLAsset(url: localURL, options: [AVURLAssetReferenceRestrictionsKey:
            AVAssetReferenceRestrictions.forbidLocalReferenceToRemote.rawValue])
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            asset.cancelLoading()
        }
        defer { timeout.cancel(); asset.cancelLoading() }
        let loaded = await withTaskCancellationHandler {
            try? await asset.load(.duration)
        } onCancel: { asset.cancelLoading() }
        guard !Task.isCancelled else { return }
        isLoadingDuration = false
        let validatedDuration = downloads.records.first(where: { $0.id == videoID })?.duration
        let knownDurations = [loaded?.seconds, validatedDuration].compactMap { value -> Double? in
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }
        guard isLocalVideoAvailable, let seconds = knownDurations.min() else {
            previewError = "无法读取视频时长，请关闭后重试。"
            return
        }
        duration = seconds
        if let saved = videoMetadata.coverFrameSeconds(for: videoID) {
            selectedSeconds = min(max(0, saved), maximumSeconds)
        } else {
            selectedSeconds = min(1, seconds * 0.1, maximumSeconds)
        }
    }

    private func loadPreview() async {
        let generation = UUID()
        previewGeneration = generation
        previewImage = nil
        previewSeconds = nil
        guard let duration, isLocalVideoAvailable else { return }
        previewError = nil
        let seconds = selectedSeconds
        do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
        guard !Task.isCancelled, previewGeneration == generation else { return }
        let data = await LocalVideoThumbnailRenderer.frameJPEG(url: localURL, seconds: seconds, duration: duration)
        guard !Task.isCancelled, previewGeneration == generation, selectedSeconds == seconds, isLocalVideoAvailable else { return }
        guard let data, let image = UIImage(data: data) else {
            previewError = "此位置的画面无法提取，请试试其他位置。"
            return
        }
        previewImage = image
        previewSeconds = seconds
    }

    private func move(by seconds: Double) {
        selectedSeconds = min(max(0, selectedSeconds + seconds), maximumSeconds)
    }

    private func save() {
        guard isLocalVideoAvailable else { saveError = "本机视频已移除，请下载后再选择封面。"; return }
        guard canSave else { saveError = "请等待当前画面加载完成。"; return }
        do {
            try videoMetadata.setCoverFrameSeconds(selectedSeconds, for: videoID)
            dismiss()
        } catch { saveError = error.localizedDescription }
    }

    private func useAutomaticCover() {
        guard isLocalVideoAvailable else { saveError = "本机视频已移除，请下载后再选择封面。"; return }
        do {
            try videoMetadata.setCoverFrameSeconds(nil, for: videoID)
            dismiss()
        } catch { saveError = error.localizedDescription }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds <= Double(Int.max / 1_000 - 1) else { return "--:--.---" }
        let milliseconds = Int((seconds * 1_000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let fraction = milliseconds % 1_000
        if hours > 0 { return String(format: "%d:%02d:%02d.%03d", hours, minutes, seconds, fraction) }
        return String(format: "%02d:%02d.%03d", minutes, seconds, fraction)
    }
}
