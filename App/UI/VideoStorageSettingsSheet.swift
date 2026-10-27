import SwiftUI

struct VideoStorageSettingsSheet: View {
    @ObservedObject var storage: VideoStorageOptimizer
    @ObservedObject var cloud: CloudVideoSync
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("优化本地存储", isOn: Binding(get: { storage.isEnabled }, set: { value in
                        do { try storage.setEnabled(value) }
                        catch { errorMessage = error.localizedDescription }
                    })).accessibilityIdentifier("optimizeLocalStorageToggle")
                    LabeledContent("视频缓存上限", value: "1 GB")
                    Text("优先保留收藏的视频，同类优先保留最近更新的内容。超过上限时，释放已确认上传到 iCloud 的旧副本；再次播放时下载。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("视频缓存", value: bytes(storage.localBytes))
                        .accessibilityIdentifier("storageUsage")
                    if !storage.usageAvailable {
                        Text("iCloud 驻留副本的占用待确认。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if storage.cloudCacheBytes > 0 {
                        LabeledContent("其中 iCloud 驻留副本", value: bytes(storage.cloudCacheBytes))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await storage.maintain() }
                    } label: {
                        if storage.isMaintaining { ProgressView("正在校验并优化…") }
                        else { Text("立即优化") }
                    }.disabled(!storage.isEnabled || storage.isMaintaining)
                        .accessibilityIdentifier("optimizeLocalStorageNow")
                    if let message = storage.message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("localStorageStatus")
                    }
                } header: {
                    Text("本机占用")
                } footer: {
                    Text("未上传成功、正在播放或正在选封面的视频会保留，可能暂时超过上限。封面、浏览数据和同步临时空间另计。")
                }
                Section {
                    Label("视频仍保留在 iCloud", systemImage: "icloud")
                    Text("优化只释放本机副本，标题、标签、收藏和封面仍在列表中。未缓存的视频需要联网后下载播放。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !cloud.isAvailable {
                        Text(cloud.message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("本地存储")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }.accessibilityIdentifier("closeStorageSettings")
                    }
                }
                .task { await storage.refreshUsage() }
                .alert("无法保存设置", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                    Button("好") { errorMessage = nil }
                } message: { Text(errorMessage ?? "请稍后重试。") }
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
