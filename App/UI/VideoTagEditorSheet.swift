import SwiftUI

struct VideoTagEditorSheet: View {
    let videoID: UUID
    let title: String
    @ObservedObject var videoMetadata: VideoMetadataStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var saveError: String?

    init(videoID: UUID, title: String, videoMetadata: VideoMetadataStore) {
        self.videoID = videoID
        self.title = title
        self.videoMetadata = videoMetadata
        _draft = State(initialValue: videoMetadata.tags(for: videoID).joined(separator: "，"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("视频") {
                    Text(title).font(.subheadline).accessibilityIdentifier("tagEditorVideoTitle")
                }
                Section {
                    TextEditor(text: $draft)
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("视频标签")
                        .accessibilityIdentifier("videoTagInput")
                } header: {
                    Text("标签")
                } footer: {
                    Text("用逗号或换行分隔，例如：旅行，教程。清空后保存可移除标签。")
                }
                if !suggestions.isEmpty {
                    Section("已有标签") {
                        ForEach(suggestions, id: \.self) { tag in
                            Button {
                                addSuggestion(tag)
                            } label: {
                                HStack {
                                    Label(tag, systemImage: "tag")
                                    Spacer()
                                    if containsTag(tag) { Image(systemName: "checkmark") }
                                    else { Image(systemName: "plus") }
                                }.foregroundStyle(containsTag(tag) ? Color.secondary : Color.accentColor)
                            }.disabled(containsTag(tag))
                                .accessibilityIdentifier("suggestedVideoTag")
                        }
                    }
                }
            }
            .navigationTitle("编辑标签").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.accessibilityIdentifier("cancelVideoTags")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).fontWeight(.semibold).accessibilityIdentifier("saveVideoTags")
                }
            }
            .alert("标签未能保存", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("好") { saveError = nil }
            } message: {
                Text(saveError ?? "请重试。")
            }
        }
    }

    private var draftTags: [String] {
        draft.components(separatedBy: CharacterSet(charactersIn: ",，\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var suggestions: [String] {
        var seen: Set<String> = []
        return videoMetadata.entries.values.flatMap(\.tags)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .filter { seen.insert($0.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)).inserted }
            .prefix(24).map { $0 }
    }

    private func containsTag(_ tag: String) -> Bool {
        let key = tag.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
        return draftTags.contains { $0.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current) == key }
    }

    private func addSuggestion(_ tag: String) {
        guard !containsTag(tag) else { return }
        draft = (draftTags + [tag]).joined(separator: "，")
    }

    private func save() {
        do {
            try videoMetadata.setTags(draftTags, for: videoID)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
