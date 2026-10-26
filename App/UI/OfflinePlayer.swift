import SwiftUI
import AVKit

@MainActor final class PlayerModel: ObservableObject {
    let player: AVPlayer
    @Published var seconds: Double = 0
    @Published var failed = false
    private let asset: AVURLAsset
    private let position: Double
    private let requiresAudio: Bool
    private var started = false
    private var observer: Any?
    private var statusObserver: NSKeyValueObservation?
    init(url: URL, position: Double, requiresAudio: Bool) {
        asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidLocalReferenceToRemote.rawValue])
        self.position = position; self.requiresAudio = requiresAudio
        player = AVPlayer()
        player.appliesMediaSelectionCriteriaAutomatically = false
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in if time.seconds.isFinite { self?.seconds = time.seconds } }
        }
    }
    func start() async {
        guard !started else { return }; started = true
        do {
            let item = try await OfflineMediaPreparation.makeItem(asset: asset, requiresAudio: requiresAudio)
            guard !Task.isCancelled else { return }
            statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .failed { Task { @MainActor in self?.failed = true } }
            }
            player.replaceCurrentItem(with: item)
            if position > 0 { await player.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
            guard !Task.isCancelled else { return }
            player.play()
        } catch { failed = true }
    }
    func stop() { player.pause(); if let observer { player.removeTimeObserver(observer); self.observer = nil } }
}

struct OfflinePlayer: View {
    let record: DownloadRecord
    @ObservedObject var library: LibraryStore
    @StateObject private var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    init(url: URL, record: DownloadRecord, library: LibraryStore) {
        self.record = record; self.library = library
        let position = library.positions[record.id.uuidString] ?? 0
        _model = StateObject(wrappedValue: PlayerModel(url: url, position: position >= (record.duration ?? .infinity) - 1 ? 0 : position, requiresAudio: record.hasAudio == true))
    }
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            NativePlayer(player: model.player).ignoresSafeArea(edges: .bottom)
            HStack {
                Button { save(); dismiss() } label: { Image(systemName: "chevron.down").padding(12).background(.ultraThinMaterial, in: Circle()) }.accessibilityIdentifier("closePlayer")
                Spacer()
                Text(model.failed ? "文件无法播放，请重新下载" : "本机视频 · 离线播放")
                    .font(.caption).padding(10).background(.ultraThinMaterial, in: Capsule()).accessibilityIdentifier("offlinePlaybackLabel")
            }.padding().foregroundStyle(.white)
            #if DEBUG
            VStack { Spacer(); Text(String(format: "播放 %.1f 秒", model.seconds)).font(.caption2).foregroundStyle(.white.opacity(0.7)).accessibilityIdentifier("playbackClock") }.padding(.bottom, 60).allowsHitTesting(false)
            #endif
        }
        .task { await model.start() }
        .onChange(of: model.seconds) { _, seconds in if Int(seconds) % 5 == 0 { library.setPosition(seconds, for: record.id) } }
        .onDisappear { save(); model.stop() }
    }
    private func save() { library.setPosition(model.seconds, for: record.id) }
}

struct NativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController(); controller.player = player
        controller.allowsPictureInPicturePlayback = true
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}
