import AVKit
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The picker owns its URL only during the transfer callback. Keep an owned,
/// protected copy until validation/import finishes, then remove it even after cancellation.
final class SelectedVideoFile: @unchecked Sendable {
    let url: URL
    private let directory: URL

    private init(url: URL, directory: URL) {
        self.url = url
        self.directory = directory
    }

    static func copy(from source: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws -> SelectedVideoFile {
        try Task.checkCancellation()
        guard source.isFileURL else { throw LocalVideoImportError.invalidSelection }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0 else { throw LocalVideoImportError.invalidSelection }
        let ext = source.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else { throw LocalVideoImportError.unsupportedFormat }
        let directory = temporaryDirectory.appendingPathComponent("VYuVideoImport-" + UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("video." + ext)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path)
            try Task.checkCancellation()
            return SelectedVideoFile(url: destination, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private enum LocalVideoImportError: LocalizedError {
    case invalidSelection, unsupportedFormat
    var errorDescription: String? {
        switch self {
        case .invalidSelection: return "未能读取选中的视频，请重新选择。"
        case .unsupportedFormat: return "请先在相册中将视频保存为 MP4 或 MOV，再导入。"
        }
    }
}

private struct SelectedVideoTransfer: Transferable {
    let file: SelectedVideoFile
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            SelectedVideoTransfer(file: try SelectedVideoFile.copy(from: received.file))
        }
    }
}

@MainActor
private final class LocalVideoImportModel: ObservableObject {
    @Published var title = "导入的视频"
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isLoading = false
    @Published private(set) var isImporting = false
    @Published private(set) var message: String?
    private var file: SelectedVideoFile?
    private var operation: Task<Void, Never>?
    private var generation = UUID()

    var canImport: Bool { file != nil && !isLoading && !isImporting }

    func select(_ item: PhotosPickerItem) {
        cancel()
        let generation = self.generation
        isLoading = true
        message = nil
        operation = Task {
            do {
                guard let result = try await item.loadTransferable(type: SelectedVideoTransfer.self) else {
                    throw LocalVideoImportError.invalidSelection
                }
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                file = result.file
                player = AVPlayer(url: result.file.url)
                isLoading = false
            } catch {
                guard self.generation == generation else { return }
                isLoading = false
                if !(error is CancellationError) {
                    if let issue = error as? LocalVideoImportError { message = issue.localizedDescription }
                    else { message = "未能读取选中的视频。如果视频还在 iCloud 相册中，请联网后重试。" }
                }
            }
        }
    }

    func save(using downloads: DownloadManager, completion: @escaping () -> Void) {
        guard canImport, let file else { return }
        player?.pause()
        isImporting = true
        message = nil
        let generation = self.generation
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        operation = Task {
            do {
                _ = try await downloads.importLocalVideo(from: file.url, title: title.isEmpty ? "导入的视频" : title)
                // A successful manager commit is the point at which this video
                // becomes visible in the offline list; the picker copy can go.
                guard self.generation == generation else { return }
                isImporting = false
                clearSelection()
                completion()
            } catch {
                guard self.generation == generation else { return }
                isImporting = false
                if !(error is CancellationError) {
                    if let issue = error as? DownloadIssue { message = issue.localizedDescription }
                    else { message = "视频未能导入。请确认相册中的视频可完整播放，并检查本机存储空间。" }
                }
            }
        }
    }

    func cancel() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        isLoading = false
        isImporting = false
        clearSelection()
    }

    private func clearSelection() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        file = nil
    }
}

struct LocalVideoImportSheet: View {
    @ObservedObject var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LocalVideoImportModel()
    @State private var selectedItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("在控制中心开启录屏，回到网页从头播放视频；播放结束后停止录屏，再从这里选择相册中的录屏。")
                    Text("录屏可能包含网页和播放控件。可先在相册中裁剪，并确认画面和声音正常；部分视频不允许录制。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("下载失败时，也可导入录屏") }

                Section {
                    PhotosPicker(selection: $selectedItem, matching: .videos, preferredItemEncoding: .current) {
                        Label(model.player == nil ? "从相册选择录屏或视频" : "重新选择视频", systemImage: "photo.on.rectangle")
                    }
                    .disabled(model.isImporting)
                    .accessibilityIdentifier("chooseImportVideo")
                    if model.isLoading {
                        ProgressView("正在读取视频…").accessibilityIdentifier("importVideoLoading")
                    }
                    if let player = model.player {
                        VideoPlayer(player: player).frame(height: 230)
                            .accessibilityIdentifier("importVideoPreview")
                        Text("播放检查后再导入。录屏中的黑屏或缺失声音无法自动恢复。")
                            .font(.footnote).foregroundStyle(.secondary)
                        TextField("视频名称", text: $model.title)
                            .disabled(model.isImporting).accessibilityIdentifier("importVideoTitle")
                    }
                    if let message = model.message {
                        Text(message).foregroundStyle(.red).accessibilityIdentifier("importVideoError")
                    }
                    if model.isImporting {
                        ProgressView("正在检查并保存视频…").accessibilityIdentifier("importVideoSaving")
                    }
                } footer: {
                    Text("只读取你选择的视频。导入成功后可在离线列表播放，并按现有设置同步到 iCloud。")
                }
            }
            .navigationTitle("导入录屏/视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { model.cancel(); dismiss() }.accessibilityIdentifier("cancelVideoImport")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { model.save(using: downloads) { dismiss() } }
                        .disabled(!model.canImport).accessibilityIdentifier("saveImportedVideo")
                }
            }
            .interactiveDismissDisabled(model.isLoading || model.isImporting)
            .onChange(of: selectedItem) { _, item in if let item { model.select(item) } }
            .onDisappear { model.cancel() }
        }
    }
}
