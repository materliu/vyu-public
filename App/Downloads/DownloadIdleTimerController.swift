import Combine
import UIKit

/// Keeps the app's screen awake only while a foreground download is doing work.
/// This changes the current application's idle timer, never system settings.
@MainActor
final class DownloadIdleTimerController: ObservableObject {
    private let setDisabled: (Bool) -> Void
    @Published private(set) var isKeepingAwake = false

    init(setDisabled: @escaping (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }) {
        self.setDisabled = setDisabled
    }

    func update(isSceneActive: Bool, hasActiveDownloads: Bool) {
        let shouldKeepAwake = isSceneActive && hasActiveDownloads
        guard shouldKeepAwake != isKeepingAwake else { return }
        isKeepingAwake = shouldKeepAwake
        setDisabled(shouldKeepAwake)
    }

    func reset() {
        update(isSceneActive: false, hasActiveDownloads: false)
    }
}
