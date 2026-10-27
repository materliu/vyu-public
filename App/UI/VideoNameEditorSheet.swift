import SwiftUI

struct VideoNameEditorSheet: View {
    let videoID: UUID
    let originalTitle: String
    let initialTitle: String
    @ObservedObject var videoMetadata: VideoMetadataStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var draft: String
    @State private var saveError: String?

    init(videoID: UUID, originalTitle: String, videoMetadata: VideoMetadataStore) {
        self.videoID = videoID
        self.originalTitle = originalTitle
        self.videoMetadata = videoMetadata
        let title = videoMetadata.displayTitle(for: videoID, fallback: originalTitle)
        initialTitle = title
        _draft = State(initialValue: title)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("视频名称") {
                    TextField("输入名称", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($nameFocused)
                        .accessibilityLabel("视频名称")
                        .accessibilityIdentifier("videoNameInput")
                }
            }
            .navigationTitle("重命名").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.accessibilityIdentifier("cancelVideoName")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).fontWeight(.semibold)
                        .disabled(!canSave).accessibilityIdentifier("saveVideoName")
                }
            }
            .onAppear { nameFocused = true }
            .alert("名称未能保存", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("好") { saveError = nil }
            } message: {
                Text(saveError ?? "请重试。")
            }
        }
    }

    private var canSave: Bool {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name != initialTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard canSave else { return }
        do {
            try videoMetadata.rename(draft, for: videoID, fallback: originalTitle)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
