import SwiftUI

struct OfflineVideoThumbnail: View {
    let record: DownloadRecord
    let localURL: URL?
    let store: VideoThumbnailStore
    @State private var image: UIImage?

    private var sourceID: String {
        "\(record.id)|\(record.phase.rawValue)|\(record.localRelativePath ?? "")"
    }

    var body: some View {
        ZStack {
            if let image {
                Color.black
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color(uiColor: .tertiarySystemFill)
                Image(systemName: "film")
                    .font(.title2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 112, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(image == nil ? "暂无视频预览" : "视频预览图")
        .accessibilityIdentifier(image == nil ? "videoThumbnailPlaceholder" : "videoThumbnail")
        .task(id: sourceID) {
            guard !Task.isCancelled else { return }
            image = nil
            let loaded = await store.image(for: record, localURL: localURL)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
