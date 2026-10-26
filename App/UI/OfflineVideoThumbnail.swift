import SwiftUI

struct OfflineVideoThumbnail: View {
    let record: DownloadRecord
    let localURL: URL?
    @ObservedObject var store: VideoThumbnailStore
    var frameSeconds: Double? = nil
    @State private var image: UIImage?

    private var sourceID: String {
        "\(record.id)|\(record.phase.rawValue)|\(record.localRelativePath ?? "")|\(frameSeconds.map { String($0.bitPattern, radix: 16) } ?? "automatic")"
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
        .accessibilityValue(frameSeconds.map { "自选封面 · \(String(format: "%.1f", $0))秒" } ?? "自动封面")
        .task(id: sourceID) {
            guard !Task.isCancelled else { return }
            image = nil
            let loaded = await store.image(for: record, localURL: localURL, frameSeconds: frameSeconds)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
